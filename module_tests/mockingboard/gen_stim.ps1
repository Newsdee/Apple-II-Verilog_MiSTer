# gen_stim.ps1 - mockingboard equivalence stimulus generator.
#
# Emits build/stim_table.vhd and build/stim_table.sv containing the IDENTICAL
# per-cycle table both testbenches consume (24-bit words, hex-aligned):
#
#   bit 23     rst      (1 = reset asserted; TB drives I_RESET_L = ~rst)
#   bit 22     iosel    (I_IOSEL_L level; 0 = board selected)
#   bit 21     ena      (I_ENA_H level)
#   bit 20     rw       (I_RW_L level; 1 = read, 0 = write)
#   bits 19..12 addr    (I_ADDR)
#   bits 11..4 din      (I_DATA)
#   bits 3..0  spare    (always 0)
#
# Phase schedule (dense alternating; derived from cycle parity in each TB,
# NOT part of the stimulus word):
#   - Even cycles: PHASE_ZERO_R=1, PHASE_ZERO_F=0 -> golden VIA falling slot.
#   - Odd cycles:  PHASE_ZERO_R=0, PHASE_ZERO_F=1 -> golden VIA rising slot
#     and PSG CE (with ENA).
# All bus accesses occur in even cycles (golden falling slot), matching the
# via6522 module harness contract extended to board level.
#
# Step model: every step emits exactly two cycles - an even cycle followed by
# an odd one. PSG register transactions need ENA high during the odd cycle so
# the stub clocks; those steps use a no-op read of DDRB (addr 2) on the odd
# cycle (no VIA read action exists for addr 2).
#
# No randomness, no wall-clock dependence.

$ErrorActionPreference = 'Stop'
$buildRoot = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

$stim = New-Object System.Collections.Generic.List[long]

function Add-Cycle {
    param([bool]$rst, [bool]$iosel, [bool]$ena, [bool]$rw, [int]$addr, [int]$din)
    # NOTE: all arithmetic must stay in Int64 - PowerShell masks Int32 shift
    # counts (1 -shl 34 would silently become 1 -shl 2).
    $v = [long]0
    if ($rst)   { $v = $v -bor ([long]1 -shl 23) }
    if ($iosel) { $v = $v -bor ([long]1 -shl 22) }
    if ($ena)   { $v = $v -bor ([long]1 -shl 21) }
    if ($rw)    { $v = $v -bor ([long]1 -shl 20) }
    $v = $v -bor ([long](($addr -band 0xFF)) -shl 12)
    $v = $v -bor ([long](($din -band 0xFF)) -shl 4)
    $stim.Add($v)
}

# Access on the even cycle, deselected idle on the odd cycle.
function Step-Access { param([bool]$rw, [int]$addr, [int]$din)
    Add-Cycle $false $false $true $rw $addr $din
    Add-Cycle $false $true  $false $true 0 0
}
function Step-Read  { param([int]$a) Step-Access $true  $a 0 }
function Step-Write { param([int]$a, [int]$d) Step-Access $false $a $d }
function Step-Reset { Add-Cycle $true $true $false $true 0 0; Add-Cycle $true $true $false $true 0 0 }
function Step-Idle  { Add-Cycle $false $true $false $true 0 0; Add-Cycle $false $true $false $true 0 0 }

# PSG register transaction: even cycle performs a real VIA access, odd cycle
# holds ENA high (F phase -> stub CE) with a no-op DDRB read.
function Step-Psg { param([bool]$rw, [int]$addr, [int]$din)
    Add-Cycle $false $false $true $rw $addr $din
    Add-Cycle $false $false $true $true 2 0
}
# PSG register transactions are side-specific: $hi = 0 (left VIA/PSG) or
# 0x80 (right VIA/PSG). PSG_EN is board-wide, so the INACTIVE side's ORB must
# hold BC=0 (value 0x00/0x04) whenever ENA=1 on an odd cycle; every PSG phase
# therefore ends by returning its own ORB to the release value.
# Write a PSG register: ORA=data (DI), then commit with ORB=0x07 (BC+BDIR).
function Step-PsgWrite { param([int]$hi, [int]$val)
    Step-Write ($hi -bor 1) $val
    Step-Psg $false $hi 0x07
}
# Read a PSG register: ORA=index, then commit read with ORB=0x05 (BC, ~BDIR).
function Step-PsgRead { param([int]$hi, [int]$idx)
    Step-Write ($hi -bor 1) $idx
    Step-Psg $false $hi 0x05
}
function Repeat { param([int]$count, [scriptblock]$sb) for ($i = 0; $i -lt $count; $i++) { & $sb } }

# --- P0: reset held for 8 cycles, then released ------------------------------
Repeat 4 { Step-Reset }
Repeat 2 { Step-Idle }

# --- P1: post-reset read sweep, both Vias, all 16 addresses ------------------
# DDRB/DDRA are 0 after reset, so ORB (addr 0) reads irb directly: golden
# port_b_i=FF vs candidate portb_in width (01) diverges here if present.
for ($a = 0; $a -le 15; $a++) { Step-Read ($a -band 0x7F) }        # left
for ($a = 0; $a -le 15; $a++) { Step-Read (0x80 -bor $a) }         # right

# --- P2: program all 16 registers on both Vias, then read back ---------------
$prog = @{ 0=0x00; 1=0xA5; 2=0xFF; 3=0xFF; 4=0x12; 5=0x34; 6=0x12; 7=0x34;
           8=0x56; 9=0x78; 10=0xC3; 11=0x00; 12=0x00; 13=0x00; 14=0x7F; 15=0xA5 }
foreach ($side in 0, 1) {
    $hi = if ($side -eq 1) { 0x80 } else { 0 }
    for ($a = 0; $a -le 15; $a++) { Step-Write ($hi -bor $a) $prog[$a] }
    for ($a = 0; $a -le 15; $a++) { Step-Read  ($hi -bor $a) }
}

# --- P3: left PSG - release reset, set channels, read back -------------------
# Right ORB is 0x00 (BC=0) from P2, so psg_right stays inert on the odd cycles
# where ENA=1 clocks both stubs.
Step-Write 0x00 0x04     # left ORB: PB2=1 releases stub RESET (BC=0, BDIR=0)
Repeat 2 { Step-Idle }
Step-PsgWrite 0 0x80     # channel A = mem[0] <= 0x80
Step-PsgWrite 0 0xC1     # channel B = mem[1] <= 0xC1
Step-PsgWrite 0 0x82     # channel C = mem[2] <= 0x82   (audio L = 451 = 0x1C3)
Repeat 2 { Step-Idle }
Step-PsgRead 0 0x00      # stub read commit: do_reg <= mem[0]
Step-Read 1              # ORA readback (returns the index written above)
Step-PsgRead 0 0x01      # stub read commit: do_reg <= mem[1]
Step-Read 1
Step-Write 0x00 0x04     # left ORB back to release state (BC=0) for P4's CE

# --- P4: right PSG ------------------------------------------------------------
# Left ORB is 0x04 (BC=0) from the P3 tail, so psg_left stays inert.
Step-Write 0x80 0x04     # right ORB releases reset
Repeat 2 { Step-Idle }
Step-PsgWrite 0x80 0x40  # channel A = mem[0] <= 0x40
Step-PsgWrite 0x80 0x81  # channel B = mem[1] <= 0x81
Step-PsgWrite 0x80 0x02  # channel C = mem[2] <= 0x02    (audio R = 195 = 0x0C3)
Repeat 2 { Step-Idle }
Step-PsgRead 0x80 0x00   # stub read commit: do_reg <= mem[0]
Step-Read 0x81           # right ORA readback
Step-Write 0x80 0x04     # right ORB back to release state (BC=0)

# --- P5: left IRQ via Timer A one-shot ----------------------------------------
Step-Write 0xE 0xFF      # IER: set all mask bits
Step-Write 6 0x02        # TA LO latch = 02
Step-Write 5 0x00        # TA HI counter write -> load {00,02}, oneshot
Repeat 6 { Step-Read 0xD }   # IFR reads (no read action); IRQ low rows appear
Step-Write 0xD 0x40      # clear TA flag via IFR write
Repeat 2 { Step-Read 0xD }

# --- P6: right NMI via Timer A one-shot ---------------------------------------
Step-Write 0x8E 0xFF
Step-Write 0x86 0x02
Step-Write 0x85 0x00
Repeat 6 { Step-Read 0x8D }
Step-Write 0x8D 0x40
Repeat 2 { Step-Read 0x8D }

# --- P7: ENA gating window (IRQ pending while I_ENA_H=0) ----------------------
Step-Write 6 0x02        # refire left TA (mask still enabled from P5)
Step-Write 5 0x00        # load at even cycle L; TA flag visible from L+8
Repeat 6 { Step-Read 0xD }   # IRQ low rows (lirq pending) - guarantees the
                             # flag is set BEFORE the ENA=0 window below
Repeat 4 { Step-Idle }       # ENA=0 window: O_IRQ_L/O_NMI_L forced high
Repeat 2 { Step-Read 0xD }   # IRQ low again
Step-Write 0xD 0x40     # clear TA flag
Repeat 2 { Step-Read 0xD }

# --- P8: IOSEL gating ----------------------------------------------------------
Step-Write 1 0x3C        # ORA = 3C (selected write)
# Deselected write attempt: iosel=1, ena=1, we fields present -> no VIA action.
Add-Cycle $false $true $true $false 1 0xC3
Add-Cycle $false $true $false $true 0 0
Step-Read 1              # ORA must still read back 3C
Step-Write 1 0xC3        # real selected write
Step-Read 1              # ORA reads back C3 (if writes work)

# --- P9: serial engine, left VIA (ACR=0x12: output, TB-tick clock) ------------
Step-Write 0xB 0x12      # ACR: shift dir=1, clk sel=01 (TB tick)
Step-Write 8 0x02        # TB LO latch = 02
Step-Write 9 0x00        # TB HI counter write -> load {00,02}, oneshot
Step-Write 0xA 0xA5      # SR load -> trigger serial transfer
Repeat 24 { Step-Idle }  # let the engine shift out all 8 bits
Step-Read 0xA            # SR readback (engine inactive by now)
Step-Read 0xD            # IFR: serial flag may be set (mask enabled)
Step-Write 0xD 0x7F      # clear ALL flags

# --- P10: final read sweep, both Vias ------------------------------------------
for ($a = 0; $a -le 15; $a++) { Step-Read ($a -band 0x7F) }
for ($a = 0; $a -le 15; $a++) { Step-Read (0x80 -bor $a) }

# --- emit ---------------------------------------------------------------------
$n = $stim.Count
if ($n % 2 -ne 0) { throw "internal: odd cycle count $n" }

$vhdl = New-Object System.Text.StringBuilder
[void]$vhdl.AppendLine('library ieee;')
[void]$vhdl.AppendLine('use ieee.std_logic_1164.all;')
[void]$vhdl.AppendLine('')
[void]$vhdl.AppendLine('package mockingboard_stim is')
[void]$vhdl.AppendLine("    constant STIM_COUNT : integer := $n;")
# 24-bit words: hex literals must be a multiple of 4 bits.
[void]$vhdl.AppendLine('    type stim_arr_t is array (0 to STIM_COUNT - 1) of std_logic_vector(23 downto 0);')
[void]$vhdl.AppendLine('    constant STIM : stim_arr_t := (')
for ($i = 0; $i -lt $n; $i++) {
    $hex = ('{0:X6}' -f $stim[$i])
    if ($i -lt $n - 1) { [void]$vhdl.AppendLine("        X`"$hex`",") } else { [void]$vhdl.AppendLine("        X`"$hex`"") }
}
[void]$vhdl.AppendLine('    );')
[void]$vhdl.AppendLine('end package mockingboard_stim;')

$sv = New-Object System.Text.StringBuilder
[void]$sv.AppendLine('`timescale 1ns/1ps')
[void]$sv.AppendLine('package mockingboard_stim;')
[void]$sv.AppendLine("    localparam int STIM_COUNT = $n;")
# Const array with inline aggregate (packages cannot contain initial blocks).
[void]$sv.AppendLine("    localparam bit [23:0] STIM[STIM_COUNT] = '{")
for ($i = 0; $i -lt $n; $i++) {
    $hex = ('{0:X6}' -f $stim[$i])
    if ($i -lt $n - 1) { [void]$sv.AppendLine("        24'h$hex,") } else { [void]$sv.AppendLine("        24'h$hex") }
}
[void]$sv.AppendLine('    };')
[void]$sv.AppendLine('endpackage')

[System.IO.File]::WriteAllText((Join-Path $buildRoot 'stim_table.vhd'), $vhdl.ToString(), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $buildRoot 'stim_table.sv'), $sv.ToString(), (New-Object System.Text.UTF8Encoding($false)))
$stopNs = 106 + 70 * ($n - 1) + 500
[System.IO.File]::WriteAllText((Join-Path $buildRoot 'stim_count.txt'), "$n`n$stopNs`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Output "STIM OK cycles=$n stopTime=${stopNs}ns"
