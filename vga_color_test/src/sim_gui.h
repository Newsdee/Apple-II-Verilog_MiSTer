// ImGui/SDL2/OpenGL2 front end for the VGA color tester (Phase 3).
//
// One SDL window hosting two ImGui windows: a compact controls window and
// a video window showing the DUT's processed RGB output with zoom. The sim
// runs continuously: one full 262-line DUT frame per GUI iteration, so
// display/palette/seam/comb/COLOR_LINE toggles take effect on the fly.
// Model reconstruction + 2-frame preamble happens only on image change
// (including threshold changes) and the Reset button (Decision Q3).

#pragma once

#include <SDL.h>

#include <string>

#include "image_source.h"
#include "vga_sim.h"

class VgaGui {
public:
    VgaGui(Settings& settings, Image1Bit& image, VideoSource& vs)
        : s_(settings), image_(image), vs_(vs) {}

    // Runs the event loop until the window is closed. Returns exit code.
    int run();

private:
    bool load_image(const std::string& path);   // re-thresholds, rebuilds DUT
    void rebuild_and_prime();
    void draw_controls(const std::string& status);
    void draw_video_window();
    void save_frame_png();
    void list_asset_images();

    Settings& s_;
    Image1Bit& image_;
    VideoSource& vs_;

    VgaSim sim_;
    std::vector<uint8_t> frame_;   // 559x192 RGB from the DUT
    std::vector<uint8_t> tex_;     // 559x192 RGBA for the GL texture

    unsigned int gl_tex_ = 0;
    SDL_Window* sdl_window_ = nullptr;
    SDL_GLContext gl_context_ = nullptr;
    float zoom_ = 2.0f;

    std::vector<std::string> asset_images_;
    int asset_index_ = -1;         // index into asset_images_
    std::string open_path_;        // "Open image" text field
    std::string status_;
    long frame_count_ = 0;
    double sim_ms_ = 0.0;          // DUT frame time
    double loop_ms_ = 0.0;         // whole GUI iteration (DUT + render)
    double ui_fps_ = 0.0;          // DUT frames/second the loop sustains
    int last_distinct_ = 0;
    bool half_width_ = true;       // half = full 559 frame scaled to 50%
    bool canvas43_ = false;        // optional 640x480 canvas: scanline-
                                   // doubled, top-left, black remainder
};
