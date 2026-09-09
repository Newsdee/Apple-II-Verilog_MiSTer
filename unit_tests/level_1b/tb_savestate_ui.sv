`timescale 1ns / 1ps

// Focused test for rtl/savestate_ui.sv (MiSTer save-state OSD/UI controller).
//
// Covers:
//   - status_menumask bits (7 = availability, 8 = always 0)
//   - OSD slot tracking and "Active slot N" feedback
//   - slot held while a transaction is busy
//   - OSD command lines (one-cycle requests, rising edge only)
//   - hotkey requests
//   - completion feedback from done/error with the latched op and slot
//   - error codes 1/2/3 mapped to info strings 13/14/15
//   - commands ignored while busy
//   - info_req low between messages

module tb_savestate_ui;
  reg clk = 1'b0;
  always #1 clk = ~clk;

  reg reset = 1'b1;
  reg allow_ss = 1'b1;
  reg ss_busy = 1'b0;
  reg ss_done = 1'b0;
  reg ss_error = 1'b0;
  reg [1:0] ss_error_code = 2'd0;
  reg [1:0] osd_slot = 2'd0;
  reg osd_save = 1'b0;
  reg osd_restore = 1'b0;
  reg hk_save = 1'b0;
  reg hk_load = 1'b0;

  wire ss_save_req, ss_load_req, info_req;
  wire [1:0] ss_slot;
  wire [7:0] info;
  wire [15:0] status_menumask;

  integer errors = 0;

  savestate_ui dut (
    .clk(clk), .reset(reset),
    .allow_ss(allow_ss), .ss_busy(ss_busy), .ss_done(ss_done),
    .ss_error(ss_error), .ss_error_code(ss_error_code),
    .osd_slot(osd_slot), .osd_save(osd_save), .osd_restore(osd_restore),
    .hk_save(hk_save), .hk_load(hk_load),
    .ss_save_req(ss_save_req), .ss_load_req(ss_load_req),
    .ss_slot(ss_slot), .info_req(info_req), .info(info),
    .status_menumask(status_menumask)
  );

  task check(input [1:0] cond, input [255:0] name);
    begin
      if (!cond) begin
        $display("ERROR: %0s", name);
        errors = errors + 1;
      end
    end
  endtask

  // Pulse ss_done (optionally with error/code) and capture the info message
  // that appears on the following cycle.
  reg [7:0] captured_info = 8'd0;
  reg captured_req = 1'b0;
  task complete(input [1:0] code, input err);
    begin
      @(negedge clk);
      ss_done = 1'b1; ss_error = err; ss_error_code = code;
      @(negedge clk);
      ss_done = 1'b0; ss_error = 1'b0; ss_error_code = 2'd0;
      // info_req/info are registered: valid one cycle after ss_done.
      captured_req = info_req;
      captured_info = info;
      @(negedge clk);
    end
  endtask

  initial begin
    repeat (3) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // --- menumask: available ---
    check(status_menumask == 16'h0080, "menumask available = 0x0080");

    // --- menumask: unavailable (e.g. Saturn) ---
    allow_ss = 1'b0;
    @(negedge clk);
    check(status_menumask == 16'h0000, "menumask unavailable = 0x0000");
    allow_ss = 1'b1;
    @(negedge clk);
    check(status_menumask == 16'h0080, "menumask back to 0x0080");

    // --- slot tracking + "Active slot N" feedback (slot index 2 = "slot 3") ---
    osd_slot = 2'd2;
    @(negedge clk);
    check(ss_slot == 2'd2, "ss_slot tracks osd_slot");
    check(info_req && info == 8'd3, "active slot 3 feedback (info=3)");
    @(negedge clk);
    check(!info_req, "info_req low between messages");

    // --- slot held while busy ---
    ss_busy = 1'b1;
    osd_slot = 2'd3;
    @(negedge clk);
    check(ss_slot == 2'd2, "ss_slot held while busy");
    check(!info_req, "no slot feedback while busy");

    // --- OSD save command while busy must be ignored ---
    osd_save = 1'b1;
    @(negedge clk);
    check(!ss_save_req, "OSD save ignored while busy");
    osd_save = 1'b0;
    ss_busy = 1'b0;
    osd_slot = 2'd2;   // restore the original slot; UI re-tracks once idle
    @(negedge clk);
    check(ss_slot == 2'd2, "ss_slot back to 2 after busy release");
    @(negedge clk);
    check(!info_req, "slot feedback settled");

    // --- OSD save command, success completion ---
    // set at negedge, DUT samples at the next posedge, check at the negedge
    // after that (request is high for exactly one cycle).
    @(negedge clk); osd_save = 1'b1;
    @(negedge clk);
    check(ss_save_req, "osd save request issued");
    check(!ss_load_req, "no load request on save");
    osd_save = 1'b0;
    @(negedge clk);
    check(!ss_save_req, "save request is one cycle");
    complete(2'd0, 1'b0);
    check(captured_req, "save completion info_req");
    // slot index 2, save: 5 + 2*2 + 0 = 9 ("State 3 saved")
    check(captured_info == 8'd9, "save success info=9 (State 3 saved)");

    // --- OSD restore command, invalid/empty error (code 2) ---
    @(negedge clk); osd_restore = 1'b1;
    @(negedge clk);
    check(ss_load_req, "osd restore request issued");
    osd_restore = 1'b0;
    @(negedge clk);
    complete(2'd2, 1'b1);
    check(captured_req && captured_info == 8'd14, "invalid/empty info=14");

    // --- hotkey load, incompatible error (code 3) ---
    @(negedge clk); hk_load = 1'b1;
    @(negedge clk);
    check(ss_load_req, "hotkey load request issued");
    check(!ss_save_req, "no save request on load");
    hk_load = 1'b0;
    @(negedge clk);
    complete(2'd3, 1'b1);
    check(captured_req && captured_info == 8'd15, "incompatible info=15");

    // --- hotkey save, Saturn rejection (code 1) ---
    @(negedge clk); hk_save = 1'b1;
    @(negedge clk);
    check(ss_save_req, "hotkey save request issued");
    hk_save = 1'b0;
    @(negedge clk);
    complete(2'd1, 1'b1);
    check(captured_req && captured_info == 8'd13, "saturn rejection info=13");

    // --- load success names the latched slot (slot index 1 = "State 2") ---
    osd_slot = 2'd1;
    @(negedge clk);
    check(info_req && info == 8'd2, "active slot 2 feedback (info=2)");
    @(negedge clk);
    @(negedge clk); hk_load = 1'b1;
    @(negedge clk);
    check(ss_load_req, "hotkey load request issued (slot 2)");
    hk_load = 1'b0;
    @(negedge clk);
    complete(2'd0, 1'b0);
    // slot index 1, load: 5 + 2*1 + 1 = 8 ("State 2 loaded")
    check(captured_req && captured_info == 8'd8, "load success info=8 (State 2 loaded)");

    if (errors == 0)
      $display("L1B UI PASS");
    else
      $display("L1B UI FAIL errors=%0d", errors);
    $finish;
  end
endmodule
