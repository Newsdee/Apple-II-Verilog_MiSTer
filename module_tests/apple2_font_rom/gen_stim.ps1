# gen_stim.ps1 - generates build/stim_table.vhd, build/stim_table.sv and
# build/stim_meta.csv for the apple2_font_rom equivalence harness.
#
# One table word per cycle (LSB first):
#   [0]     WR         (ioctl_wr)
#   [1]     ROMSWITCH
#   [2]     ALT        (alternate_character)
#   [3]     LOWER      (lowercase_character)
#   [4:9]   CH[5:0]    (character_code[5:0])
#   [10]    CH6        (character_code[6] - unused by the decode)
#   [11:13] ROW[2:0]   (glyph_row)
#   [14:26] IOCTL_ADDR[12:0]
#   [27:34] IOCTL_DATA[7:0]
#
# Phases (see the plan in README.md):
#   A  0..4095    full read sweep: RS x {ALT,LOWER} x CH 0..63 x ROW 0..7
#   A2 4096..4103 CH6=1 probe (CH 0..7) - proves bit 6 is ignored
#   B  4104+3i    32 write+readback pairs (i=0..31):
#                 rs=i%2, fl=(i/2)%2, ch=(7i) mod 64, row=i%8
#                 addr = {rs,00,fl,ch,row}; data = 0xA5 ^ addr[7:0]
#                 1 write cycle + 2 pure-read cycles decoding to addr
#   B2 4200+3j    4 read-during-write probes (j=0..3):
#                 j=0  EQUAL: rewrite B(0) with the same data (no divergence)
#                 j=1..3 DIFF: B(j) with data ^ 0xFF (guaranteed different)
#   C  4212..4227 interleave: reads, one write (addr=0x1234, data=0x77), reads
#
# TOTAL = 4228 cycles.

param()
$ErrorActionPreference = 'Stop'
$build = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$words = New-Object System.Collections.Generic.List[uint64]
$meta  = New-Object System.Collections.Generic.List[string]
[void]$meta.Add('CYCLE,WR,ADDR,DATA')

function Add-Cycle([int]$wr, [int]$rs, [int]$alt, [int]$lower, [int]$ch,
                   [int]$ch6, [int]$row, [int]$addr, [int]$data) {
    $v = [uint64]0
    if ($wr)    { $v = $v -bor ([uint64]1 -shl 0) }
    if ($rs)    { $v = $v -bor ([uint64]1 -shl 1) }
    if ($alt)   { $v = $v -bor ([uint64]1 -shl 2) }
    if ($lower) { $v = $v -bor ([uint64]1 -shl 3) }
    $v = $v -bor ([uint64]$ch  -shl 4)
    if ($ch6)   { $v = $v -bor ([uint64]1 -shl 10) }
    $v = $v -bor ([uint64]$row -shl 11)
    $v = $v -bor ([uint64]$addr -shl 14)
    $v = $v -bor ([uint64]$data -shl 27)
    $cycle = $script:words.Count
    $script:words.Add($v) | Out-Null
    [void]$script:meta.Add(("$cycle,$wr,$addr,$data"))
}

# --- Phase A: full read sweep (4096 cycles) ---
for ($n = 0; $n -lt 4096; $n++) {
    Add-Cycle -wr 0 `
        -rs   ([bool]($n -band 0x800)) `
        -alt  ([bool]($n -band 0x400)) `
        -lower([bool]($n -band 0x200)) `
        -ch   (($n -band 0x3F8) / 8) `
        -ch6  0 `
        -row  ($n -band 7) `
        -addr 0 -data 0
}
# --- Phase A2: CH6=1 probe (8 cycles) ---
for ($i = 0; $i -lt 8; $i++) {
    Add-Cycle -wr 0 -rs 0 -alt 0 -lower 0 -ch $i -ch6 1 -row 0 -addr 0 -data 0
}
# --- Phase B: 32 write + readback pairs ---
$bAddr = @(); $bData = @()
for ($i = 0; $i -lt 32; $i++) {
    $rs  = $i % 2
    # [int] cast of 1.5 rounds to 2 in PowerShell - use explicit floor.
    $fl  = [int]([Math]::Floor($i / 2)) % 2
    $ch  = ($i * 7) % 64
    $row = $i % 8
    # Read decode is {RS, 00, flag, ch, row}: the "00" occupies bits 11:10,
    # so the flag bit is bit 9.
    $addr = ($rs -shl 12) -bor ($fl -shl 9) -bor ($ch -shl 3) -bor $row
    $data = 0xA5 -bxor ($addr -band 0xFF)
    $bAddr += $addr; $bData += $data
    Add-Cycle -wr 1 -rs $rs -alt $fl -lower 0 -ch $ch -ch6 0 -row $row -addr $addr -data $data
    Add-Cycle -wr 0 -rs $rs -alt $fl -lower 0 -ch $ch -ch6 0 -row $row -addr $addr -data $data
    Add-Cycle -wr 0 -rs $rs -alt $fl -lower 0 -ch $ch -ch6 0 -row $row -addr $addr -data $data
}
# --- Phase B2: read-during-write probes ---
# j=0: EQUAL (rewrite B(0) with identical data -> must NOT diverge)
Add-Cycle -wr 1 -rs 0 -alt 0 -lower 0 -ch 0 -ch6 0 -row 0 -addr $bAddr[0] -data $bData[0]
Add-Cycle -wr 0 -rs 0 -alt 0 -lower 0 -ch 0 -ch6 0 -row 0 -addr $bAddr[0] -data $bData[0]
Add-Cycle -wr 0 -rs 0 -alt 0 -lower 0 -ch 0 -ch6 0 -row 0 -addr $bAddr[0] -data $bData[0]
# j=1..3: DIFFERENT (data ^ 0xFF vs current content)
for ($j = 1; $j -le 3; $j++) {
    $rs  = $j % 2
    $fl  = [int]([Math]::Floor($j / 2)) % 2
    $ch  = ($j * 7) % 64
    $row = $j % 8
    $addr = $bAddr[$j]
    $data = $bData[$j] -bxor 0xFF
    Add-Cycle -wr 1 -rs $rs -alt $fl -lower 0 -ch $ch -ch6 0 -row $row -addr $addr -data $data
    Add-Cycle -wr 0 -rs $rs -alt $fl -lower 0 -ch $ch -ch6 0 -row $row -addr $addr -data $data
    Add-Cycle -wr 0 -rs $rs -alt $fl -lower 0 -ch $ch -ch6 0 -row $row -addr $addr -data $data
}
# --- Phase C: interleave (16 cycles) ---
for ($i = 0; $i -lt 5; $i++) {
    Add-Cycle -wr 0 -rs 0 -alt 0 -lower 0 -ch $i -ch6 0 -row 0 -addr 0 -data 0
}
Add-Cycle -wr 1 -rs 0 -alt 0 -lower 0 -ch 0 -ch6 0 -row 0 -addr 0x1234 -data 0x77
for ($i = 0; $i -lt 10; $i++) {
    Add-Cycle -wr 0 -rs 0 -alt 0 -lower 0 -ch $i -ch6 0 -row 0 -addr 0 -data 0
}

$n = $words.Count
if ($n -ne 4228) { throw "stimulus length $n != 4228" }
Write-Output ("CYCLES: " + $n)

# --- VHDL package ---
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('-- GENERATED by gen_stim.ps1 - do not edit.')
[void]$sb.AppendLine('library ieee;')
[void]$sb.AppendLine('use ieee.std_logic_1164.all;')
[void]$sb.AppendLine('use ieee.numeric_std.all;')
[void]$sb.AppendLine('package stim_pkg is')
[void]$sb.AppendLine(('  type cyc_arr is array (0 to {0}) of unsigned(63 downto 0);' -f ($n - 1)))
[void]$sb.AppendLine('  constant TXN : cyc_arr := (')
for ($i = 0; $i -lt $n; $i += 8) {
    $count = [Math]::Min(8, $n - $i)
    $words8 = @()
    for ($j = 0; $j -lt $count; $j++) { $words8 += ('X"' + ('{0:X16}' -f $words[$i + $j]) + '"') }
    $comma = if ($i + $count -lt $n) { ',' } else { '' }
    [void]$sb.AppendLine('    ' + ($words8 -join ', ') + $comma)
}
[void]$sb.AppendLine('  );')
[void]$sb.AppendLine('end package stim_pkg;')
[System.IO.File]::WriteAllText((Join-Path $build 'stim_table.vhd'), $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# --- Verilog package ---
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('// GENERATED by gen_stim.ps1 - do not edit.')
[void]$sb.AppendLine('package stim_pkg;')
[void]$sb.AppendLine('  localparam logic [63:0] TXN [0:' + ($n - 1) + "] = '{")
for ($i = 0; $i -lt $n; $i += 8) {
    $count = [Math]::Min(8, $n - $i)
    $words8 = @()
    for ($j = 0; $j -lt $count; $j++) { $words8 += ('64''h' + ('{0:x16}' -f $words[$i + $j])) }
    $comma = if ($i + $count -lt $n) { ',' } else { '' }
    [void]$sb.AppendLine('  ' + ($words8 -join ', ') + $comma)
}
[void]$sb.AppendLine('  };')
[void]$sb.AppendLine('endpackage')
[System.IO.File]::WriteAllText((Join-Path $build 'stim_table.sv'), $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# --- runner metadata (cycle, wr, addr, data) ---
[System.IO.File]::WriteAllLines((Join-Path $build 'stim_meta.csv'), $meta, (New-Object System.Text.UTF8Encoding($false)))

Write-Output "STIM TABLE GENERATED n=$n"
