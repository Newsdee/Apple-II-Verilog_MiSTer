module savestate_ddr_l1b #(
  parameter [28:0] BASE_ADDR = 29'd0
) (
  input  wire        clk,
  input  wire        reset,
  input  wire [14:0] slot_addr,
  input  wire        slot_rd,
  input  wire        slot_wr,
  input  wire [63:0] slot_wdata,
  output reg  [63:0] slot_rdata,
  output reg         slot_ready,

  output wire        ddram_clk,
  input  wire        ddram_busy,
  output wire [7:0]  ddram_burstcnt,
  output wire [28:0] ddram_addr,
  input  wire [63:0] ddram_dout,
  input  wire        ddram_dout_ready,
  output reg         ddram_rd,
  output reg  [63:0] ddram_din,
  output wire [7:0]  ddram_be,
  output reg         ddram_we
);
  localparam [1:0] IDLE = 2'd0;
  localparam [1:0] READ_WAIT = 2'd1;
  localparam [1:0] WRITE_WAIT = 2'd2;
  localparam [1:0] COOLDOWN = 2'd3;

  reg [1:0] state;
  reg [28:0] address_latched;

  // The MiSTer DDRAM port is 64 bits wide. DDRAM_ADDR addresses complete
  // 64-bit beats and DDRAM_BURSTCNT counts those beats.
  assign ddram_clk = clk;
  assign ddram_burstcnt = 8'd1;
  assign ddram_addr = address_latched;
  assign ddram_be = 8'hFF;

  always @(posedge clk) begin
    slot_ready <= 1'b0;
    ddram_rd <= 1'b0;
    ddram_we <= 1'b0;

    if (reset) begin
      state <= IDLE;
      address_latched <= 29'd0;
      slot_rdata <= 64'd0;
      ddram_din <= 64'd0;
    end
    else begin
      case (state)
        IDLE: begin
          if (!ddram_busy && slot_rd) begin
            address_latched <= BASE_ADDR + {14'd0, slot_addr};
            ddram_rd <= 1'b1;
            state <= READ_WAIT;
          end
          else if (!ddram_busy && slot_wr) begin
            address_latched <= BASE_ADDR + {14'd0, slot_addr};
            ddram_din <= slot_wdata;
            ddram_we <= 1'b1;
            state <= WRITE_WAIT;
          end
        end
        READ_WAIT: begin
          if (ddram_dout_ready) begin
            slot_rdata <= ddram_dout;
            slot_ready <= 1'b1;
            state <= COOLDOWN;
          end
        end
        WRITE_WAIT: begin
          if (!ddram_busy) begin
            slot_ready <= 1'b1;
            state <= COOLDOWN;
          end
        end
        COOLDOWN: state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end
endmodule
