# gen_stim.ps1 - via6522 equivalence stimulus generator.
#
# Emits build/stim_table.vhd and build/stim_table.sv containing the IDENTICAL
# per-cycle table both testbenches consume (36-bit words, top bit always 0 -
# hex literals must be a multiple of 4 bits):
#
#   bit 34     reset      (active high, synchronous on both DUTs)
#   bit 33     strobe     (golden: wen|ren; candidate: strobe)
#   bit 32     we         (golden: wen; candidate: we; strobe&we = write)
#   bit 31..28 addr       (4-bit VIA register address)
#   bit 27..20 din        (data in)
#   bit 19     ca1i
#   bit 18     ca2i
#   bit 17     cb1i
#   bit 16     cb2i
#   bit 15..8  pai        (port A input)
#   bit 7..0   pbi        (port B input)
#
# Cycle model (identical effective timing on both sides):
#   - Every step emits exactly two cycles: an F slot (even index) and an R
#     slot (odd index). All bus accesses happen in F slots.
#   - Golden TB drives falling=1 in F slots, rising=1 in R slots; the VIA's
#     timer clocks and bus writes land on F-slot edges.
#   - Candidate TB drives ce=1 in F slots (timer clock) and strobe/we in F
#     slots (bus accesses). Timer decrements therefore align edge-for-edge
#     with the golden's falling-phase decrements.
#
# No randomness, no wall-clock dependence.

$ErrorActionPreference = 'Stop'
$buildRoot = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

$stim = New-Object System.Collections.Generic.List[long]
$pins = @{ ca1 = 0; ca2 = 0; cb1 = 0; cb2 = 0; pai = 0; pbi = 0 }

function Add-Cycle {
    param([bool]$reset, [bool]$strobe, [bool]$we, [int]$addr, [int]$din)
    # NOTE: all arithmetic must stay in Int64 - PowerShell masks Int32 shift
    # counts (1 -shl 34 would silently become 1 -shl 2).
    $v = [long]0
    if ($reset)  { $v = $v -bor ([long]1 -shl 34) }
    if ($strobe) { $v = $v -bor ([long]1 -shl 33) }
    if ($we)     { $v = $v -bor ([long]1 -shl 32) }
    $v = $v -bor ([long](($addr -band 0xF)) -shl 28)
    $v = $v -bor ([long](($din -band 0xFF)) -shl 20)
    if ($pins.ca1) { $v = $v -bor ([long]1 -shl 19) }
    if ($pins.ca2) { $v = $v -bor ([long]1 -shl 18) }
    if ($pins.cb1) { $v = $v -bor ([long]1 -shl 17) }
    if ($pins.cb2) { $v = $v -bor ([long]1 -shl 16) }
    $v = $v -bor ([long](($pins.pai -band 0xFF)) -shl 8)
    $v = $v -bor [long](($pins.pbi -band 0xFF))
    $stim.Add($v)
}

function Step-Idle { Add-Cycle $false $false $false 0 0; Add-Cycle $false $false $false 0 0 }
function Step-Reset { Add-Cycle $true $false $false 0 0; Add-Cycle $true $false $false 0 0 }
function Step-Read { param([int]$a) Add-Cycle $false $true $false $a 0; Add-Cycle $false $false $false 0 0 }
function Step-Write { param([int]$a, [int]$d) Add-Cycle $false $true $true $a $d; Add-Cycle $false $false $false 0 0 }
function Set-Ca1 { param([int]$v) $pins.ca1 = $v }
function Set-Ca2 { param([int]$v) $pins.ca2 = $v }
function Set-Cb1 { param([int]$v) $pins.cb1 = $v }
function Set-Cb2 { param([int]$v) $pins.cb2 = $v }
function Set-Pai { param([int]$v) $pins.pai = $v }
function Set-Pbi { param([int]$v) $pins.pbi = $v }
function Repeat { param([int]$count, [scriptblock]$sb) for ($i = 0; $i -lt $count; $i++) { & $sb } }

# --- P0: reset held for 8 cycles, then released -----------------------------
Repeat 4 { Step-Reset }
Repeat 2 { Step-Idle }

# --- P1: post-reset read sweep, all 16 addresses ----------------------------
for ($a = 0; $a -le 15; $a++) { Step-Read $a }

# --- P2: program registers, then read back all 16 addresses -----------------
Step-Write 1 0xA5   # ORA
Step-Write 0 0x5A   # ORB
Step-Write 3 0xFF   # DDRA
Step-Write 2 0xFF   # DDRB
Step-Write 0xB 0x00 # ACR
Step-Write 0xC 0x00 # PCR
Step-Write 0xE 0x7F # IER clear-all (bit7=0: mask AND= NOT 7F -> all disabled)
Step-Write 6 0x12   # TA latch LO
Step-Write 7 0x34   # TA latch HI
Step-Write 8 0x56   # TB latch LO
Step-Write 0xA 0xC3 # SR
for ($a = 0; $a -le 15; $a++) { Step-Read $a }

# --- P3: CA1/CA2 handshakes, edge select, port A latch ----------------------
Step-Write 0xC 0x00   # PCR=0: CA1 rising detect, CA2 handshake mode
Step-Write 0xB 0x00   # ACR=0: no latching
Set-Ca1 1; Repeat 2 { Step-Idle }; Set-Ca1 0     # CA1 rising pulse (detected)
Repeat 4 { Step-Idle }
Step-Read 0xD          # IFR: expect bit0 (CA1)
Step-Read 1            # ORA read clears ca1 flag/handshake
Step-Read 0xD          # IFR: cleared

Step-Write 0xC 0x01   # PCR[0]=1: CA1 falling detect
Set-Ca1 1; Repeat 2 { Step-Idle }; Set-Ca1 0     # rising (ignored), falling (detected)
Repeat 4 { Step-Idle }
Step-Read 0xD
Step-Read 1
Step-Read 0xD

# Port A latch (ACR0=1): input changes after the event must be latched.
Step-Write 0xB 0x01   # ACR0=1: PA latch enabled
Set-Pai 0x3C; Repeat 2 { Step-Idle }             # PAI=3C before the event
Set-Ca1 1; Repeat 2 { Step-Idle }; Set-Ca1 0     # CA1 rising pulse (event latches PAI)
Set-Pai 0xC3                               # input changes AFTER the event
Repeat 4 { Step-Idle }
Step-Read 1            # ORA: latched value (both sides expect 3C here)
Step-Write 0xD 0x01   # clear CA1 flag via IFR bit0 (NOT an ORA read)
Repeat 3 { Step-Idle }
Step-Read 1            # golden holds ira=3C; candidate resumes tracking PAI=C3

Step-Write 0xC 0x02   # PCR[3:1]=001: CA2 pulse mode (observe ca2o in trace)
Set-Ca1 1; Repeat 2 { Step-Idle }; Set-Ca1 0
Repeat 4 { Step-Idle }
Step-Read 0xD
Step-Write 0xD 0x01

# --- P4: CB1/CB2 handshakes, port B latch ------------------------------------
Step-Write 0xC 0x10   # PCR[4]=1: CB1 falling detect; CA2 back to handshake
Step-Write 0xB 0x02   # ACR1=1: PB latch enabled
Set-Cb1 1; Repeat 2 { Step-Idle }; Set-Cb1 0     # rising (ignored), falling (detected)
Repeat 4 { Step-Idle }
Step-Read 0xD          # IFR: expect bit3 (CB1)

Set-Pbi 0x66; Repeat 2 { Step-Idle }             # PBI=66 before the event
Set-Cb1 1; Repeat 2 { Step-Idle }; Set-Cb1 0     # CB1 falling pulse (event latches PBI)
Set-Pbi 0x99                               # input changes AFTER the event
Repeat 4 { Step-Idle }
Step-Read 0            # ORB read: golden = irb (input latch), candidate = portb mix
Step-Read 0xD
Step-Write 0xD 0x08   # clear CB1 flag

Step-Write 0xC 0x08   # PCR[7:5]=001: CB2 pulse mode (observe cb2o in trace)
Set-Cb1 1; Repeat 2 { Step-Idle }; Set-Cb1 0
Repeat 4 { Step-Idle }
Step-Read 0xD
Step-Write 0xD 0x10   # clear CB2 flag

# --- P5: Timer A --------------------------------------------------------------
Step-Write 0xB 0x40   # ACR6=1: TA free-run
Step-Write 5 0x01     # TA HI write -> load {01,12}=0x0112, start
Repeat 15 { Step-Idle }
Step-Read 4            # TA LO
Step-Read 5            # TA HI
Step-Read 0xD          # IFR: expect bit6 (TA)

Step-Write 0xB 0x00   # ACR=0: one-shot
Step-Write 5 0x01
Repeat 15 { Step-Idle }
Step-Read 0xD          # IRQ set on first overflow
Repeat 15 { Step-Idle }
Step-Read 0xD          # second overflow: one-shot must not retrigger

Step-Write 0xB 0xC0   # ACR7|ACR6: PB7 output + free-run
Step-Write 6 0x02     # TA latch LO=02
Step-Write 5 0x00     # load {00,02}=2 -> fast PB7 toggle (traced on PBO)
Repeat 20 { Step-Idle }
Step-Read 0xD
Step-Write 0xD 0x40   # clear TA flag

# --- P6: Timer B --------------------------------------------------------------
Step-Write 0xB 0x00   # ACR=0: no shift, TB one-shot
Step-Write 9 0x02     # TB HI write -> load {02,56}=0x0256
Repeat 15 { Step-Idle }
Step-Read 8            # TB LO
Step-Read 9            # TB HI
Step-Read 0xD          # IFR: expect bit5 (TB)

Step-Write 0xB 0x20   # ACR5=1: TB count mode (PB6 edges)
Set-Pbi 0xB0; Repeat 2 { Step-Idle }             # PB6=1
Set-Pbi 0x30; Repeat 2 { Step-Idle }             # PB6 falling edge #1
Set-Pbi 0xB0; Repeat 2 { Step-Idle }             # PB6=1
Set-Pbi 0x30                             # PB6 falling edge #2, held low
Repeat 10 { Step-Idle }
Step-Read 8            # golden: ~2 edges counted; candidate: level-based count
Step-Write 0xD 0x20   # clear TB flag

# --- P7: serial port, all 8 ACR[4:2] modes -----------------------------------
for ($m = 0; $m -le 7; $m++) {
    Step-Write 0xB ($m * 4)      # ACR[4:2]=m
    Step-Write 0xA 0xA5          # SR load
    Step-Read 0xA                # strobe SR -> trigger (both sides)
    if ($m -eq 3 -or $m -eq 7) { # "011"/"111": CB1-clocked modes
        for ($k = 0; $k -lt 6; $k++) { Set-Cb1 1; Step-Idle; Set-Cb1 0; Step-Idle }
    } else {
        Repeat 8 { Step-Idle }          # timer2/ce-clocked modes: free ce ticks
    }
    Step-Read 0xA                # SR readback
    Step-Read 0xD                # IFR: bit2 (SR)
    Step-Write 0xD 0x04          # clear SR flag
}

# --- P8: IFR matrix -----------------------------------------------------------
Step-Write 0xC 0x00   # PCR=0: rising detect on CA1/CB1
Set-Ca1 1; Repeat 2 { Step-Idle }; Set-Ca1 0
Repeat 3 { Step-Idle }
Step-Read 0xD          # expect bit0 set
Step-Write 0xD 0x7F   # clear ALL flags
Step-Read 0xD          # expect 0x00

Set-Cb1 1; Repeat 2 { Step-Idle }; Set-Cb1 0
Repeat 3 { Step-Idle }
Step-Write 0xD 0x08   # clear only CB1 bit
Step-Read 0xD          # expect 0x00

# --- P9: IRQ via Timer A one-shot + remaining write addresses -----------------
# The only way to get deterministic IRQ rows: enable the mask (P2 cleared it)
# and fire a 1-count one-shot. write_t1c_h (addr 5 write, F edge) loads
# count = DIN & latch(7..0); with latch LO=01 the overflow lands ~3 edges
# later and irq_flags bit6 stays set until IFR clears it.
Step-Write 0xF 0xA5   # ORA no-handshake (covers addr F write)
Step-Write 0x4 0x01   # TA LO latch = 01 (covers addr 4 write)
Step-Write 0xE 0xFF   # IER: set ALL mask bits (bit7=1: enable every source)
Step-Write 5 0x00     # load {00,01} -> overflow within a few F edges
Repeat 10 { Step-Idle }   # IRQ asserted here (>=5 rows with IRQ=1)
Step-Read 0xD          # IFR: expect bit6 (TA) set
Step-Write 0xD 0x40   # clear TA flag -> IRQ drops
Repeat 3 { Step-Idle }
Step-Read 0xD          # expect TA flag cleared

# --- emit ---------------------------------------------------------------------
$n = $stim.Count
if ($n % 2 -ne 0) { throw "internal: odd cycle count $n" }

$vhdl = New-Object System.Text.StringBuilder
[void]$vhdl.AppendLine('library ieee;')
[void]$vhdl.AppendLine('use ieee.std_logic_1164.all;')
[void]$vhdl.AppendLine('')
[void]$vhdl.AppendLine('package via6522_stim is')
[void]$vhdl.AppendLine("    constant STIM_COUNT : integer := $n;")
# 36-bit words (top bit always 0): hex literals must be a multiple of 4 bits.
[void]$vhdl.AppendLine('    type stim_arr_t is array (0 to STIM_COUNT - 1) of std_logic_vector(35 downto 0);')
[void]$vhdl.AppendLine('    constant STIM : stim_arr_t := (')
for ($i = 0; $i -lt $n; $i++) {
    $hex = ('{0:X9}' -f $stim[$i])
    if ($i -lt $n - 1) { [void]$vhdl.AppendLine("        X`"$hex`",") } else { [void]$vhdl.AppendLine("        X`"$hex`"") }
}
[void]$vhdl.AppendLine('    );')
[void]$vhdl.AppendLine('end package via6522_stim;')

$sv = New-Object System.Text.StringBuilder
[void]$sv.AppendLine('`timescale 1ns/1ps')
[void]$sv.AppendLine('package via6522_stim;')
[void]$sv.AppendLine("    localparam int STIM_COUNT = $n;")
# Const array with inline aggregate (packages cannot contain initial blocks).
[void]$sv.AppendLine("    localparam bit [35:0] STIM[STIM_COUNT] = '{")
for ($i = 0; $i -lt $n; $i++) {
    $hex = ('{0:X9}' -f $stim[$i])
    if ($i -lt $n - 1) { [void]$sv.AppendLine("        36'h$hex,") } else { [void]$sv.AppendLine("        36'h$hex") }
}
[void]$sv.AppendLine('    };')
[void]$sv.AppendLine('endpackage')

[System.IO.File]::WriteAllText((Join-Path $buildRoot 'stim_table.vhd'), $vhdl.ToString(), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $buildRoot 'stim_table.sv'), $sv.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "STIM OK cycles=$n vhdl=$(Join-Path $buildRoot 'stim_table.vhd') sv=$(Join-Path $buildRoot 'stim_table.sv')"
