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
-- PC is the full 16-bit program counter (4 hex digits). The T65 Regs port is
-- {PC[15:0], S[15:0], P, Y, X, A} = exactly 64 bits (T65.vhd line ~275; S is a
-- 16-bit register whose high byte stays FF). So P/Y/X/A live at
-- regs(31:24)/(23:16)/(15:8)/(7:0) and the SP column is the low byte of S.
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
  -- Static init from the generated package (pattern byte + phase-A program).
  -- GHDL 6.0.0 mcode corrupts nonblocking array updates when a second
  -- process drives the same array signal, so the seed must not be a process.
  signal ram : ram_vec_t := RAM_INIT;

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
    elsif ai >= 16#6B4C# and ai <= 16#6B51# then
      -- Boot preamble (phase B only): define A/X/Y deterministically at the
      -- reset vector before the pattern walk starts. The golden T65 resets
      -- only P; A/X/Y are 'U' in VHDL sim until first written, while Verilator
      -- zero-initializes them, so an immediate walk would desync on garbage
      -- ALU/indexed opcodes (simulation artifact, see PROGRESS.md). The walk
      -- then starts at $6B52.
      case ai - 16#6B4C# is
        when 0 => return x"A9";   -- LDA #$21
        when 1 => return x"21";
        when 2 => return x"A2";   -- LDX #$32
        when 3 => return x"32";
        when 4 => return x"A0";   -- LDY #$43
        when others => return x"43";
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



  stimulus : process
    file trace_output : text open write_mode is TRACE_FILE;
    variable trace_line : line;
    variable pc : std_logic_vector(15 downto 0);
    variable sp, pflag, y, x, aacc : std_logic_vector(7 downto 0);
    variable rw_b, nmi_b, irq_b : std_logic_vector(0 downto 0);
    variable total : integer;
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


      pc     := regs(63 downto 48);
      sp     := regs(39 downto 32);
      pflag  := regs(31 downto 24);
      y      := regs(23 downto 16);
      x      := regs(15 downto 8);
      aacc   := regs(7 downto 0);
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
