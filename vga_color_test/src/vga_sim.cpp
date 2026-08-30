// Implementation of vga_sim.h.

#include "vga_sim.h"

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

            top_->VIDEO = video;
            top_->HBL = hbl;
            top_->VBL = vbl;
            top_->COLOR_LINE = cl;
            top_->SCREEN_MODE = s.screen_mode;
            top_->COLOR_PALETTE = s.color_palette;
            top_->GRAY_SEAM_FIX = s.gray_seam_fix;
            top_->NTSC_VERTICAL_COMB = s.ntsc_vertical_comb;

            top_->CLK_14M = 1;
            top_->eval();

            const bool vga_hbl = top_->VGA_HBL != 0;
            const bool vga_vbl = top_->VGA_VBL != 0;

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
                    if (line_x != kOutWidth) {
                        res.bad_line_widths++;
                        if (res.bad_line_widths <= 3) {
                            char buf[128];
                            snprintf(buf, sizeof(buf),
                                     "VGA line %d has %d pixels (want %d)",
                                     out_y, line_x, kOutWidth);
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
                    (*frame)[i + 0] = top_->VGA_R;
                    (*frame)[i + 1] = top_->VGA_G;
                    (*frame)[i + 2] = top_->VGA_B;
                    res.valid_pixels++;
                }
                line_x++;
            }

            top_->CLK_14M = 0;
            top_->eval();
            prev_vga_hbl = vga_hbl;
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
