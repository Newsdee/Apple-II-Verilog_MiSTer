param([switch]$CompareOnly)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$referenceRoot = (Resolve-Path (Join-Path $projectRoot '..\Apple-II_MiSTer_newsdee')).Path
$buildRoot = Join-Path $PSScriptRoot 'build'
$vhdlBuild = Join-Path $buildRoot 'vhdl'
$verilogBuild = Join-Path $buildRoot 'verilog'
$ghdl = 'C:\msys64\ucrt64\bin\ghdl.exe'
$verilator = 'C:\msys64\ucrt64\bin\verilator_bin.exe'

if (!(Test-Path $ghdl)) { throw "GHDL not found at $ghdl" }
if (!(Test-Path $verilator)) { throw "Verilator not found at $verilator" }
$env:VERILATOR_ROOT = 'C:/msys64/ucrt64/share/verilator'
$env:MAKE = 'C:\msys64\ucrt64\bin\mingw32-make.exe'
$env:SHELL = 'C:\msys64\usr\bin\sh.exe'
$env:Path = "C:\msys64\usr\bin;C:\msys64\ucrt64\bin;$env:Path"

New-Item -ItemType Directory -Force -Path $vhdlBuild, $verilogBuild | Out-Null
$verilatorAggregate = Join-Path $verilogBuild 'Vvideo_generator_verilog_tb__ALL.cpp'
if ((Test-Path $verilatorAggregate) -and (Get-Item $verilatorAggregate).Length -eq 0) {
    Remove-Item -Force $verilatorAggregate
}

if (!$CompareOnly) {
    # Golden side: analyze the GHDL-safe constant-array spram shim INSTEAD of
    # rtl/spram.vhd (GHDL 6.0.0 does not honor ram_init_file and has a codegen
    # bug with case-based function calls in loops). The shim selects the
    # video2.mif segment via the init_file generic.
    #
    # GHDL 6.0.0 also rejects the LRM-legal shorthand entity instantiation
    # 'videorom : work.spram' in rtl/video_generator.vhd ("component name
    # expected, found entity"); Quartus accepts it. The golden RTL is left
    # untouched: a parse-normalized copy is generated under build/ that adds
    # the explicit 'entity' keyword only (a semantic no-op), with strict
    # verification that nothing else changed.
    #
    # NOTE: this GHDL build also rejects ALL hierarchical instance selection
    # (verified with minimal repros), so the testbench traces ports only and
    # recovers internal state behaviorally via the shift-register walkout
    # (see video_generator_vhdl_tb.vhd header).
    $goldenSrc = Join-Path $referenceRoot 'rtl\video_generator.vhd'
    $goldenCopy = Join-Path $vhdlBuild 'video_generator_golden.vhd'
    $srcBytes = [System.IO.File]::ReadAllBytes($goldenSrc)
    $hasBom = ($srcBytes.Length -ge 3 -and $srcBytes[0] -eq 0xEF -and $srcBytes[1] -eq 0xBB -and $srcBytes[2] -eq 0xBF)
    $srcText = [System.IO.File]::ReadAllText($goldenSrc, [System.Text.Encoding]::UTF8)
    $needle = 'videorom : work.spram'
    $replacement = 'videorom : entity work.spram'
    if (([regex]::Matches($srcText, [regex]::Escape($needle))).Count -ne 1) {
        throw "Golden normalization failed: expected exactly 1 occurrence of '$needle' in video_generator.vhd"
    }
    $dstText = $srcText.Replace($needle, $replacement)
    if ($dstText.Length -ne $srcText.Length + ($replacement.Length - $needle.Length)) {
        throw 'Golden normalization failed: unexpected text length change'
    }
    [System.IO.File]::WriteAllText($goldenCopy, $dstText, (New-Object System.Text.UTF8Encoding($hasBom)))

    $vhdlSources = @(
        (Join-Path $PSScriptRoot '..\shared\spram_const.vhd'),
        $goldenCopy,
        (Join-Path $PSScriptRoot 'video_generator_vhdl_tb.vhd')
    )

    & $ghdl -a --std=08 "--workdir=$vhdlBuild" $vhdlSources
    if ($LASTEXITCODE -ne 0) { throw "GHDL analysis failed with exit code $LASTEXITCODE" }
    & $ghdl -e --std=08 "--workdir=$vhdlBuild" video_generator_vhdl_tb
    if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration failed with exit code $LASTEXITCODE" }

    # Candidate side: rtl/video_generator.v uses an inline ROM loaded from
    # rtl/roms/video2.hex via $readmemh (CWD must be the repository root).
    $verilogSources = @(
        (Join-Path $PSScriptRoot 'video_generator_verilog_tb.sv'),
        (Join-Path $projectRoot 'rtl\video_generator.v')
    )
    & $verilator --binary --timing -Wno-fatal --top-module video_generator_verilog_tb --Mdir 'module_tests/video_generator/build/verilog' $verilogSources
    if ($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

    Push-Location $projectRoot
    try {
        & $ghdl -r --std=08 "--workdir=$vhdlBuild" video_generator_vhdl_tb
        if ($LASTEXITCODE -ne 0) { throw "VHDL simulation failed with exit code $LASTEXITCODE" }
        & (Join-Path $verilogBuild 'Vvideo_generator_verilog_tb.exe')
        if ($LASTEXITCODE -ne 0) { throw "Verilog simulation failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

$vhdlRows = @(Import-Csv (Join-Path $buildRoot 'vhdl_trace.csv'))
$verilogRows = @(Import-Csv (Join-Path $buildRoot 'verilog_trace.csv'))
if ($vhdlRows.Count -ne $verilogRows.Count) {
    throw "Trace length mismatch: VHDL=$($vhdlRows.Count), Verilog=$($verilogRows.Count)"
}

$columns = @('VIDEO', 'LDPS_N', 'WNDW_N', 'DL', 'MODE')
$comparedFields = 0
$ignoredMetavalues = 0
$video = @{}          # cycle -> VIDEO (VHDL side, upper)
$videoTransitions = 0
$prevVideo = ''
for ($rowIndex = 0; $rowIndex -lt $vhdlRows.Count; $rowIndex++) {
    $vhdlRow = $vhdlRows[$rowIndex]
    $verilogRow = $verilogRows[$rowIndex]
    if ($vhdlRow.CYCLE -ne $verilogRow.CYCLE) {
        throw "Cycle mismatch at row ${rowIndex}: VHDL=$($vhdlRow.CYCLE), Verilog=$($verilogRow.CYCLE)"
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
            throw "Mismatch at cycle $($vhdlRow.CYCLE), $column`: VHDL=$expected, Verilog=$actual"
        }
    }

    $v = $vhdlRow.VIDEO.ToUpperInvariant()
    if ($v -notmatch '[UXWZ-]') {
        $video[[int]$vhdlRow.CYCLE] = $v
        if ($prevVideo -ne '' -and $v -ne $prevVideo) { $videoTransitions++ }
        $prevVideo = $v
    }
}

function Get-Pattern([int]$start, [int]$len) {
    $s = ''
    for ($i = $start; $i -lt ($start + $len); $i++) {
        if (!$video.ContainsKey($i)) { throw "Gate failure: no VIDEO at cycle $i" }
        $s += $video[$i]
    }
    return $s
}

# Run-length-encode a VIDEO window to 'char x len' pairs. A load walks the
# byte out LSB-first inverted; CLK_7M hold phases only stretch the current
# run, never skip or reorder bits, so the run-length pattern is phase-robust
# (the exact run lengths below were derived from the verified CLK_7M phase:
# shift for (N mod 28) in 14..27, hold in 0..13).
function Get-RlePattern([string]$pattern) {
    $parts = @()
    $prev = ''
    $count = 0
    foreach ($ch in $pattern.ToCharArray()) {
        if ($ch -ne $prev) {
            if ($count -gt 0) { $parts += ("{0}x{1}" -f $prev, $count) }
            $prev = $ch
            $count = 1
        } else {
            $count++
        }
    }
    if ($count -gt 0) { $parts += ("{0}x{1}" -f $prev, $count) }
    return ($parts -join ',')
}

# Sync: WNDW_N=1 load at cycle 25 (the first load effective under the
# CLK_7M phase) -> FF shift register -> VIDEO all 0 until the next load (50).
$sync = Get-RlePattern (Get-Pattern 25 25)
if ($sync -ne '0x25') { throw "Coverage failure: sync load at cycle 25 did not show the FF shift register, got $sync" }
# WNDW_N=1 load at cycle 100 -> FF -> VIDEO all 0 (next load 125 is blocked by CLK_7M).
$ff = Get-RlePattern (Get-Pattern 100 28)
if ($ff -ne '0x28') { throw "Coverage failure: WNDW_N=1 load at cycle 100 did not show FF on VIDEO, got $ff" }
# ioctl readback: last write (cycle 513) stored 0x03 at ROM[0x234]; the load
# at cycle 750 walks it out: not(b0..b1) = 0,0 (750-751), not(b2..b7) = 1
# (752-755), 14-cycle hold (756-769), wrap not(b0..b2) = 0,0,1 (772-774).
$rb = Get-RlePattern (Get-Pattern 750 25)
if ($rb -ne '0x2,1x20,0x2,1x1') { throw "Coverage failure: ioctl readback at 0x234 wrong, expected 0x2,1x20,0x2,1x1 (byte 0x03), got $rb" }
# ROMSWITCH half 1: load at 800 reads ROM[0x118] = 0x38 = 00111000.
# not(b0..b11) = 1,1,1,0,0,0,1,1,1,1,1,0 (800-811), 14-cycle hold on 0
# (812-825), not(b12..b21) = 0,0,1,1,1,1,1,0,0,0 (826-835).
$h1 = Get-RlePattern (Get-Pattern 800 36)
if ($h1 -ne '1x3,0x3,1x5,0x17,1x5,0x3') { throw "Coverage failure: ROMSWITCH=0 read of 0x118 wrong, expected 1x3,0x3,1x5,0x17,1x5,0x3 (byte 0x38), got $h1" }
# ROMSWITCH half 2: load at 950 reads ROM[0x1118] = 0x14 = 00010100.
# not(b0..b1) = 1,1 (950-951), 14-cycle hold on 1 (952-965), not(b2..b10) =
# 0,1,0,1,1,1,1,1,0 (966-974). Window ends before the reload at 975.
$h2 = Get-RlePattern (Get-Pattern 950 25)
if ($h2 -ne '1x16,0x1,1x1,0x1,1x5,0x1') { throw "Coverage failure: ROMSWITCH=1 read of 0x1118 wrong, expected 1x16,0x1,1x1,0x1,1x5,0x1 (byte 0x14), got $h2" }

# General ROM-data loads: a load at 25k (k=1..40) walks its ROM byte out over
# the next 22 cycles (holds repeat a bit, never skip one). Count blocks whose
# walkout is non-constant (the loaded byte was neither 0x00 nor 0xFF).
$specialLoads = @(25, 100, 125, 750, 775, 800, 825, 850, 875, 900, 925, 950, 975)
$mixedBlocks = 0
$generalBlocks = 0
for ($k = 1; $k -le 40; $k++) {
    $start = 25 * $k
    if ($specialLoads -contains $start) { continue }
    $generalBlocks++
    $pattern = Get-Pattern $start 22
    if ($pattern.Contains('0') -and $pattern.Contains('1')) { $mixedBlocks++ }
}
if ($mixedBlocks -lt 20) { throw "Coverage failure: only $mixedBlocks/$generalBlocks general ROM-data load blocks showed non-constant walkouts (need >= 20)" }

if ($videoTransitions -lt 100) { throw "Coverage failure: only $videoTransitions VIDEO transitions observed" }
if ($comparedFields -lt 4000) { throw "Coverage failure: only $comparedFields initialized fields compared" }

Write-Output "VIDEO_GENERATOR EQUIVALENCE PASS rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues sync_ff=1 wndw_ff_load=1 ioctl_readback=1 romswitch_halves=1 mixed_rom_loads=$mixedBlocks/$generalBlocks video_transitions=$videoTransitions"
