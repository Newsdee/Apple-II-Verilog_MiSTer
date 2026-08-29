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
    # Golden side: the module has no reset. GHDL starts uninitialized state
    # at 'U' and 'U' propagates through the HAL network forever (verified in
    # the apple2 harness), while Verilator zero-initializes all regs. The
    # runner therefore generates a copy of the golden RTL under build/ that
    # is byte-identical EXCEPT for explicit zero initial values on the state
    # signals the original leaves uninitialized (matches Verilator power-on
    # state exactly; no logic changed). Strictly verified below.
    $goldenSrc = Join-Path $referenceRoot 'rtl\timing_generator.vhd'
    $goldenCopy = Join-Path $vhdlBuild 'timing_generator_golden.vhd'
    $srcBytes = [System.IO.File]::ReadAllBytes($goldenSrc)
    $hasBom = ($srcBytes.Length -ge 3 -and $srcBytes[0] -eq 0xEF -and $srcBytes[1] -eq 0xBB -and $srcBytes[2] -eq 0xBF)
    $srcText = [System.IO.File]::ReadAllText($goldenSrc, [System.Text.Encoding]::UTF8)
    $replacements = @(
        @('signal COLOR_DELAY_N : std_logic;', 'signal COLOR_DELAY_N : std_logic := ''0'';'),
        @('signal CLK_7M: std_logic;', 'signal CLK_7M: std_logic := ''0'';'),
        @('SEGA        : buffer std_logic;', 'SEGA        : buffer std_logic := ''0'';'),
        @('SEGB        : buffer std_logic;', 'SEGB        : buffer std_logic := ''0'';'),
        @('SEGC        : buffer std_logic;', 'SEGC        : buffer std_logic := ''0'';'),
        @('GR1         : buffer std_logic;', 'GR1         : buffer std_logic := ''0'';'),
        @('GR2         : buffer std_logic;', 'GR2         : buffer std_logic := ''0'';'),
        @('HBLANK         : out std_logic;      -- Horizontal blanking', 'HBLANK         : out std_logic := ''0'';      -- Horizontal blanking'),
        @('VBLANK         : out std_logic;      -- Vertical blanking', 'VBLANK         : out std_logic := ''0'';      -- Vertical blanking'),
        @('WNDW_N         : out std_logic;      -- Composite blanking', 'WNDW_N         : out std_logic := ''0'';      -- Composite blanking'),
        @('LDPS_N         : out std_logic', 'LDPS_N         : out std_logic := ''0''')
    )
    $dstText = $srcText
    $lenDelta = 0
    foreach ($pair in $replacements) {
        $needle = $pair[0]
        $replacement = $pair[1]
        if (([regex]::Matches($dstText, [regex]::Escape($needle))).Count -ne 1) {
            throw "Shim generation failed: expected exactly 1 occurrence of '$needle'"
        }
        $dstText = $dstText.Replace($needle, $replacement)
        $lenDelta += ($replacement.Length - $needle.Length)
    }
    if ($dstText.Length -ne $srcText.Length + $lenDelta) {
        throw 'Shim generation failed: unexpected text length change'
    }
    [System.IO.File]::WriteAllText($goldenCopy, $dstText, (New-Object System.Text.UTF8Encoding($hasBom)))

    # This GHDL build has no --generic option, so the two phases are two
    # separate workdirs with generated TB copies (PHASE generic default 0 or
    # 1; strict single-replacement check).
    $tbSrc = Join-Path $PSScriptRoot 'timing_generator_vhdl_tb.vhd'
    $tbSrcText = [System.IO.File]::ReadAllText($tbSrc, [System.Text.Encoding]::UTF8)
    foreach ($phase in 0, 1) {
        $tag = if ($phase -eq 0) { 'ntsc' } else { 'pal' }
        $wdir = Join-Path $buildRoot ("vhdl_{0}" -f $tag)
        New-Item -ItemType Directory -Force -Path $wdir | Out-Null
        $tbCopy = Join-Path $wdir 'timing_generator_vhdl_tb.vhd'
        if ($phase -eq 0) {
            [System.IO.File]::WriteAllText($tbCopy, $tbSrcText, (New-Object System.Text.UTF8Encoding($false)))
        } else {
            $needle = 'PHASE : integer := 0'
            if (([regex]::Matches($tbSrcText, [regex]::Escape($needle))).Count -ne 1) {
                throw "TB copy generation failed: expected exactly 1 occurrence of '$needle'"
            }
            [System.IO.File]::WriteAllText($tbCopy, $tbSrcText.Replace($needle, 'PHASE : integer := 1'), (New-Object System.Text.UTF8Encoding($false)))
        }
        & $ghdl -a --std=08 "--workdir=$wdir" $goldenCopy $tbCopy
        if ($LASTEXITCODE -ne 0) { throw "GHDL analysis ($tag) failed with exit code $LASTEXITCODE" }
        & $ghdl -e --std=08 "--workdir=$wdir" timing_generator_vhdl_tb
        if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration ($tag) failed with exit code $LASTEXITCODE" }
    }

    # Candidate side: two builds (PHASE parameter), no ROMs.
    foreach ($phase in 0, 1) {
        $vdir = Join-Path $buildRoot ("verilog_{0}" -f $(if ($phase -eq 0) { 'ntsc' } else { 'pal' }))
        $aggregate = Join-Path $vdir 'Vtiming_generator_verilog_tb__ALL.cpp'
        if ((Test-Path $aggregate) -and (Get-Item $aggregate).Length -eq 0) {
            Remove-Item -Force $aggregate
        }
        & $verilator --binary --timing -Wno-fatal ("-GPHASE=" + $phase) --top-module timing_generator_verilog_tb --Mdir $vdir `
            (Join-Path $PSScriptRoot 'timing_generator_verilog_tb.sv') (Join-Path $projectRoot 'rtl\timing_generator.v')
        if ($LASTEXITCODE -ne 0) { throw "Verilator build (phase $phase) failed with exit code $LASTEXITCODE" }
    }

    Push-Location $projectRoot
    try {
        foreach ($phase in 0, 1) {
            $tag = if ($phase -eq 0) { 'ntsc' } else { 'pal' }
            & $ghdl -r --std=08 "--workdir=$(Join-Path $buildRoot ("vhdl_{0}" -f $tag))" timing_generator_vhdl_tb
            if ($LASTEXITCODE -ne 0) { throw "VHDL simulation ($tag) failed with exit code $LASTEXITCODE" }
        }
        & (Join-Path $buildRoot 'verilog_ntsc\Vtiming_generator_verilog_tb.exe')
        if ($LASTEXITCODE -ne 0) { throw "Verilog simulation (NTSC) failed with exit code $LASTEXITCODE" }
        & (Join-Path $buildRoot 'verilog_pal\Vtiming_generator_verilog_tb.exe')
        if ($LASTEXITCODE -ne 0) { throw "Verilog simulation (PAL) failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

$columns = @('PHI0', 'Q3', 'RAS_N', 'AX', 'CAS_N', 'VID7M', 'COLOR_REF', 'PHI0_EN_R', 'PHI0_EN_F',
             'HBLANK', 'VBLANK', 'WNDW_N', 'LDPS_N', 'GR1', 'GR2', 'SEGA', 'SEGB', 'SEGC', 'VIDEO_ADDRESS')

function Compare-Phase([string]$name, [string]$vhdlCsv, [string]$verilogCsv, [double]$expectedRatio) {
    $vhdlRows = @(Import-Csv $vhdlCsv)
    $verilogRows = @(Import-Csv $verilogCsv)
    if ($vhdlRows.Count -ne $verilogRows.Count) {
        throw "$name`: trace length mismatch: VHDL=$($vhdlRows.Count), Verilog=$($verilogRows.Count)"
    }

    $comparedFields = 0
    $ignoredMetavalues = 0
    $transitions = @{}
    $valuesSeen = @{}
    $prev = @{}
    $addrValues = New-Object System.Collections.Generic.HashSet[string]
    # VBLANK period-ratio gate (see header comment for the machine model).
    $highPeriods = New-Object System.Collections.Generic.List[int]
    $lowPeriods = New-Object System.Collections.Generic.List[int]
    $vbState = $null
    $vbStateStart = 0

    for ($rowIndex = 0; $rowIndex -lt $vhdlRows.Count; $rowIndex++) {
        $vhdlRow = $vhdlRows[$rowIndex]
        $verilogRow = $verilogRows[$rowIndex]
        if ($vhdlRow.CYCLE -ne $verilogRow.CYCLE) {
            throw "$name`: cycle mismatch at row ${rowIndex}: VHDL=$($vhdlRow.CYCLE), Verilog=$($verilogRow.CYCLE)"
        }

        foreach ($column in $columns) {
            $expected = $vhdlRow.$column.ToUpperInvariant()
            $actual = $verilogRow.$column.ToUpperInvariant()
            if ($expected -match '[UXWZ-]') {
                $ignoredMetavalues++
                continue
            }
            $comparedFields++
            if ($expected -ne $actual) {
                throw "$name`: mismatch at cycle $($vhdlRow.CYCLE), $column`: VHDL=$expected, Verilog=$actual"
            }
        }

        foreach ($column in $columns) {
            $v = $vhdlRow.$column.ToUpperInvariant()
            if ($v -match '[UXWZ-]') { continue }
            if (-not $valuesSeen.ContainsKey("$column")) { $valuesSeen["$column"] = New-Object System.Collections.Generic.HashSet[string] }
            [void]$valuesSeen["$column"].Add($v)
            if ($prev.ContainsKey($column) -and $prev[$column] -ne $v) {
                if (-not $transitions.ContainsKey($column)) { $transitions[$column] = 0 }
                $transitions[$column] = $transitions[$column] + 1
            }
            $prev[$column] = $v
        }
        [void]$addrValues.Add($vhdlRow.VIDEO_ADDRESS.ToUpperInvariant())

        $vb = $vhdlRow.VBLANK
        if ($vb -match '[UXWZ-]') { continue }
        $cyc = [int]$vhdlRow.CYCLE
        if ($null -eq $vbState) {
            $vbState = $vb
            $vbStateStart = $cyc
        } elseif ($vb -ne $vbState) {
            if ($vbState -eq '1') { $highPeriods.Add($cyc - $vbStateStart) }
            else { $lowPeriods.Add($cyc - $vbStateStart) }
            $vbState = $vb
            $vbStateStart = $cyc
        }
    }

    # The first high period is a partial startup period (V starts inside the
    # VBL=1 region at 250), so complete (high, low) pairs start at index 1.
    $pairs = [Math]::Min($highPeriods.Count, $lowPeriods.Count) - 1
    if ($pairs -lt 2) { throw "$name`: coverage failure: only $pairs complete VBLANK periods (need >= 2)" }
    for ($i = 1; $i -le [Math]::Min($pairs, 3); $i++) {
        $ratio = [double]$lowPeriods[$i] / $highPeriods[$i]
        if ([Math]::Abs($ratio - $expectedRatio) -gt 0.1) {
            throw "$name`: coverage failure: VBLANK low/high ratio $ratio at period $i, expected $expectedRatio (V did not wrap 511 -> V_RESET for this PALMODE)"
        }
    }

    if ($transitions['PHI0'] -lt 100) { throw "$name`: coverage failure: only $($transitions['PHI0']) PHI0 transitions (HAL did not self-start)" }
    foreach ($column in @('RAS_N', 'AX', 'CAS_N', 'Q3', 'VID7M', 'COLOR_REF')) {
        if ($valuesSeen[$column].Count -lt 2) { throw "$name`: coverage failure: $column never changed value" }
    }
    foreach ($column in @('GR1', 'GR2', 'SEGA', 'SEGB', 'SEGC')) {
        if ($valuesSeen[$column].Count -lt 2) { throw "$name`: coverage failure: $column never changed value (mode inputs not exercised)" }
    }
    if ($addrValues.Count -lt 2000) { throw "$name`: coverage failure: only $($addrValues.Count) distinct VIDEO_ADDRESS values" }
    if ($valuesSeen['LDPS_N'].Count -lt 2) { throw "$name`: coverage failure: LDPS_N never changed value" }
    if ($comparedFields -lt 300000) { throw "$name`: coverage failure: only $comparedFields initialized fields compared" }

    $lastRatio = [double]$lowPeriods[$pairs] / $highPeriods[$pairs]
    Write-Output "$name`: rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues phi0_transitions=$($transitions['PHI0']) vbl_ratio=$([Math]::Round($lastRatio, 3)) distinct_addrs=$($addrValues.Count)"
}

# Expected VBLANK low/high ratios (fingerprint of the 511 -> V_RESET wrap):
# NTSC V_RESET=250: VBL high 70 lines / low 192 lines -> 192/70 = 2.743
# PAL  V_RESET=200: VBL high 120 lines / low 192 lines -> 192/120 = 1.600
$ntsc = Compare-Phase 'NTSC' (Join-Path $buildRoot 'vhdl_ntsc.csv') (Join-Path $buildRoot 'verilog_ntsc.csv') 2.743
$pal = Compare-Phase 'PAL' (Join-Path $buildRoot 'vhdl_pal.csv') (Join-Path $buildRoot 'verilog_pal.csv') 1.600

Write-Output "TIMING_GENERATOR EQUIVALENCE PASS ntsc($ntsc) pal($pal)"
