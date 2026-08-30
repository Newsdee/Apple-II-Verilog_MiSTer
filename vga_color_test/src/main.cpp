// Standalone VGA color tester.
//
// Phase 1: headless DUT driver (no GUI, no image loader).
//
// Drives the Verilated vga_controller with a full 262-line NTSC frame
// (70 VBL + 192 active lines, 912 source clocks per line) using a
// deterministic synthetic video pattern, captures the qualified VGA RGB
// output (VGA_HBL=0 && VGA_VBL=0) into a 560x192 framebuffer, and dumps
// it as PPM.
//
// Frame model (Decision Q3): 262 lines = 70 VBL + 192 active. The DUT's
// VGA_VS pulses at vcount 33-35 (VBL_TO_VSYNC=33, VGA_VSYNC_LINES=3),
// which the 70-line blanking covers. The model has no reset port; a fresh
// Verilated model starts with all registers 0, and the first frame's
// leading blanking primes vcount/VS. Preamble frames are discarded so the
// captured frame has settled vertical-comb history.
//
// COLOR_LINE (Decision Q2): mode 0 = no color (0 on all lines), mode 1 =
// text + graphics (0 for lines < N, 1 for lines >= N), mode 2 = full color
// (1 on all lines).

#include "Vvga_color_test_top.h"
#include "verilated.h"

#include "image_source.h"
#include "third_party/stb_image.h"
#include "third_party/stb_image_write.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include <sys/stat.h>
#include <sys/types.h>
#ifdef _WIN32
#include <direct.h>
#define VCT_MKDIR(p) _mkdir(p)
#else
#define VCT_MKDIR(p) mkdir((p), 0755)
#endif

// Verilator runtime time fallback for a standalone (non-SystemC) app.
// The clock is driven manually in the sim loop, so the value is unused.
double sc_time_stamp() { return 0; }

// Create the parent directory of `file` (single level, e.g. "output/").
// Best effort: existing directories are fine, failures are ignored (the
// subsequent fopen reports a real error if the path is unusable).
void ensure_parent_dir(const std::string& file) {
    size_t pos = file.find_last_of('/');
    if (pos == std::string::npos || pos == 0) return;
    VCT_MKDIR(file.substr(0, pos).c_str());
}

namespace {

constexpr int kLineClocks = 912;      // source clocks per line
constexpr int kHblHighClocks = 352;   // HBL=1 for clocks 0..351
// 262-line NTSC frame. The blanking is split leading/trailing (not all
// leading) so the DUT's delayed output window for the LAST active line
// completes inside the frame. The DUT delays raw_active by 19 cycles
// (seam window + timing_active_delay + filter), so each VGA window spans
// into the next source line; with trailing blanking that next line is in
// the same frame and the window is captured as one line instead of being
// split across the frame boundary.
constexpr int kLeadingVbl = 40;       // covers VGA_VS at vcount 33-35
constexpr int kActiveLines = 192;     // active image lines
constexpr int kTrailingVbl = 30;      // absorbs the last line's 19-cycle tail
constexpr int kFrameLines = kLeadingVbl + kActiveLines + kTrailingVbl;  // 262
// The DUT's hcount reset consumes 1 of the 560 active clocks, so each VGA
// line is 559 px wide (measured, deterministic). See PLAN.md.
constexpr int kOutWidth = 559;
constexpr int kOutHeight = 192;
constexpr int kExpectedPixels = kOutWidth * kOutHeight;  // 107,328

// COLOR_LINE control (Decision Q2).
enum ColorLineMode { kCLNoColor = 0, kCLTextGraphics = 1, kCLFullColor = 2 };

struct Settings {
    int screen_mode = 0;          // 00 color, 01 B&W, 10 green, 11 amber
    int color_palette = 0;        // 00 NTSC //e, 01 IIgs, 10 AppleWin, 11 custom
    int gray_seam_fix = 0;        // 1 = Sharper RGB
    int ntsc_vertical_comb = 0;   // 1 = vertical blend
    int color_line_mode = kCLFullColor;
    int color_line_start = 1;     // N for kCLTextGraphics (0..191)
    std::string image_path;       // empty = synthetic Phase 1 pattern
    int threshold = 128;          // luminance threshold for --image
};

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

// Deterministic synthetic pattern (12-line period) for Phase 1.
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

// Video bit provider: either the loaded 1-bit image or the synthetic
// Phase 1 pattern.
struct VideoSource {
    const Image1Bit* image = nullptr;  // non-null when --image was given
    int bit(int line, int col) const {
        if (image) return image->at(line, col);
        return video_bit(line, col);
    }
};

class VgaSim {
public:
    VgaSim() : top_(std::make_unique<Vvga_color_test_top>()) {
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
                const int video = (!vbl && !hbl) ? vs.bit(active_line, clock) : 0;

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

private:
    std::unique_ptr<Vvga_color_test_top> top_;
};

bool write_ppm(const std::string& path, const std::vector<uint8_t>& rgb) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return false;
    fprintf(f, "P6\n%d %d\n255\n", kOutWidth, kOutHeight);
    size_t n = fwrite(rgb.data(), 1, rgb.size(), f);
    fclose(f);
    return n == rgb.size();
}

bool write_png(const std::string& path, const std::vector<uint8_t>& rgb) {
    ensure_parent_dir(path);
    return stbi_write_png(path.c_str(), kOutWidth, kOutHeight, 3,
                          rgb.data(), kOutWidth * 3) != 0;
}

// Standalone PPM -> PNG conversion: `--ppm2png in.ppm out.png`.
// Loads any stb-readable image (PPM/BMP/PNG) and re-encodes it as PNG.
// Exits before any simulation runs.
int convert_to_png(const std::string& in, const std::string& out) {
    int w = 0, h = 0, comp = 0;
    unsigned char* px = stbi_load(in.c_str(), &w, &h, &comp, 3);
    if (!px) {
        fprintf(stderr, "ppm2png: cannot load %s: %s\n", in.c_str(),
                stbi_failure_reason());
        return 1;
    }
    ensure_parent_dir(out);
    if (!stbi_write_png(out.c_str(), w, h, 3, px, w * 3)) {
        fprintf(stderr, "ppm2png: cannot write %s\n", out.c_str());
        stbi_image_free(px);
        return 1;
    }
    stbi_image_free(px);
    printf("ppm2png: %s -> %s (%dx%d)\n", in.c_str(), out.c_str(), w, h);
    return 0;
}

bool parse_args(int argc, char** argv, Settings* s, std::string* dump, int* frames,
                bool* dbg, std::string* ppm2png_in, std::string* ppm2png_out) {
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&](const char* what) -> const char* {
            if (i + 1 >= argc) {
                fprintf(stderr, "missing value for %s\n", what);
                return nullptr;
            }
            return argv[++i];
        };
        if (a == "--dump-frame") {
            const char* v = next(a.c_str()); if (!v) return false;
            *dump = v;
        } else if (a == "--frames") {
            const char* v = next(a.c_str()); if (!v) return false;
            *frames = atoi(v);
            if (*frames < 1) { fprintf(stderr, "--frames must be >= 1\n"); return false; }
        } else if (a == "--display") {
            const char* v = next(a.c_str()); if (!v) return false;
            if (!strcmp(v, "color")) s->screen_mode = 0;
            else if (!strcmp(v, "bw")) s->screen_mode = 1;
            else if (!strcmp(v, "green")) s->screen_mode = 2;
            else if (!strcmp(v, "amber")) s->screen_mode = 3;
            else { fprintf(stderr, "unknown --display %s\n", v); return false; }
        } else if (a == "--palette") {
            const char* v = next(a.c_str()); if (!v) return false;
            if (!strcmp(v, "ntsc")) s->color_palette = 0;
            else if (!strcmp(v, "iigs")) s->color_palette = 1;
            else if (!strcmp(v, "applewin")) s->color_palette = 2;
            else if (!strcmp(v, "custom")) s->color_palette = 3;
            else { fprintf(stderr, "unknown --palette %s\n", v); return false; }
        } else if (a == "--sharp-rgb") {
            s->gray_seam_fix = 1;
        } else if (a == "--vertical-blend") {
            s->ntsc_vertical_comb = 1;
        } else if (a == "--debug") {
            *dbg = true;
        } else if (a == "--color-line") {
            const char* v = next(a.c_str()); if (!v) return false;
            if (!strcmp(v, "none")) s->color_line_mode = kCLNoColor;
            else if (!strcmp(v, "text")) s->color_line_mode = kCLTextGraphics;
            else if (!strcmp(v, "full")) s->color_line_mode = kCLFullColor;
            else { fprintf(stderr, "unknown --color-line %s\n", v); return false; }
        } else if (a == "--dump-png") {
            const char* v = next(a.c_str()); if (!v) return false;
            *dump = v;  // extension decides PPM vs PNG at dump time
        } else if (a == "--ppm2png") {
            const char* vi = next(a.c_str()); if (!vi) return false;
            const char* vo = next(a.c_str()); if (!vo) return false;
            *ppm2png_in = vi;
            *ppm2png_out = vo;
        } else if (a == "--image") {
            const char* v = next(a.c_str()); if (!v) return false;
            s->image_path = v;
        } else if (a == "--threshold") {
            const char* v = next(a.c_str()); if (!v) return false;
            int t = atoi(v);
            if (t < 0 || t > 255) {
                fprintf(stderr, "--threshold out of range 0..255\n");
                return false;
            }
            s->threshold = t;
        } else if (a == "--color-line-start") {
            const char* v = next(a.c_str()); if (!v) return false;
            int n = atoi(v);
            if (n < 0 || n > kActiveLines) {
                fprintf(stderr, "--color-line-start out of range 0..%d\n", kActiveLines);
                return false;
            }
            s->color_line_start = n;
        } else {
            fprintf(stderr, "unknown option %s\n", a.c_str());
            return false;
        }
    }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Settings s;
    std::string dump = "output/frame.ppm";
    int frames = 3;  // 2 preamble + 1 captured
    bool dbg = false;
    std::string ppm2png_in, ppm2png_out;
    if (!parse_args(argc, argv, &s, &dump, &frames, &dbg, &ppm2png_in,
                    &ppm2png_out))
        return 2;
    if (!ppm2png_in.empty()) return convert_to_png(ppm2png_in, ppm2png_out);

    Image1Bit image;
    VideoSource vs;
    if (!s.image_path.empty()) {
        std::string err;
        if (!load_image_1bit(s.image_path, s.threshold, &image, &err)) {
            fprintf(stderr, "PHASE2 FAIL: %s\n", err.c_str());
            return 1;
        }
        vs.image = &image;
        printf("image: %s src=%dx%d profile=%s threshold=%d\n",
               s.image_path.c_str(), image.src_width, image.src_height,
               image.profile.c_str(), s.threshold);
    }

    VgaSim sim;
    std::vector<uint8_t> frame((size_t)kOutWidth * kOutHeight * 3, 0);

    FrameResult res;
    for (int fno = 0; fno < frames; ++fno) {
        std::vector<uint8_t>* target = (fno == frames - 1) ? &frame : nullptr;
        res = sim.runFrame(s, vs, target, dbg && fno == frames - 1);
        printf("frame %d: pixels=%d lines=%d bad_widths=%d distinct=%d "
               "w[first=%d last=%d min=%d max=%d]\n",
               fno, res.valid_pixels, res.lines_captured, res.bad_line_widths,
               res.distinct_rgb, res.first_line_width, res.last_line_width,
               res.min_line_width, res.max_line_width);
    }

    if (!res.ok()) {
        fprintf(stderr,
                "PHASE1 FAIL: pixels=%d (want %d) lines=%d (want %d) "
                "bad_widths=%d distinct=%d %s\n",
                res.valid_pixels, kExpectedPixels, res.lines_captured,
                kActiveLines, res.bad_line_widths, res.distinct_rgb,
                res.error.c_str());
        return 1;
    }
    const bool want_png = dump.size() > 4 &&
        dump.compare(dump.size() - 4, 4, ".png") == 0;
    bool written = want_png ? write_png(dump, frame) : write_ppm(dump, frame);
    if (!written) {
        fprintf(stderr, "PHASE1 FAIL: cannot write %s\n", dump.c_str());
        return 1;
    }
    printf("PHASE1 OK pixels=%d lines=%d distinct=%d dump=%s\n",
           res.valid_pixels, res.lines_captured, res.distinct_rgb, dump.c_str());
    return 0;
}
