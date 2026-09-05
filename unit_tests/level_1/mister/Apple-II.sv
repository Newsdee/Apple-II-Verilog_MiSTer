//============================================================================
// unit_tests/level_1/mister/Apple-II.sv
//
// Level 1 MiSTer integration-test core (barebones).  See PLAN.md in this
// folder for scope, parity notes and acceptance criteria.
//
// DUT: the LEVEL-1 MACHINE - rtl/apple2.v (unmodified: both CPU cores
// muxed on `cpu`, RAM decode, BIOS ROM, timing HAL, native video pipeline)
// + the real PS/2 keyboard (rtl/keyboard.v, unmodified).  Monochrome
// native video only; no slots, drives, host I/O or audio.
//
// Machine wiring (reset chain, flash divider, cold-reset RAM force, RAM)
// mirrors unit_tests/level_1/tb_l1.sv, which mirrors rtl/apple2_top.v.
// MiSTer glue (hps_io, PLL, video out) follows the root project's
// Apple-II.sv (the port list below is that core's, unchanged).
//
// Video: CLK_VIDEO = 14.318 MHz, CE_PIXEL = ~HBL (1 sample per master
// cycle, the tb_l1_gui presentation), R=G=B = VIDEO.  Sync pulses derived
// from the blanking edges (machine exposes blanking, not syncs).  Text
// mode is exact; hires is half-sampled (2x stretched) - documented
// caveat, out of scope for this level.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);


/////////////////  CLOCKS  ////////////////////////

wire clk_sys;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(),      // 57.27 MHz - unused at this level (color pipeline)
	.outclk_1(clk_sys) // 14.318 MHz machine master
);

// Level 1 pixel master = the machine master (no 57.27 MHz color pipeline).
assign CLK_VIDEO = clk_sys;

/////////////////  HPS  ///////////////////////////

wire [127:0] status;
wire  [1:0]  buttons;
wire  [10:0] ps2_key;
wire [21:0]  gamma_bus;

parameter CONF_STR = {
	"Apple-II_L1;",
	"-;",
	"O5,CPU,65C02,6502;",
	"O1,OSD Pause,Off,On;",
	"R0,Cold Reset;",
	"-;"
};

// OSD pause: hold the CPU (both cores) while the OSD is open (the root
// core's pattern) so the frozen screen can be inspected behind the OSD.
wire osd_pause = status[1] && OSD_STATUS;

// SD image channel: unused at this level (no drives).  Array inputs are
// driven with constants via a generate (Quartus 17 does not parse SV
// assignment patterns).
wire [31:0] sd_lba    [3];
wire [5:0]  sd_blk_cnt[3];
wire [7:0]  sd_buff_din[3];
genvar gi;
generate
	for (gi = 0; gi < 3; gi = gi + 1) begin : sd_tieoff
		assign sd_lba[gi]     = 32'd0;
		assign sd_blk_cnt[gi] = 6'd0;
		assign sd_buff_din[gi]= 8'd0;
	end
endgenerate

hps_io #(.CONF_STR(CONF_STR), .VDNUM(3)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.gamma_bus(gamma_bus),

	.ps2_key(ps2_key),

	// SD image channel (tied off - no drives at this level)
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(3'b000),
	.sd_wr(3'b000),
	.sd_buff_din(sd_buff_din),

	// ioctl / ROM download: unused
	.ioctl_wait(1'b0),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din(8'd0),

	// core -> status writes: none at this level
	.status_in(128'd0),
	.status_set(1'b0),
	.status_menumask(16'd0),
	.info_req(1'b0),
	.info(8'd0),

	// video control: none
	.video_rotated(1'b0),
	.new_vmode(1'b0),

	// physical PS/2 lines: the HPS forwards the keyboard via the io
	// protocol (ps2_key above); these are unused in HPS mode
	.ps2_kbd_clk_in(1'b0),
	.ps2_kbd_data_in(1'b0),
	.ps2_kbd_led_status(3'd0),
	.ps2_kbd_led_use(3'd0),
	.ps2_mouse_clk_in(1'b0),
	.ps2_mouse_data_in(1'b0),

	// gamepad rumble: no gamepad at this level
	.joystick_0_rumble(16'd0),
	.joystick_1_rumble(16'd0),
	.joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0),
	.joystick_4_rumble(16'd0),
	.joystick_5_rumble(16'd0)
);

/////////////////  MACHINE  ///////////////////////
// Mirrors unit_tests/level_1/tb_l1.sv (which mirrors rtl/apple2_top.v).

// Reset chain (apple2_top.v:315-330): power-on reset set by cold reset or
// keyboard soft reset (F2), held until the 23-bit flash divider reaches
// bit 22 (~2^22 cycles ~= 294 ms at 14.3 MHz).
wire reset_cold = RESET | status[0];
wire reset_warm = buttons[1];
wire soft_reset;

reg  [22:0] flash_div = 23'b0;
wire        flash_clk = flash_div[22];
reg         power_on_reset = 1'b1;
reg         reset_sync;

always @(posedge clk_sys) begin: reset_chain
	reset_sync <= reset_warm | power_on_reset;
	if (reset_cold == 1'b1 || soft_reset == 1'b1) begin
		power_on_reset <= 1'b1;
		flash_div      <= 23'b0;
	end else begin
		if (flash_div[22] == 1'b1)
			power_on_reset <= 1'b0;
		flash_div <= flash_div + 1'b1;
	end
end

// RAM: 64 K main + 64 K aux, 1-ce latch (the newsdee Apple-II.sv /
// tb_l1.sv pattern).
wire [17:0] ram_addr;
wire  [7:0] ram_di;
reg  [15:0] ram_do;
wire        ram_we;
wire        ram_aux;

// Cold-reset RAM force (apple2_top.v:385-387): while reset_cold the RAM
// interface is held at (we=1, addr=$3F4, data=0) - the cold-boot flag
// the ROM checks.
wire        ram_we_eff   = reset_cold ? 1'b1   : ram_we;
wire [17:0] ram_addr_eff = reset_cold ? 18'h03F4 : ram_addr;
wire [7:0]  ram_di_eff   = reset_cold ? 8'b0    : ram_di;

reg [7:0] ram0 [0:65535];
reg [7:0] ram1 [0:65535];

always @(posedge clk_sys) begin: core_ram
	if (ram_we_eff & ~ram_aux) begin
		ram0[ram_addr_eff[15:0]] <= ram_di_eff;
		ram_do[7:0]              <= ram_di_eff;
	end else begin
		ram_do[7:0]              <= ram0[ram_addr_eff[15:0]];
	end
	if (ram_we_eff & ram_aux) begin
		ram1[ram_addr_eff[15:0]] <= ram_di_eff;
		ram_do[15:8]             <= ram_di_eff;
	end else begin
		ram_do[15:8]             <= ram1[ram_addr_eff[15:0]];
	end
end

// Keyboard: real PS/2 interface; the HPS forwards the physical keyboard
// via hps_io.ps2_key.  CLK_14M clocks the PS/2 decode state machine
// (newsdee apple2_top.vhd:631).  Virtual-keyboard ports tied off (no VK
// at this level).  reset = reset_cold only so a warm reset does not lose
// keyboard state (newsdee comment, apple2_top.vhd:641-643).  joy_* tied
// off (JOY_TO_KEY macro is set by the qsf, as in newsdee; no joy_to_key
// module at this level).
wire        read_key;
wire [7:0]  K;
wire        akd;

keyboard kb (
	.CLK_14M             (clk_sys),
	.PS2_Key             (ps2_key),
	.virtual_active      (1'b0),
	.virtual_event       (1'b0),
	.virtual_pressed     (1'b0),
	.virtual_code        (7'b0),
	.virtual_control     (1'b0),
	.virtual_open_apple  (1'b0),
	.virtual_closed_apple(1'b0),
	.reads               (read_key),
	.reset               (reset_cold),
	.akd                 (akd),
	.K                   (K),
	.open_apple          (),
	.closed_apple        (),
	.soft_reset          (soft_reset),
	.video_toggle        (),
	.palette_toggle      (),
	.joy_key_code        (7'b0),
	.joy_key_press       (1'b0)
);

// Machine core.  cpu = ~status[5] (OSD "65C02"=0 -> wdc65c02; "6502"=1 ->
// nmos6502; the newsdee convention).  STALL = OSD pause.
wire video, hbl, vbl;

apple2 d1 (
	.CLK_14M     (clk_sys),
	.CLK_2M      (),
	.PALMODE     (1'b0),
	.ROMSWITCH   (1'b0),
	.CPU_WAIT    (1'b0),
	.PHASE_ZERO  (),
	.PHASE_ZERO_R(),
	.PHASE_ZERO_F(),
	.FLASH_CLK   (flash_clk),
	.reset       (reset_sync),
	.cpu         (~status[5]),
	.STALL       (osd_pause),
	.ADDR        (),
	.ram_addr    (ram_addr),
	.D           (ram_di),
	.ram_do      (ram_do),
	.aux         (ram_aux),
	.PD          (8'h00),
	.CPU_WE      (),
	.IRQ_n       (1'b1),
	.NMI_n       (1'b1),
	.ram_we      (ram_we),
	.VIDEO       (video),
	.COLOR_LINE  (),
	.TEXT_MODE   (),
	.HBL         (hbl),
	.VBL         (vbl),
	.K           (K),
	.READ_KEY    (read_key),
	.AKD         (akd),
	.AN          (),
	.GAMEPORT    (8'h00),
	.PDL_STROBE  (),
	.STB         (),
	.IO_SELECT   (),
	.DEVICE_SELECT(),
	.IO_STROBE   (),
	.ioctl_addr  (25'b0),
	.ioctl_data  (8'b0),
	.ioctl_index (8'b0),
	.ioctl_download(1'b0),
	.ioctl_wr    (1'b0),
	.saturn_5_inslot(1'b0),
	.speaker     (),
	.DBG_T65_REGS(),
	.DBG_DI      (),
	.DBG_ROM_ADDR(),
	.DBG_ROM_OUT ()
);

/////////////////  VIDEO OUT  /////////////////////
// Native monochrome, 1 sample per master cycle (tb_l1_gui presentation).
// The machine core exposes blanking (HBL/VBL), not syncs: narrow sync
// pulses are the first 64 master cycles of HBL / 512 of VBL (saturating
// counters - no wrap artifacts).
reg [7:0]  hsync_cnt = 8'd0;
reg [11:0] vsync_cnt = 12'd0;

always @(posedge clk_sys) begin
	if (!hbl && hsync_cnt < 8'd200)
		hsync_cnt <= hsync_cnt + 1'd1;
	else if (hbl)
		hsync_cnt <= 8'd0;
	if (!vbl && vsync_cnt < 12'd1024)
		vsync_cnt <= vsync_cnt + 1'd1;
	else if (vbl)
		vsync_cnt <= 12'd0;
end

assign CE_PIXEL  = ~hbl;
assign VGA_R     = {8{video}};
assign VGA_G     = {8{video}};
assign VGA_B     = {8{video}};
assign VGA_HS    = hbl & (hsync_cnt < 8'd64);
assign VGA_VS    = vbl & (vsync_cnt < 12'd512);
assign VGA_DE    = ~hbl & ~vbl;
assign VIDEO_ARX = 13'd4;
assign VIDEO_ARY = 13'd3;

/////////////////  TIE-OFFS  //////////////////////
// Same patterns as the newsdee Apple-II.sv (unused buses released).

assign USER_OUT  = '1;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML,
         SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE,
         DDRAM_RD, DDRAM_WE} = 0;

assign LED_USER  = 1'b1;
assign LED_POWER = 2'b00;
assign LED_DISK  = 2'b00;
assign BUTTONS   = 2'b00;
assign VGA_F1    = 1'b0;
assign VGA_SL    = 2'b00;
assign VGA_SCALER  = 1'b0;
assign VGA_DISABLE = 1'b0;
assign HDMI_FREEZE = 1'b0;

assign ADC_BUS   = 4'bz;
assign UART_RTS  = 1'b0;
assign UART_TXD  = 1'b0;
assign UART_DTR  = 1'b0;

assign AUDIO_L   = 16'd0;
assign AUDIO_R   = 16'd0;
assign AUDIO_S   = 1'b0;
assign AUDIO_MIX = 2'b00;

endmodule
