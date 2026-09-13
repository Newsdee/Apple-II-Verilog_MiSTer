// Implementation of vga_sim.h.

#include "vga_sim.h"

// Generated internals header (for the debug raw-stage trace).
#include "Vvga_color_test_top___024root.h"

#include <cstdio>
#include <set>

int color_line_for(const Settings& s, int active_line) {
    switch (s.color_line_mode) {
        case kCLNoColor:
            return 0;
        case kCLTextGraphics:
            return active_line >= s.color_line_start ? 1 : 0;
        default:
            return 1;
    }
}

// Deterministic synthetic pattern (12-line period) for the no-image mode.
// Exercises the LUT rotation (alternating / periodic phases), the mono
// path (all-1 / all-0 / single dot), and the gray-seam path (short
// '01'/'10' islands inside a mono field).
int video_bit(int line, int col) {
    switch (line % 12) {
        case 0:  return (col & 1) ? 1 : 0;
        case 1:  return ((col + 1) % 4) < 2;
        case 2:  return 1;
        case 3:  return 0;
        case 4:  return col == 3 ? 1 : 0;
        case 5:  return ((col + 2) % 8) < 4;
        case 6:  return (col >= 100 && col <= 101) ||
                        (col >= 300 && col <= 301) ||
                        (col >= 500 && col <= 501);
        case 7:  return (col % 4) < 3;
        case 8:  return (col % 4) == 0;
        case 9:  return (col & 1) ? 0 : 1;
        case 10: return ((col + 3) % 4) < 2;
        default: return ((col + 1) % 8) < 4;
    }
}

FrameResult VgaSim::runFrame(const Settings& s, const VideoSource& vs,
                             std::vector<uint8_t>* frame, bool dbg) {
    FrameResult res;
    int out_x = 0, out_y = 0;
    int line_x = 0;
    bool line_active = false;
    bool prev_vga_hbl = true;  // fresh model: filtered_timing_active=0
    int dbg_lines_printed = 0;

    // Raw-stage trace (debug): state as seen by pixel_generator at each
    // active sample (shift_reg/hcount are the PRE-edge values it reads).
    struct TraceEntry { uint32_t sr; int hcount; uint32_t rgb; };
    std::vector<TraceEntry> trace;
    bool trace_armed = false;
    int input_line_idx = 0;
    bool prev_input_hbl = true;

    // Seam-stage decision probe (debug): the captured pixel's fill decision
    // was made 2 edges earlier (seam_rgb -> current_rgb_q -> filtered_rgb),
    // reading the window as it was pre-edge then (= post-edge 3 back). A
    // ring of 4 post-edge states lets us print both at the capture edge.
    struct ProbeState {
        uint32_t w2_rgb, w3_rgb, w4_rgb;
        int w2_luma, w3_luma, w4_luma;
        int w2_sat, w3_sat, w4_sat;
        int w3_bit, w3_valid, w2_valid, w4_valid;
        int c_luma, fill_ok;
        uint32_t fill_rgb, seam_rgb, raw_rgb;
        int sr, hc;
        int bits, valid;  // full packed [6:0] bit/valid windows
    };
    ProbeState probe_hist[4] = {};
    int probe_idx = 0;  // position of the most recently recorded state

    // Composite branch knobs. Static across the frame; the decoder
    // re-locks burst and black clamp every line, so a knob change takes
    // effect from the next line with no rebuild.
    top_->COMPOSITE_SAT = (uint8_t)(s.composite_sat & 0xff);
    top_->COMPOSITE_HUE = (uint8_t)(s.composite_hue & 0xff);
    top_->COMPOSITE_BRIGHT = (uint8_t)(s.composite_bright & 0xff);
    top_->COMPOSITE_CONTRAST = (uint8_t)(s.composite_contrast & 0xff);
    top_->COMPOSITE_PIXEL_DELAY = (uint8_t)(s.composite_pixel_delay & 3);
    top_->COMPOSITE_SMEAR = (uint8_t)(s.composite_smear & 0xf);
    top_->COMPOSITE_LUMA_DELAY = (uint8_t)(s.composite_luma_delay & 0xf);
    top_->COMPOSITE_I_MIRROR = s.composite_i_mirror ? 1 : 0;
    top_->COMPOSITE_CHROMA_SHORT = s.composite_chroma_short ? 1 : 0;
    top_->COMPOSITE_AGC_EN = s.composite_agc ? 1 : 0;
    top_->COMPOSITE_COMB_EN = s.composite_comb ? 1 : 0;
    top_->COMPOSITE_COLOR_LINE = s.composite_color_line ? 1 : 0;
    top_->COMPOSITE_LUMA_SHARPEN = (uint8_t)(s.composite_luma_sharpen & 0xf);

    // Output selection: the composite "box" (on by default) captures the
    // decoder loopback; otherwise the VGA controller output, as before.
    // The composite active window is the full 560 samples (the VGA
    // controller drops 1); the frame buffer still stores kOutWidth of them.
    const bool use_comp = s.composite_en;
    const uint8_t* out_hb = use_comp ? &top_->COMP_HB : &top_->VGA_HBL;
    const uint8_t* out_vb = use_comp ? &top_->COMP_VB : &top_->VGA_VBL;
    const int line_width = use_comp ? kCompLineWidth : kOutWidth;

    for (int line = 0; line < kFrameLines; ++line) {
        const bool vbl = line < kLeadingVbl ||
                         line >= kLeadingVbl + kActiveLines;
        const int active_line = line - kLeadingVbl;  // 0..191 in active region
        const int cl = vbl ? 0 : color_line_for(s, active_line);

        for (int clock = 0; clock < kLineClocks; ++clock) {
            const int hbl = clock < kHblHighClocks ? 1 : 0;
            // Active source columns are 0..559, i.e. clock minus the
            // 352-clock blanking offset. (Feeding raw `clock` here read
            // columns 352..911 - out of bounds past 559 - which rotated
            // the image and bled the next row into the line.)
            const int video =
                (!vbl && !hbl) ? vs.bit(active_line, clock - kHblHighClocks) : 0;
            const int vga_video = (!vbl && !hbl)
                ? vs.bit(active_line,
                         clock - kHblHighClocks - s.rgb_phase_adjust)
                : 0;

            // Pre-edge state (what pixel_generator reads at this posedge).
            const uint32_t sr_pre =
                top_->rootp->vga_color_test_top__DOT__dut__DOT__shift_reg;
            const int hc_pre =
                (int)top_->rootp->vga_color_test_top__DOT__dut__DOT__hcount;
            const bool raw_active_pre = (!hbl && !vbl) && hc_pre < 560;

            // Arm the raw-stage trace at the INPUT line start, not the VGA
            // line start: the output RGB pipeline leads the raw pipeline by
            // ~14-17 samples, so the raw samples behind an output pixel are
            // generated before the VGA window opens.
            if (prev_input_hbl && !hbl && !vbl) {
                if (input_line_idx == trace_y) {
                    trace.clear();
                    trace_armed = true;
                }
                input_line_idx++;
            }
            prev_input_hbl = hbl;

            top_->VIDEO = video;
            top_->VGA_VIDEO = vga_video;
            top_->HBL = hbl;
            top_->VBL = vbl;
            top_->COLOR_LINE = cl;
            top_->SCREEN_MODE = s.screen_mode;
            top_->COLOR_PALETTE = s.color_palette;
            top_->GRAY_SEAM_FIX = s.gray_seam_fix;
            top_->SEAM_RUN_FILL = s.seam_run_fill && s.gray_seam_fix;
            top_->SEAM_RUN_WIDE = s.seam_run_wide && s.seam_run_fill &&
                                  s.gray_seam_fix;
            top_->RUN_FILL_OK = s.run_fill_ok;
            top_->NTSC_VERTICAL_COMB = s.ntsc_vertical_comb;

            top_->CLK_14M = 1;
            top_->eval();

            if (trace_armed) {
                auto* rp = top_->rootp;
                ProbeState& p = probe_hist[probe_idx];
                // RUN=1 center is window[5] (9-sample window); [4]=left 1,
                // [6]=right 1.
                p.w2_rgb = (uint32_t)rp->vga_color_test_top__DOT__dut__DOT__seam_rgb_window[4];
                p.w3_rgb = (uint32_t)rp->vga_color_test_top__DOT__dut__DOT__seam_rgb_window[5];
                p.w4_rgb = (uint32_t)rp->vga_color_test_top__DOT__dut__DOT__seam_rgb_window[6];
                p.w2_luma = (int)rp->vga_color_test_top__DOT__dut__DOT__seam_luma_window[4];
                p.w3_luma = (int)rp->vga_color_test_top__DOT__dut__DOT__seam_luma_window[5];
                p.w4_luma = (int)rp->vga_color_test_top__DOT__dut__DOT__seam_luma_window[6];
                p.w2_sat = (int)rp->vga_color_test_top__DOT__dut__DOT__seam_saturation_window[4];
                p.w3_sat = (int)rp->vga_color_test_top__DOT__dut__DOT__seam_saturation_window[5];
                p.w4_sat = (int)rp->vga_color_test_top__DOT__dut__DOT__seam_saturation_window[6];
                p.w3_bit = (int)((rp->vga_color_test_top__DOT__dut__DOT__seam_bit_window >> 5) & 1);
                p.w2_valid = (int)((rp->vga_color_test_top__DOT__dut__DOT__seam_valid_window >> 4) & 1);
                p.w3_valid = (int)((rp->vga_color_test_top__DOT__dut__DOT__seam_valid_window >> 5) & 1);
                p.w4_valid = (int)((rp->vga_color_test_top__DOT__dut__DOT__seam_valid_window >> 6) & 1);
                p.bits = (int)rp->vga_color_test_top__DOT__dut__DOT__seam_bit_window;
                p.valid = (int)rp->vga_color_test_top__DOT__dut__DOT__seam_valid_window;
                p.c_luma = (int)rp->vga_color_test_top__DOT__dut__DOT__seam_cleanup__DOT__c_luma;
                p.fill_ok = (int)rp->vga_color_test_top__DOT__dut__DOT__seam_cleanup__DOT__fill_ok;
                p.fill_rgb = (uint32_t)rp->vga_color_test_top__DOT__dut__DOT__seam_cleanup__DOT__fill_rgb;
                p.seam_rgb = (uint32_t)rp->vga_color_test_top__DOT__dut__DOT__seam_rgb;
                p.raw_rgb = (uint32_t)rp->vga_color_test_top__DOT__dut__DOT__raw_rgb;
                p.sr = (int)rp->vga_color_test_top__DOT__dut__DOT__shift_reg;
                p.hc = (int)rp->vga_color_test_top__DOT__dut__DOT__hcount;
                probe_idx = (probe_idx + 1) & 3;
            }

            if (trace_armed && raw_active_pre) {
                trace.push_back({sr_pre, hc_pre,
                                 (uint32_t)top_->rootp
                                     ->vga_color_test_top__DOT__dut__DOT__raw_rgb});
            }

            const bool vga_hbl = *out_hb != 0;
            const bool vga_vbl = *out_vb != 0;

            if (prev_vga_hbl && !vga_hbl) {
                // VGA active line started. vbl_delayed is stable across
                // the whole VGA window (it only changes at source HBL
                // falling edges), so sampling it here is safe.
                line_x = 0;
                line_active = !vga_vbl;
                if (dbg && line_active && dbg_lines_printed < 6) {
                    printf("  [dbg] VGA line start: src_line=%d clock=%d vga_vbl=%d\n",
                           line, clock, (int)vga_vbl);
                    dbg_lines_printed++;
                }
            } else if (!prev_vga_hbl && vga_hbl) {
                // VGA active line ended.
                if (line_active) {
                    if (res.first_line_width < 0) res.first_line_width = line_x;
                    res.last_line_width = line_x;
                    if (line_x < res.min_line_width) res.min_line_width = line_x;
                    if (line_x > res.max_line_width) res.max_line_width = line_x;
                    if (line_x != line_width) {
                        res.bad_line_widths++;
                        if (res.bad_line_widths <= 3) {
                            char buf[128];
                            snprintf(buf, sizeof(buf),
                                     "%s line %d has %d pixels (want %d)",
                                     use_comp ? "COMP" : "VGA",
                                     out_y, line_x, line_width);
                            res.error = buf;
                        }
                    }
                    out_y++;
                }
                line_active = false;
            }

            if (!vga_hbl) {
                if (frame && line_active && !vga_vbl &&
                    out_y < kOutHeight && line_x < kOutWidth) {
                    size_t i = (size_t)(out_y * kOutWidth + line_x) * 3;
                    if (use_comp) {
                        (*frame)[i + 0] = top_->COMP_R;
                        (*frame)[i + 1] = top_->COMP_G;
                        (*frame)[i + 2] = top_->COMP_B;
                    } else {
                        (*frame)[i + 0] = top_->VGA_R;
                        (*frame)[i + 1] = top_->VGA_G;
                        (*frame)[i + 2] = top_->VGA_B;
                    }
                    res.valid_pixels++;
                    if (trace_armed && line_x == trace_x &&
                        out_y == trace_y) {
                        const uint32_t got = ((uint32_t)(*frame)[i] << 16) |
                            ((uint32_t)(*frame)[i + 1] << 8) |
                            (uint32_t)(*frame)[i + 2];
                        printf("TRACE out=(%d,%d) rgb=%02x%02x%02x\n",
                               trace_x, trace_y, (got >> 16) & 255,
                               (got >> 8) & 255, got & 255);
                        // Decision state: fill decision made 2 edges ago;
                        // the window it read is the post-edge state from 3
                        // edges ago.
                        const ProbeState& dec = probe_hist[(probe_idx + 1) & 3];
                        const ProbeState& win = probe_hist[probe_idx];
                        printf("  DECISION (edge -2): fill_ok=%d fill_rgb=%06x "
                               "seam_rgb_out=%06x c_luma=%d\n",
                               dec.fill_ok, dec.fill_rgb, dec.seam_rgb,
                               dec.c_luma);
                        printf("  WINDOW (edge -3): w2=%06x(luma %d sat %d) "
                               "w3=%06x(luma %d sat %d bit %d valid %d) "
                               "w4=%06x(luma %d sat %d)\n",
                               win.w2_rgb, win.w2_luma, win.w2_sat,
                               win.w3_rgb, win.w3_luma, win.w3_sat,
                               win.w3_bit, win.w3_valid,
                               win.w4_rgb, win.w4_luma, win.w4_sat);
                        printf("  WINDOWS (edge -3): bits[6:0]=%07o "
                               "valid[6:0]=%07o\n",
                               win.bits, win.valid);
                        printf("  RAW (edge -2): raw_rgb=%06x sr=%06x hc=%d | "
                               "now: raw_rgb=%06x sr=%06x hc=%d\n",
                               dec.raw_rgb, dec.sr, dec.hc,
                               (uint32_t)top_->rootp->
                                   vga_color_test_top__DOT__dut__DOT__raw_rgb,
                               (int)top_->rootp->
                                   vga_color_test_top__DOT__dut__DOT__shift_reg,
                               (int)top_->rootp->
                                   vga_color_test_top__DOT__dut__DOT__hcount);
                        // Center the window on the expected raw hcount
                        // (output x + ~16 lead); mark RGB matches.
                        size_t match = trace.size();
                        for (size_t k = 0; k < trace.size(); ++k)
                            if (trace[k].rgb == got) { match = k; break; }
                        size_t center = trace.size();
                        for (size_t k = 0; k < trace.size(); ++k)
                            if (trace[k].hcount == line_x + 16) {
                                center = k; break;
                            }
                        if (match < trace.size() &&
                            (center == trace.size() ||
                             (int)match > (int)center - 6 &&
                             (int)match < (int)center + 6))
                            center = match;
                        const int lo = (int)(center < trace.size() ? center - 14
                                        : line_x + 9);
                        const int hi = (int)(center < trace.size() ? center + 14
                                        : line_x + 27);
                        for (size_t k = 0; k < trace.size(); ++k) {
                            if ((int)k < lo || (int)k > hi) continue;
                            printf("  raw[%3zu] sr[5:0]=%06x hcount=%3d "
                                   "hcount%%4=%d raw_rgb=%06x%s\n",
                                   k, trace[k].sr, trace[k].hcount,
                                   trace[k].hcount % 4,
                                   trace[k].rgb,
                                   trace[k].rgb == got ? "  <- rgb match" : "");
                        }
                        trace_armed = false;
                    }
                }
                line_x++;
            }

            top_->CLK_14M = 0;
            top_->eval();
            prev_vga_hbl = vga_hbl;
        }
    }

    // Composite horizontal correction remains capture-only. RGB phase is
    // adjusted at its VIDEO input above, before artifact-color generation.
    if (use_comp && frame) {
        const int shift = 3 + (s.composite_left_shift & 3);
        for (int y = 0; y < kOutHeight; ++y) {
            uint8_t* row = &(*frame)[(size_t)y * kOutWidth * 3];
            for (int x = 0; x + shift < kOutWidth; ++x) {
                row[x * 3 + 0] = row[(x + shift) * 3 + 0];
                row[x * 3 + 1] = row[(x + shift) * 3 + 1];
                row[x * 3 + 2] = row[(x + shift) * 3 + 2];
            }
            for (int x = kOutWidth - shift; x < kOutWidth; ++x)
                row[x * 3 + 0] = row[x * 3 + 1] = row[x * 3 + 2] = 0;
        }
    }

    res.lines_captured = out_y;
    if (frame) {
        std::set<uint32_t> colors;
        for (size_t i = 0; i < frame->size(); i += 3) {
            colors.insert(((uint32_t)(*frame)[i] << 16) |
                          ((uint32_t)(*frame)[i + 1] << 8) |
                          (uint32_t)(*frame)[i + 2]);
        }
        res.distinct_rgb = (int)colors.size();
    }
    return res;
}
