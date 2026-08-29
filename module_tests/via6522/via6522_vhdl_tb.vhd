-- via6522_vhdl_tb.vhd - golden-side testbench for the via6522 equivalence harness.
--
-- DUT: Apple-II_MiSTer_newsdee/rtl/mockingboard/via6522.vhd (golden, VHDL).
-- Cycle model: see gen_stim.ps1 header. Even cycles are F slots (falling=1),
-- odd cycles are R slots (rising=1). All bus accesses occur in F slots; the
-- golden timer clocks on falling edges, so its decrements align edge-for-edge
-- with the candidate's ce-gated decrements.
--
-- Trace: one CSV row per cycle, sampled at posedge + 1 ns. Columns (identical
-- to the Verilog side):
--   CYCLE,RESET,STROBE,WE,ADDR,DIN,CA1I,CA2I,CB1I,CB2I,PAI,PBI,
--   DOUT,PAO,PBO,CA2O,CB2O,CB1O,IRQ
-- Metavalues (U/X) are written as their letter and counted/skipped by the
-- runner (both DUTs have uninitialized state before reset).

library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;
library work;
use work.via6522_stim.all;

entity via6522_vhdl_tb is
end entity via6522_vhdl_tb;

architecture sim of via6522_vhdl_tb is
    constant TRACE_FILE : string := "module_tests/via6522/build/vhdl_trace.csv";

    signal clk      : std_logic := '0';
    signal rising   : std_logic := '0';
    signal falling  : std_logic := '0';
    signal reset_s  : std_logic := '1';
    signal addr     : std_logic_vector(3 downto 0) := (others => '0');
    signal wen      : std_logic := '0';
    signal ren      : std_logic := '0';
    signal data_in  : std_logic_vector(7 downto 0) := (others => '0');
    signal data_out : std_logic_vector(7 downto 0);
    signal phi2_ref : std_logic;
    signal port_a_o : std_logic_vector(7 downto 0);
    signal port_a_t : std_logic_vector(7 downto 0);
    signal port_a_i : std_logic_vector(7 downto 0) := (others => '0');
    signal port_b_o : std_logic_vector(7 downto 0);
    signal port_b_t : std_logic_vector(7 downto 0);
    signal port_b_i : std_logic_vector(7 downto 0) := (others => '0');
    signal ca1_i    : std_logic := '0';
    signal ca2_o    : std_logic;
    signal ca2_i    : std_logic := '0';
    signal ca2_t    : std_logic;
    signal cb1_o    : std_logic;
    signal cb1_i    : std_logic := '0';
    signal cb1_t    : std_logic;
    signal cb2_o    : std_logic;
    signal cb2_i    : std_logic := '0';
    signal cb2_t    : std_logic;
    signal irq      : std_logic;
begin

    dut : entity work.via6522
        port map (
            clock    => clk,
            rising   => rising,
            falling  => falling,
            reset    => reset_s,
            addr     => addr,
            wen      => wen,
            ren      => ren,
            data_in  => data_in,
            data_out => data_out,
            phi2_ref => phi2_ref,
            port_a_o => port_a_o,
            port_a_t => port_a_t,
            port_a_i => port_a_i,
            port_b_o => port_b_o,
            port_b_t => port_b_t,
            port_b_i => port_b_i,
            ca1_i    => ca1_i,
            ca2_o    => ca2_o,
            ca2_i    => ca2_i,
            ca2_t    => ca2_t,
            cb1_o    => cb1_o,
            cb1_i    => cb1_i,
            cb1_t    => cb1_t,
            cb2_o    => cb2_o,
            cb2_i    => cb2_i,
            cb2_t    => cb2_t,
            irq      => irq);

    -- Event-driven driver (same pattern as the hdd harness). GHDL 6.0 mcode
    -- re-executes an unsensitized process whose body COMPLETES, so the
    -- driver must end in a bare wait; termination is enforced by the
    -- runner's --stop-time (no std_env in this build's -fsynopsys ieee lib,
    -- and the concurrent clock keeps events pending forever).
    clk <= not clk after 35 ns;

    driver : process
        file f            : text open write_mode is TRACE_FILE;
        variable w        : std_logic_vector(35 downto 0);
        variable trc_line : line;
    begin
        write(trc_line, string'("CYCLE,RESET,STROBE,WE,ADDR,DIN,CA1I,CA2I,CB1I,CB2I,PAI,PBI,DOUT,PAO,PBO,CA2O,CB2O,CB1O,IRQ"));
        writeline(f, trc_line);

        for n in 0 to STIM_COUNT - 1 loop
            wait until falling_edge(clk);

            w := STIM(n);
            reset_s  <= w(34);
            wen      <= w(32);
            ren      <= w(33) and not w(32);
            addr     <= w(31 downto 28);
            data_in  <= w(27 downto 20);
            ca1_i    <= w(19);
            ca2_i    <= w(18);
            cb1_i    <= w(17);
            cb2_i    <= w(16);
            port_a_i <= w(15 downto 8);
            port_b_i <= w(7 downto 0);
            if n mod 2 = 0 then
                falling <= '1';
                rising  <= '0';
            else
                rising  <= '1';
                falling <= '0';
            end if;

            wait until rising_edge(clk);
            wait for 1 ns;

            write(trc_line, integer'image(n));
            write(trc_line, string'(",")); write(trc_line, reset_s);
            write(trc_line, string'(",")); write(trc_line, w(33));
            write(trc_line, string'(",")); write(trc_line, w(32));
            write(trc_line, string'(",")); write(trc_line, to_hstring(w(31 downto 28)));
            write(trc_line, string'(",")); write(trc_line, to_hstring(w(27 downto 20)));
            write(trc_line, string'(",")); write(trc_line, w(19));
            write(trc_line, string'(",")); write(trc_line, w(18));
            write(trc_line, string'(",")); write(trc_line, w(17));
            write(trc_line, string'(",")); write(trc_line, w(16));
            write(trc_line, string'(",")); write(trc_line, to_hstring(w(15 downto 8)));
            write(trc_line, string'(",")); write(trc_line, to_hstring(w(7 downto 0)));
            write(trc_line, string'(",")); write(trc_line, to_hstring(data_out));
            write(trc_line, string'(",")); write(trc_line, to_hstring(port_a_o));
            write(trc_line, string'(",")); write(trc_line, to_hstring(port_b_o));
            write(trc_line, string'(",")); write(trc_line, ca2_o);
            write(trc_line, string'(",")); write(trc_line, cb2_o);
            write(trc_line, string'(",")); write(trc_line, cb1_o);
            write(trc_line, string'(",")); write(trc_line, irq);
            writeline(f, trc_line);
        end loop;

        wait;
    end process driver;

end architecture sim;
