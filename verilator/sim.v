`timescale 1ns / 1ps
/*============================================================================
	Aznable (custom 8-bit computer system) - Verilator emu module

	Author: Jim Gregory - https://github.com/JimmyStones/
	Version: 1.1
	Date: 2021-10-17

	This program is free software; you can redistribute it and/or modify it
	under the terms of the GNU General Public License as published by the Free
	Software Foundation; either version 3 of the License, or (at your option)
	any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License along
	with this program. If not, see <http://www.gnu.org/licenses/>.
===========================================================================*/

module emu (

	input clk_sys,
	input reset,
	input soft_reset,
	input menu,
	input [1:0] screen_mode,
	input [1:0] color_palette,
	input text_color,
	input gray_seam_fix,
	input ntsc_vertical_comb,
	input pixel_clock_double,
	input virtual_keyboard_enabled,
	input [1:0] virtual_keyboard_visibility,
	
	input [31:0] joystick_0,
	input [31:0] joystick_1,
	input [31:0] joystick_2,
	input [31:0] joystick_3,
	input [31:0] joystick_4,
	input [31:0] joystick_5,
	
	input [15:0] joystick_l_analog_0,
	input [15:0] joystick_l_analog_1,
	input [15:0] joystick_l_analog_2,
	input [15:0] joystick_l_analog_3,
	input [15:0] joystick_l_analog_4,
	input [15:0] joystick_l_analog_5,
	
	input [15:0] joystick_r_analog_0,
	input [15:0] joystick_r_analog_1,
	input [15:0] joystick_r_analog_2,
	input [15:0] joystick_r_analog_3,
	input [15:0] joystick_r_analog_4,
	input [15:0] joystick_r_analog_5,

	input [7:0] paddle_0,
	input [7:0] paddle_1,
	input [7:0] paddle_2,
	input [7:0] paddle_3,
	input [7:0] paddle_4,
	input [7:0] paddle_5,

	input [8:0] spinner_0,
	input [8:0] spinner_1,
	input [8:0] spinner_2,
	input [8:0] spinner_3,
	input [8:0] spinner_4,
	input [8:0] spinner_5,

	// ps2 alternative interface.
	// [8] - extended, [9] - pressed, [10] - toggles with every press/release
	input [10:0] ps2_key,

	// [24] - toggles with every event
	input [24:0] ps2_mouse,
	input [15:0] ps2_mouse_ext, // 15:8 - reserved(additional buttons), 7:0 - wheel movements

	// [31:0] - seconds since 1970-01-01 00:00:00, [32] - toggle with every change
	input [32:0] timestamp,

	output [7:0] VGA_R,
	output [7:0] VGA_G,
	output [7:0] VGA_B,
	
	output VGA_HS,
	output VGA_VS,
	output VGA_HB,
	output VGA_VB,

	output CE_PIXEL,
	output virtual_keyboard_active_debug,
	output virtual_keyboard_enabled_toggle,
	
	output	[15:0]	AUDIO_L,
	output	[15:0]	AUDIO_R,
	
	input			ioctl_download,
	input			ioctl_wr,
	input [24:0]		ioctl_addr,
	input [7:0]		ioctl_dout,
	input [7:0]		ioctl_index,
	output			ioctl_wait,

	output [31:0] 		sd_lba[3],
	output [9:0] 		sd_rd,
	output [9:0] 		sd_wr,
	input [9:0] 		sd_ack,
	input [8:0] 		sd_buff_addr,
	input [7:0] 		sd_buff_dout,
	output [7:0] 		sd_buff_din[3],
	input 			sd_buff_wr,
	input [9:0] 		img_mounted,
	input 			img_readonly,

	input [63:0] 		img_size,

	input [31:0]		RTC_l,
	input [31:0]		RTC_h,
	input 			RTC_toggle,
	input [32:0]		TIMESTAMP



);
wire [15:0] joystick_a0 =  joystick_l_analog_0;

wire [64:0] RTC = {  RTC_toggle, RTC_h,RTC_l};

wire UART_CTS;
wire UART_RTS;
wire UART_RXD;
wire UART_TXD;
wire UART_DTR;
wire UART_DSR;

wire CLK_VIDEO = clk_sys;

wire  [7:0] pdl  = {~paddle_0[7], paddle_0[6:0]};
wire [15:0] joys = joystick_a0;
wire [15:0] joya = {joys[15:8], joys[7:0]};
wire  [5:0] joyd = joystick_0[5:0] & {2'b11, {2{~|joys[7:0]}}, {2{~|joys[15:8]}}};

assign AUDIO_L = {audio_l,6'b0};
assign AUDIO_R = {audio_r,6'b0};
wire [9:0] audio_l, audio_r;

reg ce_pix;
always @(posedge CLK_VIDEO) begin
	reg div ;
	
	div <= ~div;
	ce_pix <= pixel_clock_double | &div;
end
wire [15:0] hdd_sector;
wire [10:0] filtered_ps2_key;
wire virtual_keyboard_active;
wire virtual_keyboard_commands;
wire [2:0] virtual_keyboard_row;
wire [3:0] virtual_keyboard_col;
wire virtual_keyboard_shift;
wire virtual_keyboard_control;
wire virtual_keyboard_caps;
wire virtual_keyboard_shift_active;
wire virtual_keyboard_control_active;
wire virtual_keyboard_enabled_toggle_int;
wire virtual_open_apple;
wire virtual_closed_apple;
wire virtual_keyboard_transparency_cycle;
wire virtual_keyboard_top;
wire virtual_keyboard_event;
wire virtual_keyboard_pressed;
wire [6:0] virtual_keyboard_code;
wire virtual_keyboard_reset;
wire [7:0] core_R, core_G, core_B;
wire [23:0] virtual_keyboard_rgb;
wire [6:0] virtual_font_character;
wire [2:0] virtual_font_row;
wire [7:0] virtual_font_data;
wire virtual_font_alternate;
wire virtual_font_lowercase;

virtual_keyboard_controller virtual_keyboard_controller
(
	.clk(clk_sys),
	.reset(reset),
	.ps2_key(ps2_key),
	.joystick({joystick_0[12], joystick_0[5:0]}),
	.enabled(virtual_keyboard_enabled),
	.filtered_ps2_key(filtered_ps2_key),
	.active(virtual_keyboard_active),
	.commands_page(virtual_keyboard_commands),
	.selected_row(virtual_keyboard_row),
	.selected_col(virtual_keyboard_col),
	.shift_latched(virtual_keyboard_shift),
	.control_latched(virtual_keyboard_control),
	.caps_latched(virtual_keyboard_caps),
	.shift_active(virtual_keyboard_shift_active),
	.control_active(virtual_keyboard_control_active),
	.enabled_toggle(virtual_keyboard_enabled_toggle_int),
	.open_apple(virtual_open_apple),
	.closed_apple(virtual_closed_apple),
	.transparency_cycle(virtual_keyboard_transparency_cycle),
	.overlay_top(virtual_keyboard_top),
	.virtual_event(virtual_keyboard_event),
	.virtual_pressed(virtual_keyboard_pressed),
	.virtual_code(virtual_keyboard_code),
	.command_reset(virtual_keyboard_reset)
);

assign virtual_keyboard_active_debug = virtual_keyboard_active;
assign virtual_keyboard_enabled_toggle = virtual_keyboard_enabled_toggle_int;

assign sd_lba[1] = {16'b0,hdd_sector};

assign CE_PIXEL=ce_pix;
wire led;
wire hbl,vbl;
wire fd_write;
wire	fd_write_disk;
wire	fd_read_disk;
wire [13:0] fd_track_addr;
wire [7:0] fd_data_in;
wire [7:0] fd_data_in1;
wire [7:0] fd_data_in2;
wire [7:0] fd_data_do;

always @(posedge clk_sys) begin
	//if (soft_reset) $display("soft_reset %x",soft_reset);
end
apple2_top apple2_top
(
	.CLK_14M(clk_sys),
	.CLK_50M(CLK_50M),
	.CPU_WAIT(cpu_wait_hdd  ),
	.cpu_type(1'b0), // 0 6502, 1 65C02

	.reset_cold(reset),
	.reset_warm(soft_reset | virtual_keyboard_reset),

	.hblank(VGA_HB),
	.vblank(VGA_VB),
	.hsync(VGA_HS),
	.vsync(VGA_VS),
	.r(core_R),
	.g(core_G),
	.b(core_B),
	.SCREEN_MODE(screen_mode),
	.TEXT_COLOR(text_color),
	.COLOR_PALETTE(color_palette),
	.GRAY_SEAM_FIX(gray_seam_fix),
	.NTSC_VERTICAL_COMB(ntsc_vertical_comb),
	.ioctl_addr(ioctl_addr),
	.ioctl_data(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_wait(ioctl_wait),

	.AUDIO_L(audio_l),
	.AUDIO_R(audio_r),
	.TAPE_IN(tape_adc_act & tape_adc),

	.PS2_Key(filtered_ps2_key),
	.virtual_keyboard_active(virtual_keyboard_active),
	.virtual_keyboard_event(virtual_keyboard_event),
	.virtual_keyboard_pressed(virtual_keyboard_pressed),
	.virtual_keyboard_code(virtual_keyboard_code),
	.virtual_control(virtual_keyboard_control_active),
	.virtual_open_apple(virtual_open_apple),
	.virtual_closed_apple(virtual_closed_apple),

	.joy(virtual_keyboard_active ? 6'h00 : joyd),
	.joy_an(virtual_keyboard_active ? 16'h0000 : joya),

	.mb_enabled(1'b1),


	.TRACK1(TRACK1),
	.TRACK1_ADDR(TRACK1_RAM_ADDR),
	.TRACK1_DI(TRACK1_RAM_DI),
	.TRACK1_DO (TRACK1_RAM_DO),
	.TRACK1_WE (TRACK1_RAM_WE),
	.TRACK1_BUSY (TRACK1_RAM_BUSY),
	//-- Track buffer interface disk 2
	.TRACK2(TRACK2),
	.TRACK2_ADDR(TRACK2_RAM_ADDR),
	.TRACK2_DI(TRACK2_RAM_DI),
	.TRACK2_DO (TRACK2_RAM_DO),
	.TRACK2_WE (TRACK2_RAM_WE),
	.TRACK2_BUSY (TRACK2_RAM_BUSY),

	.DISK_READY(DISK_READY),
	.D1_ACTIVE(D1_ACTIVE),
	.D2_ACTIVE(D2_ACTIVE),
	.D1_MOTOR_ON(D1_MOTOR_ON),
	.D2_MOTOR_ON(D2_MOTOR_ON),
	.D1_IO_ACTIVE(D1_IO_ACTIVE),
	.D2_IO_ACTIVE(D2_IO_ACTIVE),
	.D1_STEP_ACTIVE(D1_STEP_ACTIVE),
	.D2_STEP_ACTIVE(D2_STEP_ACTIVE),
	.D1_TRACK_ZERO_STEP(D1_TRACK_ZERO_STEP),
	.D2_TRACK_ZERO_STEP(D2_TRACK_ZERO_STEP),
	.D1_WP(disk_protect[0]),
	.D2_WP(disk_protect[1]),
	.DISK_ACT(led),


	
	.HDD_SECTOR(hdd_sector /*sd_lba[1]*/),
	.HDD_READ(hdd_read),
	.HDD_WRITE(hdd_write),
	.HDD_MOUNTED(hdd_mounted),
	.HDD_PROTECT(hdd_protect),
	.HDD_RAM_ADDR(sd_buff_addr),
	.HDD_RAM_DI(sd_buff_dout),
	.HDD_RAM_DO(sd_buff_din[1]),
	.HDD_RAM_WE(sd_buff_wr & sd_ack[1]),

	.ram_addr(ram_addr),
	.ram_do(ram_dout),
	.ram_di(ram_din),
	.ram_we(ram_we),
	.ram_aux(ram_aux),


	.UART_TXD(UART_TXD),
	.UART_RXD(UART_RXD),
	.UART_RTS(UART_RTS),
	.UART_CTS(UART_CTS),
	.UART_DTR(UART_DTR),
	.UART_DSR(UART_DSR),
	.RTC(RTC)


);

apple2_font_rom apple2_font_rom
(
	.CLK_14M(clk_sys),
	.ROMSWITCH(1'b1),
	.alternate_character(virtual_font_alternate),
	.lowercase_character(virtual_font_lowercase),
	.character_code(virtual_font_character),
	.glyph_row(virtual_font_row),
	.ioctl_addr(ioctl_addr),
	.ioctl_data(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.glyph_data(virtual_font_data)
);

virtual_keyboard_overlay virtual_keyboard_overlay
(
	.clk(clk_sys),
	.reset(reset),
	.active(virtual_keyboard_active),
	.commands_page(virtual_keyboard_commands),
	.selected_row(virtual_keyboard_row),
	.selected_col(virtual_keyboard_col),
	.shift_latched(virtual_keyboard_shift_active),
	.control_latched(virtual_keyboard_control_active),
	.caps_latched(virtual_keyboard_caps),
	.open_apple(virtual_open_apple),
	.closed_apple(virtual_closed_apple),
	.transparency(virtual_keyboard_visibility),
	.overlay_top(virtual_keyboard_top),
	.hblank(VGA_HB),
	.vblank(VGA_VB),
	.rgb_in({core_R, core_G, core_B}),
	.font_alternate(virtual_font_alternate),
	.font_lowercase(virtual_font_lowercase),
	.font_character(virtual_font_character),
	.font_row(virtual_font_row),
	.font_data(virtual_font_data),
	.rgb_out(virtual_keyboard_rgb)
);

assign {VGA_R, VGA_G, VGA_B} = virtual_keyboard_rgb;


wire [7:0] R,G,B;
wire HSync, VSync, HBlank, VBlank;


wire [17:0] ram_addr;
reg  [15:0] ram_dout;
wire  [7:0]	ram_din;
wire        ram_we;
wire        ram_aux;

reg [7:0] ram0[196608];
always @(posedge clk_sys) begin
	if(ram_we & ~ram_aux) begin
		ram0[ram_addr] <= ram_din;
		ram_dout[7:0]  <= ram_din;
	end else begin
		ram_dout[7:0]  <= ram0[ram_addr];
	end
end

reg [7:0] ram1[65536];
always @(posedge clk_sys) begin
	if(ram_we & ram_aux) begin
		ram1[ram_addr[15:0]] <= ram_din;
		ram_dout[15:8] <= ram_din;
	end else begin
		ram_dout[15:8] <= ram1[ram_addr[15:0]];
	end
end

wire  [5:0] track1;
wire  [5:0] track2;
reg   [3:0] track_sec;
wire         cpu_wait_fdd = cpu_wait_fdd1|cpu_wait_fdd2;
wire         cpu_wait_fdd1;
wire         cpu_wait_fdd2;


assign sd_rd = { 7'b0, sd_rd_fdd_b,sd_rd_hd,sd_rd_fdd_a };
assign sd_wr = { 7'b0, sd_wr_fdd_b,sd_wr_hd,sd_wr_fdd_a };
assign fd_data_in = fd_disk_1 ? fd_data_in1 : fd_disk_2 ? fd_data_in2 : 8'hFF;
wire fd_disk_1;
wire fd_disk_2;
wire sd_rd_fdd_a;
wire sd_wr_fdd_a;
wire sd_rd_fdd_b;
wire sd_wr_fdd_b;


reg  hdd_mounted = 0;
wire hdd_read;
wire hdd_write;
reg  hdd_protect;
reg  cpu_wait_hdd = 0;

reg  sd_rd_hd;
reg  sd_wr_hd;

always @(posedge clk_sys) begin
	reg old_ack ;
	reg hdd_read_pending ;
	reg hdd_write_pending ;
	reg state;

	old_ack <= sd_ack[1];
	hdd_read_pending <= hdd_read_pending | hdd_read;
	hdd_write_pending <= hdd_write_pending | hdd_write;

	if (img_mounted[1]) begin
		hdd_mounted <= img_size != 0;
		hdd_protect <= img_readonly;
	end

	if(reset) begin
		state <= 0;
		cpu_wait_hdd <= 0;
		hdd_read_pending <= 0;
		hdd_write_pending <= 0;
		sd_rd_hd <= 0;
		sd_wr_hd <= 0;
	end
	else if(!state) begin
		if (hdd_read_pending | hdd_write_pending) begin
			state <= 1;
			sd_rd_hd <= hdd_read_pending;
			sd_wr_hd <= hdd_write_pending;
			cpu_wait_hdd <= 1;
		end
	end
	else begin
		if (~old_ack & sd_ack[1]) begin
			hdd_read_pending <= 0;
			hdd_write_pending <= 0;
			sd_rd_hd <= 0;
			sd_wr_hd <= 0;
			$display("~old ack %x sd_ack[1] %x",~old_ack,sd_ack[1]);
		end
		else if(old_ack & ~sd_ack[1]) begin
			$display("old ack %x ~sd_ack[1] %x",old_ack,~sd_ack[1]);
			state <= 0;
			cpu_wait_hdd <= 0;
		end
	end
end


always @(posedge clk_sys) begin
	if (img_mounted[0]) begin
		disk_mount[0] <= img_size != 0;
		DISK_CHANGE[0] <= ~DISK_CHANGE[0];
		disk_protect[0] <= img_readonly;
	end
end
always @(posedge clk_sys) begin
	if (img_mounted[2]) begin
		disk_mount[1] <= img_size != 0;
		DISK_CHANGE[1] <= ~DISK_CHANGE[1];
		disk_protect[1] <= img_readonly;
	end
end
wire D1_ACTIVE,D2_ACTIVE;
wire D1_MOTOR_ON,D2_MOTOR_ON;
wire D1_IO_ACTIVE,D2_IO_ACTIVE;
wire D1_STEP_ACTIVE,D2_STEP_ACTIVE;
wire D1_TRACK_ZERO_STEP,D2_TRACK_ZERO_STEP;
wire TRACK1_RAM_BUSY;
wire [12:0] TRACK1_RAM_ADDR;
wire [7:0] TRACK1_RAM_DI;
wire [7:0] TRACK1_RAM_DO;
wire TRACK1_RAM_WE;
wire [5:0] TRACK1;

wire TRACK2_RAM_BUSY;
wire [12:0] TRACK2_RAM_ADDR;
wire [7:0] TRACK2_RAM_DI;
wire [7:0] TRACK2_RAM_DO;
wire TRACK2_RAM_WE;
wire [5:0] TRACK2;

wire [1:0] DISK_READY;
reg [1:0] DISK_CHANGE;
reg [1:0]disk_mount;
reg [1:0] disk_protect;



floppy_track floppy_track_1
(
   .clk(clk_sys),
	.reset(reset),

	.ram_addr(TRACK1_RAM_ADDR),
	.ram_di(TRACK1_RAM_DI),
	.ram_do(TRACK1_RAM_DO),
	.ram_we(TRACK1_RAM_WE),

	.track (TRACK1),
	.busy  (TRACK1_RAM_BUSY),
   .change(DISK_CHANGE[0]),
   .mount (disk_mount[0]),
   .ready  (DISK_READY[0]),
   .active (D1_ACTIVE),

   .sd_buff_addr (sd_buff_addr),
   .sd_buff_dout (sd_buff_dout),
   .sd_buff_din  (sd_buff_din[0]),
   .sd_buff_wr   (sd_buff_wr),

   .sd_lba       (sd_lba[0] ),
   .sd_rd        (sd_rd[0]),
   .sd_wr       ( sd_wr[0]),
   .sd_ack       (sd_ack[0])	
);


floppy_track floppy_track_2
(
   .clk(clk_sys),
	.reset(reset),

	.ram_addr(TRACK2_RAM_ADDR),
	.ram_di(TRACK2_RAM_DI),
	.ram_do(TRACK2_RAM_DO),
	.ram_we(TRACK2_RAM_WE),

	.track (TRACK2),
	.busy  (TRACK2_RAM_BUSY),
   .change(DISK_CHANGE[1]),
   .mount (disk_mount[1]),
   .ready  (DISK_READY[1]),
   .active (D2_ACTIVE),

   .sd_buff_addr (sd_buff_addr),
   .sd_buff_dout (sd_buff_dout),
   .sd_buff_din  (sd_buff_din[2]),
   .sd_buff_wr   (sd_buff_wr),

   .sd_lba       (sd_lba[2] ),
   .sd_rd        (sd_rd[2]),
   .sd_wr       ( sd_wr[2]),
   .sd_ack       (sd_ack[2])	
);


wire fd_busy;
wire sd_busy;
reg ch1_rd;
always @(posedge CLK_VIDEO) begin
	reg state;
	ch1_rd<=0;
	
	if (~fd_busy & fd_read_disk)
		ch1_rd <=1;
end

	



/* verilator lint_on PINMISSING */

// Debug defines
`define DEBUG_SIMULATION


endmodule 

