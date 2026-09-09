// =====================================================================
// ntsc_vertical_blend.sv
// =====================================================================
// 2-line vertical comb for the composite decode path (level_2).
//
// Faithful ce-strobed port of the main-branch core's "NTSC vertical
// blend" (Apple-II_MiSTer rtl/vga_controller.v, NTSC_VERTICAL_COMB):
// keep the current line's luma, average the chroma of the current and
// previous line.  NTSC's subcarrier (and the 1-bit artifact colour it
// produces) flips phase line to line, so averaging two lines' chroma
// cancels much of the decorrelated cross-colour while leaving
// brightness untouched.
//
// Domain: runs on CLK_VIDEO, strobed by `ce` = one decoded pixel
// (the composite branch's pixel rate, 14.318 MHz = CLK_VIDEO/4).
// Every "pixel cycle" of the vga_controller original is one `ce` step
// here; all pipeline stages update on ce only.
//
// Latency/alignment: when blend_en=1, the RGB AND all four
// sync/blank flags pass through the same 2-ce pipeline (stage-1 delay
// + stage-2 filter register), so pixel<->sync alignment is preserved
// (the main branch does the same with current_rgb_q/filtered_rgb and
// the matched timing_active pipeline).  When blend_en=0 the module is
// a zero-latency combinational bypass: output = input, byte-identical
// to the unblended composite path.
//
// The one-line buffer (LINE_LEN x 24 bits) is maintained continuously
// (independent of blend_en) so the knob can be toggled live.  The
// buffer write is deferred one ce (the vga_controller's line_wr_en
// trick) so a read of address x on line N+1 never aliases the write of
// address x on line N+1 in the same cycle.
//
// Deviations from the main branch (see NTSC_VERTICAL_BLEND_PLAN.md):
//   * no colour-mode gate term: the level_2 machine exposes no
//     SCREEN_MODE and the composite branch is its only colour path;
//     the gate here is blend_en && active && line_valid.
//   * LINE_LEN is a parameter (560 = the level_2 active width; the
//     main branch hardwires 560 too).  hcount is 10 bits: LINE_LEN
//     must cover the active width and the active width must be < 1024.
// =====================================================================

`default_nettype none

module ntsc_vertical_blend #(
	parameter LINE_LEN = 560
)(
	input             clk,       // CLK_VIDEO
	input             ce,        // one decoded pixel (composite branch)
	input             blend_en,  // OSD "NTSC vertical blend"

	// Decoder outputs, pixel-aligned (same LAT pipeline in the decoder).
	input      [7:0]  r_in, g_in, b_in,
	input             hb_in, vb_in, hs_in, vs_in,

	// 2-ce delayed (blend_en) or direct (bypass) outputs.
	output     [7:0]  r_out, g_out, b_out,
	output            hb_out, vb_out, hs_out, vs_out
);

localparam HC_W = 10;

wire active = ~hb_in;

// ------------------------------------------------------------------
// One-line RGB buffer (previous line, same column) + line bookkeeping.
// Structure mirrors vga_controller.v's vertical_line_buffer, with
// "cycle" replaced by "ce step".
// ------------------------------------------------------------------
reg [23:0] line_ram    [0:LINE_LEN-1];
reg [HC_W-1:0] hcount       = {HC_W{1'b0}}; // active pixel index
reg [HC_W-1:0] wr_addr      = {HC_W{1'b0}};
reg [23:0]   wr_data        = 24'd0;
reg          wr_en          = 1'b0;
reg [23:0]   prev_rgb_q     = 24'd0; // previous line, same column
reg [23:0]   cur_rgb_q      = 24'd0; // current line (1 ce of pipeline)
reg          cur_active_q   = 1'b0;
reg          cur_vb_q       = 1'b0;
reg          cur_hs_q       = 1'b0;
reg          cur_vs_q       = 1'b0;
reg          prev_valid     = 1'b0; // last line was a real (non-VBL) line
reg          line_valid_q   = 1'b0; // buffer holds a usable previous line
reg          active_d       = 1'b0;

always @(posedge clk) if (ce) begin
	cur_rgb_q    <= {r_in, g_in, b_in};
	cur_active_q <= active;
	cur_vb_q     <= vb_in;
	cur_hs_q     <= hs_in;
	cur_vs_q     <= vs_in;
	wr_en        <= 1'b0;
	active_d     <= active;
	line_valid_q <= prev_valid;
	if (vb_in) begin
		prev_valid   <= 1'b0;
		line_valid_q <= 1'b0;
		hcount       <= {HC_W{1'b0}};
	end else if (active) begin
		prev_rgb_q <= line_ram[hcount];
		wr_addr    <= hcount;
		wr_data    <= {r_in, g_in, b_in};
		wr_en      <= 1'b1;
		hcount     <= hcount + 1'b1;
	end else if (active_d) begin
		prev_valid <= 1'b1;
		hcount     <= {HC_W{1'b0}};
	end
	if (wr_en) line_ram[wr_addr] <= wr_data;
end

// ------------------------------------------------------------------
// The filter: JS-style 2-line vertical comb.  Verbatim port of
// vga_controller.v's vertical_comb_filter (integer arithmetic,
// +512/1024 luma rounding, truncating /2 chroma, clamp_rgb).
// ------------------------------------------------------------------
function [7:0] clamp_rgb;
	input integer value;
	begin
		if (value < 0)        clamp_rgb = 8'h00;
		else if (value > 255) clamp_rgb = 8'hFF;
		else                  clamp_rgb = value[7:0];
	end
endfunction

always @(posedge clk) if (ce) begin
	integer current_luma, previous_luma;
	integer current_red,  current_green,  current_blue;
	integer previous_red, previous_green, previous_blue;
	integer red_chroma, green_chroma, blue_chroma;
	reg   [23:0] output_rgb;

	output_rgb = cur_rgb_q;
	if (blend_en && cur_active_q && line_valid_q) begin
		current_red   = cur_rgb_q[23:16];
		current_green = cur_rgb_q[15:8];
		current_blue  = cur_rgb_q[7:0];
		previous_red   = prev_rgb_q[23:16];
		previous_green = prev_rgb_q[15:8];
		previous_blue  = prev_rgb_q[7:0];
		current_luma  = (306 * current_red + 601 * current_green +
						117 * current_blue + 512) / 1024;
		previous_luma = (306 * previous_red + 601 * previous_green +
						117 * previous_blue + 512) / 1024;
		red_chroma   = (current_red - current_luma +
						previous_red - previous_luma) / 2;
		green_chroma = (current_green - current_luma +
						previous_green - previous_luma) / 2;
		blue_chroma  = (current_blue - current_luma +
						previous_blue - previous_luma) / 2;
		output_rgb = {clamp_rgb(current_luma + red_chroma),
					 clamp_rgb(current_luma + green_chroma),
					 clamp_rgb(current_luma + blue_chroma)};
	end

	out_rgb <= output_rgb;
	out_hb  <= ~cur_active_q;
	out_vb  <= cur_vb_q;
	out_hs  <= cur_hs_q;
	out_vs  <= cur_vs_q;
end

reg [23:0] out_rgb = 24'd0;
reg        out_hb  = 1'b0;
reg        out_vb  = 1'b0;
reg        out_hs  = 1'b0;
reg        out_vs  = 1'b0;

// Bypass: zero latency when the knob is off (byte-identical path).
assign r_out  = blend_en ? out_rgb[23:16] : r_in;
assign g_out  = blend_en ? out_rgb[15:8]  : g_in;
assign b_out  = blend_en ? out_rgb[7:0]   : b_in;
assign hb_out = blend_en ? out_hb : hb_in;
assign vb_out = blend_en ? out_vb : vb_in;
assign hs_out = blend_en ? out_hs : hs_in;
assign vs_out = blend_en ? out_vs : vs_in;

endmodule
