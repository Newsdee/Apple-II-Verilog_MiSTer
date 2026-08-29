// timing_generator_verilog_tb.sv
//
// Cycle-equivalence testbench (candidate side) for the Verilog
// timing_generator. The golden side is timing_generator_vhdl_tb.vhd with the
// IDENTICAL stimulus schedule and CSV schema.
//
// PHASE parameter: 0 = NTSC (PALMODE=0), 1 = PAL (PALMODE=1). The runner
// builds/runs both phases; see the VHDL TB header for the machine model
// (power-on zero state, HAL self-start, V wrap at 511 -> V_RESET 126/104).
//
// Stimulus (driven at the falling edge of cycle N, identical on both sides):
//   PALMODE     = PHASE (constant for the run)
//   TEXT_MODE   = (N / 100000) mod 2
//   PAGE2       = (N / 50000)  mod 2
//   HIRES_MODE  = (N / 20000)  mod 2
//   MIXED_MODE  = (N / 15000)  mod 2
//   COL80       = (N / 8000)   mod 2
//   STORE80     = (N / 6000)   mod 2
//   DHIRES_MODE = (N / 4000)   mod 2
//   VID7        = (N / 2000)   mod 2
//
// Trace (sampled at rising edge + 1 ns): every cycle for N < 2000, then
// every 32nd cycle. Columns:
//   CYCLE, PHI0, Q3, RAS_N, AX, CAS_N, VID7M, COLOR_REF, PHI0_EN_R,
//   PHI0_EN_F, HBLANK, VBLANK, WNDW_N, LDPS_N, GR1, GR2, SEGA, SEGB,
//   SEGC, VIDEO_ADDRESS

`timescale 1ns/1ps

module timing_generator_verilog_tb;

   parameter PHASE = 0;  // 0 = NTSC, 1 = PAL

   localparam integer TOTAL = 800000;
   localparam string TRACE_FILE = (PHASE == 0) ?
      "module_tests/timing_generator/build/verilog_ntsc.csv" :
      "module_tests/timing_generator/build/verilog_pal.csv";

   reg         clk_14m    = 1'b0;
   reg         palmode    = (PHASE == 1);
   reg         text_mode  = 1'b0;
   reg         page2      = 1'b0;
   reg         hires_mode = 1'b0;
   reg         mixed_mode = 1'b0;
   reg         col80      = 1'b0;
   reg         store80    = 1'b0;
   reg         dhires     = 1'b0;
   reg         vid7       = 1'b0;
   wire        vid7m;
   wire        q3;
   wire        ras_n;
   wire        cas_n;
   wire        ax;
   wire        phi0;
   wire        phi0_en_r;
   wire        phi0_en_f;
   wire        color_ref;
   wire [15:0] video_addr;
   wire        sega;
   wire        segb;
   wire        segc;
   wire        gr1;
   wire        gr2;
   wire        hblank;
   wire        vblank;
   wire        wndw_n;
   wire        ldps_n;

   timing_generator dut (
      .CLK_14M(clk_14m),
      .PALMODE(palmode),
      .VID7M(vid7m),
      .Q3(q3),
      .RAS_N(ras_n),
      .CAS_N(cas_n),
      .AX(ax),
      .PHI0(phi0),
      .PHI0_EN_R(phi0_en_r),
      .PHI0_EN_F(phi0_en_f),
      .COLOR_REF(color_ref),
      .TEXT_MODE(text_mode),
      .PAGE2(page2),
      .HIRES_MODE(hires_mode),
      .MIXED_MODE(mixed_mode),
      .COL80(col80),
      .STORE80(store80),
      .DHIRES_MODE(dhires),
      .VID7(vid7),
      .VIDEO_ADDRESS(video_addr),
      .SEGA(sega),
      .SEGB(segb),
      .SEGC(segc),
      .GR1(gr1),
      .GR2(gr2),
      .HBLANK(hblank),
      .VBLANK(vblank),
      .WNDW_N(wndw_n),
      .LDPS_N(ldps_n)
   );

   always #5 clk_14m = ~clk_14m;

   integer f;
   integer cycle;

   initial begin
      f = $fopen(TRACE_FILE);
      if (f == 0) begin
         $display("FATAL: cannot open %s", TRACE_FILE);
         $finish;
      end
      $fdisplay(f, "CYCLE,PHI0,Q3,RAS_N,AX,CAS_N,VID7M,COLOR_REF,PHI0_EN_R,PHI0_EN_F,HBLANK,VBLANK,WNDW_N,LDPS_N,GR1,GR2,SEGA,SEGB,SEGC,VIDEO_ADDRESS");

      for (cycle = 0; cycle < TOTAL; cycle++) begin
         @(negedge clk_14m);

         text_mode  = (cycle / 100000) % 2;
         page2      = (cycle / 50000) % 2;
         hires_mode = (cycle / 20000) % 2;
         mixed_mode = (cycle / 15000) % 2;
         col80      = (cycle / 8000) % 2;
         store80    = (cycle / 6000) % 2;
         dhires     = (cycle / 4000) % 2;
         vid7       = (cycle / 2000) % 2;

         @(posedge clk_14m);
         #1;

         if (cycle < 2000 || cycle % 32 == 0) begin
            $fdisplay(f, "%0d,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%b,%04h",
                      cycle, phi0, q3, ras_n, ax, cas_n, vid7m, color_ref,
                      phi0_en_r, phi0_en_f, hblank, vblank, wndw_n, ldps_n,
                      gr1, gr2, sega, segb, segc, video_addr);
         end
      end

      $fclose(f);
      $finish;
   end

endmodule
