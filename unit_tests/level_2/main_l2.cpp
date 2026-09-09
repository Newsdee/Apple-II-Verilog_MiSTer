// ============================================================================
// unit_tests/level_2/main_l2.cpp
//
// Headless Verilator main for the level_2 harness (machine core + real
// PS/2 keyboard + real Disk II slot controller + real floppy_track x2).
// LEGACY (non-timing) Verilator build: a C++-driven 14.3 MHz clock
// (one top->eval() per 35 ns toggle, like the full sim's SimClock /
// clk_sys) plus the host side of the floppy_track SD/blkdev interface,
// now served by the SHARED BlkDevEngine (l2_disk_host.h +
// verilator/sim/sim_blkdev_engine.h): two drive channels (ft1/ft2),
// per-drive .nib images, real MiSTer protocol timing, persistent writes
// to writable images, loud no-ack rejection of writes to read-only or
// unbound images (the source image is never modified).
//
// Two scenarios (command line):
//   --empty            no disk on drive 1 - the machine should cold-boot
//                      to the ROM monitor (as in level_1) with NO disk
//                      activity.  Pass: >=3 non-blank frames AND the host
//                      served 0 sectors AND the drive-1 motor never spun.
//   --disk <file.nib>  mount <file.nib> on drive 1 (read-only by
//                      default) - the machine should cold-boot DOS 3.3
//                      from it.  Pass: the host served a real number of
//                      sectors from the image (the disk was actually
//                      read end-to-end), the drive spun up, and the
//                      machine drew non-blank frames.
//   --readonly         mount the --disk image explicitly read-only
//                      (the default; kept for explicitness).
//   --scratch          copy the --disk image to <file>.l2scratch and
//                      mount THAT copy read-write (the original image
//                      is never modified even if the machine writes).
//   --write-test       directed dirty-track flush (PLAN v6 Phase 3/4):
//                      cold-boot from a SCRATCH COPY of the --disk image
//                      (always - the source image is never written), wait
//                      for the drive to go quiescent on a loaded track,
//                      force a 16-byte debug write into ft1's track RAM
//                      (TB dbg_ft_wr_* injection hook), and require the
//                      DUT's OWN dirty-track flush logic to save the track
//                      back over sd_wr.  Pass: the engine persists exactly
//                      13 write sectors (one track), the bus returns to
//                      idle (sd_wr=0, busy=0), the scratch image on disk
//                      holds the injected pattern on the flushed track
//                      only, every other track stays byte-identical, and
//                      the source image is untouched.  With no explicit
//                      --disk the default unit_tests/level_2/DOS_3_3.nib
//                      is used.  Default sim timeout: 10 s.
//   --savestate        directed save-state test (level_1b port, 2026-09-08):
//                      cold-boot from the --disk image, wait for the drive
//                      to go quiescent, SAVE (the savestate_manager_l1b
//                      freezes the machine and serializes CPU words 0-10
//                      + both 64 KiB RAM banks into the TB DDRAM model),
//                      snapshot the live state, run the machine (drift),
//                      perturb ONE byte of the STORED state in the DDRAM
//                      model, LOAD (machine stalled), and verify the full
//                      64 KiB main-RAM image matches the saved image with
//                      exactly that one byte changed, the CPU PC and the
//                      register shadow match, and the machine keeps
//                      running after the stall releases.  Pass: all of the
//                      above, no ss_error.  Requires --disk.  Default sim
//                      timeout: 10 s.
//
// +cpu=0 -> nmos6502, +cpu=1 -> wdc65c02.  --trace / --vcd=FILE for VCD.
//
// The binary MUST run with the process CWD at the REPO ROOT (the DUT's
// $readmemh ROM paths are CWD-relative).
//
// PACE: the full sim (sim_main.cpp::verilate) calls blockdevice.BeforeEval
// ONLY on the RISING edge of the system clock.  The track dpram commits one
// port-A write per 14.3 MHz posedge, so the host must present exactly one
// byte per 14.3 MHz posedge.  This harness drives the clock from C++ (one
// toggle per 35 ns) and calls beforeEval() immediately before the eval()
// that contains the rising edge.  Presenting on the falling edge too would
// stream 2 bytes per dpram commit and silently drop half of every sector.
//
// WHY LEGACY BUILD: with --timing, Verilator moves purely input-driven
// combinational cones (the dpram wren_a/data_a nets fed by the C++ host
// bus) into the stable region, which this Verilator (5.050) evaluates only
// once at init - freezing those nets at 0 so the track RAM never receives
// the host's bytes.  The legacy eval() re-evaluates everything each step.
// (Same trap in legacy builds: a DUT cone that is a pure function of
// top-level OUTPUT ports loses its driver - hence the host signals are
// tb_l2 INPUT ports, see the tb header comment.)
// ============================================================================
#include "Vtb_l2.h"
#include "Vtb_l2___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "l2_disk_host.h"

// Verilator (non-SystemC build) declares sc_time_stamp() weak.
double sc_time_stamp()
{
	return 0.0;
}

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Dump the text page ($0400-$07FF) so a boot state is human-readable.
// The Apple II text page is 24 rows x 40 cols = 960 bytes ($0400-$07BF).
// ---------------------------------------------------------------------------
static void dumpTextPage(Vtb_l2* top)
{
	auto* r = top->rootp;
	const auto& ram0 = r->tb_l2__DOT__main_ram__DOT__mem;
	printf("L2 TEXT PAGE $0400-$07BF (24x40):\n");
	for (int row = 0; row < 24; row++) {
		printf("  ");
		for (int col = 0; col < 40; col++) {
			const uint8_t c = ram0[0x0400 + row * 40 + col];
			char ch = (c >= 0x20 && c < 0x7f) ? (char)c : '.';
			putchar(ch);
		}
		printf("\n");
	}
}

// ---------------------------------------------------------------------------
// Save-state helpers (2026-09-08, level_1b port).
//
// The directed test: cold-boot + quiesce -> SAVE -> snapshot (full ram0
// image + PC + the manager's register shadow) -> run the machine (drift)
// -> perturb ONE byte of the stored state in the TB DDRAM model (slot
// word 0xA0 = main RAM byte $0400, lane 0) -> LOAD (with the machine
// stalled) -> verify the full 64 KiB main-RAM image matches the saved
// image with exactly that one byte changed, the CPU PC equals the saved
// PC, and the register shadow equals the saved shadow -> release the
// stall and confirm the machine keeps running.
// ---------------------------------------------------------------------------
static const uint32_t SS_PERTURB_ADDR = 0x0400;  // main RAM byte (text page)
// slot word = 32 + (byte >> 3) (the manager's RAM region base is word 32)
static const uint32_t SS_PERTURB_WORD = 32 + (SS_PERTURB_ADDR >> 3);  // 0xA0
static const uint64_t SS_PERTURB_MASK = 0x5A;    // byte lane 0 of that word

static uint16_t ssReadPC(Vtb_l2* top)
{
	auto* r = top->rootp;
	if (r->tb_l2__DOT__cpu_sel)
		return (uint16_t)r->tb_l2__DOT__d1__DOT__cpu65c02__DOT__reg_pc;
	return (uint16_t)r->tb_l2__DOT__d1__DOT__cpu6502__DOT__reg_pc;
}

// ---------------------------------------------------------------------------
// Read a whole file into a vector (write-test image oracle).
// ---------------------------------------------------------------------------
static std::vector<uint8_t> readWholeFile(const std::string& path)
{
	std::vector<uint8_t> v;
	std::ifstream f(path, std::ios::binary);
	if (!f)
		return v;
	f.seekg(0, std::ios::end);
	const std::streamsize sz = f.tellg();
	f.seekg(0, std::ios::beg);
	if (sz <= 0)
		return v;
	v.resize((size_t)sz);
	f.read((char*)v.data(), sz);
	if (!f)
		v.clear();
	return v;
}

// ---------------------------------------------------------------------------
int main(int argc, char** argv)
{
	bool  tracing   = false;
	bool  do_empty  = false;
	bool  do_disk   = false;
	bool  do_write  = false; // --write-test: directed dirty-track flush
	bool  do_ss     = false; // --savestate: directed save/perturb/load test
	bool  do_composite = false; // --composite: decoded composite video smoke
	uint8_t comp_sat = 0;       // --csat=N (decoder saturation, 128 = unity)
	uint8_t comp_hue = 0;       // --chue=N (decoder hue)
	int8_t  comp_bright = 0;    // --cbright=N (signed luma offset, 0 = none)
	uint8_t comp_contrast = 128;// --ccontrast=N (128 = unity)
	bool  do_ccal = false;      // --ccal: FPGA OSD "O4,Comp cal" preset
	int    comp_sat_idx = -1;   // --csatidx=N (0..15, FPGA OSD "OCD" coarse)
	int    comp_sat_fine = -1;  // --cfineidx=N (0..15, FPGA OSD "OL" fine)
	int    comp_hue_idx = -1;   // --chueidx=N (0..15, FPGA OSD "OHI" coarse)
	int    comp_hue_fine = -1;  // --hfineidx=N (0..15, FPGA OSD "OM" fine)
	bool  no_pass   = false;  // skip the early pass/break; run to full timeout
	bool  ro_mount  = false;  // --readonly: explicit read-only open
	bool  scratch   = false;  // --scratch: copy the image, mount the copy RW
	std::vector<uint8_t> wt_orig;  // write-test: source image before the run
	const char* vcdname  = "tb_l2.vcd";
	const char* nib_path = nullptr;
	double timeout_s = 0.0;  // 0 = per-scenario default

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--trace") == 0) {
			tracing = true;
		} else if (strncmp(argv[i], "--vcd=", 6) == 0) {
			tracing = true;
			vcdname = argv[i] + 6;
		} else if (strcmp(argv[i], "--empty") == 0) {
			do_empty = true;
		} else if (strcmp(argv[i], "--disk") == 0) {
			do_disk = true;
			if (i + 1 < argc)
				nib_path = argv[++i];
		} else if (strcmp(argv[i], "--timeout") == 0) {
			if (i + 1 < argc)
				timeout_s = atof(argv[++i]);
		} else if (strcmp(argv[i], "--no-pass") == 0) {
			no_pass = true;
		} else if (strcmp(argv[i], "--readonly") == 0) {
			ro_mount = true;
		} else if (strcmp(argv[i], "--scratch") == 0) {
			scratch = true;
		} else if (strcmp(argv[i], "--write-test") == 0) {
			do_write = true;
		} else if (strcmp(argv[i], "--savestate") == 0) {
			do_ss = true;  // --savestate: directed save/perturb/load test
		} else if (strcmp(argv[i], "--composite") == 0) {
			do_composite = true;
		} else if (strncmp(argv[i], "--csat=", 7) == 0) {
			comp_sat = (uint8_t)atoi(argv[i] + 7);
		} else if (strncmp(argv[i], "--chue=", 7) == 0) {
			comp_hue = (uint8_t)atoi(argv[i] + 7);
		} else if (strncmp(argv[i], "--csatidx=", 10) == 0) {
			comp_sat_idx = atoi(argv[i] + 10);
		} else if (strncmp(argv[i], "--cfineidx=", 11) == 0) {
			comp_sat_fine = atoi(argv[i] + 11);
		} else if (strncmp(argv[i], "--chueidx=", 10) == 0) {
			comp_hue_idx = atoi(argv[i] + 10);
		} else if (strncmp(argv[i], "--hfineidx=", 11) == 0) {
			comp_hue_fine = atoi(argv[i] + 11);
		} else if (strncmp(argv[i], "--cbright=", 10) == 0) {
			int b = atoi(argv[i] + 10);
			comp_bright = (int8_t)(b < -128 ? -128 : (b > 127 ? 127 : b));
		} else if (strncmp(argv[i], "--ccontrast=", 12) == 0) {
			comp_contrast = (uint8_t)atoi(argv[i] + 12);
		} else if (strcmp(argv[i], "--ccal") == 0) {
			do_ccal = true;
		}
	}
	if (do_write) {
		if (!nib_path)
			nib_path = "unit_tests/level_2/DOS_3_3.nib";
		wt_orig = readWholeFile(nib_path);
		do_disk = true;
	}
	if (!do_empty && !do_disk)
		do_empty = true;  // default scenario

	VerilatedContext context;
	context.commandArgs(argc, argv);
	context.traceEverOn(true);
	Vtb_l2* top = new Vtb_l2(&context);
	auto* r = top->rootp;

	VerilatedVcdC vcd;
	if (tracing) {
		context.trace(&vcd, 0);
		vcd.open(vcdname);
		if (!vcd.isOpen()) {
			printf("L2 ERROR: could not open %s\n", vcdname);
			delete top;
			return 2;
		}
	}

	L2DiskHost host;
	if (do_disk) {
		if (!nib_path) {
			printf("L2 ERROR: --disk requires a path\n");
			delete top;
			return 2;
		}
		std::string mount_path = nib_path;
		if (scratch || do_write) {
			// copy the image to a scratch file; mount the copy RW so the
			// original is never modified even if the machine writes
			mount_path = std::string(nib_path) + ".l2scratch";
			std::ifstream in(nib_path, std::ios::binary);
			std::ofstream out(mount_path, std::ios::binary | std::ios::trunc);
			if (!in || !out) {
				printf("L2 ERROR: cannot create scratch copy %s\n",
				       mount_path.c_str());
				delete top;
				return 2;
			}
			out << in.rdbuf();
			if (!out) {
				printf("L2 ERROR: scratch copy failed\n");
				delete top;
				return 2;
			}
			printf("L2 HOST: scratch copy %s -> %s (mounted RW)\n",
			       nib_path, mount_path.c_str());
			if (do_write)
				printf("L2 HOST: write-test: the SOURCE image %s is never\n"
				       "written; only the scratch copy can change.\n", nib_path);
		}
		if (!host.mountDrive(0, mount_path.c_str(), ro_mount)) {
			delete top;
			return 2;
		}
	}
	if (timeout_s <= 0.0)
		timeout_s = do_write ? 10.0 : (do_disk ? 6.0 : 1.5);
	const uint64_t timeout_ps = (uint64_t)(timeout_s * 1e12);

	printf("L2 scenario=%s cpu=%s timeout=%.2fs\n",
	       do_write ? "write-test" : (do_disk ? "preloaded" : "empty"),
	       (r->tb_l2__DOT__cpu_sel ? "wdc" : "nmos"), timeout_s);

	// Prime: run initial blocks at t=0.
	top->eval();

	// Composite video path (2026-09-07): static select + decoder knobs,
	// set once before the clock starts.  use_composite=0 (default) leaves
	// the composite cone frozen (ce=0) and its stats un-updated: the
	// default run is unchanged.  (Assigned below, after the --ccal preset
	// can flip it on.)
	// FPGA OSD knob parity (mister/Apple-II.sv "OCD"+fine "OL",
	// "OHI"+fine "OM"): coarse/fine pairs -> value = coarse*16 + fine
	// (exact 0..255 on both knobs; hue 255 = full rotation).  The idx
	// flags take precedence over raw --csat/--chue when either of a pair
	// is given.
	if (comp_sat_idx >= 0 || comp_sat_fine >= 0) {
		int c = (comp_sat_idx >= 0 && comp_sat_idx <= 15) ? comp_sat_idx : 0;
		int f = (comp_sat_fine >= 0 && comp_sat_fine <= 15) ? comp_sat_fine : 0;
		comp_sat = (uint8_t)(c * 16 + f);
	}
	if (comp_hue_idx >= 0 || comp_hue_fine >= 0) {
		int c = (comp_hue_idx >= 0 && comp_hue_idx <= 15) ? comp_hue_idx : 0;
		int f = (comp_hue_fine >= 0 && comp_hue_fine <= 15) ? comp_hue_fine : 0;
		comp_hue = (uint8_t)(c * 16 + f);
	}
	// FPGA OSD "O4,Comp cal" preset parity: one flag forces the four
	// calibrated values (2026-09-08) over everything else, and turns the
	// composite path on so a single flag is the fast setup.
	if (do_ccal) {
		do_composite = true;
		comp_sat      = 100;
		comp_hue      = 128;   // burst-locked identity (see CAL_HUE in mister/Apple-II.sv)
		comp_bright   = 12;
		comp_contrast = 114;
	}
	top->use_composite = do_composite ? 1 : 0;
	top->comp_sat      = comp_sat;
	top->comp_hue      = comp_hue;
	top->comp_bright   = (uint8_t)comp_bright;
	top->comp_contrast = comp_contrast;
	if (do_composite)
		printf("L2 composite path enabled sat=%u hue=%u bright=%d contrast=%u%s\n",
		       comp_sat, comp_hue, comp_bright, comp_contrast,
		       do_ccal ? " (cal preset)" : "");
	// Save-state request pulses: low until the phase machine arms one.
	top->ss_save_req = 0;
	top->ss_load_req = 0;
	if (do_ss)
		printf("L2 save-state test enabled (--savestate)\n");
	const auto wall0 = std::chrono::steady_clock::now();

	// C++-driven 14.3 MHz master clock: one toggle per 35 ns.  Legacy
	// (non-timing) eval() model, exactly like the full sim's SimClock
	// driving clk_sys: every eval() re-evaluates the whole combinational
	// cone, so C++ field writes (this clock + the SD host bus) are seen
	// by the next eval.  In --timing mode Verilator's stable region
	// freezes purely input-driven cones (wren_a/data_a) after t=0 and
	// the track RAM would never receive its host writes.
	const uint64_t half_ps = 35000;  // 35 ns per half-period
	uint64_t sim_ps = 0;             // sim time since t=0 (ps)
	bool clk_high = false;           // level driven this step

	const uint64_t status_every_ps = 200000000000ull;  // 200 ms (ps)
	uint64_t last_status_ps = 0;
	bool pass = false;
	bool ran_to_timeout = false;

	// ---- write-test phase machine (do_write only) ----
	enum { WT_BOOT = 0, WT_QUIESCE, WT_INJECT, WT_FLUSH, WT_DONE };
	int          wt_phase    = WT_BOOT;
	uint64_t     wt_phase_ps = 0;       // sim time in the current phase
	bool         wt_boot_ok    = false;
	uint32_t     wt_qrun       = 0;     // consecutive quiescent posedge ticks
	int          wt_inj_i      = -1;    // injection byte index
	bool         wt_wr_latched = false;
	uint32_t     wt_wr_lba     = 0;
	uint64_t     wt_wr_base    = 0;     // engine writeSectors at injection
	bool         wt_flush_done = false;
	const char*  wt_fail       = nullptr;
	std::vector<uint8_t> wt_pre;       // scratch image just before injection
	const uint64_t WT_QUIESCE_TICKS  = 1000;    // ~35 us sim of full idle
	const uint32_t INJ_BASE          = 0x19F0;  // last 16 B of the last sector
	const int      INJ_LEN           = 16;
	const uint32_t INJ_PAT0          = 0xA0;    // pattern bytes 0xA0..0xAF
	const uint64_t WT_BOOT_BUDGET    = 4000000000000ull;   // 4.0 s sim
	const uint64_t WT_QUIESCE_BUDGET = 6000000000000ull;   // 6.0 s sim (the
	                                                     // post-boot garbage OS keeps
	                                                     // reading sectors for ~4.3 s)
	const uint64_t WT_FLUSH_BUDGET   = 2000000000000ull;   // 2.0 s sim

	// ---- save-state phase machine (do_ss only) ----
	enum { SS_BOOT = 0, SS_QUIESCE, SS_SAVE, SS_DRIFT, SS_LOAD,
	       SS_VERIFY, SS_RUN, SS_DONE };
	int          ss_phase      = SS_BOOT;
	uint64_t     ss_phase_ps   = 0;       // sim time in the current phase
	uint32_t     ss_qrun       = 0;       // consecutive quiescent posedge ticks
	bool         ss_pend_save  = false;   // arm the save request next posedge
	bool         ss_pend_load  = false;   // arm the load request next posedge
	bool         ss_busy_hi    = false;   // saw ss_busy go high (tx started)
	bool         ss_busy_prev_was_hi = false;  // previous posedge's ss_busy
	bool         ss_err_seen   = false;   // ss_error observed at any point
	bool         ss_drift      = false;   // machine state changed during drift
	bool         ss_verify_ok  = false;
	bool         ss_resume_ok  = false;
	const char*  ss_fail       = nullptr;
	std::vector<uint8_t> ss_ram_saved;    // full 64 KiB main-RAM snapshot
	int          ss_frames_at_run = 0;   // frame_count when SS_RUN starts
	uint16_t     ss_pc_saved   = 0;
	uint64_t     ss_shadow_saved[11];     // manager register shadow at save
	const uint64_t SS_QUIESCE_BUDGET = 6000000000000ull;  // 6.0 s sim
	const uint64_t SS_TX_BUDGET      = 10000000000000ull; // 10.0 s sim
	const uint64_t SS_DRIFT_TIME     = 100000000000ull;   // 100 ms sim
	const uint64_t SS_RUN_TIME       = 50000000000ull;    // 50 ms sim
	while (!context.gotFinish()) {
		sim_ps += half_ps;
		clk_high = !clk_high;
		top->clk_14m = clk_high ? 1 : 0;
		// Host step only on the RISING edge (the full sim's BeforeEval
		// fires on IsRising() only: one byte presented per 14.3 MHz
		// posedge = one dpram port-A commit).
		if (clk_high) {
			// write-test injection: one debug track-RAM byte per rising
			// edge (the TB muxes it onto ft1's port-B inputs; the
			// dpram commits it at this posedge and floppy_track's
			// `dirty` latch sees ram_we while ready).
			if (do_write && wt_phase == WT_INJECT && wt_inj_i < INJ_LEN) {
				top->dbg_ft_wr_en   = 1;
				top->dbg_ft_wr_addr = INJ_BASE + (uint32_t)wt_inj_i;
				top->dbg_ft_wr_data = (uint8_t)(INJ_PAT0 + wt_inj_i);
				wt_inj_i++;
			} else {
				top->dbg_ft_wr_en = 0;
			}
			// save-state request pulses: exactly one posedge high.
			if (do_ss) {
				top->ss_save_req = ss_pend_save ? 1 : 0;
				top->ss_load_req = ss_pend_load ? 1 : 0;
				ss_pend_save = false;
				ss_pend_load = false;
			}
			host.tick(top);
		}
		top->eval();
			vcd.dump(sim_ps);

		const uint64_t now_ps = sim_ps;

		// Periodic status (diagnostic).
		if (now_ps - last_status_ps >= status_every_ps) {
			last_status_ps = now_ps;
			printf("  t=%5.2fs frames=%d ink=%u srv=%llu maxlba=%u "
			       "rdy=%d sd_rd=%d trk0=%d mot1=%u trk=%d lba=%u "
			       "addr=%04X boots=%08X bootn=%u d6=%02X d6n=%u "
			       "2m=%u 2ma=%u 2mdo=%02X 2maddr=%03X 2mnz=%d "
			       "t1a=%03X t1ai=%u t1ad=%u t1aw=%u t1ar=%u t1nz=%u "
			       "wra=%u wranz=%u wraddr=%03X wrdata=%02X wrb=%u "
			       "rst1=%u rstr=%u\n",
			       now_ps / 1e12,
			       (int)r->tb_l2__DOT__frame_count,
			       (unsigned)r->tb_l2__DOT__screen_ink,
			       (unsigned long long)host.engine().readSectors(),
			       (unsigned)host.engine().maxLba(),
			       (int)r->tb_l2__DOT__h_disk_ready,
			       (int)r->tb_l2__DOT__h_sd_rd,
			       (int)r->tb_l2__DOT__h_d1_trk0_step,
			       (unsigned)r->tb_l2__DOT__dbg_motor1_cnt,
			       (int)r->tb_l2__DOT__h_d1_track,
			       (unsigned)r->tb_l2__DOT__h_sd_lba_a,
			       (unsigned)r->tb_l2__DOT__dbg_addr,
			       (unsigned)r->tb_l2__DOT__dbg_boot_sum,
			       (unsigned)r->tb_l2__DOT__dbg_boot_nz,
			       (unsigned)r->tb_l2__DOT__dbg_dev6_data,
			       (unsigned)r->tb_l2__DOT__dbg_dev6_cnt,
			       (unsigned)r->tb_l2__DOT__dbg_2m_cnt,
			       (unsigned)r->tb_l2__DOT__dbg_2m_active_cnt,
			       (unsigned)r->tb_l2__DOT__dbg_2m_do,
			       (unsigned)r->tb_l2__DOT__dbg_2m_addr,
			       (int)r->tb_l2__DOT__dbg_2m_do_nz,
			       (unsigned)r->tb_l2__DOT__t1_addr_d,
			       (unsigned)r->tb_l2__DOT__dbg_t1a_inc,
			       (unsigned)r->tb_l2__DOT__dbg_t1a_dec,
			       (unsigned)r->tb_l2__DOT__dbg_t1a_wr,
			       (unsigned)r->tb_l2__DOT__dbg_t1a_rst,
			       (unsigned)r->tb_l2__DOT__dbg_t1a_nz,
			       (unsigned)r->tb_l2__DOT__dbg_wra_cnt,
			       (unsigned)r->tb_l2__DOT__dbg_wra_nz,
			       (unsigned)r->tb_l2__DOT__dbg_wra_addr,
			       (unsigned)r->tb_l2__DOT__dbg_wra_data,
			       (unsigned)r->tb_l2__DOT__dbg_wrb_cnt,
			       (unsigned)r->tb_l2__DOT__dbg_rst1_cnt,
			       (unsigned)r->tb_l2__DOT__dbg_rst_rise);
		}

		// Pass checks (evaluated once per completed frame + at end).
		const int frames = (int)r->tb_l2__DOT__frame_count;
		const uint32_t ink = r->tb_l2__DOT__screen_ink;

		if (do_empty) {
			if (frames >= 3 && ink > 0
			    && host.engine().readSectors() == 0
			    && r->tb_l2__DOT__dbg_motor1_cnt == 0) {
				pass = true;
				break;
			}
		} else {
			// preloaded: the disk was actually read (host served
			// a real number of sectors), the drive spun up, and the
			// machine drew non-blank frames.  (write-test drives its
			// own phase machine with the same boot criterion.)
			if (!no_pass && !do_write && !do_ss
			    && host.engine().readSectors() >= 10 && frames >= 3 && ink > 0
			    && r->tb_l2__DOT__dbg_motor1_cnt > 0) {
				pass = true;
				break;
			}
		}

		// ---- write-test phase machine (poses only) ----
		if (do_write && clk_high) {
			wt_phase_ps += 2 * half_ps;  // one full 14.3 MHz period per posedge
			const bool idle = ((r->tb_l2__DOT__h_sd_rd |
					    r->tb_l2__DOT__h_sd_wr) == 0)
			    && !host.engine().active()
			    && !r->tb_l2__DOT__h_d1_active
			    && !r->tb_l2__DOT__h_t1_busy
			    && (r->tb_l2__DOT__h_disk_ready & 0x1);
			switch (wt_phase) {
			case WT_BOOT:
				if (host.engine().readSectors() >= 10
				    && frames >= 3 && ink > 0
				    && r->tb_l2__DOT__dbg_motor1_cnt > 0) {
					wt_boot_ok = true;
					wt_phase    = WT_QUIESCE;
					wt_phase_ps = 0;
					wt_qrun     = 0;
					printf("L2 WRITE-TEST: boot reached "
					       "(sectors=%llu t=%.3fs) - waiting for the "
					       "drive to go quiescent\n",
					       (unsigned long long)host.engine().readSectors(),
					       now_ps / 1e12);
				} else if (wt_phase_ps >= WT_BOOT_BUDGET) {
					wt_fail  = "boot: no sector-read boot state within budget";
					wt_phase = WT_DONE;
				}
				break;
			case WT_QUIESCE:
				wt_qrun = idle ? wt_qrun + 1 : 0;
				if (wt_qrun >= WT_QUIESCE_TICKS) {
					wt_pre     = host.readImageBytes(0);
					wt_wr_base = host.engine().writeSectors();
					printf("L2 WRITE-TEST: drive quiescent (t=%.3fs "
					       "track=%u ready=%d) - injecting %d bytes "
					       "@0x%03X\n",
					       now_ps / 1e12,
					       (unsigned)r->tb_l2__DOT__ft1__DOT__unnamedblk1__DOT__cur_track,
					       (int)(r->tb_l2__DOT__h_disk_ready & 0x1),
					       INJ_LEN, INJ_BASE);
					wt_phase   = WT_INJECT;
					wt_phase_ps = 0;
					wt_inj_i   = 0;
				} else if (wt_phase_ps >= WT_QUIESCE_BUDGET) {
					wt_fail  = "quiesce: drive never went idle within budget";
					wt_phase = WT_DONE;
				}
				break;
			case WT_INJECT:
				if (wt_inj_i >= INJ_LEN) {
					printf("L2 WRITE-TEST: injection done - waiting for "
					       "the DUT's own dirty-track flush (sd_wr)\n");
					wt_phase    = WT_FLUSH;
					wt_phase_ps = 0;
				}
				break;
			case WT_FLUSH:
				if (!wt_wr_latched && (r->tb_l2__DOT__h_sd_wr & 0x1)) {
					wt_wr_lba     = r->tb_l2__DOT__h_sd_lba_a;
					wt_wr_latched = true;
					printf("L2 WRITE-TEST: flush started (sd_wr lba=%u "
					       "track=%u)\n",
					       (unsigned)wt_wr_lba, (unsigned)(wt_wr_lba / 13));
				}
				if (wt_wr_latched
				    && host.engine().writeSectors() - wt_wr_base >= 13
				    && !host.engine().active()
				    && !(r->tb_l2__DOT__h_sd_wr & 0x1)
				    && !r->tb_l2__DOT__h_t1_busy) {
					wt_flush_done = true;
					wt_phase      = WT_DONE;
					printf("L2 WRITE-TEST: flush complete "
					       "(writeSectors=%llu t=%.3fs)\n",
					       (unsigned long long)host.engine().writeSectors(),
					       now_ps / 1e12);
				} else if (wt_phase_ps >= WT_FLUSH_BUDGET) {
					wt_fail  = wt_wr_latched
					    ? "flush: engine did not settle within budget"
					    : "flush: sd_wr never asserted (drive stayed active/busy)";
					wt_phase = WT_DONE;
				}
				break;
			case WT_DONE:
				break;
			}
			if (wt_phase == WT_DONE)
				break;   // end the main loop; the verdict is computed below
		}

		// ---- save-state phase machine (poses only, do_ss) ----
		if (do_ss && clk_high) {
			ss_phase_ps += 2 * half_ps;  // one full 14.3 MHz period per posedge
			const bool idle = ((r->tb_l2__DOT__h_sd_rd |
					    r->tb_l2__DOT__h_sd_wr) == 0)
				&& !host.engine().active()
				&& !r->tb_l2__DOT__h_d1_active
				&& !r->tb_l2__DOT__h_t1_busy
				&& (r->tb_l2__DOT__h_disk_ready & 0x1);
			const bool ss_busy_now = (bool)r->tb_l2__DOT__ss_busy;
			if (r->tb_l2__DOT__ss_error)
				ss_err_seen = true;
			if (ss_busy_now && !ss_busy_hi)
				ss_busy_hi = true;
			switch (ss_phase) {
			case SS_BOOT:
				if (host.engine().readSectors() >= 10
				    && frames >= 3 && ink > 0
				    && r->tb_l2__DOT__dbg_motor1_cnt > 0) {
					printf("L2 SAVE-TEST: boot reached (sectors=%llu t=%.3fs) "
					       "- waiting for the drive to go quiescent\n",
					       (unsigned long long)host.engine().readSectors(),
					       now_ps / 1e12);
					ss_phase    = SS_QUIESCE;
					ss_phase_ps = 0;
					ss_qrun     = 0;
				} else if (ss_phase_ps >= WT_BOOT_BUDGET) {
					ss_fail  = "boot: no sector-read boot state within budget";
					ss_phase = SS_DONE;
				}
				break;
			case SS_QUIESCE:
				ss_qrun = idle ? ss_qrun + 1 : 0;
				if (ss_qrun >= WT_QUIESCE_TICKS) {
					// snapshot the live main-RAM image (64 KiB)
					const auto& ram0 = r->tb_l2__DOT__main_ram__DOT__mem;
					ss_ram_saved.resize(65536);
					for (uint32_t i = 0; i < 65536; i++)
						ss_ram_saved[i] = ram0[i];
					ss_pc_saved = ssReadPC(top);
					printf("L2 SAVE-TEST: drive quiescent (t=%.3fs pc=$%04X) "
					       "- saving\n", now_ps / 1e12, ss_pc_saved);
					ss_phase     = SS_SAVE;
					ss_phase_ps  = 0;
					ss_busy_hi   = false;
					ss_pend_save = true;
				} else if (ss_phase_ps >= SS_QUIESCE_BUDGET) {
					ss_fail  = "quiesce: drive never went idle within budget";
					ss_phase = SS_DONE;
				}
				break;
			case SS_SAVE:
				if (ss_busy_hi && ss_busy_prev_was_hi && !ss_busy_now) {
					const auto& shadow =
					    r->tb_l2__DOT__state_manager__DOT__register_shadow;
					for (int i = 0; i < 11; i++)
						ss_shadow_saved[i] = shadow[i];
					printf("L2 SAVE-TEST: save complete (t=%.3fs pc=$%04X) "
					       "- running the machine (drift)\n",
					       now_ps / 1e12, ss_pc_saved);
					ss_phase    = SS_DRIFT;
					ss_phase_ps = 0;
				} else if (ss_phase_ps >= SS_TX_BUDGET) {
					ss_fail  = ss_busy_hi
					    ? "save: transaction never completed within budget"
					    : "save: transaction never started";
					ss_phase = SS_DONE;
				}
				break;
			case SS_DRIFT:
				if (ss_phase_ps >= SS_DRIFT_TIME) {
					const auto& ram0 = r->tb_l2__DOT__main_ram__DOT__mem;
					uint32_t diff = 0;
					for (uint32_t i = 0; i < 65536; i++)
						if (ram0[i] != ss_ram_saved[i]) diff++;
					ss_drift = (diff > 0) || (ssReadPC(top) != ss_pc_saved);
					// Perturb ONE byte of the STORED state in the TB
					// DDRAM model: slot word 0xA0, lane 0 = main RAM $0400.
					auto& mem = r->tb_l2__DOT__ddram_mem;
					mem[SS_PERTURB_WORD] ^= SS_PERTURB_MASK;
					// Stall the machine for the load + verify window
					// (ss_busy also stalls during the transaction).
					// `stall` is a module-scope reg, not a port: write it
					// through the rootp path.
					r->tb_l2__DOT__stall = 1;
					printf("L2 SAVE-TEST: drift done (t=%.3fs ram_diff=%u "
					       "pc_drift=%d) - state perturbed @word 0x%X, loading\n",
					       now_ps / 1e12, diff, !ss_drift ? 0 : 1,
					       SS_PERTURB_WORD);
					ss_phase     = SS_LOAD;
					ss_phase_ps  = 0;
					ss_busy_hi   = false;
					ss_pend_load = true;
				}
				break;
			case SS_LOAD:
				if (ss_busy_hi && ss_busy_prev_was_hi && !ss_busy_now) {
					printf("L2 SAVE-TEST: load complete (t=%.3fs) - verifying\n",
					       now_ps / 1e12);
					ss_phase    = SS_VERIFY;
					ss_phase_ps = 0;
				} else if (ss_phase_ps >= SS_TX_BUDGET) {
					ss_fail  = ss_busy_hi
					    ? "load: transaction never completed within budget"
					    : "load: transaction never started";
					ss_phase = SS_DONE;
				}
				break;
			case SS_VERIFY:
				if (ss_phase_ps >= 20 * 2 * half_ps) {  // a few settle ticks
					const auto& ram0 = r->tb_l2__DOT__main_ram__DOT__mem;
					uint32_t mm = 0, first_mm = 0;
					for (uint32_t i = 0; i < 65536; i++) {
						const uint8_t want = ss_ram_saved[i]
						    ^ (i == SS_PERTURB_ADDR ? (uint8_t)SS_PERTURB_MASK : 0);
						if (ram0[i] != want) {
							if (mm == 0) first_mm = i;
							mm++;
						}
					}
					const uint16_t pc_now = ssReadPC(top);
					bool shadow_ok = true;
					const auto& shadow =
					    r->tb_l2__DOT__state_manager__DOT__register_shadow;
					for (int i = 0; i < 11; i++)
						if (shadow[i] != ss_shadow_saved[i]) shadow_ok = false;
					ss_verify_ok = (mm == 0) && (pc_now == ss_pc_saved)
					    && shadow_ok && !ss_err_seen;
					printf("L2 SAVE-TEST: verify ram_mm=%u (first $%04X) "
					       "pc=$%04X (saved $%04X) shadow=%d err=%d drift=%d %s\n",
					       mm, first_mm, pc_now, ss_pc_saved,
					       shadow_ok ? 1 : 0, ss_err_seen ? 1 : 0,
					       ss_drift ? 1 : 0,
					       ss_verify_ok ? "OK" : "FAIL");
					if (!ss_verify_ok && ss_fail == nullptr)
						ss_fail = "verify: post-load state mismatch";
					// Release the stall; confirm the machine resumes.
					r->tb_l2__DOT__stall = 0;
					ss_frames_at_run = (int)r->tb_l2__DOT__frame_count;
					ss_phase    = SS_RUN;
					ss_phase_ps = 0;
				}
				break;
			case SS_RUN: {
				if (ss_phase_ps >= SS_RUN_TIME) {
					ss_resume_ok = (r->tb_l2__DOT__frame_count >= ss_frames_at_run);
					printf("L2 SAVE-TEST: resume frames=%d (was %d) %s\n",
					       (int)r->tb_l2__DOT__frame_count, ss_frames_at_run,
					       ss_resume_ok ? "OK" : "FAIL");
					if (!ss_resume_ok && ss_fail == nullptr)
						ss_fail = "resume: machine did not continue after load";
					ss_phase = SS_DONE;
				}
				break;
			}
			case SS_DONE:
				break;
			}
			ss_busy_prev_was_hi = ss_busy_now;
			if (ss_phase == SS_DONE)
				break;   // end the main loop; the verdict is computed below
		}

		if (now_ps >= timeout_ps) {
			ran_to_timeout = true;
			break;
		}
	}

	if (tracing)
		vcd.close();

	// Post-run dpram forensics (drive 1): did the host's port-A writes
	// actually commit into the track RAM, and what do the port-B
	// registers say?  nonzero=0 => write path never committed (the
	// host/dpram handshake is the bug); nonzero>0 with 2mnz=0 => the
	// port-B read path is the bug.
	{
		auto& mem1 = r->tb_l2__DOT__ft1__DOT__floppy_dpram__DOT__mem;
		uint64_t nz = 0;
		unsigned first = 0x7FFF, last = 0;
		for (uint32_t i = 0; i < 8192; i++) {
			if (mem1[i] != 0) {
				nz++;
				if (first == 0x7FFF) first = (unsigned)i;
				last = (unsigned)i;
			}
		}
		printf("L2 DUMP ft1 dpram: mem nonzero=%llu first=%04X last=%04X "
			       "[0]=%02X [1]=%02X [200]=%02X [400]=%02X [1000]=%02X "
			       "addr_b_r=%03X data_b_r=%02X wren_b_r=%d "
			       "rel_lba=%u lba=%u cur_track=%u\n",
			       (unsigned long long)nz, first, last,
			       (unsigned)mem1[0], (unsigned)mem1[1],
			       (unsigned)mem1[0x200], (unsigned)mem1[0x400],
			       (unsigned)mem1[0x1000],
			       (unsigned)r->tb_l2__DOT__ft1__DOT__floppy_dpram__DOT__address_b_r,
			       (unsigned)r->tb_l2__DOT__ft1__DOT__floppy_dpram__DOT__data_b_r,
			       (int)r->tb_l2__DOT__ft1__DOT__floppy_dpram__DOT__wren_b_r,
			       (unsigned)r->tb_l2__DOT__ft1__DOT__rel_lba,
			       (unsigned)r->tb_l2__DOT__ft1__DOT__lba,
			       (unsigned)r->tb_l2__DOT__ft1__DOT__unnamedblk1__DOT__cur_track);

		// dpram vs mounted .nib (sync-search debug, 2026-09-05): does the
		// track RAM hold exactly the bytes the host served for the
		// drive's current track?  If the dpram == .nib track but the CPU
		// never saw the D5 AA 96 sync (offset 38), the read sweep or the
		// CPU-side sampling is broken, not the load.
		{
			const uint32_t cur_trk =
			    r->tb_l2__DOT__ft1__DOT__unnamedblk1__DOT__cur_track;
			// fresh on-disk read of the mounted image (reflects any
			// writes persisted since the mount)
			std::vector<uint8_t> img = host.readImageBytes(0);
			if (host.imageLoaded(0) && !img.empty()
			    && (uint64_t)cur_trk * 6656 + 6656 <= img.size()) {
				uint32_t mismatch = 0, first_mm = 0;
				uint32_t d5aa96_ram = 0, d5aa96_img = 0;
				for (uint32_t i = 0; i < 6656; i++) {
					if (mem1[i] != img[cur_trk * 6656 + i]) {
						if (mismatch == 0) first_mm = i;
						mismatch++;
					}
				}
				for (uint32_t i = 0; i + 2 < 6656; i++) {
					if (mem1[i] == 0xD5 && mem1[i + 1] == 0xAA
					    && mem1[i + 2] == 0x96)
						d5aa96_ram++;
					if (img[cur_trk * 6656 + i] == 0xD5
					    && img[cur_trk * 6656 + i + 1] == 0xAA
					    && img[cur_trk * 6656 + i + 2] == 0x96)
						d5aa96_img++;
				}
				printf("L2 DUMP dpram vs .nib track %u: mismatch=%u/6656 "
				       "first_mm=%04X d5aa96 ram=%u img=%u\n",
				       cur_trk, mismatch, first_mm,
				       d5aa96_ram, d5aa96_img);
				printf("L2 DUMP dpram[0..95]:");
				for (uint32_t i = 0; i < 96; i++)
					printf(" %02X", (unsigned)mem1[i]);
				printf("\nL2 DUMP .nib t%u[0..95]:", cur_trk);
				for (uint32_t i = 0; i < 96; i++)
					printf(" %02X",
					       (unsigned)img[cur_trk * 6656 + i]);
				printf("\n");
			}
		}

		// $C0EC read history (the bytes the CPU actually saw at the
		// disk_ii data register - the bootstrap scans this for D5).
		{
			printf("L2 DUMP $C0EC: reads=%u D5=%u AA=%u 96=%u  hist[oldest..newest]: ",
			       (unsigned)r->tb_l2__DOT__dbg_c0ec_cnt,
			       (unsigned)r->tb_l2__DOT__dbg_c0ec_d5,
			       (unsigned)r->tb_l2__DOT__dbg_c0ec_aa,
			       (unsigned)r->tb_l2__DOT__dbg_c0ec_96);
			const uint64_t idx = r->tb_l2__DOT__dbg_c0ec_idx;
			for (int i = 0; i < 64; i++)
				printf("%02X ",
				       (unsigned)r->tb_l2__DOT__dbg_c0ec_hist[(idx + i) & 63]);
			printf("\n");
		}

		// RAM $0800-$0BFF dump: where the P5 ROM's boot sequence puts
		// the sector data (86 B EORed to $0300-$0355 + 256 B to
		// $0856-$09E5) and where the CPU executes from after JMP $0801.
		{
			printf("L2 DUMP RAM $0800-$0BFF (hex | charset 00-1F=A-Z):\n");
			for (int row = 0; row < 16; row++) {
				printf("  $08%02X: ", row);
				for (int i = 0; i < 16; i++)
					printf("%02X ",
					       (unsigned)r->tb_l2__DOT__main_ram__DOT__mem[0x0800 + row * 16 + i]);
				printf(" |");
				for (int i = 0; i < 16; i++) {
					unsigned c =
					    (unsigned)r->tb_l2__DOT__main_ram__DOT__mem[0x0800 + row * 16 + i];
					if (c < 32)
						printf("%c", 'A' + c);
					else if (c < 127)
						printf("%c", c);
					else
						printf(".");
				}
				printf("\n");
			}
			printf("L2 DUMP RAM $0300-$035F (ROM table region): ");
			for (int i = 0; i < 96; i++)
				printf("%02X", (unsigned)r->tb_l2__DOT__main_ram__DOT__mem[0x0300 + i]);
			printf("\n");
		}
	}

	// ----------------------------------------------------------------
	// Disk slot 6 CPU port access log (TB io6_log).
	// ----------------------------------------------------------------
	{
		printf("L2 IO6: total=%u ioread=%u devrd=%u devwr=%u data_cnt=%u\n",
		       (unsigned)r->tb_l2__DOT__io6_total,
		       (unsigned)r->tb_l2__DOT__io6_ioread,
		       (unsigned)r->tb_l2__DOT__io6_devrd,
		       (unsigned)r->tb_l2__DOT__io6_devwr,
		       (unsigned)r->tb_l2__DOT__io6_data_cnt);
		printf("L2 IO6: last addr=%02X dout=%02X din=%02X kind=%d io_min=%02X io_max=%02X\n",
		       (unsigned)r->tb_l2__DOT__io6_last_addr,
		       (unsigned)r->tb_l2__DOT__io6_last_dout,
		       (unsigned)r->tb_l2__DOT__io6_last_din,
		       (int)r->tb_l2__DOT__io6_last_kind,
		       (unsigned)r->tb_l2__DOT__io6_io_min,
		       (unsigned)r->tb_l2__DOT__io6_io_max);
		printf("L2 IO6: iobmp:");
		for (int i = 31; i >= 0; i--)
			printf(" %02X", (unsigned)r->tb_l2__DOT__io6_iobmp[i]);
		printf("\nL2 IO6: data[0..127] (CPU $C08C reads):\n");
		for (int row = 0; row < 8; row++) {
			printf("  ");
			for (int i = 0; i < 16; i++)
				printf("%02X ", (unsigned)r->tb_l2__DOT__io6_data_log[row * 16 + i]);
			printf("\n");
		}
		printf("L2 IO6: writes (addr:din): ");
		for (int i = 0; i < 32; i++)
			printf("%04X ", (unsigned)r->tb_l2__DOT__io6_wr_log[i]);
		printf("\n");
	}

	const auto wall1 = std::chrono::steady_clock::now();
	const double wall_ms =
	    std::chrono::duration<double, std::milli>(wall1 - wall0).count();
	const double sim_ms = sim_ps / 1e9;

	if (do_disk)  // preloaded: show the screen so the boot is visible
		dumpTextPage(top);
	host.printStats("L2");

	// ----------------------------------------------------------------
	// Write-test verdict: the engine persisted exactly one track and
	// nothing failed; the scratch file shows the injected pattern on
	// the flushed track only (every other byte identical to the
	// pre-injection snapshot); the source image is byte-identical to
	// before the run; the injection really reached the DUT.
	// ----------------------------------------------------------------
	if (do_write) {
		if (wt_phase != WT_DONE && wt_fail == nullptr)
			wt_fail = "timeout reached before the write-test finished";
		bool wt_pass = wt_boot_ok && wt_flush_done && wt_wr_latched
		    && wt_fail == nullptr
		    && (host.engine().writeSectors() - wt_wr_base) == 13
		    && host.engine().failedWrites() == 0
		    && (uint32_t)r->tb_l2__DOT__dbg_wri_cnt == (uint32_t)INJ_LEN;
		const uint32_t ftrk = wt_wr_lba / 13;
		if (wt_pass && wt_wr_lba % 13 != 0) wt_pass = false;
		if (wt_pass && ftrk > 34) wt_pass = false;

		const std::vector<uint8_t> post = host.readImageBytes(0);
		uint32_t pat_hits = 0, other_mm = 0;
		if (wt_pass && !wt_pre.empty()
		    && wt_pre.size() == post.size()
		    && post.size() == (size_t)35 * 6656) {
			for (size_t i = 0; i < post.size(); i++) {
				const uint32_t trk = (uint32_t)(i / 6656);
				const uint32_t off = (uint32_t)(i % 6656);
				if (trk == ftrk && off >= INJ_BASE
				    && off < INJ_BASE + INJ_LEN) {
					if (post[i] == (uint8_t)(INJ_PAT0 + (off - INJ_BASE)))
						pat_hits++;
				}
				if (post[i] != wt_pre[i] &&
				    !((trk == ftrk && off >= INJ_BASE &&
				      off < INJ_BASE + INJ_LEN) &&
				      post[i] == (uint8_t)(INJ_PAT0 + (off - INJ_BASE))))
					other_mm++;
			}
		} else {
			wt_pass = false;
			if (wt_fail == nullptr)
				wt_fail = "scratch image missing or wrong size";
		}
		if (wt_pass && pat_hits != (uint32_t)INJ_LEN) wt_pass = false;
		if (wt_pass && other_mm != 0) wt_pass = false;

		// the SOURCE image must be byte-identical to before the run
		const std::vector<uint8_t> src = readWholeFile(nib_path);
		const bool src_unchanged = (src == wt_orig);
		if (wt_pass && !src_unchanged) wt_pass = false;

		printf("L2 WRITE-TEST: flush track=%u lba=%u sectors=%llu "
		       "failedWrites=%llu wri_cnt=%u pattern=%u/%d foreign_mm=%u\n",
		       (unsigned)ftrk, (unsigned)wt_wr_lba,
		       (unsigned long long)(host.engine().writeSectors() - wt_wr_base),
		       (unsigned long long)host.engine().failedWrites(),
		       (unsigned)r->tb_l2__DOT__dbg_wri_cnt,
		       (unsigned)pat_hits, INJ_LEN, (unsigned)other_mm);
		printf("L2 WRITE-TEST: source image unchanged=%d (size %zu), "
		       "scratch %zu bytes\n",
		       (int)src_unchanged, wt_orig.size(), post.size());
		if (wt_fail)
			printf("L2 WRITE-TEST: reason: %s\n", wt_fail);
		if (wt_pass)
			pass = true;
	}

	// ----------------------------------------------------------------
	// Composite smoke (--composite): the decoded composite frame over the
	// last completed frame must (a) show the screen's bright content
	// (gmax high, ink > 0), (b) not mass-brighten the background (ink
	// within 4x the mono 1-bit ink of the last frame), and (c) at sat=0
	// be pure gray (no chroma); at sat>0 the 1-bit dither content must
	// show colour (nongray > 0).
	// ----------------------------------------------------------------
	if (do_composite) {
		const uint32_t ci  = r->tb_l2__DOT__comp_ink;
		const uint32_t cn  = r->tb_l2__DOT__comp_nongray;
		const uint32_t gmn = r->tb_l2__DOT__comp_gmin;
		const uint32_t gmx = r->tb_l2__DOT__comp_gmax;
		// Mono reference: ink of the last COMPLETED frame (latched at the same
		// VBL falling edge as comp_ink/comp_nongray).  Reading frame[] here
		// would give the NEXT frame's content, which is a different screen.
		uint32_t mono_ink = (uint32_t)r->tb_l2__DOT__mono_ink_frame_l;
		bool comp_pass = (ci > 0) && (gmx >= 160)
		    && (mono_ink > 0) && (ci <= 4u * mono_ink)
		    && ((comp_sat == 0) ? (cn == 0) : (cn > 0));
		printf("L2 COMPOSITE: ink=%u mono_ink=%u nongray=%u gmin=%u gmax=%u "
		       "sat=%u hue=%u %s\n",
		       (unsigned)ci, (unsigned)mono_ink, (unsigned)cn,
		       (unsigned)gmn, (unsigned)gmx, comp_sat, comp_hue,
		       comp_pass ? "OK" : "FAIL");
		if (!comp_pass) pass = false;
		// Hue probe (2026-09-09): average RGB hue angle of the dark
		// (background) and bright (text/edge) nongray bands.  Print-only,
		// no pass/fail: the hue-knob matrix run uses these to pick the
		// CAL_HUE constant and to prove the decoder's sine path is linear
		// (+16 knob steps = +22.5 deg rotation).
		{
			auto band = [](uint32_t n, uint32_t sr, uint32_t sg, uint32_t sb) {
				struct Band { double r, g, b, ang; } v{0.0, 0.0, 0.0, -1000.0};
				if (!n) return v;
				v.r = double(sr) / double(n);
				v.g = double(sg) / double(n);
				v.b = double(sb) / double(n);
				const double mx = v.r > v.g ? (v.r > v.b ? v.r : v.b)
				                           : (v.g > v.b ? v.g : v.b);
				const double mn = v.r < v.g ? (v.r < v.b ? v.r : v.b)
				                           : (v.g < v.b ? v.g : v.b);
				const double c = mx - mn;
				if (c < 1e-3) { v.ang = -1.0; return v; } // near gray
				double h;
				if (mx == v.r)      h = std::fmod((v.g - v.b) / c, 6.0);
				else if (mx == v.g) h = (v.b - v.r) / c + 2.0;
				else                h = (v.r - v.g) / c + 4.0;
				h *= 60.0;
				if (h < 0.0) h += 360.0;
				v.ang = h;
				return v;
			};
			const auto dk = band((uint32_t)r->tb_l2__DOT__comp_dark_n,
				                 (uint32_t)r->tb_l2__DOT__comp_dark_sr,
				                 (uint32_t)r->tb_l2__DOT__comp_dark_sg,
				                 (uint32_t)r->tb_l2__DOT__comp_dark_sb);
			const auto br = band((uint32_t)r->tb_l2__DOT__comp_bri_n,
				                 (uint32_t)r->tb_l2__DOT__comp_bri_sr,
				                 (uint32_t)r->tb_l2__DOT__comp_bri_sg,
				                 (uint32_t)r->tb_l2__DOT__comp_bri_sb);
			printf("  hue-probe dark:   n=%7u avg=(%6.1f,%6.1f,%6.1f) angle=%7.1f deg\n",
			        (unsigned)r->tb_l2__DOT__comp_dark_n,
			        dk.r, dk.g, dk.b, dk.ang);
			printf("  hue-probe bright: n=%7u avg=(%6.1f,%6.1f,%6.1f) angle=%7.1f deg\n",
			        (unsigned)r->tb_l2__DOT__comp_bri_n,
			        br.r, br.g, br.b, br.ang);
			// Phase-class + flat-background (matrix round 2, 2026-09-09):
			// the 4 subcarrier-phase artifact colors rotate RIGIDLY with the
			// hue knob (-22.5 deg per +16 knob steps), unlike the threshold
			// band averages; bg = decoded flat dark background tint.
			const unsigned pn[4] = { (unsigned)r->tb_l2__DOT__comp_p0_n,
			                         (unsigned)r->tb_l2__DOT__comp_p1_n,
			                         (unsigned)r->tb_l2__DOT__comp_p2_n,
			                         (unsigned)r->tb_l2__DOT__comp_p3_n };
			const unsigned pr[4] = { (unsigned)r->tb_l2__DOT__comp_p0_sr,
			                         (unsigned)r->tb_l2__DOT__comp_p1_sr,
			                         (unsigned)r->tb_l2__DOT__comp_p2_sr,
			                         (unsigned)r->tb_l2__DOT__comp_p3_sr };
			const unsigned pg[4] = { (unsigned)r->tb_l2__DOT__comp_p0_sg,
			                         (unsigned)r->tb_l2__DOT__comp_p1_sg,
			                         (unsigned)r->tb_l2__DOT__comp_p2_sg,
			                         (unsigned)r->tb_l2__DOT__comp_p3_sg };
			const unsigned pb[4] = { (unsigned)r->tb_l2__DOT__comp_p0_sb,
			                         (unsigned)r->tb_l2__DOT__comp_p1_sb,
			                         (unsigned)r->tb_l2__DOT__comp_p2_sb,
			                         (unsigned)r->tb_l2__DOT__comp_p3_sb };
			for (int p = 0; p < 4; p++) {
				const auto pc = band(pn[p], pr[p], pg[p], pb[p]);
				printf("  hue-probe p%d: n=%7u avg=(%6.1f,%6.1f,%6.1f) angle=%7.1f deg\n",
				        p, pn[p], pc.r, pc.g, pc.b, pc.ang);
			}
			const auto bg = band((unsigned)r->tb_l2__DOT__comp_bg_n,
			                     (unsigned)r->tb_l2__DOT__comp_bg_sr,
			                     (unsigned)r->tb_l2__DOT__comp_bg_sg,
			                     (unsigned)r->tb_l2__DOT__comp_bg_sb);
			printf("  hue-probe bg:   n=%7u avg=(%6.1f,%6.1f,%6.1f) angle=%7.1f deg\n",
			        (unsigned)r->tb_l2__DOT__comp_bg_n,
			        bg.r, bg.g, bg.b, bg.ang);
			// Round 2b: up/down edges split by luma slope (per-class averages
			// of the combined set cancel: up+down chroma are 180 deg apart).
			for (int p = 0; p < 4; p++) {
				const auto uc = band((unsigned)r->tb_l2__DOT__comp_un[p],
				                     (unsigned)r->tb_l2__DOT__comp_ur[p],
				                     (unsigned)r->tb_l2__DOT__comp_ug[p],
				                     (unsigned)r->tb_l2__DOT__comp_ub[p]);
				printf("  hue-probe u%d: n=%7u avg=(%6.1f,%6.1f,%6.1f) angle=%7.1f deg\n",
				        p, (unsigned)r->tb_l2__DOT__comp_un[p],
				        uc.r, uc.g, uc.b, uc.ang);
			}
			for (int p = 0; p < 4; p++) {
				const auto dc = band((unsigned)r->tb_l2__DOT__comp_dn[p],
				                     (unsigned)r->tb_l2__DOT__comp_dr[p],
				                     (unsigned)r->tb_l2__DOT__comp_dg[p],
				                     (unsigned)r->tb_l2__DOT__comp_db[p]);
				printf("  hue-probe d%d: n=%7u avg=(%6.1f,%6.1f,%6.1f) angle=%7.1f deg\n",
				        p, (unsigned)r->tb_l2__DOT__comp_dn[p],
				        dc.r, dc.g, dc.b, dc.ang);
			}
			// Round 2c: raw demodulated I/Q class sums (pre-YIQ/RGB, un-gated
			// geometric pixel set).  Each sum rotates RIGIDLY with the hue
			// knob; the angle is the I/Q-plane palette angle (0 = I axis).
			// The 48-bit sums wrap: the RTL member is uint64_t storage, so
			// sign-extend from bit 47 (the values are small, ~+/-1e6).
			auto iq48 = [](uint64_t raw) -> int64_t {
				return (raw & (1ULL << 47)) ? (int64_t)(raw | (~0ULL << 48))
				                               : (int64_t)raw;
			};
			const char* iqq[3][4] = { { "i0", "i1", "i2", "i3" },
			                          { "iu0", "iu1", "iu2", "iu3" },
			                          { "id0", "id1", "id2", "id3" } };
			for (int s = 0; s < 3; s++) {
				for (int p = 0; p < 4; p++) {
					const int64_t ii = (s == 0) ? iq48(r->tb_l2__DOT__comp_li8[p])
					                          : (s == 1) ? iq48(r->tb_l2__DOT__comp_li8u[p])
					                          : iq48(r->tb_l2__DOT__comp_li8d[p]);
					const int64_t qq = (s == 0) ? iq48(r->tb_l2__DOT__comp_lq8[p])
					                          : (s == 1) ? iq48(r->tb_l2__DOT__comp_lq8u[p])
					                          : iq48(r->tb_l2__DOT__comp_lq8d[p]);
					double a = std::atan2((double)qq, (double)ii) * 180.0 / 3.14159265358979323846;
					if (a < 0.0) a += 360.0;
					printf("  hue-probe %s: I=%lld Q=%lld angle=%7.1f deg\n",
					        iqq[s][p], (long long)ii, (long long)qq, a);
				}
			}
			// Round 2d: PEAK-pixel I/Q per phase class.  Every peak pixel
			// in one class points at the same I/Q angle 90c + Phi(K), so
			// each per-class sum is a high-SNR rigid vector.  Phi is the
			// palette constant; K* = Phi(0)/1.40625 (mod 256) puts class 0
			// on the red (I) axis.  xchk: raw burst vector (pre-knob) +
			// LO/burst counter alignment (P-B mod 4 = s_p - s_b).
			const char* pkl[2][4] = { { "pku0", "pku1", "pku2", "pku3" },
			                           { "pkd0", "pkd1", "pkd2", "pkd3" } };
			for (int s = 0; s < 2; s++) {
				for (int p = 0; p < 4; p++) {
					const int64_t ii = (s == 0) ? iq48(r->tb_l2__DOT__comp_lpki[p])
					                            : iq48(r->tb_l2__DOT__comp_lpki_d[p]);
					const int64_t qq = (s == 0) ? iq48(r->tb_l2__DOT__comp_lpq[p])
					                            : iq48(r->tb_l2__DOT__comp_lpq_d[p]);
					const unsigned nn = (s == 0) ? (unsigned)r->tb_l2__DOT__comp_lpn_u[p]
					                             : (unsigned)r->tb_l2__DOT__comp_lpn_d[p];
					double a = std::atan2((double)qq, (double)ii) * 180.0 / 3.14159265358979323846;
					if (a < 0.0) a += 360.0;
					double phi = a - 90.0 * p;
					while (phi < 0.0) phi += 360.0;
					while (phi >= 360.0) phi -= 360.0;
					printf("  hue-probe %s: n=%6u I=%lld Q=%lld angle=%7.1f phi=%7.1f deg\n",
					        pkl[s][p], nn, (long long)ii, (long long)qq, a, phi);
				}
			}
			{
				const int xib = (int)(int16_t)r->tb_l2__DOT__comp_lxib;
				const int xqb = (int)(int16_t)r->tb_l2__DOT__comp_lxqb;
				double a = std::atan2((double)xqb, (double)xib) * 180.0 / 3.14159265358979323846;
				if (a < 0.0) a += 360.0;
				printf("  hue-probe xchk: P=%d B=%d raw_burst=(%d,%d) angle=%7.1f deg\n",
				        (int)r->tb_l2__DOT__comp_lxP, (int)r->tb_l2__DOT__comp_lxB,
				        xib, xqb, a);
			}
		}
	}

	// ----------------------------------------------------------------
	// Save-state verdict (--savestate): the directed save/perturb/load
	// test passes when the post-load machine state equals the saved
	// state with exactly the one perturbed byte applied, the CPU PC and
	// register shadow match, no ss_error fired, and the machine keeps
	// running after the stall releases.
	// ----------------------------------------------------------------
	if (do_ss) {
		bool ss_pass = (ss_phase == SS_DONE)
		    && ss_verify_ok && ss_resume_ok && !ss_err_seen;
		if (ss_fail == nullptr && ss_phase != SS_DONE)
			ss_fail = "phase machine did not complete (loop exited early)";
		if (ss_fail)
			printf("L2 SAVE-TEST: reason: %s\n", ss_fail);
		if (ss_pass) { if (!do_write && !do_composite) pass = true; }
		else pass = false;
	}

	printf("\nL2 RESULT scenario=%s  frames=%d  ink=%u  sectors=%llu  "
	       "maxlba=%u  bytes=%llu  mot1=%u  ready=%d  addr=%04X  "
	       "sim=%.1fms wall=%.1fms\n",
	       do_write ? "write-test" : (do_ss ? "save-test"
	                                        : (do_disk ? "preloaded" : "empty")),
	       (int)r->tb_l2__DOT__frame_count,
	       (unsigned)r->tb_l2__DOT__screen_ink,
	       (unsigned long long)host.engine().readSectors(),
	       (unsigned)host.engine().maxLba(),
	       (unsigned long long)host.engine().readBytes(),
	       (unsigned)r->tb_l2__DOT__dbg_motor1_cnt,
	       (int)r->tb_l2__DOT__h_disk_ready,
	       (unsigned)r->tb_l2__DOT__dbg_addr,
	       sim_ms, wall_ms);

	// Empty scenario: also confirm the drive never came ready (no disk).
	if (do_empty && r->tb_l2__DOT__h_disk_ready != 0)
		pass = false;

	int status = pass ? 0 : 1;
	const char* scen = do_write ? "WRITE-TEST"
	    : (do_ss ? "SAVE-TEST" : (do_disk ? "PRELOADED" : "EMPTY"));
	if (!pass)
		printf("L2 %s FAIL%s\n", scen, ran_to_timeout ? " (timeout)" : "");
	else
		printf("L2 %s PASS\n", scen);

	top->final();
	delete top;
	return status;
}
