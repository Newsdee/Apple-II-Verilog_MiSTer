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
    # Golden-side GHDL normalization (the copy in build/vhdl is byte-identical
    # except where noted; no logic changed). via6522.vhd uses Quartus-legal but
    # strict-VHDL-illegal case/with-select choices on std_logic_vector:
    #   - case addr is when X"n"          (3 cases, 37 choices)
    #   - case shift_clk_sel / shift_mode_control with "nnn" choices
    #   - with ca2/cb2_out_mode select ... when "nn",
    # All are normalized to to_int_vec(...) subjects (shim package, see
    # via6522_shim.vhd) and integer choices. The copy also gains one use
    # clause: use work.via6522_shim.all;
    $goldenSrc = Join-Path $referenceRoot 'rtl\mockingboard\via6522.vhd'
    $goldenCopy = Join-Path $vhdlBuild 'via6522_golden.vhd'
    $srcBytes = [System.IO.File]::ReadAllBytes($goldenSrc)
    $hasBom = ($srcBytes.Length -ge 3 -and $srcBytes[0] -eq 0xEF -and $srcBytes[1] -eq 0xBB -and $srcBytes[2] -eq 0xBF)
    $srcText = [System.IO.File]::ReadAllText($goldenSrc, [System.Text.Encoding]::UTF8)
    $eol = if ($srcText.Contains("`r`n")) { "`r`n" } else { "`n" }

    # The use-clause insertion must match the file's EOL, so it is applied
    # after $eol is known.
        $needle = 'use ieee.std_logic_unsigned.all;'
    $count = [regex]::Matches($srcText, [regex]::Escape($needle)).Count
    if ($count -ne 1) { throw "golden transform: expected 1 use clause, found $count" }
    $dstText = $srcText.Replace($needle, ($needle + $eol + 'use work.via6522_shim.all;'))

    # (needle, replacement, expected count)
    $replacements = @(
        @('case addr is', 'case to_int_vec(addr) is', 3),
        @('when X"0" =>', 'when 0 =>', 3),
        @('when X"1" =>', 'when 1 =>', 3),
        @('when X"2" =>', 'when 2 =>', 2),
        @('when X"3" =>', 'when 3 =>', 2),
        @('when X"4" =>', 'when 4 =>', 3),
        @('when X"5" =>', 'when 5 =>', 2),
        @('when X"6" =>', 'when 6 =>', 2),
        @('when X"7" =>', 'when 7 =>', 2),
        @('when X"8" =>', 'when 8 =>', 3),
        @('when X"9" =>', 'when 9 =>', 2),
        @('when X"A" =>', 'when 10 =>', 3),
        @('when X"B" =>', 'when 11 =>', 2),
        @('when X"C" =>', 'when 12 =>', 2),
        @('when X"D" =>', 'when 13 =>', 2),
        @('when X"E" =>', 'when 14 =>', 2),
        @('when X"F" =>', 'when 15 =>', 2),
        @('case shift_clk_sel is', 'case to_int_vec(shift_clk_sel) is', 1),
        @('when "10" =>', 'when 2 =>', 1),
        @('when "00"|"01" =>', 'when 0 | 1 =>', 1),
        @('case shift_mode_control is', 'case to_int_vec(shift_mode_control) is', 1),
        @('when "001" | "101" | "100" =>', 'when 1 | 5 | 4 =>', 1),
        @('with ca2_out_mode select', 'with to_int_vec(ca2_out_mode) select', 1),
        @('with cb2_out_mode select', 'with to_int_vec(cb2_out_mode) select', 1),
        @('when "00",', 'when 0,', 2),
        @('when "01",', 'when 1,', 2),
        @('when "10",', 'when 2,', 2)
    )

    foreach ($r in $replacements) {
        $needle = $r[0]
        $count = [regex]::Matches($dstText, [regex]::Escape($needle)).Count
        if ($count -ne $r[2]) {
            throw "golden transform: expected $($r[2]) of '$needle', found $count"
        }
        $dstText = $dstText.Replace($needle, $r[1])
    }
    [System.IO.File]::WriteAllText($goldenCopy, $dstText, (New-Object System.Text.UTF8Encoding($hasBom)))
    Write-Output "GOLDEN COPY OK ($($replacements.Count) normalized constructs, no logic changed)"

    # Stimulus tables (identical for both sides).
    & (Join-Path $PSScriptRoot 'gen_stim.ps1')
    if (-not $?) { throw 'gen_stim.ps1 failed' }

    # -fsynopsys: via6522.vhd uses ieee.std_logic_arith/std_logic_unsigned
    # (Synopsys packages, not in the IEEE set).
    & $ghdl -a --std=08 -fsynopsys "--workdir=$vhdlBuild" `
        (Join-Path $PSScriptRoot 'via6522_shim.vhd') `
        $goldenCopy `
        (Join-Path $buildRoot 'stim_table.vhd') `
        (Join-Path $PSScriptRoot 'via6522_vhdl_tb.vhd')
    if ($LASTEXITCODE -ne 0) { throw "GHDL analysis failed with exit code $LASTEXITCODE" }

    # Elaboration and both simulations run from the project root: the TBs
    # open/write their trace CSV at a project-root-relative path, and GHDL
    # opens the VHDL file object already at elaboration.
    Push-Location $projectRoot
    try {
        & $ghdl -e --std=08 -fsynopsys "--workdir=$vhdlBuild" via6522_vhdl_tb
        if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration failed with exit code $LASTEXITCODE" }

        $vdir = Join-Path $buildRoot 'verilog'
        $aggregate = Join-Path $vdir 'Vvia6522_verilog_tb__ALL.cpp'
        if ((Test-Path $aggregate) -and (Get-Item $aggregate).Length -eq 0) {
            Remove-Item -Force $aggregate
        }
        & $verilator --binary --timing -Wno-fatal --top-module via6522_verilog_tb --Mdir $vdir `
            (Join-Path $buildRoot 'stim_table.sv') `
            (Join-Path $projectRoot 'rtl\mockingboard\via6522.v') `
            (Join-Path $PSScriptRoot 'via6522_verilog_tb.sv')
        if ($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

        # --stop-time is mandatory: the concurrent clock keeps events pending
        # forever after the driver suspends (no std_env in this GHDL build's
        # -fsynopsys ieee library). For 794 cycles the last sample lands at
        # 106 + 70*793 = 55616 ns; keep margin above that.
        & $ghdl -r --std=08 -fsynopsys "--workdir=$vhdlBuild" via6522_vhdl_tb --stop-time=56000ns
        if ($LASTEXITCODE -ne 0) { throw "VHDL simulation failed with exit code $LASTEXITCODE" }
        & (Join-Path $vdir 'Vvia6522_verilog_tb.exe')
        if ($LASTEXITCODE -ne 0) { throw "Verilog simulation failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

# --- compare ------------------------------------------------------------------
$columns = @('RESET', 'STROBE', 'WE', 'ADDR', 'DIN', 'CA1I', 'CA2I', 'CB1I', 'CB2I', 'PAI', 'PBI',
             'DOUT', 'PAO', 'PBO', 'CA2O', 'CB2O', 'CB1O', 'IRQ')

$vhdlRows = @(Import-Csv (Join-Path $buildRoot 'vhdl_trace.csv'))
$verilogRows = @(Import-Csv (Join-Path $buildRoot 'verilog_trace.csv'))
if ($vhdlRows.Count -ne $verilogRows.Count) {
    throw "trace length mismatch: VHDL=$($vhdlRows.Count), Verilog=$($verilogRows.Count)"
}

$comparedFields = 0
$ignoredMetavalues = 0
$mismatches = New-Object System.Collections.Generic.List[object]
$rowsByCycle = @{}
for ($rowIndex = 0; $rowIndex -lt $vhdlRows.Count; $rowIndex++) {
    $vhdlRow = $vhdlRows[$rowIndex]
    $verilogRow = $verilogRows[$rowIndex]
    if ($vhdlRow.CYCLE -ne $verilogRow.CYCLE) {
        throw "cycle mismatch at row ${rowIndex}: VHDL=$($vhdlRow.CYCLE), Verilog=$($verilogRow.CYCLE)"
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
            $mismatches.Add([pscustomobject]@{
                Cycle = [int]$vhdlRow.CYCLE
                Column = $column
                Expected = $expected
                Actual = $actual
                Context = "ADDR=$($vhdlRow.ADDR) WE=$($vhdlRow.WE) STROBE=$($vhdlRow.STROBE) DIN=$($vhdlRow.DIN) CA1I=$($vhdlRow.CA1I) CB1I=$($vhdlRow.CB1I) PAI=$($vhdlRow.PAI) PBI=$($vhdlRow.PBI)"
            })
        }
    }
    $rowsByCycle[[int]$vhdlRow.CYCLE] = $vhdlRow
}

if ($mismatches.Count -gt 0) {
    $first = $mismatches[0]
    Write-Output "FIRST DIVERGENCE at cycle $($first.Cycle), $($first.Column): VHDL=$($first.Expected), Verilog=$($first.Actual)"
    Write-Output "  context: $($first.Context)"
    Write-Output ""
    Write-Output "FULL DIVERGENCE PROFILE ($($mismatches.Count) fields over $($vhdlRows.Count) rows):"
    $byColumn = $mismatches | Group-Object Column | Sort-Object Name
    foreach ($g in $byColumn) {
        Write-Output ("  {0,-8} count={1,6}  first examples:" -f $g.Name, $g.Count)
        $g.Group | Select-Object -First 5 | ForEach-Object {
            Write-Output ("    cycle {0,5} VHDL={1} Verilog={2}" -f $_.Cycle, $_.Expected, $_.Actual)
        }
    }
    throw "VIA6522 EQUIVALENCE FAIL rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues divergences=$($mismatches.Count) first=cycle $($first.Cycle)/$($first.Column)"
}

# --- coverage gates (golden trace) --------------------------------------------
function Get-Row([int]$cycle) {
    $row = $rowsByCycle[$cycle]
    if ($null -eq $row) { throw "gate failure: no trace row for cycle $cycle" }
    return $row
}
$gateChecks = 0

# G1: all 16 addresses read (strobe, !we) at least once
$readAddrs = @{}
foreach ($row in $vhdlRows) {
    if ($row.STROBE -eq '1' -and $row.WE -eq '0') { $readAddrs[$row.ADDR.ToUpperInvariant()] = $true }
}
if ($readAddrs.Count -ne 16) { throw "gate failure G1: only $($readAddrs.Count)/16 addresses read" }
$gateChecks++

# G2: all 16 addresses written (strobe, we) at least once
$writeAddrs = @{}
foreach ($row in $vhdlRows) {
    if ($row.STROBE -eq '1' -and $row.WE -eq '1') { $writeAddrs[$row.ADDR.ToUpperInvariant()] = $true }
}
if ($writeAddrs.Count -ne 16) { throw "gate failure G2: only $($writeAddrs.Count)/16 addresses written" }
$gateChecks++

# G3: CA1I and CB1I transitions (count value changes across consecutive rows)
function Count-Transitions([string]$column) {
    $t = 0
    $prev = $null
    foreach ($row in $vhdlRows) {
        $v = $row.$column
        if ($null -ne $prev -and $v -ne $prev) { $t++ }
        $prev = $v
    }
    return $t
}
$ca1Trans = Count-Transitions 'CA1I'
$cb1Trans = Count-Transitions 'CB1I'
if ($ca1Trans -lt 4) { throw "gate failure G3: CA1I transitions=$ca1Trans (<4)" }
if ($cb1Trans -lt 4) { throw "gate failure G3: CB1I transitions=$cb1Trans (<4)" }
$gateChecks++

# G4: IRQ went high at least once
$irqHigh = @($vhdlRows | Where-Object { $_.IRQ -eq '1' }).Count
if ($irqHigh -lt 5) { throw "gate failure G4: IRQ high rows=$irqHigh (<5)" }
$gateChecks++

# G5: at least 20 distinct DOUT values observed
$distinctDout = @($vhdlRows | Where-Object { $_.DOUT -notmatch '[UXWZ-]' } | ForEach-Object { $_.DOUT.ToUpperInvariant() } | Sort-Object -Unique).Count
if ($distinctDout -lt 20) { throw "gate failure G5: distinct DOUT values=$distinctDout (<20)" }
$gateChecks++

# G6: metavalues bounded (pre-reset noise only)
if ($ignoredMetavalues -gt 600) { throw "gate failure G6: ignored_metavalues=$ignoredMetavalues (>600)" }
$gateChecks++

# G7: at least 80 strobed accesses total
$strobeCount = @($vhdlRows | Where-Object { $_.STROBE -eq '1' }).Count
if ($strobeCount -lt 80) { throw "gate failure G7: strobe rows=$strobeCount (<80)" }
$gateChecks++

Write-Output "VIA6522 EQUIVALENCE PASS rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues gate_checks=$gateChecks"
