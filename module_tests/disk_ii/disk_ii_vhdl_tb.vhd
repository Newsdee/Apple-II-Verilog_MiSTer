library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity disk_ii_vhdl_tb is
  generic (
    TRACE_FILE : string := "module_tests/disk_ii/build/vhdl_trace.csv"
  );
end entity;

architecture test of disk_ii_vhdl_tb is
  signal clk_14m : std_logic := '0';
  signal clk_2m : std_logic := '0';
  signal phase_zero : std_logic := '0';
  signal io_select : std_logic := '0';
  signal device_select : std_logic := '0';
  signal reset : std_logic := '1';
  signal disk_ready : std_logic_vector(1 downto 0) := "11";
  signal address_bus : unsigned(15 downto 0) := (others => '0');
  signal data_in : unsigned(7 downto 0) := (others => '0');
  signal data_out : unsigned(7 downto 0);
  signal drive1_active : std_logic;
  signal drive2_active : std_logic;
  signal drive1_motor_on : std_logic;
  signal drive2_motor_on : std_logic;
  signal drive1_io_active : std_logic;
  signal drive2_io_active : std_logic;
  signal drive1_step_active : std_logic;
  signal drive2_step_active : std_logic;
  signal drive1_track_zero_step : std_logic;
  signal drive2_track_zero_step : std_logic;
  signal drive1_write_protected : std_logic := '0';
  signal drive2_write_protected : std_logic := '0';
  signal track1 : unsigned(5 downto 0);
  signal track1_addr : unsigned(12 downto 0);
  signal track1_di : unsigned(7 downto 0);
  signal track1_do : unsigned(7 downto 0);
  signal track1_we : std_logic;
  signal track1_busy : std_logic := '0';
  signal track2 : unsigned(5 downto 0);
  signal track2_addr : unsigned(12 downto 0);
  signal track2_di : unsigned(7 downto 0);
  signal track2_do : unsigned(7 downto 0);
  signal track2_we : std_logic;
  signal track2_busy : std_logic := '0';
begin
  clk_14m <= not clk_14m after 5 ns;

  clk_2m_generator : process
  begin
    wait for 17 ns;
    loop
      wait for 35 ns;
      clk_2m <= not clk_2m;
    end loop;
  end process;

  track1_do <= track1_addr(7 downto 0) xor x"5A";
  track2_do <= track2_addr(7 downto 0) xor x"A5";

  dut : entity work.disk_ii
    port map (
      CLK_14M => clk_14m,
      CLK_2M => clk_2m,
      PHASE_ZERO => phase_zero,
      IO_SELECT => io_select,
      DEVICE_SELECT => device_select,
      RESET => reset,
      DISK_READY => disk_ready,
      A => address_bus,
      D_IN => data_in,
      D_OUT => data_out,
      D1_ACTIVE => drive1_active,
      D2_ACTIVE => drive2_active,
      D1_MOTOR_ON => drive1_motor_on,
      D2_MOTOR_ON => drive2_motor_on,
      D1_IO_ACTIVE => drive1_io_active,
      D2_IO_ACTIVE => drive2_io_active,
      D1_STEP_ACTIVE => drive1_step_active,
      D2_STEP_ACTIVE => drive2_step_active,
      D1_TRACK_ZERO_STEP => drive1_track_zero_step,
      D2_TRACK_ZERO_STEP => drive2_track_zero_step,
      D1_WP => drive1_write_protected,
      D2_WP => drive2_write_protected,
      TRACK1 => track1,
      TRACK1_ADDR => track1_addr,
      TRACK1_DI => track1_di,
      TRACK1_DO => track1_do,
      TRACK1_WE => track1_we,
      TRACK1_BUSY => track1_busy,
      TRACK2 => track2,
      TRACK2_ADDR => track2_addr,
      TRACK2_DI => track2_di,
      TRACK2_DO => track2_do,
      TRACK2_WE => track2_we,
      TRACK2_BUSY => track2_busy
    );

  stimulus : process
    file trace_output : text open write_mode is TRACE_FILE;
    variable trace_line : line;
    variable flags : std_logic_vector(11 downto 0);
    variable step_group : integer;
  begin
    write(trace_line, string'("CYCLE,D_OUT,FLAGS,TRACK1,TRACK1_ADDR,TRACK1_DI,TRACK2,TRACK2_ADDR,TRACK2_DI"));
    writeline(trace_output, trace_line);

    for cycle in 0 to 14005199 loop
      wait until falling_edge(clk_14m);

      reset <= '0';
      io_select <= '0';
      device_select <= '0';
      phase_zero <= '0';
      disk_ready <= "11";
      drive1_write_protected <= '0';
      drive2_write_protected <= '0';
      track1_busy <= '0';
      track2_busy <= '0';
      address_bus <= x"C080";
      data_in <= to_unsigned((cycle * 13 + 7) mod 256, 8);

      if cycle < 4 then
        reset <= '1';
      elsif cycle <= 259 then
        io_select <= '1';
        address_bus <= to_unsigned(16#C600# + cycle - 4, 16);
      elsif cycle = 260 then
        device_select <= '1'; address_bus <= x"C089";
      elsif cycle = 261 then
        device_select <= '1'; address_bus <= x"C08D";
      elsif cycle = 262 then
        drive1_write_protected <= '1';
      elsif cycle = 263 then
        drive1_write_protected <= '0';
      elsif cycle = 264 then
        device_select <= '1'; address_bus <= x"C08B";
      elsif cycle = 265 then
        drive2_write_protected <= '1';
      elsif cycle = 266 then
        device_select <= '1'; address_bus <= x"C08D"; drive2_write_protected <= '1';
      elsif cycle = 267 then
        drive2_write_protected <= '1';
      elsif cycle = 268 then
        device_select <= '1'; address_bus <= x"C08A";
      elsif cycle = 269 then
        drive1_write_protected <= '1';
      elsif cycle = 270 then
        device_select <= '1'; address_bus <= x"C08C";
      elsif cycle = 271 then
        device_select <= '1'; address_bus <= x"C081";
      elsif cycle = 272 then
        device_select <= '1'; address_bus <= x"C080";
      elsif cycle = 273 then
        device_select <= '1'; address_bus <= x"C088";
      elsif cycle >= 274 and cycle <= 413 then
        step_group := (cycle - 274) / 4;
        if (cycle - 274) mod 4 = 0 then
          device_select <= '1';
          case step_group mod 4 is
            when 0 => address_bus <= x"C083";
            when 1 => address_bus <= x"C081";
            when 2 => address_bus <= x"C087";
            when others => address_bus <= x"C085";
          end case;
        elsif (cycle - 274) mod 4 = 2 then
          device_select <= '1';
          case step_group mod 4 is
            when 0 => address_bus <= x"C082";
            when 1 => address_bus <= x"C080";
            when 2 => address_bus <= x"C086";
            when others => address_bus <= x"C084";
          end case;
        end if;
      elsif cycle = 414 then
        device_select <= '1'; address_bus <= x"C08B";
      elsif cycle >= 415 and cycle <= 554 then
        step_group := (cycle - 415) / 4;
        if (cycle - 415) mod 4 = 0 then
          device_select <= '1';
          case step_group mod 4 is
            when 0 => address_bus <= x"C083";
            when 1 => address_bus <= x"C081";
            when 2 => address_bus <= x"C087";
            when others => address_bus <= x"C085";
          end case;
        elsif (cycle - 415) mod 4 = 2 then
          device_select <= '1';
          case step_group mod 4 is
            when 0 => address_bus <= x"C082";
            when 1 => address_bus <= x"C080";
            when 2 => address_bus <= x"C086";
            when others => address_bus <= x"C084";
          end case;
        end if;
      elsif cycle = 555 then
        device_select <= '1'; address_bus <= x"C08A";
      elsif cycle = 556 then
        device_select <= '1'; address_bus <= x"C089";
      elsif cycle <= 1299 then
        device_select <= '1'; phase_zero <= '1';
        if cycle mod 8 = 0 then address_bus <= x"C08F"; else address_bus <= x"C08C"; end if;
        if cycle mod 37 = 0 then track1_busy <= '1'; end if;
      elsif cycle = 1300 then
        device_select <= '1'; address_bus <= x"C08B";
      elsif cycle <= 2099 then
        device_select <= '1'; phase_zero <= '1';
        if cycle mod 8 = 0 then address_bus <= x"C08F"; else address_bus <= x"C08C"; end if;
        if cycle mod 41 = 0 then track2_busy <= '1'; end if;
      elsif cycle = 2100 then
        device_select <= '1'; address_bus <= x"C08E";
      elsif cycle = 2101 then
        device_select <= '1'; address_bus <= x"C08A";
      elsif cycle <= 3099 then
        device_select <= '1'; address_bus <= x"C08C";
        if cycle mod 7 = 0 then phase_zero <= '1'; end if;
        if cycle mod 29 = 0 then disk_ready(0) <= '0'; end if;
      elsif cycle = 3100 then
        device_select <= '1'; address_bus <= x"C08B";
      elsif cycle <= 4099 then
        device_select <= '1'; address_bus <= x"C08C";
        if cycle mod 7 = 0 then phase_zero <= '1'; end if;
        if cycle mod 31 = 0 then disk_ready(1) <= '0'; end if;
      elsif cycle = 4100 then
        device_select <= '1'; address_bus <= x"C088";
      else
        null;
      end if;

      wait until rising_edge(clk_14m);
      wait for 1 ns;

      if cycle >= 4 and (cycle < 5000 or cycle >= 14003100) then
        flags := drive1_active & drive2_active & drive1_motor_on & drive2_motor_on &
          drive1_io_active & drive2_io_active & drive1_step_active & drive2_step_active &
          drive1_track_zero_step & drive2_track_zero_step & track1_we & track2_we;
        write(trace_line, cycle);
        write(trace_line, string'(",")); write(trace_line, to_hstring(std_logic_vector(data_out)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(flags));
        write(trace_line, string'(",")); write(trace_line, to_hstring(std_logic_vector(track1)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(std_logic_vector(track1_addr)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(std_logic_vector(track1_di)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(std_logic_vector(track2)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(std_logic_vector(track2_addr)));
        write(trace_line, string'(",")); write(trace_line, to_hstring(std_logic_vector(track2_di)));
        writeline(trace_output, trace_line);
      end if;
    end loop;

    report "VHDL trace complete" severity note;
    std.env.finish;
  end process;
end architecture;
