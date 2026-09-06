// ============================================================================
// unit_tests/level_2/gui/main_gui.cpp
//
// imgui + SDL2 + OpenGL3 GUI for the level_2 machine harness.  Built from
// top module tb_l2 (the SAME top as the headless exe - see tb_l2.sv): the
// full machine core (rtl/apple2_top.v) + real PS/2 keyboard + real Disk II
// slot controller + real floppy_track x2 - with NO test sequence and NO
// $finish; this process is the driver.
//
// What you see: the machine's NATIVE monochrome video signal, sampled
// once per 14.318 MHz master cycle (correct for TEXT-mode content - the
// DOS 3.3 boot and its READY. prompt are text).  The machine cold-boots
// on start - there is a ~294 ms (sim) power-on hold (2^22 master cycles)
// before the ROM starts - and with a disk mounted it homes the drive,
// reads the boot block through the real Disk II + track dpram, and boots
// DOS 3.3: this process serves the .nib over the floppy_track SD/blkdev
// interface through the SHARED BlkDevEngine (L2DiskHost above /
// verilator/sim/sim_blkdev_engine.h: real MiSTer protocol timing, the
// image mounts read-only by default, --scratch mounts a RW copy).
//
// BUILD NOTE (load-bearing): this is the LEGACY (non-timing) Verilator
// build, the same as the headless exe - the C++ host (L2DiskHost)
// REQUIRES legacy eval (see the Makefile NOTE: with --timing, purely
// input-driven combinational cones such as the track dpram
// wren_a/data_a nets are frozen in the stable region and the host's
// bytes never reach the RAM).
// The 14.3 MHz clock is driven from C++: one top->eval() per 35 ns
// toggle (one master half-period), and g_host.tick() is called before
// each eval() that contains a RISING edge (one host byte per 14.3 MHz
// posedge = one dpram commit).  No sc_time_stamp / eval_step / time
// slots anywhere.
//
// Controls
//   * Pause CPU checkbox / F9    -> writes tb_l2.stall (the CPU freezes
//     on the next master edge; the video keeps scanning and the drive
//     keeps spinning, as on the machine)
//   * Cold reboot button         -> one frame of reset_cold = full cold
//     power-on sequence again (POR hold + ROM boot; with a disk
//     mounted: the DOS boot re-runs)
//   * Alt+Q / window close       -> quit
//   * All other keys             -> forwarded to the machine's PS/2 port
//     as Apple //e scan codes (the same mapping as the level_1 GUI);
//     a press holds stb for 60 half-periods, the release is queued on
//     physical key-up.  With DOS up, the characters land at the READY.
//     prompt (DOS polls the keyboard via $C000).
//
// Readouts (all live)
//   * video FPS     - presented video frames per second (wall clock)
//   * render FPS    - GUI frames per second (no vsync - the loop runs
//                     at model throughput, like the whole-machine sim)
//   * sim speed     - EXACT sim-time accounting over a 1-s wall window
//                     (the pump advances sim time deterministically, so
//                     this is the true throughput; ~14-16x slower than
//                     real time on this machine)
//   * disk          - sectors served by the host, max LBA, bytes,
//                     drive-1 track / ready / sd_rd / motor spin-ups
//   * boot          - DOS boot-block checksum ($0800-$0BFF), CPU address
//   * reset         - reset_sync / power_on_reset / flash_div, reboots
//
// Headless smoke (no window; the same binary):
//   Vtb_l2.exe +cpu=0 --headless [N] [--selfkey] [--reboot]
//               [--empty | --disk <nib>] [--readonly] [--scratch]
// runs the machine until the scenario PASSES (N video frames presented -
// default 5 - the last frame non-blank, and for --disk (the DEFAULT: the
// level_2 DOS_3_3.nib) the host actually served sectors and the drive-1
// motor spun up; a sim-time budget caps the wait).  A small stall check
// then proves the C++-written `stall` reg holds the CPU (address frozen)
// while the machine's free-running PHASE_ZERO_F enable keeps counting.  --selfkey drives a synthetic PS/2 'A' press/release
// through the exact path the GUI keyboard uses and verifies the
// keyboard chain reports the key (akd counter climbs; the K byte 0xC1
// is captured too when the DOS OS reads $C000).  --reboot cold-reboots
// the machine exactly the way the GUI button does (set reset_cold, run
// a few cycles, clear it) and verifies the POR re-asserts and releases
// and a fresh non-blank frame arrives.  Prints L2_GUI SMOKE PASS/FAIL
// and exits non-zero on failure.
//
// The binary MUST run with the process CWD at the REPO ROOT: the DUT's
// $readmemh ROM paths (rtl/roms/*.hex) are CWD-relative, and the
// default .nib path is too.
// ============================================================================
#include "Vtb_l2.h"
#include "Vtb_l2___024root.h"
#include "verilated.h"

// SDL.h on Windows does `#define main SDL_main` (SDL_main.h) unless
// SDL_MAIN_HANDLED is set - that would compile our `main` as `SDL_main`
// and leave the exe with no entry point.  We keep our own `main`.
#define SDL_MAIN_HANDLED
#include <SDL.h>
#include <GL/gl.h>

#include "imgui.h"
#include "backends/imgui_impl_sdl2.h"
#include "backends/imgui_impl_opengl3.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "l2_disk_host.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/time.h>
#endif

// Video geometry: the TB samples one VIDEO bit per master cycle; the
// native text line measures 560 master cycles (tb_l1 T1 pin), so render
// 560 px wide.  The frame buffer holds 512 lines; the V-period in lines
// (measured live in frame_lines, ~262) fits with margin.
#define VID_W 560
#define VID_H 512
#define NAT_H 262  // measured lines/frame (262), texture height

// Default disk for the GUI (CWD-relative; the exe runs from the repo
// root, like the headless harness).
static const char* DEFAULT_NIB = "unit_tests/level_2/DOS_3_3.nib";

// Monotonic milliseconds since first call (NOT wall clock): FPS + sim-speed
// windows use it for deltas only.  The old Windows body used GetSystemTime
// (wSecond*1000 + wMilliseconds = ms WITHIN THE MINUTE) and wrapped every
// 60 s; after a wrap the sim-speed window test (t_ms - anchor >= 1000) went
// negative and never closed again, so the readout froze at a stale value.
//  QPC is monotonic and immune to wall-clock changes.
static long now_ms()
{
#ifdef _WIN32
	static LARGE_INTEGER qpc_freq = { 0 }, qpc_t0 = { 0 };
	LARGE_INTEGER qpc_t;
	if (qpc_freq.QuadPart == 0) {
		QueryPerformanceFrequency(&qpc_freq);
		QueryPerformanceCounter(&qpc_t0);
	}
	QueryPerformanceCounter(&qpc_t);
	return (long)(((qpc_t.QuadPart - qpc_t0.QuadPart) * 1000LL)
			      / qpc_freq.QuadPart);
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

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Copy the last completed frame from the TB into `buf` (VID_W x VID_H,
// black-filled uint32 ARGB pixels) and return the white-pixel count
// ("ink").  The TB's `frame` reg array (512 x 1024-bit lines) maps to
// VlUnpacked<VlWide<32>, 512>: each line is 32 x 32-bit words (EData is
// 32-bit in this Verilator), word 0 = bits [31:0].  (Same as the level_1
// GUI.)
// ---------------------------------------------------------------------------
static uint32_t extract_frame(const Vtb_l2___024root* r, uint32_t* buf)
{
	memset(buf, 0, (size_t)VID_W * VID_H * sizeof(uint32_t));
	const uint32_t rows16 = r->tb_l2__DOT__frame_lines;
	const int rows = rows16 < VID_H ? (int)rows16 : VID_H;
	const VlUnpacked<VlWide<32>, 512>& f = r->tb_l2__DOT__frame;
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

// ---------------------------------------------------------------------------
// The model drive (LEGACY eval, like the full sim's SimClock driving
// clk_sys).  Globals: the pump runs against one model, and a new frame is
// consumed per VBL falling edge (the TB's frame_valid latch, cleared by
// this consumer - see run_halfcycle).
// ---------------------------------------------------------------------------
static Vtb_l2*             g_top = nullptr;
static Vtb_l2___024root*   g_r   = nullptr;
static L2DiskHost          g_host;
static uint64_t            g_sim_ps = 0;    // sim time since t=0 (ps)
static bool                g_clk_high = false;
static bool                g_new_frame = false;
static uint32_t            g_frame_ink = 0;
static uint32_t            g_frame_rows = 0;
static uint32_t            g_vbuf[VID_W * VID_H];

// ---------------------------------------------------------------------------
// Disk activity indicators (GUI-side accumulation).
//
// The one-shot `drive1:` line samples the bus ONCE per frame, but at ~1/15x
// real time a 512-byte sector transfer (~13 us of machine time) starts and
// finishes many times between two frames, so that snapshot looks random and
// you cannot tell whether the disk is actually being read.  These globals
// accumulate the WHOLE frame instead: per-tick counters (drive selected /
// transferring / writing) and a persistent track map that lights up every
// track the machine actually reads.  Watch the bar pulse and the map fill
// in as DOS loads.
static uint64_t g_act_active_ticks = 0;   // rising ticks this frame, d1_active high
static uint64_t g_act_rd_ticks = 0;       // rising ticks this frame, drive-1 sd_rd high
static uint64_t g_act_wr_ticks = 0;       // rising ticks this frame, drive-1 sd_wr high
static bool     g_trackmap[64] = { false }; // tracks served so far (persistent)
static int      g_last_track = -1;        // most recent track request seen

// ---------------------------------------------------------------------------
// Track map texture (shown just under the screen).
//
// The map used to be raw draw-list rectangles in the stats panel; those
// froze in place when the panel scrolled (draw-list pixels do not
// participate in the window's item layout/scroll the way real items do).
// As a real ImGui::Image item under the video it scrolls with the canvas
// content like everything else.  64 cells in two rows of 32 (256x24),
// re-uploaded every frame (24 KB - trivial).
static const int MAP_W = 256;
static const int MAP_H = 24;
static uint8_t   g_map_px[MAP_W * MAP_H * 4];

static void build_map_tex()
{
	for (int i = 0; i < MAP_W * MAP_H; i++)
		((uint32_t*)g_map_px)[i] = 0xFF000000u;   // black
	for (int t = 0; t < 64; t++) {
		const int r = t / 32, c = t % 32;
		const int x0 = c * 8, y0 = r * 12;       // cell 7 wide x 9 tall
		const uint32_t fill = g_trackmap[t] ?
		    0xFF50DC78u : 0xFF2D2D2Du;          // green / dark gray
		for (int y = y0; y < y0 + 9; y++)
			for (int x = x0; x < x0 + 7; x++)
				((uint32_t*)g_map_px)[y * MAP_W + x] = fill;
		if (t == g_last_track) {                // white 1-px border
			for (int x = x0; x < x0 + 7; x++) {
				((uint32_t*)g_map_px)[y0 * MAP_W + x] = 0xFFFFFFFFu;
				((uint32_t*)g_map_px)[(y0 + 8) * MAP_W + x] = 0xFFFFFFFFu;
			}
			for (int y = y0; y < y0 + 9; y++) {
				((uint32_t*)g_map_px)[y * MAP_W + x0] = 0xFFFFFFFFu;
				((uint32_t*)g_map_px)[y * MAP_W + x0 + 6] = 0xFFFFFFFFu;
			}
		}
	}
}

// One-shot PBM dump of the LAST PRESENTED frame (human-viewable; the
// out/ directory is created by the runner, like the headless harness).
//
// Dumps g_vbuf, NOT the live tb_l2 `frame` register: extract_frame() fills
// g_vbuf the instant frame_valid latches (the frame is complete).  The
// TB's `frame[0..261]` region, however, is where the NEXT frame is being
// scanned in (line_cnt is an absolute counter; frame_base slides, so the
// current frame is always written from frame[0] up), so by the time a
// later dump runs it has been partially overwritten - the live register
// shows a torn, mostly-blank mix (a single stray line), not the frame
// that was actually presented.  g_vbuf is the stable, correct copy.
static void dump_pbm(const char* path) {
	FILE* fp = fopen(path, "wb");
	if (!fp) return;
	const int rows = (int)g_frame_rows;
	fprintf(fp, "P1\n%d %d\n", VID_W, rows);
	for (int y = 0; y < rows; y++)
		for (int x = 0; x < VID_W; x++) {
			fputc(g_vbuf[(size_t)y * VID_W + x] ? '1' : '0', fp);
			fputc(' ', fp);
		}
	fclose(fp);
	printf("  PBM dumped: %s\n", path);
}



static void run_halfcycle()
{
	Vtb_l2* top = g_top;
	g_sim_ps += 35000;            // one half-period (35 ns)
	g_clk_high = !g_clk_high;
	top->clk_14m = g_clk_high ? 1 : 0;
	// Host step only on the RISING edge (one byte presented per
	// 14.3 MHz posedge = one dpram port-A commit).  Legacy eval()
	// re-evaluates the whole combinational cone each step, so the C++
	// field writes (clock + SD host bus) are seen by this eval.
	if (g_clk_high)
		g_host.tick(top);
	top->eval();
	// Disk activity accumulation (drive 1): sample AFTER eval so the DUT
	// protocol outputs for this rising edge are settled (h_* are one
	// cycle delayed snapshots; that is fine for an activity meter).
	if (g_clk_high) {
		if (g_r->tb_l2__DOT__h_d1_active)
			g_act_active_ticks++;
		if (g_r->tb_l2__DOT__h_sd_rd & 1)
			g_act_rd_ticks++;
		if (g_r->tb_l2__DOT__h_sd_wr & 1)
			g_act_wr_ticks++;
		const int trk = (int)g_r->tb_l2__DOT__h_d1_track;
		if (trk >= 0 && trk < 64) {
			g_last_track = trk;
			if (g_r->tb_l2__DOT__h_sd_rd & 1)
				g_trackmap[trk] = true;   // served from this track
		}
	}
	// NOTE: tb_l2's `frame_valid` is a LATCH (set at the VBL falling
	// edge when frame_count > 0, never cleared in the TB - same scheme
	// as tb_l1_gui.sv).  The C++ consumer is responsible for clearing
	// it after consumption (the level_1 GUI does exactly this).  Without
	// the clear, extract_frame() would run on EVERY half-cycle once the
	// flag first latches high - a 286,720-pixel copy per 35 ns that
	// collapses the pump to ~1e-4 x real time.
	if (g_r->tb_l2__DOT__frame_valid) {
		g_frame_ink = extract_frame(g_r, g_vbuf);
		g_frame_rows = g_r->tb_l2__DOT__frame_lines;
		g_new_frame = true;
		g_r->tb_l2__DOT__frame_valid = 0;   // consume the latch
	}
}

static void run_halfcycles(int n)
{
	for (int i = 0; i < n; i++)
		run_halfcycle();
}

// ---------------------------------------------------------------------------
// Physical key -> Apple //e PS/2 scan code.
//
// Protocol (rtl/keyboard.v, packed exactly like the whole-machine
// sim_input.cpp and the level_1 GUI): PS2_Key = {stb[10], pressed[9],
// ext[8], code[7:0]} - bit 10 strobe, bit 9 key state (1 = press, 0 =
// release), bit 8 extended flag, [7:0] the code.
//
// The //e keyboard uses its OWN scan code set (the junction table inside
// rtl/keyboard.v), not the PC set-1 codes: e.g. A = 0x1C (0x1E on a PC),
// Return = 0x5A, Space = 0x29, Backspace = 0x66 (the //e "del" key,
// mapped to the left junction), Up = 0x75 with ext.  Lookup is by SDL
// *scancode* (layout-independent); unmapped keys are simply not sent.
// `mod` marks modifier keys (shift/ctrl/apple): for those the GUI queues
// the release on the physical key-up so the machine's modifier state is
// held while the next key is typed.
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
	case SDL_SCANCODE_RSHIFT:   *code = 0x59; *mod = true; break;
	case SDL_SCANCODE_LCTRL:    *code = 0x14; *mod = true; break;
	case SDL_SCANCODE_LALT:     *code = 0x11; *mod = true; break; // closed apple
	case SDL_SCANCODE_LGUI:     *code = 0x1F; *mod = true; break; // open apple
	case SDL_SCANCODE_CAPSLOCK: *code = 0x58; break;
	case SDL_SCANCODE_F2:       *code = 0x06; break;  // machine soft reset
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

// Native GUI outer-window size for a given integer scale.  The stats
// panel is pinned at the left (300 px wide, full window height, always
// visible); the video sits to its right.  (Same scheme as the level_1
// GUI's native variant.)
static void l2_window_size(int scale, bool half_h, int* w, int* h)
{
	const int vid_w = VID_W * scale / (half_h ? 2 : 1);
	const int vid_h = NAT_H * scale;
	*w = vid_w + 356;  // 300 panel + 32 gap + 24 margin
	*h = (vid_h > 480 ? vid_h : 480) + 40;
}

static uint32_t g_nat_buf[VID_W * NAT_H];  // texture staging (0xAARRGGBB)

int main(int argc, char** argv)
{
	bool  headless = false;
	int   headless_frames = 5;
	bool  selfkey = false;
	bool  reboot_test = false;
	bool  do_empty = false;
	bool  do_disk  = false;
	bool  ro_mount = false;  // --readonly
	bool  scratch  = false;  // --scratch: copy + mount copy RW
	const char* nib_path = nullptr;
	int   max_frames = 0;
	int   scale = 2;
	bool  half_h = true;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--headless") == 0) {
			headless = true;
			if (i + 1 < argc && atoi(argv[i + 1]) >= 1)
				headless_frames = atoi(argv[++i]);
		} else if (strcmp(argv[i], "--selfkey") == 0) {
			selfkey = true;  // with --headless: synthetic PS/2 'A' test
		} else if (strcmp(argv[i], "--reboot") == 0) {
			reboot_test = true;  // with --headless: cold-reboot test
		} else if (strcmp(argv[i], "--empty") == 0) {
			do_empty = true;
		} else if (strcmp(argv[i], "--disk") == 0) {
			do_disk = true;
			if (i + 1 < argc)
				nib_path = argv[++i];
		} else if (strcmp(argv[i], "--readonly") == 0) {
			ro_mount = true;
		} else if (strcmp(argv[i], "--scratch") == 0) {
			scratch = true;
		} else if (strcmp(argv[i], "--run-frames") == 0 && i + 1 < argc) {
			max_frames = atoi(argv[++i]);
		} else if (strcmp(argv[i], "--scale") == 0 && i + 1 < argc) {
			scale = atoi(argv[++i]);
			if (scale < 1) scale = 1;
			if (scale > 4) scale = 4;
		}
	}
	if (!do_empty && !do_disk) {
		// The GUI's point is watching the DOS boot: default to a
		// mounted disk (the level_2 DOS 3.3 image).
		do_disk = true;
		nib_path = DEFAULT_NIB;
	}
	const char* cpu_name = cpu_from_argv(argc, argv);
	const char* disk_desc = do_disk ? nib_path : "(empty)";

	VerilatedContext context;
	// tb_l2 reads +cpu= via $value$plusargs: the context must be told
	// about the process argv first (same requirement as the headless
	// mains; without this Verilator aborts on the first plusarg use).
	context.commandArgs(argc, argv);
	g_top = new Vtb_l2(&context);
	g_r = g_top->rootp;

	// Disk host setup (mirror the headless harness).
	if (do_disk) {
		std::string mount_path = nib_path ? nib_path : "";
		if (scratch && !nib_path) {
			printf("L2_GUI ERROR: --scratch requires --disk\n");
			delete g_top;
			return 2;
		}
		if (scratch) {
			// copy the image; mount the copy RW (original untouched)
			mount_path = std::string(nib_path) + ".l2scratch";
			std::ifstream in(nib_path, std::ios::binary);
			std::ofstream out(mount_path, std::ios::binary | std::ios::trunc);
			if (!in || !out || !(out << in.rdbuf())) {
				printf("L2_GUI ERROR: scratch copy failed: %s\n",
				       mount_path.c_str());
				delete g_top;
				return 2;
			}
			printf("L2_GUI HOST: scratch copy -> %s (mounted RW)\n",
			       mount_path.c_str());
		}
		if (!nib_path || !g_host.mountDrive(0, mount_path.c_str(), ro_mount)) {
			delete g_top;
			return 2;
		}
	}

	printf("L2_GUI START cpu=%s scenario=%s%s\n",
	       cpu_name, disk_desc,
	       headless ? "  (headless)" : "  (windowed)");

	// Prime: run initial blocks at t=0.
	g_top->eval();

	// ------------------------------------------------------------------
	// Headless smoke: boot frames (+ disk activity for --disk), stall
	// check, and the optional --selfkey / --reboot checks.  No SDL, no
	// window.  The pump is the SAME legacy-eval drive as the windowed
	// path (run_halfcycle), so this exercises the GUI binary end to end
	// minus the GL/imgui window layer.
	// ------------------------------------------------------------------
	if (headless) {
		const long wall0_ms = now_ms();
		printf("L2_GUI HEADLESS cpu=%s scenario=%s  (waiting for %d video "
		       "frames; sim includes the 2^22-cycle power-on hold)\n",
		       cpu_name, disk_desc, headless_frames);

		// --- phase 1: boot (frames +, for disk, real sector reads) ---
		// PASS-CONDITION driven (like the proven headless harness): run
		// until the scenario actually passed, budget as ceiling.  The
		// frame-count gate alone is NOT enough: the first video frames
		// arrive DURING the 2^22-cycle power-on hold (frame 1 at ~17 ms
		// sim, long before the 294 ms POR release), so with a disk
		// mounted the 5 required frames complete at ~84 ms sim - before
		// any disk activity.  The disk gate (host really served sectors,
		// drive-1 motor spun up) is what proves the boot path.
		const uint64_t boot_budget_ps =
		    (uint64_t)(do_disk ? 3500000000000 : 1500000000000);  // 3.5 s / 1.5 s (ps)
		int    presented = 0;
		uint32_t last_ink = 0;
		bool     por_released = false;
		uint64_t last_status_ps = 0;
		while (g_sim_ps < boot_budget_ps) {
			run_halfcycles(4000);
			if (g_new_frame) {
				g_new_frame = false;
				last_ink = g_frame_ink;
				presented++;
				printf("  video frame %d   rows=%u ink=%u  sim=%.3fs%s\n",
				       presented, g_frame_rows, last_ink,
				       g_sim_ps / 1e12,
				       por_released ? "" : "  (during power-on hold)");
			}
			if (!por_released && g_r->tb_l2__DOT__power_on_reset == 0) {
				por_released = true;
				printf("  POR released at sim=%.3fs  (flash_div=$%06x)\n",
				       g_sim_ps / 1e12,
				       (unsigned)g_r->tb_l2__DOT__flash_div);
			}
			// Pass condition (evaluated per chunk, as in the headless
			// harness): frames + non-blank + real disk activity for
			// the disk scenario / no disk activity for empty.
			if (presented >= headless_frames && last_ink > 0
			    && (do_disk
			        ? (g_host.engine().readSectors() >= 10
			            && g_r->tb_l2__DOT__dbg_motor1_cnt > 0)
			        : (g_host.engine().readSectors() == 0
			            && g_r->tb_l2__DOT__dbg_motor1_cnt == 0)))
				break;
			if (g_sim_ps - last_status_ps >= 200000000000ull) {
				last_status_ps = g_sim_ps;
				printf("  t=%5.2fs frames=%d ink=%u srv=%llu maxlba=%u "
				       "rdy=%d trk=%d mot1=%u addr=%04X bootn=%u\n",
				       g_sim_ps / 1e12,
				       presented,
				       (unsigned)g_r->tb_l2__DOT__screen_ink,
				       (unsigned long long)g_host.engine().readSectors(),
				       (unsigned)g_host.engine().maxLba(),
				       (int)g_r->tb_l2__DOT__h_disk_ready,
				       (int)g_r->tb_l2__DOT__h_d1_track,
				       (unsigned)g_r->tb_l2__DOT__dbg_motor1_cnt,
				       (unsigned)g_r->tb_l2__DOT__dbg_addr,
				       (unsigned)g_r->tb_l2__DOT__dbg_boot_nz);
			}
		}
		const int boot_pass =
		    presented >= headless_frames && last_ink > 0
		    && (do_disk
		        ? (g_host.engine().readSectors() >= 10
			    && g_r->tb_l2__DOT__dbg_motor1_cnt > 0)
		        : (g_host.engine().readSectors() == 0
			    && g_r->tb_l2__DOT__dbg_motor1_cnt == 0));
		if (boot_pass)
			// The boot screen, captured BEFORE any --reboot overwrites
			// the frame buffer.
			dump_pbm("unit_tests/level_2/out/l2_gui_headless_boot.pbm");

		// --- phase 2: stall check (always) ---
		// The C++-written module-scope `stall` reg must hold the CPU:
		// the CPU address freezes while the machine's free-running
		// PHASE_ZERO_F (PHI0_EN_F) enable pulses keep counting
		// (empirically ~1.02 MHz - a CPU-enable tick, NOT the
		// 14.3 MHz master - and it keeps pulsing under STALL).
		{
			g_r->tb_l2__DOT__stall = 1;
			const uint32_t st_pzf = g_r->tb_l2__DOT__phzf_cnt;
			const uint32_t st_addr = g_r->tb_l2__DOT__dbg_addr;
			run_halfcycles(200000);  // 7 ms of machine time
			g_r->tb_l2__DOT__stall = 0;
			const uint32_t st_pzf1 = g_r->tb_l2__DOT__phzf_cnt;
			const uint32_t st_addr1 = g_r->tb_l2__DOT__dbg_addr;
			const int stall_pass =
			    (st_pzf1 != st_pzf) && (st_addr1 == st_addr);
			printf("L2_GUI STALL %s  cpu=%s  master %u->%u  addr $%04X->%04X\n",
			       stall_pass ? "PASS" : "FAIL", cpu_name,
			       (unsigned)st_pzf, (unsigned)st_pzf1,
			       (unsigned)st_addr, (unsigned)st_addr1);
		}

		// --- phase 3: --selfkey (chain-level keyboard check) ---
		int selfkey_pass = 1;  // 1 unless --selfkey ran and failed
		if (selfkey) {
			const uint32_t akd0 = g_r->tb_l2__DOT__dbg_akd_cnt;
			const uint32_t rd0  = g_r->tb_l2__DOT__dbg_rd_cnt;
			const uint16_t sk_press =
			    (1u << 10) | (1u << 9) | 0x1Cu;  // 'A' press
			const uint16_t sk_rel = (1u << 10) | 0x1Cu;  // 'A' release
			for (int c = 0; c < 60; c++) {
				g_r->tb_l2__DOT__ps2_key = sk_press;
				run_halfcycle();
			}
			for (int c = 0; c < 60; c++) {
				g_r->tb_l2__DOT__ps2_key = sk_rel;
				run_halfcycle();
			}
			g_r->tb_l2__DOT__ps2_key = 0;
			const uint64_t sk_t0 = g_sim_ps;
			const uint64_t sk_budget_ps = 2000000000000ull;  // 2 s
			while (g_sim_ps - sk_t0 < sk_budget_ps) {
				run_halfcycles(4000);
				if ((uint32_t)(g_r->tb_l2__DOT__dbg_akd_cnt - akd0) > 0
				    && (g_r->tb_l2__DOT__dbg_rd_k == 0xC1u
				        || (g_r->tb_l2__DOT__dbg_rd_k == 0x41u
				            && g_r->tb_l2__DOT__dbg_rd_cnt > rd0)))
					break;  // chain + CPU both saw the 'A'
			}
			const uint32_t akd1 = g_r->tb_l2__DOT__dbg_akd_cnt;
			const uint32_t rd1  = g_r->tb_l2__DOT__dbg_rd_cnt;
			const uint8_t  rd_k1 = g_r->tb_l2__DOT__dbg_rd_k;
			selfkey_pass = (akd1 > akd0);
			printf("L2_GUI SELFKEY %s  cpu=%s  akd %u->%u  kb reads %u->%u "
			       "last=0x%02X (0xC1 = 'A' press)\n",
			       selfkey_pass ? "PASS" : "FAIL", cpu_name,
			       (unsigned)akd0, (unsigned)akd1,
			       (unsigned)rd0, (unsigned)rd1, (unsigned)rd_k1);
			if (rd_k1 == 0xC1u)
				printf("  (CPU read the 'A' keypress while held, AKD set - full "
				       "chain incl. the OS input path)\n");
			else if (rd_k1 == 0x41u && rd1 > rd0)
				printf("  (CPU read the 'A' code after release - full chain "
				       "incl. the OS input path)\n");
		}

		// --- phase 4: --reboot (cold reboot exactly as the GUI button) ---
		int reboot_pass = 1;  // 1 unless --reboot ran and failed
		if (reboot_test) {
			const uint32_t div0 = g_r->tb_l2__DOT__flash_div;
			g_r->tb_l2__DOT__reset_cold = 1;
			run_halfcycles(2000);  // 70 us: pulse sampled by the chain
			g_r->tb_l2__DOT__reset_cold = 0;
			const int reasserted =
			    (g_r->tb_l2__DOT__power_on_reset == 1);
			const uint64_t por_t0 = g_sim_ps;
			const uint64_t por_budget_ps = 4000000000000ull;  // 4 s
			int released = 0;
			while (g_sim_ps - por_t0 < por_budget_ps) {
				run_halfcycles(4000);
				if (g_r->tb_l2__DOT__power_on_reset == 0) {
					released = 1;
					break;
				}
			}
			const uint64_t fr_t0 = g_sim_ps;
			const uint64_t fr_budget_ps = 3500000000000ull;  // 3.5 s
			int drew = 0;
			uint32_t rb_ink = 0;
			while (g_sim_ps - fr_t0 < fr_budget_ps && !drew) {
				run_halfcycles(4000);
				if (g_new_frame) {
					g_new_frame = false;
					if (g_frame_ink > 0) {
						drew = 1;
						rb_ink = g_frame_ink;
					}
				}
			}
			printf("L2_GUI REBOOT: pulse %s  POR re-release %s  "
			       "new-frame %s  (ink=%u  div0=$%06x)\n",
			       reasserted ? "OK" : "LOST",
			       released ? "OK" : "TIMEOUT", drew ? "OK" : "TIMEOUT",
			       (unsigned)rb_ink, (unsigned)div0);
			if (!reasserted || !released || !drew) reboot_pass = 0;
		}

		const long wall1_ms = now_ms();
		const int pass = boot_pass && selfkey_pass && reboot_pass;

		// PBM dump of the last completed frame (the boot screen is
		// already saved above if boot passed).
		{
			char pbm[128];
			snprintf(pbm, sizeof(pbm),
				 "unit_tests/level_2/out/l2_gui_headless%s.pbm",
				 pass ? "" : "_fail");
			dump_pbm(pbm);
		}

		printf("\nL2_GUI RESULT cpu=%s scenario=%s  frames=%d/%d  "
		       "ink=%u  sectors=%llu  maxlba=%u  mot1=%u  "
		       "sim=%.2fs wall=%.1fs\n",
		       cpu_name, disk_desc, presented, headless_frames,
		       (unsigned)last_ink,
		       (unsigned long long)g_host.engine().readSectors(),
		       (unsigned)g_host.engine().maxLba(),
		       (unsigned)g_r->tb_l2__DOT__dbg_motor1_cnt,
		       g_sim_ps / 1e12, (wall1_ms - wall0_ms) / 1000.0);
		printf("L2_GUI SMOKE %s  cpu=%s  (boot %s, selfkey %s, reboot %s)\n",
		       pass ? "PASS" : "FAIL", cpu_name,
		       boot_pass ? "ok" : "FAIL",
		       selfkey ? (selfkey_pass ? "ok" : "FAIL") : "n/a",
		       reboot_test ? (reboot_pass ? "ok" : "FAIL") : "n/a");
		if (presented < headless_frames)
			printf("  (sim budget reached before %d frames; sim may be "
			       "slow)\n", headless_frames);
		if (do_disk && g_host.engine().readSectors() < 10)
			printf("  (the disk was not really read: sectors<10)\n");
		g_top->final();
		delete g_top;
		return pass ? 0 : 1;
	}

	// ------------------------------------------------------------------
	// Windowed GUI: SDL2 + OpenGL3 + imgui.  The video frame is shown via
	// a GL texture with ImGui::Image - the same display path as the
	// whole-machine sim and the level_1 GUI (glDrawPixels was a no-op on
	// this driver); the imgui overlay shows FPS, sim speed, live
	// disk/boot geometry and the controls.
	// ------------------------------------------------------------------
	if (SDL_Init(SDL_INIT_VIDEO) != 0) {  // SDL2: keyboard events come with video
		printf("ERROR: SDL_Init failed: %s\n", SDL_GetError());
		delete g_top;
		return 2;
	}
	// Core-profile OpenGL 3.2 context (the imgui OpenGL3 backend needs VAOs).
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, 0);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
	char wtitle[160];
	snprintf(wtitle, sizeof(wtitle), "Apple II level_2 GUI (%s, disk: %s)",
		 cpu_name, disk_desc);
	int win_w = 0, win_h = 0;
	l2_window_size(scale, half_h, &win_w, &win_h);
	SDL_Window* window = SDL_CreateWindow(
	    wtitle, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
	    win_w, win_h,
	    SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE);
	if (!window) {
		printf("ERROR: SDL window failed: %s\n", SDL_GetError());
		SDL_Quit();
		delete g_top;
		return 2;
	}
	SDL_GLContext glctx = SDL_GL_CreateContext(window);
	if (!glctx) {
		printf("ERROR: GL context failed: %s (driver without OpenGL 3.2?)\n",
		       SDL_GetError());
		SDL_DestroyWindow(window);
		SDL_Quit();
		delete g_top;
		return 2;
	}
	SDL_GL_SetSwapInterval(0);  // no vsync - run the GUI loop at model
	// throughput, like the whole-machine sim (sim_video.cpp's
	// SDL_GL_SetSwapInterval(0)); the sim speed then matches the
	// headless throughput instead of 60 Hz x steps_per_frame.

	IMGUI_CHECKVERSION();
	ImGui::CreateContext();
	// No ini persistence: the pinned position (left) and the sizes must
	// apply on every run (the level_1 GUI writes no ini either).
	ImGui::GetIO().IniFilename = NULL;
	ImGui_ImplSDL2_InitForOpenGL(window, glctx);
	ImGui_ImplOpenGL3_Init("#version 130");

	printf("L2_GUI WINDOW cpu=%s  (F9=pause, Alt+Q=quit, other keys -> machine)\n",
	       cpu_name);

	// Native video texture - the whole-machine path (sim_video.cpp
	// Initialise): GL_RGBA 560xNAT_H, re-uploaded when a new frame
	// completes; shown with ImGui::Image.  NEAREST filtering: the image
	// is an integer scale of 1-bit pixels, so nearest-neighbour keeps
	// every pixel crisp (GL_LINEAR blends the 1-bit edges and looks soft).
	for (size_t i = 0; i < sizeof(g_nat_buf) / sizeof(g_nat_buf[0]); i++)
		g_nat_buf[i] = 0xFF000000u;
	GLuint nat_tex = 0;
	glGenTextures(1, &nat_tex);
	glBindTexture(GL_TEXTURE_2D, nat_tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, VID_W, NAT_H, 0, GL_RGBA,
		     GL_UNSIGNED_BYTE, g_nat_buf);

	// Track map texture (below the screen; see build_map_tex()).
	GLuint map_tex = 0;
	glGenTextures(1, &map_tex);
	glBindTexture(GL_TEXTURE_2D, map_tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	build_map_tex();
	glBindTexture(GL_TEXTURE_2D, map_tex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, MAP_W, MAP_H, 0, GL_RGBA,
		     GL_UNSIGNED_BYTE, g_map_px);

	bool running = true;
	bool pause = false;
	// Default matches the whole-machine sim (sim_main.cpp batchSize
	// 650000 cycles/frame, no vsync): run at model throughput.  Here a
	// "slot" is one legacy eval() = one 35 ns half-period.
	int steps_per_frame = 650000;
	bool por_released = false;
	int reboot_clicks = 0;
	uint64_t reboot_t0_ps = 0;
	int frame = 0;
	uint32_t frame_ink = 0;
	uint32_t frame_rows = 0;
	int blit_diag_done = 0;  // one-shot blit diagnostics (1st video frame)
	// FPS (per presented frame, mirroring SimVideo::stats_fps)
	long old_time_ms = 0;
	float stats_fps = 0.0f;
	float stats_frame_time_ms = 0.0f;
	// SIM SPEED: exact sim-time accounting over a ~1-s wall window (the
	// pump advances sim time deterministically, so this is the true
	// throughput) -> displayed as a multiple of real time.
	long speed_anchor_ms = 0;
	uint64_t speed_anchor_sim_ps = 0;
	double sim_x_realtime = 0.0;
	unsigned long long win_sim_ms = 0, win_wall_ms = 0;

	while (running) {
		// ------------------------------------------------------ events
		SDL_Event e;
		while (SDL_PollEvent(&e)) {
			if (e.type == SDL_QUIT) running = false;
			// Ignore OS auto-repeat (e.key.repeat): a held key must
			// produce ONE machine keypress, not one per ~33 ms OS
			// repeat (same semantics as the whole machine's
			// sim_input.cpp and the level_1 GUI).
			if (e.type == SDL_KEYDOWN && !e.key.repeat) {
				// GUI-reserved: F9 pause, Alt+Q quit.  Every other
				// key is queued for the machine's PS/2 port
				// (//e codes).
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
				// Physical key-up queues a RELEASE event for every
				// key (bit 15).  The machine's keyboard FSM clears
				// akd / shift / ctrl only on a release code.
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
		g_r->tb_l2__DOT__stall = pause ? 1 : 0;  // checkbox/F9 -> TB reg
		g_act_active_ticks = 0;  // per-frame disk activity counters (reset
		g_act_rd_ticks = 0;      // before the frame's ticks are run; the
		g_act_wr_ticks = 0;      // panel below reports this frame's share)

		// ------------------------------------------- keyboard
		// Forward at most one queued entry this frame: stb held high
		// for 60 half-periods (keyboard.v latches on the stb 0->1
		// edge), then dropped.  entry = {release<<15, ext<<14, code}:
		// a press sets bit 9 (key state), a release clears it.
		if (g_keyq_n > 0) {
			const uint16_t k = g_keyq[--g_keyq_n];
			const uint16_t val =
			    (1 << 10) | ((k & 0x8000) ? 0 : (1 << 9)) |
			    ((k >> 14) << 8) | (k & 0xFF);
			for (int c = 0; c < 60; c++) {
				g_r->tb_l2__DOT__ps2_key = val;
				run_halfcycle();
			}
			g_r->tb_l2__DOT__ps2_key = 0;
			printf("L2_GUI KEY 0x%02X %s | kb rd_cnt=%u rd_k=0x%02X "
			       "akd_cnt=%u\n",
			       k & 0xFF, (k & 0x8000) ? "rel" : "press",
			       (unsigned)g_r->tb_l2__DOT__dbg_rd_cnt,
			       g_r->tb_l2__DOT__dbg_rd_k,
			       (unsigned)g_r->tb_l2__DOT__dbg_akd_cnt);
		}

		run_halfcycles(steps_per_frame);
		g_r->tb_l2__DOT__reset_cold = 0;  // C++ clears after each frame
		if (!por_released && g_r->tb_l2__DOT__power_on_reset == 0) {
			por_released = true;
			printf("L2_GUI POR released at sim=%.3fs; boot now starting\n",
			       g_sim_ps / 1e12);
		}

		// ------------------------------------------------------ video
		if (g_new_frame) {
			g_new_frame = false;
			frame_ink = g_frame_ink;
			frame_rows = g_frame_rows;
			if (frame_rows > NAT_H) frame_rows = NAT_H;
			if (frame_rows < 1) frame_rows = 1;
			// Convert into the texture buffer (0xAARRGGBB, alpha
			// 0xFF; rows beyond the frame keep their value) and
			// upload - same as the level_1 GUI.
			const int n = (int)frame_rows;
			for (int y = 0; y < n; y++)
				for (int x = 0; x < VID_W; x++)
					g_nat_buf[(size_t)y * VID_W + x] =
					    g_vbuf[(size_t)y * VID_W + x] ?
					    0xFFFFFFFFu : 0xFF000000u;
			glBindTexture(GL_TEXTURE_2D, nat_tex);
			glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, VID_W, NAT_H,
				     0, GL_RGBA, GL_UNSIGNED_BYTE, g_nat_buf);
			if (blit_diag_done == 0) {
				blit_diag_done = 1;
				printf("L2_GUI IMG 1st frame: rows=%u ink=%u "
				       "(texture %dx%d)\n",
				       (unsigned)frame_rows, (unsigned)frame_ink,
				       VID_W, NAT_H);
			}
		}

		// ------------------------------------------------------ frame
		ImGui_ImplOpenGL3_NewFrame();
		ImGui_ImplSDL2_NewFrame();
		ImGui::NewFrame();

		// Clear the whole drawable every frame: the imgui windows only
		// cover part of it, and without a clear the uncovered area shows
		// stale framebuffer contents (background glitches).
		glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);

		// --- main canvas: the area RIGHT of the pinned stats panel
		// (300 px) filling the remaining full window.  The video sits
		// at (300+8, 8) at the EXACT slider scale; imgui scrollbars
		// keep the whole picture reachable if the window is too small.
		const int vid_w = VID_W * scale / (half_h ? 2 : 1);
		const int vid_h = NAT_H * scale;
		ImGui::SetNextWindowPos(ImVec2(300.0f, 0.0f), ImGuiCond_Always);
		ImGui::SetNextWindowSize(
		    ImVec2(ImGui::GetIO().DisplaySize.x - 300.0f,
			(float)ImGui::GetIO().DisplaySize.y),
		    ImGuiCond_Always);
		ImGui::Begin("##l2_canvas", 0,
		    ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
		    ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse |
		    ImGuiWindowFlags_NoSavedSettings);
		ImGui::SetCursorPos(ImVec2(8.0f, 8.0f));
		ImGui::Image((ImTextureID)(intptr_t)nat_tex,
		    ImVec2((float)vid_w, (float)vid_h));
		ImGui::Dummy(ImVec2((float)(vid_w + 24), (float)(vid_h + 24)));
		// Track activity map directly under the screen: green = a track
		// the machine has read from (stays lit), white box = the track
		// currently requested.  Real imgui item, so it scrolls with the
		// canvas when the window is too small.  The Dummy above extends
		// the content region by ANOTHER full frame for the scrollbar, so
		// the map position is set explicitly instead of following the
		// cursor (which would leave a screen-height gap).
		{
			build_map_tex();
			glBindTexture(GL_TEXTURE_2D, map_tex);
			glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, MAP_W, MAP_H, 0,
			             GL_RGBA, GL_UNSIGNED_BYTE, g_map_px);
			ImGui::SetCursorPos(ImVec2(8.0f, 8.0f + (float)vid_h + 10.0f));
			ImGui::Image((ImTextureID)(intptr_t)map_tex,
			    ImVec2((float)MAP_W * scale, (float)MAP_H * scale));
			ImGui::Text("track map: green = track read, white box = current request");
			ImGui::Text("(rows: 0-31 / 32-63; cleared on Cold reboot)");
		}
		ImGui::End();

		// --- stats window: pinned at the TOP-LEFT, full height.
		ImGui::SetNextWindowPos(ImVec2(0.0f, 0.0f), ImGuiCond_Always);
		ImGui::SetNextWindowSize(ImVec2(300.0f, ImGui::GetIO().DisplaySize.y),
		    ImGuiCond_Always);
		ImGui::Begin("Apple II level_2 - machine + Disk II", 0,
		    ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove |
		    ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings);

		ImGui::Text("cpu: %s", cpu_name);
		ImGui::Text("frame_count: %d   FPS: %f", frame, stats_fps);
		ImGui::Text("frame time: %ld ms", (long)stats_frame_time_ms);
		ImGui::Text("sim speed (1 s): %.3fx real time", (float)sim_x_realtime);
		ImGui::Text("  %llu ms sim / %llu ms wall",
			 win_sim_ms, win_wall_ms);
		ImGui::Text("  (14.318 MHz master; model runs ~14-16x slower)");
		ImGui::Separator();

		// Integer scale only (crisp 1-bit pixels); changing it
		// resizes the SDL window too.  half_h: show the frame at
		// half displayed width (280 px active at 1x -> near square).
		ImGui::Text("scale (integer x)");
		if (ImGui::SliderInt("##scale", &scale, 1, 4) ||
		    ImGui::Checkbox("half horizontal (compact width)", &half_h)) {
			int ww = 0, hh = 0;
			l2_window_size(scale, half_h, &ww, &hh);
			SDL_SetWindowSize(window, ww, hh);
		}

		if (pause)
			ImGui::TextColored(ImVec4(1.0f, 0.8f, 0.2f, 1.0f), "PAUSED");
		else
			ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.5f, 1.0f), "RUNNING");
		ImGui::Checkbox("Pause (stall CPU)", &pause);
		ImGui::SameLine();
		if (ImGui::Button("Cold reboot")) {
			g_r->tb_l2__DOT__reset_cold = 1;
			reboot_clicks++;
			por_released = false;  // re-arm the POWER-ON HOLD banner
			reboot_t0_ps = g_sim_ps;
			for (int t = 0; t < 64; t++) g_trackmap[t] = false;
			g_last_track = -1;
		}

		ImGui::Text("sim time slots per frame");
		ImGui::SliderInt("##slots", &steps_per_frame, 1, 1750000);
		ImGui::Separator();
		ImGui::Text("disk: %s", disk_desc);
		ImGui::Text("sectors=%llu max_lba=%u bytes=%llu",
			 (unsigned long long)g_host.engine().readSectors(),
			 (unsigned)g_host.engine().maxLba(),
			 (unsigned)g_host.engine().readBytes());
		ImGui::Text("drive1: track=%d rdy=%d sd_rd=%d mot1=%u",
			 (int)g_r->tb_l2__DOT__h_d1_track,
			 (int)g_r->tb_l2__DOT__h_disk_ready,
			 (int)g_r->tb_l2__DOT__h_sd_rd,
			 (unsigned)g_r->tb_l2__DOT__dbg_motor1_cnt);
		// ------------------------------------------------- ACTIVITY VIEW
		// Whole-frame accumulation (see g_act_* above): the bar shows the
		// fraction of THIS frame's ticks during which the drive was
		// transferring; it pulses as DOS reads sectors.  The track map
		// stays lit for every track served so far - a boot fills it from
		// the left in track order.
		{
			const uint64_t ticks = (uint64_t)steps_per_frame + 60;
			const float rd_frac =
			    (float)g_act_rd_ticks / (float)ticks;
			const bool in_txn = g_host.engine().activeChannel() == 0;
			if (g_act_rd_ticks > 0 || in_txn)
				ImGui::TextColored(ImVec4(0.35f, 1.0f, 0.45f, 1.0f),
				                    "DISK ACT: READING (%.0f%%)",
				                    100.0f * rd_frac);
			else if (g_act_active_ticks > 0)
				ImGui::TextColored(ImVec4(0.9f, 0.8f, 0.3f, 1.0f),
				                    "DISK ACT: selected, no transfer");
			else
				ImGui::TextColored(ImVec4(0.5f, 0.5f, 0.5f, 1.0f),
				                    "DISK ACT: idle");
			ImGui::ProgressBar(rd_frac, ImVec2(-1.0f, 14.0f),
			    g_act_rd_ticks > 0 ?
			    "transferring" : "no transfer this frame");
			if (g_act_wr_ticks > 0)
				ImGui::TextColored(ImVec4(1.0f, 0.45f, 0.2f, 1.0f),
				                    "WRITE ACTIVITY: %llu ticks!",
				                    (unsigned long long)g_act_wr_ticks);
			ImGui::Text("track map: just under the screen (right side)");
			ImGui::Text("cur track=%d motor=%d act=%d io=%d step=%d",
			            g_last_track,
			            (int)g_r->tb_l2__DOT__h_d1_motor_on,
			            (int)g_r->tb_l2__DOT__h_d1_active,
			            (int)g_r->tb_l2__DOT__h_d1_io_active,
			            (int)g_r->tb_l2__DOT__h_d1_step_active);
		}
		ImGui::Separator();
		ImGui::Text("video lines/frame=%u  last_len=%u",
			 g_r->tb_l2__DOT__frame_lines,
			 g_r->tb_l2__DOT__last_len);
		ImGui::Text("last_act=%u  frames=%d",
			 g_r->tb_l2__DOT__last_act,
			 (int)g_r->tb_l2__DOT__frame_count);
		ImGui::Text("last frame ink=%u px", (unsigned)frame_ink);
		ImGui::Text("text_mode_s=%d  screen_ink=%u",
			 (int)g_r->tb_l2__DOT__text_mode_s,
			 (unsigned)g_r->tb_l2__DOT__screen_ink);
		ImGui::Separator();
		ImGui::Text("boot_sum=%08X boot_nz=%u (0=blank)",
			 (unsigned)g_r->tb_l2__DOT__dbg_boot_sum,
			 (unsigned)g_r->tb_l2__DOT__dbg_boot_nz);
		ImGui::Text("addr=$%04X  c0ec reads=%u D5=%u",
			 (unsigned)g_r->tb_l2__DOT__dbg_addr,
			 (unsigned)g_r->tb_l2__DOT__dbg_c0ec_cnt,
			 (unsigned)g_r->tb_l2__DOT__dbg_c0ec_d5);
		ImGui::Text("kb reads=%u last=0x%02X akd_cyc=%u",
			 (unsigned)g_r->tb_l2__DOT__dbg_rd_cnt,
			 g_r->tb_l2__DOT__dbg_rd_k,
			 (unsigned)g_r->tb_l2__DOT__dbg_akd_cnt);
		ImGui::Text("reset: rst=%d por=%d  flash_div=%u  reboots=%d",
			 (int)g_r->tb_l2__DOT__reset_sync,
			 (int)g_r->tb_l2__DOT__power_on_reset,
			 (unsigned)g_r->tb_l2__DOT__flash_div, reboot_clicks);
		if (!por_released) {
			const unsigned long long hold_ms =
			    (unsigned long long)((g_sim_ps - reboot_t0_ps) /
			                          1000000);
			ImGui::TextColored(ImVec4(1.0f, 0.9f, 0.3f, 1.0f),
			    "POWER-ON HOLD: %llu ms / 294 ms", hold_ms);
			ImGui::TextColored(ImVec4(1.0f, 0.9f, 0.3f, 1.0f),
			    "  (screen blank until release)");
		}
		ImGui::Separator();
		ImGui::TextDisabled("F9 pauses.  Alt+Q quits.  Other keys");
		ImGui::TextDisabled("go to the machine (//e scan codes:");
		ImGui::TextDisabled("letters, digits, Enter, Backspace,");
		ImGui::TextDisabled("Space, Tab, Esc, arrows, F2=reset).");
		ImGui::TextDisabled("With DOS up they land at the");
		ImGui::TextDisabled("READY. prompt.  Cold reboot re-runs");
		ImGui::TextDisabled("the power-on hold and re-boots.");

		ImGui::End();
		ImGui::Render();

		// The video is an ImGui::Image (GL texture), drawn by
		// ImGui_ImplOpenGL3_RenderDrawData below.  (the native
		// glDrawPixels path was a no-op on this driver)
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
		if (speed_anchor_ms == 0) {
			speed_anchor_ms = (long)t_ms;
			speed_anchor_sim_ps = g_sim_ps;
		} else if (t_ms - speed_anchor_ms >= 1000) {
			win_sim_ms = (unsigned long long)((g_sim_ps - speed_anchor_sim_ps)
							     / 1000000);
			win_wall_ms = (unsigned long long)(t_ms - speed_anchor_ms);
			sim_x_realtime = (double)win_sim_ms / (double)win_wall_ms;
			speed_anchor_ms = (long)t_ms;
			speed_anchor_sim_ps = g_sim_ps;
		}

		if (frame % 240 == 0)
			printf("L2_GUI FRAME %d  pause=%d  srv=%llu  sim=%.3fx\n",
			       frame, (int)pause,
			       (unsigned long long)g_host.engine().readSectors(),
			       (float)sim_x_realtime);
		if (max_frames > 0 && ++frame >= max_frames) {
			running = false;
			printf("L2_GUI run-frames limit reached (%d), exiting\n",
			       max_frames);
		} else {
			frame++;
		}
	}

	ImGui_ImplOpenGL3_Shutdown();
	ImGui_ImplSDL2_Shutdown();
	ImGui::DestroyContext();
	SDL_GL_DeleteContext(glctx);
	SDL_DestroyWindow(window);
	SDL_Quit();

	g_top->final();
	delete g_top;
	return 0;
}
