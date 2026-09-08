//============================================================================
// unit_tests/level_2/mister/Apple-II.sv
//
// Level 2 MiSTer integration-test core (barebones).  See PLAN.md in this
// folder for scope, parity notes and acceptance criteria.
//
// DUT: the LEVEL-2 MACHINE - the level_1 machine core (rtl/apple2.v,
// unmodified: both CPU cores muxed on `cpu`, RAM decode, BIOS ROM, timing
// HAL, native video) + the real PS/2 keyboard (rtl/keyboard.v) + the real
// Disk II slot controller (rtl/disk_ii.v: two drive_ii MFM decoders + the
// controller ROM) + one real floppy_track per drive (rtl/floppy_track.sv,
// each with its own dpram track RAM).  Monochrome native video only; no
// slots other than the Disk II, no HDD, no audio.
//
// Machine wiring (reset chain, flash divider, cold-reset RAM force, RAM,
// 60 Hz IRQ, disk_ii/floppy_track wiring) mirrors unit_tests/level_2/
// tb_l2.sv, which mirrors rtl/apple2_top.v + verilator/sim.v.  MiSTer glue
// (hps_io, PLL, video out) follows the root project's Apple-II.sv.
//
// Disk: the two hps_io SD image channels drive the two floppy_track
// instances (channel 0 -> drive 1, channel 1 -> drive 2).  Mounting a
// .nib image via the OSD "Mount image" menu arms that drive; a cold boot
// with a disk on drive 1 runs the ROM's disk-boot routine (DOS 3.3).
//
// Video: proper MiSTer presentation (level-1 pattern, swapped in 2026-09-06
// after the first hardware run): CLK_VIDEO = 57.27 MHz (PLL outclk_0) +
// 4:1 ce_pix divider (14.318 MHz, one sample per machine cycle), R=G=B =
// VIDEO through video_mixer.  Sync pulses derived from the blanking edges
// (the machine exposes HBL/VBL blanking, not syncs): a 68-cycle HSYNC 130
// cycles into HBL and a 3-line VSYNC 33 lines into VBL, matching the
// newsdee vga_controller structure.  Text mode is exact; hires is
// half-sampled (2x stretched) - documented caveat.
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
	output [7:0]  DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input         [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output [1:0]  SDRAM_BA,
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
	output [1:0]  SDRAM2_BA,
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
	.outclk_0(CLK_VIDEO), // 57.27 MHz MiSTer video clock
	.outclk_1(clk_sys) // 14.318 MHz machine master
);

// One native machine sample every four video clocks, matching the working
// core's normal MiSTer presentation cadence.
reg [1:0] video_div = 2'd0;
reg       ce_pix = 1'b0;
always @(posedge CLK_VIDEO) begin
	video_div <= video_div + 1'd1;
	ce_pix <= &video_div;
end

/////////////////  HPS  ///////////////////////////

wire [127:0] status;
wire  [1:0]  buttons;
wire  [10:0] ps2_key;
wire [21:0]  gamma_bus;

parameter CONF_STR = {
	// SS3E000000:200000 = the MiSTer binary save-state DDR region (4 x
	// 2 MiB slots at framework byte base 0x3E000000 - the level_1b
	// convention; the direct 64-bit DDR beat base is 29'h07C00000).
	"Apple-II_L2;SS3E000000:200000;",
	"-;",
	// OSD image-mount items (HPS convention, S<d>,<exts>[,<label>]): the HPS
	// generates one "Mount" menu entry per item; <d> = hps_io image channel
	// (0=drive 1, 1=drive 2), <exts> = 3-char extension groups the file
	// browser filters by.  The HPS does NOT auto-generate these from VDNUM.
	"S0,NIB,Drive 1;",
	"S1,NIB,Drive 2;",
	"O5,CPU,65C02,6502;",
	"O1,OSD Pause,Off,On;",
	"O2,Save State,Off,Save;",
	"O3,Load State,Off,Load;",
	"O6,WP Drive 1,Off,On;",
	"O7,WP Drive 2,Off,On;",
	"O8,Disk LED overlay,Yes,No;",
	"O9,Composite video,Off,On;",
	// Composite knobs (16 states each; see COMPOSITE_ARTIFACT_COLOR_PLAN.md
	// 5.3): the framework writes each option's state index into the 4-bit
	// field at the first ID char's value ("OCD" C=12 -> [15:12], "OHI"
	// H=17 -> [20:17]).  sat step = idx*17 (0..255), hue step = idx*16.
	"OCD,Comp sat,Off,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255;",
	"OHI,Comp hue,0,16,32,48,64,80,96,112,128,144,160,176,192,208,224,240;",
	"R0,Cold Reset;",
	"-;"
};

// OSD pause: hold the CPU (both cores) while the OSD is open (the root
// core's pattern) so the frozen screen can be inspected behind the OSD.
wire osd_pause = status[1] && OSD_STATUS;

// OSD "Composite video" (O9): select the video_mixer_plus composite branch
// (encoded + decoded 1-bit composite) instead of the native monochrome path.
wire use_composite = status[9];

// OSD composite knobs (CONF_STR "OCD"/"OHI" above; 16 states each).  The
// framework writes the option's state index into the 4-bit field at the
// first ID char's value: C=12 -> [15:12], H=17 -> [20:17].  comp_sat_v =
// idx*17 over 0..255 (state 0 = Off/gray, 8 -> 136 ~ unity, 15 -> 255
// over-saturated); comp_hue_v = idx*16 over the 256-step burst phase.
// Decoder-side only: the encoder below keeps unity sat / zero hue.
wire [3:0] comp_sat_idx = status[15:12];
wire [3:0] comp_hue_idx = status[20:17];
wire [7:0] comp_sat_v   = comp_sat_idx * 8'd17;
wire [7:0] comp_hue_v   = {comp_hue_idx, 4'b0000};

// Save-state requests (level_1b pattern): the OSD "Save State"/"Load
// State" options are one-shot - edge-detect the option being armed while
// the OSD is open.
reg save_request_d = 1'b0;
reg load_request_d = 1'b0;
always @(posedge clk_sys) begin
	save_request_d <= status[2] && OSD_STATUS;
	load_request_d <= status[3] && OSD_STATUS;
end
wire save_request = (status[2] && OSD_STATUS) && !save_request_d;
wire load_request = (status[3] && OSD_STATUS) && !load_request_d;

// SD image channel: 2 channels -> the 2 floppy drives (channel 0 -> drive
// 1, channel 1 -> drive 2).  hps_io drives the *_ack/addr/dout/wr side;
// the floppy_track instances drive the *_lba/rd/wr/buff_din side.
wire [31:0] sd_lba    [2];
wire [5:0]  sd_blk_cnt[2];
wire [1:0]  sd_rd;
wire [1:0]  sd_wr;
wire [1:0]  sd_ack;
wire [13:0] sd_buff_addr;
wire [7:0]  sd_buff_dout;
wire [7:0]  sd_buff_din[2];
wire        sd_buff_wr;
wire [1:0]  img_mounted;
wire        img_readonly;
wire [63:0] img_size;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.gamma_bus(gamma_bus),

	.ps2_key(ps2_key),

	// SD image channel: 2 channels -> the 2 floppy drives
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

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
// Mirrors unit_tests/level_2/tb_l2.sv (which mirrors rtl/apple2_top.v +
// the Verilator full sim, sim.v).

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
	// Save-state restore (level_1b pattern): register word 8 carries the
	// wrapper's own reset/flash state so a load reproduces the exact
	// power-on phase.
	if (ss_wren && (ss_addr == 10'd8)) begin
		flash_div      <= ss_wdata[22:0];
		power_on_reset <= ss_wdata[23];
		reset_sync     <= ss_wdata[24];
	end else if (reset_cold == 1'b1 || soft_reset == 1'b1) begin
		power_on_reset <= 1'b1;
		flash_div      <= 23'b0;
	end else begin
		if (flash_div[22] == 1'b1)
			power_on_reset <= 1'b0;
		flash_div <= flash_div + 1'b1;
	end
end

// 60 Hz IRQ (tb_l2.sv): one short IRQ pulse per frame, derived from the
// VBL rising edge.  The ROM's 60 Hz handler keeps the OS 1-second counter
// the power-up/boot path waits on.
reg  [4:0] irq_60hz_cnt = 5'd0;
reg        vbl_irq_d    = 1'b0;
wire       irq_60hz_pulse = (irq_60hz_cnt != 5'd0);
always @(posedge clk_sys) begin: irq_60hz
	vbl_irq_d <= vbl;
	if (vbl && !vbl_irq_d)
		irq_60hz_cnt <= 5'd16;
	else if (irq_60hz_cnt != 5'd0)
		irq_60hz_cnt <= irq_60hz_cnt - 5'd1;
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
// the ROM checks (arms the disk-boot routine).
wire        ram_we_eff   = reset_cold ? 1'b1   : ram_we;
wire [17:0] ram_addr_eff = reset_cold ? 18'h03F4 : ram_addr;
wire [7:0]  ram_di_eff   = reset_cold ? 8'b0    : ram_di;

// Save-state RAM client port (savestate_manager_l1b).  The main RAM is
// two EXPLICIT dpram (altsyncram) instances - the level_1b mister
// pattern, hardware-verified there - because Quartus 17 refuses to
// infer the dual-client inferred arrays: first "asynchronous read
// logic" (a cross-array ternary read), then "unsupported read-during-
// write behavior" (write-through port A + conditional port B in one
// array).  Port A = the machine, port B = the save-state walker.  The
// two write ports are never enabled in the same cycle (machine write
// implies !ss_busy, ss write implies ss_busy).  ss_busy=0 in normal
// operation, so the machine path is unchanged.
wire        ram_ss_bank;
wire [15:0] ram_ss_addr;
wire        ram_ss_rd, ram_ss_wr;
wire [7:0]  ram_ss_wdata, ram_ss_rdata;
wire        ram_we_mach  = ram_we_eff && !ss_busy;

wire [7:0] main_ram_q_a, main_ram_q_b;
wire [7:0] aux_ram_q_a,  aux_ram_q_b;

dpram #(16,8) main_ram (
	.address_a(ram_addr_eff[15:0]), .address_b(ram_ss_addr),
	.clock_a(clk_sys), .clock_b(clk_sys),
	.data_a(ram_di_eff), .data_b(ram_ss_wdata),
	.enable_a(1'b1), .enable_b(1'b1),
	.wren_a(ram_we_mach && !ram_aux),
	.wren_b(ram_ss_wr && !ram_ss_bank && !ss_reset),
	.q_a(main_ram_q_a), .q_b(main_ram_q_b)
);

dpram #(16,8) aux_ram (
	.address_a(ram_addr_eff[15:0]), .address_b(ram_ss_addr),
	.clock_a(clk_sys), .clock_b(clk_sys),
	.data_a(ram_di_eff), .data_b(ram_ss_wdata),
	.enable_a(1'b1), .enable_b(1'b1),
	.wren_a(ram_we_mach && ram_aux),
	.wren_b(ram_ss_wr && ram_ss_bank && !ss_reset),
	.q_a(aux_ram_q_a), .q_b(aux_ram_q_b)
);

// dpram q_a is a combinational NEW_DATA read; one register stage keeps
// the EXACT registered-read timing of the previously verified inferred
// RAM (on a write cycle q_a = the new data, so the write-through
// behavior is preserved byte-for-byte).
always @(posedge clk_sys) begin: ram_do_reg
	ram_do[7:0]  <= main_ram_q_a;
	ram_do[15:8] <= aux_ram_q_a;
end

// Save-state read: the RAW q_b (same wiring as the level_1b mister).
// Port B's address is registered (address_reg_b=CLOCK1), so q_b during
// cycle N+1 holds the byte at the address presented during cycle N -
// exactly the one-cycle latency the manager's protocol samples (ram_rd
// in cycle N, ram_rdata sampled in N+1).
assign ram_ss_rdata = ram_ss_bank ? aux_ram_q_b : main_ram_q_b;

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

// Core slot / timing signals (apple2 outputs -> disk_ii inputs).
wire [15:0] w_addr;
wire [7:0]  w_io_sel;
wire [7:0]  w_dev_sel;
wire        w_io_str;
wire        w_stb;
wire        w_clk_2m;
wire        w_pz;
wire        w_pzr;
wire        w_pzf;

// Disk II drive status (from disk_ii).
wire        d1_active, d2_active;
wire        d1_motor_on, d2_motor_on;
wire        d1_io_active, d2_io_active;
wire        d1_step_active, d2_step_active;
wire        d1_track_zero_step, d2_track_zero_step;
wire [1:0]  disk_ready;

// Disk II track bus (disk_ii <-> floppy_track).
wire [5:0]  t1_track, t2_track;
wire [12:0] t1_addr, t2_addr;
wire [7:0]  t1_di, t2_di, t1_do, t2_do;
wire        t1_we, t2_we, t1_busy, t2_busy;
wire [7:0]  disk_do;   // disk_ii.D_OUT -> core.PD

// Disk mount/change, armed by the hps_io img_mounted pulse (sim.v:605-620).
reg [1:0] disk_mount  = 2'b00;
reg [1:0] disk_change = 2'b00;
always @(posedge clk_sys) begin: disk_mount_regs
	if (img_mounted[0]) begin
		disk_mount[0]  <= img_size != 0;
		disk_change[0] <= ~disk_change[0];
	end
	if (img_mounted[1]) begin
		disk_mount[1]  <= img_size != 0;
		disk_change[1] <= ~disk_change[1];
	end
end

// Machine core.  cpu = ~status[5] (OSD "65C02"=0 -> wdc65c02; "6502"=1 ->
// nmos6502; the newsdee convention).  STALL = OSD pause.  PD = disk_ii
// data out (the Disk II is the only slot peripheral here).
wire video, hbl, vbl;

apple2 d1 (
	.CLK_14M     (clk_sys),
	.CLK_2M      (w_clk_2m),
	.PALMODE     (1'b0),
	.ROMSWITCH   (1'b0),
	.CPU_WAIT    (1'b0),
	.PHASE_ZERO  (w_pz),
	.PHASE_ZERO_R(w_pzr),
	.PHASE_ZERO_F(w_pzf),
	.FLASH_CLK   (flash_clk),
	.reset       (reset_sync),
	.cpu         (active_cpu),
	// OSD pause + save-state freeze (level_1b pattern).
	.STALL       (osd_pause || ss_busy),
	.ADDR        (w_addr),
	.ram_addr    (ram_addr),
	.D           (ram_di),
	.ram_do      (ram_do),
	.aux         (ram_aux),
	.PD          (disk_do),
	.CPU_WE      (),
	.IRQ_n       (~irq_60hz_pulse),
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
	.STB         (w_stb),
	.IO_SELECT   (w_io_sel),
	.DEVICE_SELECT(w_dev_sel),
	.IO_STROBE   (w_io_str),
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
	.DBG_ROM_OUT (),
	// Save-state (level_1b port, 2026-09-08): machine_ce is the
	// manager's freeze - 1 only in IDLE/FREEZE, 0 during the
	// register/RAM walk (the core gates ALL machine state on it;
	// unconnected it ties to GND and the machine is dead - the
	// 2026-09-06 black-screen build).  The ss_* bus carries the
	// per-word register capture/apply; the wrapper mux below owns
	// words 8/9/10 (reset/flash state, spare, CPU select).
	.machine_ce  (machine_ce),
	.ss_addr     (ss_addr),
	.ss_wdata    (ss_wdata),
	.ss_wren     (ss_wren),
	.ss_rdata    (core_ss_rdata),
	.cpu_frozen  (cpu_frozen)
);

/////////////////  SAVE STATE (level_1b port)  /////////////////////
// One atomic coordinator (savestate_manager_l1b) freezes the machine,
// captures/serializes register words 0-10 and both 64 KiB RAM banks,
// and restores them in the order RAM -> machine words 3-10 -> CPU
// words 0-2.  The direct 64-bit DDRAM bridge (savestate_ddr_l1b,
// corrected 2026-09-07: beat base 29'h07C00000, stride 1, burst 1) does
// one acknowledged 64-bit transaction at a time.  V1 scope (level_1b
// map): CPU + main/aux RAM + machine latches + timing/video phase.
// The Disk II path (disk_ii/drive_ii/floppy_track) is NOT in the v1
// state - see SAVESTATE_V2_DISK_MAP.md for the planned v2 extension.
wire [9:0]  ss_addr;
wire [63:0] ss_wdata, ss_rdata, core_ss_rdata;
wire        ss_wren;
wire        machine_ce;
wire        cpu_frozen;
wire        ss_busy, ss_done, ss_error, ss_locked_cpu;
wire        slot_rd, slot_wr, slot_ready;
wire [14:0] slot_addr;
wire [63:0] slot_wdata, slot_rdata;
wire        current_cpu  = ~status[5];
wire        active_cpu   = ss_busy ? ss_locked_cpu : current_cpu;
wire        ss_reset     = reset_cold || reset_warm || soft_reset;

// Wrapper-owned register words (level_1b pattern): 8 = reset/flash
// chain, 9 = spare, 10 = selected CPU.  Everything else is the core's.
assign ss_rdata = (ss_addr == 10'd8) ?
                  {39'd0, reset_sync, power_on_reset, flash_div} :
                  (ss_addr == 10'd9) ? 64'd0 :
                  (ss_addr == 10'd10) ? {63'd0, active_cpu} : core_ss_rdata;

savestate_manager_l1b state_manager (
	.clk(clk_sys), .reset(ss_reset),
	.request_save(save_request), .request_load(load_request),
	.allow_save_state(1'b1), .cpu_type(current_cpu), .cpu_frozen(cpu_frozen),
	.stall(), .machine_ce(machine_ce), .busy(ss_busy), .done(ss_done),
	.error(ss_error), .locked_cpu_type(ss_locked_cpu),
	.ss_addr(ss_addr), .ss_wdata(ss_wdata), .ss_wren(ss_wren), .ss_rdata(ss_rdata),
	.ram_bank(ram_ss_bank), .ram_addr(ram_ss_addr), .ram_rd(ram_ss_rd),
	.ram_wr(ram_ss_wr), .ram_wdata(ram_ss_wdata), .ram_rdata(ram_ss_rdata),
	.slot_addr(slot_addr), .slot_rd(slot_rd), .slot_wr(slot_wr),
	.slot_wdata(slot_wdata), .slot_rdata(slot_rdata), .slot_ready(slot_ready)
);

savestate_ddr_l1b #(.BASE_ADDR(29'h07C00000)) ddr_ss (
	.clk(clk_sys), .reset(ss_reset),
	.slot_addr(slot_addr), .slot_rd(slot_rd), .slot_wr(slot_wr),
	.slot_wdata(slot_wdata), .slot_rdata(slot_rdata), .slot_ready(slot_ready),
	.ddram_clk(DDRAM_CLK), .ddram_busy(DDRAM_BUSY), .ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_addr(DDRAM_ADDR), .ddram_dout(DDRAM_DOUT),
	.ddram_dout_ready(DDRAM_DOUT_READY), .ddram_rd(DDRAM_RD),
	.ddram_din(DDRAM_DIN), .ddram_be(DDRAM_BE), .ddram_we(DDRAM_WE)
);

// Disk II slot controller (slot 6) - mirrors apple2_top.v:528 / tb_l2.sv.
// RESET = the power-on reset (held during POR).  Write protect from the
// OSD (status[6]/status[7]).
disk_ii disk (
	.CLK_14M(clk_sys),
	.CLK_2M(w_clk_2m),
	.PHASE_ZERO(w_pz),
	.IO_SELECT(w_io_sel[6]),
	.DEVICE_SELECT(w_dev_sel[6]),
	.RESET(reset_sync),
	.DISK_READY(disk_ready),
	.A(w_addr),
	.D_IN(ram_di),
	.D_OUT(disk_do),
	.D1_ACTIVE(d1_active),
	.D2_ACTIVE(d2_active),
	.D1_MOTOR_ON(d1_motor_on),
	.D2_MOTOR_ON(d2_motor_on),
	.D1_IO_ACTIVE(d1_io_active),
	.D2_IO_ACTIVE(d2_io_active),
	.D1_STEP_ACTIVE(d1_step_active),
	.D2_STEP_ACTIVE(d2_step_active),
	.D1_TRACK_ZERO_STEP(d1_track_zero_step),
	.D2_TRACK_ZERO_STEP(d2_track_zero_step),
	.D1_WP(status[6]),
	.D2_WP(status[7]),
	.TRACK1(t1_track),
	.TRACK1_ADDR(t1_addr),
	.TRACK1_DI(t1_di),
	.TRACK1_DO(t1_do),
	.TRACK1_WE(t1_we),
	.TRACK1_BUSY(t1_busy),
	.TRACK2(t2_track),
	.TRACK2_ADDR(t2_addr),
	.TRACK2_DI(t2_di),
	.TRACK2_DO(t2_do),
	.TRACK2_WE(t2_we),
	.TRACK2_BUSY(t2_busy)
);

// floppy_track x2: the physical track buffers + SD interface - mirrors
// the full sim (sim.v:645/674) / tb_l2.sv.  Clock = clk_sys (14.318 MHz); the
// SD handshake is edge/byte based, so the clock domain is irrelevant to
// correctness.  Channel 0 -> drive 1, channel 1 -> drive 2.
floppy_track ft1 (
	.clk(clk_sys),
	.reset(reset_sync),
	.ram_addr(t1_addr),
	.ram_di(t1_di),
	.ram_do(t1_do),
	.ram_we(t1_we),
	.track(t1_track),
	.busy(t1_busy),
	.change(disk_change[0]),
	.mount(disk_mount[0]),
	.ready(disk_ready[0]),
	.active(d1_active),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din[0]),
	.sd_buff_wr(sd_buff_wr),
	.sd_lba(sd_lba[0]),
	.sd_rd(sd_rd[0]),
	.sd_wr(sd_wr[0]),
	.sd_ack(sd_ack[0])
);

floppy_track ft2 (
	.clk(clk_sys),
	.reset(reset_sync),
	.ram_addr(t2_addr),
	.ram_di(t2_di),
	.ram_do(t2_do),
	.ram_we(t2_we),
	.track(t2_track),
	.busy(t2_busy),
	.change(disk_change[1]),
	.mount(disk_mount[1]),
	.ready(disk_ready[1]),
	.active(d2_active),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din[1]),
	.sd_buff_wr(sd_buff_wr),
	.sd_lba(sd_lba[1]),
	.sd_rd(sd_rd[1]),
	.sd_wr(sd_wr[1]),
	.sd_ack(sd_ack[1])
);

/////////////////  VIDEO OUT  /////////////////////
// Native monochrome source presented through MiSTer's standard video_mixer.
// The machine core exposes blanking (HBL/VBL), not syncs.  The newsdee
// core derives its syncs in vga_controller.v; we replicate that structure
// here from the raw blanking so the display locks the same way:
//   HSYNC = 68 master cycles, starting 130 cycles after the HBL rise
//           (vga_controller VGA_FRONT_PORCH=130, VGA_HSYNC=68)
//   VSYNC = 3 lines, starting 33 lines after the VBL rise
//           (vga_controller VBL_TO_VSYNC=33, VGA_VSYNC_LINES=3)
// Count cycles/lines WITHIN the blanking interval (reset while active) so
// the pulse is a narrow window inside the blanking, not the whole blanking.
localparam integer HSYNC_FRONT_PORCH = 130;
localparam integer HSYNC_WIDTH       = 68;
localparam integer VSYNC_FRONT_PORCH = 33;
localparam integer VSYNC_LINES       = 3;

// Master cycles since the start of the horizontal blanking interval.
// HBL is high ~350 cycles max, so 10 bits never overflows.
reg [9:0] hblank_cnt = 10'd0;
always @(posedge clk_sys) begin
	if (hbl)
		hblank_cnt <= hblank_cnt + 10'd1;
	else
		hblank_cnt <= 10'd0;
end

// Lines since the start of the vertical blanking interval, counted by the
// HBL rising edges that occur while VBL is high.
reg         hbl_d      = 1'b0;
wire        hbl_rise   = hbl & ~hbl_d;
always @(posedge clk_sys) hbl_d <= hbl;
reg [6:0]   vblank_lines = 7'd0;
always @(posedge clk_sys) begin
	if (vbl) begin
		if (hbl_rise)
			vblank_lines <= vblank_lines + 7'd1;
	end else begin
		vblank_lines <= 7'd0;
	end
end

wire native_hsync = hbl & (hblank_cnt >= HSYNC_FRONT_PORCH) &
                    (hblank_cnt < HSYNC_FRONT_PORCH + HSYNC_WIDTH);
wire native_vsync = vbl & (vblank_lines >= VSYNC_FRONT_PORCH) &
                    (vblank_lines < VSYNC_FRONT_PORCH + VSYNC_LINES);
wire [7:0] native_rgb = {8{video}};

/////////////////  COMPOSITE VIDEO  /////////////////////
// video_mixer_plus' composite branch decodes the composite stream in the
// CLK_VIDEO (57.27 MHz) domain, so the encoder must run there too.  The
// machine clock (14.318 MHz) is CLK_VIDEO/4 via ce_pix: every machine
// signal changes at most once per 4 CLK_VIDEO-cycle window, so a 2-FF
// synchronizer is safe for video/blanking, and ce_pix strobes exactly one
// composite sample per machine cycle (the encoder is clock-domain
// agnostic - it sequences one sample per ce pulse).
reg video_s1, video_s2;
always @(posedge CLK_VIDEO) begin
	video_s1 <= video;
	video_s2 <= video_s1;
end
wire video_c = video_s2;
reg hbl_s1, hbl_s2;
always @(posedge CLK_VIDEO) begin
	hbl_s1 <= hbl;
	hbl_s2 <= hbl_s1;
end
wire hbl_c = hbl_s2;
reg vbl_s1, vbl_s2;
always @(posedge CLK_VIDEO) begin
	vbl_s1 <= vbl;
	vbl_s2 <= vbl_s1;
end
wire vbl_c = vbl_s2;

// Sync derivation in the CLK_VIDEO domain - same structure as the native
// path above, but cycle/line counts tick on ce_pix (machine cycles) and
// the edges are of the synchronized blanking, so the encoder and the
// mixer's decoder see one coherent, mutually aligned signal set.
reg [9:0] hblank_cnt_c = 10'd0;
always @(posedge CLK_VIDEO) begin
	if (ce_pix && hbl_c)
		hblank_cnt_c <= hblank_cnt_c + 10'd1;
	else
		hblank_cnt_c <= 10'd0;
end
reg         hbl_c_d    = 1'b0;
wire        hbl_c_rise = hbl_c & ~hbl_c_d;
always @(posedge CLK_VIDEO) hbl_c_d <= hbl_c;
reg [6:0]   vblank_lines_c = 7'd0;
always @(posedge CLK_VIDEO) begin
	if (vbl_c) begin
		if (hbl_c_rise)
			vblank_lines_c <= vblank_lines_c + 7'd1;
	end else begin
		vblank_lines_c <= 7'd0;
	end
end
wire comp_hsync_c = hbl_c & (hblank_cnt_c >= HSYNC_FRONT_PORCH) &
                    (hblank_cnt_c < HSYNC_FRONT_PORCH + HSYNC_WIDTH);
wire comp_vsync_c = vbl_c & (vblank_lines_c >= VSYNC_FRONT_PORCH) &
                    (vblank_lines_c < VSYNC_FRONT_PORCH + VSYNC_LINES);

// Encoder (unity saturation, zero hue): modulated sample stream out.
// The internal loopback decoder's r/g/b are unconnected here and are
// pruned at synthesis.
wire signed [23:0] comp_sample;
apple_composite #(
	.BURST_START(8),
	.BURST_LEN  (64)
) comp_enc (
	.clk         (CLK_VIDEO),
	.ce          (ce_pix),
	.video       (video_c),
	.hs          (comp_hsync_c),
	.vs          (comp_vsync_c),
	.hb          (hbl_c),
	.vb          (vbl_c),
	.sat         (8'd128),
	.hue         (8'd0),
	.r           (),
	.g           (),
	.b           (),
	.ce_out      (),
	.hs_out      (),
	.vs_out      (),
	.hb_out      (),
	.vb_out      (),
	.comp_sample (comp_sample)
);

// Drive status LED overlay (byte-identical copy of the newsdee core's
// rtl/drive_status_overlay.sv): 2x2 LEDs near the bottom-right of the
// active area, one per drive.  Dim while the selected drive's motor is on;
// bright for ~50 ms after an I/O transfer.  Sits between the native core
// RGB and the video_mixer.  No HDD in this core -> HDD LED tied off.
wire [23:0] drive_overlay_rgb;
drive_status_overlay drive_status_overlay
(
	.clk(clk_sys),
	.reset(reset_cold),
	.enable(~status[8]),		// OSD "Disk LED overlay" (O8)
	.hblank(hbl),
	.vblank(vbl),
	.rgb_in({native_rgb, native_rgb, native_rgb}),
	.drive1_motor(d1_active),
	.drive1_activity(d1_io_active),
	.drive2_motor(d2_active),
	.drive2_activity(d2_io_active),
	.hdd_mounted(1'b0),
	.hdd_activity(1'b0),
	.rgb_out(drive_overlay_rgb)
);

video_mixer_plus #(.LINE_LENGTH(580), .GAMMA(1), .COMP_SPC(4)) video_mixer_plus
(
	.CLK_VIDEO (CLK_VIDEO),
	.CE_PIXEL  (CE_PIXEL),
	.ce_pix    (ce_pix),
	.scandoubler(1'b0),
	.hq2x      (1'b0),
	.use_composite(use_composite),
	.ce_comp   (ce_pix),
	.composite (comp_sample),
	.comp_hs   (comp_hsync_c),
	.comp_vs   (comp_vsync_c),
	.comp_hb   (hbl_c),
	.comp_vb   (vbl_c),
	.comp_burst_start(10'd8),
	.comp_burst_len  (10'd64),
	.comp_sat    (comp_sat_v),
	.comp_hue    (comp_hue_v),
	.comp_smear  (4'd0),
	.comp_luma_delay(4'd0),
	.comp_setup  (16'sd0),
	.comp_luma_gain(16'sd2857),
	.comp_agc    (1'b1),
	.gamma_bus (gamma_bus),
	.R         (drive_overlay_rgb[23:16]),
	.G         (drive_overlay_rgb[15:8]),
	.B         (drive_overlay_rgb[7:0]),
	.HSync     (native_hsync),
	.VSync     (native_vsync),
	.HBlank    (hbl),
	.VBlank    (vbl),
	.HDMI_FREEZE(1'b0),
	.freeze_sync(),
	.VGA_R     (VGA_R),
	.VGA_G     (VGA_G),
	.VGA_B     (VGA_B),
	.VGA_VS    (VGA_VS),
	.VGA_HS    (VGA_HS),
	.VGA_DE    (VGA_DE)
);

assign VIDEO_ARX = 13'd4;
assign VIDEO_ARY = 13'd3;

/////////////////  TIE-OFFS  //////////////////////
// Same patterns as the newsdee Apple-II.sv (unused buses released).

assign USER_OUT  = '1;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML,
         SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
// DDRAM_* is driven by the save-state bridge (ddr_ss above).

assign LED_USER  = 1'b1;
assign LED_POWER = 2'b00;
assign LED_DISK  = {d1_motor_on | d2_motor_on, d1_io_active | d2_io_active};
assign BUTTONS   = 2'b00;
assign VGA_F1    = 1'b0;
assign VGA_SL    = 2'b00;
assign VGA_SCALER  = 1'b0;
assign VGA_DISABLE = 1'b0;
// Freeze the HDMI output while a save/load transaction is in flight
// (level_1b pattern).
assign HDMI_FREEZE = ss_busy;

assign ADC_BUS   = 4'bz;
assign UART_RTS  = 1'b0;
assign UART_TXD  = 1'b0;
assign UART_DTR  = 1'b0;

assign AUDIO_L   = 16'd0;
assign AUDIO_R   = 16'd0;
assign AUDIO_S   = 1'b0;
assign AUDIO_MIX = 2'b00;

endmodule
