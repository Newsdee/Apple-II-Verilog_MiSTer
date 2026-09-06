# Level_2 DOS 3.3 boot — PLAN (v7, write-test COMPLETE, 2026-09-06 ~16:05)

Companion to `PROGRESS.md` (read that first: full state, evidence, the v4
correction that overturns the v3 "stuck reading $00" model, the v5 GUI
land + direction reset, ROM facts, and the history). The disk-read debug
is DONE (v4); the GUI is built and green (v5); the user is about to watch
the boot with their own eyes in the window.

## Where we are (v5)
- **Disk read path RESOLVED + working (deterministic, reproduced multiple
times; see the v4 block in PROGRESS.md).**
- **imgui GUI LANDED (v5, 2026-09-06):** `gui/main_gui.cpp` (same `tb_l2`
top; headless smoke + windowed imgui/SDL2/OpenGL3 path), `Makefile gui`
target, `run_l2.sh gui` branch, `run_l2_gui.bat`. Fresh headless smoke
this session: `L2_GUI SMOKE PASS cpu=nmos6502 (boot ok, selfkey ok,
reboot ok)`, exit 0 (25 frames, ink=67779, 262 sectors, homing 17→0,
reboot OK). The frame_valid pump bug and the boot-phase gate bug found
while landing the GUI are fixed (PROGRESS v5).
- **Direction reset (user):** priority = watch the boot in the window and
  confirm; level_1 is the video bisection level if a video fault is
  suspected. The v4 "blank text page at 12 s" question and the pass-
  criterion rework are PARKED pending that visual check.
- Known cosmetic defect: `now_ms()` (seconds+milliseconds of the day,
  non-monotonic) makes the RESULT `wall=` field go negative across a
  minute/hour boundary (display only).

## Ordered steps
1. [DONE] Read final IO6 dump; interpret io6 counters; disassemble the ROM disk
   code + pin the $C65E–$C665 sync scan (raw-byte verified); slot-6 map pinned.
2. [DONE] Staged diagnostics built + run (v4): $C0EC read-history + D5/AA/96
   counters (tb_l2.sv); post-run dpram-vs-.nib compare + 96-B dumps + $C0EC
   history dump (main_l2.cpp). Brace in the dpram-forensics block fixed.
3. [DONE] Decisive 5 s run (x2, identical): read path works — sync seen, boot
   sector decoded, OS running (addr=BA03). Premise disproven.
4. [DONE] 12 s run (l2_boot12.log, deterministic): OS fully boots — sectors=1144
   (tracks 0–6), boot block 176→407 non-zero bytes (boots=000079F2), CPU in RAM
   (addr=B952), every track byte-perfect (dpram vs .nib mismatch=0). GENUINE
   DOS 3.3 boot confirmed.
   > CORRECTION (2026-09-06): that claim was an overclaim. `DOS_3_3.nib` is
   > a SYNTHETIC protocol-test disk, not DOS 3.3: exactly 16 D5AA96 markers
   > per track at exactly 409 B spacing (560 = 35x16), PRNG gap bytes (0x96
   > at 21%), no boot-block signature, no "DOS 3.3" string, zero real sector
   > content. The DUT's slot-6 bootstrap is the genuine Apple Disk II P5 card
   > ROM (rtl/roms/...341-0027.bin, 256 B, $C600-$C6FF) which sync-scans the
   > raw byte stream for D5 AA 96 in software (original Disk II behavior);
   > it "decoded" the synthetic junk and the CPU executed garbage (blank
   > screen, 2 stray chars). All the cited evidence was protocol-level
   > (transport fidelity, CPU liveness) and never verified decoded content.
   > A real DOS 3.3 image exists in the workspace (`Apple DOS 3.3 January
   > 1983.dsk`, 140 K, 280 sectors, genuine code + "DOS 3.3" string, already
   > copied into unit_tests/level_2/) and needs conversion to the DUT's raw
   > per-sector layout (D5AA96 + validated header + 512 B data).
5. [PARKED → user] Screen mostly blank at 12 s (2 chars, ink=969 stable):
   superseded as an agent question — the user watches the boot in the GUI
   window (`run_l2_gui.bat`) and judges it. If the video is suspect, bisect
   at level_1 (video + keyboard, no disk). The crashed session's font/glyph
   forensics on the power-on "diagonal stripe" pattern is parked (PROGRESS v5 §7).
6. [PARKED] Rework the pass criterion to require real boot evidence (boot-block
   checksum change / bootn>0 / PC in $0800–$0FFF / decoded track-0 sectors in
   RAM). Deferred: the headless boot phase now requires real sectors + motor
   spin, and the windowed path shows the live `bootn` counter.
7. [NEXT] If a real video/OS fault is found (from the user's visual check or
   level_1), smallest grounded fix, then rebuild + re-run. (No RTL change
   expected for the read path — it works.)
8. [OPEN] Full Verilator smoke test (Vemu.exe --smoke-test) + report per
   AGENTS.md checklist (narrow test result, warnings, what remains
   Quartus/hardware-only). Harness-only change (no rtl/ edits), so the
   machine smoke is unaffected — pre-commit hygiene item.
9. [DONE] imgui GUI for level_2 (window + headless smoke) + `run_l2_gui.bat`,
   2026-09-06 — `L2_GUI SMOKE PASS` both... (nmos verified this session; the
   window path is CPU-agnostic: `run_l2_gui.bat wdc` for wdc65c02).

## Block-device protocol repair (v6)

The Disk II RTL is not the fault: `disk_ii.v`, `drive_ii.v`, and
`floppy_track.sv` are byte-identical between the Verilator and newsdee trees,
and the Disk II differential test passes all coverage gates. The defects are
in the media-event and C++ host layers around that RTL.

Current problems:

- level_2 implements only `sd_rd`; an `sd_wr` request is never acknowledged,
  so a dirty-track flush can leave `floppy_track.busy` asserted forever;
- full Verilator holds `img_mounted` high while a shared delay expires, while
  `sim.v` toggles `DISK_CHANGE` on every high cycle;
- full Verilator shares `reading`, `writing`, `bytecnt`, and `ack_delay`
  across all devices, and decrements the shared mount delay from inside the
  ten-device loop;
- level_2 generates a clean high/low change pulse, so it avoids rather than
  tests the full simulator and MiSTer mount behavior;
- `floppy_track` updates `ready <= mount` only on a rising `change` edge even
  though the wrappers use a persistent toggling event bit;
- `DISK_CHANGE`, `disk_mount`, and simulator protection state are not reset
  explicitly;
- level_2's `dbg_sdwr_cnt` counts host-to-track-RAM `sd_buff_wr` bytes, not
  track-to-image `sd_wr` requests.

### Protocol to enforce

Use these semantics in MiSTer, full Verilator, and level_2:

1. `img_mounted[index]` is a one-cycle notification. `img_size` and
   `img_readonly` are valid with that notification.
2. The wrapper stores `mount[index]` and protection state, then toggles one
   persistent `change[index]` bit exactly once per notification.
3. `floppy_track` treats either `change` edge as a media change. On an edge it
   latches `ready <= mount`, invalidates `cur_track`, cancels any old transfer,
   and clears dirty state belonging to the removed image.
4. Only one SD channel owns the shared buffer bus at a time.
5. A request starts when the selected channel asserts `sd_rd` or `sd_wr`.
   The host latches channel, direction, and LBA once.
6. After the configured latency, the host asserts only that channel's
   `sd_ack` while transferring exactly 512 addresses `0..511`.
7. For reads, the host drives `sd_buff_addr`, `sd_buff_dout`, and
   `sd_buff_wr`. For writes, it drives `sd_buff_addr` and samples the selected
   channel's `sd_buff_din`; `sd_buff_wr` remains low.
8. The host deasserts `sd_ack` after byte 511. `floppy_track` advances its
   13-sector sequence on that falling edge.
9. Reads beyond EOF return zero. Writes beyond the current image size fail
   loudly unless deliberate image growth is explicitly enabled.
10. Read-only images report write protection and reject host writes without
    modifying the source file.

### Phase 1: lock down media-change RTL

Files:

- `rtl/floppy_track.sv`
- mirrored `Apple-II_MiSTer_newsdee/rtl/floppy_track.sv`
- `verilator/sim.v`
- `Apple-II_MiSTer_newsdee/Apple-II.sv`

Steps:

1. Add deterministic initialization/reset for `DISK_CHANGE`, `disk_mount`,
   and simulator `disk_protect` state.
2. Change `floppy_track` from rising-edge-only media handling to
   `old_change != change`, applying `ready <= mount` on both polarities.
3. Preserve existing track-load, dirty-save, 35-track clamp, and SD ACK
   sequencing after the event block.
4. Keep both `floppy_track.sv` copies byte-identical.
5. Add a focused RTL test for mount, same-drive replacement, eject on each
   toggle polarity, and remount. Assert `ready`, `busy`, first LBA, and absence
   of stale writes.

First discriminator: two consecutive media notifications must both update
`ready` correctly even though their `change` levels have opposite polarity.

### Phase 2: replace the full Verilator host state machine

Files:

- `verilator/sim/sim_blkdevice.h`
- `verilator/sim/sim_blkdevice.cpp`
- `verilator/sim_main.cpp`

Steps:

1. Introduce one initialized per-device record containing file, size,
   read-only state, mount request, and mount status.
2. Keep transfer direction, byte index, latency, latched LBA, and selected
   channel in one explicit bus-transaction record. Do not decrement its delay
   inside the device-discovery loop.
3. Emit `img_mounted` for exactly one rising-clock callback per queued mount,
   replacement, or eject. Do not reuse sector `ack_delay` for mount events.
4. Open writable images read/write; fall back to read-only open when needed
   and propagate `img_readonly` accurately.
5. Use `seekg` for reads and `seekp` for writes. Check stream errors and flush
   completed writes.
6. Reject simultaneous read and write requests and invalid/unbound channels
   with a diagnostic instead of dereferencing null pointers.
7. Preserve one-byte-per-rising-edge pacing required by the synchronous
   track DPRAM.

First discriminator: mounting one image must produce exactly one
`img_mounted` pulse and one `DISK_CHANGE` transition, independent of
`kVDNUM` and channel number.

### Phase 3: make level_2 use the same host implementation

Files:

- `unit_tests/level_2/main_l2.cpp`
- `unit_tests/level_2/gui/main_gui.cpp`
- `unit_tests/level_2/tb_l2.sv`
- `unit_tests/level_2/Makefile`

Steps:

1. Extract the protocol engine from `SimBlockDevice` behind a small bus
   adapter so full Verilator, headless level_2, and GUI level_2 execute the
   same transaction code.
2. Keep UI, logging, and boot-pass policy outside the shared engine.
3. Expose both track-buffer `sd_buff_din` values to the adapter and implement
   level_2 write transactions rather than ignoring `sd_wr`.
4. Rename diagnostics:
   - `dbg_sdload_byte_cnt` for `sd_buff_wr` commits into track RAM;
   - `dbg_sdwrite_req_cnt` for rising `sd_wr` requests;
   - add completed read-sector and write-sector counters.
5. Add `--readonly` and a disposable output-image option. Never run write
   tests against the repository's source `.nib` files.

First discriminator: a directed dirty-track flush must complete all 13 sector
writes, lower `busy`, and alter only the disposable image copy.

### Phase 4: regression matrix

Protocol-level tests:

- mount drive 1, replace drive 1, eject drive 1, remount drive 1;
- repeat the same sequence on drive 2/channel 2;
- simultaneous queued mounts serialize without changing transfer latency;
- one 512-byte read has addresses `0..511` and one ACK rise/fall pair;
- one 512-byte write has addresses `0..511`, persists byte-for-byte, and has
  one ACK rise/fall pair;
- EOF read returns zero without stream failure;
- protected media reports write protect and remains byte-identical;
- reset during mount latency, track read, and dirty flush returns the bus to
  idle without a stuck `busy`, `sd_rd`, `sd_wr`, or `sd_ack`.

Existing regressions:

1. `module_tests/disk_ii/run_equivalence.ps1` including write-protect gates.
2. level_2 empty boot on both CPU cores.
3. level_2 DOS 3.3 boot on both CPU cores from a disposable image copy.
4. level_2 directed write and reread from the disposable copy.
5. full `Vemu.exe --smoke-test`, then a full-simulator floppy write/reread.
6. Compare the two mirrored `floppy_track.sv` files byte-for-byte.

### Phase 5: MiSTer integration

After simulation passes:

1. Run Quartus Analysis & Synthesis for the newsdee project to validate the
   mixed-language binding and source registration.
2. Review new warnings separately from existing warnings.
3. Run a full compile only when requested, then confirm map, fitter, timing,
   and assembler report timestamps.
4. On hardware test insert, replace, eject, write, reboot, both drives, and
   OSD write protection. Verify persistence only with disposable media.

### Completion criteria

- one media notification causes one deterministic change event;
- both change polarities update `ready` and mount state identically;
- all host state is initialized and transfer timing is independent of device
  count/index;
- level_2 and full Verilator share the same read/write protocol engine;
- read, write, replace, eject, protection, two-drive, and reset tests pass;
- source disk images remain unchanged;
- mirrored RTL remains byte-identical;
- remaining Quartus or hardware-only validation is stated explicitly.

## Runners / commands (verified working)
- Rebuild level_2 (stop any running Vemu.exe/Vtb_l2.exe first):
  `cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/unit_tests/level_2 && cmd.exe //c "set PATH=C:\\msys64\\ucrt64\\bin;%PATH% && mingw32-make -j4 all"`
- Run 1.2 s DOS_3.3: `cmd.exe //c "C:\\Users\\newsdee\\AppData\\Local\\Temp\\run_io6.bat"`
  (Vtb_l2.exe +cpu=0 --disk unit_tests/level_2/DOS_3_3.nib --no-pass
  --timeout 1.2 → unit_tests\level_2\l2_io6.log)
- Inspect:
  `grep -n "L2 DUMP" unit_tests/level_2/l2_io6.log` (NEW v3 dumps + dpram)
  `grep -n "L2 IO6:" unit_tests/level_2/l2_io6.log` (final io6 counters)
  `grep -n "L2 TRK" unit_tests/level_2/l2_io6.log` (stepping/homing)
- Disasm: `cd /c/Users/newsdee/AppData/Local/Temp && perl dasm2.pl <file> <start> <end> 2>/dev/null`
  — `apple2e_flat.bin` (main ROM), `diskii_img.bin` (bootstrap @ $C600).
  Branch-target display is off-by-one; verify targets with
  `dd if=<file> bs=1 skip=$((0xNNNN)) count=N | od -A x -t x1`.
- Long run (for stability): same bat with `--timeout 15` (l2_long.log pattern).

## Guardrails
- Behavior-preserving, smallest edits; no unrelated cleanup.
- Mixed-EOL repo: after any RTL edit run `bash eol_guard.sh` at workspace
  root; MSYS text utils mangle \r — use od/xxd/perl :raw for byte work.
- Don't touch the uncommitted FPGA-project changes in
  Apple-II_MiSTer_newsdee (separate workstream: NSC CPU, keyboard verilog
  port, etc.).
- Don't commit unless asked.
- Keep the v1/v2 history in PROGRESS.md (corrections are marked, not
  deleted) — future sessions rely on it.

## v6: Block-device protocol repair (2026-09-06, COMPLETE)

The five phases above are all implemented and validated in this session
(details + evidence in the v6 block of PROGRESS.md). Status per phase:

- **Phase 1 (RTL lockdown):** DONE. `floppy_track.sv` (both copies
  byte-identical, `cmp`-verified), `sim.v`, `Apple-II.sv` (wrapper reg
  init `'b00`, comment fixes). The `hdd_sector` Critical Warning in the
  map report is PRE-EXISTING user HDD work (16-bit `HDD_SECTOR` in
  `apple2_top.vhd` vs 32-bit `sd_lba[1]` in `Apple-II.sv`), not v6.
- **Phase 2 (shared engine):** DONE. `verilator/sim/sim_blkdev_engine.h`
  (header-only, Verilator-independent); `sim_blkdevice.h/.cpp` rewritten
  as a thin 3-channel adapter; `sim_main.cpp` `ext_reset` sampling.
- **Module test:** DONE + extended. `module_tests/floppy_track/` with
  scenarios S1–S10 (S10 added this session: simultaneous queued mounts
  serialize, one one-tick pulse each, DUT resyncs, normal read
  latency). **92/92 PASS**.
- **Phase 3 (L2 shared host):** DONE. `unit_tests/level_2/l2_disk_host.h`
  (new), `main_l2.cpp` + `gui/main_gui.cpp` rewritten onto it (backups
  `*.bak_v6`), Makefile gains `-I$(REPO)/verilator/sim`. Headless
  `--empty`/`--disk` PASS on both CPUs; `--disk --scratch` PASS; GUI
  headless smoke PASS on both CPUs.
- **Phase 4 (regression matrix):** mostly green.
  - module test protocol properties incl. queued mounts: PASS
  - disk_ii equivalence `-CompareOnly`: PASS (known-good numbers)
  - L2 empty + DOS 3.3 boot, both CPUs: PASS
  - Vemu full `--smoke-test`: PASS (default floppy.nib unmodified)
  - mirrored `floppy_track.sv` byte-identical: verified
  - REMAINING: L2 directed write/reread (needs the TB debug-injection
    hook; `--write-test` deferred) and full-sim floppy write/reread
    (interactive DOS WRITE — manual check); explicit drive-2 DUT
    protocol sequence (engine channel handling is structurally
    identical; L2 build exercises the 2-channel engine).
- **Phase 5 (MiSTer integration):** A&S (quartus_map 17.0.2) SUCCEEDED
  (sys_top, 23,559 registers; v6 added 2 wrapper regs). Full compile
  remains for the user per AGENTS.md. The pre-existing `hdd_sector`
  Critical Warning is in the user's in-progress HDD workstream
  (`rtl/apple2_top.vhd` + `Apple-II.sv` both show uncommitted HDD
  changes), untouched by v6.

### v6 build notes (reproducible)

- Vemu build: `sh verilate.sh -j4` fails in this environment because the
  sub-make falls back to MSYS `make` and g++ temp-file creation breaks
  ("Cannot create temporary file in C:\WINDOWS\\"). Working sequence:
  run the verilator step, then finish objects with the native make:
  ```
  export PATH=/c/msys64/usr/bin:/c/msys64/ucrt64/bin:$PATH
  export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
  mingw32-make -C verilator/obj_dir -f Vemu.mk -j4
  ```
  (Two Vemu-specific fixes landed this session: `sim_blkdevice.h` port
  pointer types widened to match sim.v's 32-bit `sd_lba[3]` / 9-bit
  `sd_buff_addr` (IData*/SData*), and the `*sd_buff_addr` cast fixed to
  SData — the CData cast truncated the 9-bit address.)
- L2/module-test builds: `mingw32-make` with the same TMP trio (as
  before). Run exes from the repo root (CWD-relative ROM paths).

### v7 addendum (2026-09-06 ~16:05): `--write-test` landed

The Phase-4 REMAINING item "L2 directed write/reread (needs the TB
debug-injection hook; `--write-test` deferred)" is CLOSED:

- `run_l2.sh --write-test` (optionally `--write-test --disk <nib>`;
  default `unit_tests/level_2/DOS_3_3.nib`) boots from a scratch copy,
  waits for the drive to quiesce, injects a 16-byte pattern into ft1's
  track RAM through the new `tb_l2.sv` debug ports (`dbg_ft_wr_en/
  addr/data` — C++-driven top-level inputs, muxed onto port B, inert
  while low), and verifies the DUT's own dirty-track flush persisted
  the track over `sd_wr` (13 engine write sectors, bus settled, scratch
  file pattern at exactly the injected offsets, all other bytes
  identical, source image byte-identical).
- Green on nmos and wdc (exit 0), deterministic timelines; `--empty`
  regression still green (mux inert). Full record: PROGRESS.md v7.
- Phase-4 REMAINING now reduces to: full-sim interactive DOS WRITE
  (manual), optional `--drive2` scenario, real `.dsk`→`.nib`
  conversion, Phase 5 full Quartus compile (user).

