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
$verilatorAggregate = Join-Path $verilogBuild 'Vkeyboard_verilog_tb__ALL.cpp'
if ((Test-Path $verilatorAggregate) -and (Get-Item $verilatorAggregate).Length -eq 0) {
    Remove-Item -Force $verilatorAggregate
}

if (!$CompareOnly) {
    # Golden side: analyze the GHDL-safe constant-array spram shim INSTEAD of
    # rtl/spram.vhd (GHDL 6.0.0 does not honor ram_init_file and has a codegen
    # bug with case-based function calls in loops). The shim selects the
    # keyboard.mif segment via the init_file generic.
    #
    # GHDL 6.0.0 also rejects the LRM-legal shorthand entity instantiation
    # 'keyboard_rom : work.spram' in rtl/keyboard.vhd ("component name
    # expected, found entity"); Quartus accepts it. The golden RTL is left
    # untouched: a parse-normalized copy is generated under build/ that adds
    # the explicit 'entity' keyword only (a semantic no-op), with strict
    # verification that nothing else changed.
    $goldenSrc = Join-Path $referenceRoot 'rtl\keyboard.vhd'
    $goldenCopy = Join-Path $vhdlBuild 'keyboard_golden.vhd'
    $srcBytes = [System.IO.File]::ReadAllBytes($goldenSrc)
    $hasBom = ($srcBytes.Length -ge 3 -and $srcBytes[0] -eq 0xEF -and $srcBytes[1] -eq 0xBB -and $srcBytes[2] -eq 0xBF)
    $srcText = [System.IO.File]::ReadAllText($goldenSrc, [System.Text.Encoding]::UTF8)
    $needle = 'keyboard_rom : work.spram'
    $replacement = 'keyboard_rom : entity work.spram'
    if (([regex]::Matches($srcText, [regex]::Escape($needle))).Count -ne 1) {
        throw "Golden normalization failed: expected exactly 1 occurrence of '$needle' in keyboard.vhd"
    }
    $dstText = $srcText.Replace($needle, $replacement)
    if ($dstText.Length -ne $srcText.Length + ($replacement.Length - $needle.Length)) {
        throw 'Golden normalization failed: unexpected text length change'
    }
    [System.IO.File]::WriteAllText($goldenCopy, $dstText, (New-Object System.Text.UTF8Encoding($hasBom)))

    $vhdlSources = @(
        (Join-Path $PSScriptRoot '..\shared\spram_const.vhd'),
        $goldenCopy,
        (Join-Path $PSScriptRoot 'keyboard_vhdl_tb.vhd')
    )

    & $ghdl -a --std=08 "--workdir=$vhdlBuild" $vhdlSources
    if ($LASTEXITCODE -ne 0) { throw "GHDL analysis failed with exit code $LASTEXITCODE" }
    & $ghdl -e --std=08 "--workdir=$vhdlBuild" keyboard_vhdl_tb
    if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration failed with exit code $LASTEXITCODE" }

    # Candidate side: rtl/keyboard.v unconditionally instantiates the rom
    # helper with rtl/roms/keyboard.hex (the spram/mif branch is commented
    # out), so Verilator compiles the rom + keyboard.hex path.
    $verilogSources = @(
        (Join-Path $PSScriptRoot 'keyboard_verilog_tb.sv'),
        (Join-Path $projectRoot 'rtl\keyboard.v'),
        (Join-Path $projectRoot 'rtl\rom.v')
    )
    & $verilator --binary --timing -Wno-fatal --top-module keyboard_verilog_tb --Mdir 'module_tests/keyboard/build/verilog' $verilogSources
    if ($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

    Push-Location $projectRoot
    try {
        & $ghdl -r --std=08 "--workdir=$vhdlBuild" keyboard_vhdl_tb
        if ($LASTEXITCODE -ne 0) { throw "VHDL simulation failed with exit code $LASTEXITCODE" }
        & (Join-Path $verilogBuild 'Vkeyboard_verilog_tb.exe')
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

$columns = @('K', 'READ_KEY', 'AKD', 'OPEN_APPLE', 'CLOSED_APPLE', 'SOFT_RESET', 'VIDEO_TOGGLE', 'PALETTE_TOGGLE')
$comparedFields = 0
$ignoredMetavalues = 0
$softResetPulse = $false; $softResetHigh = $false
$videoTogglePulse = $false; $videoToggleHigh = $false
$paletteTogglePulse = $false; $paletteToggleHigh = $false
$makeObserved = $false
$firstMakeCycle = -1
$akdHighSeen = $false
$breakObserved = $false
$prevAkd = ''
$extendedKeyObserved = $false
$caplockKeyObserved = $false
$virtualKeyObserved = $false
$openAppleObserved = $false
$closedAppleObserved = $false
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

    if ($vhdlRow.K -notmatch '[UXWZ-]') {
        $kValue = [Convert]::ToInt32($vhdlRow.K, 16)
        if (($kValue -band 0x80) -ne 0) {
            $makeObserved = $true
            if ($firstMakeCycle -lt 0) { $firstMakeCycle = [int]$vhdlRow.CYCLE }
        }
        if ($vhdlRow.K -eq '8B') { $extendedKeyObserved = $true }
        if ($vhdlRow.K -eq 'E1') { $caplockKeyObserved = $true }
        if ($vhdlRow.K -eq 'AA') { $virtualKeyObserved = $true }
    }
    if ($vhdlRow.AKD -eq '1') { $akdHighSeen = $true }
    # AKD 1->0 after the first make proves the key-up path (GOT_KEY_UP_CODE)
    # executed. In this DUT the strobe falling edge also drives a key-up of
    # whatever code is on the bus; explicit break bytes additionally clear
    # modifiers/toggles/caplock at KEY_UP, covered by the other gates.
    if (($prevAkd -eq '1') -and ($vhdlRow.AKD -eq '0') -and ([int]$vhdlRow.CYCLE -gt $firstMakeCycle)) {
        $breakObserved = $true
    }
    $prevAkd = $vhdlRow.AKD
    if ($vhdlRow.OPEN_APPLE -eq '1') { $openAppleObserved = $true }
    if ($vhdlRow.CLOSED_APPLE -eq '1') { $closedAppleObserved = $true }
    if ($vhdlRow.SOFT_RESET -eq '1') {
        $softResetHigh = $true
    } elseif ($vhdlRow.SOFT_RESET -eq '0' -and $softResetHigh) {
        $softResetPulse = $true
    }
    if ($vhdlRow.VIDEO_TOGGLE -eq '1') {
        $videoToggleHigh = $true
    } elseif ($vhdlRow.VIDEO_TOGGLE -eq '0' -and $videoToggleHigh) {
        $videoTogglePulse = $true
    }
    if ($vhdlRow.PALETTE_TOGGLE -eq '1') {
        $paletteToggleHigh = $true
    } elseif ($vhdlRow.PALETTE_TOGGLE -eq '0' -and $paletteToggleHigh) {
        $paletteTogglePulse = $true
    }
}

if (!$softResetPulse) { throw 'Coverage failure: soft_reset pulse (F2 make then break) was not observed' }
if (!$videoTogglePulse) { throw 'Coverage failure: video_toggle pulse (F9 make then break) was not observed' }
if (!$paletteTogglePulse) { throw 'Coverage failure: palette_toggle pulse (F8 make then break) was not observed' }
if (!$makeObserved -or !$akdHighSeen) { throw 'Coverage failure: no full key make was observed (K bit7 / AKD never high)' }
if (!$breakObserved) { throw 'Coverage failure: no AKD 1->0 key-up transition was observed after the first key make' }
if (!$extendedKeyObserved) { throw 'Coverage failure: extended-key decoded value K=8B (up arrow, ROM[0x10F]) was never observed' }
if (!$caplockKeyObserved) { throw 'Coverage failure: caplock-shifted decoded value K=E1 (A with caplock, ROM[0x253]) was never observed' }
if (!$virtualKeyObserved) { throw 'Coverage failure: virtual-keyboard decoded value K=AA (code 0x2A press) was never observed' }
if (!$openAppleObserved -or !$closedAppleObserved) { throw 'Coverage failure: open/closed apple outputs were not both asserted via virtual keyboard' }
if ($comparedFields -lt 1500) { throw "Coverage failure: only $comparedFields initialized fields compared" }

Write-Output "KEYBOARD EQUIVALENCE PASS rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues soft_reset_pulse=1 video_toggle_pulse=1 palette_toggle_pulse=1 key_make_break=1 extended_key=1 caplock_key=1 virtual_key=1 open_apple=1 closed_apple=1"
