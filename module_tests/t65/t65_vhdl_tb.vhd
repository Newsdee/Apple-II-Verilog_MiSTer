-- T65 (VHDL golden) vs t65 (Verilog candidate) cycle-equivalence testbench.
--
-- Instantiates the VHDL T65 from ../Apple-II_MiSTer_newsdee/rtl/t65/ with:
--   * Mode="00" (6502), BCD_en default '1', Rdy/Abort_n/SO_n tied high —
--     exactly the connections used by rtl/apple2.vhd.
--   * Combinational ROM ($F000-$FFFF from apple2e.hex, generated constant) and
--     RAM ($0000-$EFFF). Enable is continuously high, so each core clock is one
--     T65 microstep. This reproduces the full-core instruction stream: the full
--     core uses a 1-cycle-latency ROM but only steps the CPU every 14th cycle,
--     so the read data always settles within the step (same address/data pipeline).
--
-- PHASE=0 ("prog", 320 cycles): real writable RAM seeded with the deterministic
--   pattern byte plus a test program at $0500-$054D exercising SBC/ADC flags,
--   taken and not-taken branches, zero-page/absolute X transfers, JSR/RTS, CLI,
--   then an IRQ pulse (120-124) and NMI pulse (200-204). ROM reset vector is
--   overridden to $0500.
-- PHASE=1 ("boot", 500 cycles): stateless RAM — the exact main_byte() model of
--   module_tests/apple2 (including its program override regions), pure apple2e
--   ROM, no stimulus after reset release. Reproduces the known full-core
--   apple2 finding environment (reset vector $6B4C, boot into ROM $FE8x).
--
-- Trace columns (must match t65_verilog_tb.sv exactly):
--   CYCLE,PC,SP,P,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N
-- P bits follow T65_Pack: C=0,Z=1,I=2,D=3,B=4,V=6,N=7.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.t65_rom_array.all;

entity t65_vhdl_tb is
  generic (
    PHASE      : integer := 0;
    TRACE_FILE : string  := "module_tests/t65/build/vhdl_prog.csv"
  );
end entity;

architecture test of t65_vhdl_tb is
  constant TOTAL_A : integer := 320;
  constant TOTAL_B : integer := 500;

  type byte_vec_t is array (natural range <>) of std_logic_vector(7 downto 0);

  -- Phase B program override region, copied verbatim from apple2_vhdl_tb.vhd.
  constant PHASE_B_PROG : byte_vec_t(0 to 46) := (
    x"A9", x"37",             -- 0540 LDA #$37
    x"8D", x"60", x"06",      -- 0542 STA $0660   AUX RAM write
    x"AD", x"60", x"06",      -- 0545 LDA $0660   AUX RAM read
    x"A9", x"5A",             -- 0548 LDA #$5A
    x"8D", x"20", x"02",      -- 054A STA $0220   main RAM write
    x"AD", x"20", x"02",      -- 054D LDA $0220   main RAM read
    x"A9", x"6B",             -- 0550 LDA #$6B
    x"8D", x"30", x"C0",      -- 0552 STA $C030   speaker toggle
    x"AD", x"00", x"C0",      -- 0555 LDA $C000   keyboard read
    x"AD", x"60", x"C0",      -- 0558 LDA $C060   gameport read
    x"AD", x"70", x"C0",      -- 055B LDA $C070   PDL (floating bus)
    x"AD", x"40", x"C0",      -- 055E LDA $C040   STB (floating bus)
    x"AD", x"90", x"C0",      -- 0561 LDA $C090   devselect read
    x"8D", x"90", x"C0",      -- 0564 STA $C090   devselect write
    x"AD", x"00", x"C2",      -- 0567 LDA $C200   ioselect(2) read
    x"A9", x"77",             -- 056A LDA #$77
    x"4C", x"80", x"05"       -- 056C JMP $0580   normal park
  );

  signal clk : std_logic := '0';
  signal res_n  : std_logic;
  signal irq_n  : std_logic;
  signal nmi_n  : std_logic;
  signal rw_n   : std_logic;
  signal a24    : std_logic_vector(23 downto 0);
  signal di     : std_logic_vector(7 downto 0);
  signal do_sig : std_logic_vector(7 downto 0);
  signal regs   : std_logic_vector(63 downto 0);

  -- Real RAM, $0000-$EFFF (phase A). Phase B never reads it.
  type ram_vec_t is array (0 to 6143) of std_logic_vector(7 downto 0);
  signal ram : ram_vec_t := (others => (others => '0'));

  -- Stateless pattern RAM, copied verbatim from apple2_vhdl_tb.vhd main_byte.
  function main_byte(a : unsigned) return std_logic_vector is
    variable ai : integer;
  begin
    ai := to_integer(a);
    if ai >= 16#5857# and ai <= 16#585B# then
      case ai - 16#5857# is
        when 0 => return x"4C";
        when 1 => return x"00";
        when 2 => return x"C1";
        when others => return x"EA";
      end case;
    elsif ai >= 16#0540# and ai <= 16#056E# then
      return PHASE_B_PROG(ai - 16#0540#);
    elsif ai >= 16#0580# and ai <= 16#0582# then
      case ai - 16#0580# is
        when 0 => return x"4C";
        when 1 => return x"80";
        when others => return x"05";
      end case;
    elsif ai >= 16#05A0# and ai <= 16#05A2# then
      case ai - 16#05A0# is
        when 0 => return x"4C";
        when 1 => return x"A0";
        when others => return x"05";
      end case;
    else
      return std_logic_vector(to_unsigned((ai + ai/16 + 60) mod 256, 8));
    end if;
  end function main_byte;

  -- ROM byte with the phase-A reset-vector override ($FFC/$FFD -> $0500).
  function rom_byte(i : integer) return std_logic_vector is
  begin
    if PHASE = 0 then
      if i = 16#FFC# then return x"00"; end if;
      if i = 16#FFD# then return x"05"; end if;
    end if;
    return ROM_DATA(i);
  end function rom_byte;

begin
  clk <= not clk after 5 ns;

  dut : entity work.T65
    port map (
      Mode    => "00",
      Res_n   => res_n,
      Enable  => '1',
      Clk     => clk,
      Rdy     => '1',
      Abort_n => '1',
      SO_n    => '1',
      IRQ_n   => irq_n,
      NMI_n   => nmi_n,
      R_W_n   => rw_n,
      A       => a24,
      DI      => di,
      DO      => do_sig,
      Regs    => regs
    );

  gen_phase_a : if PHASE = 0 generate
    di <= rom_byte(to_integer(unsigned(a24(15 downto 0))) - 16#F000#)
           when unsigned(a24(15 downto 0)) >= 16#F000#
         else ram(to_integer(unsigned(a24(15 downto 0))));

    -- Commit writes at the end of the step in which RW_n is low (the write
    -- strobe is registered inside T65, so it is stable for the whole step).
    process(clk)
    begin
      if rising_edge(clk) then
        if rw_n = '0' and unsigned(a24(15 downto 0)) < 16#F000# then
          ram(to_integer(unsigned(a24(15 downto 0)))) <= do_sig;
        end if;
      end if;
    end process;
  end generate gen_phase_a;

  gen_phase_b : if PHASE = 1 generate
    di <= rom_byte(to_integer(unsigned(a24(15 downto 0))) - 16#F000#)
           when unsigned(a24(15 downto 0)) >= 16#F000#
         else main_byte(unsigned(a24(15 downto 0)));
  end generate gen_phase_b;

  -- Phase A RAM seed: pattern byte everywhere, then the test program.
  ram_init : process
  begin
    if PHASE = 0 then
      for i in 0 to 6143 loop
        ram(i) <= std_logic_vector(to_unsigned((i + i/16 + 60) mod 256, 8));
      end loop;
      -- $0500: A9 05   LDA #$05
      ram(16#0500# - 0) <= x"A9"; ram(16#0501#) <= x"05";
      -- $0502: 18      CLC
      ram(16#0502#) <= x"18";
      -- $0503: E9 07   SBC #$07   (A=FD C=0 N=1)
      ram(16#0503#) <= x"E9"; ram(16#0504#) <= x"07";
      -- $0505: 69 03   ADC #$03   (A=00 C=1 Z=1)
      ram(16#0505#) <= x"69"; ram(16#0506#) <= x"03";
      -- $0507: 38      SEC
      ram(16#0507#) <= x"38";
      -- $0508: 69 FF   ADC #$FF   (A=00 C=1 Z=1 V=0)
      ram(16#0508#) <= x"69"; ram(16#0509#) <= x"FF";
      -- $050A: A9 7F   LDA #$7F
      ram(16#050A#) <= x"A9"; ram(16#050B#) <= x"7F";
      -- $050C: 69 00   ADC #$00   (A=80 N=1 V=1 C=0)
      ram(16#050C#) <= x"69"; ram(16#050D#) <= x"00";
      -- $050E: B8      CLV
      ram(16#050E#) <= x"B8";
      -- $050F: A9 00   LDA #$00   (Z=1)
      ram(16#050F#) <= x"A9"; ram(16#0510#) <= x"00";
      -- $0511: F0 03   BEQ +3 -> $0516 (taken)
      ram(16#0511#) <= x"F0"; ram(16#0512#) <= x"03";
      -- $0513/$0514: EA EA  (must never execute)
      ram(16#0513#) <= x"EA"; ram(16#0514#) <= x"EA";
      -- $0516: A9 01   LDA #$01   (Z=0)
      ram(16#0516#) <= x"A9"; ram(16#0517#) <= x"01";
      -- $0518: D0 03   BNE +3 -> $051D (taken)
      ram(16#0518#) <= x"D0"; ram(16#0519#) <= x"03";
      -- $051A/$051B: EA EA  (must never execute)
      ram(16#051A#) <= x"EA"; ram(16#051B#) <= x"EA";
      -- $051D: A9 01   LDA #$01   (Z=0)
      ram(16#051D#) <= x"A9"; ram(16#051E#) <= x"01";
      -- $051F: F0 FE   BEQ -2 (not taken; if taken it would self-loop)
      ram(16#051F#) <= x"F0"; ram(16#0520#) <= x"FE";
      -- $0521: A9 02   LDA #$02
      ram(16#0521#) <= x"A9"; ram(16#0522#) <= x"02";
      -- $0523: 85 34   STA $34
      ram(16#0523#) <= x"85"; ram(16#0524#) <= x"34";
      -- $0525: A5 34   LDA $34
      ram(16#0525#) <= x"A5"; ram(16#0526#) <= x"34";
      -- $0527: A2 0A   LDX #$0A
      ram(16#0527#) <= x"A2"; ram(16#0528#) <= x"0A";
      -- $0529: 8E 34 06 STX $0634
      ram(16#0529#) <= x"8E"; ram(16#052A#) <= x"34"; ram(16#052B#) <= x"06";
      -- $052C: AE 34 06 LDX $0634
      ram(16#052C#) <= x"AE"; ram(16#052D#) <= x"34"; ram(16#052E#) <= x"06";
      -- $052F: A0 05   LDY #$05
      ram(16#052F#) <= x"A0"; ram(16#0530#) <= x"05";
      -- $0531: 98      TYA
      ram(16#0531#) <= x"98";
      -- $0532: 20 49 05 JSR $0549 (pushes $0535, RTS returns to $0536)
      ram(16#0532#) <= x"20"; ram(16#0533#) <= x"49"; ram(16#0534#) <= x"05";
      -- $0535: EA      NOP (skipped by RTS+1)
      ram(16#0535#) <= x"EA";
      -- $0536: A9 77   LDA #$77   (resume point after RTS)
      ram(16#0536#) <= x"A9"; ram(16#0537#) <= x"77";
      -- $0538: 58      CLI
      ram(16#0538#) <= x"58";
      -- $0539: 4C 46 05 JMP $0546 (to park)
      ram(16#0539#) <= x"4C"; ram(16#053A#) <= x"46"; ram(16#053B#) <= x"05";
      -- $053C-$0545: EA padding
      for i in 16#053C# to 16#0545# loop
        ram(i) <= x"EA";
      end loop;
      -- $0546: 4C 46 05 JMP $0546 (park)
      ram(16#0546#) <= x"4C"; ram(16#0547#) <= x"46"; ram(16#0548#) <= x"05";
      -- $0549: A9 5A   LDA #$5A   (subroutine)
      ram(16#0549#) <= x"A9"; ram(16#054A#) <= x"5A";
      -- $054B: 48      PHA
      ram(16#054B#) <= x"48";
      -- $054C: 68      PLA
      ram(16#054C#) <= x"68";
      -- $054D: 60      RTS
      ram(16#054D#) <= x"60";
    end if;
    wait for 1 ns;
    report "SEED_DONE ram500=" & to_hstring(ram(16#0500#))
      & " ram501=" & to_hstring(ram(16#0501#))
      & " ram0=" & to_hstring(ram(0)) severity note;
    wait;
  end process ram_init;

  dbg_t0 : process
  begin
    wait for 1 ns;
    report "DBG_T0 ram500=" & to_hstring(ram(16#0500#))
      & " ram501=" & to_hstring(ram(16#0501#))
      & " ram0=" & to_hstring(ram(0))
      & " ramEFFF=" & to_hstring(ram(6143)) severity note;
    wait;
  end process dbg_t0;

  stimulus : process
    file trace_output : text open write_mode is TRACE_FILE;
    variable trace_line : line;
    variable pc, sp, pflag, y, x, aacc : std_logic_vector(7 downto 0);
    variable rw_b, nmi_b, irq_b : std_logic_vector(0 downto 0);
    variable total : integer;
    variable dbg_rw : string(1 to 1);
  begin
    if PHASE = 0 then total := TOTAL_A; else total := TOTAL_B; end if;

    write(trace_line, string'("CYCLE,PC,SP,P,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N"));
    writeline(trace_output, trace_line);

    for cycle in 0 to total - 1 loop
      wait until falling_edge(clk);

      res_n <= '0' when cycle < 4 else '1';
      if PHASE = 0 then
        irq_n <= '0' when (cycle >= 120 and cycle <= 124) else '1';
        nmi_n <= '0' when (cycle >= 200 and cycle <= 204) else '1';
      else
        irq_n <= '1';
        nmi_n <= '1';
      end if;

      wait until rising_edge(clk);
      wait for 1 ns;

      if cycle >= 11 and cycle <= 14 then
        if rw_n = '1' then dbg_rw := "1"; else dbg_rw := "0"; end if;
        report "DBG cyc=" & integer'image(cycle)
          & " a24=" & to_hstring(a24)
          & " di=" & to_hstring(di)
          & " ram500=" & to_hstring(ram(16#0500#))
          & " ram501=" & to_hstring(ram(16#0501#))
          & " ram0=" & to_hstring(ram(0))
          & " ram100=" & to_hstring(ram(100))
          & " ramEFFF=" & to_hstring(ram(6143))
          & " rw=" & (dbg_rw) severity note;
      end if;

      pc     := regs(63 downto 56);
      sp     := regs(55 downto 48);
      pflag  := regs(47 downto 40);
      y      := regs(39 downto 32);
      x      := regs(31 downto 24);
      aacc   := regs(23 downto 16);
      rw_b   := (others => rw_n);
      nmi_b  := (others => nmi_n);
      irq_b  := (others => irq_n);

      write(trace_line, cycle);
      write(trace_line, string'(",")); write(trace_line, to_hstring(pc));
      write(trace_line, string'(",")); write(trace_line, to_hstring(sp));
      write(trace_line, string'(",")); write(trace_line, to_hstring(pflag));
      write(trace_line, string'(",")); write(trace_line, to_hstring(y));
      write(trace_line, string'(",")); write(trace_line, to_hstring(x));
      write(trace_line, string'(",")); write(trace_line, to_hstring(aacc));
      write(trace_line, string'(",")); write(trace_line, to_hstring(a24(15 downto 0)));
      write(trace_line, string'(",")); write(trace_line, to_hstring(di));
      write(trace_line, string'(",")); write(trace_line, to_hstring(do_sig));
      write(trace_line, string'(",")); write(trace_line, to_hstring(rw_b));
      write(trace_line, string'(",")); write(trace_line, to_hstring(nmi_b));
      write(trace_line, string'(",")); write(trace_line, to_hstring(irq_b));
      writeline(trace_output, trace_line);
    end loop;

    report "VHDL trace complete (phase=" & integer'image(PHASE) & ")" severity note;
    std.env.finish;
  end process;
end architecture;
