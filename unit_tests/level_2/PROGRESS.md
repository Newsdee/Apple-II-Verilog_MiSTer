# Level_2 DOS 3.3 boot — PROGRESS (v7, WRITE-TEST GREEN, 2026-09-06 ~16:05)

v5: the level_2 imgui GUI landed and the headless smoke PASSES (fresh run
verified this session). v4 (disk-read debug) remains RESOLVED and stands.
This file keeps the v1/v2/v3/v4 history (corrections marked, not deleted)
because future sessions rely on it.

## v5 — 2026-09-06: GUI landed; direction reset (GUI-first)

### What session 01a07314 did (crashed ~04:25 local)
1. Reconstructed context from the 01a07232 → 01a07273 session chain.
2. Built the level_2 imgui GUI: `gui/main_gui.cpp` (~1250 lines — same
   `tb_l2` top as the headless harness; headless smoke + windowed
   imgui/SDL2/OpenGL3 path; pump = the same legacy-eval 35 ns half-cycle
   drive), `Makefile gui` target, `run_l2.sh gui` branch, `run_l2_gui.bat`.
   Window controls: F9/Pause stall, cold-reboot button, PS/2 keys (F2 =
   soft reset), `--run-frames`, `--scale`.
3. Fixed the frame_valid pump bug: `tb_l2`'s `frame_valid` is a LATCH
   (set on VBL-fall, never cleared). The first GUI pump treated it as a
   pulse and called extract_frame() every half-cycle → pump speed ~0.0001×
   (900 s tool timeout). Fix: C++ clears the latch after consuming the
   frame (the level_1 pattern). After the fix: full model throughput.
4. Fixed the headless boot-phase gate: the 5-frame gate alone was met
   DURING the 294 ms power-on hold (frame 1 at ~17 ms sim; frame 5 at
   ~84 ms — before any disk activity starts at ~294 ms). Now
   pass-condition driven, like the proven headless harness: frames +
   ink>0 + sectors>=10 + mot1>0 (empty scenario: no sectors + no motor),
   with a 3.5 s / 1.5 s sim budget as ceiling.
5. PHASE_ZERO_F (PHI0_EN_F) confirmed a ~1.02 MHz CPU-enable tick (NOT the
   14.3 MHz master) that keeps pulsing under STALL → used as the stall
   check's free-running master.
6. One-shot PBM dump of the last presented frame at headless pass/fail
   (`out/l2_gui_headless*.pbm`) + the `pbm_*.pl` preview helpers.
7. DETOUR (user judged it the wrong direction — PARKED): forensics of the
   power-on screen's full-screen "diagonal stripe" pattern — glyph search
   in video2.hex (0 hits; the file is 24-byte lines, my 16-byte parse
   miscounted), ROM power-on disasm ($C3FA → $FDED dispatcher → $C600
   bootstrap), font-ROM read. State at detour end: the pattern is genuine
   DUT video (ink 18595 → 67779 after POR release); whether it is the
   intended power-on screen or an OS-completion question is deferred to
   the user's visual check in the GUI window.
8. Crash point: the final edit (a `dump_tscreen` text-screen RAM
   $0400–$07FF hex dump in `gui/main_gui.cpp`) was ISSUED but did not
   land — verified absent from the on-disk file. On-disk sources equal
   the last successful build (no rebuild needed; see below).

### Direction reset (user, 2026-09-06)
- **Priority 1: the level_2 GUI works so the user watches the DOS 3.3
  boot sequence with their own eyes and confirms it.** READY NOW:
  - `run_l2_gui.bat` — window, nmos + DOS_3_3.nib (the default). The 294 ms
    sim power-on hold plays at sim speed; after POR release the drive
    homes (17→0, ~0.8 s sim) and the DOS boot runs; keyboard works (at
    the READY. prompt, keys land in DOS).
  - `run_l2_gui.bat --headless [N] [--selfkey] [--reboot]` — headless
    smoke, exit 0 on PASS.
- If a video fault is suspected: **level_1 is the video bisection level**
  (video + keyboard, no disk).
- v4 step 5 (mostly-blank text page vs ink=969 at 12 s) and step 6
  (pass-criterion rework) are PARKED pending the user's visual check —
  the GUI makes "is the boot real" a human judgment.

### Fresh verification (2026-09-06 ~04:35 local, this session)
- `mingw32-make -C unit_tests/level_2 gui` → no-op (build current:
  `Vtb_l2.exe` 04:18 is not older than `tb_l2.sv` 03:45 or
  `gui/main_gui.cpp` 04:18).
- Headless smoke from the repo root, `+cpu=0 --headless 5 --selfkey
  --reboot` (DOS_3_3.nib):
  - `L2_GUI SMOKE PASS cpu=nmos6502  (boot ok, selfkey ok, reboot ok)`,
    exit 0.
  - Final: frames=25/5, ink=67779, sectors=262, maxlba=246, mot1=1,
    sim=2.73 s. Boot phase passed at ~0.45 s sim (sectors>=10 at 0.40 s;
    motor+first step ~0.45 s). Homing 17→0 streamed 0.294→1.134 s sim.
  - STALL PASS: master 438465→445592 (~1.02 MHz ✓), addr frozen $FCAE
    (the $FCAB stepper-wait region, consistent with the v4 note).
  - SELFKEY PASS: akd 0→58, last=0x20 (0xC1 'A' press).
  - REBOOT PASS: pulse OK, POR re-release OK, new-frame OK (ink=191).
- Cosmetic defect (display-only, NOT fixed): the RESULT line printed
  `wall=-16.4s` — `now_ms()` (gui/main_gui.cpp:123) is built from
  GetSystemTime seconds+milliseconds only (no hour field, non-
  monotonic), so a run crossing a minute/hour boundary prints a negative
  wall time. The windowed sim-speed window has the same latent glitch.
  Fix when touched: std::chrono::steady_clock.

### Not landed / parked
- `dump_tscreen` (text-screen RAM hex dump) — crashed session's last edit,
  not on disk. Re-add if/when the text-page question is re-opened; the
  GUI window is the better tool for that judgment.
- v4 step 5 (12 s text page mostly blank; reconcile `ink` with the active
  video page $0400+$0801) — parked for the user's visual check.
- v4 step 6 (pass criterion requiring real boot evidence: boot-block
  checksum / bootn>0 / PC in $0800–$0FFF) — deferred. The headless boot
  phase now requires real sector reads + motor spin, and the windowed
  path surfaces the live `bootn` (boot-block non-zero byte count).
- v4 step 8 (full-machine `Vemu.exe --smoke-test`) — still open. No
  `rtl/` file was changed by the level_2/GUI work (harness-only), so the
  machine smoke is unaffected; it remains a pre-commit hygiene item.

## STATUS — RESOLVED (v4 disk-read debug; superseded where v5 notes say)
The Disk II read path is **functional and deterministic** in the current build.
The CPU does **NOT** get stuck reading $00 from $C0EC. The original premise
("CPU reads $00 while dpram/.nib hold D5 AA 96") was a **misdiagnosis** from an
older host build + too-short (1.2 s) runs. Evidence (below) is reproducible.

## v4 CORRECTION (overturns the v3 "stuck in sync scan" model)
The v3 model claimed the CPU is stuck in the $C65E–$C665 sync scan reading $00
(every $C0EC read = $00, persistent into the 15 s run). **This is wrong.**

The decisive runs (current build, `--timeout 5`, reproduced twice identically:
l2_boot5.log and l2_boot5b.log, `+cpu=0 --disk DOS_3_3.nib`):
- `L2 DUMP dpram vs .nib track 0: mismatch=0/6656 d5aa96 ram=16 img=16`
  → the host loaded track 0 **byte-perfect**; 16 D5AA96 markers in RAM and
  image (35 tracks x 16 = 560 total, all present).
- `L2 DUMP $C0EC: reads=1534074 D5=2274 AA=7230 96=68592`
  → the CPU read the Disk II data port **1,534,074 times** and saw the D5/AA/96
  sync bytes. It is **not** reading $00.
- `L2 RESULT … frames=299 ink=967 sectors=312 maxlba=246 mot1=28 ready=1
  addr=BA03`
  → the CPU left the bootstrap and is **executing the DOS 3.3 OS in RAM**
  (addr=BA03, and a 12-sample timeline shows it moving through many RAM
  addresses: 3A0D→391A→CA7B→0041→1C13→BA03 — not a tight loop).

### The real timeline (5 s run)
```
t=0.40  boot ROM (addr~FCAA), motor on, homing starts (track 17)
t=0.60-1.00  homing 17→14→9→4 (NOP delay loop at $FCAB, the stepper wait)
t=1.20  homing done (track 0); drive streams (2mdo nonzero)
t=2.00  CPU reaches the sync scan (addr=C665/C663/C65F)
t=2.60+ CPU EXITED the scan → executing OS in RAM (addr=3A0D, 391A, CA7B …)
```
The 1.2 s run (l2_io6.log) ends **during homing** (track 0 just reached,
addr=FCAC, 14 $C0EC reads = normal pre-homing power-on init). It never reaches
the sync scan — that is why the short runs looked "stuck". A 1.2 s timeout is
**too short** for Level_2 (homing takes ~0.8 s; the scan starts ~t=2.0).

### Why the OLD 15 s run (l2_long.log, Sep 5 18:48) looked stuck
l2_long.log (older build, BEFORE the current main_l2.cpp/host edits of Sep 6
00:52) homed correctly then sat in the $C65E–$C663 scan from t=2.2 to t=15
with `srv` frozen at 260. The RTL (apple2.v / disk_ii.v / drive_ii.v) is
**byte-identical** across the old and new builds (mtimes Sep 5 10:33 / 12:49,
both before both runs); only the testbench host (main_l2.cpp, mtime Sep 6
00:52) changed. So the old run's stuck state came from the **older host build**,
not from the Disk II RTL. The current build (deterministic; two identical 5 s
runs) boots past the scan. Do NOT re-litigate the old l2_long.log against the
current RTL — it is not representative.

### Answer to the original question
"Why does the CPU read $00 from $C0EC while dpram/.nib hold D5 AA 96?"
→ It doesn't, in the current build. The dpram↔.nib track RAM is byte-perfect
(mismatch=0); the drive streams it; the CPU reads $C0EC ~1.5 M times and sees
D5/AA/96 (the sync), decodes the boot sector, and runs the OS. The $00 reads in
the short/old runs were (a) the pre-homing power-on init, or (b) the scan
polling between sync bytes in a host build that never aligned the stream.
Neither is a Disk II RTL fault.

## Remaining (minor, NOT a read-path fault)
- The OS boots and runs, but the screen is mostly blank in 5 s AND 12 s.
  12 s run (l2_boot12.log, deterministic): `sectors=1144 maxlba=311
  addr=B952 mot1=87 boots=000079F2 bootn=407`; `dpram vs .nib track 6:
  mismatch=0`. The boot block grew from 176 (5 s) → 407 non-zero bytes (12 s)
  as the OS loads the DOS system; the drive reads system tracks 0–6 (1144
  sectors); the CPU executes DOS in RAM. So it is a GENUINE, ongoing DOS 3.3
  boot.
  > CORRECTION (2026-09-06): overclaim — see PLAN.md item 4. The disk is
  > synthetic (16 D5AA96/track at exact 409 B spacing, PRNG bytes, no DOS 3.3
  > content); the CPU was executing garbage decoded from it by the genuine
  > Disk II P5 card-ROM sync scanner. The blank screen / 2-char symptom is
  > fully explained by this: there is no real OS to print a prompt.
- BUT the text-page dump ($0400–$07BF, 24x40) is mostly blank at 12 s (only 2
  visible chars: `-` and a backtick) even though `ink=969` (stable 963–969
  across 5 s and 12 s). So either the OS needs more time to print the prompt,
  or the video is showing the wrong page / the `ink` counter measures a
  different region than the text-page dump. This is a SEPARATE video/
  OS-completion concern — NOT a disk read fault. Next: a 15–20 s run to see if
  a prompt appears, and reconcile `ink` with the text-page dump (check the
  active video page $0400+$0801 and what `ink` actually counts).

## KEY FACTS (still valid, background)
- Repo `E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer`. Level_2 dir
  `unit_tests\level_2` (UNTRACKED in git). Sim is ~16x slower than real time
  (5 s sim ≈ 80 s wall; 15 s ≈ 210 s).
- Harness: `tb_l2.sv` (TB) + `main_l2.cpp` (C++ host, sector-streaming
  protocol mirrors verilator/sim/sim_blkdevice.cpp) + `Makefile`. Instantiates
  the `apple2` DUT directly (NOT apple2_top) with the Disk II slot-6
  peripherals (disk_ii + 2x drive_ii + floppy_track + dpram + apple2_font_rom)
  wired exactly as apple2_top.vhd does.
- Pass criterion (current): `sectors>=10 && frames>=3 && ink>0 && mot1>0`,
  300 ms debounce, 5 ms sampling. `--no-pass` disables the pass check. A proper
  run (>=5 s) MEETS the criterion (312 sectors, 299 frames, ink 967, mot1 28);
  "FAIL (timeout)" under `--no-pass` is only because the pass check is off.
- .nib format: 35 tracks x 6656 B raw = 232960 B. DOS_3_3.nib = 560 D5AA96.
  The host loads tracks **on demand** (srv/sectors rises as the drive steps);
  "preloaded" is a scenario label, not "all tracks in RAM at t=0".

### ROM layout (valid)
Flat `apple2e_flat.bin` = 64 KB; the 16 KB main ROM occupies $C000–$FFFF
(file offset $03000–$03FFF). Vectors @ file 0x3FFA; reset → $C3FA; boot ROM
$CF00. Power-on: $FF60–$FF87 → $FF3A `LDA #$87; JMP $FDED` dispatcher →
slot-6 Disk II bootstrap at $C600. $C600–$C6FF is **executable** bootstrap
code (not a LUT). Stuck/scan loop (still where the CPU enters the sync scan):
```
C65E: BD 8C C0  LDA $C08C,X   ; X=$60 → $C0EC
C661: 10 FB     BPL $C65E     ; wait for a byte w/ bit7 set
C663: 49 D5     EOR #$D5
C665: D0 F7     BNE $C65E     ; (not D5) rescan
C667: BD 8C C0  LDA $C08C,X
C66A: 10 FB     BPL $C667
C66C: C9 AA     CMP #$AA
C66E: D0 F3     BNE $C663
C670: EA        NOP
C671: BD 8C C0  LDA $C08C,X
C674: 10 FB     BPL $C671
C676: C9 96     CMP #$96
C678: F0 09     BEQ $C683     ; D5 AA 96 found → sector decode at $C683
```
`$FCAB` = all-NOP region (stepper wait during homing), NOT a stuck loop.

### Slot-6 map (valid, v3-corrected)
Slot-6 device ports $C0E0–$C0EF (devselect[6] = A[6:4]==110b, apple2.v:325).
Data port **$C0EC**. Bootstrap uses **X=$60** (LDA $C08C,X → $C0EC).
(TB binds disk_ii to bit 6: IO_SELECT[6]/DEVICE_SELECT[6].)

### Drive read path (valid; works)
drive_ii.v: on CLK_2M rising edge with DISK_READY & DISK_ACTIVE & !WRITE_MODE,
`byte_delay--`; at 0 it latches `data_reg <= TRACK_DO` and advances
`track_byte_addr` (one byte per 64 CLK_2M cycles). disk_ii.v: `D_OUT =
(IO_SELECT==1)?rom_dout : (q6==0)?data_reg : wp`; for a $C0EC read (IO_SELECT=0,
q6=0) → D_OUT = data_reg = d_out1. w_clk_2m/w_pz are driven by apple2.v
outputs (CLK_2M line 62, PHASE_ZERO line 66), NOT undriven.

## Diagnostics present (built, working)
- tb_l2.sv: 64-deep $C0EC read-history ring + D5/AA/96 byte counters
  (dbg_c0ec_hist/cnt/d5/aa/96), sampled on `w_dev_sel[6] && w_addr[3:0]==4'hC
  && !w_cpu_we` at clk_14m. Plus the earlier live probes (2m/2ma/2mdo/2maddr,
  t1a/t1nz, wra/wranz, io6, trk, cpu addr/trk/mot1).
- main_l2.cpp: post-run dpram-vs-.nib compare (mismatch + D5AA96 counts + 96-B
  hex dumps of RAM and image) and the $C0EC history dump. (The "Post-run dpram
  forensics" block's brace was fixed in this session.)

## v1/v2/v3 HISTORY (superseded where noted)
- v1→v2: ROM layout corrected ($C000 base, 16 KB, vectors 0x3FFA, reset $C3FA,
  boot $CF00); slot-6 map corrected (dev $C0E0–$C0EF, data $C0EC, X=$60).
- v2→v3: pinned the $C65E–$C665 sync scan as the "stuck" loop (raw-byte
  verified); staged the $C0EC-history + dpram-vs-.nib diagnostics.
- v3→v4 (this session): **v3's "stuck reading $00" is disproven.** The staged
  diagnostics + a proper 5 s run show the read path works (sync bytes seen,
  boot sector decoded, OS running). The 1.2 s runs were too short (ended during
  homing); the old 15 s stuck run was an older host build. See v4 block above.

## v6 (2026-09-06): Block-device protocol repair — COMPLETE

Full record in PLAN.md v6 section; evidence summary here.

### What changed
- **RTL (Phase 1):** `rtl/floppy_track.sv` media-change lockdown
  (deterministic power-on state; change-edge handling hardened); both
  repo copies byte-identical (`cmp`). `verilator/sim.v` +
  `Apple-II.sv` wrapper register initializers (`DISK_CHANGE = 'b00`,
  `disk_mount = 'b00`; img_size wrappers initialized) + comment fixes.
- **Shared engine (Phase 2):** `verilator/sim/sim_blkdev_engine.h`
  (header-only BlkDevEngine: per-channel mount/replace/eject, one
  img_mounted pulse per queued notification, LAT/TRF/TAIL transfer
  states, RO write rejection with loud one-shot + latch, EOF→zeros,
  reset drops in-flight transactions). `sim_blkdevice.h/.cpp` rewritten
  as the 3-channel emu adapter; boot gate (2000 cycles) stays in the
  adapter. `sim_main.cpp` samples `ext_reset` per frame.
- **Module test:** `module_tests/floppy_track/` (tb_ft.sv +
  main_ft.cpp, S1–S10) — real DUT + C++ machine model, engine
  latency 50.
- **Level 2 (Phase 3):** `l2_disk_host.h` (L2DiskHost over the shared
  engine, 2 channels, wrapper latch mirroring sim.v/Apple-II.sv,
  image oracle reads); `main_l2.cpp` + `gui/main_gui.cpp` rewritten
  onto it (backups `*.bak_v6`); new flags `--readonly`, `--scratch`
  (scratch auto-copies to `<nib>.l2scratch`, mounted RW).

### Evidence (this session)
- `module_tests/floppy_track`: **FLOPPY_TRACK MODULE TEST: PASS 92/92**
  (S1 mount, S2 read, S3 flush, S4 replace-fall, S5 eject, S6 remount,
  S7 EOF, S8 WP-reject+RW-remount-retry, S9 reset mid-latency/mid-transfer,
  S10 queued mounts serialized; S10 added this session).
- L2 headless (`+cpu=0/1`): `--empty` PASS, `--disk DOS_3_3.nib`
  PRELOADED PASS (both CPUs, identical stats: frames=26, ink=580,
  sectors=13, maxlba=233, mot1=1, ready=1); `--disk --scratch` PASS
  (scratch copy created, original nib git-clean).
- L2 GUI headless smoke (`+cpu=0/1 --disk --headless 5 --selfkey
  --reboot`): **L2_GUI SMOKE PASS** both CPUs (260 sectors served,
  maxlba=246, sim≈2.73 s).
- Vemu: rebuilt with the new engine; **SMOKE PASS** (frames=6, audio,
  keys, reset, video settings, virtual keyboard all green);
  `verilator/floppy.nib` unmodified (git-clean).
- disk_ii equivalence `-CompareOnly`: PASS (known-good numbers:
  rows=7096 fields=54521 ignored_metavalues=2247 flags=0xFFF
  write_protect_samples=6).
- Quartus A&S (quartus_map 17.0.2, newsdee project): **Successful**
  (sys_top; 23,559 registers). Pre-existing Critical Warning triaged:
  `hdd_sector` = user's in-progress HDD work (16-bit `HDD_SECTOR` in
  `rtl/apple2_top.vhd` vs 32-bit `sd_lba[1]` in `Apple-II.sv`), not v6.
- EOL: `core.autocrlf=true` in both repos (eol_guard HEAD-comparison
  flags are autocrlf artifacts); all v6-touched files verified
  internally consistent (CRLF files fully CRLF, test files pure LF);
  mirrored `floppy_track.sv` copies byte-identical.

### Fixed this session (Vemu bring-up)
- `sim_blkdevice.h`: `sd_lba[k]` SData*→IData* (sim.v `sd_lba[3]` are
  32-bit per channel), `sd_buff_addr` CData*→SData* (9-bit port).
- `sim_blkdevice.cpp`: `*sd_buff_addr = (SData)addr` (the CData cast
  truncated the 9-bit LBA address to 8 bits).
- Vemu build workaround (g++ temp-file env failure under verilate.sh
  sub-make): `mingw32-make -C obj_dir -f Vemu.mk -j4` with the MSYS TMP
  trio (details in PLAN.md v6 build notes).

### Remaining (honest list)
- L2 directed write/reread from the disposable copy: deferred to the TB
  debug-injection hook (`--write-test` not implemented). The engine +
  DUT write path is exercised by module-test S3/S8 (DUT-level) and the
  machine never writes during a DOS boot.
- Full-sim floppy write/reread: interactive DOS WRITE → manual check.
- Explicit drive-2 DUT protocol sequence: engine channels are
  structurally identical; add an L2 `--drive2` scenario if wanted.
- Phase 5 full Quartus compile: for the user (A&S already green).
- Cosmetic: `now_ms()` wall-time wrap in GUI RESULT line (display only).
  [FIXED 2026-09-06 — QPC monotonic clock, see entry at end of file]
  > CLOSED in v7 (2026-09-06 ~16:05): the `--write-test` scenario above is
  > implemented and green on both CPUs — see v7 section below.

## v7 (2026-09-06 ~16:05): `--write-test` — directed dirty-track flush (the last v6 open item)

### What changed (testbench/harness only — NO DUT RTL touched)
- **`tb_l2.sv`**: three new C++-driven top-level INPUT ports
  `dbg_ft_wr_en` / `dbg_ft_wr_addr[12:0]` / `dbg_ft_wr_data[7:0]` (same
  top-level-port rule as `sd_ack`: safe in the legacy build), muxed onto
  ft1's track-RAM port-B inputs (inert while the bit is low — default
  scenarios are byte-identical, re-verified below). Plus an `h_t1_busy`
  capture register and a `dbg_wri_cnt` injection counter.
- **`main_l2.cpp`**: `--write-test` scenario. Always mounts a scratch
  copy (source `.nib` never opened for write; default nib when no
  `--disk` given). Five phases: (1) boot — the standard criterion
  (readSectors>=10, frames>=3, ink>0, mot1>0); (2) quiesce — 1000
  consecutive posedges with no sd request, engine idle, motor off,
  ready, ft1 not busy; (3) inject — 16 bytes `0xA0..0xAF` at track-RAM
  `0x19F0..0x19FF` (last 16 B of the last sector), one byte per
  posedge, dirtying the track exactly like a machine DISK WRITE would;
  (4) flush — the DUT's OWN dirty-track flush must save the track back
  over `sd_wr` (latch the write LBA from `h_sd_lba_a`; wait for 13
  engine write sectors + bus settle); (5) verdict — engine delta
  writeSectors==13, failedWrites==0, wri_cnt==16, lba%13==0, scratch
  file shows the pattern at exactly the 16 injected offsets of the
  flushed track, every other byte identical to the pre-injection
  snapshot, source image byte-identical to before the run.
- **`run_l2.sh`**: `--write-test` flag (composes `--write-test [--disk]`).
- **Budget fix found during the first green run**: the phase timer
  counted half a period per posedge (budgets 2× looser than
  documented); now one full 14.3 MHz period per posedge. Quiesce budget
  6.0 s sim — the post-boot garbage OS keeps reading sectors for ~4.3 s
  (312 sectors by end of run), so the quiescent window arrives at
  ~4.7 s.

### Evidence (both CPUs; deterministic — identical timelines)
```
L2 WRITE-TEST: boot reached (sectors=13 t=0.431s) - waiting for the drive to go quiescent
L2 WRITE-TEST: drive quiescent (t=4.700s track=0 ready=1) - injecting 16 bytes @0x19F0
L2 WRITE-TEST: injection done - waiting for the DUT's own dirty-track flush (sd_wr)
L2 WRITE-TEST: flush started (sd_wr lba=0 track=0)
L2 WRITE-TEST: flush complete (writeSectors=13 t=4.702s)      (wdc: 4.701s)
L2 WRITE-TEST: flush track=0 lba=0 sectors=13 failedWrites=0 wri_cnt=16 pattern=16/16 foreign_mm=0
L2 WRITE-TEST: source image unchanged=1 (size 232960), scratch 232960 bytes
L2 RESULT scenario=write-test  frames=282  ink=967  sectors=312  maxlba=246  mot1=27  ready=1  sim=4701ms
L2 WRITE-TEST PASS
```
- `run_l2.sh --write-test`: **L2 WRITE-TEST PASS on nmos and wdc**, exit 0.
  The flush itself takes ~1–2 ms sim (13 sectors over the 14.3 MHz
  byte bus).
- Post-run forensics: the dpram-vs-.nib dump of the flushed track shows
  `mismatch=0/6656` (track RAM still holds the post-injection content
  and the scratch file matches it). The scratch copy
  `unit_tests/level_2/DOS_3_3.nib.l2scratch` is left on disk as
  evidence; the source `DOS_3_3.nib` is byte-identical (verified every
  run).
- Regression: `run_l2.sh --empty` re-run after the TB change —
  **L2 EMPTY PASS on both CPUs** (the injection mux is inert).

### Remaining (honest list, v7)
- Full-sim floppy write/reread: interactive DOS WRITE → manual check
  (level_2 now covers the DUT flush at machine scale; the full-sim
  path is still only exercised read-only).
- Explicit drive-2 DUT protocol sequence: add an L2 `--drive2`
  scenario if wanted (engine channels structurally identical).
- Real `.dsk` → `.nib` conversion: the DOS 3.3 nib stays synthetic
  (PRNG bytes, 560 D5AA96 markers); the "garbage OS" behavior is
  expected and now also defines the write-test quiescence window.
- Phase 5 full Quartus compile: for the user (A&S already green;
  nothing RTL-level changed in v7 — no recompile needed for this
  scenario, but the user may still want a full compile for the v6 RTL
  changes).
- Cosmetic: `now_ms()` wall-time wrap in GUI RESULT line (display
  only; headless/CLI paths unaffected).
  [FIXED 2026-09-06 — QPC monotonic clock, see entry at end of file]


## 2026-09-06 (GUI sim-speed meter: `now_ms()` 60 s wrap — FIXED)

User report: the windowed GUI displayed "sim speed 3109x real time",
far from the true pump throughput. Root cause: `now_ms()`
(gui/main_gui.cpp) was built from GetSystemTime's
`wSecond*1000 + wMilliseconds` = ms *within the minute* — it wraps
every 60 s (this defect was documented above as the RESULT-line
`wall=-16.4s` cosmetic bug, with the note that "the windowed
sim-speed window has the same latent glitch"). After a wrap the
sim-speed window test `t_ms - speed_anchor_ms >= 1000` (signed) goes
negative and can never be true again → the 1-s window stops closing →
the readout freezes at a stale value (or never updates).

The true pump rate on this machine is ~0.05x real time (measured:
sim=0.44 s in 8-9 s wall, headless + CLI — 20x SLOWER than real time).
What the user watches on disk load is machine-time Disk II boot I/O:
the 294 ms (2^22-cycle) power-on hold, motor spin-up, step-to-track,
and the DOS sector reads — all advancing at ~1/20 of real time. The
`.nib` itself is never "loaded" as a step: `mountDrive()` opens the
file at t=0 (instant) and bytes are served on demand through the real
sd_ bus (one byte per 14.318 MHz cycle, host `tick()`).

Fix (gui/main_gui.cpp only, no DUT/harness change): the Windows
`now_ms()` branch now returns monotonic ms since first call via
QueryPerformanceCounter (immune to wall-clock changes and minute
wraps). The non-Windows gettimeofday branch (epoch ms, monotonic in
practice) is unchanged. The `speed_anchor_ms == 0` first-sample
sentinel is unaffected: the first windowed sample arrives ~0.4 s
after process start, well clear of 0.

Verification: GUI rebuilt 18:58 (main_gui.o + Vtb_l2.exe fresh; the
first make run's "Error 1" was a post-link substep — the second run
reports the tree up to date and the exe timestamp postdates the
edit). Headless smoke with the NEW binary, `--disk`:
`L2_GUI SMOKE PASS cpu=nmos6502 (boot ok)` — frames=25, sectors=13,
mot1=1, sim=0.44 s wall=8.1 s. The windowed 1-s window now closes
correctly across minute boundaries; user re-run of the windowed GUI
confirms the readout (~0.05x, i.e. ~20x slower than real time).

## 2026-09-06 (~21:55): Save-state follow-on work — v2 disk map draft + DDR contract directed test (design-only)

Triggered by the level_1b status check: level_1b is now at Phase 4/5
(mister project exists, full Quartus compile green 21:46 — A&S/Fitter/
STA/ASM, level1b.rbf built; all four Verilator TBs pass, including the
new `tb_ss_arbiter` run ad-hoc). The DDR bridge address math remained
the open hardware risk (session's own README flags the base).

Two design-only deliverables added to this directory (no RTL touched,
no level_1b file touched — the parallel session's WIP stays clean):

1. `SAVESTATE_V2_DISK_MAP.md` — draft format-v2 state map for the disk
   machine (PLAN risk #12: revision, not a port; major 1 -> 2).
   Inventories every registered state in the disk path (disk_ii:
   motor_phase/drive_on/drive_real_on/drive2_select/q6/q7/step pulses/
   spindown_delay[23:0]/drive_on_old; drive_ii x2: phase,
   track_byte_addr, data_reg, reset_data_reg, rel_phase, byte_delay,
   TRACK_WE, CLK_2M_D; floppy_track x2: sd_rd/sd_wr/ready/busy/dirty/
   saving/old_ack/old_change/rel_lba/cur_track/lba; wrapper
   disk_mount/disk_change latches). Assigns v1-reserved register words
   11-15 to disk_ii/drive_ii x2/floppy_track x2, the 4 wrapper latches
   into word 10 [7:4] (keeps all v1 RAM byte offsets stable), a
   disk-present feature bit in header word 1, and two new walker
   regions (2 x 8,192 B track buffers, 1,024 64-bit words each).
   v2 payload: 18,465 words with CRC (147,720 B). Documents the
   derived-vs-serialized split, media-not-state rule (host .nib left
   as found on load), restore ordering, load-validation additions, and
   out-of-scope list. Also records: the whole disk path is single-clock
   (CLK_14M = clk_sys; drive_ii registers all on CLK_14M, CLK_2M is an
   edge-detected input) so the existing freeze covers it, and the
   v1 PLAN's "approximately 256 KiB" payload comment is a 2x miscount
   of its own table (128.2 KiB).

2. `SAVESTATE_DDR_CONTRACT_CHECK.md` + `tb_ss_ddr.sv` — the directed
   first/last-address test the PLAN risk #10 and Phase 4 exit demand.
   The TB models the HPS DDRAM side per the PLAN frozen contract
   (DWORD addresses, burst 2 per 64-bit xfer, window
   0x03800000..+4x0x00080000 DWORD) and drives the UNMODIFIED bridge
   through a full 16,417-word v1 save + readback. Measured result
   against the current bridge: T1 region FAIL (all 32,834 tx outside
   the window), T2 first/last FAIL (0x1F00000..0x1F20100 vs
   0x3800000..0x3808040), T3 stride FAIL (x8 not x2), T4 burst FAIL
   (1 not 2), T5 integrity FAIL (upper half of every word lost),
   T6 handshake PASS (double=0). Exits non-zero until the bridge is
   conformed; run command and fix guidance (stride x2, burst 2,
   slot-base parameter from the HPS-verified window) are in the doc.
   Items genuinely unverifiable from local sources (SS<base>:<size>
   units, HPS window base, burst semantics, out-of-window behavior)
   are listed as HPS-side verification with resolution paths.

No commit (files untracked; user commits at discretion). EOL: all three
new files pure LF. level_1b WIP untouched (verified: only tracked
mod remains Apple-II.qsf).

## 2026-09-08: Save-state (level_1b) ported to level_2 — Verilator + mister

Triggered by the user: port the level_1b save-state work to level_2 first
(level_2b later), and make it part of the level_2 mister build.

### What was ported (v1 scope, unchanged from level_1b)
`savestate_manager_l1b` (atomic coordinator: freeze -> headers -> register
words 0-10 -> both 64 KiB RAM banks; restore RAM -> machine words 3-10 ->
CPU words 0-2) + `savestate_ddr_l1b` (direct 64-bit DDRAM bridge, corrected
2026-09-07: beat base, stride 1, burst 1). Referenced LIVE from
`unit_tests/level_1b/` (the regs/ram/arbiter clients are Verilator-TB-only
in level_1b and are NOT used here - the manager drives the slot bus
directly, exactly as the level_1b mister wrapper does).

**V1 scope = CPU + main/aux RAM + machine latches + timing/video phase.
The Disk II path (disk_ii/drive_ii/floppy_track) is NOT in the state.**
`SAVESTATE_V2_DISK_MAP.md` remains the planned v2 extension (needs ss ports
on the disk DUTs + track-buffer walker regions - not done).

### Verilator harness (`tb_l2.sv` + `main_l2.cpp` + `Makefile`)
- `tb_l2.sv`: manager + DDR bridge + a TB model of the HPS DDRAM port
  (64-bit beats, one acknowledged tx at a time, 4-cycle latency;
  `ddram_mem[0:32767]`); ss bus wired into `apple2`
  (`.machine_ce(machine_ce)`, `.ss_*`, `.cpu_frozen`); STALL =
  `stall || ss_busy`; RAM ss read/write path in the inferred arrays
  (ss write takes priority; the machine's frozen idempotent write is
  suppressed while ss_busy - inert in normal operation); reset-chain
  ss-restore branch (word 8); wrapper ss_rdata mux (words 8/9/10).
  New C++-driven input ports `ss_save_req`/`ss_load_req`.
- `main_l2.cpp`: new `--savestate` scenario - cold-boot + quiesce ->
  SAVE -> snapshot (full 64 KiB ram0 image + PC + manager register
  shadow) -> 100 ms run (drift) -> perturb ONE byte of the STORED state
  in the DDRAM model (slot word 0xA0, lane 0 = main RAM $0400) -> LOAD
  (machine stalled via the TB `stall` reg) -> verify the full 64 KiB
  main-RAM image equals the saved image with exactly that one byte
  changed, PC + register shadow match, no ss_error -> release stall,
  confirm frames keep advancing.
- `Makefile`: `SS_SRC` added to the headless and GUI builds.

**Result (2026-09-08, both CPUs, deterministic - identical timelines):**
```
L2 SAVE-TEST: save complete (t=4.722s pc=$1C15)
L2 SAVE-TEST: drift done (ram_diff=6081 pc_drift=1) - perturbed @word 0xA0
L2 SAVE-TEST: verify ram_mm=0 pc=$1C15 (saved $1C15) shadow=1 err=0 drift=1 OK
L2 SAVE-TEST: resume frames=290 (was 287) OK
L2 SAVE-TEST PASS        (nmos6502 and wdc65c02)
```
Regression: `--disk` PRELOADED PASS, `--empty` EMPTY PASS (ss path inert).

Bugs found by the test (both fixed): the `apple2` instance in the TB (and
initially the mister wrapper) did not connect the `.cpu_frozen` output -
the manager's FREEZE state hangs forever without it; and the generic
preloaded pass-check had to exclude `do_ss` (it broke the loop at boot).

### mister build (`mister/Apple-II.sv` + `files.qip` + `level2.qsf`)
Same wiring as the level_1b mister wrapper: `SS3E000000:200000` in
CONF_STR, OSD `O2,Save State` / `O3,Load State` (edge-detected), manager +
`savestate_ddr_l1b #(.BASE_ADDR(29'h07C00000))` driving the DDRAM_* ports
(were tied 0), STALL = `osd_pause || ss_busy`, `.cpu(active_cpu)`
(locked CPU during a transaction), RAM ss path in the inferred arrays,
reset-chain ss-restore, `HDMI_FREEZE = ss_busy`. Both savestate sources
registered in `files.qip` AND the qsf source list (live refs to
`../../level_1b/`).

Verified at the Verilator lint level (full wrapper elaborates clean; the
only remaining lint errors are pre-existing PROCASSWIRE strictness in
`sys/hps_io.sv`/`hq2x.sv`, which Quartus compiles fine). **The Quartus
compile is for the user** (build.bat). Watch for: the inferred-RAM
dual-read-port inference (machine read + ss read per bank) and any
fit/timing delta from the manager + DDR bridge.

### Not done / remaining
- Quartus full compile of the level_2 mister core (user).
- Hardware: OSD Save/Load with a disk mounted; confirm persistence and
  that the disk path (not in v1 state) behaves acceptably across a load.
- v2 disk map (disk path state) - separate work, `SAVESTATE_V2_DISK_MAP.md`.
- level_2b port - explicitly deferred by the user.
- NOTE: `mister/level2.qsf` was rewritten CRLF by the parallel composite
  session (HEAD was pure LF) - EOL drift to normalize at commit time.

### 2026-09-08 (cont.): Quartus Error 276003 - save-state RAM read broke inference (FIXED)

First level_2 mister compile with save state failed A&S:
`Info (276007): RAM logic "emu:emu|ram0/ram1" is uninferred due to
asynchronous read logic` -> 262,144 leftover registers ->
`Error (276003)`. Cause: the save-state read
`ram_ss_rdata_r <= ram_ss_bank ? ram1[ram_ss_addr] : ram0[ram_ss_addr]`
muxes the ARRAY INDEX across two memories; Quartus 17 sees asynchronous
read logic and refuses to infer either bank.

Fix (mister/Apple-II.sv AND tb_l2.sv, mirrored): canonical dual-port
pattern - port A = the ORIGINAL machine pattern (inferred RAM, registered
read, write-through; only change: wren gated by !ss_busy so the two
write ports can never be enabled in the same cycle), port B = separate
per-bank always blocks (`ss_ram0`/`ss_ram1`) with the bank mux on the
REGISTERED OUTPUTS (`ram0_ss_r`/`ram1_ss_r`), never on the array.
`video_rom` (video_generator) shows the same "uninferred due to
asynchronous read" info but is pre-existing (the Sep 6 build fit with
it) and harmless.

Re-verified after the restructure: L2 SAVE-TEST PASS both CPUs,
byte-identical timelines to before (ram_mm=0, pc/shadow match, drift=1,
resume OK). Quartus re-compile is for the user: the map report must show
ram0/ram1 inferred (no 276007 for emu:emu|ram0/ram1) and no 276003.

### 2026-09-08 (cont. 2): second inference failure -> explicit dpram RAMs (FIXED, verified)

Second compile still failed A&S, new reason:
`Info (276009): RAM logic "emu:emu|ram0/ram1" is uninferred due to
unsupported read-during-write behavior` (the async-read issue was gone).
Quartus 17 will not infer the dual-client arrays in any shape tried
(cross-array ternary read; then per-bank blocks with write-through port A
+ conditional port B). Stopped fighting the inference heuristics and
switched to the pattern the newsdee project and the level_1b mister both
landed on: **two explicit `dpram` (altsyncram) instances**
(`rtl/dpram.vhd`, already registered in this project for floppy_track):

- port A = machine (`wren_a = ram_we_mach && aux_sel`), port B = save
  state (`wren_b = ram_ss_wr && bank_sel && !ss_reset`); the two write
  ports can never be enabled in the same cycle.
- `ram_do` = one register stage on the combinational NEW_DATA `q_a` -
  byte-identical timing to the previously verified inferred RAM
  (write-through preserved: q_a = new data on write cycles).
- ss read = the RAW `q_b` (exactly the level_1b mister wiring): port B's
  address is registered (address_reg_b=CLOCK1), so q_b in cycle N+1
  holds the byte at the address presented in cycle N - precisely the
  manager's one-cycle protocol (ram_rd in N, ram_rdata sampled in N+1).

The TB (`tb_l2.sv`) mirrors the FPGA wiring EXACTLY: the same `dpram`
module (Verilog behavioral model `rtl/dpram.v`, verified against the
altsyncram config), same port connections, same raw-q_b read, same
register stage. C++ rootp paths updated (`main_ram.mem`).

Differential result: L2 SAVE-TEST PASS both CPUs with a
byte-identical timeline to the inferred-RAM version (load complete
t=4.840s, ram_mm=0, pc/shadow match, drift=1, resume frames 287->290) -
i.e. the FPGA wiring is now simulation-verified end-to-end. Regression:
PRELOADED PASS. Quartus re-compile for the user: expect main_ram/aux_ram
as altsyncram (block RAM), no 276007/276009 for emu:emu|ram0/ram1, no
276003. Resource note: 2 x 64 KiB in M10Ks (was inferred before the
save-state change; same memory, now explicit).

### 2026-09-08 (cont. 3): level_2 mister full compile GREEN with save state

User-confirmed. `level2.map.summary` A&S Successful 07:20, Fitter
Successful 07:28, Assembler Successful 07:28, RBF built
(`level2_build05.rbf`). Map report: `dpram:main_ram|altsyncram` and
`dpram:aux_ram|altsyncram` - both main RAMs in block RAM; no 276009, no
276003; only the pre-existing harmless `video_rom` 276007 (present in
the Sep 6 passing build too). ALM 11,503 / 41,910 (27%).

Remaining: on-hardware OSD Save/Load test (save with a disk mounted,
change machine state, load, confirm continuation) and the v2 disk map
when wanted.
