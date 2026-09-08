// Level 1b MiSTer wrapper: Apple II level 1 machine plus atomic save-state DDR.
// This wrapper keeps the level-1 video and keyboard path intact while one
// coordinator serializes the machine registers and both RAM banks.

module emu
(
  input CLK_50M,
  input RESET,
  inout [48:0] HPS_BUS,
  output CLK_VIDEO,
  output CE_PIXEL,
  output [12:0] VIDEO_ARX,
  output [12:0] VIDEO_ARY,
  output [7:0] VGA_R, VGA_G, VGA_B,
  output VGA_HS, VGA_VS, VGA_DE,
  output VGA_F1,
  output [1:0] VGA_SL,
  output VGA_SCALER,
  output VGA_DISABLE,
  input [11:0] HDMI_WIDTH,
  input [11:0] HDMI_HEIGHT,
  output HDMI_FREEZE,
  output LED_USER,
  output [1:0] LED_POWER,
  output [1:0] LED_DISK,
  output [1:0] BUTTONS,
  input CLK_AUDIO,
  output [15:0] AUDIO_L, AUDIO_R,
  output AUDIO_S,
  output [1:0] AUDIO_MIX,
  inout [3:0] ADC_BUS,
  output SD_SCK, SD_MOSI,
  input SD_MISO,
  output SD_CS,
  input SD_CD,
  output DDRAM_CLK,
  input DDRAM_BUSY,
  output [7:0] DDRAM_BURSTCNT,
  output [28:0] DDRAM_ADDR,
  input [63:0] DDRAM_DOUT,
  input DDRAM_DOUT_READY,
  output DDRAM_RD,
  output [63:0] DDRAM_DIN,
  output [7:0] DDRAM_BE,
  output DDRAM_WE,
  output SDRAM_CLK,
  output SDRAM_CKE,
  output [12:0] SDRAM_A,
  output [1:0] SDRAM_BA,
  inout [15:0] SDRAM_DQ,
  output SDRAM_DQML, SDRAM_DQMH,
  output SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE,
  input UART_CTS,
  output UART_RTS,
  input UART_RXD,
  output UART_TXD,
  output UART_DTR,
  input UART_DSR,
  input [6:0] USER_IN,
  output [6:0] USER_OUT,
  input OSD_STATUS
);
  wire clk_sys;
  wire [127:0] status;
  wire [1:0] buttons;
  wire [10:0] ps2_key;
  wire [21:0] gamma_bus;

  reg save_request_d = 1'b0;
  reg load_request_d = 1'b0;
  always @(posedge clk_sys) begin
    save_request_d <= status[2] && OSD_STATUS;
    load_request_d <= status[3] && OSD_STATUS;
  end
  wire save_request = (status[2] && OSD_STATUS) && !save_request_d;
  wire load_request = (status[3] && OSD_STATUS) && !load_request_d;
  wire reset_cold = RESET | status[0];
  wire reset_warm = buttons[1];
  wire soft_reset;
  wire osd_pause = status[1] && OSD_STATUS;

  parameter CONF_STR = {
    "Apple-II_L1B;SS3E000000:200000;",
    "-;",
    "O5,CPU,65C02,6502;",
    "O1,OSD Pause,Off,On;",
    "O2,Save State,Off,Save;",
    "O3,Load State,Off,Load;",
    "R0,Cold Reset;",
    "-;"
  };

  wire [31:0] sd_lba [3];
  wire [5:0] sd_blk_cnt[3];
  wire [7:0] sd_buff_din[3];
  genvar gi;
  generate
    for (gi = 0; gi < 3; gi = gi + 1) begin : sd_tieoff
      assign sd_lba[gi] = 32'd0;
      assign sd_blk_cnt[gi] = 6'd0;
      assign sd_buff_din[gi] = 8'd0;
    end
  endgenerate

  hps_io #(.CONF_STR(CONF_STR), .VDNUM(3)) hps_io (
    .clk_sys(clk_sys), .HPS_BUS(HPS_BUS),
    .buttons(buttons), .status(status), .gamma_bus(gamma_bus), .ps2_key(ps2_key),
    .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(3'b000), .sd_wr(3'b000),
    .sd_buff_din(sd_buff_din),
    .ioctl_wait(1'b0), .ioctl_upload_req(1'b0), .ioctl_upload_index(8'd0), .ioctl_din(8'd0),
    .status_in(128'd0), .status_set(1'b0), .status_menumask(16'd0),
    .info_req(1'b0), .info(8'd0), .video_rotated(1'b0), .new_vmode(1'b0),
    .ps2_kbd_clk_in(1'b0), .ps2_kbd_data_in(1'b0), .ps2_kbd_led_status(3'd0),
    .ps2_kbd_led_use(3'd0), .ps2_mouse_clk_in(1'b0), .ps2_mouse_data_in(1'b0),
    .joystick_0_rumble(16'd0), .joystick_1_rumble(16'd0), .joystick_2_rumble(16'd0),
    .joystick_3_rumble(16'd0), .joystick_4_rumble(16'd0), .joystick_5_rumble(16'd0)
  );

  wire [22:0] flash_div;
  reg [22:0] flash_counter = 23'd0;
  assign flash_div = flash_counter;
  reg power_on_reset = 1'b1;
  reg reset_sync;
  always @(posedge clk_sys) begin
    reset_sync <= reset_warm | power_on_reset;
    if (ss_wren && (ss_addr == 10'd8)) begin
      flash_counter <= ss_wdata[22:0];
      power_on_reset <= ss_wdata[23];
      reset_sync <= ss_wdata[24];
    end else if (reset_cold || soft_reset) begin
      power_on_reset <= 1'b1;
      flash_counter <= 23'd0;
    end else if (machine_ce) begin
      if (flash_counter[22]) power_on_reset <= 1'b0;
      flash_counter <= flash_counter + 1'b1;
    end
  end

  wire [17:0] ram_addr;
  wire [7:0] ram_di;
  wire [15:0] ram_do;
  wire ram_we, ram_aux;
  wire ram_we_eff = reset_cold ? 1'b1 : ram_we;
  wire [17:0] ram_addr_eff = reset_cold ? 18'h03F4 : ram_addr;
  wire [7:0] ram_di_eff = reset_cold ? 8'd0 : ram_di;

  wire read_key;
  wire [7:0] K;
  wire akd;
  keyboard kb (
    .CLK_14M(clk_sys), .PS2_Key(ps2_key), .virtual_active(1'b0), .virtual_event(1'b0),
    .virtual_pressed(1'b0), .virtual_code(7'd0), .virtual_control(1'b0),
    .virtual_open_apple(1'b0), .virtual_closed_apple(1'b0), .reads(read_key),
    .reset(reset_cold), .akd(akd), .K(K), .open_apple(), .closed_apple(),
    .soft_reset(soft_reset), .video_toggle(), .palette_toggle(),
    .joy_key_code(7'd0), .joy_key_press(1'b0)
  );

  wire [9:0] ss_addr;
  wire [63:0] ss_wdata, ss_rdata, core_ss_rdata;
  wire ss_wren;
  wire machine_ce;
  wire cpu_frozen;
  wire video, hbl, vbl;

  wire ss_busy;
  wire ss_done;
  wire ss_error;
  wire ss_locked_cpu;
  wire ram_ss_bank, ram_ss_rd, ram_ss_wr;
  wire [15:0] ram_ss_addr;
  wire [7:0] ram_ss_wdata, ram_ss_rdata;
  wire slot_rd, slot_wr;
  wire [14:0] slot_addr;
  wire [63:0] slot_wdata, slot_rdata;
  wire slot_ready;
  wire current_cpu = ~status[5];
  wire active_cpu = ss_busy ? ss_locked_cpu : current_cpu;
  wire ss_reset = reset_cold || reset_warm || soft_reset;

  assign ss_rdata = (ss_addr == 10'd8) ?
                    {39'd0, reset_sync, power_on_reset, flash_counter} :
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

  apple2 d1 (
    .CLK_14M(clk_sys), .CLK_2M(), .PALMODE(1'b0), .ROMSWITCH(1'b0), .CPU_WAIT(1'b0),
    .PHASE_ZERO(), .PHASE_ZERO_R(), .PHASE_ZERO_F(), .FLASH_CLK(flash_div[22]),
    .reset(reset_sync), .cpu(active_cpu), .STALL(osd_pause || ss_busy), .ADDR(),
    .ram_addr(ram_addr), .D(ram_di), .ram_do(ram_do), .aux(ram_aux), .PD(8'd0),
    .CPU_WE(), .IRQ_n(1'b1), .NMI_n(1'b1), .ram_we(ram_we), .VIDEO(video),
    .COLOR_LINE(), .TEXT_MODE(), .HBL(hbl), .VBL(vbl), .K(K), .READ_KEY(read_key),
    .AKD(akd), .AN(), .GAMEPORT(8'd0), .PDL_STROBE(), .STB(), .IO_SELECT(),
    .DEVICE_SELECT(), .IO_STROBE(), .ioctl_addr(25'd0), .ioctl_data(8'd0),
    .ioctl_index(8'd0), .ioctl_download(1'b0), .ioctl_wr(1'b0), .saturn_5_inslot(1'b0),
    .speaker(), .DBG_T65_REGS(), .DBG_DI(), .DBG_ROM_ADDR(), .DBG_ROM_OUT(),
    .ss_addr(ss_addr), .ss_wdata(ss_wdata), .ss_wren(ss_wren), .ss_rdata(core_ss_rdata),
    .machine_ce(machine_ce), .cpu_frozen(cpu_frozen)
  );
  wire [7:0] main_ram_q_a, main_ram_q_b;
  wire [7:0] aux_ram_q_a, aux_ram_q_b;

  dpram #(.addr_width_g(16), .data_width_g(8)) main_ram (
    .address_a(ram_addr_eff[15:0]), .address_b(ram_ss_addr),
    .clock_a(clk_sys), .clock_b(clk_sys),
    .data_a(ram_di_eff), .data_b(ram_ss_wdata),
    .enable_a(1'b1), .enable_b(1'b1),
    .wren_a(ram_we_eff && !ram_aux), .wren_b(ram_ss_wr && !ram_ss_bank && !ss_reset),
    .q_a(main_ram_q_a), .q_b(main_ram_q_b)
  );

  dpram #(.addr_width_g(16), .data_width_g(8)) aux_ram (
    .address_a(ram_addr_eff[15:0]), .address_b(ram_ss_addr),
    .clock_a(clk_sys), .clock_b(clk_sys),
    .data_a(ram_di_eff), .data_b(ram_ss_wdata),
    .enable_a(1'b1), .enable_b(1'b1),
    .wren_a(ram_we_eff && ram_aux), .wren_b(ram_ss_wr && ram_ss_bank && !ss_reset),
    .q_a(aux_ram_q_a), .q_b(aux_ram_q_b)
  );

  assign ram_do = {aux_ram_q_a, main_ram_q_a};
  assign ram_ss_rdata = ram_ss_bank ? aux_ram_q_b : main_ram_q_b;

  pll pll (.refclk(CLK_50M), .rst(1'b0), .outclk_0(CLK_VIDEO), .outclk_1(clk_sys));
  assign CE_PIXEL = 1'b1;
  assign VIDEO_ARX = 13'd4;
  assign VIDEO_ARY = 13'd3;
  assign HDMI_FREEZE = ss_busy;
  assign VGA_R = {8{video}}; assign VGA_G = {8{video}}; assign VGA_B = {8{video}};
  assign VGA_DE = ~(hbl | vbl); assign VGA_HS = hbl; assign VGA_VS = vbl;

  assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
  assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH,
          SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
  assign USER_OUT = '1;
  assign LED_USER = 1'b1; assign LED_POWER = 2'b00; assign LED_DISK = 2'b00; assign BUTTONS = 2'b00;
  assign VGA_F1 = 1'b0; assign VGA_SL = 2'b00; assign VGA_SCALER = 1'b0; assign VGA_DISABLE = 1'b0;
  assign ADC_BUS = 4'bz; assign UART_RTS = 1'b0; assign UART_TXD = 1'b0; assign UART_DTR = 1'b0;
  assign AUDIO_L = 16'd0; assign AUDIO_R = 16'd0; assign AUDIO_S = 1'b0; assign AUDIO_MIX = 2'b00;
endmodule
