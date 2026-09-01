// Implementation of smoke_test.h.

#include "smoke_test.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#ifdef _WIN32
#include <direct.h>
#endif

#include "image_source.h"
#include "vga_sim.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void fail(const std::string& gate, const std::string& msg) {
    g_failures++;
    fprintf(stderr, "SMOKE FAIL [%s]: %s\n", gate.c_str(), msg.c_str());
}

void pass(const std::string& gate, const std::string& msg) {
    printf("SMOKE PASS [%s]: %s\n", gate.c_str(), msg.c_str());
}

bool check(const std::string& gate, bool ok, const std::string& msg) {
    g_checks++;
    if (ok) {
        pass(gate, msg);
        return true;
    }
    fail(gate, msg);
    return false;
}

bool write_ppm(const std::string& path, const std::vector<uint8_t>& rgb) {
    const size_t pos = path.find_last_of('/');
    if (pos != std::string::npos && pos > 0) {
#ifdef _WIN32
        _mkdir(path.substr(0, pos).c_str());
#else
        ::mkdir(path.substr(0, pos).c_str(), 0755);
#endif
    }
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return false;
    fprintf(f, "P6\n%d %d\n255\n", kOutWidth, kOutHeight);
    const size_t n = fwrite(rgb.data(), 1, rgb.size(), f);
    fclose(f);
    return n == rgb.size();
}

void dump_failure(const std::string& gate,
                  const std::vector<uint8_t>& frame) {
    const std::string path = "output/smoke_fail_" + gate + ".ppm";
    if (write_ppm(path, frame))
        fprintf(stderr, "  failing frame dumped to %s\n", path.c_str());
}

uint64_t fnv1a(const std::vector<uint8_t>& d) {
    uint64_t h = 1469598103934665603ULL;
    for (uint8_t b : d) {
        h ^= b;
        h *= 1099511628211ULL;
    }
    return h;
}

std::vector<std::string> list_assets() {
    std::vector<std::string> out;
    namespace fs = std::filesystem;
    std::error_code ec;
    if (!fs::is_directory("assets", ec)) return out;
    for (const auto& e : fs::directory_iterator("assets", ec)) {
        if (!e.is_regular_file()) continue;
        const std::string ext = e.path().extension().string();
        if (ext == ".png" || ext == ".bmp" || ext == ".PNG" || ext == ".BMP")
            out.push_back("assets/" + e.path().filename().string());
    }
    std::sort(out.begin(), out.end());
    return out;
}

// Rebuild the DUT, run 2 preamble frames, capture one frame.
FrameResult capture_clean(VgaSim& sim, const Settings& s,
                          const VideoSource& vs, std::vector<uint8_t>* frame) {
    sim.rebuild();
    sim.runFrame(s, vs, nullptr, false);
    sim.runFrame(s, vs, nullptr, false);
    return sim.runFrame(s, vs, frame, false);
}

}  // namespace

int run_smoke_test() {
    printf("=== vga_color_test smoke test (headless) ===\n");
    Settings s;  // defaults: color, NTSC, phase 2, align 12, full color-line
    VgaSim sim;
    std::vector<uint8_t> frame((size_t)kOutWidth * kOutHeight * 3, 0);

    // --- Gate 1: image load ---
    const std::vector<std::string> assets = list_assets();
    if (!check("image-load", !assets.empty(),
               assets.empty() ? "no images in assets/"
                              : std::to_string(assets.size()) + " bundled images"))
        return 1;

    struct Loaded {
        std::string path;
        Image1Bit image;
    };
    std::vector<Loaded> loaded;
    for (const auto& p : assets) {
        Image1Bit img;
        std::string err;
        if (load_image_1bit(p, s.threshold, &img, &err)) {
            Loaded l;
            l.path = p;
            l.image = std::move(img);
            loaded.push_back(std::move(l));
        } else {
            fail("image-load", p + ": " + err);
        }
    }
    if (loaded.empty()) return 1;
    printf("  loaded %zu/%zu images (profiles: ", loaded.size(), assets.size());
    for (size_t i = 0; i < loaded.size(); ++i) {
        // re-derive profile text via a fresh load is wasteful; print sizes
        printf("%s%s %dx%d", i ? ", " : "", loaded[i].path.c_str(),
               loaded[i].image.src_width, loaded[i].image.src_height);
    }
    printf(")\n");

    // Representative image: prefer a native 560/568 source (no duplication)
    // so the settings matrix exercises the full palette.
    const Loaded* rep = &loaded[0];
    for (const auto& l : loaded)
        if (l.image.src_width >= 560) { rep = &l; break; }

    // --- Gate 2: basic capture for every image ---
    bool basic_ok = true;
    for (const auto& l : loaded) {
        VideoSource vs;
        vs.image = &l.image;
        vs.offset = s.phase + s.align;
        std::fill(frame.begin(), frame.end(), 0);
        FrameResult r = capture_clean(sim, s, vs, &frame);
        if (!check("basic-capture", r.ok(),
                   l.path + ": " + std::to_string(r.valid_pixels) + " px, " +
                   std::to_string(r.lines_captured) + " lines, " +
                   std::to_string(r.bad_line_widths) + " bad widths" +
                   (r.error.empty() ? std::string() : " " + r.error))) {
            basic_ok = false;
            dump_failure("basic_" +
                         std::filesystem::path(l.path).stem().string(), frame);
        }
    }
    if (!basic_ok) return 1;

    // --- Gate 3: settings matrix on the representative image ---
    VideoSource rvs;
    rvs.image = &rep->image;
    int cases = 0;
    bool matrix_ok = true;
    for (int display = 0; display < 4; ++display)
        for (int palette = 0; palette < 3; ++palette)  // built-in only
            for (int seam = 0; seam < 2; ++seam)
                for (int runf = 0; runf < 2; ++runf)  // 2-3 px run fill
                    for (int wide = 0; wide < 2; ++wide)  // 2-5 px extension
                        for (int comb = 0; comb < 2; ++comb)
                            for (int cl = 0; cl < 2; ++cl) {  // none, full
                            Settings m = s;
                            m.screen_mode = display;
                            m.color_palette = palette;
                            m.gray_seam_fix = (seam != 0);
                            m.seam_run_fill = (seam != 0) && (runf != 0);
                            m.seam_run_wide = m.seam_run_fill && (wide != 0);
                            m.ntsc_vertical_comb = (comb != 0);
                            m.color_line_mode = cl ? kCLFullColor : kCLNoColor;
                            rvs.offset = m.phase + m.align;
                            std::fill(frame.begin(), frame.end(), 0);
                            FrameResult r = capture_clean(sim, m, rvs, &frame);
                            cases++;
                            if (!r.ok()) {
                                char tag[64];
                                snprintf(tag, sizeof(tag),
                                         "d%d p%d s%d r%d w%d c%d cl%d",
                                         display, palette, seam, runf, wide,
                                         comb, cl);
                                check("settings-matrix", false,
                                      rep->path + " " + tag + ": " + r.error);
                                matrix_ok = false;
                                dump_failure(std::string("matrix_") + tag,
                                             frame);
                            }
                        }
    if (matrix_ok)
        pass("settings-matrix",
             std::to_string(cases) + " cases on " + rep->path +
             " (4 display x 3 palette x seam x run-fill x wide x comb x "
             "color-line)");

    // --- Gate 3b: RUN_FILL_OK gate equivalence ---
    // With the mode gate low (the HGR case) the DUT must take the exact
    // run-fill-off path: the gated frame is byte-identical to the
    // SEAM_RUN_FILL=0 frame, and the ungated frame differs (the fill is
    // actually active when the gate is high).
    {
        Settings gated = s;   // run fill requested but gated off
        gated.gray_seam_fix = true;
        gated.seam_run_fill = true;
        gated.seam_run_wide = true;
        gated.run_fill_ok = false;
        Settings off = gated; // v2-only reference
        off.seam_run_fill = false;
        off.seam_run_wide = false;
        off.run_fill_ok = true;
        Settings ungated = gated;
        ungated.run_fill_ok = true;
        std::vector<uint8_t> fa(frame.size()), fb(frame.size()),
            fc(frame.size());
        rvs.offset = gated.phase + gated.align;
        FrameResult ra = capture_clean(sim, gated, rvs, &fa);
        FrameResult rb = capture_clean(sim, off, rvs, &fb);
        FrameResult rc = capture_clean(sim, ungated, rvs, &fc);
        int diff_ab = 0, diff_ac = 0;
        for (size_t i = 0; i < fa.size(); ++i) {
            if (fa[i] != fb[i]) diff_ab++;
            if (fa[i] != fc[i]) diff_ac++;
        }
        if (!check("run-gate-equiv", ra.ok() && rb.ok() && rc.ok() &&
                   diff_ab == 0 && diff_ac > 0,
                   rep->path + ": gated-vs-off " + std::to_string(diff_ab) +
                   " px (want 0), gated-vs-ungated " +
                   std::to_string(diff_ac) + " px (want >0)")) {
            dump_failure("run_gate_gated", fa);
            dump_failure("run_gate_off", fb);
            dump_failure("run_gate_ungated", fc);
        }
    }

    // --- Gate 4: B&W mono (R=G=B) ---
    {
        Settings m = s;
        m.screen_mode = 1;            // B&W
        m.color_line_mode = kCLNoColor;
        rvs.offset = m.phase + m.align;
        std::fill(frame.begin(), frame.end(), 0);
        FrameResult r = capture_clean(sim, m, rvs, &frame);
        int non_gray = 0;
        for (size_t i = 0; i < frame.size(); i += 3)
            if (frame[i] != frame[i + 1] || frame[i] != frame[i + 2]) non_gray++;
        if (!check("bw-mono", r.ok() && non_gray == 0,
                   rep->path + ": " + std::to_string(non_gray) +
                   " non-gray pixels (want 0)"))
            dump_failure("bw_mono", frame);
    }

    // --- Gate 5: determinism across clean reconstructions ---
    {
        std::vector<uint8_t> a(frame.size()), b(frame.size());
        capture_clean(sim, s, rvs, &a);
        capture_clean(sim, s, rvs, &b);
        const uint64_t ha = fnv1a(a), hb = fnv1a(b);
        char msg[160];
        snprintf(msg, sizeof(msg), "hash %016llx vs %016llx",
                 (unsigned long long)ha, (unsigned long long)hb);
        if (!check("determinism", ha == hb, msg)) {
            dump_failure("determinism_a", a);
            dump_failure("determinism_b", b);
        }
    }

    // --- Gate 6: alignment (feeder column indexing regression) ---
    {
        Settings m = s;
        m.screen_mode = 1;
        m.color_line_mode = kCLNoColor;
        rvs.offset = m.phase + m.align;
        std::fill(frame.begin(), frame.end(), 0);
        capture_clean(sim, m, rvs, &frame);
        const Image1Bit& src = rep->image;
        const int W = Image1Bit::kWidth;
        int best_err = 0x7fffffff, best_s = -1;
        for (int sh = 0; sh < W; ++sh) {
            int err = 0;
            for (int y = 0; y < kOutHeight; ++y)
                for (int x = 0; x < kOutWidth; ++x) {
                    const size_t fi = ((size_t)y * kOutWidth + x) * 3;
                    const int luma = (frame[fi] * 77 + frame[fi + 1] * 150 +
                                      frame[fi + 2] * 29) >> 8;
                    const int ob = luma >= 64 ? 1 : 0;
                    if (ob != src.at(y, (x + sh) % W)) err++;
                }
            if (err < best_err) { best_err = err; best_s = sh; }
        }
        const double pct = 100.0 * best_err / kExpectedPixels;
        char msg[160];
        snprintf(msg, sizeof(msg),
                 "best shift %d, mismatch %d/%d (%.2f%%, want < 1%%)",
                 best_s, best_err, kExpectedPixels, pct);
        if (!check("alignment", pct < 1.0, msg))
            dump_failure("alignment", frame);
    }

    // --- Gate 7: unsupported size fails cleanly ---
    {
        const std::string p = "output/smoke_bad_size.ppm";
        FILE* f = fopen(p.c_str(), "wb");
        bool ok = false;
        if (f) {
            fputs("P6\n100 100\n255\n", f);
            const unsigned char z[30000] = {0};
            ok = fwrite(z, 1, sizeof(z), f) == sizeof(z);
            fclose(f);
        }
        if (ok) {
            Image1Bit img;
            std::string err;
            const bool rejected = !load_image_1bit(p, s.threshold, &img, &err);
            check("bad-size", rejected && !err.empty(),
                  rejected ? "100x100 rejected: " + err
                           : "100x100 was NOT rejected");
            std::remove(p.c_str());
        } else {
            fail("bad-size", "cannot create temporary test PPM");
        }
    }

    printf("=== smoke test %s: %d checks, %d failure(s) ===\n",
           g_failures ? "FAIL" : "OK", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
