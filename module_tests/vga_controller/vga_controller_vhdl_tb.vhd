-- vga_controller_vhdl_tb.vhd
--
-- Cycle-equivalence testbench (golden side) for the VHDL vga_controller
-- (VGA line-doubler + artifact colorizer + custom palette download).
-- The candidate side is vga_controller_verilog_tb.sv with the IDENTICAL
-- procedural stimulus (same schedule + pattern functions) and CSV schema.
--
-- Machine model / timing convention:
--   * CLK toggles every 5 ns. Inputs updated at the falling edge of cycle
--     N, latched by the DUT at the rising edge ending cycle N, outputs
--     sampled at rising edge + 1 ns.
--   * No reset port: initial state is defined by the power-up schedule.
--     Golden signals start U; Verilog regs start 0. Leading per-column
--     metavalue runs are skipped and counted (never mismatches).
--   * Line geometry: 912 cycles/line; HBL=1 for c=0..351, HBL=0 for
--     c=352..911. VIDEO is a deterministic pattern function of (line, c).
--
-- Schedule (179 lines = 163248 cycles), identical in both TBs:
--   0-1    P0 preamble (VBL=1, defaults)
--   2      custom palette download: 64 beats at c=0..63 (4 beats/color,
--          color i: d0=17i+1, d1=13i+2, d2=11i+3, d3=0x5A, mod 256),
--          ioctl_download=1, ioctl_index=8'h02
--   3-4    P1a active (resets vcount in the golden)
--   5-44   P1b 40 VBL lines (vcount 1..40 -> VGA_VS asserts at 33,
--          deasserts at 36)
--   45-52  P1c active pattern mix
--   53-57  P1d 5 VBL lines (VS must NOT reassert)
--   58-65  P1d active pattern mix (seams, mono dots)
--   66-129 P2 all 16 {SM,CP} combos x 4 lines
--   130-141 GSF=1 (6 lines SM=00/CP=00, 6 lines SM=01/CP=01)
--   142-170 NVC=1: 4 VBL + 8 active + 5 VBL + 8 active (SM=00/CP=00)
--           + 4 active (SM=01/CP=00, comb must bypass)
--   171-178 P3 CP=11 custom palette: patterns whose hcount rotations
--           cover all 16 LUT entries
--
-- KNOWN EXPECTED DIVERGENCE (see README.md plan): palette download beat
-- handling differs (golden buffer = {d0,d1,d2}; candidate latches the
-- new value and wraps color_addr after beat 2). The divergence surfaces
-- on the P3 CP=11 lines. Any OTHER mismatch is a real finding.
--
-- Trace (every cycle), 21 columns:
--   CYCLE,VIDEO,HBL,VBL,SM,CP,GSF,NVC,CL,IOCTL_DL,IOCTL_IDX,IOCTL_WR,
--   IOCTL_DATA,VGA_HS,VGA_VS,VGA_HBL,VGA_VBL,VGA_R,VGA_G,VGA_B,IOCTL_WAIT

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity vga_controller_vhdl_tb is
end entity vga_controller_vhdl_tb;

architecture sim of vga_controller_vhdl_tb is
  constant TOTAL : integer := 163248;
  constant TRACE_FILE : string := "module_tests/vga_controller/build/vhdl_trace.csv";
  signal clk            : std_logic := '0';
  signal video          : std_logic := '0';
  signal color_line     : std_logic := '1';
  signal screen_mode    : std_logic_vector(1 downto 0) := "00";
  signal color_palette  : std_logic_vector(1 downto 0) := "00";
  signal gray_seam_fix  : std_logic := '0';
  signal nvc            : std_logic := '0';
  signal hbl            : std_logic := '1';
  signal vbl            : std_logic := '1';
  signal vga_hs         : std_logic;
  signal vga_vs         : std_logic;
  signal vga_hbl        : std_logic;
  signal vga_vbl        : std_logic;
  signal vga_r          : unsigned(7 downto 0);
  signal vga_g          : unsigned(7 downto 0);
  signal vga_b          : unsigned(7 downto 0);
  signal ioctl_addr     : std_logic_vector(24 downto 0) := (others => '0');
  signal ioctl_data     : std_logic_vector(7 downto 0) := (others => '0');
  signal ioctl_index    : std_logic_vector(7 downto 0) := (others => '0');
  signal ioctl_download : std_logic := '0';
  signal ioctl_wr       : std_logic := '0';
  signal ioctl_wait     : std_logic;

  function video_bit(pat : integer; ph : integer; c : integer) return std_logic is
    variable r : std_logic := '0';
  begin
    case pat is
      when 0  => if c mod 2 = 1 then r := '1'; end if;
      when 4  => if (c + ph) mod 4 < 2 then r := '1'; end if;
      when 5  => r := '1';
      when 6  => r := '0';
      when 7  => if c = ph then r := '1'; end if;
      when 8  => if (c + ph) mod 8 < 4 then r := '1'; end if;
      when 9  => if (c >= 100 and c <= 101) or (c >= 300 and c <= 301) then r := '1'; end if;
      when 10 => if not (c >= 500 and c <= 501) then r := '1'; end if;
      when 11 => if (c + ph) mod 4 < 3 then r := '1'; end if;
      when 12 => if (c + ph) mod 4 = 0 then r := '1'; end if;
      when others => r := '0';
    end case;
    return r;
  end function;
begin
  clk <= not clk after 5 ns;

  dut : entity work.vga_controller
    port map (
      CLK_14M    => clk,
      VIDEO      => video,
      COLOR_LINE => color_line,
      SCREEN_MODE => screen_mode,
      COLOR_PALETTE => color_palette,
      GRAY_SEAM_FIX => gray_seam_fix,
      NTSC_VERTICAL_COMB => nvc,
      HBL        => hbl,
      VBL        => vbl,
      VGA_HS     => vga_hs,
      VGA_VS     => vga_vs,
      VGA_HBL    => vga_hbl,
      VGA_VBL    => vga_vbl,
      VGA_R      => vga_r,
      VGA_G      => vga_g,
      VGA_B      => vga_b,
      ioctl_addr => ioctl_addr,
      ioctl_data => ioctl_data,
      ioctl_index => ioctl_index,
      ioctl_download => ioctl_download,
      ioctl_wr   => ioctl_wr,
      ioctl_wait => ioctl_wait);

  stim : process
    variable li, c, k, j : integer;
    variable pat, ph, d : integer;
    variable dl, wr      : boolean;
    variable vbl_v, gsf_v, nvc_v, cl_v : std_logic;
    variable sm_v, cp_v : std_logic_vector(1 downto 0);
    file f : text open write_mode is TRACE_FILE;
    variable trc_line : line;
  begin
    write(trc_line, string'("CYCLE,VIDEO,HBL,VBL,SM,CP,GSF,NVC,CL,IOCTL_DL,IOCTL_IDX,IOCTL_WR,IOCTL_DATA,VGA_HS,VGA_VS,VGA_HBL,VGA_VBL,VGA_R,VGA_G,VGA_B,IOCTL_WAIT"));
    writeline(f, trc_line);

    for n in 0 to TOTAL - 1 loop
      wait until falling_edge(clk);

      li := n / 912;
      c  := n mod 912;

      vbl_v := '1'; sm_v := "00"; cp_v := "00";
      gsf_v := '0'; nvc_v := '0'; cl_v := '1';
      pat := 0; ph := 0; dl := false; wr := false; d := 0;

      if li = 2 and c < 64 then
        dl := true; wr := true;
        k := c / 4; j := c mod 4;
        if j = 0 then d := (17 * k + 1) mod 256;
        elsif j = 1 then d := (13 * k + 2) mod 256;
        elsif j = 2 then d := (11 * k + 3) mod 256;
        else d := 90; end if;
      end if;

      if li >= 3 and li <= 4 then
        vbl_v := '0';
        if li = 3 then pat := 4; ph := 0; else pat := 0; end if;
      elsif li >= 5 and li <= 44 then
        vbl_v := '1';
      elsif li >= 45 and li <= 52 then
        vbl_v := '0';
        case li - 45 is
          when 0 => pat := 0;
          when 1 => pat := 4; ph := 1;
          when 2 => pat := 4; ph := 2;
          when 3 => pat := 4; ph := 3;
          when 4 => pat := 5;
          when 5 => pat := 6;
          when 6 => pat := 7; ph := 200; cl_v := '0';
          when others => pat := 8; ph := 0;
        end case;
      elsif li >= 53 and li <= 57 then
        vbl_v := '1';
      elsif li >= 58 and li <= 65 then
        vbl_v := '0';
        case li - 58 is
          when 0 => pat := 9;
          when 1 => pat := 10;
          when 2 => pat := 4; ph := 0;
          when 3 => pat := 7; ph := 400; cl_v := '0';
          when 4 => pat := 0;
          when 5 => pat := 8; ph := 4;
          when 6 => pat := 5;
          when others => pat := 9;
        end case;
      elsif li >= 66 and li <= 129 then
        vbl_v := '0';
        k := (li - 66) / 4; j := (li - 66) mod 4;
        sm_v := std_logic_vector(to_unsigned(k mod 4, 2));
        cp_v := std_logic_vector(to_unsigned(k / 4, 2));
        if j = 0 then pat := 7; ph := 200; cl_v := '0';
        elsif j = 1 then pat := 4; ph := k mod 4;
        elsif j = 2 then pat := 0;
        else pat := 9; end if;
      elsif li >= 130 and li <= 141 then
        vbl_v := '0'; gsf_v := '1';
        if li <= 135 then sm_v := "00"; cp_v := "00";
        else sm_v := "01"; cp_v := "01"; end if;
        j := (li - 130) mod 6;
        case j is
          when 0 => pat := 9;
          when 1 => pat := 10;
          when 2 => pat := 4; ph := 0;
          when 3 => pat := 7; ph := 300; cl_v := '0';
          when 4 => pat := 9;
          when others => pat := 0;
        end case;
      elsif li >= 142 and li <= 145 then
        vbl_v := '1'; nvc_v := '1';
      elsif li >= 146 and li <= 153 then
        vbl_v := '0'; nvc_v := '1';
        case li - 146 is
          when 0 => pat := 4; ph := 0;
          when 1 => pat := 4; ph := 2;
          when 2 => pat := 4; ph := 1;
          when 3 => pat := 4; ph := 3;
          when 4 => pat := 0;
          when 5 => pat := 8; ph := 0;
          when 6 => pat := 9;
          when others => pat := 5;
        end case;
      elsif li >= 154 and li <= 158 then
        vbl_v := '1'; nvc_v := '1';
      elsif li >= 159 and li <= 166 then
        vbl_v := '0'; nvc_v := '1';
        case li - 159 is
          when 0 => pat := 4; ph := 2;
          when 1 => pat := 4; ph := 0;
          when 2 => pat := 4; ph := 3;
          when 3 => pat := 4; ph := 1;
          when 4 => pat := 0;
          when 5 => pat := 8; ph := 4;
          when 6 => pat := 10;
          when others => pat := 7; ph := 200; cl_v := '0';
        end case;
      elsif li >= 167 and li <= 170 then
        vbl_v := '0'; nvc_v := '1'; sm_v := "01";
        case li - 167 is
          when 0 => pat := 4; ph := 0;
          when 1 => pat := 4; ph := 2;
          when 2 => pat := 0;
          when others => pat := 9;
        end case;
      elsif li >= 171 and li <= 178 then
        vbl_v := '0'; cp_v := "11";
        case li - 171 is
          when 0 => pat := 4; ph := 0;
          when 1 => pat := 11; ph := 0;
          when 2 => pat := 12; ph := 0;
          when 3 => pat := 0;
          when 4 => pat := 5;
          when 5 => pat := 6;
          when 6 => pat := 11; ph := 2;
          when others => pat := 12; ph := 2;
        end case;
      else
        vbl_v := '1';
      end if;

      hbl <= '1' when c < 352 else '0';
      vbl <= vbl_v;
      screen_mode <= sm_v;
      color_palette <= cp_v;
      gray_seam_fix <= gsf_v;
      nvc <= nvc_v;
      color_line <= cl_v;
      video <= video_bit(pat, ph, c) when vbl_v = '0' else '0';
      ioctl_download <= '1' when dl else '0';
      ioctl_index <= "00000010" when dl else (others => '0');
      ioctl_wr <= '1' when wr else '0';
      ioctl_data <= std_logic_vector(to_unsigned(d, 8)) when wr else (others => '0');

      wait until rising_edge(clk);
      wait for 1 ns;

      write(trc_line, integer'image(n));
      write(trc_line, string'(",")); write(trc_line, video);
      write(trc_line, string'(",")); write(trc_line, hbl);
      write(trc_line, string'(",")); write(trc_line, vbl);
      write(trc_line, string'(",")); write(trc_line, screen_mode);
      write(trc_line, string'(",")); write(trc_line, color_palette);
      write(trc_line, string'(",")); write(trc_line, gray_seam_fix);
      write(trc_line, string'(",")); write(trc_line, nvc);
      write(trc_line, string'(",")); write(trc_line, color_line);
      write(trc_line, string'(",")); write(trc_line, ioctl_download);
      write(trc_line, string'(",")); write(trc_line, to_hstring(ioctl_index));
      write(trc_line, string'(",")); write(trc_line, ioctl_wr);
      write(trc_line, string'(",")); write(trc_line, to_hstring(ioctl_data));
      write(trc_line, string'(",")); write(trc_line, vga_hs);
      write(trc_line, string'(",")); write(trc_line, vga_vs);
      write(trc_line, string'(",")); write(trc_line, vga_hbl);
      write(trc_line, string'(",")); write(trc_line, vga_vbl);
      write(trc_line, string'(",")); write(trc_line, to_hstring(vga_r));
      write(trc_line, string'(",")); write(trc_line, to_hstring(vga_g));
      write(trc_line, string'(",")); write(trc_line, to_hstring(vga_b));
      write(trc_line, string'(",")); write(trc_line, ioctl_wait);
      writeline(f, trc_line);
    end loop;

    report "VHDL trace complete" severity note;
    std.env.finish;
  end process stim;

end architecture sim;
