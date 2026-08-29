-- ym2149_stub.vhd - deterministic PSG stub for the mockingboard harness.
--
-- GHDL cannot compile the shared YM2149.sv, so both sides of this harness
-- use a stub with the EXACT port list of the real chip's component
-- declaration in mockingboard.vhd. The Verilog twin (ym2149_stub.v) must
-- remain bit-identical in behavior: same register file, same protocol,
-- same reset semantics, same combinational channel outputs.
--
-- Stub semantics (NOT an AY-3-8910 model - determinism and parity only):
--   - 32x8 register file, value 0 after reset/power-up.
--   - On posedge CLK:
--       RESET=1                 -> clear all registers and DO to 0
--       CE=1, BC=1, BDIR=1      -> mem[DI(5 downto 0)] <= DI   (write)
--       CE=1, BC=1, BDIR=0      -> do_reg <= mem[DI(5 downto 0)] (read)
--     (CE/BC/BDIR are levels sampled on the clock edge, like the real chip.)
--   - DO is a registered readout (one-cycle read latency).
--   - CHANNEL_A/B/C are pure combinational functions of mem(0)/mem(1)/mem(2);
--     they carry no free-running state, so O_AUDIO changes only on writes.
--   - SEL/MODE/IOA_in/IOB_in are ignored; ACTIVE is unused by the board.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity YM2149 is
    port (
        CLK         : in  std_logic;
        CE          : in  std_logic;
        RESET       : in  std_logic;
        BDIR        : in  std_logic; -- Bus Direction (0 - read , 1 - write)
        BC          : in  std_logic; -- Bus control
        DI          : in  std_logic_vector(7 downto 0);
        DO          : out std_logic_vector(7 downto 0);
        CHANNEL_A   : out std_logic_vector(7 downto 0);
        CHANNEL_B   : out std_logic_vector(7 downto 0);
        CHANNEL_C   : out std_logic_vector(7 downto 0);

        SEL         : in  std_logic;
        MODE        : in  std_logic;

        ACTIVE      : out std_logic_vector(5 downto 0);

        IOA_in      : in  std_logic_vector(7 downto 0);
        IOA_out     : out std_logic_vector(7 downto 0);

        IOB_in      : in  std_logic_vector(7 downto 0);
        IOB_out     : out std_logic_vector(7 downto 0)
    );
end entity YM2149;

architecture stub of YM2149 is
    type regfile_t is array (0 to 31) of std_logic_vector(7 downto 0);
    signal mem    : regfile_t := (others => (others => '0'));
    signal do_reg : std_logic_vector(7 downto 0) := (others => '0');
begin
    process (CLK)
        variable idx : natural;
    begin
        if rising_edge(CLK) then
            if RESET = '1' then
                mem    <= (others => (others => '0'));
                do_reg <= (others => '0');
            elsif CE = '1' and BC = '1' then
                idx := to_integer(unsigned(DI(5 downto 0)));
                if BDIR = '1' then
                    mem(idx) <= DI;
                else
                    do_reg <= mem(idx);
                end if;
            end if;
        end if;
    end process;

    DO        <= do_reg;
    CHANNEL_A <= mem(0);
    CHANNEL_B <= mem(1);
    CHANNEL_C <= mem(2);

    ACTIVE  <= (others => '0');
    IOA_out <= (others => '0');
    IOB_out <= (others => '0');
end architecture stub;
