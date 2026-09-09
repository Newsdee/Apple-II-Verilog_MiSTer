// apple_composite.sv
// =====================================================================
// Apple II VIDEO (1-bit, 14.318 MHz) -> NTSC composite -> RGB.
//
// This core's VIDEO output is blanked during HBL: video_generator forces
// the shift register to 0xFF whenever WNDW_N (HBL|VBL) is high, so the raw
// bitstream contains NO sync pulse and NO color burst (measured: VIDEO is
// constant 0 for the entire 352-cycle HBL span, every line). A physical
// Apple II would put both in the waveform; here the encoder synthesizes
// them from the timing signals the wrapper already derives for the
// video_mixer (native_hsync/native_vsync from HBL/VBL):
//
//   * sync level: the hs pulse drives the comp waveform to the NTSC sync
//     tip (-40 IRE, the same 0.286 V amplitude as the burst). The vs flag
//     does NOT force the tip on the vsync lines: this decoder takes vs as a
//     flag (it never reads the sync tip) and re-locks its burst vector and
//     black clamp from the back porch of EVERY line. Suppressing the burst
//     on the vsync lines leaves the first line after the vs block with a
//     ~57% burst vector (3x chroma) and a stale black level, which shows up
//     as a 1-line luma/chroma transient at the top of every field. Vsync
//     lines therefore carry the normal burst + blank porch + the real video
//     (the first visible row on this core); the decoder's vs_out flags them
//     for the downstream blanking.
//   * color burst: a full-rate +/-20 IRE square wave (2-sample period,
//     4 samples per subcarrier cycle, SPC=4) generated inside a fixed
//     window after the hs fall. The window sits in the back porch, and
//     the line (912 cycles = 228 subcarrier cycles) is a whole number of
//     subcarrier cycles, so the free-running phase is column-stable.
//
// Luma is the raw VIDEO bit: 1 -> +70 IRE white, 0 -> black. No averaging
// or boxcar on the encoder side; composite is the machine's native output
// and 1-bit video has no color to pre-multiply. (No 7.5 IRE setup: this
// machine's picture is 0/70 IRE only.)
//
// The decoder is mister's composite_decoder (SPC=4). Its burst-measurement
// and black-clamp windows are anchored at the same hcnt counter semantics
// (hcnt = samples since the hs fall), and both get the same
// burst_start/burst_len, so the generated burst lands exactly where the
// decoder looks for it.
//
// Geometry measured on this core (tb_burst_probe, 2026-09-10):
//   line        912 cycles  (352 HBL + 560 active)
//   hs pulse    hblank_cnt 130..197 (68 cycles, hs fall at 198)
//   back porch  hblank_cnt 199..351 (VIDEO constant 0 here)
//   constraints for the decoder (SPC=4, BURST_ACC=16, CLAMP_ACC=16):
//     burst_start + 16 <= 153            (measurement fits in HBL)
//     burst_start + burst_len + 16 <= 153 (clamp fits in the back porch)
//   chosen: burst_start=8, burst_len=64  (generated burst at hblank_cnt
//   207..270, clamp at 271..286)
// =====================================================================

`default_nettype none

module apple_composite #(
  // Burst window, in hcnt units (samples after the hs fall). Must satisfy
  // the decoder constraints noted above; tunable if the decoder changes.
  parameter BURST_START = 8,
  parameter BURST_LEN   = 64
)(
  input  wire        clk,        // 14.318 MHz, one composite sample per edge
  input  wire        ce,         // sample valid (1 here; kept for reuse)
  input  wire        video,      // raw 1-bit Apple VIDEO
  input  wire        hs, vs,     // positive sync pulses, sample domain
  input  wire        hb, vb,     // blanking, sample domain
  input  wire [7:0]  sat,        // 128 = unity
  input  wire [7:0]  hue,        // 256 = one full cycle
  input  wire [7:0]  bright,     // signed luma offset, 0 = none
  input  wire [7:0]  contrast,   // mid-gray-centred gain, 128 = unity
  output wire [7:0]  r, g, b,
  output wire        ce_out, hs_out, vs_out, hb_out, vb_out,
  // Modulated sample stream (Q2.21 volts, 1 V = 2^21), one sample per ce
  // pulse.  Exposed for the FPGA path: video_mixer_plus' composite branch
  // decodes this stream.  The loopback r/g/b above stay for the TBs.
  output wire signed [23:0] comp_sample
);

  // ------------------------------------------------------------------
  // Encoder levels, Q2.21 (1.0 V = 2^21 = 20 IRE)
  // ------------------------------------------------------------------
  localparam signed [23:0] V_SYNC  = -24'sd599186;  // -40 IRE (0.286 V)
  localparam signed [23:0] V_BLANK =  24'sd0;       // 0 IRE
  localparam signed [23:0] V_BLACK =  24'sd0;       // 0 IRE
  localparam signed [23:0] V_WHITE =  24'sd1497380; // +70 IRE (0.713 V)
  localparam signed [23:0] V_BURST =  24'sd299892;  // +/-20 IRE (0.286 V p-p)

  // ------------------------------------------------------------------
  // Burst window counter - same semantics as composite_decoder's hcnt:
  // samples since the hs fall. (hb is not needed: the window fits the
  // back porch, which lies inside hb.)
  // ------------------------------------------------------------------
  localparam [9:0] BS = BURST_START[9:0];
  localparam [9:0] BL = BURST_LEN[9:0];

  reg        hs_d;
  reg [9:0]  hcnt;
  always @(posedge clk) begin
    if (ce) begin
      hs_d <= hs;
      if (hs_d && ~hs) hcnt <= 10'd0;
      else if (~&hcnt) hcnt <= hcnt + 10'd1;
    end
  end

  wire in_burst = (hcnt >= BS) && (hcnt < BS + BL);

  // ------------------------------------------------------------------
  // Generated burst: the subcarrier square wave. SPC=4 means four samples
  // per subcarrier cycle, so the burst is two samples high and two low
  // (a period-4-samples / 2-clock-cycle waveform). A period-2 waveform
  // would sit at 2*fsc and the decoder's notch would reject it.
  // Free-running; the line length is a whole number of subcarrier cycles
  // (912 = 4 * 228) so its phase relative to the active video is identical
  // on every line.
  // ------------------------------------------------------------------
  logic [1:0] burst_cnt;
  always @(posedge clk)
    if (ce) burst_cnt <= burst_cnt + 2'd1;

  wire burst_phase = burst_cnt[1];   // two samples high, two samples low

  // ------------------------------------------------------------------
  // Composite sample
  //
  // vs is deliberately NOT part of the sync-tip condition: see the note in
  // the header. The decoder re-locks burst + black clamp per line and needs
  // both alive on the vsync lines; vs still passes through to vs_out.
  // ------------------------------------------------------------------
  logic signed [23:0] comp;
  assign comp = hs
                     ? V_SYNC
                    : (hb && in_burst)
                     ? (burst_phase ? V_BURST : -V_BURST)
                    : (hb)
                     ? V_BLANK
                     : (video ? V_WHITE : V_BLACK);

  // ------------------------------------------------------------------
  // Decoder
  // ------------------------------------------------------------------
  assign comp_sample = comp;
  wire [7:0] r_i, g_i, b_i;
  composite_decoder #(.SPC(4)) u_dec (
    .clk         (clk),
    .ce          (ce),
    .comp        (comp),
    .hs_in       (hs),
    .vs_in       (vs),
    .hb_in       (hb),
    .vb_in       (vb),
    .burst_start (BS),
    .burst_len   (BL),
    .sat         (sat),
    .hue         (hue),
    .bright      (bright),
    .contrast    (contrast),
    .smear       (4'd0),
    .luma_delay  (4'd0),
    .setup       (16'sd0),
    .luma_gain   (16'sd2857),
    .agc_en      (1'b1),
    .ce_out      (ce_out),
    .hs_out      (hs_out),
    .vs_out      (vs_out),
    .hb_out      (hb_out),
    .vb_out      (vb_out),
    .r_out       (r_i),
    .g_out       (g_i),
    .b_out       (b_i)
  );

  assign r = r_i;
  assign g = g_i;
  assign b = b_i;

endmodule

`default_nettype wire
