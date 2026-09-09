// =====================================================================
// tb_vblend.sv
// =====================================================================
// Unit testbench for ntsc_vertical_blend.sv (2-line vertical comb for
// the level_2 composite decode path).  Self-driving, ce=1 every cycle
// (one pixel per clk - the module only acts on ce edges, so this
// exercises the full ce pipeline with minimal timing complexity).
//
// Geometry (matches the level_2 machine: 912 machine cycles/line):
//   HBL 352 (HS pulse at [130,198)), active 560, VBL 3 lines.
//
// Checks (see NTSC_VERTICAL_BLEND_PLAN.md section 4).  When blend_en=1
// the module adds the main-branch 2-cycle pipeline: the output at ce
// step j is computed from the input at ce step j-2 (stage-1 + stage-2
// register pair).  With blend_en=0 it is a zero-latency bypass.
//
//   P1  blend_en=0: zero-latency bypass - out == in sample-for-sample
//       (RGB and hb), all lines.
//   P2  blend_en=1:
//       a. first line after VBL: unfiltered (line_valid_q=0) but still
//          through the 2-stage pipeline -> out[i] = in[i-2];
//       b. following lines: per-sample exact match against an oracle
//          that recomputes the MAIN-BRANCH formula (integer luma
//          +512/1024, truncating /2 chroma, clamp) with the previous
//          line's SAME-COLUMN pixel (catches hcount/RAM off-by-one);
//       c. (removed 2026-09-10) luma preservation |luma(out) -
//          luma(in[i-2])| <= 3 is NOT a valid invariant here: the exact
//          formula preserves luma only WITHOUT clamping, and the
//          extreme cur/prev luma gaps in these patterns (pure blue
//          vs pure red: luma 29 vs 76) make the per-channel clamps
//          move the output luma by more than any fixed window.  The
//          exact-match oracle (b) is the strong net.
//       d. sync alignment: per-ce check that hb/vb/vs_out track the
//          input by exactly the same 2-ce delay, plus exact counts
//          over the phase (hs 8 x 68, vs 3 full lines, hb low
//          5 x 560 - 2: the 2-ce shift moves the last counted
//          line's blank window 2 ce past the counted span).
// =====================================================================
`timescale 1ns / 1ps

`default_nettype none

module tb_vblend;

localparam HBL    = 352;
localparam ACT    = 560;
localparam LINE   = HBL + ACT;   // 912
localparam VBL_N  = 3;
localparam HS_ST  = 130;
localparam HS_EN  = 198;

reg clk = 1'b0;
reg blend_en = 1'b0;

reg  [7:0] r_in, g_in, b_in;
reg        hb_in, vb_in, hs_in, vs_in;
wire [7:0] r_out, g_out, b_out;
wire       hb_out, vb_out, hs_out, vs_out;

ntsc_vertical_blend #(.LINE_LEN(560)) dut (
	.clk      (clk),
	.ce       (1'b1),
	.blend_en (blend_en),
	.r_in     (r_in),
	.g_in     (g_in),
	.b_in     (b_in),
	.hb_in    (hb_in),
	.vb_in    (vb_in),
	.hs_in    (hs_in),
	.vs_in    (vs_in),
	.r_out    (r_out),
	.g_out    (g_out),
	.b_out    (b_out),
	.hb_out   (hb_out),
	.vb_out   (vb_out),
	.hs_out   (hs_out),
	.vs_out   (vs_out)
);

always #5 clk = ~clk;

// --------------------------------------------------------------------
// Oracles (verbatim port of the main-branch vga_controller formula).
// --------------------------------------------------------------------
function [7:0] clampi;
	input integer v;
	begin
		if (v < 0)        clampi = 8'h00;
		else if (v > 255) clampi = 8'hFF;
		else              clampi = v[7:0];
	end
endfunction

function [23:0] oracle_blend;
	input [7:0] cr, cg, cb;   // current line pixel
	input [7:0] pr, pg, pb;   // previous line, same column
	integer icr, icg, icb, ipr, ipg, ipb;
	integer cl, pl, rc, gc, bc;
	begin
		// NOTE: channel bytes go to signed integers BEFORE the
		// multiplications.  A raw `306 * cr` is self-determined at
		// max(9,8)=9 bits and the product truncates (TB width bug
		// found 2026-09-10: the oracle came out wrong while the DUT
		// was sample-exact).  The DUT sizes these explicitly.
		icr = cr; icg = cg; icb = cb;
		ipr = pr; ipg = pg; ipb = pb;
		cl = (306 * icr + 601 * icg + 117 * icb + 512) / 1024;
		pl = (306 * ipr + 601 * ipg + 117 * ipb + 512) / 1024;
		rc = (icr - cl + ipr - pl) / 2;
		gc = (icg - cl + ipg - pl) / 2;
		bc = (icb - cl + ipb - pl) / 2;
		oracle_blend = {clampi(cl + rc), clampi(cl + gc), clampi(cl + bc)};
	end
endfunction

function integer luma8;
	input [23:0] rgb;
	integer r, g, b;
	begin
		r = rgb[23:16]; g = rgb[15:8]; b = rgb[7:0];
		luma8 = (306 * r + 601 * g + 117 * b + 512) / 1024;
	end
endfunction

// Line patterns: 0=black 1=red 2=blue 3=per-column ramp 4=column split
// (red for col<280, black otherwise - alignment boundary probe).
// NOTE: the ramp bytes go through 8-bit regs assigned in separate
// statements, then concatenated.  Verilator 5.050 miscompiles a
// part-select of a 32-bit value in the LEADING slot of a concatenation
// when a sibling element is wider than 8 bits (the MSB byte comes out
// zero; the (ui+128)&8'hFF element is 32 bits, which bloats the
// concatenation to 48 bits and drops the leading part-select).  The
// signed `i` form and the unsigned `ui` form both fail; the part-select
// in the trailing slot works - so this is leading-slot-specific.
// Verified 2026-09-10 with probe2/probe3 (C:/Users/newsdee/AppData/Local/
// Temp/probe1).
function [23:0] patfn;
	input [1:0] pat;
	input integer i;
	reg [31:0] ui;
	reg [7:0] pb0, pb1, pb2;
	begin
		ui = i;
		case (pat)
			2'd0   : patfn = 24'd0;
			2'd1   : patfn = 24'hFF0000;
			2'd2   : patfn = 24'h0000FF;
			2'd3   : begin
				pb0 = ui[7:0];
				pb1 = (ui + 128) & 8'hFF;
				pb2 = ui[8:1];
				patfn = {pb0, pb1, pb2};
			end
			default: patfn = (i < 280) ? 24'hFF0000 : 24'd0;
		endcase
	end
endfunction

function [23:0] oracle2;
	// expected filtered output pixel for current pattern `pat` at
	// index i-2 against previous-line pattern `prev` at index i-2
	// (the module's 2-ce pipeline delay, see header).
	input [1:0] pat;
	input [1:0] prev;
	input integer i;
	reg [23:0] c, p;
	begin
		c = patfn(pat, i - 2);
		p = patfn(prev, i - 2);
		oracle2 = oracle_blend(c[23:16], c[15:8], c[7:0],
					p[23:16], p[15:8], p[7:0]);
	end
endfunction

// --------------------------------------------------------------------
// Error accounting
// --------------------------------------------------------------------
integer fails = 0;
integer line_no = 0;
reg [23:0] in_rgb = 0;

// 1-ce / 2-ce delayed copies of the input, matching the DUT pipeline:
// when blend_en=1, the output at ce step j reflects the input applied
// at ce step j-2 (stage-1 + stage-2 register pair).  With blend_en=0
// the DUT is a zero-latency combinational bypass (out == in at the
// same ce).
reg [23:0] in_d1 = 24'd0;
reg [23:0] in_d2 = 24'd0;
reg        hb_d1 = 1'b1;
reg        hb_d2 = 1'b1;
reg        vs_d1 = 1'b1;
reg        vs_d2 = 1'b1;
reg        vb_d1 = 1'b1;
reg        vb_d2 = 1'b1;

task automatic failchk;
	input [255:0] what;
	input integer idx;
	begin
		fails = fails + 1;
		$display("FAIL %0d: %s @ line=%0d sample=%0d blend_en=%b in=%0h out=%0h",
				fails, what, line_no, idx, blend_en, in_rgb,
				{r_out, g_out, b_out});
		// first failure on a line: dump the DUT pipeline internals so
		// the effective (cur, prev) pair is visible.
		if (!dbg_done && (what == "filter px" || what == "unfiltered px")) begin
			dbg_done = 1;
			$display("  DBG line=%0d i=%0d: cur_q=%0h prev_q=%0h lv=%b caq=%b hc=%0d",
					line_no, idx, dut.cur_rgb_q, dut.prev_rgb_q,
					dut.line_valid_q, dut.cur_active_q, dut.hcount);
			$display("  DBG out=%0h in(i)=%0h",
					{r_out, g_out, b_out}, in_rgb);
		end
	end
endtask

reg dbg_done = 1;

// --------------------------------------------------------------------
// Line driver + checker.
//   mode 0 = bypass check (blend_en=0): out == in, zero delay.
//   mode 1 = unfiltered check (blend_en=1, line_valid_q=0):
//            out[i] = in[i-2] (pipeline delay only, 2 ce).
//   mode 2 = filtered check (blend_en=1): out[i] = oracle2(i),
//            plus luma preservation against in[i-2].
//   In blend_en=1 the blanking/sync outputs must track the input by
//   exactly the same 2-ce delay (checked per ce in both loops).
// --------------------------------------------------------------------
integer cnt_hs_out, cnt_hb_lo, cnt_vs_out;

task automatic run_line;
	input [1:0] pat;
	input [1:0] vbl;
	input [1:0] mode;
	input [1:0] prev_pat;
	integer i;
	reg [23:0] exp;
	begin
		line_no = line_no + 1;
		for (i = 0; i < HBL; i = i + 1) begin
			@(negedge clk);
			vb_in = vbl;
			hs_in = (i >= HS_ST && i < HS_EN);
			hb_in = 1'b1;
			vs_in = vbl;
			{r_in, g_in, b_in} = 24'd0;
			in_rgb = 24'd0;
			#1;   // settle the DUT combinational path before sampling
			if (hs_out) cnt_hs_out = cnt_hs_out + 1;
			if (!hb_out) cnt_hb_lo = cnt_hb_lo + 1;
			if (vs_out) cnt_vs_out = cnt_vs_out + 1;
			if (blend_en) begin
				if (hb_out !== hb_d2) failchk("shift hb", i);
				if (vs_out !== vs_d2) failchk("shift vs", i);
				if (vb_out !== vb_d2) failchk("shift vb", i);
			end
			{in_d2, hb_d2, vs_d2, vb_d2} = {in_d1, hb_d1, vs_d1, vb_d1};
			in_d1 = 24'd0;
			hb_d1 = 1'b1;
			vs_d1 = vbl;
			vb_d1 = vbl;
		end
		for (i = 0; i < ACT; i = i + 1) begin
			@(negedge clk);
			vb_in = vbl;
			hs_in = 1'b0;
			hb_in = vbl;
			vs_in = vbl;
			{r_in, g_in, b_in} = vbl ? 24'd0 : patfn(pat, i);
			in_rgb = vbl ? 24'd0 : patfn(pat, i);
			#1;   // settle the DUT combinational path before sampling
			if (hs_out) cnt_hs_out = cnt_hs_out + 1;
			if (!hb_out) cnt_hb_lo = cnt_hb_lo + 1;
			if (vs_out) cnt_vs_out = cnt_vs_out + 1;
			if (blend_en) begin
				if (hb_out !== hb_d2) failchk("shift hb", i);
				if (vs_out !== vs_d2) failchk("shift vs", i);
				if (vb_out !== vb_d2) failchk("shift vb", i);
			end
			if (vbl) begin
				if (hb_out !== 1'b1)
					failchk("vbl hb", i);
			end else if (mode == 0) begin
				if ({r_out, g_out, b_out} !== in_rgb)
					failchk("bypass px", i);
				if (hb_out !== 1'b0)
					failchk("bypass hb", i);
			end else if (mode == 1) begin
				exp = (i < 2) ? 24'd0 : patfn(pat, i - 2);
				if ({r_out, g_out, b_out} !== exp)
					failchk("unfiltered px", i);
				if (hb_out !== ((i < 2) ? 1'b1 : 1'b0))
					failchk("unfiltered hb", i);
			end else begin
				if (i < 2) begin
					if ({r_out, g_out, b_out} !== 24'd0)
						failchk("filter px0", i);
				end else begin
					exp = oracle2(pat, prev_pat, i);
					if ({r_out, g_out, b_out} !== exp)
						failchk("filter px", i);
					// NB: no luma window check - clamping with extreme
					// cur/prev luma gaps moves luma beyond any fixed
					// window (see header note c).  Exact match above is
					// the strong net.
				end
				if (hb_out !== ((i < 2) ? 1'b1 : 1'b0))
					failchk("filter hb", i);
			end
			{in_d2, hb_d2, vs_d2, vb_d2} = {in_d1, hb_d1, vs_d1, vb_d1};
			in_d1 = vbl ? 24'd0 : patfn(pat, i);
			hb_d1 = vbl;
			vs_d1 = vbl;
			vb_d1 = vbl;
		end
	end
endtask

// --------------------------------------------------------------------
// Sequence
// --------------------------------------------------------------------
initial begin
	// ---------------- Phase 1: blend_en=0 (bypass) ----------------
	blend_en = 1'b0;
	cnt_hs_out = 0; cnt_hb_lo = 0; cnt_vs_out = 0;
	dbg_done = 1;
	run_line(2'd0, 1'b1, 0, 2'd0);  // VBL
	run_line(2'd0, 1'b1, 0, 2'd0);
	run_line(2'd0, 1'b1, 0, 2'd0);
	run_line(2'd1, 1'b0, 0, 2'd0);  // red
	run_line(2'd3, 1'b0, 0, 2'd0);  // ramp
	run_line(2'd4, 1'b0, 0, 2'd0);  // split
	// zero delay: 3 active lines x 560 exact, hs 6 x 68, vs 3 lines
	if (cnt_hb_lo !== 3 * ACT) begin
		fails = fails + 1;
		$display("FAIL: P1 hb_low count %0d != %0d", cnt_hb_lo, 3 * ACT);
	end
	if (cnt_hs_out !== 6 * (HS_EN - HS_ST)) begin
		fails = fails + 1;
		$display("FAIL: P1 hs count %0d != %0d",
				cnt_hs_out, 6 * (HS_EN - HS_ST));
	end
	if (cnt_vs_out !== 3 * LINE) begin
		fails = fails + 1;
		$display("FAIL: P1 vs count %0d != %0d", cnt_vs_out, 3 * LINE);
	end
	$display("P1 bypass done (fails so far: %0d)", fails);

	// ---------------- Phase 2: blend_en=1 ----------------
	blend_en = 1'b1;
	cnt_hs_out = 0; cnt_hb_lo = 0; cnt_vs_out = 0;
	dbg_done = 0;
	run_line(2'd0, 1'b1, 0, 2'd0);  // VBL x3 (clear line_valid_q)
	run_line(2'd0, 1'b1, 0, 2'd0);
	run_line(2'd0, 1'b1, 0, 2'd0);
	run_line(2'd1, 1'b0, 1, 2'd0);  // first line after VBL: unfiltered
	run_line(2'd2, 1'b0, 2, 2'd1);  // blue vs red    -> (104,0,104)
	run_line(2'd1, 1'b0, 2, 2'd2);  // red vs blue    -> (151,24,151)
	run_line(2'd3, 1'b0, 2, 2'd1);  // ramp vs red    (per-column oracle)
	run_line(2'd4, 1'b0, 2, 2'd3);  // split vs ramp  (boundary probe)
	// 8 lines: hs 8 x 68 exact; vs = 3 full lines (a pure 2-ce delay
	// keeps the pulse count, and the 8-line window contains both
	// edges of the delayed pulse); hb low = exactly 5 x 560: the 2-ce
	// shift moves the last counted line's blank window 2 ce past the
	// counted span (-2) and those 2 steps are exactly cancelled by
	// the +2 carry-over of P1's last active line into the first 2 HBL
	// steps of this phase (the pipeline is continuous across phases).
	if (cnt_hb_lo !== 5 * ACT) begin
		fails = fails + 1;
		$display("FAIL: P2 hb_low count %0d != %0d",
				cnt_hb_lo, 5 * ACT);
	end
	if (cnt_hs_out !== 8 * (HS_EN - HS_ST)) begin
		fails = fails + 1;
		$display("FAIL: P2 hs count %0d != %0d",
				cnt_hs_out, 8 * (HS_EN - HS_ST));
	end
	if (cnt_vs_out !== 3 * LINE) begin
		fails = fails + 1;
		$display("FAIL: P2 vs count %0d != %0d", cnt_vs_out, 3 * LINE);
	end
	$display("P2 filter done (fails so far: %0d)", fails);

	// ---------------- verdict ----------------
	if (fails == 0)
		$display("tb_vblend PASS (0 failures)");
	else
		$display("tb_vblend FAIL (%0d failures)", fails);
	$finish;
end

endmodule
