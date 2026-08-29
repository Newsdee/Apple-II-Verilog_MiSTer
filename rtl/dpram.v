// Behavioral dual-port RAM matching the Quartus altsyncram configuration in
// dpram.vhd (newsdee project):
//   - Port A: unregistered address, unregistered output,
//             read_during_write = NEW_DATA
//   - Port B: address, data and wrcontrol registered on clock_b
//             (address_reg_b / indata_reg_b / wrcontrol_wraddress_reg_b =
//             "CLOCK1"), unregistered output, read_during_write = NEW_DATA.
//             The write committed at a clock_b edge uses the address/data
//             PRESENT at that edge (capture and write happen on the same
//             edge); the read output reflects the address latched at the
//             previous edge.
//   - clocken0/clocken1 => enable_a/enable_b gate the port logic only
//     (clock_enable_output = BYPASS, so outputs are not gated)
//   - enable_a/enable_b default to 1, matching the VHDL port defaults
//     (floppy_track.sv leaves them unconnected)
//
// Simulation model for Verilator; on Cyclone V the original instantiates
// altsyncram directly.
module dpram #(
    parameter addr_width_g = 8,
    parameter data_width_g = 8
) (
    input  wire [addr_width_g-1:0]  address_a,
    input  wire [addr_width_g-1:0]  address_b,
    input  wire                     clock_a,
    input  wire                     clock_b,
    input  wire [data_width_g-1:0]  data_a,
    input  wire [data_width_g-1:0]  data_b,
    input  wire                     enable_a = 1'b1,
    input  wire                     enable_b = 1'b1,
    input  wire                     wren_a,
    input  wire                     wren_b,
    output wire [data_width_g-1:0]  q_a,
    output wire [data_width_g-1:0]  q_b
);
    reg [data_width_g-1:0] mem [0:(1<<addr_width_g)-1];

    // Port B: address, data and wrcontrol are registered on clock_b.
    reg [addr_width_g-1:0] address_b_r;
    reg [data_width_g-1:0] data_b_r;
    reg                    wren_b_r;
    always @(posedge clock_b) begin
        if (enable_b) begin
            address_b_r <= address_b;
            data_b_r    <= data_b;
            wren_b_r    <= wren_b;
        end
    end

    // Port A: unregistered write.
    always @(posedge clock_a) begin
        if (enable_a && wren_a)
            mem[address_a] <= data_a;
    end

    // Port B: the write committed at this edge uses the address/data present
    // at the edge (altsyncram CLOCK1 registers capture and commit together).
    always @(posedge clock_b) begin
        if (enable_b && wren_b)
            mem[address_b] <= data_b;
    end

    // Unregistered outputs. NEW_DATA: a read colliding with a write on the
    // same port returns the data being written. Port A is unregistered, so
    // the collision is the present cycle; port B's collision is the write
    // committed at the previous edge (registered wrcontrol/data).
    assign q_a = (enable_a && wren_a) ? data_a   : mem[address_a];
    assign q_b = wren_b_r              ? data_b_r : mem[address_b_r];

endmodule
