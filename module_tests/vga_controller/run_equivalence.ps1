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
    # Golden copy: GHDL rejects `end process <label>;` for unlabeled
    # processes (Quartus-legal, not strict VHDL). Strip the 4 end labels.
    $goldenSrc = Join-Path $referenceRoot 'rtl\vga_controller.vhd'
    $goldenCopy = Join-Path $vhdlBuild 'vga_controller_golden.vhd'
    $srcBytes = [System.IO.File]::ReadAllBytes($goldenSrc)
    $hasBom = ($srcBytes.Length -ge 3 -and $srcBytes[0] -eq 0xEF -and $srcBytes[1] -eq 0xBB -and $srcBytes[2] -eq 0xBF)
    $srcText = [System.IO.File]::ReadAllText($goldenSrc, [System.Text.Encoding]::UTF8)
    # Transformations (byte-identical except where noted; no logic changed):
    #   1. `end process <label>;` for unlabeled processes is rejected -
    #      strip the 4 end labels.
    #   2. GHDL 6.0.0 enforces STRICT case coverage: a case on a
    #      std_logic_vector/unsigned must cover every value of the base
    #      range (std_logic has 15 values 'U'..'-'). Quartus is lenient.
    #      Convert each vector case to `case to_integer(<expr>)` with
    #      integer choices (behavior-identical; the hdd golden copy uses
    #      the same pattern).
    $labels = @('pixel_generator', 'seam_cleanup', 'vertical_line_buffer', 'vertical_comb_filter')
    # 2-bit choices: color_addr (1) + SCREEN_MODE (2) = 3 each.
    # 4-bit choices: palette_index (1, single space) + shift_color
    # (4, six spaces) = 1 + 4 each. The shift_reg(3 downto 2) case has
    # `when others` and is GHDL-legal as-is - leave it untouched.
    $dstText = $srcText
    $lenDelta = 0
    foreach ($label in $labels) {
        $needle = "end process ${label};"
        if (([regex]::Matches($dstText, [regex]::Escape($needle))).Count -ne 1) {
            throw "Golden copy generation failed: expected 1 occurrence of '$needle'"
        }
        $dstText = $dstText.Replace($needle, 'end process;')
        $lenDelta -= ($label.Length + 1)
    }
    function Convert-Choice([string]$needle, [string]$replacement, [int]$expected) {
        if (([regex]::Matches($script:dstText, [regex]::Escape($needle))).Count -ne $expected) {
            throw "Golden copy generation failed: expected $expected occurrences of '$needle'"
        }
        $script:dstText = $script:dstText.Replace($needle, $replacement)
        $script:lenDelta += $expected * ($replacement.Length - $needle.Length)
    }
    foreach ($v in 0..3) {
        $bits = [Convert]::ToString($v, 2).PadLeft(2, '0')
        Convert-Choice "when `"$bits`" =>" "when $v =>" 3
    }
    foreach ($v in 0..15) {
        $bits = [Convert]::ToString($v, 2).PadLeft(4, '0')
        Convert-Choice "when `"$bits`" =>" "when $v =>" 1
        Convert-Choice "when `"$bits`"      =>" "when $v =>" 4
    }
    # The case expressions themselves. SCREEN_MODE is a std_logic_vector
    # port, so to_integer needs an explicit unsigned() conversion; the
    # others are already unsigned.
    $caseExprs = @(
        @('case color_addr is', 'case to_integer(color_addr) is', 1),
        @('case palette_index is', 'case to_integer(palette_index) is', 1),
        @('case SCREEN_MODE is', 'case to_integer(unsigned(SCREEN_MODE)) is', 2),
        @('case shift_color is', 'case to_integer(shift_color) is', 4)
    )
    foreach ($pair in $caseExprs) {
        $needle = $pair[0]; $replacement = $pair[1]; $expected = [int]$pair[2]
        if (([regex]::Matches($dstText, [regex]::Escape($needle))).Count -ne $expected) {
            throw "Golden copy generation failed: expected $expected occurrences of '$needle'"
        }
        $dstText = $dstText.Replace($needle, $replacement)
        $lenDelta += $expected * ($replacement.Length - $needle.Length)
    }
    # GHDL strict coverage also demands `when others` for the converted
    # to_integer cases (integer is unbounded). Insert it before each
    # `end case;` that does not already have one. Unreachable in hardware
    # (2/4-bit expressions) and metavalue-free in this harness (the else
    # branch resets color_addr/palette_index/palette_rgb_in every cycle),
    # so behavior is unchanged.
    $crlfCount = ([regex]::Matches($dstText, "`r`n")).Count
    $lfOnly = ([regex]::Matches($dstText, "(?<!`r)`n")).Count
    $eol = if ($crlfCount -ge $lfOnly) { "`r`n" } else { "`n" }
    $lines = [regex]::Split($dstText, "`r?`n")
    $outLines = New-Object System.Collections.Generic.List[string]
    foreach ($i in 0..($lines.Count - 1)) {
        if ($lines[$i].Trim() -eq 'end case;') {
            $j = $i - 1
            while ($j -ge 0 -and $lines[$j].Trim().Length -eq 0) { $j-- }
            $prev = if ($j -ge 0) { $lines[$j].Trim() } else { '' }
            if (-not $prev.StartsWith('when others')) {
                $indent = ($lines[$i] -replace '\S.*', '')
                $outLines.Add($indent + 'when others => null;')
                $lenDelta += $indent.Length + 'when others => null;'.Length + $eol.Length
            }
        }
        $outLines.Add($lines[$i])
    }
    $dstText = $outLines -join $eol
    if ($dstText.Length -ne $srcText.Length + $lenDelta) {
        throw 'Golden copy generation failed: unexpected text length change'
    }
    [System.IO.File]::WriteAllText($goldenCopy, $dstText, (New-Object System.Text.UTF8Encoding($hasBom)))

    & $ghdl -a --std=08 "--workdir=$vhdlBuild" $goldenCopy (Join-Path $PSScriptRoot 'vga_controller_vhdl_tb.vhd')
    if ($LASTEXITCODE -ne 0) { throw "GHDL analysis failed with exit code $LASTEXITCODE" }
    & $ghdl -e --std=08 "--workdir=$vhdlBuild" vga_controller_vhdl_tb
    if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration failed with exit code $LASTEXITCODE" }

    $vdir = Join-Path $buildRoot 'verilog'
    $aggregate = Join-Path $vdir 'Vvga_controller_verilog_tb__ALL.cpp'
    if ((Test-Path $aggregate) -and (Get-Item $aggregate).Length -eq 0) {
        Remove-Item -Force $aggregate
    }
    & $verilator --binary --timing -Wno-fatal --top-module vga_controller_verilog_tb --Mdir $vdir `
        (Join-Path $projectRoot 'rtl\vga_controller.v') `
        (Join-Path $PSScriptRoot 'vga_controller_verilog_tb.sv')
    if ($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

    Push-Location $projectRoot
    try {
        & $ghdl -r --std=08 "--workdir=$vhdlBuild" vga_controller_vhdl_tb
        if ($LASTEXITCODE -ne 0) { throw "VHDL simulation failed with exit code $LASTEXITCODE" }
        & (Join-Path $vdir 'Vvga_controller_verilog_tb.exe')
        if ($LASTEXITCODE -ne 0) { throw "Verilog simulation failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

$inputCols  = @('VIDEO', 'HBL', 'VBL', 'SM', 'CP', 'GSF', 'NVC', 'CL', 'IOCTL_DL', 'IOCTL_IDX', 'IOCTL_WR', 'IOCTL_DATA')
$outputCols = @('VGA_HS', 'VGA_VS', 'VGA_HBL', 'VGA_VBL', 'VGA_R', 'VGA_G', 'VGA_B', 'IOCTL_WAIT')
$allCols = @($inputCols + $outputCols)

$vhdlRows = @(Import-Csv (Join-Path $buildRoot 'vhdl_trace.csv'))
$verilogRows = @(Import-Csv (Join-Path $buildRoot 'verilog_trace.csv'))
if ($vhdlRows.Count -ne $verilogRows.Count) {
    throw "trace length mismatch: VHDL=$($vhdlRows.Count), Verilog=$($verilogRows.Count)"
}

$comparedFields = 0
$ignoredMetavalues = 0
$firstMismatch = $null
$mismatchCount = 0
$mismatchCols = New-Object System.Collections.Generic.HashSet[string]
$mismatchLines = New-Object System.Collections.Generic.HashSet[int]
$mismatchFirstCycle = 0
$mismatchLastCycle = 0
$firstInputMismatch = $null
# Line-0 power-up artifact: the golden's hcount starts U (no init), the
# candidate's starts 0 (Verilog semantics = Cyclone V power-up default).
# This delays the golden's line-0 raw_active by one cycle, shifting the
# line-0 VGA_HBL edge by exactly one cycle (all later lines identical -
# verified at the line-1 edge, cycle 1284 on both sides). Classified
# separately; gate: VGA_HBL only, <= 2 fields.
$powerupCount = 0
$powerupCols = New-Object System.Collections.Generic.HashSet[string]
# Power-up transients (golden has no reset port; Verilog regs start 0):
#   VGA_VBL U until 351, VGA_HS U until 1046, IOCTL_WAIT U until 1823
#   (first download beat), VGA_VS U until ~34790 (vcount stays U until
#   the first VBL=0 falling edge at line 3, and VGA_VS is only assigned
#   when vcount=33/36 - no else branch). All single LEADING runs.
#   VGA_HBL additionally has one 1-cycle U island at cycle 17 (uninit
#   seam_timing_active/ctq/fta registers crossing the delay chain).
# Gate: islands (U after a known in the same column) allowed only at
# cycle <= 100; total U fields <= 45000.
$colSeenKnown = @{}
$earlyIslands = 0
$lateIslands = 0
$lateIslandFirst = -1

for ($i = 0; $i -lt $vhdlRows.Count; $i++) {
    $vhdlRow = $vhdlRows[$i]
    $verilogRow = $verilogRows[$i]
    if ($vhdlRow.CYCLE -ne $verilogRow.CYCLE) {
        throw "cycle mismatch at row ${i}: VHDL=$($vhdlRow.CYCLE), Verilog=$($verilogRow.CYCLE)"
    }
    $cycle = [int]$vhdlRow.CYCLE
    foreach ($column in $allCols) {
        $expected = $vhdlRow.$column.ToUpperInvariant()
        $actual = $verilogRow.$column.ToUpperInvariant()
        if ($expected -match '[UXWZ-]') {
            $ignoredMetavalues++
            if ($colSeenKnown[$column] -eq $true) {
                if ($cycle -le 100) { $earlyIslands++ }
                else { if ($lateIslandFirst -lt 0) { $lateIslandFirst = $cycle }; $lateIslands++ }
            }
            continue
        }
        $colSeenKnown[$column] = $true
        $comparedFields++
        if ($expected -ne $actual) {
            if ($inputCols -contains $column -and $null -eq $firstInputMismatch) {
                $firstInputMismatch = "cycle ${cycle}, ${column}: VHDL=$expected, Verilog=$actual"
            }
            if ($cycle -lt 912) {
                $powerupCount++
                [void]$powerupCols.Add($column)
            } else {
                $mismatchCount++
                [void]$mismatchCols.Add($column)
                [void]$mismatchLines.Add([int]($cycle / 912))
                if ($null -eq $firstMismatch) {
                    $firstMismatch = $cycle
                    $mismatchFirstCycle = $cycle
                }
                $mismatchLastCycle = $cycle
            }
        }
    }
}

if ($null -ne $firstInputMismatch) {
    throw "HARNESS ERROR (stimulus mismatch between TBs): $firstInputMismatch"
}

if ($lateIslands -gt 0) {
    throw "metavalue gate failure: $lateIslands island metavalue fields after cycle 100 (first at $lateIslandFirst)"
}

if ($powerupCount -gt 2) {
    throw "power-up gate failure: $powerupCount line-0 mismatches in $($powerupCols -join '+') (expected VGA_HBL only, <= 2)"
}

# --- Coverage gates (golden trace) ---
if ($vhdlRows.Count -lt 163000) { throw "coverage failure: only $($vhdlRows.Count) rows (need >= 163000)" }

# VGA_HS rising edges
$hsEdges = 0
$prevHs = $null
foreach ($row in $vhdlRows) {
    $v = $row.VGA_HS
    if ($v -match '[UXWZ-]') { continue }
    if ($v -eq '1' -and $prevHs -eq '0') { $hsEdges++ }
    $prevHs = $v
}
if ($hsEdges -lt 170) { throw "coverage failure: only $hsEdges VGA_HS rising edges (need >= 170)" }

# VGA_VS: high for >= 2500 cycles and back low
$vsHigh = 0; $vsLowAfter = $false; $seenHigh = $false
foreach ($row in $vhdlRows) {
    $v = $row.VGA_VS
    if ($v -match '[UXWZ-]') { continue }
    if ($v -eq '1') { $vsHigh++; $seenHigh = $true }
    elseif ($seenHigh) { $vsLowAfter = $true }
}
if (-not $seenHigh -or $vsHigh -lt 2500 -or -not $vsLowAfter) {
    throw "coverage failure: VGA_VS high=$vsHigh seenHigh=$seenHigh lowAfter=$vsLowAfter (need >= 2500 and reassert)"
}

# distinct {SM,CP}
$combos = New-Object System.Collections.Generic.HashSet[string]
foreach ($row in $vhdlRows) { [void]$combos.Add($row.SM + $row.CP) }
if ($combos.Count -lt 16) { throw "coverage failure: only $($combos.Count) distinct {SM,CP} (need >= 16)" }

# active-cycle gates
$gsfActive = 0; $nvc0Active = 0; $nvc1Active = 0; $cl0Active = 0
foreach ($row in $vhdlRows) {
    if ($row.VBL -eq '0' -and $row.HBL -eq '0') {
        if ($row.GSF -eq '1') { $gsfActive++ }
        if ($row.NVC -eq '1' -and $row.SM -eq '00') { $nvc0Active++ }
        if ($row.NVC -eq '1' -and $row.SM -eq '01') { $nvc1Active++ }
        if ($row.CL -eq '0') { $cl0Active++ }
    }
}
if ($gsfActive -lt 560 * 12) { throw "coverage failure: GSF active cycles $gsfActive < $((560 * 12))" }
if ($nvc0Active -lt 560 * 16) { throw "coverage failure: NVC SM=00 active cycles $nvc0Active < $((560 * 16))" }
if ($nvc1Active -lt 560 * 4) { throw "coverage failure: NVC SM=01 active cycles $nvc1Active < $((560 * 4))" }
if ($cl0Active -lt 560 * 4) { throw "coverage failure: CL=0 active cycles $cl0Active < $((560 * 4))" }

# distinct VGA_R
$rValues = New-Object System.Collections.Generic.HashSet[string]
foreach ($row in $vhdlRows) { if ($row.VGA_R -notmatch '[UXWZ-]') { [void]$rValues.Add($row.VGA_R) } }
if ($rValues.Count -lt 24) { throw "coverage failure: only $($rValues.Count) distinct VGA_R (need >= 24)" }

if ($ignoredMetavalues -gt 45000) {
    throw "coverage failure: $ignoredMetavalues ignored metavalue fields (limit 45000)"
}

if ($mismatchCount -gt 0) {
    # Report the first mismatch with input context, then the full summary.
    # Cycle number equals row index (cycles are 0..N-1).
    $first = $vhdlRows[$firstMismatch]
    $firstV = $verilogRows[$firstMismatch]
    $ctx = "SM=$($first.SM) CP=$($first.CP) GSF=$($first.GSF) NVC=$($first.NVC) CL=$($first.CL) VBL=$($first.VBL) HBL=$($first.HBL) line=$([int]([int]$first.CYCLE / 912))"
    $detail = @()
    foreach ($column in $outputCols) {
        if ($first.$column -ne $firstV.$column) {
            $detail += "$($column): VHDL=$($first.$column) Verilog=$($firstV.$column)"
        }
    }
    # Signature containment: the known palette-download differences
    # (candidate latches the NEW beat value and wraps color_addr after
    # beat 2 = 3 beats/color, so its 16-color LUT is scrambled from color
    # 1 on and colors 0-4 are overwritten by a second pass over beats
    # 48-62) can only affect CP=11 lines: P2 k=12..15 = lines 114-129
    # plus the seam-carryover successor line 130, and P3 lines 171-178
    # plus successor 179. Any mismatch outside this set is unexpected.
    $expectedCols = @('VGA_R', 'VGA_G', 'VGA_B')
    $unexpectedCols = @($mismatchCols | Where-Object { $expectedCols -notcontains $_ })
    $unexpectedLines = @($mismatchLines | Where-Object { ($_ -lt 114 -or $_ -gt 130) -and ($_ -lt 171 -or $_ -gt 179) })
    $sortedLines = @($mismatchLines | Sort-Object) -join ', '
    if ($unexpectedCols.Count -gt 0 -or $unexpectedLines.Count -gt 0) {
        Write-Output ("VGA_CONTROLLER DIVERGENCE (UNEXPECTED) first=cycle ${firstMismatch} ($($detail -join '; ')) context: ${ctx}" +
            " rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues" +
            " mismatched_fields=$mismatchCount columns=$($mismatchCols -join '+') lines=${sortedLines}" +
            " unexpected_columns=$($unexpectedCols -join '+') unexpected_lines=$($unexpectedLines -join ', ')" +
            " powerup_line0=$powerupCount/$($powerupCols -join '+') early_islands=$earlyIslands inputs_ok=true")
    } else {
        Write-Output ("VGA_CONTROLLER DIVERGENCE (expected palette-download signature) first=cycle ${firstMismatch} ($($detail -join '; ')) context: ${ctx}" +
            " rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues" +
            " mismatched_fields=$mismatchCount columns=$($mismatchCols -join '+') lines=${sortedLines}" +
            " powerup_line0=$powerupCount/$($powerupCols -join '+') early_islands=$earlyIslands inputs_ok=true")
    }
} else {
    # PASS path: verify the custom palette actually took effect on P3.
    $triples = New-Object System.Collections.Generic.HashSet[string]
    foreach ($row in $vhdlRows) {
        $li = [int]([int]$row.CYCLE / 912)
        if ($li -ge 171 -and $li -le 178 -and $row.VBL -eq '0' -and $row.HBL -eq '0') {
            [void]$triples.Add($row.VGA_R + $row.VGA_G + $row.VGA_B)
        }
    }
    if ($triples.Count -lt 12) { throw "coverage failure: only $($triples.Count) distinct P3 {R,G,B} triples (need >= 12)" }
    Write-Output ("VGA_CONTROLLER EQUIVALENCE PASS rows=$($vhdlRows.Count) fields=$comparedFields" +
        " ignored_metavalues=$ignoredMetavalues early_islands=$earlyIslands hs_edges=$hsEdges vs_high=$vsHigh combos=$($combos.Count)" +
        " p3_triples=$($triples.Count)")
}
