// Implementation of sim_gui.h.

#include "sim_gui.h"

#include <SDL.h>
#include <SDL_opengl.h>

#include <imgui.h>
#include <imgui_impl_opengl2.h>
#include <imgui_impl_sdl.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <vector>

#include "third_party/stb_image_write.h"

namespace {

// Fixed RGBA buffer for the output texture (559x192).
std::vector<uint8_t> make_texture_buffer() {
    return std::vector<uint8_t>((size_t)kOutWidth * kOutHeight * 4, 0);
}

}  // namespace

void VgaGui::list_asset_images() {
    asset_images_.clear();
    namespace fs = std::filesystem;
    std::error_code ec;
    if (!fs::is_directory("assets", ec)) return;
    for (const auto& e : fs::directory_iterator("assets", ec)) {
        if (!e.is_regular_file()) continue;
        const std::string ext = e.path().extension().string();
        if (ext == ".png" || ext == ".bmp" || ext == ".PNG" || ext == ".BMP")
            asset_images_.push_back("assets/" + e.path().filename().string());
    }
    sort(asset_images_.begin(), asset_images_.end());
}

void VgaGui::rebuild_and_prime() {
    sim_.rebuild();
    // Two discarded preamble frames so vertical-comb history is settled.
    sim_.runFrame(s_, vs_, nullptr, false);
    sim_.runFrame(s_, vs_, nullptr, false);
}

bool VgaGui::load_image(const std::string& path) {
    Image1Bit loaded;
    std::string err;
    if (!load_image_1bit(path, s_.threshold, &loaded, &err)) {
        status_ = "ERROR: " + err;
        return false;
    }
    image_ = loaded;
    vs_.image = &image_;
    s_.image_path = path;
    rebuild_and_prime();
    status_ = "loaded " + path + " (" +
              std::to_string(image_.src_width) + "x" +
              std::to_string(image_.src_height) + ", " + image_.profile +
              ", threshold " + std::to_string(s_.threshold) + ")";
    return true;
}

void VgaGui::save_frame_png() {
    char name[128];
    const time_t t = time(nullptr);
    struct tm tmv;
#ifdef _WIN32
    localtime_s(&tmv, &t);
#else
    localtime_r(&t, &tmv);
#endif
    strftime(name, sizeof(name), "output/gui_frame_%Y%m%d_%H%M%S.png", &tmv);
    if (stbi_write_png(name, kOutWidth, kOutHeight, 3, frame_.data(),
                       kOutWidth * 3))
        status_ = std::string("saved ") + name;
    else
        status_ = std::string("ERROR: cannot write ") + name;
}

int VgaGui::run() {
    // --- SDL + OpenGL (same pattern as the full harness, non-WIN32 path) ---
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
    SDL_WindowFlags flags =
        (SDL_WindowFlags)(SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE |
                          SDL_WINDOW_ALLOW_HIGHDPI);
    sdl_window_ = SDL_CreateWindow("Apple II VGA Color Tester",
                                   SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                   1200, 900, flags);
    if (!sdl_window_) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }
    gl_context_ = SDL_GL_CreateContext(sdl_window_);
    SDL_GL_MakeCurrent(sdl_window_, gl_context_);
    SDL_GL_SetSwapInterval(0);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    ImGui_ImplSDL2_InitForOpenGL(sdl_window_, gl_context_);
    ImGui_ImplOpenGL2_Init();

    // Output texture (NEAREST: pixel-exact, zoom is integer-ish scaling).
    glGenTextures(1, &gl_tex_);
    glBindTexture(GL_TEXTURE_2D, gl_tex_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, kOutWidth, kOutHeight, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, nullptr);

    frame_.assign((size_t)kOutWidth * kOutHeight * 3, 0);
    tex_ = make_texture_buffer();

    list_asset_images();
    if (!s_.image_path.empty())
        load_image(s_.image_path);
    else
        rebuild_and_prime();  // synthetic pattern

    const ImVec4 clear_color(0.10f, 0.10f, 0.12f, 1.0f);
    char open_buf[512] = "";
    bool done = false;

    while (!done) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            ImGui_ImplSDL2_ProcessEvent(&event);
            if (event.type == SDL_QUIT) done = true;
        }

        ImGui_ImplOpenGL2_NewFrame();
        ImGui_ImplSDL2_NewFrame(sdl_window_);
        ImGui::NewFrame();

        // ---------------- Controls window ----------------
        ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Once);
        ImGui::SetNextWindowSize(ImVec2(280, 520), ImGuiCond_Once);
        ImGui::Begin("VGA Controls");

        // Image selection. Labels sit ABOVE the controls so the widgets get
        // the full window width (saves wrapped lines in the narrow window).
        if (!asset_images_.empty()) {
            std::vector<const char*> items;
            for (const auto& p : asset_images_) items.push_back(p.c_str());
            ImGui::Text("Image (bundled)");
            ImGui::SetNextItemWidth(-1);
            if (ImGui::Combo("##image", &asset_index_,
                             items.data(), (int)items.size())) {
                if (asset_index_ >= 0 &&
                    asset_index_ < (int)asset_images_.size())
                    load_image(asset_images_[asset_index_]);
            }
        }
        ImGui::Text("Open image path");
        ImGui::SetNextItemWidth(-1);
        ImGui::InputText("##openpath", open_buf, sizeof(open_buf));
        ImGui::SameLine();
        if (ImGui::Button("Load") && open_buf[0]) {
            if (!load_image(open_buf)) {
                // keep the previous image; status shows the error
            }
        }
        ImGui::Text("Luminance threshold");
        ImGui::SliderInt("##threshold", &s_.threshold, 0, 255);
        if (s_.image_path.empty())
            ImGui::TextDisabled("(no image: synthetic pattern)");

        ImGui::Separator();
        // Live toggles: each control maps 1:1 to a DUT input and takes
        // effect on the next simulated line (Decision Q3).
        ImGui::Text("Display");
        ImGui::SetNextItemWidth(-1);
        ImGui::Combo("##display", &s_.screen_mode,
                     "Color\0B&W\0Green\0Amber\0");
        ImGui::Text("Palette");
        ImGui::SetNextItemWidth(-1);
        ImGui::Combo("##palette", &s_.color_palette,
                     "NTSC //e\0IIgs\0AppleWin\0Custom\0");
        ImGui::Checkbox("Sharper RGB (composite fix)", &s_.gray_seam_fix);
        ImGui::Checkbox("NTSC vertical blend", &s_.ntsc_vertical_comb);

        const char* cl_items[] = {"No color", "Text + graphics", "Full color"};
        ImGui::Text("COLOR_LINE");
        ImGui::SetNextItemWidth(-1);
        ImGui::Combo("##color_line", &s_.color_line_mode, cl_items, 3);
        if (s_.color_line_mode == kCLTextGraphics)
            ImGui::SliderInt("Color starts at line", &s_.color_line_start,
                             0, kActiveLines - 1);

        ImGui::Separator();
        if (ImGui::Button("Reset (rebuild + preamble)"))
            rebuild_and_prime();
        if (ImGui::Button("Save frame as PNG"))
            save_frame_png();

        ImGui::Separator();
        // TextWrapped: the narrow controls window needs these to break
        // across lines instead of overflowing.
        ImGui::TextWrapped("frame %ld  |  %.1f fps  |  loop %.1f ms (sim %.1f)  |  colors %d",
                           frame_count_, ui_fps_, loop_ms_, sim_ms_,
                           last_distinct_);
        ImGui::TextWrapped("%s", status_.c_str());
        ImGui::End();

        const auto t_loop_start = std::chrono::steady_clock::now();

        // ---------------- Run one DUT frame ----------------
        const auto t0 = std::chrono::steady_clock::now();
        FrameResult res = sim_.runFrame(s_, vs_, &frame_, false);
        const auto t1 = std::chrono::steady_clock::now();
        sim_ms_ = std::chrono::duration<double, std::milli>(t1 - t0).count();
        frame_count_++;
        last_distinct_ = res.distinct_rgb;
        if (!res.ok() && status_.rfind("ERROR", 0) != 0)
            status_ = "SIM WARN: " + res.error;

        // RGB -> RGBA upload.
        for (int i = 0; i < kOutWidth * kOutHeight; ++i) {
            tex_[(size_t)i * 4 + 0] = frame_[(size_t)i * 3 + 0];
            tex_[(size_t)i * 4 + 1] = frame_[(size_t)i * 3 + 1];
            tex_[(size_t)i * 4 + 2] = frame_[(size_t)i * 3 + 2];
            tex_[(size_t)i * 4 + 3] = 255;
        }
        glBindTexture(GL_TEXTURE_2D, gl_tex_);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, kOutWidth, kOutHeight, 0,
                     GL_RGBA, GL_UNSIGNED_BYTE, tex_.data());

        // ---------------- Video window ----------------
        ImGui::SetNextWindowPos(ImVec2(290, 0), ImGuiCond_Once);
        ImGui::SetNextWindowSize(ImVec2(840, 880), ImGuiCond_Once);
        ImGui::Begin("VGA Output (DUT)");
        // Width: full 559, or the full frame scaled to half width.
        // (In 4:3 canvas mode the real output width 559 is always shown.)
        if (canvas43_) {
            ImGui::BeginDisabled();
            ImGui::RadioButton("Full 559", true);
            ImGui::SameLine();
            ImGui::RadioButton("Half (scaled)", false);
            ImGui::EndDisabled();
        } else {
            ImGui::RadioButton("Full 559", !half_width_);
            ImGui::SameLine();
            ImGui::RadioButton("Half (scaled)", half_width_);
        }
        ImGui::SameLine();
        const bool prev_canvas43 = canvas43_;
        ImGui::Checkbox("4:3 canvas 640x480", &canvas43_);
        // The canvas view is already scanline-doubled (2x height), so
        // compensate the zoom to keep the apparent content size stable.
        if (canvas43_ != prev_canvas43) {
            zoom_ *= canvas43_ ? 0.5f : 2.0f;
            if (zoom_ < 0.5f) zoom_ = 0.5f;
            if (zoom_ > 8.0f) zoom_ = 8.0f;
        }
        ImGui::SliderFloat("Zoom", &zoom_, 0.5f, 8.0f, "%.2f");

        // Content size in frame units (pre-zoom).
        // Bare frame: uniform 50% scale in half mode.
        // 4:3 canvas: full 559 width, scanline-doubled height (192 -> 384),
        // centered on 640x480 with black bars - the real-output look.
        const float content_w =
            (canvas43_ || !half_width_) ? (float)kOutWidth
                                        : (float)kOutWidth * 0.5f;
        const float content_h =
            canvas43_ ? (float)kOutHeight * 2.0f
                      : (float)kOutHeight * (half_width_ ? 0.5f : 1.0f);
        // NEAREST for pixel-exact / scanline doubling; LINEAR only for the
        // bare half-width downscale.
        const bool linear = half_width_ && !canvas43_;
        glBindTexture(GL_TEXTURE_2D, gl_tex_);
        const int filt = linear ? GL_LINEAR : GL_NEAREST;
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filt);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filt);

        const ImVec2 pos = ImGui::GetCursorScreenPos();
        ImDrawList* dl = ImGui::GetWindowDrawList();
        if (canvas43_) {
            const float cw = 640.0f * zoom_, ch = 480.0f * zoom_;
            dl->AddRectFilled(pos, ImVec2(pos.x + cw, pos.y + ch),
                              IM_COL32(0, 0, 0, 255));
            // Image sticks to the top-left of the canvas (no centering bars).
            dl->AddImage((ImTextureID)(uintptr_t)gl_tex_, pos,
                         ImVec2(pos.x + content_w * zoom_,
                                pos.y + content_h * zoom_));
            ImGui::Dummy(ImVec2(cw, ch));
        } else {
            dl->AddImage((ImTextureID)(uintptr_t)gl_tex_, pos,
                         ImVec2(pos.x + content_w * zoom_,
                                pos.y + content_h * zoom_));
            ImGui::Dummy(ImVec2(content_w * zoom_, content_h * zoom_));
        }
        ImGui::End();

        // ---------------- Render ----------------
        ImGui::Render();
        glViewport(0, 0, (int)ImGui::GetIO().DisplaySize.x,
                   (int)ImGui::GetIO().DisplaySize.y);
        glClearColor(clear_color.x, clear_color.y, clear_color.z,
                     clear_color.w);
        glClear(GL_COLOR_BUFFER_BIT);
        ImGui_ImplOpenGL2_RenderDrawData(ImGui::GetDrawData());
        SDL_GL_SwapWindow(sdl_window_);

        // FPS: one DUT frame per loop iteration, so loop rate == DUT rate.
        // No artificial cap: the user wants the true setup throughput.
        const double loop_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t_loop_start).count();
        loop_ms_ = ui_fps_ > 0.0 ? 0.9 * loop_ms_ + 0.1 * loop_ms
                                 : loop_ms;
        ui_fps_ = 1000.0 / loop_ms_;
    }

    // --- Cleanup ---
    glDeleteTextures(1, &gl_tex_);
    ImGui_ImplOpenGL2_Shutdown();
    ImGui_ImplSDL2_Shutdown();
    ImGui::DestroyContext();
    SDL_GL_DeleteContext(gl_context_);
    SDL_DestroyWindow(sdl_window_);
    SDL_Quit();
    return 0;
}
