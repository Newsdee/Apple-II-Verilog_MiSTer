-- video_generator_vhdl_tb.vhd
--
-- Cycle-equivalence testbench (golden side) for the VHDL video_generator.
-- The candidate side is video_generator_verilog_tb.sv, which drives the
-- Verilog rtl/video_generator.v with the IDENTICAL stimulus schedule below
-- and writes the same CSV schema.
--
-- GHDL 6.0.0 in this build rejects ALL hierarchical instance selection
-- ("component instance cannot be selected by name" - verified with minimal
-- repros for entity, component, port and internal-signal cases, std 93c and
-- 08), so this bench traces PORTS ONLY. Internal state is recovered
-- behaviorally:
--   * The shift register shifts one bit per cycle while CLK_7M=0 (it holds
--     while CLK_7M=1). After a ROM load (LDPS_N=0, WNDW_N=0), bit k of the
--     loaded ROM byte appears on VIDEO (= NOT shiftreg(0)) within the next
--     8 cycles (a hold phase only repeats the current bit, never skips one).
--   * The schedule uses 25-cycle blocks (odd, so SEGA/SEGB/SEGC and DL(5:0)
--     vary between loads): 1 load + 24 shifts/holds.
--
-- Machine model:
--   * No reset exists in this module. Cycles 0-24 are a synchronization
--     window (WNDW_N=1, load at 0 -> shift register <= FF), so VIDEO is
--     defined from the first traced cycle (4).
--   * CLK_7M is generated identically on both sides: toggled at the falling
--     edge when cycle mod 14 = 0. The DUT therefore sees CLK_7M=0 (shift)
--     for (N mod 28) in 14..27 and CLK_7M=1 (hold) for (N mod 28) in 0..13.
--   * The spram ROM is the GHDL-safe constant-array shim (shared/spram_const.vhd,
--     video2.mif segment); the runner analyzes it instead of rtl/spram.vhd.
--
-- Stimulus schedule (driven at the falling edge of cycle N, both sides):
--   ldps_n    = 0 when (N mod 25) = 0 else 1
--   wndw_n    = 1 when N < 25 or 100 <= N <= 124 else 0
--   dl        = (N * 7) mod 256
--   sega      = N mod 2
--   segb      = (N / 2) mod 2
--   segc      = (N / 4) mod 2
--   gr2       = (N / 8) mod 2
--   altchar   = (N / 16) mod 2
--   romswitch = (N / 64) mod 2
--   flash_clk = (N / 32) mod 2
--   ioctl     : N in 504..513 -> wr=1, addr=0x00234, data=(N*3) mod 256
--               (last write N=513 -> data 0x03)
--   readback  : N in 748..773 -> force video_rom_input_addr = 0x234 via
--               romswitch=0, gr2=0, altchar=1, flash_clk=0, dl=0x46,
--               segc=1, segb=0, sega=0 (address math verified by script).
--               The load at N=750 (25|750) reads q latched from
--               addr(749)=0x234; expected byte 0x03.
--   romswitch : N in 799..975 -> force addr = 0x118 (romswitch=0 for
--               799..822) / 0x1118 (romswitch=1 for 823..975) via
--               gr2=0, altchar=0, flash_clk=0, dl=0x23, segc=0, segb=0,
--               sega=0. Load at 800 reads ROM[0x118]=0x38; load at 950
--               reads ROM[0x1118]=0x14 (the halves differ there).
--
-- NOTE on load effectiveness: a load only takes effect when CLK_7M=0 at
-- the rising edge, i.e. for (N mod 28) in 14..27. Loads at 0, 125, 825,
-- 850, 875, 900, 925 are blocked by the hold phase; the effective loads
-- used by the gates are 25 (FF sync), 100 (FF), 750, 800, 950.
--
-- Trace (sampled at rising edge + 1 ns, from cycle 4):
--   CYCLE, VIDEO, LDPS_N, WNDW_N, DL, MODE
--   MODE = ROMSWITCH GR2 ALTCHAR FLASH_CLK SEGC SEGB SEGA (7 bits, 1 hex digit)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity video_generator_vhdl_tb is
  generic (
    TRACE_FILE : string := "module_tests/video_generator/build/vhdl_trace.csv"
  );
end entity;

architecture test of video_generator_vhdl_tb is
  signal clk_14m    : std_logic := '0';
  signal clk_7m     : std_logic := '0';
  signal altchar    : std_logic := '0';
  signal romswitch  : std_logic := '0';
  signal gr2        : std_logic := '0';
  signal sega       : std_logic := '0';
  signal segb       : std_logic := '0';
  signal segc       : std_logic := '0';
  signal wndw_n     : std_logic := '1';
  signal dl         : unsigned(7 downto 0) := (others => '0');
  signal ldps_n     : std_logic := '1';
  signal ioctl_addr : std_logic_vector(24 downto 0) := (others => '0');
  signal ioctl_data : std_logic_vector(7 downto 0) := (others => '0');
  signal ioctl_wr   : std_logic := '0';
  signal flash_clk  : std_logic := '0';
  signal video_out  : std_logic;
begin
  clk_14m <= not clk_14m after 5 ns;

  dut : entity work.video_generator
    port map (
      CLK_14M    => clk_14m,
      CLK_7M     => clk_7m,
      ALTCHAR    => altchar,
      ROMSWITCH  => romswitch,
      GR2        => gr2,
      SEGA       => sega,
      SEGB       => segb,
      SEGC       => segc,
      WNDW_N     => wndw_n,
      DL         => dl,
      LDPS_N     => ldps_n,
      ioctl_addr => ioctl_addr,
      ioctl_data => ioctl_data,
      ioctl_wr   => ioctl_wr,
      FLASH_CLK  => flash_clk,
      VIDEO      => video_out
    );

  stimulus : process
    file trace_output : text open write_mode is TRACE_FILE;
    variable trace_line : line;
    variable mode_bits  : std_logic_vector(6 downto 0);
    variable one_bit    : std_logic_vector(3 downto 0);
    variable cyc        : integer;
  begin
    write(trace_line, string'("CYCLE,VIDEO,LDPS_N,WNDW_N,DL,MODE"));
    writeline(trace_output, trace_line);

    for cyc in 0 to 1023 loop
      wait until falling_edge(clk_14m);

      -- General schedule (see header for the identical Verilog schedule).
      ldps_n    <= '1';
      wndw_n    <= '0';
      dl        <= to_unsigned((cyc * 7) mod 256, 8);
      sega      <= '0'; segb <= '0'; segc <= '0';
      gr2       <= '0'; altchar <= '0';
      romswitch <= '0'; flash_clk <= '0';
      ioctl_wr  <= '0'; ioctl_addr <= (others => '0'); ioctl_data <= (others => '0');

      if (cyc mod 25) = 0 then ldps_n <= '0'; end if;
      if (cyc mod 2) = 1 then sega <= '1'; end if;
      if (cyc / 2) mod 2 = 1 then segb <= '1'; end if;
      if (cyc / 4) mod 2 = 1 then segc <= '1'; end if;
      if (cyc / 8) mod 2 = 1 then gr2 <= '1'; end if;
      if (cyc / 16) mod 2 = 1 then altchar <= '1'; end if;
      if (cyc / 64) mod 2 = 1 then romswitch <= '1'; end if;
      if (cyc / 32) mod 2 = 1 then flash_clk <= '1'; end if;
      if cyc <= 49 or (cyc >= 100 and cyc <= 124) then wndw_n <= '1'; end if;
      if cyc >= 504 and cyc <= 513 then
        ioctl_wr   <= '1';
        ioctl_addr <= '0' & x"000234";
        ioctl_data <= std_logic_vector(to_unsigned((cyc * 3) mod 256, 8));
      end if;
      if cyc >= 748 and cyc <= 773 then
        -- Readback window: force video_rom_input_addr = 0x234.
        romswitch <= '0'; gr2 <= '0'; altchar <= '1'; flash_clk <= '0';
        dl <= x"46"; segc <= '1'; segb <= '0'; sega <= '0';
      end if;
      if cyc >= 799 and cyc <= 975 then
        -- ROMSWITCH window: force addr = 0x118 / 0x1118.
        romswitch <= '0'; gr2 <= '0'; altchar <= '0'; flash_clk <= '0';
        dl <= x"23"; segc <= '0'; segb <= '0'; sega <= '0';
        if cyc >= 823 then romswitch <= '1'; end if;
      end if;
      if cyc mod 14 = 0 then clk_7m <= not clk_7m; end if;

      wait until rising_edge(clk_14m);
      wait for 1 ns;

      if cyc >= 4 then
        mode_bits := romswitch & gr2 & altchar & flash_clk & segc & segb & sega;
        one_bit := "000" & video_out;
        write(trace_line, cyc);
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & ldps_n;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & wndw_n;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        write(trace_line, string'(",")); write(trace_line, to_hstring(std_logic_vector(dl)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(mode_bits));
        writeline(trace_output, trace_line);
      end if;
    end loop;

    report "VHDL trace complete" severity note;
    std.env.finish;
  end process;
end architecture;
