//-------------------------------------------------------------------------------
//
// HDD interface
//
// This is a ProDOS HDD interface based on the AppleWin interface.
// Currently, the CPU must be halted during command execution.
//
// Steven A. Wilson
//
//-------------------------------------------------------------------------------
// Registers (per AppleWin source/Harddisk.cpp)
// C0F0         (r)   EXECUTE AND RETURN STATUS
// C0F1         (r)   STATUS (or ERROR)
// C0F2         (r/w) COMMAND
// C0F3         (r/w) UNIT NUMBER
// C0F4         (r/w) LOW BYTE OF MEMORY BUFFER
// C0F5         (r/w) HIGH BYTE OF MEMORY BUFFER
// C0F6         (r/w) LOW BYTE OF BLOCK NUMBER
// C0F7         (r/w) HIGH BYTE OF BLOCK NUMBER
// C0F8         (r)   NEXT BYTE
//-------------------------------------------------------------------------------

module hdd(
    CLK_14M,
    IO_SELECT,      // e.g., C600 - C6FF ROM
    DEVICE_SELECT,  // e.g., C0E0 - C0EF I/O locations
    RESET,
    A,
    RD,             // 6502 RD/WR
    D_IN,           // From 6502
    D_OUT,          // To 6502
    sector,         // Sector number to read/write
    hdd_read,
    hdd_write,
    hdd_mounted,
    hdd_protect,
    ram_addr,       // Address for sector buffer
    ram_di,         // Data to sector buffer
    ram_do,         // Data from sector buffer
    ram_we          // Sector buffer write enable
);
    input             CLK_14M;
    input             IO_SELECT;
    input             DEVICE_SELECT;
    input             RESET;
    input      [15:0] A;
    input             RD;
    input      [7:0]  D_IN;
    output reg [7:0]  D_OUT;
    output reg [15:0] sector;
    output reg        hdd_read;
    output reg        hdd_write;
    input             hdd_mounted;
    input             hdd_protect;
    input      [8:0]  ram_addr;
    input      [7:0]  ram_di;
    output reg [7:0]  ram_do;
    input             ram_we;

    wire [7:0] rom_dout;

    // Interface registers
    reg [7:0] reg_status;
    reg [7:0] reg_command;
    reg [7:0] reg_unit;
    reg [7:0] reg_mem_l;
    reg [7:0] reg_mem_h;
    reg [7:0] reg_block_l;
    reg [7:0] reg_block_h;

    // Internal sector buffer offset counter; incremented by
    // access to C0F8 and reset when a command is written to
    // C0F2.
    reg [8:0] sec_addr;
    reg increment_sec_addr;
    reg select_d;

    // Sector buffer
    // Double-ported RAM for holding a sector
    reg [7:0] sector_buf [0:511];

    // ProDOS constants
    localparam [7:0] PRODOS_COMMAND_STATUS   = 8'h00;
    localparam [7:0] PRODOS_COMMAND_READ     = 8'h01;
    localparam [7:0] PRODOS_COMMAND_WRITE    = 8'h02;
    localparam [7:0] PRODOS_COMMAND_FORMAT   = 8'h03;
    localparam [7:0] PRODOS_STATUS_NO_DEVICE = 8'h28;
    localparam [7:0] PRODOS_STATUS_PROTECT   = 8'h2B;

    assign sector = {reg_block_h, reg_block_l};

    always @(posedge CLK_14M) begin
        D_OUT     <= 8'hFF;
        hdd_read  <= 1'b0;
        hdd_write <= 1'b0;
        if (RESET == 1'b1) begin
            reg_status  <= 8'h00;
            reg_command <= 8'h00;
            reg_unit    <= 8'h00;
            reg_mem_l   <= 8'h00;
            reg_mem_h   <= 8'h00;
            reg_block_l <= 8'h00;
            reg_block_h <= 8'h00;
        end else begin
            select_d <= DEVICE_SELECT;
            if (DEVICE_SELECT == 1'b1) begin
                if (RD == 1'b1) begin
                    case (A[3:0])
                        4'h0: begin
                            sec_addr <= 9'h000;
                            case (reg_command)
                                PRODOS_COMMAND_STATUS: begin
                                    if (hdd_mounted == 1'b1 && reg_unit == 8'h70) begin
                                        reg_status <= 8'h00;
                                        D_OUT      <= 8'h00;
                                    end else begin
                                        reg_status <= 8'h01;
                                        D_OUT      <= PRODOS_STATUS_NO_DEVICE;
                                    end
                                end
                                PRODOS_COMMAND_READ: begin
                                    if (hdd_mounted == 1'b1 && reg_unit == 8'h70) begin
                                        hdd_read   <= 1'b1;
                                        reg_status <= 8'h00;
                                        D_OUT      <= 8'h00;
                                    end else begin
                                        reg_status <= 8'h01;
                                        D_OUT      <= PRODOS_STATUS_NO_DEVICE;
                                    end
                                end
                                PRODOS_COMMAND_WRITE: begin
                                    if (hdd_mounted == 1'b0 || reg_unit != 8'h70) begin
                                        D_OUT      <= PRODOS_STATUS_NO_DEVICE;
                                        reg_status <= 8'h01;
                                    end else if (hdd_protect == 1'b1) begin
                                        D_OUT      <= PRODOS_STATUS_PROTECT;
                                    end else begin
                                        D_OUT      <= 8'h00;
                                        reg_status <= 8'h00;
                                        hdd_write  <= 1'b1;
                                    end
                                end
                                default: ;
                            endcase
                        end
                        4'h1: D_OUT <= reg_status;
                        4'h2: D_OUT <= reg_command;
                        4'h3: D_OUT <= reg_unit;
                        4'h4: D_OUT <= reg_mem_l;
                        4'h5: D_OUT <= reg_mem_h;
                        4'h6: D_OUT <= reg_block_l;
                        4'h7: D_OUT <= reg_block_h;
                        4'h8: begin
                            D_OUT              <= sector_buf[sec_addr];
                            increment_sec_addr <= 1'b1;
                        end
                        default: ;
                    endcase
                end else begin // RD = 0; 6502 is writing
                    case (A[3:0])
                        4'h2: begin
                            if (D_IN == 8'h02) begin
                                sec_addr <= 9'h000;
                            end
                            reg_command <= D_IN;
                        end
                        4'h3: reg_unit    <= D_IN;
                        4'h4: reg_mem_l   <= D_IN;
                        4'h5: reg_mem_h   <= D_IN;
                        4'h6: reg_block_l <= D_IN;
                        4'h7: reg_block_h <= D_IN;
                        4'h8: begin
                            sector_buf[sec_addr]  <= D_IN;
                            increment_sec_addr    <= 1'b1;
                        end
                        default: ;
                    endcase
                end // RD/WR
            end else if (DEVICE_SELECT == 1'b0 && select_d == 1'b1) begin
                if (increment_sec_addr == 1'b1) begin
                    sec_addr           <= sec_addr + 1'b1;
                    increment_sec_addr <= 1'b0;
                end
            end else if (IO_SELECT == 1'b1) begin // Firmware ROM read
                if (RD == 1'b1) begin
                    D_OUT <= rom_dout;
                end
            end // DEVICE_SELECT/IO_SELECT
        end // RESET
    end

    // Dual-ported RAM holding the contents of the sector
    always @(posedge CLK_14M) begin
        if (ram_we == 1'b1) begin
            sector_buf[ram_addr] <= ram_di;
        end
        ram_do <= sector_buf[ram_addr];
    end

    // Firmware ROM (hdd_rom.vhd equivalent)
    rom #(8,8,"rtl/roms/hdd.hex") hddrom (
        .clock(CLK_14M),
        .ce(1'b1),
        .a(A[7:0]),
        .data_out(rom_dout)
    );
endmodule
