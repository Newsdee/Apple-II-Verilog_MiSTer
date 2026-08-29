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
$verilatorAggregate = Join-Path $verilogBuild 'Vapple2_verilog_tb__ALL.cpp'
if ((Test-Path $verilatorAggregate) -and (Get-Item $verilatorAggregate).Length -eq 0) {
    Remove-Item -Force $verilatorAggregate
}

if (!$CompareOnly) {
    # Golden side: reference VHDL core + test-side shims.
    #   spram_const.vhd           -> work.spram (GHDL-safe constant ROM, shared shim)
    #   ramcard_stub.vhd          -> work.ramcard (reference ships Verilog only)
    #   timing_generator_init.vhd -> work.timing_generator (init-only reset shim;
    #                                 original has no reset and cannot self-start in GHDL)
    #   video_generator_ent.vhd   -> one-word copy of reference video_generator.vhd
    #                                 ('videorom : entity work.spram'; Quartus accepts the
    #                                 keyword-less form, GHDL requires it)
    #   apple2_ent.vhd            -> one-word copy of reference apple2.vhd
    #                                 ('roms : entity work.spram', same reason)
    #   R65C02_ent.vhd            -> copy of reference R65Cx2.vhd with the 256
    #                                 opcodeInfoTable rows resolved to explicit
    #                                 unsigned'("<44 bits>") literals (mixed string/
    #                                 unsigned &-chains are rejected by GHDL); each
    #                                 row is bit-identical, independently verified.
    #                                 Created by make_R65C02_ent.ps1 (kept for audit).
    $vhdlSources = @(
        (Join-Path $PSScriptRoot '..\shared\spram_const.vhd'),
        (Join-Path $PSScriptRoot 'ramcard_stub.vhd'),
        (Join-Path $PSScriptRoot 'timing_generator_init.vhd'),
        (Join-Path $PSScriptRoot 'video_generator_ent.vhd'),
        (Join-Path $referenceRoot 'rtl\t65\T65_Pack.vhd'),
        (Join-Path $referenceRoot 'rtl\t65\T65_MCode.vhd'),
        (Join-Path $referenceRoot 'rtl\t65\T65_ALU.vhd'),
        (Join-Path $referenceRoot 'rtl\t65\T65.vhd'),
        (Join-Path $PSScriptRoot 'R65C02_ent.vhd'),
        (Join-Path $PSScriptRoot 'apple2_ent.vhd'),
        (Join-Path $PSScriptRoot 'apple2_vhdl_tb.vhd')
    )

    Push-Location $projectRoot
    try {
        # -fsynopsys: T65_MCode.vhd uses ieee.std_logic_unsigned (Synopsys package).
        & $ghdl -a --std=08 -fsynopsys "--workdir=$vhdlBuild" $vhdlSources
        if ($LASTEXITCODE -ne 0) { throw "GHDL analysis failed with exit code $LASTEXITCODE" }
        & $ghdl -e --std=08 -fsynopsys "--workdir=$vhdlBuild" apple2_vhdl_tb
        if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration failed with exit code $LASTEXITCODE" }

        # Candidate side: this repository's Verilog core.
        $verilogSources = @(
            (Join-Path $PSScriptRoot 'apple2_verilog_tb.sv'),
            (Join-Path $projectRoot 'rtl\apple2.v'),
            (Join-Path $projectRoot 'rtl\t65\t65_pack.v'),
            (Join-Path $projectRoot 'rtl\t65\t65_mcode.v'),
            (Join-Path $projectRoot 'rtl\t65\t65_alu.v'),
            (Join-Path $projectRoot 'rtl\t65\t65.v'),
            (Join-Path $projectRoot 'rtl\R65Cx2.sv'),
            (Join-Path $projectRoot 'rtl\timing_generator.v'),
            (Join-Path $projectRoot 'rtl\video_generator.v'),
            (Join-Path $projectRoot 'rtl\rom.v'),
            (Join-Path $projectRoot 'rtl\ramcard.v')
        )
        & $verilator --binary --timing -Wno-fatal --top-module apple2_verilog_tb --Mdir 'module_tests/apple2/build/verilog' $verilogSources
        if ($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

        # Both simulations run from the project root so relative ROM paths
        # ("rtl/roms/*.hex|*mif") resolve on both sides.
        & $ghdl -r --std=08 -fsynopsys "--workdir=$vhdlBuild" apple2_vhdl_tb
        if ($LASTEXITCODE -ne 0) { throw "VHDL simulation failed with exit code $LASTEXITCODE" }
        & (Join-Path $verilogBuild 'Vapple2_verilog_tb.exe')
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

$columns = @('ADDR', 'D', 'RAM_ADDR', 'RAM_WE', 'AUX', 'CPU_WE', 'PD', 'IO_SELECT',
             'DEVICE_SELECT', 'IO_STROBE', 'SPEAKER', 'VIDEO', 'PHASE_ZERO',
             'PHASE_ZERO_R', 'PHASE_ZERO_F', 'ROMSWITCH', 'PALMODE', 'CPU_WAIT', 'NMI_N')
$comparedFields = 0
$ignoredMetavalues = 0
$parkReached = $false
$errorParkReached = $false
$auxRamWriteObserved = $false
$ioStrobeObserved = $false
$slotSelectObserved = $false
$nmiExecuted = $false
$romswitch0VideoHigh = $false
$romswitch0VideoLow = $false
$romswitch1VideoHigh = $false
$romswitch1VideoLow = $false
$palmodeAlwaysZero = $true
$waitAddrSeen = @{}
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

    $cycle = [int]$vhdlRow.CYCLE
    if ($vhdlRow.ADDR -eq '0580') { $parkReached = $true }
    if ($vhdlRow.ADDR -eq '05A0') { $errorParkReached = $true }
    if ($vhdlRow.AUX -eq '1' -and $vhdlRow.RAM_WE -eq '1') { $auxRamWriteObserved = $true }
    if ($vhdlRow.IO_STROBE -eq '1') { $ioStrobeObserved = $true }
    if ($vhdlRow.IO_SELECT -ne '00') { $slotSelectObserved = $true }
    if ($vhdlRow.ADDR -eq 'C3FA') { $nmiExecuted = $true }
    if ($vhdlRow.ROMSWITCH -eq '0') {
        if ($vhdlRow.VIDEO -eq '1') { $romswitch0VideoHigh = $true }
        if ($vhdlRow.VIDEO -eq '0') { $romswitch0VideoLow = $true }
    } else {
        if ($vhdlRow.VIDEO -eq '1') { $romswitch1VideoHigh = $true }
        if ($vhdlRow.VIDEO -eq '0') { $romswitch1VideoLow = $true }
    }
    if ($vhdlRow.PALMODE -ne '0') { $palmodeAlwaysZero = $false }
    if ($cycle -ge 2600 -and $cycle -lt 2615) { $waitAddrSeen[$vhdlRow.ADDR] = $true }
}

if (!$parkReached) { throw 'Coverage failure: normal park at $0580 was never reached (program did not complete)' }
if ($errorParkReached) { throw 'Coverage failure: error park at $05A0 was reached (softswitch readback failed)' }
if (!$auxRamWriteObserved) { throw 'Coverage failure: no write to auxiliary RAM was observed (PAGE2/STORE80 path unexercised)' }
if (!$ioStrobeObserved -or !$slotSelectObserved) { throw 'Coverage failure: IO_STROBE and non-zero IO_SELECT were not both observed' }
if (!$nmiExecuted) { throw 'Coverage failure: NMI vector fetch at $C3FA was never observed' }
if ($waitAddrSeen.Count -ne 1) { throw "Coverage failure: CPU address changed during CPU_WAIT window (distinct values=$($waitAddrSeen.Count))" }
if (!$romswitch0VideoHigh -or !$romswitch0VideoLow) { throw 'Coverage failure: VIDEO did not toggle both ways with ROMSWITCH=0' }
if (!$romswitch1VideoHigh -or !$romswitch1VideoLow) { throw 'Coverage failure: VIDEO did not toggle both ways with ROMSWITCH=1' }
if (!$palmodeAlwaysZero) { throw 'Coverage failure: PALMODE was driven non-zero' }
if ($comparedFields -lt 50000) { throw "Coverage failure: only $comparedFields initialized fields compared" }

Write-Output "APPLE2 EQUIVALENCE PASS rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues park=$($waitAddrSeen.Keys[0]) aux_write=1 io_strobe=1 nmi=1 romswitch_01=1 palmode_0=1"
