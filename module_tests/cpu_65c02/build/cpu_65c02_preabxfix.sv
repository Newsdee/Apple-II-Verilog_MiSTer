// Copyright (c) 2026 Jamie Blanks
//
// 65C02 CPU core for the Sitronix ST2204 (GameKing).
//
// Written new for this project (PLAN_gameking_core_20260731.md decision 1):
// full W65C02S instruction set including the Rockwell RMB/SMB/BBR/BBS bit
// ops, WAI, and STP, with per-opcode cycle counts following the W65C02S
// datasheet. Undefined opcodes execute as the W65C02S NOPs of documented
// length and cycle count.
//
// Bus model: one memory access per CPU cycle. `ce` marks the end of a bus
// cycle - `din` is sampled and the next cycle's address/write are launched
// on the same edge. `sync` is high through the opcode fetch cycle and
// `vector_pull` through the two vector read cycles ($FFFA-$FFFF; the SoC
// remaps them into the $7Fxx window and auto-clears IREQ).
//
// ST2xxx integration stays outside this core: it issues standard vectors
// and reports `rti_done` so the SoC can manage the IRR bank override.

module cpu_65c02
#(
	parameter [9:0] SS_BASE = 10'd0    // savestate word base address
)
(
	input  wire        clk,
	input  wire        ce,             // 6 MHz phase 2 enable
	input  wire        ce_n,           // mid-cycle (phase 1) enable
	input  wire        reset,          // active high, synchronous
	input  wire        stall,          // hold in place (LCDC/DMA/savestate)

	input  wire        irq_n,          // level-sensitive IRQ
	input  wire        nmi_n,          // edge-sensitive NMI
	input  wire        rdy,            // classic RDY (honored on all cycles)
	input  wire        stp_nop,        // 1: execute STP as a NOP. The
	                                   // GameKing's idle auto-power-off
	                                   // uses STP, which only reset can
	                                   // wake; cores without a power
	                                   // switch disable it by default.

	output reg  [15:0] addr,
	output reg  [7:0]  dout,
	input  wire [7:0]  din,
	output reg         we,             // write cycle
	output reg         sync,           // opcode fetch cycle
	output reg         vector_pull,    // fetching a vector byte
	output wire        int_seq,        // vector fetch is a hardware interrupt (not BRK)
	output wire        rti_done,       // high through RTI's final cycle
	output reg         in_wai,         // executed WAI, waiting for interrupt
	output reg         in_stp,         // executed STP, stopped until reset

	// Savestate register bus
	input  wire [9:0]  ss_addr,
	input  wire [63:0] ss_wdata,
	input  wire        ss_wren,
	output wire [63:0] ss_rdata
);

	// ------------------------------------------------------------------
	// Architectural state
	// ------------------------------------------------------------------
	reg [7:0]  reg_a, reg_x, reg_y, reg_s;
	reg [15:0] reg_pc;
	// P: N V 1 B D I Z C
	reg        fl_n, fl_v, fl_d, fl_i, fl_z, fl_c;
	wire [7:0] reg_p = {fl_n, fl_v, 1'b1, 1'b1, fl_d, fl_i, fl_z, fl_c};

	// Working state
	reg [7:0]  ir;          // instruction register
	reg [7:0]  dl;          // operand/data latch (zp addr, offsets, RMW value)
	reg [15:0] ea;          // effective address
	reg        nmi_pending;
	reg        nmi_last;
	reg        int_active;  // current BRK sequence is an IRQ/NMI (B clear)
	reg        int_is_nmi;

	// ------------------------------------------------------------------
	// Decode
	// ------------------------------------------------------------------
	// Addressing modes
	localparam [4:0] M_IMP = 5'd0,  M_ACC = 5'd1,  M_IMM = 5'd2,  M_ZP  = 5'd3;
	localparam [4:0] M_ZPX = 5'd4,  M_ZPY = 5'd5,  M_ABS = 5'd6,  M_ABX = 5'd7;
	localparam [4:0] M_ABY = 5'd8,  M_IZX = 5'd9,  M_IZY = 5'd10, M_IZP = 5'd11;
	localparam [4:0] M_IAB = 5'd12, M_IAX = 5'd13, M_REL = 5'd14, M_ZPR = 5'd15;
	localparam [4:0] M_STK = 5'd16;

	// Instruction classes
	localparam [4:0] C_ALU  = 5'd0;   // A = A op M (also loads via PASS)
	localparam [4:0] C_LOAD = 5'd1;   // dst = M, NZ
	localparam [4:0] C_STORE= 5'd2;   // M = src
	localparam [4:0] C_RMW  = 5'd3;   // M = op M
	localparam [4:0] C_CMP  = 5'd4;   // flags = src - M
	localparam [4:0] C_BIT  = 5'd5;   // NV from M, Z from A&M
	localparam [4:0] C_BITI = 5'd6;   // BIT #: Z only
	localparam [4:0] C_BRA  = 5'd7;   // conditional/unconditional branch
	localparam [4:0] C_JMP  = 5'd8;
	localparam [4:0] C_JSR  = 5'd9;
	localparam [4:0] C_RTS  = 5'd10;
	localparam [4:0] C_RTI  = 5'd11;
	localparam [4:0] C_BRK  = 5'd12;
	localparam [4:0] C_PUSH = 5'd13;
	localparam [4:0] C_PULL = 5'd14;
	localparam [4:0] C_TXFR = 5'd15;  // register transfer (NZ except TXS)
	localparam [4:0] C_FLAG = 5'd16;  // CLC/SEC/CLI/SEI/CLD/SED/CLV
	localparam [4:0] C_NOP  = 5'd17;  // NOPs incl. multi-byte/multi-cycle
	localparam [4:0] C_WAI  = 5'd18;
	localparam [4:0] C_STP  = 5'd19;
	localparam [4:0] C_RSMB = 5'd20;  // RMB/SMB zp
	localparam [4:0] C_BBRS = 5'd21;  // BBR/BBS zp,rel
	localparam [4:0] C_TRB  = 5'd22;  // TRB/TSB (RMW, Z from A&M)

	// ALU ops (must match cpu_alu)
	localparam [3:0] ALU_ADC = 4'd0,  ALU_SBC = 4'd1,  ALU_AND = 4'd2;
	localparam [3:0] ALU_ORA = 4'd3,  ALU_EOR = 4'd4,  ALU_ASL = 4'd5;
	localparam [3:0] ALU_LSR = 4'd6,  ALU_ROL = 4'd7,  ALU_ROR = 4'd8;
	localparam [3:0] ALU_INC = 4'd9,  ALU_DEC = 4'd10, ALU_CMP = 4'd11;
	localparam [3:0] ALU_BIT = 4'd12, ALU_TRB = 4'd13, ALU_TSB = 4'd14;
	localparam [3:0] ALU_PASS = 4'd15;

	// Register selects
	localparam [2:0] R_A = 3'd0, R_X = 3'd1, R_Y = 3'd2, R_S = 3'd3;
	localparam [2:0] R_P = 3'd4, R_Z = 3'd5, R_NONE = 3'd6;

	reg [4:0] dc_mode;
	reg [4:0] dc_class;
	reg [3:0] dc_alu;
	reg [2:0] dc_src;
	reg [2:0] dc_dst;
	reg       dc_wr_nz, dc_wr_c, dc_wr_v;

	// Column/row fields of the classic aaabbbcc opcode structure
	wire [2:0] d_aaa = ir[7:5];
	wire [2:0] d_bbb = ir[4:2];
	wire [1:0] d_cc  = ir[1:0];

	always @* begin
		dc_mode  = M_IMP;
		dc_class = C_NOP;
		dc_alu   = ALU_PASS;
		dc_src   = R_NONE;
		dc_dst   = R_NONE;
		dc_wr_nz = 1'b0;
		dc_wr_c  = 1'b0;
		dc_wr_v  = 1'b0;

		case (d_cc)
		// --------------------------------------------------------------
		2'b01: begin
			// ORA AND EOR ADC STA LDA CMP SBC
			case (d_bbb)
				3'b000: dc_mode = M_IZX;
				3'b001: dc_mode = M_ZP;
				3'b010: dc_mode = M_IMM;
				3'b011: dc_mode = M_ABS;
				3'b100: dc_mode = M_IZY;
				3'b101: dc_mode = M_ZPX;
				3'b110: dc_mode = M_ABY;
				3'b111: dc_mode = M_ABX;
			endcase
			case (d_aaa)
				3'b000: begin dc_class = C_ALU; dc_alu = ALU_ORA; dc_dst = R_A; dc_wr_nz = 1'b1; end
				3'b001: begin dc_class = C_ALU; dc_alu = ALU_AND; dc_dst = R_A; dc_wr_nz = 1'b1; end
				3'b010: begin dc_class = C_ALU; dc_alu = ALU_EOR; dc_dst = R_A; dc_wr_nz = 1'b1; end
				3'b011: begin dc_class = C_ALU; dc_alu = ALU_ADC; dc_dst = R_A; dc_wr_nz = 1'b1; dc_wr_c = 1'b1; dc_wr_v = 1'b1; end
				3'b100: begin
					if (d_bbb == 3'b010) begin dc_class = C_BITI; dc_alu = ALU_BIT; end   // $89 BIT #
					else begin dc_class = C_STORE; dc_src = R_A; end
				end
				3'b101: begin dc_class = C_ALU; dc_alu = ALU_PASS; dc_dst = R_A; dc_wr_nz = 1'b1; end
				3'b110: begin dc_class = C_CMP; dc_alu = ALU_CMP; dc_src = R_A; dc_wr_nz = 1'b1; dc_wr_c = 1'b1; end
				3'b111: begin dc_class = C_ALU; dc_alu = ALU_SBC; dc_dst = R_A; dc_wr_nz = 1'b1; dc_wr_c = 1'b1; dc_wr_v = 1'b1; end
			endcase
		end
		// --------------------------------------------------------------
		2'b10: begin
			// ASL ROL LSR ROR STX LDX DEC INC (+ 65C02 (zp) column)
			case (d_bbb)
				3'b000: dc_mode = M_IMM;                     // only $A2 LDX #
				3'b001: dc_mode = M_ZP;
				3'b010: dc_mode = M_ACC;
				3'b011: dc_mode = M_ABS;
				3'b100: dc_mode = M_IZP;                     // 65C02 (zp) for cc=01 ops
				3'b101: dc_mode = (d_aaa == 3'b100 || d_aaa == 3'b101) ? M_ZPY : M_ZPX;
				3'b110: dc_mode = M_IMP;                     // TXS/TSX/DEX-col specials handled below
				3'b111: dc_mode = (d_aaa == 3'b101) ? M_ABY : M_ABX;
			endcase
			if (d_bbb == 3'b100) begin
				// $x2 column: 65C02 (zp) versions of the cc=01 ops for rows
				// 1,3,5,7,9,B,D,F; rows 0,2,4,6,8,A,C,E are 2-byte 2-cycle NOPs.
				if (ir[4] == 1'b0) begin
					// never reached: bbb=100 means ir[4:2]=100 so ir[4]=1
					dc_class = C_NOP;
				end
				case (d_aaa)
					3'b000: begin dc_class = C_ALU; dc_alu = ALU_ORA; dc_dst = R_A; dc_wr_nz = 1'b1; end   // $12
					3'b001: begin dc_class = C_ALU; dc_alu = ALU_AND; dc_dst = R_A; dc_wr_nz = 1'b1; end   // $32
					3'b010: begin dc_class = C_ALU; dc_alu = ALU_EOR; dc_dst = R_A; dc_wr_nz = 1'b1; end   // $52
					3'b011: begin dc_class = C_ALU; dc_alu = ALU_ADC; dc_dst = R_A; dc_wr_nz = 1'b1; dc_wr_c = 1'b1; dc_wr_v = 1'b1; end // $72
					3'b100: begin dc_class = C_STORE; dc_src = R_A; end                                     // $92
					3'b101: begin dc_class = C_ALU; dc_alu = ALU_PASS; dc_dst = R_A; dc_wr_nz = 1'b1; end   // $B2
					3'b110: begin dc_class = C_CMP; dc_alu = ALU_CMP; dc_src = R_A; dc_wr_nz = 1'b1; dc_wr_c = 1'b1; end // $D2
					3'b111: begin dc_class = C_ALU; dc_alu = ALU_SBC; dc_dst = R_A; dc_wr_nz = 1'b1; dc_wr_c = 1'b1; dc_wr_v = 1'b1; end // $F2
				endcase
			end else begin
				case (d_aaa)
					3'b000, 3'b001, 3'b010, 3'b011: begin
						// ASL ROL LSR ROR
						dc_alu = (d_aaa == 3'b000) ? ALU_ASL :
						         (d_aaa == 3'b001) ? ALU_ROL :
						         (d_aaa == 3'b010) ? ALU_LSR : ALU_ROR;
						dc_wr_nz = 1'b1;
						dc_wr_c  = 1'b1;
						if (dc_mode == M_ACC) begin
							dc_class = C_ALU;   // operates on A via b-input
							dc_src   = R_A;
							dc_dst   = R_A;
						end else if (dc_mode == M_IMM || dc_mode == M_IMP) begin
							dc_class = C_NOP;   // $02/$22/$42/$62 handled in cc=00? (see below)
							dc_wr_nz = 1'b0;
							dc_wr_c  = 1'b0;
						end else begin
							dc_class = C_RMW;
						end
					end
					3'b100: begin
						// STX / TXA($8A on cc=10? no: $8A is cc=10,bbb=010) handled:
						if (dc_mode == M_ACC) begin dc_class = C_TXFR; dc_src = R_X; dc_dst = R_A; dc_wr_nz = 1'b1; end // $8A TXA
						else if (dc_mode == M_IMP) begin dc_class = C_TXFR; dc_src = R_X; dc_dst = R_S; end             // $9A TXS
						else if (dc_mode == M_IMM) begin dc_class = C_NOP; end                                          // $82 NOP #
						else begin dc_class = C_STORE; dc_src = R_X; end
					end
					3'b101: begin
						// LDX / TAX / TSX
						if (dc_mode == M_ACC) begin dc_class = C_TXFR; dc_src = R_A; dc_dst = R_X; dc_wr_nz = 1'b1; end // $AA TAX
						else if (dc_mode == M_IMP) begin dc_class = C_TXFR; dc_src = R_S; dc_dst = R_X; dc_wr_nz = 1'b1; end // $BA TSX
						else begin dc_class = C_LOAD; dc_dst = R_X; dc_wr_nz = 1'b1; end
					end
					3'b110: begin
						// DEC / DEX($CA) / $DA PHX
						if (dc_mode == M_ACC) begin dc_class = C_TXFR; dc_src = R_X; dc_dst = R_X; dc_alu = ALU_DEC; dc_wr_nz = 1'b1; end // $CA DEX
						else if (dc_mode == M_IMP) begin dc_class = C_PUSH; dc_src = R_X; end   // $DA PHX
						else if (dc_mode == M_IMM) begin dc_class = C_NOP; end                  // $C2 NOP #
						else begin dc_class = C_RMW; dc_alu = ALU_DEC; dc_wr_nz = 1'b1; end
					end
					3'b111: begin
						// INC / NOP($EA) / $FA PLX
						if (dc_mode == M_ACC) begin dc_class = C_NOP; end                       // $EA NOP
						else if (dc_mode == M_IMP) begin dc_class = C_PULL; dc_dst = R_X; dc_wr_nz = 1'b1; end // $FA PLX
						else if (dc_mode == M_IMM) begin dc_class = C_NOP; end                  // $E2 NOP #
						else begin dc_class = C_RMW; dc_alu = ALU_INC; dc_wr_nz = 1'b1; end
					end
				endcase
			end
			// $9E STZ abs,X and $96/$B6 zp,Y and $BE abs,Y adjustments
			if (ir == 8'h9E) begin dc_class = C_STORE; dc_src = R_Z; dc_mode = M_ABX; dc_alu = ALU_PASS; dc_wr_nz = 1'b0; dc_wr_c = 1'b0; end
			if (ir == 8'hBE) begin dc_mode = M_ABY; end
			// $1A INC A / $3A DEC A (cc=10, bbb=110 rows 0/1)
			if (ir == 8'h1A) begin dc_mode = M_ACC; dc_class = C_TXFR; dc_src = R_A; dc_dst = R_A; dc_alu = ALU_INC; dc_wr_nz = 1'b1; end
			if (ir == 8'h3A) begin dc_mode = M_ACC; dc_class = C_TXFR; dc_src = R_A; dc_dst = R_A; dc_alu = ALU_DEC; dc_wr_nz = 1'b1; end
			if (ir == 8'h5A) begin dc_mode = M_IMP; dc_class = C_PUSH; dc_src = R_Y; end   // PHY
			if (ir == 8'h7A) begin dc_mode = M_IMP; dc_class = C_PULL; dc_dst = R_Y; dc_wr_nz = 1'b1; end // PLY
		end
		// --------------------------------------------------------------
		2'b00: begin
			case (d_bbb)
				3'b000: dc_mode = M_IMM;    // rows: BRK/JSR/RTI/RTS use M_STK below
				3'b001: dc_mode = M_ZP;
				3'b010: dc_mode = M_IMP;    // stack/implied column
				3'b011: dc_mode = M_ABS;
				3'b100: dc_mode = M_REL;    // branch column ($x0 rows 8-F... see below)
				3'b101: dc_mode = M_ZPX;
				3'b110: dc_mode = M_IMP;    // flag column
				3'b111: dc_mode = M_ABX;
			endcase
			// Branch column is xxx10000: bbb=100 covers $10,$30,...,$F0
			case (ir)
				8'h00: begin dc_mode = M_STK; dc_class = C_BRK; end
				8'h20: begin dc_mode = M_STK; dc_class = C_JSR; end
				8'h40: begin dc_mode = M_STK; dc_class = C_RTI; end
				8'h60: begin dc_mode = M_STK; dc_class = C_RTS; end
				8'h80: begin dc_mode = M_REL; dc_class = C_BRA; end   // BRA
				8'hA0: begin dc_class = C_LOAD; dc_dst = R_Y; dc_wr_nz = 1'b1; end // LDY #
				8'hC0: begin dc_class = C_CMP; dc_alu = ALU_CMP; dc_src = R_Y; dc_wr_nz = 1'b1; dc_wr_c = 1'b1; end // CPY #
				8'hE0: begin dc_class = C_CMP; dc_alu = ALU_CMP; dc_src = R_X; dc_wr_nz = 1'b1; dc_wr_c = 1'b1; end // CPX #
				8'h10, 8'h30, 8'h50, 8'h70, 8'h90, 8'hB0, 8'hD0, 8'hF0:
					begin dc_mode = M_REL; dc_class = C_BRA; end
				8'h04: begin dc_class = C_TRB; dc_alu = ALU_TSB; end  // TSB zp
				8'h0C: begin dc_class = C_TRB; dc_alu = ALU_TSB; end  // TSB abs
				8'h14: begin dc_class = C_TRB; dc_alu = ALU_TRB; dc_mode = M_ZP; end   // TRB zp
				8'h1C: begin dc_class = C_TRB; dc_alu = ALU_TRB; dc_mode = M_ABS; end  // TRB abs
				8'h24, 8'h2C: begin dc_class = C_BIT; dc_alu = ALU_BIT; end
				8'h34, 8'h3C: begin dc_class = C_BIT; dc_alu = ALU_BIT; end   // BIT zp,X / abs,X
				8'h44: begin dc_class = C_NOP; dc_mode = M_ZP; end            // NOP zp (3 cyc)
				8'h54, 8'hD4, 8'hF4: begin dc_class = C_NOP; dc_mode = M_ZPX; end
				8'h5C: begin dc_class = C_NOP; dc_mode = M_ABS; end           // 8-cycle NOP (approx: abs read)
				8'hDC, 8'hFC: begin dc_class = C_NOP; dc_mode = M_ABS; end    // 4-cycle NOP abs
				8'h64: begin dc_class = C_STORE; dc_src = R_Z; end            // STZ zp
				8'h74: begin dc_class = C_STORE; dc_src = R_Z; end            // STZ zp,X
				8'h9C: begin dc_class = C_STORE; dc_src = R_Z; dc_mode = M_ABS; end // STZ abs
				8'h84, 8'h8C: begin dc_class = C_STORE; dc_src = R_Y; end     // STY
				8'h94: begin dc_class = C_STORE; dc_src = R_Y; end            // STY zp,X
				8'hA4, 8'hAC, 8'hB4: begin dc_class = C_LOAD; dc_dst = R_Y; dc_wr_nz = 1'b1; end // LDY
				8'hBC: begin dc_class = C_LOAD; dc_dst = R_Y; dc_wr_nz = 1'b1; end // LDY abs,X
				8'hC4, 8'hCC: begin dc_class = C_CMP; dc_alu = ALU_CMP; dc_src = R_Y; dc_wr_nz = 1'b1; dc_wr_c = 1'b1; end // CPY
				8'hE4, 8'hEC: begin dc_class = C_CMP; dc_alu = ALU_CMP; dc_src = R_X; dc_wr_nz = 1'b1; dc_wr_c = 1'b1; end // CPX
				8'h4C: begin dc_class = C_JMP; dc_mode = M_ABS; end
				8'h6C: begin dc_class = C_JMP; dc_mode = M_IAB; end
				8'h7C: begin dc_class = C_JMP; dc_mode = M_IAX; end
				8'h08: begin dc_class = C_PUSH; dc_src = R_P; end   // PHP
				8'h28: begin dc_class = C_PULL; dc_dst = R_P; end   // PLP
				8'h48: begin dc_class = C_PUSH; dc_src = R_A; end   // PHA
				8'h68: begin dc_class = C_PULL; dc_dst = R_A; dc_wr_nz = 1'b1; end // PLA
				8'h88: begin dc_class = C_TXFR; dc_src = R_Y; dc_dst = R_Y; dc_alu = ALU_DEC; dc_wr_nz = 1'b1; end // DEY
				8'hC8: begin dc_class = C_TXFR; dc_src = R_Y; dc_dst = R_Y; dc_alu = ALU_INC; dc_wr_nz = 1'b1; end // INY
				8'hE8: begin dc_class = C_TXFR; dc_src = R_X; dc_dst = R_X; dc_alu = ALU_INC; dc_wr_nz = 1'b1; end // INX
				8'hA8: begin dc_class = C_TXFR; dc_src = R_A; dc_dst = R_Y; dc_wr_nz = 1'b1; end // TAY
				8'h98: begin dc_class = C_TXFR; dc_src = R_Y; dc_dst = R_A; dc_wr_nz = 1'b1; end // TYA
				8'h18, 8'h38, 8'h58, 8'h78, 8'hB8, 8'hD8, 8'hF8:
					begin dc_class = C_FLAG; end
				default: begin dc_class = C_NOP; dc_mode = M_IMP; end
			endcase
		end
		// --------------------------------------------------------------
		2'b11: begin
			// $x3/$xB: single-cycle NOPs (WDC). $x7: RMB/SMB. $xF: BBR/BBS.
			if (ir[2]) begin
				if (ir[3]) begin
					dc_mode  = M_ZPR;        // $xF BBR/BBS
					dc_class = C_BBRS;
				end else begin
					dc_mode  = M_ZP;         // $x7 RMB/SMB
					dc_class = C_RSMB;
				end
			end else begin
				dc_mode  = M_IMP;
				dc_class = C_NOP;            // 1-byte 1-cycle NOP
			end
			// WAI/STP live in the cc=11 NOP columns ($CB/$DB)
			if (ir == 8'hCB) begin dc_mode = M_IMP; dc_class = C_WAI; end
			if (ir == 8'hDB) begin dc_mode = M_IMP; dc_class = C_STP; end
		end
		endcase
	end

	// Branch condition (ir[7:5] selects flag, ir[5]... classic Bxx)
	reg branch_taken;
	always @* begin
		if (ir == 8'h80) branch_taken = 1'b1;   // BRA
		else begin
			case (ir[7:6])
				2'b00: branch_taken = (fl_n == ir[5]);
				2'b01: branch_taken = (fl_v == ir[5]);
				2'b10: branch_taken = (fl_c == ir[5]);
				2'b11: branch_taken = (fl_z == ir[5]);
			endcase
		end
	end

	// BBR/BBS test result (bit of zp data in dl, tested against ir[7])
	wire bbrs_taken = (dl[ir[6:4]] == ir[7]);

	// RTI completion, combinational through the final RTI cycle so the
	// SoC drops the IRR interrupt-bank override at the edge that launches
	// the return-address fetch. The registered form cleared it one cycle
	// late: the first post-RTI OPCODE fetched from the IRR bank while its
	// operands fetched from PRR - a mixed-bank instruction that sent cart
	// games into the weeds (found by the Verilator harness on Soldier).
	assign rti_done = (state == S_VEC_HI) && (ir == 8'h40);

	// Branch target low-byte adder and page-cross detect (offset in dl)
	wire [8:0] bra_sum   = {1'b0, reg_pc[7:0]} + {1'b0, dl};
	wire       bra_cross = dl[7] ? ~bra_sum[8] : bra_sum[8];

	// PC incrementer used where a slice of PC+1 is needed
	wire [15:0] pc_inc = reg_pc + 16'd1;

	assign int_seq = int_active;

	// ------------------------------------------------------------------
	// ALU
	// ------------------------------------------------------------------
	reg  [7:0] alu_a, alu_b;
	reg  [3:0] alu_sel;
	wire [7:0] alu_result;
	wire       alu_c, alu_vf, alu_nf, alu_zf;

	cpu_alu alu (
		.op(alu_sel),
		.a(alu_a),
		.b(alu_b),
		.carry_in(fl_c),
		.decimal(fl_d),
		.result(alu_result),
		.carry_out(alu_c),
		.overflow(alu_vf),
		.negative(alu_nf),
		.zero(alu_zf)
	);

	// Register source mux
	reg [7:0] src_val;
	always @* begin
		case (dc_src)
			R_A: src_val = reg_a;
			R_X: src_val = reg_x;
			R_Y: src_val = reg_y;
			R_S: src_val = reg_s;
			R_P: src_val = reg_p;      // pushes see B set (PHP)
			R_Z: src_val = 8'h00;
			default: src_val = 8'h00;
		endcase
	end

	// ------------------------------------------------------------------
	// Sequencer
	// ------------------------------------------------------------------
	localparam [5:0] S_FETCH   = 6'd0;
	localparam [5:0] S_OP2     = 6'd1;   // second cycle: operand/dummy at PC
	localparam [5:0] S_ZPX_D   = 6'd2;   // dummy read at un-indexed zp
	localparam [5:0] S_ABS_LO  = 6'd3;
	localparam [5:0] S_ABS_HI  = 6'd4;
	localparam [5:0] S_IDX_FIX = 6'd5;   // page-cross / forced index dummy
	localparam [5:0] S_IZX_LO  = 6'd6;
	localparam [5:0] S_IZX_HI  = 6'd7;
	localparam [5:0] S_IZY_LO  = 6'd8;
	localparam [5:0] S_IZY_HI  = 6'd9;
	localparam [5:0] S_READ    = 6'd10;
	// (no BCD extra-cycle state: D=1 ADC/SBC needs no extra bus cycle — the
	//  decimal correction is combinational in the ALU, matching R65Cx2 and
	//  real 65xx silicon; the WDC SST suite's $007F/$0000 dummy reads are a
	//  reference-model artifact, see module_tests/cpu_65c02/wdc_vs_6502_analysis.md)
	localparam [5:0] S_RMW_M   = 6'd12;  // second read of EA (65C02)
	localparam [5:0] S_RMW_WR  = 6'd13;
	localparam [5:0] S_WRITE   = 6'd14;
	localparam [5:0] S_BRA_ADD = 6'd15;
	localparam [5:0] S_BRA_FIX = 6'd16;
	localparam [5:0] S_PUSH    = 6'd17;
	localparam [5:0] S_PULL_D  = 6'd18;  // dummy stack read at old S
	localparam [5:0] S_PULL    = 6'd19;
	localparam [5:0] S_JSR_D   = 6'd20;  // internal stack cycle
	localparam [5:0] S_JSR_PH  = 6'd21;
	localparam [5:0] S_JSR_PL  = 6'd22;
	localparam [5:0] S_JSR_HI  = 6'd23;
	localparam [5:0] S_RTS_D   = 6'd24;
	localparam [5:0] S_RTS_PL  = 6'd25;
	localparam [5:0] S_RTS_PH  = 6'd26;
	localparam [5:0] S_RTS_INC = 6'd27;  // dummy read at pulled PC, then PC++
	localparam [5:0] S_RTI_P   = 6'd28;
	localparam [5:0] S_RTI_PL  = 6'd29;
	localparam [5:0] S_RTI_PH  = 6'd30;
	localparam [5:0] S_BRK_PH  = 6'd31;
	localparam [5:0] S_BRK_PL  = 6'd32;
	localparam [5:0] S_BRK_P   = 6'd33;
	localparam [5:0] S_VEC_LO  = 6'd34;
	localparam [5:0] S_VEC_HI  = 6'd35;
	localparam [5:0] S_JMP_LO  = 6'd36;  // (abs)/(abs,X) pointer reads
	localparam [5:0] S_JMP_HI  = 6'd37;
	localparam [5:0] S_ZPR_RD  = 6'd38;  // BBR/BBS zp data read
	localparam [5:0] S_ZPR_OFF = 6'd39;  // BBR/BBS offset fetch
	localparam [5:0] S_ZPR_INT = 6'd40;  // BBR/BBS internal cycle
	localparam [5:0] S_WAI     = 6'd41;
	localparam [5:0] S_STP     = 6'd42;
	localparam [5:0] S_NOP8    = 6'd43;  // $5C filler cycles

	reg [5:0] state;
	reg [2:0] nop8_cnt;
	reg       idx_carry;      // page-cross flag from indexed low-byte add
	reg [7:0] idx_reg;        // X or Y for the active indexed mode

	// Deferred register/flag writeback (applied at instruction end)
	task automatic do_writeback(input [2:0] dst, input [7:0] val);
		begin
			case (dst)
				R_A: reg_a <= val;
				R_X: reg_x <= val;
				R_Y: reg_y <= val;
				R_S: reg_s <= val;
				R_P: begin
					fl_n <= val[7];
					fl_v <= val[6];
					fl_d <= val[3];
					fl_i <= val[2];
					fl_z <= val[1];
					fl_c <= val[0];
				end
				default: ;
			endcase
		end
	endtask

	task automatic set_alu_flags;
		begin
			if (dc_wr_nz) begin
				fl_n <= alu_nf;
				fl_z <= alu_zf;
			end
			if (dc_wr_c) fl_c <= alu_c;
			if (dc_wr_v) fl_v <= alu_vf;
		end
	endtask

	// Interrupt recognition at fetch
	wire take_int = nmi_pending || (~irq_n && !fl_i);

	always @(posedge clk) begin
		if (reset) begin
			reg_a       <= 8'h00;
			reg_x       <= 8'h00;
			reg_y       <= 8'h00;
			reg_s       <= 8'h00;
			reg_pc      <= 16'h0000;
			fl_n        <= 1'b0;
			fl_v        <= 1'b0;
			fl_d        <= 1'b0;
			fl_i        <= 1'b1;
			fl_z        <= 1'b0;
			fl_c        <= 1'b0;
			ir          <= 8'h00;
			dl          <= 8'h00;
			ea          <= 16'h0000;
			addr        <= 16'hFFFC;
			dout        <= 8'h00;
			we          <= 1'b0;
			sync        <= 1'b0;
			vector_pull <= 1'b1;
			in_wai      <= 1'b0;
			in_stp      <= 1'b0;
			nmi_pending <= 1'b0;
			nmi_last    <= 1'b1;
			int_active  <= 1'b1;    // reset behaves as an interrupt sequence
			int_is_nmi  <= 1'b0;
			state       <= S_VEC_LO;
			nop8_cnt    <= 3'd0;
			idx_carry   <= 1'b0;
			idx_reg     <= 8'h00;
		end else begin
			// NMI edge detect runs every clock
			nmi_last <= nmi_n;
			if (nmi_last && !nmi_n) nmi_pending <= 1'b1;

			if (ce && !stall && rdy && !in_stp) begin
				we       <= 1'b0;
				sync     <= 1'b0;
				vector_pull <= 1'b0;

				case (state)
				// ------------------------------------------------------
				S_FETCH: begin
					// din = opcode
					if (take_int) begin
						// discard opcode, run interrupt sequence
						ir         <= 8'h00;
						int_active <= 1'b1;
						int_is_nmi <= nmi_pending;
						addr       <= reg_pc;      // dummy re-read
						state      <= S_OP2;
					end else begin
						ir         <= din;
						int_active <= 1'b0;
						reg_pc     <= reg_pc + 16'd1;
						addr       <= reg_pc + 16'd1;
						state      <= S_OP2;
					end
				end
				// ------------------------------------------------------
				S_OP2: begin
					// din = byte after opcode (operand / dummy)
					case (dc_mode)
						M_IMP, M_ACC: begin
							// Execute single-cycle register ops
							case (dc_class)
								C_TXFR: begin
									// INC/DEC A, DEX/DEY/INX/INY route through ALU
									set_alu_flags;
									do_writeback(dc_dst, alu_result);
								end
								C_ALU: begin
									// ASL/LSR/ROL/ROR A
									set_alu_flags;
									do_writeback(dc_dst, alu_result);
								end
								C_FLAG: begin
									case (ir)
										8'h18: fl_c <= 1'b0;
										8'h38: fl_c <= 1'b1;
										8'h58: fl_i <= 1'b0;
										8'h78: fl_i <= 1'b1;
										8'hB8: fl_v <= 1'b0;
										8'hD8: fl_d <= 1'b0;
										8'hF8: fl_d <= 1'b1;
										default: ;
									endcase
								end
								default: ;   // NOP1 etc.
							endcase
							if (dc_class == C_PUSH) begin
								addr  <= {8'h01, reg_s};
								dout  <= src_val;
								we    <= 1'b1;
								state <= S_PUSH;
							end else if (dc_class == C_PULL) begin
								addr  <= {8'h01, reg_s};
								state <= S_PULL_D;
							end else if (dc_class == C_WAI) begin
								in_wai <= 1'b1;
								addr   <= reg_pc;
								state  <= S_WAI;
							end else if (dc_class == C_STP && !stp_nop) begin
								in_stp <= 1'b1;
								state  <= S_STP;
							end else begin
								addr  <= reg_pc;
								sync  <= 1'b1;
								state <= S_FETCH;
							end
						end
						M_IMM: begin
							reg_pc <= reg_pc + 16'd1;
							// din = immediate operand: execute now
							if (dc_class == C_BITI) begin
								fl_z <= ((reg_a & din) == 8'h00);
							end else begin
								set_alu_flags;
								if (dc_class == C_ALU || dc_class == C_LOAD)
									do_writeback(dc_dst, alu_result);
							end
							addr  <= reg_pc + 16'd1;
							sync  <= 1'b1;
							state <= S_FETCH;
						end
						M_ZP: begin
							reg_pc <= reg_pc + 16'd1;
							ea     <= {8'h00, din};
							addr   <= {8'h00, din};
							if (dc_class == C_STORE) begin
								dout  <= src_val;
								we    <= 1'b1;
								state <= S_WRITE;
							end else begin
								state <= S_READ;
							end
						end
						M_ZPX, M_ZPY: begin
							reg_pc <= reg_pc + 16'd1;
							dl     <= din;
							addr   <= {8'h00, din};   // dummy read, un-indexed
							idx_reg <= (dc_mode == M_ZPY) ? reg_y : reg_x;
							state  <= S_ZPX_D;
						end
						M_ABS, M_IAB, M_IAX: begin
							reg_pc <= reg_pc + 16'd1;
							dl     <= din;
							addr   <= reg_pc + 16'd1;
							state  <= S_ABS_HI;
						end
						M_ABX, M_ABY: begin
							reg_pc <= reg_pc + 16'd1;
							dl     <= din;
							addr   <= reg_pc + 16'd1;
							idx_reg <= (dc_mode == M_ABY) ? reg_y : reg_x;
							state  <= S_ABS_HI;
						end
						M_IZX: begin
							reg_pc <= reg_pc + 16'd1;
							dl     <= din;
							addr   <= {8'h00, din};   // dummy
							state  <= S_ZPX_D;
						end
						M_IZY: begin
							reg_pc <= reg_pc + 16'd1;
							dl     <= din;
							addr   <= {8'h00, din};
							state  <= S_IZY_LO;
						end
						M_IZP: begin
							reg_pc <= reg_pc + 16'd1;
							dl     <= din;
							addr   <= {8'h00, din};
							state  <= S_IZY_LO;   // shared: read lo/hi then no index
						end
						M_REL: begin
							reg_pc <= reg_pc + 16'd1;
							dl     <= din;
							if (branch_taken) begin
								addr  <= reg_pc + 16'd1;   // dummy
								state <= S_BRA_ADD;
							end else begin
								addr  <= reg_pc + 16'd1;
								sync  <= 1'b1;
								state <= S_FETCH;
							end
						end
						M_ZPR: begin
							reg_pc <= reg_pc + 16'd1;
							ea     <= {8'h00, din};
							addr   <= {8'h00, din};
							state  <= S_ZPR_RD;
						end
						M_STK: begin
							// BRK/JSR/RTI/RTS second cycle
							case (dc_class)
								C_BRK: begin
									// BRK skips its padding byte; a hardware
									// interrupt pushes the un-incremented PC.
									if (!int_active) reg_pc <= pc_inc;
									addr  <= {8'h01, reg_s};
									dout  <= int_active ? reg_pc[15:8] : pc_inc[15:8];
									we    <= 1'b1;
									state <= S_BRK_PH;
								end
								C_JSR: begin
									reg_pc <= reg_pc + 16'd1;
									dl     <= din;             // target lo
									addr   <= {8'h01, reg_s};  // internal cycle
									state  <= S_JSR_D;
								end
								C_RTI: begin
									addr  <= {8'h01, reg_s};   // dummy stack read
									state <= S_RTI_P;
								end
								C_RTS: begin
									addr  <= {8'h01, reg_s};   // dummy stack read
									state <= S_RTS_PL;
								end
								default: ;
							endcase
						end
						default: begin
							addr  <= reg_pc;
							sync  <= 1'b1;
							state <= S_FETCH;
						end
					endcase
					// M_IMP one-cycle NOPs ($x3/$xB): 1 byte, 1 cycle total.
					// They re-fetch immediately without consuming this byte.
					if (dc_class == C_NOP && dc_mode == M_IMP && d_cc == 2'b11) begin
						addr  <= reg_pc;
						sync  <= 1'b1;
						state <= S_FETCH;
					end
				end
				// ------------------------------------------------------
				S_ZPX_D: begin
					// din = dummy; index now
					if (dc_mode == M_IZX) begin
						addr  <= {8'h00, dl + reg_x};
						state <= S_IZX_LO;
					end else begin
						ea   <= {8'h00, dl + idx_reg};
						addr <= {8'h00, dl + idx_reg};
						if (dc_class == C_STORE) begin
							dout  <= src_val;
							we    <= 1'b1;
							state <= S_WRITE;
						end else begin
							state <= S_READ;
						end
					end
				end
				S_ABS_HI: begin
					// din = high byte
					reg_pc <= reg_pc + 16'd1;
					if (dc_class == C_JMP && dc_mode == M_ABS) begin
						reg_pc <= {din, dl};
						addr   <= {din, dl};
						sync   <= 1'b1;
						state  <= S_FETCH;
					end else if (dc_mode == M_IAB) begin
						ea    <= {din, dl};
						addr  <= {din, dl};
						state <= S_IDX_FIX;   // 6-cycle (abs): extra internal cycle
					end else if (dc_mode == M_IAX) begin
						ea    <= {din, dl} + {8'd0, reg_x};
						addr  <= reg_pc + 16'd1;   // internal indexing cycle
						state <= S_IDX_FIX;
					end else if (dc_mode == M_ABX || dc_mode == M_ABY) begin
						{idx_carry, ea[7:0]} <= {1'b0, dl} + {1'b0, idx_reg};
						ea[15:8] <= din;
						// Cross/forced-dummy decision happens next cycle via
						// idx_carry; launch the (possibly wrong-page) access.
						addr <= {din, dl + idx_reg};
						if (dc_class == C_STORE) begin
							state <= S_IDX_FIX;   // stores always take the fix cycle
						end else if (dc_class == C_RMW &&
						             (dc_alu == ALU_ASL || dc_alu == ALU_LSR ||
						              dc_alu == ALU_ROL || dc_alu == ALU_ROR)) begin
							state <= S_READ;      // W65C02S shift RMW abs,X: 6+p
						end else if (dc_class == C_RMW || dc_class == C_TRB) begin
							state <= S_IDX_FIX;   // INC/DEC abs,X always 7
						end else begin
							state <= S_READ;      // page cross inserts fix in S_READ
						end
					end else begin
						ea   <= {din, dl};
						addr <= {din, dl};
						if (dc_class == C_STORE) begin
							dout  <= src_val;
							we    <= 1'b1;
							state <= S_WRITE;
						end else begin
							state <= S_READ;
						end
					end
				end
				S_IDX_FIX: begin
					// Internal/fix cycle for indexed stores/RMW and JMP indirect
					if (dc_class == C_JMP) begin
						addr  <= ea;
						state <= S_JMP_LO;
					end else begin
						ea    <= ea + (idx_carry ? 16'd256 : 16'd0);
						addr  <= ea + (idx_carry ? 16'd256 : 16'd0);
						idx_carry <= 1'b0;
						if (dc_class == C_STORE) begin
							dout  <= src_val;
							we    <= 1'b1;
							state <= S_WRITE;
						end else begin
							state <= S_READ;
						end
					end
				end
				S_IZX_LO: begin
					dl    <= din;              // pointer lo
					addr  <= {8'h00, addr[7:0] + 8'd1};
					state <= S_IZX_HI;
				end
				S_IZX_HI: begin
					ea   <= {din, dl};
					addr <= {din, dl};
					if (dc_class == C_STORE) begin
						dout  <= src_val;
						we    <= 1'b1;
						state <= S_WRITE;
					end else begin
						state <= S_READ;
					end
				end
				S_IZY_LO: begin
					dl    <= din;              // pointer lo
					addr  <= {8'h00, addr[7:0] + 8'd1};
					state <= S_IZY_HI;
				end
				S_IZY_HI: begin
					if (dc_mode == M_IZP) begin
						ea   <= {din, dl};
						addr <= {din, dl};
						if (dc_class == C_STORE) begin
							dout  <= src_val;
							we    <= 1'b1;
							state <= S_WRITE;
						end else begin
							state <= S_READ;
						end
					end else begin
						{idx_carry, ea[7:0]} <= {1'b0, dl} + {1'b0, reg_y};
						ea[15:8] <= din;
						addr <= {din, dl + reg_y};
						if (dc_class == C_STORE) begin
							state <= S_IDX_FIX;
						end else begin
							state <= S_READ;
						end
					end
				end
				// ------------------------------------------------------
				S_READ: begin
					// Page-cross fix for read-type indexed modes: the access
					// just completed was on the wrong page; redo it.
					if (idx_carry) begin
						idx_carry <= 1'b0;
						ea        <= ea + 16'd256;
						addr      <= ea + 16'd256;
						state     <= S_READ;
					end else begin
						// din = memory operand
						case (dc_class)
							C_RMW, C_TRB, C_RSMB: begin
								dl    <= din;
								addr  <= ea;        // 65C02 second read
								state <= S_RMW_M;
							end
							C_BIT: begin
								fl_n <= din[7];
								fl_v <= din[6];
								fl_z <= ((reg_a & din) == 8'h00);
								addr  <= reg_pc;
								sync  <= 1'b1;
								state <= S_FETCH;
							end
							C_NOP: begin
								addr  <= reg_pc;
								sync  <= 1'b1;
								if (ir == 8'h5C) begin
									nop8_cnt <= 3'd4;   // $5C burns 4 extra cycles
									sync     <= 1'b0;
									state    <= S_NOP8;
								end else begin
									state <= S_FETCH;
								end
							end
							default: begin
								set_alu_flags;
								if (dc_class == C_ALU || dc_class == C_LOAD)
									do_writeback(dc_dst, alu_result);
								addr  <= reg_pc;
								sync  <= 1'b1;
								state <= S_FETCH;
							end
						endcase
					end
				end
				S_RMW_M: begin
					// din = second read (discard); write modified value
					addr  <= ea;
					we    <= 1'b1;
					if (dc_class == C_RSMB) begin
						dout <= ir[7] ? (dl | (8'h01 << ir[6:4]))
						              : (dl & ~(8'h01 << ir[6:4]));
					end else begin
						dout <= alu_result;
						if (dc_class == C_TRB) begin
							fl_z <= ((reg_a & dl) == 8'h00);
						end else begin
							set_alu_flags;
						end
					end
					state <= S_RMW_WR;
				end
				S_RMW_WR: begin
					addr  <= reg_pc;
					sync  <= 1'b1;
					state <= S_FETCH;
				end
				S_WRITE: begin
					addr  <= reg_pc;
					sync  <= 1'b1;
					state <= S_FETCH;
				end
				S_NOP8: begin
					nop8_cnt <= nop8_cnt - 3'd1;
					addr     <= reg_pc;
					if (nop8_cnt == 3'd1) begin
						sync  <= 1'b1;
						state <= S_FETCH;
					end
				end
				// ------------------------------------------------------
				S_BRA_ADD: begin
					// din = dummy; apply the low-byte add. A carry (forward
					// branch) or missing borrow (backward branch) means the
					// high byte still needs the fix cycle.
					reg_pc[7:0] <= bra_sum[7:0];
					addr        <= {reg_pc[15:8], bra_sum[7:0]};
					if (bra_cross) begin
						state <= S_BRA_FIX;
					end else begin
						sync  <= 1'b1;
						state <= S_FETCH;
					end
				end
				S_BRA_FIX: begin
					reg_pc[15:8] <= reg_pc[15:8] + (dl[7] ? 8'hFF : 8'h01);
					addr  <= {reg_pc[15:8] + (dl[7] ? 8'hFF : 8'h01), reg_pc[7:0]};
					sync  <= 1'b1;
					state <= S_FETCH;
				end
				// ------------------------------------------------------
				S_PUSH: begin
					reg_s <= reg_s - 8'd1;
					addr  <= reg_pc;
					sync  <= 1'b1;
					state <= S_FETCH;
				end
				S_PULL_D: begin
					reg_s <= reg_s + 8'd1;
					addr  <= {8'h01, reg_s + 8'd1};
					state <= S_PULL;
				end
				S_PULL: begin
					if (dc_dst == R_P) begin
						do_writeback(R_P, din);
					end else begin
						do_writeback(dc_dst, din);
						if (dc_wr_nz) begin
							fl_n <= din[7];
							fl_z <= (din == 8'h00);
						end
					end
					addr  <= reg_pc;
					sync  <= 1'b1;
					state <= S_FETCH;
				end
				// ------------------------------------------------------
				S_JSR_D: begin
					addr  <= {8'h01, reg_s};
					dout  <= reg_pc[15:8];
					we    <= 1'b1;
					state <= S_JSR_PH;
				end
				S_JSR_PH: begin
					reg_s <= reg_s - 8'd1;
					addr  <= {8'h01, reg_s - 8'd1};
					dout  <= reg_pc[7:0];
					we    <= 1'b1;
					state <= S_JSR_PL;
				end
				S_JSR_PL: begin
					reg_s <= reg_s - 8'd1;
					addr  <= reg_pc;           // fetch target hi
					state <= S_JSR_HI;
				end
				S_JSR_HI: begin
					reg_pc <= {din, dl};
					addr   <= {din, dl};
					sync   <= 1'b1;
					state  <= S_FETCH;
				end
				// ------------------------------------------------------
				S_RTS_PL: begin
					reg_s <= reg_s + 8'd1;
					addr  <= {8'h01, reg_s + 8'd1};
					state <= S_RTS_PH;
				end
				S_RTS_PH: begin
					dl    <= din;              // PCL
					reg_s <= reg_s + 8'd1;
					addr  <= {8'h01, reg_s + 8'd1};
					state <= S_RTS_INC;
				end
				S_RTS_INC: begin
					reg_pc <= {din, dl};
					addr   <= {din, dl};       // dummy read at pulled PC
					state  <= S_RTS_D;
				end
				S_RTS_D: begin
					reg_pc <= reg_pc + 16'd1;
					addr   <= reg_pc + 16'd1;
					sync   <= 1'b1;
					state  <= S_FETCH;
				end
				// ------------------------------------------------------
				S_RTI_P: begin
					reg_s <= reg_s + 8'd1;
					addr  <= {8'h01, reg_s + 8'd1};
					state <= S_RTI_PL;
				end
				S_RTI_PL: begin
					do_writeback(R_P, din);
					reg_s <= reg_s + 8'd1;
					addr  <= {8'h01, reg_s + 8'd1};
					state <= S_RTI_PH;
				end
				S_RTI_PH: begin
					dl    <= din;              // PCL
					reg_s <= reg_s + 8'd1;
					addr  <= {8'h01, reg_s + 8'd1};
					state <= S_VEC_HI;         // reuse: next read completes PC
					// mark RTI completion on the final cycle
				end
				// ------------------------------------------------------
				S_BRK_PH: begin
					reg_s <= reg_s - 8'd1;
					addr  <= {8'h01, reg_s - 8'd1};
					dout  <= reg_pc[7:0];
					we    <= 1'b1;
					state <= S_BRK_PL;
				end
				S_BRK_PL: begin
					reg_s <= reg_s - 8'd1;
					addr  <= {8'h01, reg_s - 8'd1};
					dout  <= {fl_n, fl_v, 1'b1, ~int_active, fl_d, fl_i, fl_z, fl_c};
					we    <= 1'b1;
					state <= S_BRK_P;
				end
				S_BRK_P: begin
					reg_s <= reg_s - 8'd1;
					fl_i  <= 1'b1;
					fl_d  <= 1'b0;             // 65C02 clears D on interrupt
					vector_pull <= 1'b1;
					if (int_is_nmi) begin
						addr <= 16'hFFFA;
						nmi_pending <= 1'b0;
					end else begin
						addr <= 16'hFFFE;
					end
					state <= S_VEC_LO;
				end
				S_VEC_LO: begin
					dl          <= din;
					vector_pull <= 1'b1;
					addr        <= {addr[15:1], 1'b1};
					state       <= S_VEC_HI;
				end
				S_VEC_HI: begin
					// Shared by interrupt entry and RTI's final PC assembly
					reg_pc <= {din, dl};
					addr   <= {din, dl};
					sync   <= 1'b1;
					state  <= S_FETCH;
				end
				// ------------------------------------------------------
				S_JMP_LO: begin
					dl    <= din;
					addr  <= ea + 16'd1;
					state <= S_JMP_HI;
				end
				S_JMP_HI: begin
					reg_pc <= {din, dl};
					addr   <= {din, dl};
					sync   <= 1'b1;
					state  <= S_FETCH;
				end
				// ------------------------------------------------------
				S_ZPR_RD: begin
					dl    <= din;              // zp data to test
					addr  <= reg_pc;           // fetch offset
					state <= S_ZPR_OFF;
				end
				S_ZPR_OFF: begin
					reg_pc <= reg_pc + 16'd1;
					ea[7:0] <= din;            // offset parked in ea low
					addr   <= reg_pc + 16'd1;  // internal cycle
					state  <= S_ZPR_INT;
				end
				S_ZPR_INT: begin
					if (bbrs_taken) begin
						dl    <= ea[7:0];      // hand offset to branch path
						addr  <= reg_pc;
						state <= S_BRA_ADD;
					end else begin
						addr  <= reg_pc;
						sync  <= 1'b1;
						state <= S_FETCH;
					end
				end
				// ------------------------------------------------------
				S_WAI: begin
					if (nmi_pending || ~irq_n) begin
						in_wai <= 1'b0;
						addr   <= reg_pc;
						sync   <= 1'b1;
						state  <= S_FETCH;   // masked IRQ resumes; unmasked vectors at fetch
					end else begin
						addr <= reg_pc;      // hold
					end
				end
				S_STP: begin
					// Only reset leaves; in_stp gates the whole block anyway
					state <= S_STP;
				end
				default: begin
					addr  <= reg_pc;
					sync  <= 1'b1;
					state <= S_FETCH;
				end
				endcase
			end
			// Savestate restore (core held in stall while these apply)
			if (ss_wren && (ss_addr == SS_BASE)) begin
				reg_pc <= ss_wdata[63:48];
				reg_a  <= ss_wdata[47:40];
				reg_x  <= ss_wdata[39:32];
				reg_y  <= ss_wdata[31:24];
				reg_s  <= ss_wdata[23:16];
				fl_n   <= ss_wdata[15];
				fl_v   <= ss_wdata[14];
				fl_d   <= ss_wdata[11];
				fl_i   <= ss_wdata[10];
				fl_z   <= ss_wdata[9];
				fl_c   <= ss_wdata[8];
				ir     <= ss_wdata[7:0];
			end
			if (ss_wren && (ss_addr == SS_BASE + 10'd1)) begin
				dl          <= ss_wdata[63:56];
				ea          <= ss_wdata[55:40];
				state       <= ss_wdata[39:34];
				nmi_pending <= ss_wdata[33];
				nmi_last    <= ss_wdata[32];
				int_active  <= ss_wdata[31];
				int_is_nmi  <= ss_wdata[30];
				in_wai      <= ss_wdata[29];
				in_stp      <= ss_wdata[28];
				idx_carry   <= ss_wdata[27];
				idx_reg     <= ss_wdata[26:19];
				nop8_cnt    <= ss_wdata[18:16];
				addr        <= ss_wdata[15:0];
			end
			if (ss_wren && (ss_addr == SS_BASE + 10'd2)) begin
				we          <= ss_wdata[10];
				sync        <= ss_wdata[9];
				vector_pull <= ss_wdata[8];
				dout        <= ss_wdata[7:0];
			end
		end
	end

	// ALU operand routing (combinational, evaluated in the cycle that uses it)
	always @* begin
		alu_sel = dc_alu;
		alu_a   = reg_a;
		alu_b   = din;
		case (dc_class)
			C_CMP:  begin alu_a = src_val; end
			C_TXFR: begin
				// INC/DEC/transfer route the source through b
				alu_b = src_val;
				if (dc_alu == ALU_PASS) alu_sel = ALU_PASS;
			end
			C_ALU: begin
				if (dc_mode == M_ACC) alu_b = reg_a;   // shifts on A
			end
			C_RMW, C_TRB: begin
				alu_b = (state == S_RMW_M) ? dl : din;
			end
			default: ;
		endcase
	end

	// Savestate words: 0 = architectural registers; 1 = sequencer state;
	// 2 = bus output registers
	assign ss_rdata =
		(ss_addr == SS_BASE) ?
			{reg_pc, reg_a, reg_x, reg_y, reg_s,
			 fl_n, fl_v, 2'b11, fl_d, fl_i, fl_z, fl_c, ir} :
		(ss_addr == SS_BASE + 10'd1) ?
			{dl, ea, state, nmi_pending, nmi_last, int_active, int_is_nmi,
			 in_wai, in_stp, idx_carry, idx_reg, nop8_cnt, addr} :
		(ss_addr == SS_BASE + 10'd2) ?
			{53'd0, we, sync, vector_pull, dout} : 64'd0;

	wire unused_ok = &{1'b0, ce_n, alu_zf, ss_wdata[63:11]};

endmodule
