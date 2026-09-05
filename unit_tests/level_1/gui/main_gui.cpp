// unit_tests/level_1/gui/main_gui.cpp
//
// imgui + SDL2 + OpenGL3 GUI for the level-1 machine harness.  Built from
// top module tb_l1_gui (see tb_l1_gui.sv): the same machine core
// (rtl/apple2.v) + real PS/2 keyboard (rtl/keyboard.v) as tb_l1, but
// with NO test sequence and NO $finish - this process is the driver.
//
// What you see: the machine's NATIVE monochrome VIDEO signal, sampled
// once per 14.318 MHz master cycle (correct for TEXT-mode content; the
// boot screen and the Apple logo are text).  The machine cold-boots on
// start - there is a ~294 ms (sim) power-on hold (2^22 master cycles) before the ROM starts
// - and then the BIOS draws the striped Apple logo on the text screen.
// The "Cold reboot" button re-triggers the machine's cold reset (the
// same reset_cold input the host's "Cold Reset" uses) to watch it again.
//
// Controls
//   * Pause CPU checkbox / F9    -> writes tb_l1_gui.stall (the CPU
//     freezes on the next master edge; the video keeps scanning, as on
//     the machine)
//   * Cold reboot button         -> one tick of reset_cold = full cold
//     power-on sequence again (POR hold + ROM boot + Apple logo)
//   * Alt+Q / window close       -> quit
//   * All other keys             -> forwarded to the machine's PS/2 port
//     as Apple //e scan codes (the //e's own code set per the junction
//     table in rtl/keyboard.v - NOT PC set 1); one event per rendered
//     frame; modifiers are held until the physical key is released
//
// FPS / speed readouts (all wall-clock based)
//   * video FPS   - presented VIDEO frames per second: how fast the
//                   simulated machine generates complete video frames
//                   (this is the "sim speed" expressed in frames)
//   * render FPS  - GUI frames per second (no vsync - loop runs at
//                   model throughput; same measurement scheme as the
//                   machine build's sim_video.cpp stats_fps)
//   * sim speed   - 1-s wall window of master-clock cycles
//                   (context.time()) -> simulated MHz in the 14.318
//                   MHz domain
//
// Headless smoke (no window):
//   Vtb_l1_gui.exe +cpu=0 --headless [N]
//   Vtb_l1_gui.exe +cpu=0 --headless 3 --selfkey   # boot + PS/2 'A' test
// runs the machine until N video frames have completed (default 3) and
// checks the last captured frame is not blank (white-pixel ink > 0 =
// the ROM actually drew the logo / cursor).  Prints L1_GUI SMOKE
// PASS/FAIL and exits non-zero on failure.
//
//   --dump-gl  (windowed, native variant) dump the exact buffer uploaded
//              to the GL texture (the displayed image) to
//              unit_tests/level_1/out/l1_glbuf_frame.pbm on exit —
//              the display-path diagnostic (P1, rows top-to-bottom).
//
// L1_VGA build variant (+define+L1_VGA / -DL1_VGA, `make gui_vga`):
// TEMPORARY A/B path - the machine's video is routed through the real
// vga_controller (same wiring as rtl/apple2_top.v) and the harness
// samples its RGB output with the whole-machine SimVideo::Clock logic
// (verilator/sim/sim_video.cpp, one sample per vga pixel strobe = every
// 2nd master cycle), shown via a GL texture + ImGui::Image - the exact
// display path of the working whole-machine sim (verilator/sim).
//
// The binary MUST run with the process CWD at the REPO ROOT: the DUT's
// $readmemh ROM paths (rtl/roms/*.hex) are CWD-relative.
#include "Vtb_l1_gui.h"
#include "Vtb_l1_gui___024root.h"
#include "verilated.h"

// SDL.h on Windows does `#define main SDL_main` (SDL_main.h) unless
// SDL_MAIN_HANDLED is set — that would compile our `main` as `SDL_main`
// and leave the exe with no entry point.  We keep our own `main`.
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

// Video geometry: the TB samples one VIDEO bit per master cycle; the
// native text line measures 560 master cycles (tb_l1 T1 pin), so render
// 560 px wide.  The frame buffer holds 512 lines; the V-period in lines
// (measured live in frame_lines) fits with margin.
#define VID_W 560
#define VID_H 512

// Wall-clock milliseconds (same scheme as sim_video.cpp's stats
// sampling: GetSystemTime on Windows, gettimeofday elsewhere).
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

// Same weak-symbol requirement as the headless mains (verilated_funcs.h
// declares sc_time_stamp() weak; a non-SystemC user program must
// provide it).
double sc_time_stamp()
{
	return 0.0;
}

// Run `n` time slots of the model using this Verilator 5.050 MSYS2
// --timing protocol (same as the headless mains): eval_step drains a
// slot, nextTimeSlot() is READ-ONLY (returns the next scheduled time),
// so the context time must be advanced explicitly with context.time().
static void run_slots(Vtb_l1_gui* top, VerilatedContext& context, int n)
{
	for (int i = 0; i < n && !context.gotFinish(); i++) {
		if (!top->eventsPending()) break;
		const uint64_t next = top->nextTimeSlot();
		if (next > context.time()) context.time(next);
		top->eval_step();
	}
}

// ---------------------------------------------------------------------------
// Physical key -> Apple //e PS/2 scan code.
//
// Protocol (rtl/keyboard.v, packed exactly like the whole-machine
// sim_input.cpp:642-652): PS2_Key = {stb[10], pressed[9], ext[8],
// code[7:0]} - bit 10 strobe, bit 9 key state (1 = press, 0 = release),
// bit 8 extended flag, [7:0] the code.
//
// The //e keyboard uses its OWN scan code set (the junction table inside
// rtl/keyboard.v), not the PC set-1 codes: e.g. A = 0x1C (0x1E on a PC),
// Return = 0x5A, Space = 0x29, Backspace = 0x66 (the //e "del" key,
// mapped to the left junction), Up = 0x75 with ext.  Lookup is by SDL
// *scancode* (layout-independent); unmapped keys are simply not sent.
// `mod` marks modifier keys (shift/ctrl/apple): for those the GUI queues
// the release on the physical key-up so the machine's modifier state is
// held while the next key is typed; other keys get a press+release pair
// automatically.  Note the machine's own F9 (video toggle) is 0x01 and is
// NOT reachable here: the GUI reserves F9 for pause.
// ---------------------------------------------------------------------------
static int ps2_make_code(SDL_Scancode sc, uint8_t* code, bool* ext, bool* mod)
{
	*ext = false;
	*mod = false;
	switch (sc) {
	// letters (//e code set, not PC set 1)
	case SDL_SCANCODE_A: *code = 0x1C; break;
	case SDL_SCANCODE_B: *code = 0x32; break;
	case SDL_SCANCODE_C: *code = 0x21; break;
	case SDL_SCANCODE_D: *code = 0x23; break;
	case SDL_SCANCODE_E: *code = 0x24; break;
	case SDL_SCANCODE_F: *code = 0x2B; break;
	case SDL_SCANCODE_G: *code = 0x34; break;
	case SDL_SCANCODE_H: *code = 0x33; break;
	case SDL_SCANCODE_I: *code = 0x43; break;
	case SDL_SCANCODE_J: *code = 0x3B; break;
	case SDL_SCANCODE_K: *code = 0x42; break;
	case SDL_SCANCODE_L: *code = 0x4B; break;
	case SDL_SCANCODE_M: *code = 0x3A; break;
	case SDL_SCANCODE_N: *code = 0x31; break;
	case SDL_SCANCODE_O: *code = 0x44; break;
	case SDL_SCANCODE_P: *code = 0x4D; break;
	case SDL_SCANCODE_Q: *code = 0x15; break;
	case SDL_SCANCODE_R: *code = 0x2D; break;
	case SDL_SCANCODE_S: *code = 0x1B; break;
	case SDL_SCANCODE_T: *code = 0x2C; break;
	case SDL_SCANCODE_W: *code = 0x1D; break;
	case SDL_SCANCODE_X: *code = 0x22; break;
	case SDL_SCANCODE_Y: *code = 0x35; break;
	case SDL_SCANCODE_Z: *code = 0x1A; break;
	// digits
	case SDL_SCANCODE_0: *code = 0x45; break;
	case SDL_SCANCODE_1: *code = 0x16; break;
	case SDL_SCANCODE_2: *code = 0x1E; break;
	case SDL_SCANCODE_3: *code = 0x26; break;
	case SDL_SCANCODE_4: *code = 0x25; break;
	case SDL_SCANCODE_5: *code = 0x2E; break;
	case SDL_SCANCODE_6: *code = 0x36; break;
	case SDL_SCANCODE_7: *code = 0x3D; break;
	case SDL_SCANCODE_8: *code = 0x3E; break;
	case SDL_SCANCODE_9: *code = 0x46; break;
	// keys (//e "del" = 0x66, mapped to the left junction)
	case SDL_SCANCODE_RETURN:    *code = 0x5A; break;
	case SDL_SCANCODE_SPACE:     *code = 0x29; break;
	case SDL_SCANCODE_BACKSPACE: *code = 0x66; break;
	case SDL_SCANCODE_TAB:       *code = 0x0D; break;
	case SDL_SCANCODE_ESCAPE:    *code = 0x76; break;
	// modifiers (machine shift/ctrl/apple states)
	case SDL_SCANCODE_LSHIFT:   *code = 0x12; *mod = true; break;
	case SDL_SCANCODE_RSHIFT:  *code = 0x59; *mod = true; break;
	case SDL_SCANCODE_LCTRL:   *code = 0x14; *mod = true; break;
	case SDL_SCANCODE_LALT:    *code = 0x11; *mod = true; break; // closed apple
	case SDL_SCANCODE_LGUI:    *code = 0x1F; *mod = true; break; // open apple
	case SDL_SCANCODE_CAPSLOCK:   *code = 0x58; break;
	case SDL_SCANCODE_F2:        *code = 0x06; break;  // machine soft reset
	// arrows (extended)
	case SDL_SCANCODE_UP:    *code = 0x75; *ext = true; break;
	case SDL_SCANCODE_DOWN:  *code = 0x72; *ext = true; break;
	case SDL_SCANCODE_LEFT:  *code = 0x6B; *ext = true; break;
	case SDL_SCANCODE_RIGHT: *code = 0x74; *ext = true; break;
	default: return 0;
	}
	return 1;
}
static uint16_t g_keyq[16];   // {release<<15 | ext<<14 | code[7:0]}
static int      g_keyq_n = 0;

// Copy the last completed frame from the TB into `buf` (VID_W x VID_H,
// black-filled uint32 ARGB pixels) and return the white-pixel count
// ("ink").  The TB's `frame` reg array (512 x 1024-bit lines) maps to
// VlUnpacked<VlWide<32>, 512>: each line is 32 x 32-bit words (EData is
// 32-bit in this Verilator), word 0 = bits [31:0].
static uint32_t extract_frame(const Vtb_l1_gui___024root* r, uint32_t* buf)
{
	memset(buf, 0, (size_t)VID_W * VID_H * sizeof(uint32_t));
	const uint32_t rows16 = r->tb_l1_gui__DOT__frame_lines;
	const int rows = rows16 < VID_H ? (int)rows16 : VID_H;
	const VlUnpacked<VlWide<32>, 512>& f = r->tb_l1_gui__DOT__frame;
	uint32_t ink = 0;
	for (int y = 0; y < rows; y++) {
		for (int x = 0; x < VID_W; x++) {
			const uint32_t w = f[y][x >> 5];          // 32-bit word
			const uint8_t px = (uint8_t)(w >> (x & 31)) & 1u;
			buf[(size_t)y * VID_W + x] = px ? 0xFFFFFFFFu : 0u;
			ink += px;
		}
	}
	return ink;
}

// CPU name from the +cpu= / cpu= command-line arg (the TB reads the same
// plusarg).  Default: nmos.
static const char* cpu_from_argv(int argc, char** argv)
{
	for (int i = 1; i < argc; i++) {
		if (strncmp(argv[i], "+cpu=", 5) == 0 || strncmp(argv[i], "cpu=", 4) == 0) {
			return argv[i][strlen(argv[i]) - 1] == '1' ? "wdc65c02" : "nmos6502";
		}
	}
	return "nmos6502";
}

#ifdef L1_VGA
// ---------------------------------------------------------------------------
// L1_VGA (temporary A/B): the whole-machine video path, ported from
// verilator/sim/sim_video.cpp (SimVideo::Clock): edge-triggered line/frame
// counters driven by the vga_controller's HBL/VBL/VS + one RGB sample per
// vga pixel strobe.  In sim.v the pixel strobe (CE_PIXEL) runs at half the
// master rate, so the C++ harness samples every 2nd master cycle.
// 640x240 RGBA, pixels are 0x00RRGGBB (little-endian R,G,B,AA in memory,
// uploaded as GL_RGBA - same convention as sim_video.cpp's output_ptr).
// ---------------------------------------------------------------------------
#define VGA_W 640
#define VGA_H 240

static uint32_t g_vga_buf[VGA_W * VGA_H];

struct VgaSampler {
	int x = 0;
	int y = 0;
	bool last_hb = false;
	bool last_vb = false;
	bool last_vs = false;
	bool frame_ready = false;
	void clock(bool hb, bool vb, bool vs, uint32_t c)
	{
		const bool de = !(hb || vb);
		if (!vb) {
			if (last_hb && !hb) {  // hblank falling edge = next line
				y++;
				x = 0;
			}
			if (de) x++;
		}
		if (last_vs && !vs) {  // vsync falling edge = frame start
			y = 0;
			frame_ready = true;
		}
		if (de) {
			int xx = x - 1;
			int yy = y - 1;
			if (xx < 0) xx = 0;
			if (xx > VGA_W - 1) xx = VGA_W - 1;
			if (yy < 0) yy = 0;
			if (yy > VGA_H - 1) yy = VGA_H - 1;
			g_vga_buf[(size_t)yy * VGA_W + xx] = c;
		}
		last_hb = hb;
		last_vb = vb;
		last_vs = vs;
	}
};

// Run `n` slots AND sample the vga output once per pixel strobe.  One
// 35 ns slot = half a master cycle, so the strobe (1 per 2 master cycles)
// lands every 4 slots.  The vga outputs are read from the TB's dbg_vga_*
// REGISTERS (latched on every master posedge) - the top-level wires are
// stale in C++ (see the tb_l1_gui.sv note).  Sample on slot parity 1
// (mid-cycle): the register then holds the value from the just-finished
// master cycle.
static void run_slots_vga(Vtb_l1_gui* top, VerilatedContext& context, int n,
			    VgaSampler& s)
{
	uint32_t sc = 0;
	for (int i = 0; i < n && !context.gotFinish(); i++) {
		if (!top->eventsPending()) break;
		const uint64_t next = top->nextTimeSlot();
		if (next > context.time()) context.time(next);
		top->eval_step();
		if ((sc & 3) == 1) {
			const Vtb_l1_gui___024root* r = top->rootp;
			s.clock((bool)r->tb_l1_gui__DOT__dbg_vga_hb,
				(bool)r->tb_l1_gui__DOT__dbg_vga_vb,
				(bool)r->tb_l1_gui__DOT__dbg_vga_vs,
				0xFF000000u
				| ((uint32_t)r->tb_l1_gui__DOT__dbg_vga_b << 16)
				| ((uint32_t)r->tb_l1_gui__DOT__dbg_vga_g << 8)
				| (uint32_t)r->tb_l1_gui__DOT__dbg_vga_r);
		}
		sc++;
	}
}

// Non-black pixel count of the vga frame buffer.
static uint32_t vga_ink()
{
	uint32_t ink = 0;
	for (int i = 0; i < VGA_W * VGA_H; i++)
		ink += (g_vga_buf[i] & 0x00FFFFFFu) != 0u;
	return ink;
}
#endif  // L1_VGA

#ifndef L1_VGA
// Native variant display buffer: 560 x NAT_H (262 measured lines/frame),
// 0xAARRGGBB (alpha always 0xFF), uploaded as GL_RGBA.  Shown through the
// SAME texture + ImGui::Image path as the VGA variant and the whole-machine
// sim (sim_video.cpp) - glDrawPixels on the default framebuffer is a no-op
// on this driver (verified via --dump-gl: the buffer data was correct), so
// the image must go through a texture.
#define NAT_H 262
static uint32_t g_nat_buf[VID_W * NAT_H];

// Native GUI outer-window size for a given integer scale.  The stats
// panel is pinned at the left (300 px wide, full window height, always
// visible); the video sits to its right.
static void l1_window_size(int scale, bool half_h, int* w, int* h)
{
	const int vid_w = VID_W * scale / (half_h ? 2 : 1);
	const int vid_h = NAT_H * scale;
	*w = vid_w + 356;  // 300 panel + 32 gap + 24 margin
	*h = (vid_h > 480 ? vid_h : 480) + 40;
}
#endif  // L1_VGA

int main(int argc, char** argv)
{
	bool headless = false;
	int headless_frames = 3;
	bool selfkey = false;
	bool reboot_test = false;
	int max_frames = 0;
	int scale = 3;
	bool half_h = true;
	bool dump_gl = false;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--headless") == 0) {
			headless = true;
			if (i + 1 < argc && atoi(argv[i + 1]) >= 1) headless_frames = atoi(argv[++i]);
		} else if (strcmp(argv[i], "--selfkey") == 0) {
			selfkey = true;  // with --headless: synthetic PS/2 'A' test
		} else if (strcmp(argv[i], "--reboot") == 0) {
			reboot_test = true;  // with --headless: cold-reboot x2 test
		} else if (strcmp(argv[i], "--run-frames") == 0 && i + 1 < argc) {
			max_frames = atoi(argv[++i]);
		} else if (strcmp(argv[i], "--scale") == 0 && i + 1 < argc) {
			scale = atoi(argv[++i]);
			if (scale < 1) scale = 1;
			if (scale > 3) scale = 3;
		} else if (strcmp(argv[i], "--dump-gl") == 0) {
			dump_gl = true;
		}
	}
	const char* cpu_name = cpu_from_argv(argc, argv);

	VerilatedContext context;
	// tb_l1_gui reads +cpu= via $value$plusargs: the context must be told
	// about the process argv first (same requirement as the headless
	// mains; without this Verilator aborts on the first plusarg use).
	context.commandArgs(argc, argv);
	Vtb_l1_gui* top = new Vtb_l1_gui(&context);
	top->eval_step();  // prime: run initial blocks at t=0
	Vtb_l1_gui___024root* r = top->rootp;

	// ------------------------------------------------------------------
	// Headless smoke: run the machine, wait for video frames, verify the
	// last one is not blank.  No SDL, no window.
	// ------------------------------------------------------------------
	if (headless) {
#ifdef L1_VGA
		printf("L1_GUI HEADLESS (VGA A/B) cpu=%s  (waiting for %d vga frames; "
		       "sim includes the 2^22-cycle power-on hold)\n",
		       cpu_name, headless_frames);
		if (selfkey)
			printf("  (selfkey not supported in the VGA A/B build; plain smoke only)\n");
		for (size_t i = 0; i < sizeof(g_vga_buf) / sizeof(g_vga_buf[0]); i++)
			g_vga_buf[i] = 0xFF000000u;
		VgaSampler vga_s;
		const long budget_slots = 120000000L;  // ~4.2 s of machine time
		long slots = 0;
		int presented = 0;
		bool por_released = false;
		uint32_t last_ink = 0;
		while (presented < headless_frames && slots < budget_slots
		       && !context.gotFinish()) {
			run_slots_vga(top, context, 200000, vga_s);
			slots += 200000;
			const long sim_ns = (long)(context.time() / 1000);
			if (!por_released && r->tb_l1_gui__DOT__power_on_reset == 0) {
				por_released = true;
				printf("  POR released at sim=%ld ns  (flash_div=$%06x)\n",
				       sim_ns, (unsigned)r->tb_l1_gui__DOT__flash_div);
			}
			if (vga_s.frame_ready) {
				vga_s.frame_ready = false;
				if (!por_released) continue;  // pre-boot blank frame
				last_ink = vga_ink();
				presented++;
				printf("  vga frame %d   ink=%u  sim=%llu ns\n",
				       presented, last_ink,
				       (unsigned long long)(context.time() / 1000));
				if (presented >= headless_frames) {
					// PPM dump of the last frame (RGB, human
					// viewable) for visual inspection.
					FILE* fp = fopen("unit_tests/level_1/out/l1_gui_vga_frame.ppm",
							"wb");
					if (fp) {
						fprintf(fp, "P3\n%d %d\n255\n", VGA_W, VGA_H);
						for (int i = 0; i < VGA_W * VGA_H; i++) {
							const uint32_t p = g_vga_buf[i];
							fprintf(fp, "%u %u %u\n",
								(unsigned)(p & 0xFFu),
								(unsigned)((p >> 8) & 0xFFu),
								(unsigned)((p >> 16) & 0xFFu));
						}
						fclose(fp);
						printf("  PPM dumped: unit_tests/level_1/out/l1_gui_vga_frame.ppm\n");
					}
				}
			}
		}
		const int pass = presented >= headless_frames && last_ink > 0;
		printf("L1_GUI VGA SMOKE %s  cpu=%s  frames=%d/%d  ink=%u  sim_time=%llu ns\n",
		       pass ? "PASS" : "FAIL", cpu_name, presented, headless_frames,
		       last_ink, (unsigned long long)(context.time() / 1000));
		top->final();
		delete top;
		return pass ? 0 : 1;
#else
		printf("L1_GUI HEADLESS cpu=%s  (waiting for %d video frames; "
		       "sim includes the 2^22-cycle power-on hold)\n",
		       cpu_name, headless_frames);
		const long budget_slots = 360000000L;  // ~2.5 s of machine time
		long slots = 0;
		int presented = 0;
		bool por_released = false;
		uint32_t last_ink = 0;
		uint32_t last_rows = 0;
		long last_hb_sim_ns = -1;
		while (presented < headless_frames && slots < budget_slots
		       && !context.gotFinish()) {
			run_slots(top, context, 200000);
			slots += 200000;
			const long sim_ns = (long)(context.time() / 1000);
			if (!por_released && r->tb_l1_gui__DOT__power_on_reset == 0) {
				por_released = true;
				printf("  POR released at sim=%ld ns  (flash_div=$%06x)\n",
				       sim_ns, (unsigned)r->tb_l1_gui__DOT__flash_div);
			}
			if (last_hb_sim_ns < 0 || sim_ns - last_hb_sim_ns >= 20000000L) {
				last_hb_sim_ns = sim_ns;
				printf("  sim %12ld ns  lines=%d  last_len=%u last_act=%u "
				       "vbl_falls=%d  cpu_cycles=%u  screen_ink=%u "
				       "addr_last=$%04x addr_chg=%u clk_cnt=%u div=%06x "
				       "rst=%d por=%d text_mode=%d regs=%016llx\n",
				       sim_ns,
				       (int)r->tb_l1_gui__DOT__line_cnt,
				       (unsigned)r->tb_l1_gui__DOT__last_len,
				       (unsigned)r->tb_l1_gui__DOT__last_act,
				       (int)r->tb_l1_gui__DOT__frame_count,
				       (unsigned)r->tb_l1_gui__DOT__phzf_cnt,
				       (unsigned)r->tb_l1_gui__DOT__screen_ink,
				       (unsigned)r->tb_l1_gui__DOT__dbg_addr_last,
				       (unsigned)r->tb_l1_gui__DOT__dbg_addr_chg,
				       (unsigned)r->tb_l1_gui__DOT__dbg_clk_cnt,
				       (unsigned)r->tb_l1_gui__DOT__flash_div,
				       (int)r->tb_l1_gui__DOT__reset_sync,
				       (int)r->tb_l1_gui__DOT__power_on_reset,
				       (int)r->tb_l1_gui__DOT__text_mode_s,
				       (unsigned long long)r->tb_l1_gui__DOT__w_dbg_regs);
			}
			if (r->tb_l1_gui__DOT__frame_valid) {
				r->tb_l1_gui__DOT__frame_valid = 0;
				if (!por_released) continue;  // pre-boot blank frame
				uint32_t buf[VID_W * VID_H];
				last_ink = extract_frame(r, buf);
				last_rows = r->tb_l1_gui__DOT__frame_lines;
				presented++;
				printf("  video frame %d   rows=%u ink=%u  sim=%llu ns\n",
				       presented, last_rows, last_ink,
				       (unsigned long long)(context.time() / 1000));
			// keep the LAST frame (final screen state) for visual inspection
			if (presented >= headless_frames) {
				FILE* fp =
				    fopen("unit_tests/level_1/out/l1_gui_frame.pbm", "w");
				if (fp) {
					const VlUnpacked<VlWide<32>, 512>& f =
					    r->tb_l1_gui__DOT__frame;
					fprintf(fp, "P1\n%d %d\n", VID_W, (int)last_rows);
					for (int y = 0; y < (int)last_rows; y++)
						for (int x = 0; x < VID_W; x++) {
							const uint32_t w = f[y][x >> 5];
							fputc((w >> (x & 31)) & 1u ? '1' : '0', fp);
							fputc(' ', fp);
						}
					fclose(fp);
				}
			}
		}
	}
	// --selfkey (headless only): after the boot frames, drive a synthetic
	// PS/2 'A' press+release through the exact path the GUI uses (stb
	// held 60 master cycles, then dropped) and verify the ROM monitor
	// reads it from $C000: the sticky dbg_rd_k_hi latch must capture
	// 0xC1 (key_pressed=1 | ASCII 'A'=0x41).  rd_cnt climbing without
	// 0xC1 means the machine polls but the keyboard chain dropped the
	// key; rd_cnt frozen means the ROM never polls $C000.
	int selfkey_pass = 1;  // 1 unless --selfkey ran and failed
	if (selfkey) {
		const long sk_rd0 = (long)r->tb_l1_gui__DOT__dbg_rd_cnt;
		const long sk_krd0 = (long)r->tb_l1_gui__DOT__dbg_k_rd_cnt;
		const long sk_t0 = (long)(context.time() / 1000);
		const uint16_t sk_press = (1u << 10) | (1u << 9) | 0x1Cu;  // A press
		const uint16_t sk_rel   = (1u << 10) | 0x1Cu;               // A release
		for (int c = 0; c < 60; c++) {
			r->tb_l1_gui__DOT__ps2_key = sk_press;
			run_slots(top, context, 1);
		}
		for (int c = 0; c < 60; c++) {
			r->tb_l1_gui__DOT__ps2_key = sk_rel;
			run_slots(top, context, 1);
		}
		r->tb_l1_gui__DOT__ps2_key = 0;
		const long sk_budget_ns = 2000000000L;  // 2 s of machine time
		int sk_caught = 0;
		long sk_last_rep = 0;
		while ((long)(context.time() / 1000) - sk_t0 < sk_budget_ns
		       && !context.gotFinish()) {
			run_slots(top, context, 100000);
			if (r->tb_l1_gui__DOT__dbg_k_rd_caught == 0xC1u) {
				sk_caught = 1;
				break;
			}
			if ((long)(context.time() / 1000) - sk_t0 - sk_last_rep >= 500000000L) {
				sk_last_rep += 500000000L;
				printf("  selfkey t=%3lld ms rd_cnt=%lu k_rd_cnt=%lu "
				       "k_val=0x%02X k_caught=0x%02X addr=$%04x "
				       "rom_addr=$%04x\n",
				       sk_last_rep / 1000000,
				       (unsigned long)r->tb_l1_gui__DOT__dbg_rd_cnt,
				       (unsigned long)r->tb_l1_gui__DOT__dbg_k_rd_cnt,
				       (unsigned)r->tb_l1_gui__DOT__dbg_k_rd_val,
				       (unsigned)r->tb_l1_gui__DOT__dbg_k_rd_caught,
				       (unsigned)r->tb_l1_gui__DOT__w_addr,
				       (unsigned)r->tb_l1_gui__DOT__w_dbg_roma);
			}
		}
		const long sk_rd1 = (long)r->tb_l1_gui__DOT__dbg_rd_cnt;
		const long sk_krd1 = (long)r->tb_l1_gui__DOT__dbg_k_rd_cnt;
		const uint8_t sk_khi = r->tb_l1_gui__DOT__dbg_k_rd_caught;
		selfkey_pass = sk_caught;
		printf("L1_GUI SELFKEY %s  cpu=%s  A-read=0x%02X  rd_cnt %lu->%lu "
		       "k_rd_cnt %lu->%lu  window=%.1f ms\n",
		       sk_caught ? "PASS" : "FAIL", cpu_name, (unsigned)sk_khi,
		       (unsigned long)sk_rd0, (unsigned long)sk_rd1,
		       (unsigned long)sk_krd0, (unsigned long)sk_krd1,
		       ((context.time() / 1000.0 - sk_t0) / 1e6));
		if (!sk_caught)
			printf("  (0xC1 never read on $C000: k_rd_cnt frozen => ROM "
			       "not polling the keyboard; climbing with 0xC1 absent "
			       "=> keyboard chain dropped the key)\n");
	}
	// --reboot (headless only): cold-reboot the machine TWICE exactly the
	// way the GUI "Cold reboot" button does (set reset_cold, run a few
	// slots, clear it) and verify after each: (1) the pulse was sampled
	// by the reset chain (power_on_reset re-asserts), (2) the 2^22-cycle
	// power-on hold re-runs and releases, (3) a fresh NON-BLANK video
	// frame arrives (the machine really re-booted and drew - the Apple
	// logo).  This isolates the TB/machine reboot path from the ImGui
	// click layer (see the windowed "cold reboot stops working" report).
	int reboot_pass = 1;  // 1 unless --reboot ran and failed
	if (reboot_test) {
		for (int rb = 1; rb <= 2; rb++) {
			const uint32_t div0 = r->tb_l1_gui__DOT__flash_div;
			r->tb_l1_gui__DOT__reset_cold = 1;
			run_slots(top, context, 1000);
			r->tb_l1_gui__DOT__reset_cold = 0;
			const int reasserted = (r->tb_l1_gui__DOT__power_on_reset == 1);
			long rb_budget = 400000000L;  // ~2.8 s machine time
			int released = 0;
			while (rb_budget-- > 0 && !context.gotFinish()) {
				run_slots(top, context, 100000);
				if (r->tb_l1_gui__DOT__power_on_reset == 0) {
					released = 1;
					break;
				}
			}
			int drew = 0;
			uint32_t rb_ink = 0;
			rb_budget = 400000000L;
			while (rb_budget-- > 0 && !drew && !context.gotFinish()) {
				run_slots(top, context, 100000);
				if (r->tb_l1_gui__DOT__frame_valid) {
					r->tb_l1_gui__DOT__frame_valid = 0;
					uint32_t buf[VID_W * VID_H];
					rb_ink = extract_frame(r, buf);
					if (rb_ink > 0) drew = 1;
				}
			}
			printf("L1_GUI REBOOT %d: pulse %s  POR-re-release %s  "
			       "new-frame %s  (ink=%u  div0=$%06x)\n",
			       rb, reasserted ? "OK" : "LOST",
			       released ? "OK" : "TIMEOUT", drew ? "OK" : "TIMEOUT",
			       (unsigned)rb_ink, (unsigned)div0);
			if (!reasserted || !released || !drew) reboot_pass = 0;
		}
		printf("L1_GUI REBOOT %s  cpu=%s\n",
		       reboot_pass ? "PASS" : "FAIL", cpu_name);
	}
	const int pass = presented >= headless_frames && last_ink > 0
	    && selfkey_pass && reboot_pass;
	printf("L1_GUI SMOKE %s  cpu=%s  frames=%d/%d  frame_lines=%u  ink=%u  sim_time=%llu ns\n",
	       pass ? "PASS" : "FAIL", cpu_name, presented, headless_frames,
	       last_rows, last_ink, (unsigned long long)(context.time() / 1000));
	if (presented >= headless_frames && last_ink == 0)
		printf("  (all frames blank - the ROM did not draw the logo; check DUT)\n");
	if (presented < headless_frames)
		printf("  (slot budget reached before %d frames; sim may be slow)\n",
		       headless_frames);
	top->final();
	delete top;
	return pass ? 0 : 1;
#endif  // L1_VGA headless
	}

	// ------------------------------------------------------------------
	// Windowed GUI: SDL2 + OpenGL3 + imgui.  The video frame is shown via
	// a GL texture with ImGui::Image - the same display path as the
	// whole-machine sim and the L1_VGA variant (glDrawPixels was a
	// no-op on this driver); the imgui overlay shows FPS, sim speed,
	// live geometry and the controls.
	//   * Pause checkbox / Space     -> writes stall (CPU held, the
	//     video keeps scanning, as on the machine)
	//   * "Cold reboot" button       -> pulses reset_cold: the TB
	//     re-arms the power-on chain (2^22-cycle hold, $03F4 cleared)
	//   * Esc / window close         -> quit
	// ------------------------------------------------------------------
	if (SDL_Init(SDL_INIT_VIDEO) != 0) {  // SDL2: keyboard events come with video
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
	char wtitle[128];
#ifdef L1_VGA
	snprintf(wtitle, sizeof(wtitle), "Apple II level_1 VGA A/B (%s)", cpu_name);
	const int win_w = VGA_W * scale;
	const int win_h = (VGA_H + 300) * scale;
#else
	snprintf(wtitle, sizeof(wtitle), "Apple II level_1 GUI (%s)", cpu_name);
	int win_w = 0, win_h = 0;
	l1_window_size(scale, half_h, &win_w, &win_h);
#endif
	SDL_Window* window = SDL_CreateWindow(
	    wtitle, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
	    win_w, win_h,
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
	SDL_GL_SetSwapInterval(0);  // no vsync - run the GUI loop at model
	// throughput, like the whole-machine sim (sim_video.cpp's
	// SDL_GL_SetSwapInterval(0)); the sim speed then matches the
	// headless throughput instead of 60 Hz x steps_per_frame.
	//
	// Pixel store: the blit buffer is tightly packed 3-byte (RGB)
	// pixels.  The DEFAULT GL_UNPACK_ALIGNMENT (4) is a spec violation
	// for 3-byte items - driver behavior is then undefined (observed:
	// black window).  1 = tightly packed, spec-correct.
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

	IMGUI_CHECKVERSION();
	ImGui::CreateContext();
	// No ini persistence: the pinned position (top-left) and the
	// first-use default size below must apply on every run.  (The
	// whole-machine sim keeps its own ini handling; this harness
	// writes none.)
	ImGui::GetIO().IniFilename = NULL;
	ImGui_ImplSDL2_InitForOpenGL(window, glctx);
	ImGui_ImplOpenGL3_Init("#version 130");

	printf("L1_GUI START cpu=%s  (F9=pause, Alt+Q=quit, other keys -> machine)\n", cpu_name);

#ifdef L1_VGA
	VgaSampler vga_s;
	GLuint vga_tex = 0;
	// Video texture - the whole-machine path (sim_video.cpp
	// Initialise): GL_RGBA 640x240, LINEAR filter, re-uploaded when
	// a new vga frame completes; shown with ImGui::Image.
	for (size_t i = 0; i < sizeof(g_vga_buf) / sizeof(g_vga_buf[0]); i++)
		g_vga_buf[i] = 0xFF000000u;
	glGenTextures(1, &vga_tex);
	glBindTexture(GL_TEXTURE_2D, vga_tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, VGA_W, VGA_H, 0, GL_RGBA,
		     GL_UNSIGNED_BYTE, g_vga_buf);
#else
	GLuint nat_tex = 0;
	// Native video texture - the whole-machine path (sim_video.cpp
	// Initialise): GL_RGBA 560xNAT_H, re-uploaded when a new frame
	// completes; shown with ImGui::Image.  NEAREST filtering: the image
	// is an integer scale of 1-bit pixels, so nearest-neighbour keeps
	// every pixel crisp (GL_LINEAR blends the 1-bit edges and looks soft).
	for (size_t i = 0; i < sizeof(g_nat_buf) / sizeof(g_nat_buf[0]); i++)
		g_nat_buf[i] = 0xFF000000u;
	glGenTextures(1, &nat_tex);
	glBindTexture(GL_TEXTURE_2D, nat_tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, VID_W, NAT_H, 0, GL_RGBA,
		     GL_UNSIGNED_BYTE, g_nat_buf);
#endif

	bool running = true;
	bool pause = false;
	// Default matches the whole-machine sim (sim_main.cpp batchSize
	// 650000 cycles/frame, no vsync): run at model throughput; the
	// GUI frame rate falls where it may.
	int steps_per_frame = 650000;  // sim time slots per presented frame
	bool por_released = false;
	// Cold-reboot click feedback: the visible effect of a reboot is short
	// (blank -> logo flash -> blank monitor), so without an explicit
	// readout a click that "did nothing" is indistinguishable from a click
	// that was never delivered.  reboot_clicks proves the click reached
	// this code; the POWER-ON HOLD banner (por_released re-armed per click)
	// proves the TB saw the pulse.
	int reboot_clicks = 0;
	unsigned long long reboot_t0_ns = 0;
	int frame = 0;
	uint32_t vbuf[VID_W * VID_H];
	int frame_ink = 0;
	int frame_rows = 0;
	int blit_diag_done = 0;  // one-shot blit diagnostics (1st video frame)
	// FPS (per presented frame, mirroring SimVideo::stats_fps)
	long old_time_ms = 0;
	float stats_fps = 0.0f;
	float stats_frame_time_ms = 0.0f;
	// SIM SPEED: 1-s wall-clock window over dbg_clk_cnt (14.318 MHz
	// master cycles; freezes with pause) -> simulated master MHz.
	long speed_anchor_ms = 0;
	uint32_t speed_anchor_cc = 0;
	double sim_speed_MHz = 0.0;
	unsigned long long win_dcc = 0, win_wall_ms = 0;

	while (running) {
		// ------------------------------------------------------ events
		SDL_Event e;
		while (SDL_PollEvent(&e)) {
			if (e.type == SDL_QUIT) running = false;
			// Ignore OS auto-repeat (e.key.repeat): a held key must produce
			// ONE machine keypress, not one per ~33 ms OS repeat.  The
			// full machine's driver has the same semantics (sim_input.cpp
			// only injects on state change: m_keyboardState_last[k] !=
			// m_keyboardState[k]); letting repeats through made a held key
			// type the character twice ("2 keys instead of 1") and also
			// spam-toggled F9 / Alt+Q.
			if (e.type == SDL_KEYDOWN && !e.key.repeat) {
				// GUI-reserved: F9 pause, Alt+Q quit.  Every other key
				// is queued for the machine's PS/2 port (//e codes).
				if (e.key.keysym.mod & KMOD_ALT) {
					if (e.key.keysym.sym == SDLK_q)
						running = false;
				} else if (e.key.keysym.sym == SDLK_F9) {
					pause = !pause;
				} else if (g_keyq_n < 16) {
					uint8_t code = 0; bool ext = false, mod = false;
					if (ps2_make_code(e.key.keysym.scancode,
						&code, &ext, &mod))
						g_keyq[g_keyq_n++] =
						    (uint16_t)((ext ? 1 : 0) << 14 |
						      code);
				}
			}
			if (e.type == SDL_KEYUP && g_keyq_n < 16) {
				// Physical key-up queues a RELEASE event for every key
				// (bit 15).  The machine's keyboard FSM clears akd /
				// shift / ctrl only on a release code; without it a
				// held key auto-repeats into the machine every ~66 ms
				// and modifier state sticks.
				uint8_t code = 0; bool ext = false, mod = false;
				if (ps2_make_code(e.key.keysym.scancode,
					&code, &ext, &mod))
					g_keyq[g_keyq_n++] =
					    (uint16_t)(1 << 15 | (ext ? 1 : 0) << 14 |
					      code);
			}
			ImGui_ImplSDL2_ProcessEvent(&e);
		}

		// ------------------------------------------- drive the model
		r->tb_l1_gui__DOT__stall = pause ? 1 : 0;  // checkbox/F9 -> TB reg

		// ------------------------------------------- keyboard
		// Forward at most one queued entry this frame: stb held high
		// for 60 master cycles (keyboard.v latches on the stb 0->1
		// edge), then dropped.  entry = {release<<15, ext<<14, code}:
		// a press sets bit 9 (key state), a release clears it (akd
		// clear, shift state, caps-lock toggle happen on key-up).
		if (g_keyq_n > 0) {
			const uint16_t k = g_keyq[--g_keyq_n];
			const uint16_t val =
			    (1 << 10) | ((k & 0x8000) ? 0 : (1 << 9)) |
			    ((k >> 14) << 8) | (k & 0xFF);
			for (int c = 0; c < 60; c++) {
				r->tb_l1_gui__DOT__ps2_key = val;
				run_slots(top, context, 1);
			}
			r->tb_l1_gui__DOT__ps2_key = 0;
			printf("L1_GUI KEY 0x%02X %s | rd_cnt=%lu rd_k=0x%02X akd_cnt=%lu\n",
			       k & 0xFF, (k & 0x8000) ? "rel" : "press",
			       (unsigned long)r->tb_l1_gui__DOT__dbg_rd_cnt,
			       r->tb_l1_gui__DOT__dbg_rd_k,
			       (unsigned long)r->tb_l1_gui__DOT__dbg_akd_cnt);
		}
		// Keyboard poll baseline: if dbg_rd_cnt climbs here with no
		// keys pressed, the machine is in a keyboard-polling loop.
		if ((frame % 60) == 0)
			printf("L1_GUI KB rd_cnt=%lu rd_k=0x%02X akd_cnt=%lu addr=$%04X\n",
			       (unsigned long)r->tb_l1_gui__DOT__dbg_rd_cnt,
			       r->tb_l1_gui__DOT__dbg_rd_k,
			       (unsigned long)r->tb_l1_gui__DOT__dbg_akd_cnt,
			       (unsigned)r->tb_l1_gui__DOT__dbg_addr_last);
#ifdef L1_VGA
		run_slots_vga(top, context, steps_per_frame, vga_s);
		r->tb_l1_gui__DOT__reset_cold = 0;  // C++ clears after each step
		if (!por_released && r->tb_l1_gui__DOT__power_on_reset == 0) {
			por_released = true;
			printf("L1_GUI POR released at sim=%llu ns; boot now starting\n",
			       (unsigned long long)(context.time() / 1000));
		}
		if (vga_s.frame_ready) {
			vga_s.frame_ready = false;
			glBindTexture(GL_TEXTURE_2D, vga_tex);
			glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, VGA_W, VGA_H, 0,
				     GL_RGBA, GL_UNSIGNED_BYTE, g_vga_buf);
			frame_ink = (int)vga_ink();
		}
#else
		run_slots(top, context, steps_per_frame);
		r->tb_l1_gui__DOT__reset_cold = 0;  // C++ clears after each step
		if (!por_released && r->tb_l1_gui__DOT__power_on_reset == 0) {
			por_released = true;
			printf("L1_GUI POR released at sim=%llu ns; boot now starting\n",
			       (unsigned long long)(context.time() / 1000));
		}

		// ------------------------------------------------------ video
		if (r->tb_l1_gui__DOT__frame_valid) {
			frame_ink = extract_frame(r, vbuf);
			frame_rows = (int)r->tb_l1_gui__DOT__frame_lines;
			if (frame_rows > VID_H) frame_rows = VID_H;
			if (frame_rows < 1) frame_rows = 1;
			r->tb_l1_gui__DOT__frame_valid = 0;
			// Convert into the texture buffer (0xAARRGGBB, alpha
			// 0xFF; rows beyond the frame keep their value) and
			// upload - same as the vga path.
			const int n = frame_rows < NAT_H ? frame_rows : NAT_H;
			for (int y = 0; y < n; y++)
				for (int x = 0; x < VID_W; x++)
					g_nat_buf[(size_t)y * VID_W + x] =
					    vbuf[(size_t)y * VID_W + x] ?
					    0xFFFFFFFFu : 0xFF000000u;
			glBindTexture(GL_TEXTURE_2D, nat_tex);
			glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, VID_W, NAT_H,
				     0, GL_RGBA, GL_UNSIGNED_BYTE, g_nat_buf);
			if (blit_diag_done == 0) {
				blit_diag_done = 1;
				printf("L1_GUI IMG 1st frame: rows=%d ink=%d "
				       "(texture %dx%d)\n",
				       n, frame_ink, VID_W, NAT_H);
			}
		}
#endif  // L1_VGA

		// (no direct blit in either variant: both images are drawn
		// by ImGui::Image from a GL texture - the native glDrawPixels
		// path was a no-op on this driver; see PROGRESS.md)

		// ------------------------------------------------------ frame
		ImGui_ImplOpenGL3_NewFrame();
		ImGui_ImplSDL2_NewFrame();
		ImGui::NewFrame();

		// Clear the whole drawable every frame: the imgui windows only
		// cover part of it, and without a clear the uncovered area shows
		// stale framebuffer contents (background glitches).
		glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);

#ifdef L1_VGA
		// The whole-machine display path: GL texture + ImGui::Image
		// (sim_video.cpp Render / sim_main.cpp:587-596).
		ImGui::SetNextWindowSize(ImVec2((float)VGA_W * scale + 40,
						    (float)VGA_H * scale + 240),
				ImGuiCond_FirstUseEver);
		ImGui::Begin("Apple II level_1 VGA A/B (vga_controller + SimVideo)");
		ImGui::Image((ImTextureID)(intptr_t)vga_tex,
			ImVec2((float)VGA_W * scale, (float)VGA_H * scale));
		ImGui::Separator();
		ImGui::Text("cpu: %s  (640x240 vga, sampled every 2nd master cycle)", cpu_name);
		ImGui::Text("frame_count: %d   FPS: %f   (frame time %ld ms)",
			 frame, stats_fps, (long)stats_frame_time_ms);
		ImGui::Text("sim speed (1 s window): %0.3f MHz  (14.318 MHz master; %llu clk / %llu ms wall)",
			 (float)sim_speed_MHz, win_dcc, win_wall_ms);
		ImGui::Separator();
		ImGui::Checkbox("Pause (stall CPU)", &pause);
		ImGui::SameLine(220);
		if (ImGui::Button("Cold reboot")) {
			r->tb_l1_gui__DOT__reset_cold = 1;
			reboot_clicks++;
			por_released = false;       // re-arm the POWER-ON HOLD banner
			reboot_t0_ns = context.time();  // hold elapsed-time anchor
		}
		ImGui::SameLine(380);
		if (pause) {
			ImGui::TextColored(ImVec4(1.0f, 0.8f, 0.2f, 1.0f), "PAUSED");
		} else {
			ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.5f, 1.0f), "RUNNING");
		}

		ImGui::SliderInt("sim time slots per frame", &steps_per_frame, 1, 1750000);
		ImGui::Separator();
		ImGui::Text("last frame ink=%d px  (non-black, 640x240)", frame_ink);
		ImGui::Text("reset: rst=%d por=%d  flash_div=%u  reboots=%d  addr_last=$%04x  addr_chg=%u",
			 (int)r->tb_l1_gui__DOT__reset_sync, (int)r->tb_l1_gui__DOT__power_on_reset,
			 (unsigned)r->tb_l1_gui__DOT__flash_div, reboot_clicks,
			 (unsigned)r->tb_l1_gui__DOT__dbg_addr_last,
			 r->tb_l1_gui__DOT__dbg_addr_chg);
		if (!por_released) {
			const unsigned long long hold_ms =
			    (unsigned long long) ((context.time() - reboot_t0_ns) /
			                          1000000);
			ImGui::TextColored(ImVec4(1.0f, 0.9f, 0.3f, 1.0f),
			    "POWER-ON HOLD: %llu ms / 294 ms (screen blank until release)",
			    hold_ms);
		}
		ImGui::Separator();
		ImGui::TextDisabled("F9 pauses.  Alt+Q quits.  Other keys");
		ImGui::TextDisabled("go to the machine (//e scan");
		ImGui::TextDisabled("letters, digits, Enter, Backspace,");
		ImGui::TextDisabled("Space, Tab, Esc, arrows, F2=reset).");
		ImGui::TextDisabled("Cold");
		ImGui::TextDisabled("reboot re-runs the power-on hold");
		ImGui::TextDisabled("and re-boots the ROM.");

		ImGui::End();
#else
		// --- main canvas: the area RIGHT of the pinned stats panel
		// (300 px) filling the remaining full window.  ImGui clips
		// content to the canvas bounds, so no matter how far the user
		// scrolls, the video image can never go under the control panel
		// or above the top of the window (on-screen X >= 300 >= 0 and
		// Y >= 0 at all times).  The video sits at (300+8, 8) on screen
		// at the EXACT slider scale: it never auto-resizes when the
		// outer window is enlarged.  If the outer window is too small
		// for the image, imgui shows scrollbars on this canvas (spanning
		// the whole video area) so the whole picture stays reachable.
		const int vid_w = VID_W * scale / (half_h ? 2 : 1);
		const int vid_h = NAT_H * scale;
		ImGui::SetNextWindowPos(ImVec2(300.0f, 0.0f), ImGuiCond_Always);
		ImGui::SetNextWindowSize(
		    ImVec2(ImGui::GetIO().DisplaySize.x - 300.0f,
			(float)ImGui::GetIO().DisplaySize.y),
		    ImGuiCond_Always);
		ImGui::Begin("##l1_canvas", 0,
		    ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
		    ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse |
		    ImGuiWindowFlags_NoSavedSettings);
		ImGui::SetCursorPos(ImVec2(8.0f, 8.0f));
		ImGui::Image((ImTextureID)(intptr_t)nat_tex,
		    ImVec2((float)vid_w, (float)vid_h));
		// content extent = video + margin, so the scrollbars
		// cover the whole picture when the window is too small
		ImGui::Dummy(ImVec2((float)(vid_w + 24), (float)(vid_h + 24)));
		ImGui::End();

		// --- stats window: pinned at the TOP-LEFT and stretched to
		// the full window height (IO.DisplaySize is the backend's own
		// full-window size in imgui coordinates), so it stays visible
		// no matter how the window or display is resized.
		ImGui::SetNextWindowPos(ImVec2(0.0f, 0.0f), ImGuiCond_Always);
		ImGui::SetNextWindowSize(ImVec2(300.0f, ImGui::GetIO().DisplaySize.y),
		    ImGuiCond_Always);
		ImGui::Begin("Apple II level_1 - machine stats", 0,
		    ImGuiWindowFlags_NoResize |
		    ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse |
		    ImGuiWindowFlags_NoSavedSettings);

		ImGui::Text("cpu: %s", cpu_name);
		ImGui::Text("frame_count: %d   FPS: %f", frame, stats_fps);
		ImGui::Text("frame time: %ld ms", (long)stats_frame_time_ms);
		ImGui::Text("sim speed (1 s): %0.3f MHz", (float)sim_speed_MHz);
		ImGui::Text("  %llu clk / %llu ms wall",
			 win_dcc, win_wall_ms);
		ImGui::Text("  (14.318 MHz master)");
		ImGui::Separator();

		// Integer scale only: the image is an exact N x of the
		// 560x262 frame (GL_NEAREST + integer pixels = crisp, even
		// pixel grid).  Changing it resizes the SDL window too, so
		// the outer frame stays an exact multiple of the video
		// pixels.  (If the Windows display scaling is non-integer,
		// e.g. 125%, the GPU adds a fractional layer on top.)
		// half_h: show the whole frame squashed to half its displayed
		// WIDTH (280 wide at 1x -> nearly square 280x262).
		ImGui::Text("scale (integer x)");
		if (ImGui::SliderInt("##scale", &scale, 1, 3) ||
		    ImGui::Checkbox("half horizontal (compact width)", &half_h)) {
			int ww = 0, hh = 0;
			l1_window_size(scale, half_h, &ww, &hh);
			SDL_SetWindowSize(window, ww, hh);
		}

		if (pause)
			ImGui::TextColored(ImVec4(1.0f, 0.8f, 0.2f, 1.0f), "PAUSED");
		else
			ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.5f, 1.0f), "RUNNING");
		ImGui::Checkbox("Pause (stall CPU)", &pause);
		ImGui::SameLine();
		if (ImGui::Button("Cold reboot")) {
			r->tb_l1_gui__DOT__reset_cold = 1;
			reboot_clicks++;
			por_released = false;       // re-arm the POWER-ON HOLD banner
			reboot_t0_ns = context.time();  // hold elapsed-time anchor
		}

		ImGui::Text("sim time slots per frame");
		ImGui::SliderInt("##slots", &steps_per_frame, 1, 1750000);
		ImGui::Separator();
		ImGui::Text("video lines/frame=%u  last_len=%u",
			 r->tb_l1_gui__DOT__frame_lines, r->tb_l1_gui__DOT__last_len);
		ImGui::Text("last_act=%u  frames=%d",
			 r->tb_l1_gui__DOT__last_act,
			 (int)r->tb_l1_gui__DOT__frame_count);
		ImGui::Text("last frame ink=%d px", frame_ink);
		ImGui::Text("kb reads=%llu last=0x%02X akd_cyc=%llu",
			 (unsigned long long)r->tb_l1_gui__DOT__dbg_rd_cnt,
			 r->tb_l1_gui__DOT__dbg_rd_k,
			 (unsigned long long)r->tb_l1_gui__DOT__dbg_akd_cnt);
		ImGui::Text("text_mode_s=%d  screen_ink=%u",
			 (int)r->tb_l1_gui__DOT__text_mode_s,
			 r->tb_l1_gui__DOT__screen_ink);
		ImGui::Text("reset: rst=%d por=%d  flash_div=%u  reboots=%d",
			 (int)r->tb_l1_gui__DOT__reset_sync,
			 (int)r->tb_l1_gui__DOT__power_on_reset,
			 (unsigned)r->tb_l1_gui__DOT__flash_div, reboot_clicks);
		ImGui::Text("addr_last=$%04x  addr_chg=%u",
			 (unsigned)r->tb_l1_gui__DOT__dbg_addr_last,
			 r->tb_l1_gui__DOT__dbg_addr_chg);
		if (!por_released) {
			const unsigned long long hold_ms =
			    (unsigned long long) ((context.time() - reboot_t0_ns) /
			                          1000000);
			ImGui::TextColored(ImVec4(1.0f, 0.9f, 0.3f, 1.0f),
			    "POWER-ON HOLD: %llu ms / 294 ms", hold_ms);
			ImGui::TextColored(ImVec4(1.0f, 0.9f, 0.3f, 1.0f),
			    "  (screen blank until release)");
		}
		ImGui::Separator();
		ImGui::TextDisabled("F9 pauses.  Alt+Q quits.");
		ImGui::TextDisabled("Other keys go to the machine");
		ImGui::TextDisabled("(//e scan codes: letters, digits,");
		ImGui::TextDisabled("Enter, Backspace, Space, Tab,");
		ImGui::TextDisabled("Esc, arrows).");
		ImGui::TextDisabled("Cold reboot re-runs the power-on");
		ImGui::TextDisabled("hold and re-boots the ROM.");

		ImGui::End();
#endif  // L1_VGA panel
		ImGui::Render();

		// Both variants: the video is an ImGui::Image (GL texture),
		// drawn by ImGui_ImplOpenGL3_RenderDrawData below.
		// (the native glDrawPixels path was a no-op on this driver)
		ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
		SDL_GL_SwapWindow(window);

		// Sample once per presented frame (same scheme as the machine
		// build's stats_fps in sim_video.cpp).
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
		const uint32_t cc = r->tb_l1_gui__DOT__dbg_clk_cnt;
		if (speed_anchor_ms == 0) {
			speed_anchor_ms = (long)t_ms;
			speed_anchor_cc = cc;
		} else if (t_ms - speed_anchor_ms >= 1000) {
			win_dcc = (unsigned long long)(cc - speed_anchor_cc);
			win_wall_ms = (unsigned long long)(t_ms - speed_anchor_ms);
			sim_speed_MHz = (double)win_dcc / ((double)win_wall_ms / 1000.0) / 1.0e6;
			speed_anchor_ms = (long)t_ms;
			speed_anchor_cc = cc;
		}

		if (frame % 240 == 0)
			printf("L1_GUI FRAME %d  pause=%d  clk_cnt=%u  sim=%0.3f MHz\n",
			       frame, (int)pause, cc, (float)sim_speed_MHz);
		if (max_frames > 0 && ++frame >= max_frames) {
			running = false;
			printf("L1_GUI run-frames limit reached (%d), exiting\n",
			       max_frames);
		}
	}

#ifndef L1_VGA
	// Display-path diagnostic: dump the EXACT buffer uploaded to the
	// GL texture (the image ImGui::Image presents) as a top-to-bottom
	// P1 image.
	if (dump_gl) {
		FILE* fp = fopen("unit_tests/level_1/out/l1_glbuf_frame.pbm", "wb");
		if (fp) {
			fprintf(fp, "P1\n%d %d\n", VID_W, NAT_H);
			for (int y = 0; y < NAT_H; y++)
				for (int x = 0; x < VID_W; x++)
					fputc((g_nat_buf[(size_t)y * VID_W + x] &
					       0x00FFFFFFu) != 0u ? '1' : '0',
					       fp);
			fputc('\n', fp);
			fclose(fp);
			printf("L1_GUI nat_buf dumped: unit_tests/level_1/out/l1_glbuf_frame.pbm (%dx%d)\n",
			       VID_W, NAT_H);
		} else {
			printf("L1_GUI nat_buf dump FAILED (fopen)\n");
		}
	}
#endif  // L1_VGA

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
