// Standalone VGA color tester entry point.
//
// Modes:
//   (no output options)        -> ImGui GUI (Phase 3)
//   --dump-frame f.ppm         -> headless: simulate, dump PPM/PNG
//   --dump-png f.png           -> headless: simulate, dump PNG
//   --ppm2png in out           -> convert any stb-readable image to PNG
//   --smoke-test               -> (Phase 4) headless validation
//
// See vga_sim.h for the DUT/frame model, image_source.h for image loading,
// sim_gui.h for the GUI, and PLAN.md/PROGRESS.md for decisions and status.

#include "Vvga_color_test_top.h"
#include "verilated.h"

#include "image_source.h"
#include "sim_gui.h"
#include "smoke_test.h"
#include "vga_sim.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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

#include "third_party/stb_image.h"
#include "third_party/stb_image_write.h"

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

bool write_ppm(const std::string& path, const std::vector<uint8_t>& rgb) {
    ensure_parent_dir(path);
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

// Standalone image -> PNG conversion: `--ppm2png in out`.
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

namespace {

struct Cli {
    Settings settings;
    std::string dump;          // empty = no headless dump
    bool dump_requested = false;
    int frames = 3;            // 2 preamble + 1 captured
    bool dbg = false;
    bool smoke_test = false;
    bool hue_sweep = false;    // headless: compare composite chroma vs native per hue
    bool cols = false;         // print per-column native averages (band finder)
    int x0 = 0, x1 = kOutWidth;  // x-slice for the color comparison
    std::string ppm2png_in, ppm2png_out;
    int trace_x = -1, trace_y = -1;
};

bool parse_args(int argc, char** argv, Cli* c) {
    Settings* s = &c->settings;
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
            c->dump = v;
            c->dump_requested = true;
        } else if (a == "--dump-png") {
            const char* v = next(a.c_str()); if (!v) return false;
            c->dump = v;
            c->dump_requested = true;
        } else if (a == "--ppm2png") {
            const char* vi = next(a.c_str()); if (!vi) return false;
            const char* vo = next(a.c_str()); if (!vo) return false;
            c->ppm2png_in = vi;
            c->ppm2png_out = vo;
        } else if (a == "--trace-x") {
            const char* v = next(a.c_str()); if (!v) return false;
            c->trace_x = atoi(v);
        } else if (a == "--trace-y") {
            const char* v = next(a.c_str()); if (!v) return false;
            c->trace_y = atoi(v);
        } else if (a == "--hue-sweep") {
            c->hue_sweep = true;
        } else if (a == "--cols") {
            c->cols = true;
        } else if (a == "--x0") {
            const char* v = next(a.c_str()); if (!v) return false; c->x0 = atoi(v);
        } else if (a == "--x1") {
            const char* v = next(a.c_str()); if (!v) return false; c->x1 = atoi(v);
        } else if (a == "--frames") {
            const char* v = next(a.c_str()); if (!v) return false;
            c->frames = atoi(v);
            if (c->frames < 1) { fprintf(stderr, "--frames must be >= 1\n"); return false; }
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
            s->gray_seam_fix = true;
        } else if (a == "--seam-run-fill") {
            s->seam_run_fill = true;
            s->gray_seam_fix = true;  // the run fill lives inside the feature
        } else if (a == "--seam-run-wide") {
            s->seam_run_fill = true;
            s->seam_run_wide = true;
            s->gray_seam_fix = true;
        } else if (a == "--no-run-fill-ok") {
            s->run_fill_ok = false;  // simulate the HGR (gated-off) mode
        } else if (a == "--vertical-blend") {
            s->ntsc_vertical_comb = true;
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
        } else if (a == "--phase") {
            const char* v = next(a.c_str()); if (!v) return false;
            int p = atoi(v);
            if (p < 0 || p > 3) {
                fprintf(stderr, "--phase out of range 0..3\n");
                return false;
            }
            s->phase = p;
        } else if (a == "--align") {
            const char* v = next(a.c_str()); if (!v) return false;
            int n = atoi(v);
            if (n < 0 || n > 16) {
                fprintf(stderr, "--align out of range 0..16\n");
                return false;
            }
            s->align = n;
        } else if (a == "--color-line") {
            const char* v = next(a.c_str()); if (!v) return false;
            if (!strcmp(v, "none")) s->color_line_mode = kCLNoColor;
            else if (!strcmp(v, "text")) s->color_line_mode = kCLTextGraphics;
            else if (!strcmp(v, "full")) s->color_line_mode = kCLFullColor;
            else { fprintf(stderr, "unknown --color-line %s\n", v); return false; }
        } else if (a == "--color-line-start") {
            const char* v = next(a.c_str()); if (!v) return false;
            int n = atoi(v);
            if (n < 0 || n > kActiveLines) {
                fprintf(stderr, "--color-line-start out of range 0..%d\n", kActiveLines);
                return false;
            }
            s->color_line_start = n;
        } else if (a == "--composite") {
            s->composite_en = true;
        } else if (a == "--no-composite") {
            s->composite_en = false;  // capture the VGA controller output
        } else if (a == "--comp-sat") {
            const char* v = next(a.c_str()); if (!v) return false;
            s->composite_sat = atoi(v); s->composite_en = true;
        } else if (a == "--comp-hue") {
            const char* v = next(a.c_str()); if (!v) return false;
            s->composite_hue = atoi(v); s->composite_en = true;
        } else if (a == "--comp-bright") {
            const char* v = next(a.c_str()); if (!v) return false;
            s->composite_bright = atoi(v); s->composite_en = true;
        } else if (a == "--comp-contrast") {
            const char* v = next(a.c_str()); if (!v) return false;
            s->composite_contrast = atoi(v); s->composite_en = true;
        } else if (a == "--comp-pixel-delay") {
            const char* v = next(a.c_str()); if (!v) return false;
            s->composite_pixel_delay = atoi(v); s->composite_en = true;
        } else if (a == "--comp-smear") {
            const char* v = next(a.c_str()); if (!v) return false;
            s->composite_smear = atoi(v); s->composite_en = true;
        } else if (a == "--comp-luma-delay") {
            const char* v = next(a.c_str()); if (!v) return false;
            s->composite_luma_delay = atoi(v); s->composite_en = true;
        } else if (a == "--comp-i-mirror") {
            const char* v = next(a.c_str()); if (!v) return false;
            s->composite_i_mirror = (atoi(v) != 0); s->composite_en = true;
        } else if (a == "--comp-luma-sharpen") {
            const char* v = next(a.c_str()); if (!v) return false;
            s->composite_luma_sharpen = atoi(v); s->composite_en = true;
        } else if (a == "--comp-color-line") {
            const char* v = next(a.c_str()); if (!v) return false;
            s->composite_color_line = (atoi(v) != 0); s->composite_en = true;
        } else if (a == "--comp-chroma-short") {
            s->composite_chroma_short = true; s->composite_en = true;
        } else if (a == "--no-comp-agc") {
            s->composite_agc = false; s->composite_en = true;
        } else if (a == "--smoke-test") {
            c->smoke_test = true;
        } else if (a == "--debug") {
            c->dbg = true;
        } else {
            fprintf(stderr, "unknown option %s\n", a.c_str());
            return false;
        }
    }
    return true;
}

// Average R/G/B over an x-slice [x0,x1) of the captured frame buffer.
static void frame_avg(const std::vector<uint8_t>& f, int x0, int x1, int& r, int& g, int& b) {
    long sr = 0, sg = 0, sb = 0; long n = 0;
    for (int y = 0; y < kOutHeight; ++y)
        for (int x = x0; x < x1 && x < kOutWidth; ++x) {
            size_t i = (size_t)(y * kOutWidth + x) * 3;
            sr += f[i]; sg += f[i+1]; sb += f[i+2]; n++;
        }
    r = (int)(sr / n); g = (int)(sg / n); b = (int)(sb / n);
}
static double chroma_angle(int r, int g, int b) {
    return atan2((double)(b - g), (double)(r - g)) * 180.0 / M_PI;
}

// Headless hue calibration: render the same input through the NATIVE (correct-color
// LUT) path as a reference, then through the COMPOSITE path at each hue, and report
// the hue whose chroma direction best matches the native reference.
int run_hue_sweep(const Cli& c) {
    Image1Bit image;
    VideoSource vs;
    if (c.settings.image_path.empty()) { fprintf(stderr, "--hue-sweep needs --image\n"); return 2; }
    std::string err;
    if (!load_image_1bit(c.settings.image_path, c.settings.threshold, &image, &err)) {
        fprintf(stderr, "load: %s\n", err.c_str()); return 1;
    }
    vs.image = &image;
    vs.offset = c.settings.phase + c.settings.align;

    VgaSim sim;
    const size_t fsz = (size_t)kOutWidth * kOutHeight * 3;
    std::vector<uint8_t> fr(fsz, 0);

    // Preamble to settle burst lock / vertical comb (both paths run every frame).
    Settings pre = c.settings; pre.composite_en = true;
    sim.runFrame(pre, vs, nullptr, false);
    sim.runFrame(pre, vs, nullptr, false);

    Settings ns = c.settings; ns.composite_en = false;
    sim.runFrame(ns, vs, nullptr, false);
    sim.runFrame(ns, vs, &fr, false);
    int nr, ng, nb; frame_avg(fr, c.x0, c.x1, nr, ng, nb);
    double nang = chroma_angle(nr, ng, nb);
    printf("native  avg RGB = %3d %3d %3d  chroma angle = %7.2f deg  [x %d..%d]\n", nr, ng, nb, nang, c.x0, c.x1);

    const int x0 = c.x0, x1 = c.x1;
    // Per-column native diagnostic (downsampled) so a single strong-color band can be picked.
    if (c.cols) {
        std::vector<uint8_t> nf(fsz, 0);
        sim.runFrame(ns, vs, nullptr, false);
        sim.runFrame(ns, vs, &nf, false);
        for (int cx = 8; cx < kOutWidth; cx += 24) {
            int rr, gg, bb; frame_avg(nf, cx, cx + 8, rr, gg, bb);
            printf("col %3d: native RGB = %3d %3d %3d  angle=%7.2f\n", cx, rr, gg, bb, chroma_angle(rr,gg,bb));
        }
    }

    // Strong-color bands (x-slices) from the colorbars, used for the global metric.
    struct Band { int x0, x1; const char* name; };
    static const Band bands[] = {
        { 96,120,"blue"}, {120,144,"green1"}, {144,168,"blue2"}, {216,240,"green2"},
        {288,312,"red"},  {312,336,"magenta"},{384,408,"orange"}, {456,480,"yellow"},
    };
    const int NB = (int)(sizeof(bands)/sizeof(bands[0]));
    double nat_ang[NB];
    for (int i = 0; i < NB; ++i) {
        int rr,gg,bb; frame_avg(fr, bands[i].x0, bands[i].x1, rr,gg,bb); // fr = native capture
        nat_ang[i] = chroma_angle(rr,gg,bb);
    }

    int best_h = -1; double best_d = 1e9;
    for (int h = 0; h < 256; h += 2) {
        Settings cs = c.settings; cs.composite_en = true; cs.composite_hue = h;
        sim.runFrame(cs, vs, nullptr, false);
        sim.runFrame(cs, vs, &fr, false);
        double total = 0; double per[NB];
        for (int i = 0; i < NB; ++i) {
            int cr,cg,cb; frame_avg(fr, bands[i].x0, bands[i].x1, cr,cg,cb);
            double a = chroma_angle(cr,cg,cb);
            double d = fabs(a - nat_ang[i]); if (d > 180.0) d = 360.0 - d;
            per[i] = d; total += d;
        }
        if (total < best_d) { best_d = total; best_h = h; }
        if (h % 32 == 0 || h == 254) {
            printf("hue %3d: total_err=%7.2f  [", h, total);
            for (int i = 0; i < NB; ++i) printf(" %s=%.0f", bands[i].name, per[i]);
            printf(" ]\n");
        }
    }
    printf("BEST hue = %d (total band angle error = %.2f deg vs native)\n", best_h, best_d);
    return 0;
}

int run_headless(const Cli& c) {
    Image1Bit image;
    VideoSource vs;
    if (!c.settings.image_path.empty()) {
        std::string err;
        if (!load_image_1bit(c.settings.image_path, c.settings.threshold,
                             &image, &err)) {
            fprintf(stderr, "PHASE2 FAIL: %s\n", err.c_str());
            return 1;
        }
        vs.image = &image;
        vs.offset = c.settings.phase + c.settings.align;
        printf("image: %s src=%dx%d profile=%s threshold=%d phase=%d align=%d\n",
               c.settings.image_path.c_str(), image.src_width,
               image.src_height, image.profile.c_str(), c.settings.threshold,
               c.settings.phase, c.settings.align);
    }

    VgaSim sim;
    sim.trace_x = c.trace_x;
    sim.trace_y = c.trace_y;
    std::vector<uint8_t> frame((size_t)kOutWidth * kOutHeight * 3, 0);

    FrameResult res;
    for (int fno = 0; fno < c.frames; ++fno) {
        std::vector<uint8_t>* target = (fno == c.frames - 1) ? &frame : nullptr;
        res = sim.runFrame(c.settings, vs, target, c.dbg && fno == c.frames - 1);
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

    if (c.dump_requested) {
        const bool want_png = c.dump.size() > 4 &&
            c.dump.compare(c.dump.size() - 4, 4, ".png") == 0;
        bool written = want_png ? write_png(c.dump, frame)
                                : write_ppm(c.dump, frame);
        if (!written) {
            fprintf(stderr, "PHASE1 FAIL: cannot write %s\n", c.dump.c_str());
            return 1;
        }
    }
    printf("PHASE1 OK pixels=%d lines=%d distinct=%d dump=%s\n",
           res.valid_pixels, res.lines_captured, res.distinct_rgb,
           c.dump_requested ? c.dump.c_str() : "(none)");
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Cli c;
    if (!parse_args(argc, argv, &c)) return 2;

    if (!c.ppm2png_in.empty())
        return convert_to_png(c.ppm2png_in, c.ppm2png_out);

    if (c.smoke_test)
        return run_smoke_test();

    if (c.hue_sweep)
        return run_hue_sweep(c);

    if (c.dump_requested)
        return run_headless(c);

    // Default: interactive GUI.
    Image1Bit image;
    VideoSource vs;
    vs.offset = c.settings.phase + c.settings.align;  // always: GUI image
    if (!c.settings.image_path.empty()) {
        std::string err;
        if (!load_image_1bit(c.settings.image_path, c.settings.threshold,
                             &image, &err)) {
            fprintf(stderr, "cannot load --image %s: %s (starting GUI without it)\n",
                    c.settings.image_path.c_str(), err.c_str());
            c.settings.image_path.clear();
        }
        vs.image = &image;
    }
    VgaGui gui(c.settings, image, vs);
    return gui.run();
}
