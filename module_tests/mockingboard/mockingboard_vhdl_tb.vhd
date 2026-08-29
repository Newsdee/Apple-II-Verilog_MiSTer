-- mockingboard_vhdl_tb.vhd - golden-side testbench for the mockingboard
-- equivalence harness.
--
-- DUT: Apple-II_MiSTer_newsdee/rtl/mockingboard/mockingboard.vhd (golden,
-- VHDL) with its YM2149 component declaration stripped in the build/ copy so
-- that the psg_left/psg_right instantiations bind to work.YM2149 - the
-- deterministic stub (ym2149_stub.vhd). The golden via6522.vhd is the
-- normalized build/ copy (same transform as the via6522 harness).
--
-- Phase schedule (dense alternating, from cycle parity):
--   even cycles: PHASE_ZERO_R=1 -> golden VIA falling slot (bus work)
--   odd cycles:  PHASE_ZERO_F=1 -> golden VIA rising slot, PSG CE (with ENA)
-- All stimulus bus accesses occur in even cycles.
--
-- Trace: one CSV row per cycle, sampled at posedge + 1 ns. Columns (identical
-- to the Verilog side):
--   CYCLE,RESET,IOSL,ENA,RW,ADDR,DIN,ODATA,OE,IRQ,NMI,AUDL,AUDR
-- where RESET/IOSL/ENA/RW are the port levels I_RESET_L/I_IOSEL_L/I_ENA_H/
-- I_RW_L (RESET=0 means reset asserted), and IRQ/NMI are O_IRQ_L/O_NMI_L
-- (active low). Metavalues (U/X) are written as their letter and counted/
-- skipped by the runner.

library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;
library work;
use work.mockingboard_stim.all;

entity mockingboard_vhdl_tb is
end entity mockingboard_vhdl_tb;

architecture sim of mockingboard_vhdl_tb is
    constant TRACE_FILE : string := "module_tests/mockingboard/build/vhdl_trace.csv";

    signal clk        : std_logic := '0';
    signal phase_zero : std_logic := '0';
    signal phase_r    : std_logic := '0';
    signal phase_f    : std_logic := '0';
    signal i_addr     : std_logic_vector(7 downto 0) := (others => '0');
    signal i_data     : std_logic_vector(7 downto 0) := (others => '0');
    signal o_data     : std_logic_vector(7 downto 0);
    signal oe         : std_logic;
    signal i_rw_l     : std_logic := '1';
    signal o_irq_l    : std_logic;
    signal o_nmi_l    : std_logic;
    signal i_iosel_l  : std_logic := '1';
    signal i_reset_l  : std_logic := '0';
    signal i_ena_h    : std_logic := '0';
    signal o_audio_l  : std_logic_vector(9 downto 0);
    signal o_audio_r  : std_logic_vector(9 downto 0);
begin

    dut : entity work.MOCKINGBOARD
        port map (
            CLK_14M      => clk,
            PHASE_ZERO   => phase_zero,
            PHASE_ZERO_R => phase_r,
            PHASE_ZERO_F => phase_f,
            I_ADDR       => i_addr,
            I_DATA       => i_data,
            O_DATA       => o_data,
            OE           => oe,
            I_RW_L       => i_rw_l,
            O_IRQ_L      => o_irq_l,
            O_NMI_L      => o_nmi_l,
            I_IOSEL_L    => i_iosel_l,
            I_RESET_L    => i_reset_l,
            I_ENA_H      => i_ena_h,
            O_AUDIO_L    => o_audio_l,
            O_AUDIO_R    => o_audio_r);

    -- Event-driven driver (same pattern as the via6522/hdd harnesses). GHDL
    -- 6.0 mcode re-executes an unsensitized process whose body COMPLETES, so
    -- the driver must end in a bare wait; termination is enforced by the
    -- runner's --stop-time (no std_env in this build's -fsynopsys ieee lib).
    clk <= not clk after 35 ns;

    driver : process
        file f            : text open write_mode is TRACE_FILE;
        variable w        : std_logic_vector(23 downto 0);
        variable trc_line : line;
    begin
        write(trc_line, string'("CYCLE,RESET,IOSL,ENA,RW,ADDR,DIN,ODATA,OE,IRQ,NMI,AUDL,AUDR"));
        writeline(f, trc_line);

        for n in 0 to STIM_COUNT - 1 loop
            wait until falling_edge(clk);

            w := STIM(n);
            i_reset_l <= not w(23);
            i_iosel_l <= w(22);
            i_ena_h   <= w(21);
            i_rw_l    <= w(20);
            i_addr    <= w(19 downto 12);
            i_data    <= w(11 downto 4);
            if n mod 2 = 0 then
                phase_r <= '1';
                phase_f <= '0';
            else
                phase_r <= '0';
                phase_f <= '1';
            end if;

            wait until rising_edge(clk);
            wait for 1 ns;

            write(trc_line, integer'image(n));
            write(trc_line, string'(",")); write(trc_line, i_reset_l);
            write(trc_line, string'(",")); write(trc_line, i_iosel_l);
            write(trc_line, string'(",")); write(trc_line, i_ena_h);
            write(trc_line, string'(",")); write(trc_line, i_rw_l);
            write(trc_line, string'(",")); write(trc_line, to_hstring(i_addr));
            write(trc_line, string'(",")); write(trc_line, to_hstring(i_data));
            write(trc_line, string'(",")); write(trc_line, to_hstring(o_data));
            write(trc_line, string'(",")); write(trc_line, oe);
            write(trc_line, string'(",")); write(trc_line, o_irq_l);
            write(trc_line, string'(",")); write(trc_line, o_nmi_l);
            write(trc_line, string'(",")); write(trc_line, to_hstring(o_audio_l));
            write(trc_line, string'(",")); write(trc_line, to_hstring(o_audio_r));
            writeline(f, trc_line);
        end loop;

        wait;
    end process driver;

end architecture sim;
