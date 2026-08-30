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
$verilatorAggregate = Join-Path $verilogBuild 'Vt65_verilog_tb__ALL.cpp'
if ((Test-Path $verilatorAggregate) -and (Get-Item $verilatorAggregate).Length -eq 0) {
    Remove-Item -Force $verilatorAggregate
}

# Trace schema: CYCLE,PC,SP,P,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N (PC is full 16-bit).
$columns = @('PC', 'SP', 'P', 'Y', 'X', 'A', 'ADDR', 'DI', 'DO', 'RW', 'NMI_N', 'IRQ_N')

function Invoke-PhaseCompare {
    param([string]$Name, [string]$VhdlCsv, [string]$VerilogCsv, [int]$ExpectedRows)

    if (!(Test-Path $VhdlCsv)) { throw "missing VHDL trace: $VhdlCsv" }
    if (!(Test-Path $VerilogCsv)) { throw "missing Verilog trace: $VerilogCsv" }
    $vhdlRows = @(Import-Csv $VhdlCsv)
    $verilogRows = @(Import-Csv $VerilogCsv)
    if ($vhdlRows.Count -ne $verilogRows.Count) {
        throw "$Name trace length mismatch: VHDL=$($vhdlRows.Count), Verilog=$($verilogRows.Count)"
    }
    if ($vhdlRows.Count -ne $ExpectedRows) {
        throw "$Name row count $($vhdlRows.Count) != expected $ExpectedRows (simulation truncated?)"
    }

    # Row-level metavalue skip. The golden T65 resets only P (T65.vhd register
    # process); ABC/X/Y have no reset, so in VHDL simulation they start 'UUUU'
    # until the first LDA/LDX/LDY executes, while Verilator starts them at 0.
    # Bus outputs derived from them (ADDR via BAL<=BAL+BusA(X), DI via the TB
    # read mux) are then 'U' or defined-but-garbage. This is a simulation-only
    # power-on artifact (FPGA registers power up 0 on both sides), so rows whose
    # golden state is partially undefined are skipped whole and counted; every
    # fully-defined row is compared strictly, field by field.
    $compared = 0
    $ignoredRows = 0
    $first = $null
    for ($i = 1; $i -lt $vhdlRows.Count; $i++) {
        $vr = $vhdlRows[$i]
        $rr = $verilogRows[$i]
        if ([string]$vr.CYCLE -ne [string]$rr.CYCLE) {
            throw "$Name cycle mismatch at row ${i}: VHDL=$($vr.CYCLE), Verilog=$($rr.CYCLE)"
        }
        $rowHasMeta = $false
        foreach ($col in $columns) {
            if ([string]$vr.$col -match '[UXWZ-]') { $rowHasMeta = $true; break }
        }
        if ($rowHasMeta) { $ignoredRows++; continue }
        foreach ($col in $columns) {
            $expected = [string]$vr.$col
            $actual = [string]$rr.$col
            $compared++
            if ($expected.ToUpperInvariant() -ne $actual.ToUpperInvariant()) {
                if (-not $first) {
                    $first = [pscustomobject]@{ Row = $i; Cycle = $vr.CYCLE; Column = $col; Vhdl = $expected; Verilog = $actual }
                }
            }
        }
    }

    $result = [pscustomobject]@{
        Name = $Name; Rows = $vhdlRows.Count; Compared = $compared; Ignored = $ignoredRows; First = $first
        VhdlRows = $vhdlRows; VerilogRows = $verilogRows
    }

    if ($first) {
        Write-Host "$Name DIVERGENCE first=cycle $($first.Cycle) $($first.Column): VHDL=$($first.Vhdl) Verilog=$($first.Verilog)"
        $lo = [Math]::Max(1, $first.Row - 5)
        $hi = [Math]::Min($vhdlRows.Count - 1, $first.Row + 3)
        Write-Host "  context (cycle | PC SP P | ADDR DI RW):"
        for ($i = $lo; $i -le $hi; $i++) {
            $vr = $vhdlRows[$i]; $rr = $verilogRows[$i]
            $mark = if ($i -eq $first.Row) { '>>>' } else { '   ' }
            $v = "$($vr.PC) $($vr.SP) $($vr.P) | $($vr.ADDR) $($vr.DI) $($vr.RW)"
            $r = "$($rr.PC) $($rr.SP) $($rr.P) | $($rr.ADDR) $($rr.DI) $($rr.RW)"
            $flag = if ($v -ne $r) { '  <-- differs' } else { '' }
            Write-Host ("  {0} {1,-5} {2}{3}" -f $mark, $vr.CYCLE, $v, $flag)
        }
        if ($first.Column -eq 'ADDR' -and $first.Vhdl[0..1] -eq '01' -and $first.Verilog[0..1] -eq '01') {
            $dv = [convert]::ToUInt16($first.Vhdl, 16) - [convert]::ToUInt16($first.Verilog, 16)
            if ($dv -eq 1) {
                Write-Host "  signature: stack-region address off by exactly 1 (VHDL higher) -- stack pointer off-by-one,"
                Write-Host "  matching the apple2 full-core finding at cycle 358 (ADDR 01FB vs 01FE)."
            }
        }
        if ($first.Column -eq 'SP' -and [int]$first.Cycle -le 10) {
            Write-Host "  signature: stack pointer differs during the reset sequence -- golden T65.vhd line ~418 allows"
            Write-Host "  Dec_S while RstCycle=1 in Mode='00' (S walks 00->FF->FE->FD); candidate t65.v line ~550 drops"
            Write-Host "  the 'or Mode == \"00\"' clause, so S stays 00. See README.md 'Known divergence'."
        }
    }
    return $result
}

if (!$CompareOnly) {
    # Golden ROM constant must come from the same hex file the Verilog side
    # $readmemh's, so regenerate it every full run.
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'gen_rom_array.ps1')
    if ($LASTEXITCODE -ne 0) { throw "ROM array generation failed" }

    $vhdlSources = @(
        (Join-Path $buildRoot 't65_rom_array.vhd'),
        (Join-Path $referenceRoot 'rtl\t65\T65_Pack.vhd'),
        (Join-Path $referenceRoot 'rtl\t65\T65_MCode.vhd'),
        (Join-Path $referenceRoot 'rtl\t65\T65_ALU.vhd'),
        (Join-Path $referenceRoot 'rtl\t65\T65.vhd'),
        (Join-Path $PSScriptRoot 't65_vhdl_tb.vhd'),
        (Join-Path $PSScriptRoot 't65_vhdl_wrappers.vhd')
    )

    Push-Location $projectRoot
    try {
        # -fsynopsys: T65_MCode.vhd uses ieee.std_logic_unsigned (Synopsys package).
        & $ghdl -a --std=08 -fsynopsys "--workdir=$vhdlBuild" $vhdlSources
        if ($LASTEXITCODE -ne 0) { throw "GHDL analysis failed with exit code $LASTEXITCODE" }

        $verilogSources = @(
            (Join-Path $PSScriptRoot 't65_verilog_tb.sv'),
            (Join-Path $projectRoot 'rtl\t65\t65_pack.v'),
            (Join-Path $projectRoot 'rtl\t65\t65_mcode.v'),
            (Join-Path $projectRoot 'rtl\t65\t65_alu.v'),
            (Join-Path $projectRoot 'rtl\t65\t65.v')
        )
        & $verilator --binary --timing -Wno-fatal --top-module t65_verilog_tb --Mdir 'module_tests/t65/build/verilog' $verilogSources
        if ($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

        $exe = Join-Path $verilogBuild 'Vt65_verilog_tb.exe'

        # Phase A: directed program (320 cycles). Last sample lands at 3201 ns.
        & $ghdl -e --std=08 -fsynopsys "--workdir=$vhdlBuild" t65_vhdl_tb_prog
        if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration (prog) failed with exit code $LASTEXITCODE" }
        & $ghdl -r --std=08 -fsynopsys "--workdir=$vhdlBuild" t65_vhdl_tb_prog --stop-time=5000ns
        if ($LASTEXITCODE -ne 0) { throw "VHDL simulation (prog) failed with exit code $LASTEXITCODE" }
        & $exe +PHASE=0
        if ($LASTEXITCODE -ne 0) { throw "Verilog simulation (prog) failed with exit code $LASTEXITCODE" }

        # Phase B: full-core boot environment (500 cycles). Last sample at 5001 ns.
        & $ghdl -e --std=08 -fsynopsys "--workdir=$vhdlBuild" t65_vhdl_tb_boot
        if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration (boot) failed with exit code $LASTEXITCODE" }
        & $ghdl -r --std=08 -fsynopsys "--workdir=$vhdlBuild" t65_vhdl_tb_boot --stop-time=7000ns
        if ($LASTEXITCODE -ne 0) { throw "VHDL simulation (boot) failed with exit code $LASTEXITCODE" }
        & $exe +PHASE=1
        if ($LASTEXITCODE -ne 0) { throw "Verilog simulation (boot) failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

$prog = Invoke-PhaseCompare -Name 'A(prog)' `
    -VhdlCsv (Join-Path $buildRoot 'vhdl_prog.csv') `
    -VerilogCsv (Join-Path $buildRoot 'verilog_prog.csv') `
    -ExpectedRows 320
$boot = Invoke-PhaseCompare -Name 'B(boot)' `
    -VhdlCsv (Join-Path $buildRoot 'vhdl_boot.csv') `
    -VerilogCsv (Join-Path $buildRoot 'verilog_boot.csv') `
    -ExpectedRows 500

# Coverage gates (evaluated on the VHDL reference rows).
$gates = 0
function Check-Gate {
    param([scriptblock]$Condition, [string]$What)
    if (& $Condition) { $script:gates++ }
    else { throw "coverage gate failure: $What" }
}

$rowsA = $prog.VhdlRows
Check-Gate { (@($rowsA | Where-Object { $_.PC -eq '0546' }).Count) -gt 0 } 'park at $0546 never reached in phase A (program did not complete)'
# Apple II vector convention (as implemented by T65): IRQ at $FFFE/$FFFF,
# NMI at $FFFA/$FFFB, reset at $FFFC/$FFFD.
Check-Gate { (@($rowsA | Where-Object { [int]$_.CYCLE -ge 120 -and ($_.ADDR -eq 'FFFE' -or $_.ADDR -eq 'FFFF') }).Count) -gt 0 } 'IRQ vector fetch at $FFFE/$FFFF never observed in phase A'
Check-Gate { (@($rowsA | Where-Object { [int]$_.CYCLE -ge 200 -and ($_.ADDR -eq 'FFFA' -or $_.ADDR -eq 'FFFB') }).Count) -gt 0 } 'NMI vector fetch at $FFFA/$FFFB never observed in phase A'
Check-Gate { (@($rowsA | Where-Object { $_.RW -eq '0' }).Count) -ge 10 } 'fewer than 10 write cycles observed in phase A'
Check-Gate { ($rowsA.PC | Select-Object -Unique).Count -ge 20 } 'fewer than 20 distinct PC values observed in phase A'
# Flag results (P bits: C=0,Z=1,I=2,D=3,B=4,V=6,N=7). SBC #$07 with A=$05 gives
# A=$FD N=1; ADC #$03 with C=0 gives A=$00 Z=1 C=1. Check the bits, not the
# whole byte, so I/D/B state does not matter.
Check-Gate { (@($rowsA | Where-Object { $_.A -eq 'FD' -and ([int]('0x' + $_.P) -band 0x80) -ne 0 }).Count) -gt 0 } 'SBC result (A=$FD with N set) never observed in phase A'
Check-Gate { (@($rowsA | Where-Object { $_.A -eq '00' -and (([int]('0x' + $_.P) -band 0x03) -eq 3) }).Count) -gt 0 } 'ADC result (A=$00 with Z and C set) never observed in phase A'
Check-Gate { (@($rowsA | Where-Object { [int]$_.CYCLE -ge 95 -and $_.SP -eq 'FD' }).Count) -gt 0 } 'stack pointer never returned to $FD after JSR/RTS + PHA/PLA in phase A'
Check-Gate { ($rowsA.P | Select-Object -Unique).Count -ge 4 } 'fewer than 4 distinct P values observed in phase A (flag coverage too thin)'

# Phase B is the standalone reproduction of the full-core finding environment:
# reset vector $6B4C points into main RAM, so both CPUs execute the
# deterministic pattern bytes as code. The walk is not identical to the
# full-core one (that core has real soft-switch/IO behavior), but it drives
# the same S/stack machinery hard -- which is where the known full-core
# divergence lives. Gates anchor on the walk's shape, not full-core addresses.
$rowsB = $boot.VhdlRows
Check-Gate { (@($rowsB | Where-Object { $_.PC -eq '6B4C' }).Count) -gt 0 } 'boot walk never started at reset vector target $6B4C in phase B'
$distinctB = @($rowsB | Select-Object -ExpandProperty ADDR -Unique).Count
Check-Gate { $distinctB -ge 100 } "only $distinctB distinct addresses observed in phase B (walk too short or stuck)"
$stackRowsB = @($rowsB | Where-Object { $_.ADDR -match '^01[0-9A-F][0-9A-F]$' }).Count
Check-Gate { $stackRowsB -ge 5 } "only $stackRowsB stack-page ($01xx) accesses observed in phase B (S machinery not exercised)"
Check-Gate { (@($rowsB | Where-Object { $_.RW -eq '0' }).Count) -ge 20 } 'fewer than 20 write cycles observed in phase B'
$spValsB = @($rowsB | Select-Object -ExpandProperty SP -Unique).Count
Check-Gate { $spValsB -ge 3 } "only $spValsB distinct stack-pointer values observed in phase B (stack not exercised)"
$totalIgnored = $prog.Ignored + $boot.Ignored
Check-Gate { $totalIgnored -lt 400 } "metavalue rows too numerous: $totalIgnored (registers likely never initialized -- walk not reaching load instructions?)"
# Enough fully-defined rows must be strictly compared in each phase so the
# metavalue skip cannot create an empty pass (measured: 256/320 and 416/500).
Check-Gate { $prog.Compared -ge 3000 } "phase A compared only $($prog.Compared) fields (expected >= 3000)"
Check-Gate { $boot.Compared -ge 4800 } "phase B compared only $($boot.Compared) fields (expected >= 4800)"

if ($prog.First) { throw 'phase A (directed program) diverged -- see context above' }
if ($boot.First) {
    Write-Output "T65 DIVERGENCE phase=B(boot) first=cycle $($boot.First.Cycle) $($boot.First.Column): VHDL=$($boot.First.Vhdl) Verilog=$($boot.First.Verilog) | phaseA=match rowsA=$($prog.Rows) fieldsA=$($prog.Compared) ignored=$totalIgnored gate_checks=$gates"
    exit 1
}
Write-Output "T65 EQUIVALENCE PASS rowsA=$($prog.Rows) rowsB=$($boot.Rows) fieldsA=$($prog.Compared) fieldsB=$($boot.Compared) ignored_metavalues=$totalIgnored gate_checks=$gates"
exit 0
