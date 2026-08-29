-- timing_generator_vhdl_tb.vhd
--
-- Cycle-equivalence testbench (golden side) for the VHDL timing_generator.
-- The candidate side is timing_generator_verilog_tb.sv with the IDENTICAL
-- stimulus schedule and CSV schema.
--
-- PHASE generic: 0 = NTSC (PALMODE=0), 1 = PAL (PALMODE=1). Each phase is
-- a separate run (the runner elaborates/runs both); the two phases let the
-- V wrap (V: 511 -> V_RESET) be observed, where V_RESET differs:
--   NTSC: "011111010" (126)   PAL: "011001000" (104)
-- V(5:3) of the post-wrap value (7 vs 6) appears on VIDEO_ADDRESS(9:7).
--
-- Initialization: the real module has NO reset. The runner analyzes a
-- generated copy (build/vhdl/timing_generator_golden.vhd) that is
-- byte-identical to the RTL except for explicit zero initial values on the
-- state signals the original leaves uninitialized (CLK_7M, COLOR_DELAY_N,
-- SEGA/SEGB/SEGC, GR1/GR2, HBLANK, VBLANK, WNDW_N, LDPS_N). GHDL starts
-- those at 'U' and 'U' propagates through the HAL network forever (verified
-- in the apple2 harness); Verilator zero-initializes all regs, so the shim
-- matches the candidate's power-on state exactly. No logic is changed.
--
-- The HAL network self-starts from the power-on state; H counts 64..127 and
-- V increments every 65 RASRISE1 ticks. V starts at 126, so the wrap at 511
-- happens after ~386 V increments (~25-40K CLK_14M cycles at the ~14-cycle
-- HAL period); TOTAL=500000 leaves wide margin.
--
-- Stimulus (driven at the falling edge of cycle N, identical on both sides):
--   PALMODE     = PHASE (constant for the run)
--   TEXT_MODE   = (N / 100000) mod 2
--   PAGE2       = (N / 50000)  mod 2
--   HIRES_MODE  = (N / 20000)  mod 2
--   MIXED_MODE  = (N / 15000)  mod 2
--   COL80       = (N / 8000)   mod 2
--   STORE80     = (N / 6000)   mod 2
--   DHIRES_MODE = (N / 4000)   mod 2
--   VID7        = (N / 2000)   mod 2
--
-- Trace (sampled at rising edge + 1 ns): every cycle for N < 2000, then
-- every 32nd cycle. Columns:
--   CYCLE, PHI0, Q3, RAS_N, AX, CAS_N, VID7M, COLOR_REF, PHI0_EN_R,
--   PHI0_EN_F, HBLANK, VBLANK, WNDW_N, LDPS_N, GR1, GR2, SEGA, SEGB,
--   SEGC, VIDEO_ADDRESS

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity timing_generator_vhdl_tb is
  generic (
    PHASE : integer := 0  -- 0 = NTSC, 1 = PAL
  );
end entity;

architecture test of timing_generator_vhdl_tb is
  constant TOTAL : integer := 800000;
  function trace_name(p : integer) return string is
  begin
    if p = 0 then return "module_tests/timing_generator/build/vhdl_ntsc.csv"; end if;
    return "module_tests/timing_generator/build/vhdl_pal.csv";
  end function;
  constant TRACE_FILE : string := trace_name(PHASE);
  signal clk_14m    : std_logic := '0';
  signal palmode    : std_logic;
  signal text_mode  : std_logic := '0';
  signal page2      : std_logic := '0';
  signal hires_mode : std_logic := '0';
  signal mixed_mode : std_logic := '0';
  signal col80      : std_logic := '0';
  signal store80    : std_logic := '0';
  signal dhires     : std_logic := '0';
  signal vid7       : std_logic := '0';
  signal vid7m      : std_logic;
  signal q3         : std_logic;
  signal ras_n      : std_logic;
  signal cas_n      : std_logic;
  signal ax         : std_logic;
  signal phi0       : std_logic;
  signal phi0_en_r  : std_logic;
  signal phi0_en_f  : std_logic;
  signal color_ref  : std_logic;
  signal video_addr : unsigned(15 downto 0);
  signal sega       : std_logic;
  signal segb       : std_logic;
  signal segc       : std_logic;
  signal gr1        : std_logic;
  signal gr2        : std_logic;
  signal hblank     : std_logic;
  signal vblank     : std_logic;
  signal wndw_n     : std_logic;
  signal ldps_n     : std_logic;
begin
  palmode <= '0' when PHASE = 0 else '1';

  clk_14m <= not clk_14m after 5 ns;

  dut : entity work.timing_generator
    port map (
      CLK_14M       => clk_14m,
      PALMODE       => palmode,
      VID7M         => vid7m,
      Q3            => q3,
      RAS_N         => ras_n,
      CAS_N         => cas_n,
      AX            => ax,
      PHI0          => phi0,
      PHI0_EN_R     => phi0_en_r,
      PHI0_EN_F     => phi0_en_f,
      COLOR_REF     => color_ref,
      TEXT_MODE     => text_mode,
      PAGE2         => page2,
      HIRES_MODE    => hires_mode,
      MIXED_MODE    => mixed_mode,
      COL80         => col80,
      STORE80       => store80,
      DHIRES_MODE   => dhires,
      VID7          => vid7,
      VIDEO_ADDRESS => video_addr,
      SEGA          => sega,
      SEGB          => segb,
      SEGC          => segc,
      GR1           => gr1,
      GR2           => gr2,
      HBLANK        => hblank,
      VBLANK        => vblank,
      WNDW_N        => wndw_n,
      LDPS_N        => ldps_n
    );

  stimulus : process
    file trace_output : text open write_mode is TRACE_FILE;
    variable trace_line : line;
    variable one_bit    : std_logic_vector(3 downto 0);
    variable cyc        : integer;
  begin
    write(trace_line, string'("CYCLE,PHI0,Q3,RAS_N,AX,CAS_N,VID7M,COLOR_REF,PHI0_EN_R,PHI0_EN_F,HBLANK,VBLANK,WNDW_N,LDPS_N,GR1,GR2,SEGA,SEGB,SEGC,VIDEO_ADDRESS"));
    writeline(trace_output, trace_line);

    for cyc in 0 to TOTAL - 1 loop
      wait until falling_edge(clk_14m);

      text_mode  <= '0';
      page2      <= '0';
      hires_mode <= '0';
      mixed_mode <= '0';
      col80      <= '0';
      store80    <= '0';
      dhires     <= '0';
      vid7       <= '0';
      if (cyc / 100000) mod 2 = 1 then text_mode <= '1'; end if;
      if (cyc / 50000) mod 2 = 1 then page2 <= '1'; end if;
      if (cyc / 20000) mod 2 = 1 then hires_mode <= '1'; end if;
      if (cyc / 15000) mod 2 = 1 then mixed_mode <= '1'; end if;
      if (cyc / 8000) mod 2 = 1 then col80 <= '1'; end if;
      if (cyc / 6000) mod 2 = 1 then store80 <= '1'; end if;
      if (cyc / 4000) mod 2 = 1 then dhires <= '1'; end if;
      if (cyc / 2000) mod 2 = 1 then vid7 <= '1'; end if;

      wait until rising_edge(clk_14m);
      wait for 1 ns;

      if (cyc < 2000) or (cyc mod 32 = 0) then
        one_bit := "000" & phi0;
        write(trace_line, cyc);
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & q3;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & ras_n;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & ax;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & cas_n;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & vid7m;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & color_ref;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & phi0_en_r;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & phi0_en_f;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & hblank;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & vblank;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & wndw_n;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & ldps_n;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & gr1;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & gr2;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & sega;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & segb;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        one_bit := "000" & segc;
        write(trace_line, string'(",")); write(trace_line, to_hstring(one_bit));
        write(trace_line, string'(",")); write(trace_line, to_hstring(std_logic_vector(video_addr)));
        writeline(trace_output, trace_line);
      end if;
    end loop;

    report "VHDL trace complete" severity note;
    std.env.finish;
  end process;
end architecture;
