-- apple2_vhdl_tb.vhd
--
-- Cycle-equivalence testbench for the VHDL `apple2` full core (golden side),
-- taken from Apple-II_MiSTer_newsdee/rtl.  The candidate side is
-- module_tests/apple2/apple2_verilog_tb.sv, which drives the Verilog `apple2`
-- module with the identical stimulus schedule below and writes the same CSV
-- schema.
--
-- Run with CWD = Apple-II-Verilog_MiSTer (the runner does Push-Location) so
-- that "rtl/roms/apple2e.mif" (main ROM, via work.spram) resolves.
--
-- GHDL shims used on this side (test-side only, never used by Quartus):
--   * module_tests/shared/spram_const.vhd  -> work.spram (constant-array ROM)
--   * module_tests/apple2/timing_generator_init.vhd
--       -> work.timing_generator.  The original timing_generator.vhd has no
--          reset; under GHDL its uninitialized registers start as 'U' and can
--          never self-start, while Verilator zero-initializes them.  The shim
--          is a byte-identical copy with explicit zero initial values added
--          to the same registers Verilator zeroes (init-only diff).
--   * module_tests/apple2/ramcard_stub.vhd -> work.ramcard.  The reference
--          project ships ramcard only as Verilog; this is a cycle-exact VHDL
--          translation matching the component declaration in apple2.vhd.
--   * module_tests/apple2/video_generator_ent.vhd, apple2_ent.vhd
--       -> one-word copies of the reference files ('entity work.spram'
--          direct entity instantiation; Quartus accepts the keyword-less form,
--          GHDL requires it).  No behavioral change.
--   * module_tests/apple2/R65C02_ent.vhd -> copy of reference R65Cx2.vhd with
--          the opcodeInfoTable rows resolved to explicit unsigned literals
--          (GHDL rejects the mixed string/unsigned &-chains); each row is
--          bit-identical.  Created by make_R65C02_ent.ps1 (kept for audit).
--
-- Machine model (identical to the Verilog bench):
--   * Main/aux RAM is a stateless deterministic function of ADDR (low byte and
--     high byte use different functions so aux misrouting is observable).
--     A few small regions hold the CPU program this harness executes.
--   * Slot 1 (C1xx) serves the Phase A program from PD.
--   * Main RAM holds a JMP $C100 at $5857: the real ROM boot path always
--     reaches $5857 (RTS from the FE84 subroutine), handing control to Phase A.
--   * C3ROM resets to 0, so C3xx reads hit main ROM (not PD); the NMI vector
--     ($C3FA) therefore executes the real IIe NMI handler (BIT $C015 / STA
--     $C007 / CLD / SEI / JSR $0101), which then falls into the deterministic
--     pattern code in main RAM at $0101.
--   * All other slot reads return a deterministic f(cycle, ADDR).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity apple2_vhdl_tb is
  generic (
    TRACE_FILE : string := "module_tests/apple2/build/vhdl_trace.csv"
  );
end entity apple2_vhdl_tb;

architecture test of apple2_vhdl_tb is
  -- Shared constants (must match apple2_verilog_tb.sv exactly)
  constant TOTAL        : integer := 320000;
  constant TRACE_START  : integer := 256;
  constant DENSE_END    : integer := 3000;
  constant SPARSE_BASE  : integer := 8128;   -- sparse rows at SPARSE_BASE + 16k
  constant RESET_CYCLES : integer := 64;
  constant WAIT_LO      : integer := 2600;
  constant WAIT_HI      : integer := 2615;
  constant NMI_LO       : integer := 8000;
  constant NMI_HI       : integer := 8009;
  constant AKD_LO       : integer := 100;
  constant AKD_HI       : integer := 500;
  constant IOCTL_LO     : integer := 12000;
  constant IOCTL_HI     : integer := 12120;
  constant IOCTL_Q      : integer := 30;
  constant ROMSW_AT     : integer := 250000;
  constant FLASH_P      : integer := 30000;
  constant NMI_TRACE_LO : integer := 7990;   -- dense trace window around the NMI pulse
  constant NMI_TRACE_HI : integer := 8120;

  type byte_vec_t is array (natural range <>) of std_logic_vector(7 downto 0);

  -- Phase A program (full C1xx page, 256 bytes).  Code occupies C100-C152;
  -- the rest is NOP padding.  Note: $C800 is read before $C300 because any
  -- C3xx read with C3ROM=0 latches C8ROM=1 in the core, which would route
  -- later C8xx-CFxx reads to ROM instead of generating IO_STROBE.
  constant PHASE_A : byte_vec_t(0 to 255) := (
    x"38", x"A9", x"00", x"8D", x"06", x"C0", x"A9", x"00",
    x"8D", x"FF", x"C0", x"A9", x"42", x"8D", x"00", x"01",
    x"AD", x"00", x"01", x"A9", x"55", x"8D", x"55", x"C0",
    x"AD", x"1C", x"C0", x"29", x"80", x"D0", x"05", x"4C",
    x"A0", x"05", x"EA", x"EA", x"A9", x"0D", x"8D", x"0D",
    x"C0", x"AD", x"1F", x"C0", x"29", x"80", x"D0", x"05",
    x"4C", x"A0", x"05", x"EA", x"EA", x"A9", x"01", x"8D",
    x"01", x"C0", x"AD", x"18", x"C0", x"29", x"80", x"D0",
    x"05", x"4C", x"A0", x"05", x"EA", x"EA", x"AD", x"00",
    x"C1", x"AD", x"00", x"C8", x"AD", x"00", x"C3", x"4C",
    x"40", x"05", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA",
    x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA", x"EA"
  );

  -- Phase B program, held in main RAM at $0540-$056E (47 bytes)
  constant PHASE_B : byte_vec_t(0 to 46) := (
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

  -- Main RAM low byte: deterministic function of ADDR with program overrides.
  function main_byte(a : unsigned) return std_logic_vector is
    variable ai : integer;
  begin
    ai := to_integer(a);
    if ai >= 16#5857# and ai <= 16#585B# then
      -- Boot handoff: the ROM boot path always reaches $5857.
      case ai - 16#5857# is
        when 0 => return x"4C";
        when 1 => return x"00";
        when 2 => return x"C1";
        when others => return x"EA";
      end case;
    elsif ai >= 16#0540# and ai <= 16#056E# then
      return PHASE_B(ai - 16#0540#);
    elsif ai >= 16#0580# and ai <= 16#0582# then
      -- Normal park: JMP $0580
      case ai - 16#0580# is
        when 0 => return x"4C";
        when 1 => return x"80";
        when others => return x"05";
      end case;
    elsif ai >= 16#05A0# and ai <= 16#05A2# then
      -- Error park: JMP $05A0
      case ai - 16#05A0# is
        when 0 => return x"4C";
        when 1 => return x"A0";
        when others => return x"05";
      end case;
    else
      return std_logic_vector(to_unsigned((ai + ai/16 + 60) mod 256, 8));
    end if;
  end function main_byte;

  -- Low 7 bits of (a XOR b); matches Verilog bench: ((cycle/16) ^ 8'h55) & 8'h7F
  function xor7(a : natural; b : natural) return std_logic_vector is
    variable va : std_logic_vector(6 downto 0);
    variable vb : std_logic_vector(6 downto 0);
  begin
    va := std_logic_vector(to_unsigned(a mod 128, 7));
    vb := std_logic_vector(to_unsigned(b mod 128, 7));
    return va xor vb;
  end function xor7;

  -- DUT signals
  signal clk_14m    : std_logic := '0';
  signal flash_clk  : std_logic := '0';
  signal reset      : std_logic := '1';
  signal cpu        : std_logic := '0';
  signal romswitch  : std_logic := '0';
  signal palmode    : std_logic := '0';
  signal cpu_wait   : std_logic := '0';
  signal nmi_n      : std_logic := '1';
  signal irq_n      : std_logic := '1';
  signal akd        : std_logic := '0';
  signal k          : unsigned(7 downto 0) := (others => '0');
  signal gameport   : std_logic_vector(7 downto 0) := (others => '0');
  signal pd         : unsigned(7 downto 0) := (others => '0');
  signal ram_do     : unsigned(15 downto 0) := (others => '0');
  signal saturn_5_inslot : std_logic := '0';
  signal ioctl_addr   : std_logic_vector(24 downto 0) := (others => '0');
  signal ioctl_data   : std_logic_vector(7 downto 0) := (others => '0');
  signal ioctl_index  : std_logic_vector(7 downto 0) := (others => '0');
  signal ioctl_download : std_logic := '0';
  signal ioctl_wr     : std_logic := '0';

  -- DUT outputs (types must match the apple2 entity port types exactly)
  signal addr        : unsigned(15 downto 0);
  signal ram_addr    : unsigned(17 downto 0);
  signal d           : unsigned(7 downto 0);
  signal ram_we      : std_logic;
  signal cpu_we      : std_logic;
  signal io_select   : std_logic_vector(7 downto 0);
  signal device_select : std_logic_vector(7 downto 0);
  signal io_strobe   : std_logic;
  signal speaker     : std_logic;
  signal dbg_t65_regs : std_logic_vector(63 downto 0);
  signal dbg_di       : std_logic_vector(7 downto 0);
  signal dbg_rom_addr : std_logic_vector(13 downto 0);
  signal dbg_rom_out  : std_logic_vector(7 downto 0);
  signal video       : std_logic;
  signal color_line  : std_logic;
  signal hbl         : std_logic;
  signal vbl         : std_logic;
  signal text_mode   : std_logic;
  signal phase_zero  : std_logic;
  signal phase_zero_r : std_logic;
  signal phase_zero_f : std_logic;
  signal aux         : std_logic;
  signal read_key    : std_logic;
  signal an          : std_logic_vector(3 downto 0);
  signal pdl_strobe  : std_logic;
  signal stb         : std_logic;
  signal clk_2m      : std_logic;

begin

  dut : entity work.apple2
    port map (
      CLK_14M => clk_14m,
      CLK_2M => clk_2m,
      PALMODE => palmode,
      ROMSWITCH => romswitch,
      CPU_WAIT => cpu_wait,
      PHASE_ZERO => phase_zero,
      PHASE_ZERO_R => phase_zero_r,
      PHASE_ZERO_F => phase_zero_f,
      FLASH_CLK => flash_clk,
      reset => reset,
      cpu => cpu,
      ADDR => addr,
      ram_addr => ram_addr,
      D => d,
      ram_do => ram_do,
      aux => aux,
      PD => pd,
      CPU_WE => cpu_we,
      IRQ_n => irq_n,
      NMI_n => nmi_n,
      ram_we => ram_we,
      VIDEO => video,
      COLOR_LINE => color_line,
      TEXT_MODE => text_mode,
      HBL => hbl,
      VBL => vbl,
      K => k,
      READ_KEY => read_key,
      AKD => akd,
      AN => an,
      GAMEPORT => gameport,
      PDL_STROBE => pdl_strobe,
      STB => stb,
      IO_SELECT => io_select,
      DEVICE_SELECT => device_select,
      IO_STROBE => io_strobe,
      ioctl_addr => ioctl_addr,
      ioctl_data => ioctl_data,
      ioctl_index => ioctl_index,
      ioctl_download => ioctl_download,
      ioctl_wr => ioctl_wr,
      saturn_5_inslot => saturn_5_inslot,
      speaker => speaker,
      DBG_T65_REGS => dbg_t65_regs,
      DBG_DI => dbg_di,
      DBG_ROM_ADDR => dbg_rom_addr,
      DBG_ROM_OUT => dbg_rom_out
    );

  -- Stateless deterministic RAM: low and high bytes use different functions.
  ram_do(7 downto 0) <= unsigned(main_byte(addr));
  ram_do(15 downto 8) <= to_unsigned((to_integer(addr)*7 + 165) mod 256, 8);

  clk_14m <= not clk_14m after 5 ns;

  stimulus : process
    file trace_output : text open write_mode is TRACE_FILE;
    variable trace_line : line;
    variable q : integer;
    variable ai : integer;
  begin
    -- Column order must match apple2_verilog_tb.sv exactly.
    write(trace_line, string'("CYCLE,ADDR,D,RAM_ADDR,RAM_WE,AUX,CPU_WE,PD,IO_SELECT,DEVICE_SELECT,IO_STROBE,SPEAKER,VIDEO,PHASE_ZERO,PHASE_ZERO_R,PHASE_ZERO_F,ROMSWITCH,PALMODE,CPU_WAIT,NMI_N,T65_REGS,T65_DI,ROM_ADDR,ROM_OUT"));
    writeline(trace_output, trace_line);

    for cycle in 0 to TOTAL-1 loop
      wait until falling_edge(clk_14m);

      reset <= '1' when cycle < RESET_CYCLES else '0';
      romswitch <= '1' when cycle >= ROMSW_AT else '0';
      cpu_wait <= '1' when cycle >= WAIT_LO and cycle < WAIT_HI else '0';
      nmi_n <= '0' when cycle >= NMI_LO and cycle < NMI_HI else '1';
      akd <= '1' when cycle >= AKD_LO and cycle < AKD_HI else '0';
      flash_clk <= '1' when (cycle / FLASH_P) mod 2 = 1 else '0';
      k(7) <= '0';
      k(6 downto 0) <= to_unsigned(cycle/4 mod 128, 7);
      gameport(7) <= '0';
      gameport(6 downto 0) <= xor7(cycle/16, 85);

      if cycle >= IOCTL_LO and cycle < IOCTL_HI then
        q := (cycle - IOCTL_LO) / IOCTL_Q;
        ioctl_download <= '1';
        case q mod 4 is
          when 0 =>
            ioctl_data <= x"DE";
          when 1 =>
            ioctl_data <= x"AD";
          when 2 =>
            ioctl_data <= x"BE";
          when others =>
            ioctl_data <= x"EF";
        end case;
        ioctl_addr <= std_logic_vector(to_unsigned(240 + q, 25));
        ioctl_index <= x"01";
        ioctl_wr <= '1';
      else
        ioctl_download <= '0';
        ioctl_wr <= '0';
        ioctl_index <= x"00";
        ioctl_data <= x"00";
        ioctl_addr <= (others => '0');
      end if;

      -- PD: slot 1 = Phase A, all other slot reads = deterministic pattern.
      ai := to_integer(addr);
      if io_select(0) = '1' and ai >= 16#C100# and ai <= 16#C1FF# then
        pd <= unsigned(PHASE_A(ai - 16#C100#));
      else
        pd <= to_unsigned((cycle/3 + 7*ai) mod 256, 8);
      end if;

      wait until rising_edge(clk_14m);
      wait for 1 ns;

      if (cycle >= TRACE_START and cycle <= DENSE_END) or
         (cycle >= NMI_TRACE_LO and cycle <= NMI_TRACE_HI) or
         (cycle >= SPARSE_BASE and (cycle - SPARSE_BASE) mod 16 = 0) then
        write(trace_line, cycle);
        write(trace_line, string'(",")); write(trace_line, to_hstring(addr));
        write(trace_line, string'(",")); write(trace_line, to_hstring(d));
        write(trace_line, string'(",")); write(trace_line, to_hstring(ram_addr));
        write(trace_line, string'(",")); write(trace_line, ram_we);
        write(trace_line, string'(",")); write(trace_line, aux);
        write(trace_line, string'(",")); write(trace_line, cpu_we);
        write(trace_line, string'(",")); write(trace_line, to_hstring(pd));
        write(trace_line, string'(",")); write(trace_line, to_hstring(io_select));
        write(trace_line, string'(",")); write(trace_line, to_hstring(device_select));
        write(trace_line, string'(",")); write(trace_line, io_strobe);
        write(trace_line, string'(",")); write(trace_line, speaker);
        write(trace_line, string'(",")); write(trace_line, video);
        write(trace_line, string'(",")); write(trace_line, phase_zero);
        write(trace_line, string'(",")); write(trace_line, phase_zero_r);
        write(trace_line, string'(",")); write(trace_line, phase_zero_f);
        write(trace_line, string'(",")); write(trace_line, romswitch);
        write(trace_line, string'(",")); write(trace_line, palmode);
        write(trace_line, string'(",")); write(trace_line, cpu_wait);
        write(trace_line, string'(",")); write(trace_line, nmi_n);
        write(trace_line, string'(",")); write(trace_line, to_hstring(dbg_t65_regs));
        write(trace_line, string'(",")); write(trace_line, to_hstring(dbg_di));
        write(trace_line, string'(",")); write(trace_line, to_hstring(dbg_rom_addr));
        write(trace_line, string'(",")); write(trace_line, to_hstring(dbg_rom_out));
        writeline(trace_output, trace_line);
      end if;
    end loop;

    file_close(trace_output);
    std.env.stop;
  end process stimulus;

end architecture test;
