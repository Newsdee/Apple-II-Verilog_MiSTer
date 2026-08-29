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
    # ROM parity: the golden hdd_rom is a VHDL constant array; the candidate
    # reads rtl/roms/hdd.hex. They must be byte-identical (256 bytes).
    $v = Get-Content (Join-Path $referenceRoot 'rtl\hdd_rom.vhd') -Raw
    $vhdlBytes = [regex]::Matches($v, 'X"([0-9A-Fa-f]{2})"') | ForEach-Object { $_.Groups[1].Value.ToLower() }
    $hexBytes = @()
    foreach ($line in (Get-Content (Join-Path $projectRoot 'rtl\roms\hdd.hex'))) {
        foreach ($tok in ($line -split '\s+')) { if ($tok -ne '') { $hexBytes += $tok.ToLower() } }
    }
    if ($vhdlBytes.Count -ne 256 -or $hexBytes.Count -ne 256) {
        throw "ROM parity failure: expected 256 bytes, got vhdl=$($vhdlBytes.Count) hex=$($hexBytes.Count)"
    }
    for ($i = 0; $i -lt 256; $i++) {
        if ($vhdlBytes[$i] -ne $hexBytes[$i]) {
            throw "ROM parity failure at byte $i : vhdl=$($vhdlBytes[$i]) hex=$($hexBytes[$i])"
        }
    }
    Write-Output "ROM PARITY OK (hdd_rom.vhd constant == rtl/roms/hdd.hex, 256 bytes)"

    # Stimulus tables (identical for both sides).
    & (Join-Path $PSScriptRoot 'gen_stim.ps1')
    if (-not $?) { throw 'gen_stim.ps1 failed' }

    # Golden side: hdd.vhd needs two transformations for GHDL (the copy is
    # byte-identical except where noted; no logic changed):
    #   1. It cases on unsigned slices with X"n" choices (Quartus-legal, not
    #      strict VHDL - choices must be discrete). Normalized to
    #      to_integer + integer literals.
    #   2. GHDL 6.0.0 codegen bug (repro t3/t9/t11/t12 in the hdd test notes):
    #      when a process has multiple element accesses to an array signal, or
    #      two processes both access one array signal with computed indices,
    #      the computed-index accesses silently read stale/lost values. The
    #      original has TWO processes (cpu_interface, sec_storage) both doing
    #      computed-index accesses to sector_buf. Merging them into one
    #      process with only computed-index accesses works correctly (t12).
    #      Both processes are on the same clock edge; the merge is
    #      behavior-identical for conflict-free port operations (the test
    #      schedule never writes the same element from both ports in one
    #      cycle; the original two-process form would be a multiple-driver
    #      runtime error in that case).
    $goldenSrc = Join-Path $referenceRoot 'rtl\hdd.vhd'
    $goldenCopy = Join-Path $vhdlBuild 'hdd_golden.vhd'
    $srcBytes = [System.IO.File]::ReadAllBytes($goldenSrc)
    $hasBom = ($srcBytes.Length -ge 3 -and $srcBytes[0] -eq 0xEF -and $srcBytes[1] -eq 0xBB -and $srcBytes[2] -eq 0xBF)
    $srcText = [System.IO.File]::ReadAllText($goldenSrc, [System.Text.Encoding]::UTF8)
    $eol = if ($srcText.Contains("`r`n")) { "`r`n" } else { "`n" }
    function Join-Lines([string[]]$lines) { $lines -join $eol }
    # (needle, replacement, expected count) - the A-case and most choices
    # occur in both the read and the write branch.
    $replacements = @(
        @('case A(3 downto 0) is', 'case to_integer(A(3 downto 0)) is', 2),
        @('when X"0" =>', 'when 0 =>', 1),
        @('when X"1" =>', 'when 1 =>', 1),
        @('when X"2" =>', 'when 2 =>', 2),
        @('when X"3" =>', 'when 3 =>', 2),
        @('when X"4" =>', 'when 4 =>', 2),
        @('when X"5" =>', 'when 5 =>', 2),
        @('when X"6" =>', 'when 6 =>', 2),
        @('when X"7" =>', 'when 7 =>', 2),
        @('when X"8" =>', 'when 8 =>', 2),
        @('case reg_command is', 'case to_integer(reg_command) is', 1),
        @('when PRODOS_COMMAND_STATUS =>', 'when 0 =>', 1),
        @('when PRODOS_COMMAND_READ =>', 'when 1 =>', 1),
        @('when PRODOS_COMMAND_WRITE =>', 'when 2 =>', 1),
        # Merge sec_storage into cpu_interface (GHDL bug workaround):
        # insert the sec_storage body at the top of the clocked region...
        @((Join-Lines @('    if rising_edge(CLK_14M) then', '      D_OUT <= X"FF";')),
          (Join-Lines @('    if rising_edge(CLK_14M) then',
                        '      if ram_we = ''1'' then',
                        '        sector_buf(to_integer(ram_addr)) <= ram_di;',
                        '      end if;',
                        '      ram_do <= sector_buf(to_integer(ram_addr));',
                        '      D_OUT <= X"FF";')), 1),
        # ...and delete the now-duplicate sec_storage process.
        @((Join-Lines @('  -- Dual-ported RAM holding the contents of the sector',
                        '  sec_storage : process (CLK_14M)',
                        '  begin',
                        '    if rising_edge(CLK_14M) then',
                        '      if ram_we = ''1'' then',
                        '        sector_buf(to_integer(ram_addr)) <= ram_di;',
                        '      end if;',
                        '      ram_do <= sector_buf(to_integer(ram_addr));',
                        '    end if;',
                        '  end process;')),
          (Join-Lines @('  -- Dual-ported RAM holding the contents of the sector',
                        '  -- (merged into cpu_interface for GHDL - see run_equivalence.ps1 header notes)')), 1)
    )
    $dstText = $srcText
    $lenDelta = 0
    foreach ($pair in $replacements) {
        $needle = $pair[0]
        $replacement = $pair[1]
        $expected = [int]$pair[2]
        if (([regex]::Matches($dstText, [regex]::Escape($needle))).Count -ne $expected) {
            throw "Golden copy generation failed: expected $expected occurrences of '$needle'"
        }
        $dstText = $dstText.Replace($needle, $replacement)
        $lenDelta += $expected * ($replacement.Length - $needle.Length)
    }
    if ($dstText.Length -ne $srcText.Length + $lenDelta) {
        throw 'Golden copy generation failed: unexpected text length change'
    }
    [System.IO.File]::WriteAllText($goldenCopy, $dstText, (New-Object System.Text.UTF8Encoding($hasBom)))

    # hdd_rom must be analyzed before hdd (direct entity instantiation).
    & $ghdl -a --std=08 "--workdir=$vhdlBuild" `
        (Join-Path $referenceRoot 'rtl\hdd_rom.vhd') `
        $goldenCopy `
        (Join-Path $buildRoot 'stim_table.vhd') `
        (Join-Path $PSScriptRoot 'hdd_vhdl_tb.vhd')
    if ($LASTEXITCODE -ne 0) { throw "GHDL analysis failed with exit code $LASTEXITCODE" }
    & $ghdl -e --std=08 "--workdir=$vhdlBuild" hdd_vhdl_tb
    if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration failed with exit code $LASTEXITCODE" }

    $vdir = Join-Path $buildRoot 'verilog'
    $aggregate = Join-Path $vdir 'Vhdd_verilog_tb__ALL.cpp'
    if ((Test-Path $aggregate) -and (Get-Item $aggregate).Length -eq 0) {
        Remove-Item -Force $aggregate
    }
    & $verilator --binary --timing -Wno-fatal --top-module hdd_verilog_tb --Mdir $vdir `
        (Join-Path $buildRoot 'stim_table.sv') `
        (Join-Path $projectRoot 'rtl\rom.v') `
        (Join-Path $projectRoot 'rtl\hdd.v') `
        (Join-Path $PSScriptRoot 'hdd_verilog_tb.sv')
    if ($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

    Push-Location $projectRoot
    try {
        & $ghdl -r --std=08 "--workdir=$vhdlBuild" hdd_vhdl_tb
        if ($LASTEXITCODE -ne 0) { throw "VHDL simulation failed with exit code $LASTEXITCODE" }
        & (Join-Path $vdir 'Vhdd_verilog_tb.exe')
        if ($LASTEXITCODE -ne 0) { throw "Verilog simulation failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

$columns = @('D_OUT', 'SECTOR', 'HDD_READ', 'HDD_WRITE', 'RAM_DO', 'A', 'RD', 'IO_SELECT',
             'DEVICE_SELECT', 'RESET', 'D_IN', 'MOUNTED', 'PROTECT', 'RAM_ADDR', 'RAM_DI', 'RAM_WE')

$vhdlRows = @(Import-Csv (Join-Path $buildRoot 'vhdl_trace.csv'))
$verilogRows = @(Import-Csv (Join-Path $buildRoot 'verilog_trace.csv'))
if ($vhdlRows.Count -ne $verilogRows.Count) {
    throw "trace length mismatch: VHDL=$($vhdlRows.Count), Verilog=$($verilogRows.Count)"
}

$comparedFields = 0
$ignoredMetavalues = 0
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
            throw "mismatch at cycle $($vhdlRow.CYCLE), $column`: VHDL=$expected, Verilog=$actual"
        }
    }
    $rowsByCycle[[int]$vhdlRow.CYCLE] = $vhdlRow
}

# --- Coverage gates (golden trace, transaction T is sampled at cycle 20+8*T) ---
function Get-Row([int]$t) {
    $row = $rowsByCycle[20 + 8 * $t]
    if ($null -eq $row) { throw "gate failure: no trace row for transaction T=$t (cycle $((20 + 8 * $t)))" }
    return $row
}
$gateChecks = 0
function Check-Field([int]$t, [string]$column, [string]$expectedHex, [string]$gateName) {
    $actual = (Get-Row $t).$column.ToUpperInvariant()
    $expected = $expectedHex.ToUpperInvariant()
    if ($actual.Length -lt $expected.Length) { $actual = $actual.PadLeft($expected.Length, '0') }
    if ($actual -ne $expected) {
        throw "$gateName`: T${t} $column = $actual, expected $expected"
    }
    $script:gateChecks++
}

# reset_clear
Check-Field 0 'D_OUT' '00' 'reset_clear'
# reg_readback
Check-Field 2  'D_OUT' '01' 'reg_readback'
Check-Field 4  'D_OUT' '70' 'reg_readback'
Check-Field 7  'D_OUT' '12' 'reg_readback'
Check-Field 8  'D_OUT' '34' 'reg_readback'
Check-Field 11 'D_OUT' '56' 'reg_readback'
Check-Field 12 'D_OUT' '78' 'reg_readback'
# sector_out
Check-Field 8  'SECTOR' '0000' 'sector_out'
Check-Field 12 'SECTOR' '7856' 'sector_out'
# no_device
foreach ($t in 14, 19, 22, 29) { Check-Field $t 'D_OUT' '28' 'no_device' }
# read_ok
Check-Field 16 'D_OUT' '00' 'read_ok'
if ((Get-Row 16).HDD_READ -ne '1') { throw "read_ok`: T16 hdd_read pulse missing" }
if ((Get-Row 17).HDD_READ -ne '0') { throw "read_ok`: T17 hdd_read still high (pulse too wide)" }
$gateChecks += 2
# write_ok
Check-Field 23 'D_OUT' '00' 'write_ok'
if ((Get-Row 23).HDD_WRITE -ne '1') { throw "write_ok`: T23 hdd_write pulse missing" }
if ((Get-Row 24).HDD_WRITE -ne '0') { throw "write_ok`: T24 hdd_write still high (pulse too wide)" }
$gateChecks += 2
# protect
Check-Field 24 'D_OUT' '2B' 'protect'
# format_others (unhandled command leaves D_OUT at its 0xFF default)
Check-Field 26 'D_OUT' 'FF' 'format_others'
# status_ok
Check-Field 28 'D_OUT' '00' 'status_ok'
Check-Field 30 'D_OUT' '00' 'status_ok'
# c0f8_points (CPU write pattern, 9-bit wrap, deferred increment, host bytes)
# sa: T551=8, T552=9, T553..T555=10 (hold defers the increment), T556=11,
# T573+i = 12+i (CPU pattern until sa=199, host bytes 0xA0+ from sa=200).
$c0f8 = @{ 551 = '08'; 552 = '09'; 553 = '0A'; 554 = '0A'; 555 = '0A'; 556 = '0B';
           573 = '0C'; 600 = '27'; 700 = '8B'; 761 = 'A0'; 762 = 'A1'; 768 = 'A7' }
foreach ($t in $c0f8.Keys) { Check-Field $t 'D_OUT' $c0f8[$t] 'c0f8_points' }
# host_ram_do (dual-port: CPU-written bytes 0..7 and 504..511)
for ($i = 0; $i -lt 8; $i++) {
    Check-Field (769 + $i) 'RAM_DO' ('{0:X2}' -f $i) 'host_ram_do'
    Check-Field (777 + $i) 'RAM_DO' ('{0:X2}' -f (248 + $i)) 'host_ram_do'
}
# rom_read (two registered stages: D_OUT at sample N = ROM[A(N-1)]; the io
# window holds A for P=0..1, so ROM[a] is visible at P=1 of the transaction)
$hexBytes = @()
foreach ($line in (Get-Content (Join-Path $projectRoot 'rtl\roms\hdd.hex'))) {
    foreach ($tok in ($line -split '\s+')) { if ($tok -ne '') { $hexBytes += $tok.ToLower() } }
}
$romAddrs = @(0x00, 0x01, 0x70, 0xFF, 0x80, 0x00)
for ($i = 0; $i -lt 6; $i++) {
    $row = $rowsByCycle[20 + 8 * (785 + $i) + 1]
    if ($null -eq $row) { throw "rom_read: no trace row for T$(785 + $i) P=1" }
    $actual = $row.D_OUT.ToUpperInvariant()
    $expected = $hexBytes[$romAddrs[$i]].ToUpperInvariant()
    if ($actual -ne $expected) { throw "rom_read: T$(785 + $i) D_OUT = $actual, expected ROM[$($romAddrs[$i].ToString('X2'))] = $expected" }
    $gateChecks++
}
# mid_reset (sector buffer + sec_addr survive; interface registers cleared)
# sa after T768 is 208; buf[208] is host-written 0xA8.
Check-Field 793 'D_OUT' 'A8' 'mid_reset'
Check-Field 794 'D_OUT' '00' 'mid_reset'
Check-Field 795 'D_OUT' '00' 'mid_reset'
Check-Field 796 'D_OUT' '28' 'mid_reset'
# pulse_width: hdd_read/hdd_write high exactly once, at the execute cycles
$readPulses = @($vhdlRows | Where-Object { $_.HDD_READ -eq '1' })
$writePulses = @($vhdlRows | Where-Object { $_.HDD_WRITE -eq '1' })
if ($readPulses.Count -ne 1 -or [int]$readPulses[0].CYCLE -ne (20 + 8 * 16)) {
    throw "pulse_width`: hdd_read high on $($readPulses.Count) rows (expected 1 at cycle $((20 + 8 * 16)))"
}
if ($writePulses.Count -ne 1 -or [int]$writePulses[0].CYCLE -ne (20 + 8 * 23)) {
    throw "pulse_width`: hdd_write high on $($writePulses.Count) rows (expected 1 at cycle $((20 + 8 * 23)))"
}
$gateChecks += 2
if ($comparedFields -lt 90000) { throw "coverage failure: only $comparedFields fields compared (need > 90000)" }

Write-Output "HDD EQUIVALENCE PASS rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues gate_checks=$gateChecks"
