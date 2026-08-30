// Shared DUT driver for the VGA color tester (headless + GUI).
//
// Drives the Verilated vga_controller with a full 262-line NTSC frame
// (40 leading VBL + 192 active + 30 trailing VBL, 912 source clocks per
// line) and captures the qualified VGA RGB output (VGA_HBL=0 &&
// VGA_VBL=0) into a 559x192 framebuffer.
//
// Frame model (Decision Q3): the DUT's VGA_VS pulses at vcount 33-35, which
// the leading blanking covers. The blanking is split leading/trailing (not
// all leading) so the DUT's delayed output window for the LAST active line
// completes inside the frame (the DUT delays raw_active by 19 cycles, so
// each VGA window spans into the next source line). The model has no reset
// port; a fresh model starts with all registers 0, and preamble frames are
// discarded so the captured frame has settled vertical-comb history.
//
// COLOR_LINE (Decision Q2): mode 0 = no color (0 on all lines), mode 1 =
// text + graphics (0 for lines < N, 1 for lines >= N), mode 2 = full color
// (1 on all lines).

#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "Vvga_color_test_top.h"
#include "image_source.h"

constexpr int kLineClocks = 912;      // source clocks per line
constexpr int kHblHighClocks = 352;   // HBL=1 for clocks 0..351
constexpr int kLeadingVbl = 40;       // covers VGA_VS at vcount 33-35
constexpr int kActiveLines = 192;     // active image lines
constexpr int kTrailingVbl = 30;      // absorbs the last line's 19-cycle tail
constexpr int kFrameLines = kLeadingVbl + kActiveLines + kTrailingVbl;  // 262
// The DUT's hcount reset consumes 1 of the 560 active clocks, so each VGA
// line is 559 px wide (measured, deterministic). See PROGRESS.md.
constexpr int kOutWidth = 559;
constexpr int kOutHeight = 192;
constexpr int kExpectedPixels = kOutWidth * kOutHeight;  // 107,328

// COLOR_LINE control (Decision Q2).
enum ColorLineMode { kCLNoColor = 0, kCLTextGraphics = 1, kCLFullColor = 2 };

struct Settings {
    int screen_mode = 0;          // 00 color, 01 B&W, 10 green, 11 amber
    int color_palette = 0;        // 00 NTSC //e, 01 IIgs, 10 AppleWin, 11 custom
    bool gray_seam_fix = false;   // Sharper RGB
    bool ntsc_vertical_comb = false;  // vertical blend
    int color_line_mode = kCLFullColor;
    int color_line_start = 1;     // N for kCLTextGraphics (0..191)
    std::string image_path;       // empty = synthetic pattern
    int threshold = 128;          // luminance threshold for images
    int phase = 2;                // feed phase 0..3 (color-phase offset;
                                  // 2 verified correct against real NTSC)
    // Alignment offset in samples. The DUT's internal data pipeline leads its
    // timing window by ~12 samples (measured 0.08% residual at shift 12), so
    // content fed at the HBL falling edge appears ~12 samples early. In the
    // real core the video stream's phase relative to HBL compensates this
    // implicitly; the synthetic feeder compensates it explicitly.
    int align = 12;
};

int color_line_for(const Settings& s, int active_line);

// Deterministic synthetic pattern (12-line period) used when no image is
// loaded. Exercises the LUT rotation, the mono path, and the gray-seam path.
int video_bit(int line, int col);

// Video bit provider: either the loaded 1-bit image or the synthetic
// pattern.
struct VideoSource {
    const Image1Bit* image = nullptr;  // non-null when an image is loaded
    // Feed offset: circular shift of the 560-sample row before feeding.
    // offset = phase (0..3, color phase) + align (DUT skew compensation).
    // The artifact-color rotation (shift_color = rotl(sr[4:1], hcount[1:0]))
    // depends on which sample phase the content sits at relative to the HBL
    // falling edge, so the offset modulo 4 sets the palette rotation and the
    // full offset sets the horizontal alignment - they are coupled.
    int offset = 0;
    int bit(int line, int col) const {
        if (image) {
            const int W = Image1Bit::kWidth;
            const int c = (col - offset + 2 * W) % W;
            return image->at(line, c);
        }
        return video_bit(line, col);
    }
};

struct FrameResult {
    int valid_pixels = 0;
    int lines_captured = 0;
    int bad_line_widths = 0;
    int distinct_rgb = 0;
    int min_line_width = 0x7fffffff;
    int max_line_width = 0;
    int first_line_width = -1;
    int last_line_width = -1;
    std::string error;
    bool ok() const {
        return valid_pixels == kExpectedPixels &&
               lines_captured == kActiveLines &&
               bad_line_widths == 0 &&
               distinct_rgb >= 2 &&
               error.empty();
    }
};

class VgaSim {
public:
    VgaSim() { rebuild(); }

    // Reconstruct the Verilated model (no reset port exists) so stale
    // vertical-comb history cannot survive an image change / Reset.
    // Callers must run 2 preamble frames after a rebuild.
    void rebuild() {
        top_ = std::make_unique<Vvga_color_test_top>();
        // Hold the custom-palette loader inactive.
        top_->ioctl_addr = 0;
        top_->ioctl_data = 0;
        top_->ioctl_index = 0;
        top_->ioctl_download = 0;
        top_->ioctl_wr = 0;
    }

    // Simulate one 262-line frame. If `frame` is non-null, capture the
    // 559x192 RGB output (row-major, packed).
    FrameResult runFrame(const Settings& s, const VideoSource& vs,
                         std::vector<uint8_t>* frame, bool dbg);

private:
    std::unique_ptr<Vvga_color_test_top> top_;
};
