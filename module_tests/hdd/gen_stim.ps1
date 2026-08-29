# gen_stim.ps1 - generates build/stim_table.vhd and build/stim_table.sv with
# the IDENTICAL TXN stimulus table for the hdd equivalence harness.
#
# Transaction bit layout (LSB first):
#   [0]      RD
#   [1]      hdd_mounted
#   [2]      hdd_protect
#   [3]      ram_we        (active at P=0 only)
#   [4]      hold          (DEVICE_SELECT held P=0..7 instead of P=0)
#   [5]      io_sel        (IO_SELECT at P=0, DS never asserted)
#   [6:21]   A[15:0]
#   [22:29]  D_IN[7:0]
#   [30:38]  ram_addr[8:0]
#   [39:46]  ram_di[7:0]
#
# Both testbenches drive: one transaction per 8 cycles (T = (N-20)/8,
# P = (N-20)%8, N>=20; N<20 is power-on reset). See hdd_vhdl_tb.vhd header.

param()
$ErrorActionPreference = 'Stop'
$build = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$txn = New-Object System.Collections.Generic.List[uint64]

function Add-Txn([uint32]$a, [int]$rd = 0, [int]$d = 0, [int]$m = 0, [int]$p = 0,
                 [int]$rwe = 0, [int]$hold = 0, [int]$io = 0, [int]$ra = 0, [int]$rdi = 0) {
    $v = [uint64]0
    if ($rd)   { $v = $v -bor ([uint64]1 -shl 0) }
    if ($m)    { $v = $v -bor ([uint64]1 -shl 1) }
    if ($p)    { $v = $v -bor ([uint64]1 -shl 2) }
    if ($rwe)  { $v = $v -bor ([uint64]1 -shl 3) }
    if ($hold) { $v = $v -bor ([uint64]1 -shl 4) }
    if ($io)   { $v = $v -bor ([uint64]1 -shl 5) }
    $v = $v -bor ([uint64]$a   -shl 6)
    $v = $v -bor ([uint64]$d   -shl 22)
    $v = $v -bor ([uint64]$ra  -shl 30)
    $v = $v -bor ([uint64]$rdi -shl 39)
    $script:txn.Add($v) | Out-Null
}

# --- T0..T30: register setup and readbacks ---
Add-Txn 0xC0F1 -rd 1          # T0:  status readback after reset -> 0x00
Add-Txn 0xC0F2 -d 0x01        # T1:  command = READ
Add-Txn 0xC0F2 -rd 1          # T2:  -> 0x01
Add-Txn 0xC0F3 -d 0x70        # T3:  unit = 0x70
Add-Txn 0xC0F3 -rd 1          # T4:  -> 0x70
Add-Txn 0xC0F4 -d 0x12        # T5:  mem_l
Add-Txn 0xC0F5 -d 0x34        # T6:  mem_h
Add-Txn 0xC0F4 -rd 1          # T7:  -> 0x12
Add-Txn 0xC0F5 -rd 1          # T8:  -> 0x34
Add-Txn 0xC0F6 -d 0x56        # T9:  block_l
Add-Txn 0xC0F7 -d 0x78        # T10: block_h
Add-Txn 0xC0F6 -rd 1          # T11: -> 0x56
Add-Txn 0xC0F7 -rd 1          # T12: -> 0x78 (sector = 0x7856)
# --- execute: no device ---
Add-Txn 0xC0F2 -d 0x01        # T13: READ cmd (sec_addr reset)
Add-Txn 0xC0F0 -rd 1          # T14: mounted=0 -> 0x28
Add-Txn 0xC0F1 -rd 1          # T15: -> 0x01
# --- execute: READ ok ---
Add-Txn 0xC0F0 -rd 1 -m 1     # T16: -> 0x00, hdd_read pulse
Add-Txn 0xC0F1 -rd 1          # T17: -> 0x00
# --- execute: wrong unit ---
Add-Txn 0xC0F3 -d 0x71        # T18
Add-Txn 0xC0F0 -rd 1 -m 1     # T19: -> 0x28
Add-Txn 0xC0F3 -d 0x70        # T20
# --- execute: WRITE ---
Add-Txn 0xC0F2 -d 0x02        # T21: WRITE cmd (sec_addr reset)
Add-Txn 0xC0F0 -rd 1          # T22: mounted=0 -> 0x28
Add-Txn 0xC0F0 -rd 1 -m 1     # T23: -> 0x00, hdd_write pulse
Add-Txn 0xC0F0 -rd 1 -m 1 -p 1  # T24: protect -> 0x2B
# --- execute: FORMAT (unhandled command) ---
Add-Txn 0xC0F2 -d 0x03        # T25
Add-Txn 0xC0F0 -rd 1 -m 1     # T26: -> 0xFF
# --- execute: STATUS ---
Add-Txn 0xC0F2 -d 0x00        # T27
Add-Txn 0xC0F0 -rd 1 -m 1     # T28: -> 0x00
Add-Txn 0xC0F0 -rd 1          # T29: mounted=0 -> 0x28
Add-Txn 0xC0F0 -rd 1 -m 1     # T30: -> 0x00 (sec_addr = 0)
# --- T31..T550: C0F8 CPU writes, 520 bytes (sec_addr wraps at 512) ---
for ($k = 0; $k -lt 520; $k++) { Add-Txn 0xC0F8 -d ($k % 256) -m 1 }
# --- T551..T556: readback across the wrap + deferred increment ---
Add-Txn 0xC0F8 -rd 1 -m 1            # T551: sa=8  -> 0x08
Add-Txn 0xC0F8 -rd 1 -m 1            # T552: sa=9  -> 0x09
Add-Txn 0xC0F8 -rd 1 -m 1 -hold 1    # T553: sa=10 -> 0x0A
Add-Txn 0xC0F8 -rd 1 -m 1 -hold 1    # T554: sa=10 -> 0x0A (increment deferred)
Add-Txn 0xC0F8 -rd 1 -m 1            # T555: sa=10 -> 0x0A (increment deferred)
Add-Txn 0xC0F8 -rd 1 -m 1            # T556: sa=11 -> 0x0B
# --- T557..T572: host-port writes to bytes 200..215 ---
for ($i = 0; $i -lt 16; $i++) { Add-Txn 0 -m 1 -rwe 1 -ra (200 + $i) -rdi (0xA0 + $i) }
# --- T573..T768: 196 C0F8 reads: sa 11..206 -> 0x0B..0xC7, 0xA0..0xA6 ---
for ($i = 0; $i -lt 196; $i++) { Add-Txn 0xC0F8 -rd 1 -m 1 }
# --- T769..T784: host reads: CPU-written 0..7 and 504..511 ---
for ($i = 0; $i -lt 8; $i++) { Add-Txn 0 -m 1 -ra $i }
for ($i = 0; $i -lt 8; $i++) { Add-Txn 0 -m 1 -ra (504 + $i) }
# --- T785..T790: firmware ROM reads (IO_SELECT; D_OUT shows ROM[prev A(7:0)]) ---
Add-Txn 0x0000 -rd 1 -io 1     # T785: ROM[0x00]
Add-Txn 0x0001 -rd 1 -io 1     # T786: ROM[0x00]
Add-Txn 0x0070 -rd 1 -io 1     # T787: ROM[0x01]
Add-Txn 0x00FF -rd 1 -io 1     # T788: ROM[0x70]
Add-Txn 0x0080 -rd 1 -io 1     # T789: ROM[0xFF]
Add-Txn 0x0000 -rd 1 -io 1     # T790: ROM[0x80]
# --- T791..T792: mid-test reset (driven by the TBs from T index) ---
Add-Txn 0
Add-Txn 0
# --- T793..T796: post-reset: sector buffer + sec_addr survive, regs cleared ---
Add-Txn 0xC0F8 -rd 1 -m 1      # T793: buf[207] = 0xA7
Add-Txn 0xC0F1 -rd 1 -m 1      # T794: -> 0x00
Add-Txn 0xC0F3 -rd 1 -m 1      # T795: -> 0x00
Add-Txn 0xC0F0 -rd 1 -m 1      # T796: -> 0x28 (unit cleared)

$n = $txn.Count
Write-Output ("TXN count: " + $n)

# --- VHDL package ---
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('-- GENERATED by gen_stim.ps1 - do not edit.')
[void]$sb.AppendLine('library ieee;')
[void]$sb.AppendLine('use ieee.std_logic_1164.all;')
[void]$sb.AppendLine('use ieee.numeric_std.all;')
[void]$sb.AppendLine('package stim_pkg is')
[void]$sb.AppendLine(('  type txn_arr is array (0 to {0}) of unsigned(63 downto 0);' -f ($n - 1)))
[void]$sb.AppendLine('  constant TXN : txn_arr := (')
for ($i = 0; $i -lt $n; $i += 8) {
    $count = [Math]::Min(8, $n - $i)
    $words = @()
    for ($j = 0; $j -lt $count; $j++) { $words += ('X"' + ('{0:X16}' -f $txn[$i + $j]) + '"') }
    $comma = if ($i + $count -lt $n) { ',' } else { '' }
    [void]$sb.AppendLine('    ' + ($words -join ', ') + $comma)
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
    $words = @()
    for ($j = 0; $j -lt $count; $j++) { $words += ('64''h' + ('{0:x16}' -f $txn[$i + $j])) }
    $comma = if ($i + $count -lt $n) { ',' } else { '' }
    [void]$sb.AppendLine('  ' + ($words -join ', ') + $comma)
}
[void]$sb.AppendLine('  };')
[void]$sb.AppendLine('endpackage')
[System.IO.File]::WriteAllText((Join-Path $build 'stim_table.sv'), $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Output "STIM TABLE GENERATED n=$n"
