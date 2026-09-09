`timescale 1ns / 1ps

module tb_savestate_hotkeys;
  reg clk;
  initial clk = 1'b0;
  always #1 clk = ~clk;

  reg reset = 1'b1;
  reg [10:0] filtered_ps2_key = 11'd0;
  wire [10:0] core_ps2_key;
  wire save_request;
  wire load_request;
  integer errors = 0;

  savestate_hotkeys dut (
    .clk(clk), .reset(reset), .filtered_ps2_key(filtered_ps2_key),
    .core_ps2_key(core_ps2_key), .save_request(save_request),
    .load_request(load_request)
  );

  task send_event(input pressed, input extended_key, input [7:0] scan_code);
    begin
      filtered_ps2_key = {~filtered_ps2_key[10], pressed, extended_key, scan_code};
      @(posedge clk);
      #1;
    end
  endtask

  task check_condition(input condition, input string message);
    begin
      if (!condition) begin
        $display("FAIL: %0s", message);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    repeat (2) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    send_event(1'b1, 1'b0, 8'h03);
    check_condition(load_request && !save_request, "F5 press must request one load");
    check_condition(core_ps2_key == 11'd0, "F5 press must be consumed");
    @(posedge clk); #1;
    check_condition(!load_request && !save_request, "F5 request must last one cycle");
    send_event(1'b0, 1'b0, 8'h03);
    check_condition(!load_request && !save_request, "F5 release must not request load");
    check_condition(core_ps2_key == 11'd0, "F5 release must be consumed");

    send_event(1'b1, 1'b0, 8'h0B);
    check_condition(save_request && !load_request, "F6 press must request one save");
    check_condition(core_ps2_key == 11'd0, "F6 press must be consumed");
    @(posedge clk); #1;
    check_condition(!load_request && !save_request, "F6 request must last one cycle");
    send_event(1'b0, 1'b0, 8'h0B);
    check_condition(!load_request && !save_request, "F6 release must not request save");
    check_condition(core_ps2_key == 11'd0, "F6 release must be consumed");

    send_event(1'b1, 1'b0, 8'h1C);
    check_condition(core_ps2_key[9:0] == {1'b1, 1'b0, 8'h1C},
            "ordinary key press must be forwarded");
    send_event(1'b0, 1'b0, 8'h1C);
    check_condition(core_ps2_key[9:0] == {1'b0, 1'b0, 8'h1C},
            "ordinary key release must be forwarded");

    send_event(1'b1, 1'b1, 8'h03);
    check_condition(!load_request && !save_request,
            "extended F5 code must not be consumed");
    check_condition(core_ps2_key[9:0] == {1'b1, 1'b1, 8'h03},
            "extended key must be forwarded");

    if (errors == 0)
      $display("SAVESTATE HOTKEYS PASS");
    else
      $fatal(1, "SAVESTATE HOTKEYS FAIL errors=%0d", errors);
    $finish;
  end
endmodule
