library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity keyboard_vhdl_tb is
  generic (
    TRACE_FILE : string := "module_tests/keyboard/build/vhdl_trace.csv"
  );
end entity;

architecture test of keyboard_vhdl_tb is
  signal clk_14m : std_logic := '0';
  signal ps2_key : std_logic_vector(10 downto 0) := (others => '0');
  signal virtual_active : std_logic := '0';
  signal virtual_event : std_logic := '0';
  signal virtual_pressed : std_logic := '0';
  signal virtual_code : std_logic_vector(6 downto 0) := (others => '0');
  signal virtual_control : std_logic := '0';
  signal virtual_open_apple : std_logic := '0';
  signal virtual_closed_apple : std_logic := '0';
  signal reads : std_logic := '0';
  signal reset : std_logic := '1';
  signal akd : std_logic;
  signal k_out : unsigned(7 downto 0);
  signal open_apple : std_logic;
  signal closed_apple : std_logic;
  signal soft_reset : std_logic;
  signal video_toggle : std_logic;
  signal palette_toggle : std_logic;
begin
  clk_14m <= not clk_14m after 5 ns;

  dut : entity work.keyboard
    port map (
      CLK_14M => clk_14m,
      PS2_Key => ps2_key,
      virtual_active => virtual_active,
      virtual_event => virtual_event,
      virtual_pressed => virtual_pressed,
      virtual_code => virtual_code,
      virtual_control => virtual_control,
      virtual_open_apple => virtual_open_apple,
      virtual_closed_apple => virtual_closed_apple,
      reads => reads,
      reset => reset,
      akd => akd,
      K => k_out,
      open_apple => open_apple,
      closed_apple => closed_apple,
      soft_reset => soft_reset,
      video_toggle => video_toggle,
      palette_toggle => palette_toggle
    );

  stimulus : process
    file trace_output : text open write_mode is TRACE_FILE;
    variable trace_line : line;
    variable trace_flags : std_logic_vector(6 downto 0);
  begin
    write(trace_line, string'("CYCLE,K,READ_KEY,AKD,OPEN_APPLE,CLOSED_APPLE,SOFT_RESET,VIDEO_TOGGLE,PALETTE_TOGGLE"));
    writeline(trace_output, trace_line);

    for cycle in 0 to 319 loop
      wait until falling_edge(clk_14m);

      reset <= '0';
      ps2_key <= (others => '0');
      reads <= '0';
      virtual_active <= '0';
      virtual_event <= '0';
      virtual_pressed <= '0';
      virtual_code <= (others => '0');
      virtual_control <= '0';
      virtual_open_apple <= '0';
      virtual_closed_apple <= '0';

      if cycle < 4 then
        reset <= '1';
      elsif cycle >= 8 and cycle <= 13 then
        ps2_key <= '1' & '1' & '0' & x"1C";  -- make A
      elsif cycle >= 28 and cycle <= 33 then
        ps2_key <= '1' & '1' & '0' & x"12";  -- make left shift
      elsif cycle >= 40 and cycle <= 45 then
        ps2_key <= '1' & '1' & '0' & x"1C";  -- make A (shift held)
      elsif cycle >= 60 and cycle <= 65 then
        ps2_key <= '1' & '0' & '0' & x"12";  -- break left shift
      elsif cycle >= 72 and cycle <= 77 then
        ps2_key <= '1' & '1' & '1' & x"75";  -- make extended up arrow
      elsif cycle >= 92 and cycle <= 97 then
        ps2_key <= '1' & '0' & '1' & x"75";  -- break extended up arrow
      elsif cycle >= 104 and cycle <= 109 then
        ps2_key <= '1' & '1' & '0' & x"06";  -- make F2 (soft reset)
      elsif cycle >= 124 and cycle <= 129 then
        ps2_key <= '1' & '0' & '0' & x"06";  -- break F2
      elsif cycle >= 136 and cycle <= 141 then
        ps2_key <= '1' & '1' & '0' & x"0A";  -- make F8 (palette toggle)
      elsif cycle >= 148 and cycle <= 153 then
        ps2_key <= '1' & '0' & '0' & x"0A";  -- break F8
      elsif cycle >= 160 and cycle <= 165 then
        ps2_key <= '1' & '1' & '0' & x"01";  -- make F9 (video toggle)
      elsif cycle >= 172 and cycle <= 177 then
        ps2_key <= '1' & '0' & '0' & x"01";  -- break F9
      elsif cycle >= 184 and cycle <= 189 then
        ps2_key <= '1' & '1' & '0' & x"58";  -- make caps lock
      elsif cycle >= 196 and cycle <= 201 then
        ps2_key <= '1' & '0' & '0' & x"58";  -- break caps lock (toggles caplock)
      elsif cycle >= 208 and cycle <= 213 then
        ps2_key <= '1' & '1' & '0' & x"1C";  -- make A (caplock set)
      elsif cycle >= 232 and cycle <= 271 then
        virtual_active <= '1';
        if cycle >= 240 and cycle <= 255 then
          virtual_event <= '1';
          virtual_pressed <= '1';
          virtual_code <= "0101010";  -- 7-bit code 0x2A
          virtual_control <= '1';
        end if;
        if cycle >= 240 and cycle <= 249 then
          virtual_open_apple <= '1';
        end if;
        if cycle >= 250 and cycle <= 255 then
          virtual_closed_apple <= '1';
        end if;
      end if;

      if cycle = 20 or cycle = 52 or cycle = 84 or
         cycle = 220 or cycle = 248 or cycle = 272 then
        reads <= '1';
      end if;

      wait until rising_edge(clk_14m);
      wait for 1 ns;

      if cycle >= 4 then
        trace_flags := reads & akd & open_apple & closed_apple & soft_reset & video_toggle & palette_toggle;
        write(trace_line, cycle);
        write(trace_line, string'(",")); write(trace_line, to_hstring(std_logic_vector(k_out)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(trace_flags(6 downto 6)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(trace_flags(5 downto 5)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(trace_flags(4 downto 4)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(trace_flags(3 downto 3)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(trace_flags(2 downto 2)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(trace_flags(1 downto 1)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(trace_flags(0 downto 0)));
        writeline(trace_output, trace_line);
      end if;
    end loop;

    report "VHDL trace complete" severity note;
    std.env.finish;
  end process;
end architecture;
