// apple2_verilog_tb.sv
//
// Cycle-equivalence testbench for the Verilog `apple2` full core (candidate
// side).  The golden side is module_tests/apple2/apple2_vhdl_tb.vhd, which
// drives the VHDL `apple2` entity with the identical stimulus schedule below
// and writes the same CSV schema.
//
// Run with CWD = this repository root so that "rtl/roms/apple2e.hex"
// (main ROM, via rom.v) resolves.
//
// Machine model (identical to the VHDL bench):
//   * Main/aux RAM is a stateless deterministic function of ADDR (low byte and
//     high byte use different functions so aux misrouting is observable).
//     A few small regions hold the CPU program this harness executes.
//   * Slot 1 (C1xx) serves the Phase A program from PD.
//   * Main RAM holds a JMP $C100 at $5858: the real ROM boot path ends with
//     RTS from the $FE84 subroutine.  T65 JSR pushes PC+2 and RTS adds +1 to
//     the popped value, so the deterministic pattern walk lands at $5858;
//     $5857 holds a NOP guard.  The JMP hands control to Phase A.
//   * Main RAM holds a JMP $C3FA at $03FB: the ROM NMI vector ($FFFA/$FFFB)
//     maps to $03FB under this core's rom_addr = A[13:0] mapping; the
//     trampoline makes the NMI pulse execute the real IIe NMI handler
//     (BIT $C015 / STA $C007 / CLD / SEI / JSR $0101), which then falls into
//     the deterministic pattern code in main RAM at $0101.
//   * All other slot reads return a deterministic f(cycle, ADDR).

`timescale 1ns/1ps

module apple2_verilog_tb;

   // Shared constants (must match apple2_vhdl_tb.vhd exactly)
   localparam integer TOTAL        = 320000;
   localparam integer TRACE_START  = 0;       // from reset: vector reads + boot handoff
   localparam integer DENSE_END    = 3000;
   localparam integer SPARSE_BASE  = 8128;   // sparse rows at SPARSE_BASE + 16k
   localparam integer RESET_CYCLES = 64;
   localparam integer WAIT_LO      = 2600;
   localparam integer WAIT_HI      = 2615;
   localparam integer NMI_LO       = 8000;
   localparam integer NMI_HI       = 8009;
   localparam integer AKD_LO       = 100;
   localparam integer AKD_HI       = 500;
   localparam integer IOCTL_LO     = 12000;
   localparam integer IOCTL_HI     = 12120;
   localparam integer IOCTL_Q      = 30;
   localparam integer ROMSW_AT     = 250000;
   localparam integer FLASH_P      = 30000;
   localparam integer NMI_TRACE_LO = 7990;  // dense trace window around the NMI pulse
   localparam integer NMI_TRACE_HI = 8120;

   localparam string TRACE_FILE = "module_tests/apple2/build/verilog_trace.csv";

   // Phase A program (full C1xx page, 256 bytes).  Code occupies C100-C14F;
   // the rest is NOP padding.  Core softswitch facts this relies on:
   //  * $C050-$C05F writes latch soft_switches[A[3:1]] := A[0] (value comes
   //    from the ADDRESS, not the data bus): $C055 sets PAGE2=1.
   //  * $C000-$C00F write-only latches (PHASE_ZERO_R & we), also value = A[0]:
   //    $C001 STORE80=1, $C003 RAMRD=1, $C00C COL80=0, etc.
   //  * The core latches SF_D at PHASE_ZERO_R, i.e. AFTER T65 samples DI, so
   //    a C01x read returns the value latched by the PREVIOUS C01x read.
   //    Each test is therefore preceded by a dummy C01x read that latches the
   //    flag under test, and an LDA #0 that normalizes A/flags (also clears
   //    VHDL 'U' after the very first read).
   //  * $C01C source = PAGE2, $C013 source = RAMRD.
   //  * STA $C001 sets STORE80 so Phase B's page-06 writes route to AUX RAM
   //    (auxRamWriteObserved gate).
   //  * Softswitch-test failure jumps to the $05A0 error park, making a bad
   //    softswitch readback observable via the errorParkReached gate.
   //  * $C800 is read before $C300 because any C3xx access with C3ROM=0
   //    latches C8ROM=1 in the core, which would route later C8xx-CFxx reads
   //    to ROM instead of generating IO_STROBE.
   localparam reg [7:0] PHASE_A [0:255] = '{
      // C100 CLE | C101 LDA #0 | C103 STA $C00C (COL80=0) | C106 LDA #0
      // C108 STA $C0FF (devselect write, harmless) | C10B LDA #$42
      8'h38, 8'hA9, 8'h00, 8'h8D, 8'h0C, 8'hC0, 8'hA9, 8'h00, 8'h8D, 8'hFF, 8'hC0, 8'hA9, 8'h42, 8'h8D, 8'h00, 8'h01,
      // C110 LDA $0100 | C113 LDA #$55 | C115 STA $C055 (PAGE2=1)
      // C118 LDA $C01C (dummy: latches SF_D := PAGE2) | C11B LDA #0
      8'hAD, 8'h00, 8'h01, 8'hA9, 8'h55, 8'h8D, 8'h55, 8'hC0, 8'hAD, 8'h1C, 8'hC0, 8'hA9, 8'h00, 8'hAD, 8'h1C, 8'hC0,
      // C11D LDA $C01C (test 1) | C120 AND #$80 | C122 BNE -> $C129
      // C124 JMP $05A0 (error park) | C127-C128 NOPs | C129 LDA #0
      // C12B STA $C003 (RAMRD=1) | C12E LDA $C013 (dummy: latches SF_D := RAMRD)
      8'h29, 8'h80, 8'hD0, 8'h05, 8'h4C, 8'hA0, 8'h05, 8'hEA, 8'hEA, 8'hA9, 8'h00, 8'h8D, 8'h03, 8'hC0, 8'hAD, 8'h13,
      // C130 (cont) | C131 LDA #0 | C133 LDA $C013 (test 2) | C136 AND #$80
      // C138 BNE -> $C13F | C13A JMP $05A0 (error park) | C13D-C13E NOPs
      // C13F LDA $C100 (PD feedback)
      8'hC0, 8'hA9, 8'h00, 8'hAD, 8'h13, 8'hC0, 8'h29, 8'h80, 8'hD0, 8'h05, 8'h4C, 8'hA0, 8'h05, 8'hEA, 8'hEA, 8'hAD,
      // C140 (cont) | C142 LDA $C800 (IO_STROBE) | C145 LDA $C300 (ROM, latches C8ROM)
      // C148 LDA #1 | C14A STA $C001 (STORE80=1) | C14D JMP $0540 (Phase B)
      8'h00, 8'hC1, 8'hAD, 8'h00, 8'hC8, 8'hAD, 8'h00, 8'hC3, 8'hA9, 8'h01, 8'h8D, 8'h01, 8'hC0, 8'h4C, 8'h40, 8'h05,
      // C150-C1FF NOP padding tail (code ends at $C14F)
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA,
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA,
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA,
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA,
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA,
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA,
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA,
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA,
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA,
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA,
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA,
      8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA, 8'hEA
   };

   // Phase B program (47 bytes), held in main RAM at $0540-$056E.
   localparam reg [7:0] PHASE_B [0:46] = '{
      8'hA9, 8'h37, 8'h8D, 8'h60, 8'h06, 8'hAD, 8'h60, 8'h06,
      8'hA9, 8'h5A, 8'h8D, 8'h20, 8'h02, 8'hAD, 8'h20, 8'h02,
      8'hA9, 8'h6B, 8'h8D, 8'h30, 8'hC0, 8'hAD, 8'h00, 8'hC0,
      8'hAD, 8'h60, 8'hC0, 8'hAD, 8'h70, 8'hC0, 8'hAD, 8'h40,
      8'hC0, 8'hAD, 8'h90, 8'hC0, 8'h8D, 8'h90, 8'hC0, 8'hAD,
      8'h00, 8'hC2, 8'hA9, 8'h77, 8'h4C, 8'h80, 8'h05
   };

   // Main RAM low byte: deterministic function of ADDR with program overrides.
   function automatic [7:0] main_byte(input [15:0] a);
      integer ai;
      begin
         ai = a;
         if (ai >= 16'h5857 && ai <= 16'h585B) begin
            // Boot handoff: the ROM boot path ends with RTS from $FE84.  T65
            // JSR pushes PC+2 and RTS adds +1 to the popped value, so the
            // deterministic pattern walk lands at $5858; $5857 is a NOP guard.
            case (ai - 16'h5857)
               0:       main_byte = 8'hEA;
               1:       main_byte = 8'h4C;
               2:       main_byte = 8'h00;
               3:       main_byte = 8'hC1;
               default: main_byte = 8'hEA;
            endcase
         end else if (ai >= 16'h03FB && ai <= 16'h03FD) begin
            // NMI trampoline: the ROM NMI vector ($FFFA/$FFFB) maps to $03FB
            // under this core's rom_addr = A[13:0] mapping.  Jump to the real
            // IIe NMI handler at $C3FA so the NMI pulse executes real ROM code.
            case (ai - 16'h03FB)
               0:       main_byte = 8'h4C;
               1:       main_byte = 8'hFA;
               default: main_byte = 8'hC3;
            endcase
         end else if (ai >= 16'h0540 && ai <= 16'h056E) begin
            main_byte = PHASE_B[ai - 16'h0540];
         end else if (ai >= 16'h0580 && ai <= 16'h0582) begin
            // Normal park: JMP $0580
            case (ai - 16'h0580)
               0:       main_byte = 8'h4C;
               1:       main_byte = 8'h80;
               default: main_byte = 8'h05;
            endcase
         end else if (ai >= 16'h05A0 && ai <= 16'h05A2) begin
            // Error park: JMP $05A0
            case (ai - 16'h05A0)
               0:       main_byte = 8'h4C;
               1:       main_byte = 8'hA0;
               default: main_byte = 8'h05;
            endcase
         end else begin
            main_byte = (a + (a >> 4) + 8'h3C);
         end
      end
   endfunction

   reg        clk_14m    = 1'b0;
   reg        flash_clk  = 1'b0;
   reg        reset      = 1'b1;
   reg        romswitch  = 1'b0;
   reg        cpu_wait   = 1'b0;
   reg        nmi_n      = 1'b1;
   reg        akd        = 1'b0;
   reg  [7:0] k          = 8'h00;
   reg  [7:0] gameport   = 8'h00;
   reg  [24:0] ioctl_addr     = 25'h000;
   reg  [7:0]  ioctl_data     = 8'h00;
   reg  [7:0]  ioctl_index    = 8'h00;
   reg         ioctl_download = 1'b0;
   reg         ioctl_wr       = 1'b0;

   wire [15:0] addr;
   wire [17:0] ram_addr;
   wire [7:0]  d;
   wire        ram_we;
   wire        cpu_we;
   wire        io_strobe;
   wire        speaker;
   wire [63:0] dbg_t65_regs;
   wire [7:0]  dbg_di;
   wire [13:0] dbg_rom_addr;
   wire [7:0]  dbg_rom_out;
   wire        video;
   wire        color_line;
   wire        text_mode;
   wire        hbl;
   wire        vbl;
   wire        phase_zero;
   wire        phase_zero_r;
   wire        phase_zero_f;
   wire        aux;
   wire        read_key;
   wire [3:0]  an;
   wire        pdl_strobe;
   wire        stb;
   wire [7:0]  io_select;
   wire [7:0]  device_select;
   wire        clk_2m;

   wire [15:0] ram_do;
   reg  [7:0]  pd     = 8'h00;

   apple2 dut (
      .CLK_14M(clk_14m),
      .CLK_2M(clk_2m),
      .PALMODE(1'b0),
      .ROMSWITCH(romswitch),
      .CPU_WAIT(cpu_wait),
      .PHASE_ZERO(phase_zero),
      .PHASE_ZERO_R(phase_zero_r),
      .PHASE_ZERO_F(phase_zero_f),
      .FLASH_CLK(flash_clk),
      .reset(reset),
      .cpu(1'b0),
      .ADDR(addr),
      .ram_addr(ram_addr),
      .D(d),
      .ram_do(ram_do),
      .aux(aux),
      .PD(pd),
      .CPU_WE(cpu_we),
      .IRQ_n(1'b1),
      .NMI_n(nmi_n),
      .ram_we(ram_we),
      .VIDEO(video),
      .COLOR_LINE(color_line),
      .TEXT_MODE(text_mode),
      .HBL(hbl),
      .VBL(vbl),
      .K(k),
      .READ_KEY(read_key),
      .AKD(akd),
      .AN(an),
      .GAMEPORT(gameport),
      .PDL_STROBE(pdl_strobe),
      .STB(stb),
      .IO_SELECT(io_select),
      .DEVICE_SELECT(device_select),
      .IO_STROBE(io_strobe),
      .ioctl_addr(ioctl_addr),
      .ioctl_data(ioctl_data),
      .ioctl_index(ioctl_index),
      .ioctl_download(ioctl_download),
      .ioctl_wr(ioctl_wr),
      .saturn_5_inslot(1'b0),
      .speaker(speaker),
      .DBG_T65_REGS(dbg_t65_regs),
      .DBG_DI(dbg_di),
      .DBG_ROM_ADDR(dbg_rom_addr),
      .DBG_ROM_OUT(dbg_rom_out)
   );

   always #5 clk_14m = ~clk_14m;

   // Stateless deterministic RAM.  The core latches CPU_DL from ram_do[7:0]
   // (MAIN) or ram_do[15:8] (AUX) depending on the aux routing flag, so both
   // banks are preloaded with the SAME image: once Phase A sets STORE80+PAGE2,
   // pages 04-07 (Phase B at $0540, parks at $0580/$05A0) and page-03 reads
   // with RAMRD=1 (NMI trampoline at $03FB) all come from the AUX half.
   assign ram_do[7:0]  = main_byte(addr);
   assign ram_do[15:8] = main_byte(addr);

   integer f;
   integer cycle;
   integer q;
   integer ai;

   initial begin
      // Column order must match apple2_vhdl_tb.vhd exactly.
      f = $fopen(TRACE_FILE);
      if (f == 0) begin
         $display("FATAL: cannot open %s", TRACE_FILE);
         $finish;
      end
      $fdisplay(f, "CYCLE,ADDR,D,RAM_ADDR,RAM_WE,AUX,CPU_WE,PD,IO_SELECT,DEVICE_SELECT,IO_STROBE,SPEAKER,VIDEO,PHASE_ZERO,PHASE_ZERO_R,PHASE_ZERO_F,ROMSWITCH,PALMODE,CPU_WAIT,NMI_N,T65_REGS,T65_DI,ROM_ADDR,ROM_OUT");

      for (cycle = 0; cycle < TOTAL; cycle++) begin
         @(negedge clk_14m);

         reset     = (cycle < RESET_CYCLES);
         romswitch = (cycle >= ROMSW_AT);
         cpu_wait  = (cycle >= WAIT_LO && cycle < WAIT_HI);
         nmi_n     = !(cycle >= NMI_LO && cycle < NMI_HI);
         akd       = (cycle >= AKD_LO && cycle < AKD_HI);
         flash_clk = ((cycle / FLASH_P) % 2);
         k         = {1'b0, 7'((cycle / 4) % 128)};
         gameport  = 8'h00;
         gameport = {1'b0, (((cycle / 16) ^ 16'h0055) & 8'h7F)};

         if (cycle >= IOCTL_LO && cycle < IOCTL_HI) begin
            q = (cycle - IOCTL_LO) / IOCTL_Q;
            ioctl_download = 1'b1;
            case (q % 4)
               0:       ioctl_data = 8'hDE;
               1:       ioctl_data = 8'hAD;
               2:       ioctl_data = 8'hBE;
               default: ioctl_data = 8'hEF;
            endcase
            ioctl_addr  = 25'h0F0 + q[7:0];
            ioctl_index = 8'h01;
            ioctl_wr    = 1'b1;
         end else begin
            ioctl_download = 1'b0;
            ioctl_wr       = 1'b0;
            ioctl_index    = 8'h00;
            ioctl_data     = 8'h00;
            ioctl_addr     = 25'h000;
         end

         // PD: C1xx slot = Phase A, all other slot reads = deterministic pattern.
         // NOTE: the core routes C1xx to ioselect[1] (ioselect[A[10:8]]), not bit 0.
         ai = addr;
         if (io_select[1] == 1'b1 && ai >= 16'hC100 && ai <= 16'hC1FF) begin
            pd = PHASE_A[ai - 16'hC100];
         end else begin
            pd = ((cycle / 3 + 7 * ai) % 256);
         end

         @(posedge clk_14m);
         #1;

         if ((cycle >= TRACE_START && cycle <= DENSE_END) ||
             (cycle >= NMI_TRACE_LO && cycle <= NMI_TRACE_HI) ||
             (cycle >= SPARSE_BASE && ((cycle - SPARSE_BASE) % 16 == 0))) begin
            $fdisplay(f, "%0d,%04h,%02h,%05h,%b,%b,%b,%02h,%02h,%02h,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%016h,%02h,%04h,%02h",
                      cycle, addr, d, ram_addr, ram_we, aux, cpu_we, pd,
                      io_select, device_select, io_strobe, speaker, video,
                      phase_zero, phase_zero_r, phase_zero_f, romswitch,
                      1'b0, cpu_wait, nmi_n, dbg_t65_regs, dbg_di, dbg_rom_addr, dbg_rom_out);
         end
      end

      $fclose(f);
      $finish;
   end

endmodule
