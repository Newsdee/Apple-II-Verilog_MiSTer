// unit_tests/level_neg1/gui/main_gui.cpp
//
// imgui + SDL2 + OpenGL3 GUI for the level_neg1 (config -1) CPU harness.
// Built from top module tb_cpu_gui (see tb_cpu_gui.sv): the same isolated
// CPU + memory + savestate bus as tb_cpu, but with NO test sequence and NO
// $finish - this process is the driver.
//
// Controls
//   * "Stall (pause core)" checkbox  -> writes tb_cpu_gui__DOT__stall (the
//     same reg the headless TB's save/restore path drives; the DUT samples
//     it on ce edges, so the core freezes on the next ce pulse).
//   * Space                          -> toggles stall
//   * Esc / window close             -> quit
//   The SDL window is resizable (the imgui window and GL viewport follow
//   the new size each frame).  The "FPS" line counts presented GUI frames
//   using the same wall-clock per-frame measurement as the machine build's
//   sim_video.cpp stats_fps.  The "SIM SPEED" line is the GUI equivalent of
//   the headless CPU_NEG1 SPEED report: a 1-s wall-clock window of
//   ce_count (stall-gated core cycles) -> simulated CPU MHz.  It reads
//   ~0 while the core is stalled (sim time still advances, the core does
//   not), and is display-rate-limited (vsync x slots-per-frame), so it
//   will always be far below the headless throughput.
//
// "Is it being used" - the GUI shows live simulation state every frame:
//   ce_count: the TB's stall-gated ce counter (ticks while the core runs,
//   FREEZES when stalled - the most direct proof the checkbox drives the
//   sim), plus PC/A/X/Y/S/P, IR, core state, the live bus (addr/din/dout/
//   we), and RAM $0200/$0201 which the demo program writes every iteration.
//   The demo program is the same DEX loop as tb_cpu.sv's program P, so
//   registers and RAM are always moving while unstalled.
//
// Headless check of the control path (no window):
//   Vtb_cpu_gui.exe --stall-test
// runs the sim, asserts the stall write, and verifies ce_count advances /
// freezes / advances again.  Prints CPU_NEG1_GUI STALL_TEST PASS/FAIL.
//
// Options
//   --stall-test      run the headless stall verification and exit
//   --run-frames N    quit after N rendered frames (0 = unlimited; used for
//                     automated smoke launches)
#include "Vtb_cpu_gui.h"
#include "Vtb_cpu_gui___024root.h"
#include "verilated.h"

// SDL.h on Windows does `#define main SDL_main` (SDL_main.h) unless
// SDL_MAIN_HANDLED is set — that would compile our `main` as `SDL_main`
// and leave the exe with no entry point (linker then pulls the GUI CRT
// trampoline and fails on `WinMain`).  We keep our own `main`.
#define SDL_MAIN_HANDLED
#include <SDL.h>
#include <GL/gl.h>

#include "imgui.h"
#include "backends/imgui_impl_sdl2.h"
#include "backends/imgui_impl_opengl3.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/time.h>
#endif

// Wall-clock milliseconds (same scheme as sim_video.cpp's stats sampling:
// GetSystemTime on Windows, gettimeofday elsewhere).
static long now_ms()
{
#ifdef _WIN32
	SYSTEMTIME st;
	GetSystemTime(&st);
	return (long)(st.wSecond * 1000 + st.wMilliseconds);
#else
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return (long)(tv.tv_sec) * 1000 + (long)(tv.tv_usec) / 1000;
#endif
}

// Same weak-symbol requirement as main.cpp (verilated_funcs.h declares
// sc_time_stamp() weak; a non-SystemC user program must provide it).
double sc_time_stamp()
{
	return 0.0;
}

// Run `n` time slots of the model using this Verilator 5.050 MSYS2
// --timing protocol (same as main.cpp): eval_step drains a slot,
// nextTimeSlot() is READ-ONLY (returns the next scheduled time), so the
// context time must be advanced explicitly with context.time(next).
static void run_slots(Vtb_cpu_gui* top, VerilatedContext& context, int n)
{
	for (int i = 0; i < n && !context.gotFinish(); i++) {
		if (!top->eventsPending()) break;
		const uint64_t next = top->nextTimeSlot();
		if (next > context.time()) context.time(next);
		top->eval_step();
	}
}

// GUI_CPU_NAME is passed unquoted from the Makefile (-DGUI_CPU_NAME=nmos);
// stringify here (two-level macro: expand the define, then quote).
#define GUI_STR_(x) #x
#define GUI_STR(x) GUI_STR_(x)

int main(int argc, char** argv)
{
	const char* cpu_name = GUI_STR(GUI_CPU_NAME);
	bool stall_test = false;
	int max_frames = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--stall-test") == 0) stall_test = true;
		else if (strcmp(argv[i], "--run-frames") == 0 && i + 1 < argc)
			max_frames = atoi(argv[++i]);
	}

	VerilatedContext context;
	Vtb_cpu_gui* top = new Vtb_cpu_gui(&context);
	top->eval_step();  // prime: run initial blocks (reset sequence) at t=0

	// ------------------------------------------------------------------
	// Headless control-path verification (no SDL, no window).
	// ------------------------------------------------------------------
	if (stall_test) {
		Vtb_cpu_gui___024root* r = top->rootp;
		printf("CPU_NEG1_GUI STALL_TEST cpu=%0s\n", cpu_name);
		run_slots(top, context, 400);            // let reset settle + run
		const uint64_t c0 = r->tb_cpu_gui__DOT__ce_count;
		run_slots(top, context, 300);
		const uint64_t c1 = r->tb_cpu_gui__DOT__ce_count;
		r->tb_cpu_gui__DOT__stall = 1;           // same write the checkbox does
		run_slots(top, context, 300);
		const uint64_t c2 = r->tb_cpu_gui__DOT__ce_count;
		r->tb_cpu_gui__DOT__stall = 0;
		run_slots(top, context, 300);
		const uint64_t c3 = r->tb_cpu_gui__DOT__ce_count;
		printf("  ce_count: run=%llu run=%llu stalled=%llu released=%llu\n",
		       (unsigned long long)c0, (unsigned long long)c1,
		       (unsigned long long)c2, (unsigned long long)c3);
		const int fail = (c1 <= c0) || (c2 != c1) || (c3 <= c2);
		printf("CPU_NEG1_GUI STALL_TEST %s  cpu=%0s  "
		       "(running advances, stall freezes, release resumes)\n",
		       fail ? "FAIL" : "PASS", cpu_name);
		top->final();
		delete top;
		return fail ? 1 : 0;
	}

	// ------------------------------------------------------------------
	// GUI.
	// ------------------------------------------------------------------
	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		printf("ERROR: SDL_Init failed: %s\n", SDL_GetError());
		delete top;
		return 2;
	}
	// Core-profile OpenGL 3.2 context (the imgui OpenGL3 backend needs VAOs).
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, 0);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
	SDL_Window* window = SDL_CreateWindow(
	    "level_neg1 CPU GUI (config -1)", SDL_WINDOWPOS_CENTERED,
	    SDL_WINDOWPOS_CENTERED, 720, 540,
	    SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE);
	if (!window) {
		printf("ERROR: SDL window failed: %s\n", SDL_GetError());
		SDL_Quit();
		delete top;
		return 2;
	}
	SDL_GLContext glctx = SDL_GL_CreateContext(window);
	if (!glctx) {
		printf("ERROR: GL context failed: %s (driver without OpenGL 3.2?)\n",
		       SDL_GetError());
		SDL_DestroyWindow(window);
		SDL_Quit();
		delete top;
		return 2;
	}
	SDL_GL_SetSwapInterval(1);  // vsync

	IMGUI_CHECKVERSION();
	ImGui::CreateContext();
	ImGui_ImplSDL2_InitForOpenGL(window, glctx);
	ImGui_ImplOpenGL3_Init("#version 130");

	printf("CPU_NEG1_GUI START cpu=%0s  (Space=stall toggle, Esc=quit)\n",
	       cpu_name);

	bool running = true;
	bool stall = false;
	int steps_per_frame = 200;  // sim time slots per frame (10 ns each)
	int frame = 0;
	// FPS (per presented frame, mirroring SimVideo::stats_fps)
	long old_time_ms = 0;
	float stats_fps = 0.0f;
	float stats_frame_time_ms = 0.0f;
	// SIM SPEED: 1-s wall-clock window over ce_count (stall-gated core
	// cycles) -> simulated CPU MHz, the GUI analogue of the headless
	// CPU_NEG1 SPEED line.  context.time() (ps) keeps advancing while
	// stalled, so the raw window also shows sim-time-vs-wall compression.
	long speed_anchor_ms = 0;
	uint64_t speed_anchor_ce = 0;
	uint64_t speed_anchor_ps = 0;
	double sim_speed_MHz = 0.0;
	unsigned long long win_dce = 0, win_dsim_ns = 0, win_wall_ms = 0;
	Vtb_cpu_gui___024root* r = top->rootp;

	while (running) {
		// ------------------------------------------------------ events
		SDL_Event e;
		while (SDL_PollEvent(&e)) {
			if (e.type == SDL_QUIT) running = false;
			if (e.type == SDL_KEYDOWN) {
				if (e.key.keysym.sym == SDLK_ESCAPE) running = false;
				if (e.key.keysym.sym == SDLK_SPACE) stall = !stall;
			}
			ImGui_ImplSDL2_ProcessEvent(&e);
		}

		// ------------------------------------------- drive the model
		r->tb_cpu_gui__DOT__stall = stall ? 1 : 0;  // checkbox -> TB reg
		run_slots(top, context, steps_per_frame);

		// ------------------------------------------------------ readout
		const uint32_t ce_count = r->tb_cpu_gui__DOT__ce_count;
		const uint16_t pc = r->tb_cpu_gui__DOT__dut__DOT__reg_pc;
		const uint8_t a = r->tb_cpu_gui__DOT__dut__DOT__reg_a;
		const uint8_t x = r->tb_cpu_gui__DOT__dut__DOT__reg_x;
		const uint8_t y = r->tb_cpu_gui__DOT__dut__DOT__reg_y;
		const uint8_t s = r->tb_cpu_gui__DOT__dut__DOT__reg_s;
		const uint8_t p = r->tb_cpu_gui__DOT__dut__DOT__reg_p;
		const uint8_t ir = r->tb_cpu_gui__DOT__dut__DOT__ir;
		const uint8_t state = r->tb_cpu_gui__DOT__dut__DOT__state;
		const uint16_t addr = r->tb_cpu_gui__DOT__addr;
		const uint8_t din = r->tb_cpu_gui__DOT__din;
		const uint8_t dout = r->tb_cpu_gui__DOT__dout;
		const uint8_t we = r->tb_cpu_gui__DOT__we;

		// ------------------------------------------------------ frame
		int fw, fh;
		SDL_GL_GetDrawableSize(window, &fw, &fh);
		ImGui_ImplOpenGL3_NewFrame();
		ImGui_ImplSDL2_NewFrame();
		ImGui::NewFrame();

		ImGui::SetNextWindowSize(ImVec2(680, 0), ImGuiCond_FirstUseEver);
		ImGui::Begin("level_neg1 CPU GUI - isolated CPU + memory (config -1)");

		// FPS / frame counter (wall clock; same measurement scheme as the
		// machine build's `sim FPS` readout in sim_video.cpp).
		ImGui::Text("frame_count: %d   FPS: %f   (frame time %ld ms)",
		         frame, stats_fps, (long)stats_frame_time_ms);
		ImGui::Text("sim speed (1 s window): %0.4f MHz   (=%llu ce / %llu sim ns / %llu ms wall)",
		         (float)sim_speed_MHz, win_dce, win_dsim_ns, win_wall_ms);
		ImGui::Separator();

		ImGui::Checkbox("Stall (pause core)", &stall);
		ImGui::SameLine(240);
		if (stall) {
			ImGui::TextColored(ImVec4(1.0f, 0.8f, 0.2f, 1.0f),
			                "PAUSED - stall=1, core not advancing");
		} else {
			ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.5f, 1.0f),
			                "RUNNING");
		}

		ImGui::SliderInt("sim time slots per frame", &steps_per_frame, 10, 2000);

		ImGui::Separator();
		ImGui::Text("CPU %0s", cpu_name);
		ImGui::Text("PC=0x%04X  A=0x%02X  X=0x%02X  Y=0x%02X  S=0x%02X  P=0x%02X",
		         pc, a, x, y, s, p);
		ImGui::Text("IR=0x%02X   core state=%0X", ir, state);
		ImGui::Separator();
		ImGui::Text("bus:  addr=0x%04X   din=0x%02X   dout=0x%02X   we=%d",
		         addr, din, dout, we);
		ImGui::Text("RAM $0200=0x%02X   RAM $0201=0x%02X   (written every loop)",
		         r->tb_cpu_gui__DOT__ram0200, r->tb_cpu_gui__DOT__ram0201);
		ImGui::Separator();
		ImGui::Text("ce_count (stall-gated) = %u   sim time = %llu ns",
		         ce_count, (unsigned long long)(context.time() / 100));
		ImGui::ProgressBar((float)(ce_count % 1000) / 999.0f,
		                ImVec2(-1, 0),
		                stall ? "frozen (stalled)" : "active");
		ImGui::TextDisabled(
		    "Space toggles stall, Esc quits.  ce_count and the bar freeze "
		    "while stalled - proof the checkbox drives the sim.");

		ImGui::End();
		ImGui::Render();

		glViewport(0, 0, fw, fh);
		glClearColor(0.10f, 0.10f, 0.12f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
		SDL_GL_SwapWindow(window);

		// Sample once per presented frame (the machine build samples its
		// stats_fps on each video-frame vsync; the presented frame is the
		// GUI equivalent).
		const long t_ms = now_ms();
		if (old_time_ms > 0) {
			const long dt = t_ms - old_time_ms;
			if (dt > 0) {
				stats_frame_time_ms = (float)dt;
				stats_fps = 1000.0f / (float)dt;
			}
		}
		old_time_ms = t_ms;

		// Close/re-anchor the sim-speed window every ~1 s of wall clock.
		if (speed_anchor_ms == 0) {
			speed_anchor_ms = (long)t_ms;
			speed_anchor_ce = ce_count;
			speed_anchor_ps = context.time();
		} else if (t_ms - speed_anchor_ms >= 1000) {
			win_dce = (unsigned long long)(ce_count - speed_anchor_ce);
			win_dsim_ns = (unsigned long long)((context.time() - speed_anchor_ps) / 100);
			win_wall_ms = (unsigned long long)(t_ms - speed_anchor_ms);
			sim_speed_MHz = (double)win_dce / ((double)win_wall_ms / 1000.0) / 1.0e6;
			speed_anchor_ms = (long)t_ms;
			speed_anchor_ce = ce_count;
			speed_anchor_ps = context.time();
		}

		if (frame % 240 == 0)
			printf("CPU_NEG1_GUI FRAME %d  stall=%d  ce_count=%u  pc=0x%04X  sim=%0.4f MHz\n",
			       frame, (int)stall, ce_count, pc, (float)sim_speed_MHz);
		if (max_frames > 0 && ++frame >= max_frames) {
			running = false;
			printf("CPU_NEG1_GUI run-frames limit reached (%d), exiting\n",
			       max_frames);
		}
	}

	ImGui_ImplOpenGL3_Shutdown();
	ImGui_ImplSDL2_Shutdown();
	ImGui::DestroyContext();
	SDL_GL_DeleteContext(glctx);
	SDL_DestroyWindow(window);
	SDL_Quit();

	top->final();
	delete top;
	return 0;
}
