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
    # --- Golden-side normalization (no logic changed) -------------------------
    # (1) mockingboard_golden.vhd: strip the YM2149 component declaration so
    #     psg_left/psg_right bind to entity work.YM2149 - the deterministic
    #     stub analyzed from ym2149_stub.vhd (GHDL cannot compile YM2149.sv).
    $boardSrc = Join-Path $referenceRoot 'rtl\mockingboard\mockingboard.vhd'
    $boardCopy = Join-Path $vhdlBuild 'mockingboard_golden.vhd'
    $srcBytes = [System.IO.File]::ReadAllBytes($boardSrc)
    $hasBom = ($srcBytes.Length -ge 3 -and $srcBytes[0] -eq 0xEF -and $srcBytes[1] -eq 0xBB -and $srcBytes[2] -eq 0xBF)
    $boardText = [System.IO.File]::ReadAllText($boardSrc, [System.Text.Encoding]::UTF8)

    # Strip the YM2149 component declaration (instantiations become direct
    # entity references to the stub) and expand the Quartus-legal shorthand
    # instantiations to VHDL-2008 direct-entity form (GHDL is strict: a bare
    # or work.-qualified name in an instantiation statement denotes a
    # component, not an entity).
    $pattern = '(?s)\s*component YM2149.*?end component;\r?\n'
    $count = [regex]::Matches($boardText, $pattern).Count
    if ($count -ne 1) { throw "board transform: expected 1 YM2149 component declaration, found $count" }
    $boardOut = [regex]::Replace($boardText, $pattern, '')

    # (needle, replacement, expected count)
    $boardReplacements = @(
        @('m6522_left : work.via6522', 'm6522_left : entity work.via6522', 1),
        @('m6522_right : work.via6522', 'm6522_right : entity work.via6522', 1),
        @('psg_left: YM2149', 'psg_left: entity work.YM2149', 1),
        @('psg_right: YM2149', 'psg_right: entity work.YM2149', 1)
    )
    foreach ($r in $boardReplacements) {
        $needle = $r[0]
        $count = [regex]::Matches($boardOut, [regex]::Escape($needle)).Count
        if ($count -ne $r[2]) {
            throw "board transform: expected $($r[2]) of '$needle', found $count"
        }
        $boardOut = $boardOut.Replace($needle, $r[1])
    }
    [System.IO.File]::WriteAllText($boardCopy, $boardOut, (New-Object System.Text.UTF8Encoding($hasBom)))
    Write-Output "BOARD GOLDEN COPY OK (component stripped; $($boardReplacements.Count) instantiations to direct-entity form)"

    # (2) via6522_golden.vhd: identical normalization to the via6522 harness.
    #     The golden uses Quartus-legal but strict-VHDL-illegal case/with-select
    #     choices on std_logic_vector; all are normalized to to_int_vec(...)
    #     subjects (shim package) and integer choices. One use clause added.
    $viaSrc = Join-Path $referenceRoot 'rtl\mockingboard\via6522.vhd'
    $viaCopy = Join-Path $vhdlBuild 'via6522_golden.vhd'
    $vBytes = [System.IO.File]::ReadAllBytes($viaSrc)
    $vHasBom = ($vBytes.Length -ge 3 -and $vBytes[0] -eq 0xEF -and $vBytes[1] -eq 0xBB -and $vBytes[2] -eq 0xBF)
    $srcText = [System.IO.File]::ReadAllText($viaSrc, [System.Text.Encoding]::UTF8)
    $eol = if ($srcText.Contains("`r`n")) { "`r`n" } else { "`n" }

    $needle = 'use ieee.std_logic_unsigned.all;'
    $count = [regex]::Matches($srcText, [regex]::Escape($needle)).Count
    if ($count -ne 1) { throw "via6522 transform: expected 1 use clause, found $count" }
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
            throw "via6522 transform: expected $($r[2]) of '$needle', found $count"
        }
        $dstText = $dstText.Replace($needle, $r[1])
    }
    [System.IO.File]::WriteAllText($viaCopy, $dstText, (New-Object System.Text.UTF8Encoding($vHasBom)))
    Write-Output "VIA GOLDEN COPY OK ($($replacements.Count) normalized constructs, no logic changed)"

    # Stimulus tables (identical for both sides) + stop-time.
    & (Join-Path $PSScriptRoot 'gen_stim.ps1')
    if (-not $?) { throw 'gen_stim.ps1 failed' }
    $stimInfo = Get-Content (Join-Path $buildRoot 'stim_count.txt')
    $stimCount = [int]$stimInfo[0]
    $stopNs = [int]$stimInfo[1]

    # -fsynopsys: via6522.vhd uses ieee.std_logic_arith/std_logic_unsigned
    # (Synopsys packages, not in the IEEE set).
    & $ghdl -a --std=08 -fsynopsys "--workdir=$vhdlBuild" `
        (Join-Path $PSScriptRoot 'via6522_shim.vhd') `
        (Join-Path $PSScriptRoot 'ym2149_stub.vhd') `
        $viaCopy `
        $boardCopy `
        (Join-Path $buildRoot 'stim_table.vhd') `
        (Join-Path $PSScriptRoot 'mockingboard_vhdl_tb.vhd')
    if ($LASTEXITCODE -ne 0) { throw "GHDL analysis failed with exit code $LASTEXITCODE" }

    # Elaboration and both simulations run from the project root: the TBs
    # open/write their trace CSV at a project-root-relative path, and GHDL
    # opens the VHDL file object already at elaboration.
    Push-Location $projectRoot
    try {
        & $ghdl -e --std=08 -fsynopsys "--workdir=$vhdlBuild" mockingboard_vhdl_tb
        if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration failed with exit code $LASTEXITCODE" }

        $vdir = Join-Path $buildRoot 'verilog'
        $aggregate = Join-Path $vdir 'Vmockingboard_verilog_tb__ALL.cpp'
        if ((Test-Path $aggregate) -and (Get-Item $aggregate).Length -eq 0) {
            Remove-Item -Force $aggregate
        }
        & $verilator --binary --timing -Wno-fatal --top-module mockingboard_verilog_tb --Mdir $vdir `
            (Join-Path $buildRoot 'stim_table.sv') `
            (Join-Path $projectRoot 'rtl\mockingboard\mockingboard.v') `
            (Join-Path $projectRoot 'rtl\mockingboard\via6522.v') `
            (Join-Path $PSScriptRoot 'ym2149_stub.v') `
            (Join-Path $PSScriptRoot 'mockingboard_verilog_tb.sv')
        if ($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

        # --stop-time is mandatory: the concurrent clock keeps events pending
        # forever after the driver suspends (no std_env in this GHDL build's
        # -fsynopsys ieee library).
        & $ghdl -r --std=08 -fsynopsys "--workdir=$vhdlBuild" mockingboard_vhdl_tb "--stop-time=${stopNs}ns"
        if ($LASTEXITCODE -ne 0) { throw "VHDL simulation failed with exit code $LASTEXITCODE" }
        & (Join-Path $vdir 'Vmockingboard_verilog_tb.exe')
        if ($LASTEXITCODE -ne 0) { throw "Verilog simulation failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

# --- compare ------------------------------------------------------------------
$columns = @('RESET', 'IOSL', 'ENA', 'RW', 'ADDR', 'DIN', 'ODATA', 'OE', 'IRQ', 'NMI', 'AUDL', 'AUDR')

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
                Context = "ADDR=$($vhdlRow.ADDR) DIN=$($vhdlRow.DIN) RW=$($vhdlRow.RW) ENA=$($vhdlRow.ENA) IOSL=$($vhdlRow.IOSL)"
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
    throw "MOCKINGBOARD EQUIVALENCE FAIL rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues divergences=$($mismatches.Count) first=cycle $($first.Cycle)/$($first.Column)"
}

# --- coverage gates (golden trace) --------------------------------------------
function Get-Row([int]$cycle) {
    $row = $rowsByCycle[$cycle]
    if ($null -eq $row) { throw "gate failure: no trace row for cycle $cycle" }
    return $row
}
$gateChecks = 0

# G1: both Vias accessed in both directions (selected + enabled rows)
$leftWrite = @($vhdlRows | Where-Object { $_.ENA -eq '1' -and $_.IOSL -eq '0' -and $_.RW -eq '0' -and [int]([convert]::ToInt32($_.ADDR, 16)) -lt 0x80 }).Count
$leftRead  = @($vhdlRows | Where-Object { $_.ENA -eq '1' -and $_.IOSL -eq '0' -and $_.RW -eq '1' -and [int]([convert]::ToInt32($_.ADDR, 16)) -lt 0x80 }).Count
$rightWrite = @($vhdlRows | Where-Object { $_.ENA -eq '1' -and $_.IOSL -eq '0' -and $_.RW -eq '0' -and [int]([convert]::ToInt32($_.ADDR, 16)) -ge 0x80 }).Count
$rightRead  = @($vhdlRows | Where-Object { $_.ENA -eq '1' -and $_.IOSL -eq '0' -and $_.RW -eq '1' -and [int]([convert]::ToInt32($_.ADDR, 16)) -ge 0x80 }).Count
if ($leftWrite -lt 4 -or $leftRead -lt 4 -or $rightWrite -lt 4 -or $rightRead -lt 4) {
    throw "gate failure G1: left W/R=$($leftWrite)/$($leftRead), right W/R=$($rightWrite)/$($rightRead) (need >=4 each)"
}
$gateChecks++

# G2/G3: all 16 low addresses read and written on each side
$readL = @{}; $readR = @{}; $writeL = @{}; $writeR = @{}
foreach ($row in $vhdlRows) {
    if ($row.ENA -ne '1' -or $row.IOSL -ne '0') { continue }
    $a = [int]([convert]::ToInt32($row.ADDR, 16))
    if ($a -lt 0x80) {
        if ($row.RW -eq '1') { $readL[$a] = $true } else { $writeL[$a] = $true }
    } else {
        if ($row.RW -eq '1') { $readR[$a - 0x80] = $true } else { $writeR[$a - 0x80] = $true }
    }
}
if ($readL.Count -ne 16 -or $writeL.Count -ne 16) { throw "gate failure G2/G3: left read=$($readL.Count)/16 write=$($writeL.Count)/16" }
if ($readR.Count -ne 16 -or $writeR.Count -ne 16) { throw "gate failure G2/G3: right read=$($readR.Count)/16 write=$($writeR.Count)/16" }
$gateChecks += 2

# G4: OE toggled both ways
$oeLow = @($vhdlRows | Where-Object { $_.OE -eq '0' }).Count
$oeHigh = @($vhdlRows | Where-Object { $_.OE -eq '1' }).Count
if ($oeLow -lt 8 -or $oeHigh -lt 8) { throw "gate failure G4: OE low=$oeLow high=$oeHigh (need >=8 each)" }
$gateChecks++

# G5: IRQ asserted (O_IRQ_L=0) and later deasserted
$irqLowRows = @($vhdlRows | Where-Object { $_.IRQ -eq '0' })
if ($irqLowRows.Count -lt 3) { throw "gate failure G5: IRQ low rows=$($irqLowRows.Count) (<3)" }
$firstLow = $irqLowRows[0].CYCLE
$highAfter = @($vhdlRows | Where-Object { [int]$_.CYCLE -gt [int]$firstLow -and $_.IRQ -eq '1' }).Count
if ($highAfter -lt 3) { throw "gate failure G5: IRQ high rows after first low=$highAfter (<3)" }
$gateChecks++

# G6: NMI asserted and later deasserted
$nmiLowRows = @($vhdlRows | Where-Object { $_.NMI -eq '0' })
if ($nmiLowRows.Count -lt 3) { throw "gate failure G6: NMI low rows=$($nmiLowRows.Count) (<3)" }
$firstNmiLow = $nmiLowRows[0].CYCLE
$nmiHighAfter = @($vhdlRows | Where-Object { [int]$_.CYCLE -gt [int]$firstNmiLow -and $_.NMI -eq '1' }).Count
if ($nmiHighAfter -lt 3) { throw "gate failure G6: NMI high rows after first low=$nmiHighAfter (<3)" }
$gateChecks++

# G7: ENA gating window - an IRQ-low selected row, then a run of >=8
#     consecutive ENA=0 rows with both IRQ and NMI forced high, then another
#     IRQ-low selected row (P7: TA flag pending across the I_ENA_H=0 window).
#     The run is >=8 (not exactly 8) because each stimulus step contributes a
#     trailing ENA=0 odd cycle between the selected even-cycle accesses.
$g7 = $false
for ($i = 0; $i -lt $vhdlRows.Count -and -not $g7; $i++) {
    $r = $vhdlRows[$i]
    if ($r.ENA -ne '1' -or $r.IRQ -ne '0') { continue }
    $k = $i + 1
    $run = 0
    while ($k -lt $vhdlRows.Count) {
        $c = $vhdlRows[$k]
        if ($c.ENA -eq '0' -and $c.IRQ -eq '1' -and $c.NMI -eq '1') { $run++; $k++; continue }
        break
    }
    if ($run -ge 8 -and $k -lt $vhdlRows.Count) {
        $last = $vhdlRows[$k]
        if ($last.ENA -eq '1' -and $last.IRQ -eq '0') { $g7 = $true }
    }
}
if (-not $g7) { throw "gate failure G7: ENA gating window pattern not found" }
$gateChecks++

# G8: audio sums reach the expected values (stub channels active + summing OK)
$maxL = 0; $maxR = 0
$distinctL = @{}; $distinctR = @{}
foreach ($row in $vhdlRows) {
    if ($row.AUDL -match '^[0-9A-F]+$') {
        $v = [convert]::ToInt32($row.AUDL, 16)
        if ($v -gt $maxL) { $maxL = $v }
        $distinctL[$v] = $true
    }
    if ($row.AUDR -match '^[0-9A-F]+$') {
        $v = [convert]::ToInt32($row.AUDR, 16)
        if ($v -gt $maxR) { $maxR = $v }
        $distinctR[$v] = $true
    }
}
# Expected: left 0x80+0xC1+0x82 = 451 = 0x1C3; right 0x40+0x81+0x02 = 195 = 0x0C3
if ($maxL -ne 0x1C3) { throw "gate failure G8: max AUDL=$($maxL.ToString('X')) (expected 1C3)" }
if ($maxR -ne 0xC3) { throw "gate failure G8: max AUDR=$($maxR.ToString('X')) (expected C3)" }
if ($distinctL.Count -lt 2 -or $distinctR.Count -lt 2) { throw "gate failure G8: distinct audio values L=$($distinctL.Count) R=$($distinctR.Count) (<2)" }
$gateChecks++

# G9: metavalues bounded (pre-reset noise only)
if ($ignoredMetavalues -gt 600) { throw "gate failure G9: ignored_metavalues=$ignoredMetavalues (>600)" }
$gateChecks++

# G10: total selected+enabled access rows
$accessRows = @($vhdlRows | Where-Object { $_.ENA -eq '1' -and $_.IOSL -eq '0' }).Count
if ($accessRows -lt 100) { throw "gate failure G10: access rows=$accessRows (<100)" }
$gateChecks++

Write-Output "MOCKINGBOARD EQUIVALENCE PASS rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues gate_checks=$gateChecks"
