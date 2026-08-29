// ym2149_stub.v - deterministic PSG stub for the mockingboard harness.
//
// Bit-identical behavior twin of ym2149_stub.vhd (same register file, same
// protocol, same reset semantics, same combinational channel outputs). The
// module name is YM2149 so it binds directly to the board's instantiation;
// the real rtl/mockingboard/YM2149.sv is NOT in this harness's source list.
//
// Stub semantics (NOT an AY-3-8910 model - determinism and parity only):
//   - 32x8 register file, value 0 after reset/power-up.
//   - On posedge CLK:
//       RESET=1                 -> clear all registers and DO to 0
//       CE=1, BC=1, BDIR=1      -> mem[DI[5:0]] <= DI        (write)
//       CE=1, BC=1, BDIR=0      -> do_reg <= mem[DI[5:0]]    (read)
//   - DO is a registered readout (one-cycle read latency).
//   - CHANNEL_A/B/C are pure combinational functions of mem[0]/mem[1]/mem[2];
//     they carry no free-running state, so O_AUDIO changes only on writes.
//   - SEL/MODE/IOA_in/IOB_in are ignored; ACTIVE is unused by the board.

`timescale 1ns / 1ps

module YM2149 (
    input         CLK,
    input         CE,
    input         RESET,
    input         BDIR,   // Bus Direction (0 - read , 1 - write)
    input         BC,     // Bus control
    input  [7:0]  DI,
    output [7:0]  DO,
    output [7:0]  CHANNEL_A,
    output [7:0]  CHANNEL_B,
    output [7:0]  CHANNEL_C,

    input         SEL,
    input         MODE,

    output [5:0]  ACTIVE,

    input  [7:0]  IOA_in,
    output [7:0]  IOA_out,

    input  [7:0]  IOB_in,
    output [7:0]  IOB_out
);

    reg [7:0] mem [0:31];
    reg [7:0] do_reg;

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) mem[i] = 8'h00;
        do_reg = 8'h00;
    end

    always @(posedge CLK) begin
        if (RESET) begin
            for (i = 0; i < 32; i = i + 1) mem[i] <= 8'h00;
            do_reg <= 8'h00;
        end else if (CE && BC) begin
            if (BDIR) begin
                mem[DI[5:0]] <= DI;
            end else begin
                do_reg <= mem[DI[5:0]];
            end
        end
    end

    assign DO        = do_reg;
    assign CHANNEL_A = mem[0];
    assign CHANNEL_B = mem[1];
    assign CHANNEL_C = mem[2];

    assign ACTIVE  = 6'h00;
    assign IOA_out = 8'h00;
    assign IOB_out = 8'h00;

endmodule
