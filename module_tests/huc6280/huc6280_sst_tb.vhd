-- HUC6280 (PC Engine 65C02 variant) — single-step test bench (GHDL).
--
-- Part of the module_tests/huc6280 benchmark comparing the HUC6280 against
-- the canonical 65C02 core (rtl/cpu_65c02.sv, see huc6280_65c02_tb.sv).
-- Both benches consume the same batch file and emit the same result-line
-- format so sst_driver.py can parse and cross-compare them.
--
-- DUT: the test-adapter copy rtl_tb/huc6280_cpu_tb.vhd (HUC6280_CPU with
-- TB_INJ state-injection ports; identical behavior when TB_INJ='0').
--
-- Bus model notes (differences from the canonical 65C02 core):
--   * A_OUT is 21 bits: bits 12..0 are the physical address, bits 20..13
--     select an MPR (multi-port register) bank. With MPR all zero (reset
--     state, kept by the injection), every logical address aliases into
--     physical $0000-$1FFF. The TB indexes a 64K memory with A_OUT(14..0);
--     A_OUT(20..15) must stay zero for the result to be meaningful.
--   * Only cycles with MCYCLE='1' are real memory cycles; idle cycles are
--     reported as the sentinel bus token FFFFRFF.
--
-- Batch file format (one line per test, fixed width, LF endings):
--   <idx:8d> <pc:4h> <sp:2h> <a:2h> <x:2h> <y:2h> <p:2h> <ncyc:3d> <npatch:3d> <AAAAVV...>
-- Result line format (identical to the Verilator bench):
--   R <idx:8d> then per cycle c: "<addr4><R|W><data2> " + "<pc4><sp2><a2><x2><y2><p2>"
-- P is emitted with R/B forced to 1 (canonical-core convention).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

entity huc6280_sst_tb is
end entity huc6280_sst_tb;

architecture sim of huc6280_sst_tb is

	-- This GHDL build's std_logic_1164 has no image(); local substitute for
	-- debug reports only.
	function dbgimg (v : std_logic_vector) return string is
		variable s : string(1 to v'length);
	begin
		for i in 0 to v'length - 1 loop
			case v(v'length - 1 - i) is
				when '0' => s(i + 1) := '0';
				when '1' => s(i + 1) := '1';
				when others => s(i + 1) := 'U';
			end case;
		end loop;
		return s;
	end function;

	function dbgimg (v : std_logic) return string is
	begin
		if v = '0' then return "0";
		elsif v = '1' then return "1";
		else return "U";
		end if;
	end function;

	constant W : integer := 16;

	-- DUT interface
	signal clk    : std_logic := '0';
	signal rst_n  : std_logic := '0';
	signal ce     : std_logic := '0';
	signal rdy    : std_logic := '1';
	signal nmi_n  : std_logic := '1';
	signal irq1_n : std_logic := '1';
	signal irq2_n : std_logic := '1';
	signal irqt_n : std_logic := '1';
	signal vdcnum : std_logic := '0';
	signal tb_inj : std_logic := '0';
	signal inj_a  : std_logic_vector(7 downto 0)  := (others => '0');
	signal inj_x  : std_logic_vector(7 downto 0)  := (others => '0');
	signal inj_y  : std_logic_vector(7 downto 0)  := (others => '0');
	signal inj_sp : std_logic_vector(7 downto 0)  := (others => '0');
	signal inj_p  : std_logic_vector(7 downto 0)  := (others => '0');
	signal inj_pc : std_logic_vector(15 downto 0) := (others => '0');
	signal a_out  : std_logic_vector(20 downto 0);
	signal di     : std_logic_vector(7 downto 0);
	signal do_o   : std_logic_vector(7 downto 0);
	signal we_n   : std_logic;
	signal mcycle : std_logic;
	signal cs_o   : std_logic;
	signal obs_a  : std_logic_vector(7 downto 0);
	signal obs_x  : std_logic_vector(7 downto 0);
	signal obs_y  : std_logic_vector(7 downto 0);
	signal obs_sp : std_logic_vector(7 downto 0);
	signal obs_p  : std_logic_vector(7 downto 0);
	signal obs_pc : std_logic_vector(15 downto 0);
	signal obs_addr : std_logic_vector(15 downto 0);

	-- Memory (64K, sentinel 0xEE)
	type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);
	signal mem : mem_t;

	function hval (s : string) return integer is
		variable v : integer := 0;
	begin
		for i in s'range loop
			v := v * 16;
			case s(i) is
				when '0' => v := v + 0;
				when '1' => v := v + 1;
				when '2' => v := v + 2;
				when '3' => v := v + 3;
				when '4' => v := v + 4;
				when '5' => v := v + 5;
				when '6' => v := v + 6;
				when '7' => v := v + 7;
				when '8' => v := v + 8;
				when '9' => v := v + 9;
				when 'A' | 'a' => v := v + 10;
				when 'B' | 'b' => v := v + 11;
				when 'C' | 'c' => v := v + 12;
				when 'D' | 'd' => v := v + 13;
				when 'E' | 'e' => v := v + 14;
				when 'F' | 'f' => v := v + 15;
				when others => v := v;
			end case;
		end loop;
		return v;
	end function hval;

	function ival (s : string) return integer is
		variable v : integer := 0;
	begin
		for i in s'range loop
			if s(i) >= '0' and s(i) <= '9' then
				v := v * 10 + (character'pos(s(i)) - character'pos('0'));
			end if;
		end loop;
		return v;
	end function ival;

	function decstr8 (v : integer) return string is
		variable s : string(1 to 8);
		variable r : integer;
		variable i : integer;
	begin
		r := v;
		for i in 8 downto 1 loop
			s(i) := character'val(character'pos('0') + (r mod 10));
			r := r / 10;
		end loop;
		return s;
	end function decstr8;

	function hstr8 (v : std_logic_vector(7 downto 0)) return string is
		constant D : string := "0123456789abcdef";
	begin
		return D(to_integer(unsigned(v(7 downto 4))) + 1) &
		       D(to_integer(unsigned(v(3 downto 0))) + 1);
	end function hstr8;

	function hstr16 (v : std_logic_vector(15 downto 0)) return string is
	begin
		return hstr8(v(15 downto 8)) & hstr8(v(7 downto 0));
	end function hstr16;

begin

	-- Entity (not component) instantiation: hierarchical register reads
	-- (dut.AG.PCr etc.) are only legal through entity instances.
	dut : entity work.huc6280_cpu
	port map (
		CLK => clk, RST_N => rst_n, CE => ce,
		A_OUT => a_out, DI => di, DO => do_o, WE_N => we_n,
		RDY => rdy, NMI_N => nmi_n, IRQ1_N => irq1_n, IRQ2_N => irq2_n,
		IRQT_N => irqt_n, VDCNUM => vdcnum,
		MCYCLE => mcycle, CS => cs_o,
		TB_INJ => tb_inj, INJ_A => inj_a, INJ_X => inj_x, INJ_Y => inj_y,
		INJ_SP => inj_sp, INJ_P => inj_p, INJ_PC => inj_pc,
		OBS_A => obs_a, OBS_X => obs_x, OBS_Y => obs_y,
		OBS_SP => obs_sp, OBS_P => obs_p, OBS_PC => obs_pc, OBS_ADDR => obs_addr
	);

	-- 100 MHz sim clock (10 ns period). Bounded: sized to the batch (~300 ns
	-- per test: 4 setup posedges + 16 falling-edge samples = 200 ns, plus
	-- margin) then held. When the main process finishes and the clock stops,
	-- the event queue drains and GHDL exits (this GHDL build has no
	-- std.env.finish or --stop-at).
	process
		file tf : text;
		variable ll     : line;
		variable ntests : integer;
		variable i      : integer;
	begin
		ntests := 1;
		file_open(tf, "module_tests/huc6280/build/sst_batch.txt", read_mode);
		while not endfile(tf) loop
			readline(tf, ll);
			ntests := ntests + 1;
		end loop;
		file_close(tf);
		for i in 0 to ntests * 60 + 100 loop   -- half-periods
			clk <= not clk;
			wait for 5 ns;
		end loop;
		wait;
	end process;

	-- Data-in: the DUT's DI is combinational from the memory contents
	assign_di : process (obs_addr, mem, rst_n)
	begin
		if rst_n = '0' then
			di <= (others => '0');
		else
			-- flat 64K logical memory: index by the full 16-bit logical
			-- address (ADDR_BUS), not the 13-bit physical A_OUT (MPR=0 here)
			di <= mem(to_integer(unsigned(obs_addr)));
		end if;
	end process assign_di;

	-- Main test loop
	process
		file tf  : text;
		file ofp : text;
		variable l      : line;
		variable idx    : integer;
		variable pc, sp, a, x, y, p : integer;
		variable ncyc, npatch : integer;
		variable i, c : integer;
		variable addr, val : integer;
		variable bstok  : string(1 to 7);
		variable regs : string(1 to 14);
		variable outl : string(1 to 512);
		variable used : integer := 0;
	begin
		-- Single writer for mem: init + per-test patches all in this process.
		-- (GHDL mcode bug: 2+ processes writing array elements corrupts the array.)
		for i in 0 to 65535 loop
			mem(i) <= x"EE";
		end loop;

		file_open(tf,  "module_tests/huc6280/build/sst_batch.txt", read_mode);
		file_open(ofp, "module_tests/huc6280/build/huc6280_results.txt", write_mode);

		while not endfile(tf) loop
			readline(tf, l);
			if l'length >= 37 then

			idx    := ival(l(1 to 8));  -- idx is decimal in the batch
			pc     := hval(l(10 to 13));
			sp     := hval(l(15 to 16));
			a      := hval(l(18 to 19));
			x      := hval(l(21 to 22));
			y      := hval(l(24 to 25));
			p      := hval(l(27 to 28));
			ncyc   := ival(l(30 to 32));
			npatch := ival(l(34 to 36));

			-- apply memory patch. The HUC6280 remaps the 6502 zero page
			-- ($0000-$00FF) to $2000-$20FF and the stack page ($0100-$01FF)
			-- to $2100-$21FF. Mirror the first two pages of the WDC setup so
			-- the HUC6280 sees the same zero-page/stack data (isolates the
			-- memory-map remap from the CPU-logic comparison).
			for i in 0 to npatch - 1 loop
				addr := hval(l(38 + 6*i to 41 + 6*i));
				val  := hval(l(42 + 6*i to 43 + 6*i));
				mem(addr) <= std_logic_vector(to_unsigned(val, 8));
				if addr < 512 then
					mem(addr + 8192) <= std_logic_vector(to_unsigned(val, 8));  -- +$2000
				end if;
			end loop;

			-- reset, then inject architectural state
			rst_n  <= '0';
			ce     <= '0';
			tb_inj <= '0';
			wait until rising_edge(clk);
			wait until rising_edge(clk);
			rst_n <= '1';
			wait until rising_edge(clk);
			inj_a  <= std_logic_vector(to_unsigned(a, 8));
			inj_x  <= std_logic_vector(to_unsigned(x, 8));
			inj_y  <= std_logic_vector(to_unsigned(y, 8));
			inj_sp <= std_logic_vector(to_unsigned(sp, 8));
			inj_p  <= std_logic_vector(to_unsigned(p, 8));
			inj_pc <= std_logic_vector(to_unsigned(pc, 16));
			tb_inj <= '1';
			wait until rising_edge(clk);   -- injection latched
			tb_inj <= '0';
			-- Build the result line as one string: this GHDL build lacks the
			-- write(file, character) overload, string writes work.
			outl(1 to 11) := "R " & decstr8(idx) & " ";
			used := 11;

			-- Sample at falling edges: mid-cycle, all DUT signals stable
			-- regardless of process resumption order at the posedge. Row c is
			-- then: bus access of cycle c + registers before cycle c — the
			-- same convention as cpu65_sst_tb_v2.sv.
			ce <= '1';   -- release: next posedge runs cycle 0
			for c in 0 to W - 1 loop
				wait until falling_edge(clk);
				-- sample (hierarchical reads of DUT registers)
				if mcycle = '1' then
					bstok(1 to 4) := hstr16(obs_addr);
					if we_n = '0' then
						bstok(5) := 'W';
						bstok(6 to 7) := hstr8(do_o);
					else
						bstok(5) := 'R';
						bstok(6 to 7) := hstr8(di);
					end if;
				else
					bstok := "ffffrff";  -- idle-cycle sentinel
				end if;
				regs := hstr16(obs_pc) & hstr8(obs_sp) & hstr8(obs_a) &
				        hstr8(obs_x) & hstr8(obs_y) &
				        hstr8(obs_p(7) & obs_p(6) & '1' & '1' &
				                obs_p(3) & obs_p(2) & obs_p(1) & obs_p(0));
				outl(used + 1 to used + 22) := bstok & " " & regs;
				used := used + 22;
			end loop;
			outl(used + 1) := character'val(10);
			write(ofp, outl(1 to used + 1));

			-- restore memory image
			for i in 0 to npatch - 1 loop
				addr := hval(l(38 + 6*i to 41 + 6*i));
				mem(addr) <= x"EE";
			end loop;
			end if;
		end loop;

		file_close(ofp);
		file_close(tf);
		report "huc6280 sst batch complete";
		wait;
	end process;

end architecture sim;
