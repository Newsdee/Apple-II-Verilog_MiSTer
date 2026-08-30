`timescale 1ns / 1ps
// nsc_tb.sv — unit + integration test for rtl/no_slot_clock.sv and
// rtl/nsc_ticker.sv (NSC port, Verilog repo). Build with the verilator
// binary in C:/msys64/ucrt64/bin (--timing --binary, top nsc_tb).

module nsc_tb;

localparam real CLK_PERIOD = 70.0; // ~14.318 MHz
logic clk = 0, rst = 1, strobe = 0, rw = 0;
logic [15:0] addr = 16'h0000;
logic [63:0] time_bcd = '0;
logic        time_en  = 0;
logic [7:0]  wr_data  = '0;
logic        wr_data_en = 0;

localparam logic [63:0] KNOWN_TIME = 64'h2503300117510000; // 25-03-30, dow1, 17:51:00.00

// Part B/C switch: static known time (Part B), then live ticker feed
// (Part C). Regs driven by ONE always block — no procedural/continuous
// driver conflict (a wire driven both ways never pulsed in Verilator).
reg c_live = 1'b0;   // Part C: feed live ticker output into the DUT
reg b_load = 1'b0;   // Part B: one-shot static time load
reg [83:0] nsc_input_time;
reg        nsc_time_en;
always @(*) begin
    if (c_live) begin
        nsc_input_time = {20'h0, time_bcd};
        nsc_time_en    = time_en;
    end else begin
        nsc_input_time = {20'h0, KNOWN_TIME};
        nsc_time_en    = b_load;
    end
end

localparam logic [64:0] RTC_235958 = {
    1'b1,      // [64] set-strobe
    13'h000,   // [63:51]
    3'd1,      // [50:48] dow (Monday)
    4'd2,      // [47:44] year tens
    4'd5,      // [43:40] year ones
    3'h0,      // [39:37]
    1'b0,      // [36] month tens
    4'd1,      // [35:32] month ones
    2'h0,      // [31:30]
    2'd3,      // [29:28] day tens
    4'd1,      // [27:24] day ones
    2'h0,      // [23:22]
    2'd2,      // [21:20] hour tens
    4'd3,      // [19:16] hour ones
    1'b0,      // [15]
    3'd5,      // [14:12] min tens
    4'd9,      // [11:8] min ones
    1'b0,      // [7]
    3'd5,      // [6:4] sec tens
    4'd8       // [3:0] sec ones
};

no_slot_clock dut(
    .clk(clk),
    .rst(rst),
    .strobe(strobe),
    .addr(addr),
    .rw(rw),
    .slot_sel(1'b1),
    .input_time(nsc_input_time),
    .input_time_en(nsc_time_en),
    .wr_data(wr_data),
    .wr_data_en(wr_data_en)
);

nsc_ticker tkr(
    .clk(clk),
    .rst(rst),
    .rtc(RTC_235958),
    .time_bcd(time_bcd),
    .time_en(time_en)
);

initial begin
    forever #(CLK_PERIOD/2.0) clk = ~clk;
end

integer errors = 0;

task automatic chk(input string name, input logic cond);
    if (cond) begin
        $display("PASS: %s", name);
    end else begin
        $display("FAIL: %s", name);
        errors++;
    end
endtask

// One CPU access: strobe pulses for one clk; outputs sampled after.
logic [7:0]  out_data;
logic        out_valid;
task automatic do_cycle(input logic [15:0] a, input logic r);
    @(negedge clk) #1;
    addr = a; rw = r; strobe = 1'b0;
    @(negedge clk) #1;
    strobe = 1'b1;
    @(negedge clk) #1;   // DUT registered the access at the posedge in between
    strobe = 1'b0;
    out_data  = wr_data;
    out_valid = wr_data_en;
endtask

// Stock-driver unlock: bytes C5,3A,A3,5C x2, LSB-first per byte, A0 = bit.
function automatic logic [7:0] unlk_byte(input integer i);
    case (i)
        0:   return 8'hC5;
        1:   return 8'h3A;
        2:   return 8'hA3;
        3:   return 8'h5C;
        default: return 8'h00;
    endcase
endfunction
task automatic unlock_seq(input logic [15:0] base);
    integer b, i;
    for (b = 0; b < 8; b++) begin
        for (i = 0; i < 8; i++) begin
            do_cycle(base + ((unlk_byte(b % 4) >> i) & 8'h1), 1'b0);
        end
    end
endtask

// Read 64 bits at base+4; returns assembled value (first bit = LSB).
logic [63:0] rd_val;
integer      rd_valid_count;
task automatic readout_seq(input logic [15:0] base);
    integer i;
    rd_val = '0;
    rd_valid_count = 0;
    for (i = 0; i < 64; i++) begin
        do_cycle(base + 8'd4, 1'b1);
        if (out_valid) begin
            rd_val[i] = out_data[0];
            rd_valid_count++;
        end
    end
endtask

initial begin
    // ------------------------------------------------------------------
    $display("== Part A: nsc_ticker rollover (23:59:58 -> +3 s) ==");
    // rst high; rtc already holds flag=1. Deassert reset; ticker reloads
    // at the first posedge, then ticks once per 14318182 cycles.
    repeat (4) @(negedge clk) #1;
    rst = 1'b0;
    // 3 full seconds + 500k cycles margin (well inside the 4th second)
    repeat (3*14318182 + 500000) @(negedge clk);
    chk("A: ticker 23:59:58 + 3s = 00:00:01 next day, dow+1",
        time_bcd == 64'h2502010200000100);
    $display("  ticker time_bcd = %h (expect 2502010200000100)", time_bcd);

    // ------------------------------------------------------------------
    $display("== Part B: NSC protocol (static time, no reloads) ==");
    c_live = 1'b0;
    b_load = 1'b1;                  // one-shot static load (KNOWN_TIME)
    @(negedge clk) #1;
    b_load = 1'b0;

    // B1: read before unlock -> nothing emitted, but re-arms writes
    do_cycle(16'hC304, 1'b1);
    chk("B1: no data before unlock", out_valid == 1'b0);

    // B2: mismatch on first bit (expected C5[0]=1, write 0) -> disabled
    do_cycle(16'hC300, 1'b0);
    begin : b2rest
        integer x, y;
        for (x = 0; x < 8; x++) begin
            for (y = (x==0) ? 1 : 0; y < 8; y++) begin
                do_cycle(16'hC300 + ((unlk_byte(x % 4) >> y) & 8'h1), 1'b0);
            end
        end
    end
    readout_seq(16'hC300);
    chk("B2: mismatched unlock does not enable readout", rd_valid_count == 0);

    // B3: stray READS at A2=0 during a fresh unlock must not record bits
    //     (ported module requires !rw on the write path)
    do_cycle(16'hC304, 1'b1);            // re-arm
    begin : b3
        integer x, y;
        for (x = 0; x < 8; x++) begin
            do_cycle(16'hC300, 1'b1);    // stray read at A2=0 (must ignore)
            for (y = 0; y < 8; y++) begin
                do_cycle(16'hC300 + ((unlk_byte(x % 4) >> y) & 8'h1), 1'b0);
            end
        end
    end
    readout_seq(16'hC300);
    chk("B3: unlock with stray reads works, value matches",
        rd_valid_count == 64 && rd_val == KNOWN_TIME);
    $display("  B3 readout = %h (expect %h)", rd_val, KNOWN_TIME);

    // B4: after a full readout the register is disabled; further reads
    //     emit nothing (and re-arm writes)
    do_cycle(16'hC304, 1'b1);
    chk("B4: no data after readout exhaustion", out_valid == 1'b0);

    // B5: re-unlock works
    unlock_seq(16'hC300);
    readout_seq(16'hC300);
    chk("B5: re-unlock + readout matches", rd_valid_count == 64 && rd_val == KNOWN_TIME);

    // B6a: access at offset 8 (A3=1, outside $00-$07) must be ignored
    do_cycle(16'hC304, 1'b1);            // re-arm
    unlock_seq(16'hC308);                // wrong offset: no effect
    readout_seq(16'hC300);
    chk("B6a: unlock at offset 8 does not arm readout", rd_valid_count == 0);

    // B6b: WRITE cycles at a read offset (A2=1, within $00-$07) must not
    //      record compare bits (they hit the re-arm path instead)
    do_cycle(16'hC304, 1'b1);            // re-arm
    begin : b6b
        integer x, y;
        for (x = 0; x < 8; x++) begin
            for (y = 0; y < 8; y++) begin
                do_cycle(16'hC304 + ((unlk_byte(x % 4) >> y) & 8'h1), 1'b0);
            end
        end
    end
    readout_seq(16'hC300);
    chk("B6b: writes at A2=1 offsets do not arm readout", rd_valid_count == 0);

    // ------------------------------------------------------------------
    $display("== Part C: integration — ticker feeds NSC, free-run 1.5 s ==");
    c_live = 1'b1;
    repeat (21477273) @(negedge clk);   // ~1.5 s at 14.318 MHz
    // sample the ticker just before arming; a second-tick may land during
    // the ~10 us unlock+readout burst, so allow +1 s on the h/m/s fields
    time_bcd_sample = time_bcd;
    do_cycle(16'hC304, 1'b1);            // re-arm
    unlock_seq(16'hC300);
    readout_seq(16'hC300);
    chk("C: readout valid (64 bits)", rd_valid_count == 64);
    chk("C: readout csec is valid BCD (<100)",
        rd_val[7:4] < 4'd10 && rd_val[3:0] < 4'd10);
    chk("C: readout h/m/s == ticker (or +1 s boundary)",
        hms_match(rd_val, time_bcd_sample));
    $display("  C readout = %h, ticker(before) = %h", rd_val, time_bcd_sample);

    if (errors == 0) $display("NSC UNIT PASS");
    else             $display("NSC UNIT FAIL (%0d errors)", errors);
    $finish;
end

logic [63:0] time_bcd_sample;

// h/m/s fields equal, or ticker advanced by exactly one second (BCD carry)
function automatic logic hms_match(input logic [63:0] rd, input logic [63:0] tk);
    logic [7:0] s0, m0, h0, s1, m1, h1;
    s0 = tk[15:8]; m0 = tk[23:16]; h0 = tk[31:24];
    if (s0 == 8'd59) begin s1 = 8'd0;  m1 = (m0 == 8'd59) ? 8'd0 : m0 + 8'd1; end
    else              begin s1 = s0+1; m1 = m0; end
    if (m1 == 8'd0 && m0 == 8'd59) begin
        h1 = (h0 == 8'd23) ? 8'd0 : h0 + 8'd1;
    end else begin
        h1 = h0;
    end
    return (rd[31:8] === tk[31:8]) ||
           (rd[15:8] === s1 && rd[23:16] === m1 && rd[31:24] === h1);
endfunction

// watchdog
initial begin
    #8_000_000_000;
    $display("FAIL: watchdog timeout");
    $finish;
end

endmodule
