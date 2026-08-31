param([switch]$CompareOnly)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$referenceRoot = (Resolve-Path (Join-Path $projectRoot '..\Apple-II_MiSTer_newsdee')).Path
$buildRoot = Join-Path $PSScriptRoot 'build'
$vhdlBuild = Join-Path $buildRoot 'vhdl'
$ghdl = 'C:\msys64\ucrt64\bin\ghdl.exe'
$verilator = 'C:\msys64\ucrt64\bin\verilator_bin.exe'

if (!(Test-Path $ghdl)) { throw "GHDL not found at $ghdl" }
if (!(Test-Path $verilator)) { throw "Verilator not found at $verilator" }
$env:VERILATOR_ROOT = 'C:/msys64/ucrt64/share/verilator'
$env:MAKE = 'C:\msys64\ucrt64\bin\mingw32-make.exe'
$env:SHELL = 'C:\msys64\usr\bin\sh.exe'
$env:Path = "C:\msys64\usr\bin;C:\msys64\ucrt64\bin;$env:Path"

New-Item -ItemType Directory -Force -Path $vhdlBuild | Out-Null

if (!$CompareOnly) {
    # ROM parity: golden loads rtl/roms/video2.mif (newsdee, via the
    # spram_const shim segment generated from it); the candidate reads
    # rtl/roms/video2.hex. They must be byte-identical (8192 bytes).
    $mif = Get-Content (Join-Path $referenceRoot 'rtl\roms\video2.mif')
    $mifBytes = @()
    $inContent = $false
    foreach ($line in $mif) {
        if ($line -match '^\s*CONTENT\s+BEGIN') { $inContent = $true; continue }
        if ($line -match '^\s*END\s*;') { $inContent = $false; continue }
        if (-not $inContent) { continue }
        $body = $line -replace ':', ' ' -replace ';', ''
        foreach ($tok in ($body -split '\s+')) {
            if ($tok -match '^[0-9A-Fa-f]{2}$') { $mifBytes += $tok.ToLower() }
        }
    }
    $hexBytes = @()
    foreach ($line in (Get-Content (Join-Path $projectRoot 'rtl\roms\video2.hex'))) {
        foreach ($tok in ($line -split '\s+')) {
            if ($tok -match '^[0-9A-Fa-f]{2}$') { $hexBytes += $tok.ToLower() }
        }
    }
    if ($mifBytes.Count -ne 8192 -or $hexBytes.Count -ne 8192) {
        throw "ROM parity failure: expected 8192 bytes, got mif=$($mifBytes.Count) hex=$($hexBytes.Count)"
    }
    for ($i = 0; $i -lt 8192; $i++) {
        if ($mifBytes[$i] -ne $hexBytes[$i]) {
            throw "ROM parity failure at byte $i : mif=$($mifBytes[$i]) hex=$($hexBytes[$i])"
        }
    }
    Write-Output "ROM PARITY OK (video2.mif == video2.hex, 8192 bytes)"

    # Stimulus tables (identical for both sides) + runner metadata.
    & (Join-Path $PSScriptRoot 'gen_stim.ps1')
    if (-not $?) { throw 'gen_stim.ps1 failed' }

    # Golden copy: GHDL 6.0.0 rejects the shorthand entity instantiation
    # `font_rom : work.spram`; add the explicit `entity` keyword only.
    $goldenSrc = Join-Path $referenceRoot 'rtl\old\apple2_font_rom.vhd'
    $goldenCopy = Join-Path $vhdlBuild 'apple2_font_rom_golden.vhd'
    $srcBytes = [System.IO.File]::ReadAllBytes($goldenSrc)
    $hasBom = ($srcBytes.Length -ge 3 -and $srcBytes[0] -eq 0xEF -and $srcBytes[1] -eq 0xBB -and $srcBytes[2] -eq 0xBF)
    $srcText = [System.IO.File]::ReadAllText($goldenSrc, [System.Text.Encoding]::UTF8)
    $needle = 'font_rom : work.spram'
    $replacement = 'font_rom : entity work.spram'
    if (([regex]::Matches($srcText, [regex]::Escape($needle))).Count -ne 1) {
        throw "Golden copy generation failed: expected 1 occurrence of '$needle'"
    }
    $dstText = $srcText.Replace($needle, $replacement)
    [System.IO.File]::WriteAllText($goldenCopy, $dstText, (New-Object System.Text.UTF8Encoding($hasBom)))

    # spram (shim) must be analyzed before the golden (direct instantiation).
    & $ghdl -a --std=08 "--workdir=$vhdlBuild" `
        (Join-Path $projectRoot 'module_tests\shared\spram_const.vhd') `
        $goldenCopy `
        (Join-Path $buildRoot 'stim_table.vhd') `
        (Join-Path $PSScriptRoot 'apple2_font_rom_vhdl_tb.vhd')
    if ($LASTEXITCODE -ne 0) { throw "GHDL analysis failed with exit code $LASTEXITCODE" }
    & $ghdl -e --std=08 "--workdir=$vhdlBuild" apple2_font_rom_vhdl_tb
    if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration failed with exit code $LASTEXITCODE" }

    $vdir = Join-Path $buildRoot 'verilog'
    $aggregate = Join-Path $vdir 'Vapple2_font_rom_verilog_tb__ALL.cpp'
    if ((Test-Path $aggregate) -and (Get-Item $aggregate).Length -eq 0) {
        Remove-Item -Force $aggregate
    }
    & $verilator --binary --timing -Wno-fatal --top-module apple2_font_rom_verilog_tb --Mdir $vdir `
        (Join-Path $buildRoot 'stim_table.sv') `
        (Join-Path $projectRoot 'rtl\apple2_font_rom.v') `
        (Join-Path $PSScriptRoot 'apple2_font_rom_verilog_tb.sv')
    if ($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

    Push-Location $projectRoot
    try {
        & $ghdl -r --std=08 "--workdir=$vhdlBuild" apple2_font_rom_vhdl_tb
        if ($LASTEXITCODE -ne 0) { throw "VHDL simulation failed with exit code $LASTEXITCODE" }
        & (Join-Path $vdir 'Vapple2_font_rom_verilog_tb.exe')
        if ($LASTEXITCODE -ne 0) { throw "Verilog simulation failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

# --- Runner metadata: per-cycle stimulus (wr/addr/data) + initial ROM ---
$metaByCycle = @{}
$writeCycles = New-Object System.Collections.Generic.List[int]
foreach ($row in (Import-Csv (Join-Path $buildRoot 'stim_meta.csv') | Select-Object -Skip 0)) {
    $c = [int]$row.CYCLE
    $wr = [int]$row.WR
    $metaByCycle[$c] = @{ wr = $wr; addr = [int]$row.ADDR; data = [int]$row.DATA }
    if ($wr) { $writeCycles.Add($c) }
}
$mem = @{}
$hexLines = Get-Content (Join-Path $projectRoot 'rtl\roms\video2.hex')
$i = 0
foreach ($line in $hexLines) {
    foreach ($tok in ($line -split '\s+')) {
        if ($tok -match '^[0-9A-Fa-f]{2}$') { $mem[$i] = $tok.ToUpperInvariant(); $i++ }
    }
}
if ($i -ne 8192) { throw "video2.hex parse: got $i bytes" }

$columns = @('ROMSWITCH', 'ALT', 'LOWER', 'CH', 'ROW', 'IOCTL_WR', 'IOCTL_ADDR', 'IOCTL_DATA', 'GLYPH_DATA')

$vhdlRows = @(Import-Csv (Join-Path $buildRoot 'vhdl_trace.csv'))
$verilogRows = @(Import-Csv (Join-Path $buildRoot 'verilog_trace.csv'))
if ($vhdlRows.Count -ne $verilogRows.Count) {
    throw "trace length mismatch: VHDL=$($vhdlRows.Count), Verilog=$($verilogRows.Count)"
}

$comparedFields = 0
$ignoredMetavalues = 0
$divergentWrites = 0
$equalWrites = 0
$firstDivergent = $null
$firstUnexpected = $null
$glyphValues = New-Object System.Collections.Generic.HashSet[string]
$altLowerPairs = New-Object System.Collections.Generic.HashSet[string]
$rsValues = New-Object System.Collections.Generic.HashSet[string]
$ch6Rows = 0

for ($rowIndex = 0; $rowIndex -lt $vhdlRows.Count; $rowIndex++) {
    $vhdlRow = $vhdlRows[$rowIndex]
    $verilogRow = $verilogRows[$rowIndex]
    $cycle = [int]$vhdlRow.CYCLE
    if ($vhdlRow.CYCLE -ne $verilogRow.CYCLE) {
        throw "cycle mismatch at row ${rowIndex}: VHDL=$($vhdlRow.CYCLE), Verilog=$($verilogRow.CYCLE)"
    }
    $meta = $metaByCycle[$cycle]
    $isWrite = ($meta -ne $null -and $meta.wr -eq 1)

    # Coverage bookkeeping (golden trace).
    if ($vhdlRow.GLYPH_DATA -notmatch '[UXWZ-]') { [void]$glyphValues.Add($vhdlRow.GLYPH_DATA.ToUpperInvariant()) }
    [void]$altLowerPairs.Add($vhdlRow.ALT + $vhdlRow.LOWER)
    [void]$rsValues.Add($vhdlRow.ROMSWITCH)
    if ([int]('0x' + $vhdlRow.CH) -ge 64) { $ch6Rows++ }

    foreach ($column in $columns) {
        $expected = $vhdlRow.$column.ToUpperInvariant()
        $actual = $verilogRow.$column.ToUpperInvariant()
        if ($expected -match '[UXWZ-]') { $ignoredMetavalues++; continue }

        if ($isWrite -and $column -eq 'GLYPH_DATA') {
            # Write cycle: golden spram is write-first (q = new data on the
            # write edge). Candidate aligned 2026-08-29 (glyph_data returns
            # ioctl_data on writes), so both sides must show the NEW value.
            # The memory model below tracks pre-write content for diagnostics.
            $data = ('{0:X2}' -f $meta.data)
            $pre  = $mem[$meta.addr]
            if ($data -eq $pre) {
                # Equal write: both sides must show the (same) value.
                $comparedFields++
                if ($expected -ne $actual) {
                    if ($null -eq $firstUnexpected) {
                        $firstUnexpected = "cycle ${cycle}, GLYPH_DATA (equal write): VHDL=$expected, Verilog=$actual"
                    }
                }
                $equalWrites++
            } else {
                # Divergent write (new != pre): both sides must show the NEW
                # value. divergentWrites counts aligned read-during-write
                # probes (coverage evidence); any other combination fails.
                $comparedFields++
                if ($expected -ne $actual) {
                    if ($null -eq $firstUnexpected) {
                        $firstUnexpected = "cycle ${cycle}, GLYPH_DATA (divergent write): VHDL=$expected (new=$data), Verilog=$actual (pre=$pre)"
                    }
                } else {
                    if ($null -eq $firstDivergent) { $firstDivergent = "cycle ${cycle}, GLYPH_DATA: both show new=$expected" }
                    $divergentWrites++
                }
            }
            $mem[$meta.addr] = $data
        } else {
            $comparedFields++
            if ($expected -ne $actual) {
                if ($null -eq $firstUnexpected) {
                    $ctx = if ($isWrite) { ' (write cycle)' } else { '' }
                    $firstUnexpected = "cycle ${cycle}, ${column}${ctx}: VHDL=$expected, Verilog=$actual"
                }
            }
        }
    }
}

# Readback gate: for each Phase B write (the first 32 write cycles), both
# sides must show the written value at W+1 and W+2 (per-side check - a side
# failing its own readback is a harness error, not a cross-side divergence).
$readbackOk = 0
$rowsByCycle = @{}
for ($rowIndex = 0; $rowIndex -lt $vhdlRows.Count; $rowIndex++) {
    $rowsByCycle[[int]$vhdlRows[$rowIndex].CYCLE] = $vhdlRows[$rowIndex]
    $rowsByCycle['V' + [int]$verilogRows[$rowIndex].CYCLE] = $verilogRows[$rowIndex]
}
$phaseB = $writeCycles | Select-Object -First 32
foreach ($w in $phaseB) {
    $data = ('{0:X2}' -f $metaByCycle[$w].data)
    foreach ($off in 1, 2) {
        $v = $rowsByCycle[$w + $off].GLYPH_DATA.ToUpperInvariant()
        $e = $rowsByCycle['V' + ($w + $off)].GLYPH_DATA.ToUpperInvariant()
        if ($v -ne $data -or $e -ne $data) {
            throw "readback failure at cycle $($w + $off): VHDL=$v Verilog=$e, expected $data (write at cycle $w)"
        }
        $readbackOk++
    }
}

# --- Coverage gates ---
if ($vhdlRows.Count -lt 4200) { throw "coverage failure: only $($vhdlRows.Count) rows (need >= 4200)" }
if ($glyphValues.Count -lt 100) { throw "coverage failure: only $($glyphValues.Count) distinct GLYPH_DATA values (need >= 100)" }
foreach ($pair in @('00', '01', '10', '11')) {
    if (-not $altLowerPairs.Contains($pair)) { throw "coverage failure: ALT/LOWER pair $pair missing" }
}
foreach ($rs in @('0', '1')) {
    if (-not $rsValues.Contains($rs)) { throw "coverage failure: ROMSWITCH=$rs missing" }
}
if ($ch6Rows -lt 8) { throw "coverage failure: only $ch6Rows rows with CH(6)=1 (need >= 8)" }
if ($writeCycles.Count -lt 36) { throw "coverage failure: only $($writeCycles.Count) write cycles (need >= 36)" }
if ($readbackOk -ne 64) { throw "coverage failure: readback checks $readbackOk != 64" }
if ($ignoredMetavalues -gt 6) { throw "coverage failure: $ignoredMetavalues ignored metavalue fields (limit 6)" }

if ($null -ne $firstUnexpected) {
    throw "UNEXPECTED mismatch (not the known write-first signature): $firstUnexpected"
}

Write-Output ("APPLE2_FONT_ROM EQUIVALENCE PASS rows=$($vhdlRows.Count) fields=$comparedFields" +
    " ignored_metavalues=$ignoredMetavalues writes=$($writeCycles.Count)" +
    " divergent_write_probes=$divergentWrites equal_writes=$equalWrites readbacks_ok=$readbackOk rom_values=$($glyphValues.Count)")
