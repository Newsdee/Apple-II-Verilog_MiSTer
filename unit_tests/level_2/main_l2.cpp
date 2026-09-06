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
	const auto& ram0 = r->tb_l2__DOT__ram0;
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
			if (!no_pass && !do_write
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
					       (unsigned)r->tb_l2__DOT__ram0[0x0800 + row * 16 + i]);
				printf(" |");
				for (int i = 0; i < 16; i++) {
					unsigned c =
					    (unsigned)r->tb_l2__DOT__ram0[0x0800 + row * 16 + i];
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
				printf("%02X", (unsigned)r->tb_l2__DOT__ram0[0x0300 + i]);
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

	printf("\nL2 RESULT scenario=%s  frames=%d  ink=%u  sectors=%llu  "
	       "maxlba=%u  bytes=%llu  mot1=%u  ready=%d  addr=%04X  "
	       "sim=%.1fms wall=%.1fms\n",
	       do_write ? "write-test" : (do_disk ? "preloaded" : "empty"),
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
	const char* scen = do_write ? "WRITE-TEST" : (do_disk ? "PRELOADED" : "EMPTY");
	if (!pass)
		printf("L2 %s FAIL%s\n", scen, ran_to_timeout ? " (timeout)" : "");
	else
		printf("L2 %s PASS\n", scen);

	top->final();
	delete top;
	return status;
}
