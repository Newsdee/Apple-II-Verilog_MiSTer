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
$verilatorAggregate = Join-Path $verilogBuild 'Vdisk_ii_verilog_tb__ALL.cpp'
if ((Test-Path $verilatorAggregate) -and (Get-Item $verilatorAggregate).Length -eq 0) {
    Remove-Item -Force $verilatorAggregate
}

if (!$CompareOnly) {
    $vhdlSources = @(
        (Join-Path $referenceRoot 'rtl\disk_ii_rom.vhd'),
        (Join-Path $referenceRoot 'rtl\drive_ii.vhd'),
        (Join-Path $referenceRoot 'rtl\disk_ii.vhd'),
        (Join-Path $PSScriptRoot 'disk_ii_vhdl_tb.vhd')
    )

    & $ghdl -a --std=08 "--workdir=$vhdlBuild" $vhdlSources
    if ($LASTEXITCODE -ne 0) { throw "GHDL analysis failed with exit code $LASTEXITCODE" }
    & $ghdl -e --std=08 "--workdir=$vhdlBuild" disk_ii_vhdl_tb
    if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration failed with exit code $LASTEXITCODE" }

    $verilogSources = @(
        (Join-Path $PSScriptRoot 'disk_ii_verilog_tb.sv'),
        (Join-Path $projectRoot 'rtl\disk_ii.v'),
        (Join-Path $projectRoot 'rtl\drive_ii.v'),
        (Join-Path $projectRoot 'rtl\rom.v')
    )
    & $verilator --binary --timing -Wno-fatal --top-module disk_ii_verilog_tb --Mdir 'module_tests/disk_ii/build/verilog' $verilogSources
    if ($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

    Push-Location $projectRoot
    try {
        & $ghdl -r --std=08 "--workdir=$vhdlBuild" disk_ii_vhdl_tb
        if ($LASTEXITCODE -ne 0) { throw "VHDL simulation failed with exit code $LASTEXITCODE" }
        & (Join-Path $verilogBuild 'Vdisk_ii_verilog_tb.exe')
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

$columns = @('D_OUT', 'FLAGS', 'TRACK1', 'TRACK1_ADDR', 'TRACK1_DI', 'TRACK2', 'TRACK2_ADDR', 'TRACK2_DI')
$comparedFields = 0
$ignoredMetavalues = 0
$observedFlags = 0
$track1ZeroObserved = $false
$track2ZeroObserved = $false
$track1AddressAdvanced = $false
$track2AddressAdvanced = $false
$spindownObserved = $false
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

    if ($vhdlRow.FLAGS -notmatch '[UXWZ-]') {
        $flagsValue = [Convert]::ToInt32($vhdlRow.FLAGS, 16)
        $observedFlags = $observedFlags -bor $flagsValue
        if ([int]$vhdlRow.CYCLE -ge 14004110 -and ($flagsValue -band 0xC00) -eq 0) {
            $spindownObserved = $true
        }
    }
    if ($vhdlRow.TRACK1 -eq '00') { $track1ZeroObserved = $true }
    if ($vhdlRow.TRACK2 -eq '00') { $track2ZeroObserved = $true }
    if ($vhdlRow.TRACK1_ADDR -notin @('0000', 'XXXX')) { $track1AddressAdvanced = $true }
    if ($vhdlRow.TRACK2_ADDR -notin @('0000', 'XXXX')) { $track2AddressAdvanced = $true }
}

$writeProtectObserved = @($vhdlRows | Where-Object { $_.D_OUT -eq '80' }).Count
if ($writeProtectObserved -eq 0) { throw 'Coverage failure: write-protect value 0x80 was never observed' }
$missingFlags = 0xFFF -band (-bnot $observedFlags)
if ($missingFlags -ne 0) { throw ('Coverage failure: status flags 0x{0:X3} were never asserted' -f $missingFlags) }
if (!$track1ZeroObserved -or !$track2ZeroObserved) { throw 'Coverage failure: both heads did not reach track zero' }
if (!$track1AddressAdvanced -or !$track2AddressAdvanced) { throw 'Coverage failure: both media addresses did not advance' }
if (!$spindownObserved) { throw 'Coverage failure: one-second motor spindown was not observed' }
if ($comparedFields -lt 40000) { throw "Coverage failure: only $comparedFields initialized fields compared" }

Write-Output "DISK II EQUIVALENCE PASS rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues flags=0x$($observedFlags.ToString('X3')) write_protect_samples=$writeProtectObserved"
