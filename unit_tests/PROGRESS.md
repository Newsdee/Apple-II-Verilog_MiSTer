# PROGRESS — `unit_tests` ladder / config −1 (isolated CPU + savestate)

**Repo:** `E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer`
**Last updated:** 2026-09-05 (session 4: level_1 GUI speed/vsync fix +
temporary vga_controller A/B variant — see §1h-GUI-VGA) —
**level_neg1 and level_0 are ALL GREEN on both CPUs** (§1d/§1f/§1g; the §1f
INT1/INT2 hang was a harness stub typo 0x87→0x8D — core exonerated).
**level_1 (video + keyboard, mono): GUI headless boot smoke PASS on both
CPUs** (full 2^22-cycle POR hold + ROM boot + non-blank screen, §1h-GUI);
the tb_l1 test-suite run was aborted at T6; T1–T5 anomalies diagnosed as
harness artifacts (unframe-aligned captures, analytic V expectations,
mis-armed PC traces) — fix list in §1h.
Bookkeeping done 2026-09-05: PLAN.md §3.3/§4/§7/§9 rewritten (level_1 =
video + keyboard, Disk II deferred), `run_unit_tests.ps1` gained a level_1
section, regeneratable run artifacts gitignored. level_neg1 + level_0 +
`common/` sources are **staged, not committed**; `level_1/` stays untracked
until green.

> **Scope note:** the repo-root `PROGRESS.md` / `PLAN.md` (untracked, from
> 2026-09-02) document the *other* task — the `R65Cx2` → top-level
> `rtl/cpu_65c02.sv` replacement + Quartus compile. That work is done and
> its "Outstanding / user actions" (hardware boot test, savestate phases in
> that PLAN.md §6) still stand. This file tracks the new `unit_tests/`
> feature. Do not conflate the two CPU efforts.
>
> **Companion file:** `unit_tests/PLAN.md` — the agreed config-ladder
> design (level definitions, correctness rules, roadmap). This file is the
> rolling state; PLAN.md is the design of record.

---

## 0. How to resume (cold-start checklist)

1. Read the workspace `AGENTS.md` (`E:\MiSTer\Apple-II_FPGAdev\AGENTS.md`) —
   operating rules: preserve EOLs, no unrelated cleanup, narrowest
   validation first, **do not commit unless asked**.
2. Read `unit_tests/PLAN.md` (design of record), then this file (state).
3. Read `unit_tests/level_neg1/tb_cpu.sv` (the harness as written),
   `main.cpp`, and the `Makefile` in the same directory.
4. **Git state:** the CPU swap (§1a) and the `unit_tests/` tree are
   **committed** (2026-09-04: `3c0c08b` = swap [its `verilator/Makefile`
   half landed earlier in the user's `0876f19`], `755ecd6` = unit_tests).
   Since then (2026-09-05 sessions 1-3 + bookkeeping cleanup): the
   level_neg1 + level_0 items are **staged, not committed** —
   `unit_tests/level_neg1/tb_cpu.sv` (TB bug fixes §1d + INT1/INT2 §1f +
   stub fix 0x87→0x8D §1g), `unit_tests/level_neg1/Makefile`,
   `unit_tests/level_0/` (tb_l0.sv stub fix + T2 span fix + boot trace),
   `unit_tests/common/` (extraction consumed by neg1 + L0),
   `unit_tests/PROGRESS.md`/`PLAN.md`/`run_unit_tests.ps1` (bookkeeping),
   and `unit_tests/.gitignore` (regeneratable run artifacts: logs, traces,
   VCD, PBM, out/). Regeneratable artifacts are NOT staged (gitignored).
   `unit_tests/level_1/` remains **untracked** (in progress, §1h). The
   repo also holds unrelated pre-existing user changes (see `git status`)
   — leave them untouched.
5. Pick up at level_1 (§3): level_0 and level_neg1 are green on both
   CPUs (§1g). Full history of the 2026-09-04 crashed session, if needed:
   `C:\Users\newsdee\.pi\agent\sessions\--E--MiSTer-Apple-II_FPGAdev--\
   2026-09-04T00-39-37-537Z_01a069db-5741-71fb-a761-3b8262cdc650.jsonl`

---

## 1. Completed in this session (2026-09-04)

### 1a. CPU swap in the Verilator machine build — DONE, both paths validated
Replaced the machine's CPUs with the cores under `rtl/cpu/`:
- `T65` (6502 path) → **`nmos6502`** (`rtl/cpu/nmos6502/`, `WDC_MODE=0`).
- top-level `cpu_65c02` (65C02 path) → **`wdc65c02`** (`rtl/cpu/wdc65c02/`,
  `WDC_MODE=1` default; its ports are byte-identical to the old top-level
  `cpu_65c02.sv`, so this side is a pure rename).

Because both core folders shared the module names `cpu_65c02`/`cpu_alu`,
modules were renamed so both coexist in one build:
- `rtl/cpu/nmos6502/cpu_65c02.sv`: `cpu_65c02` → `nmos6502`
- `rtl/cpu/nmos6502/cpu_alu.sv`: `cpu_alu` → `nmos6502_alu`
- `rtl/cpu/wdc65c02/cpu_65c02.sv`: `cpu_65c02` → `wdc65c02`
- `rtl/cpu/wdc65c02/cpu_alu.sv`: `cpu_alu` → `wdc65c02_alu`

Files changed (6, all EOL-clean per `git diff --numstat` vs
`--ignore-all-space`):
- the 4 files above
- `rtl/apple2.v` — T65 instance replaced by `nmos6502` (wire renames +
  NMOS-only pins `so_n/be/ml_n/phi1o/phi2o/bus_oe/dout_oe` tied off), WDC
  instance renamed, bus mux + debug wiring updated. `DBG_T65_REGS` port
  name kept (intentionally).
- `verilator/Makefile` — `V_CPU` now lists
  `$(RTL)/cpu/nmos6502/{cpu_65c02,cpu_alu}.sv` +
  `$(RTL)/cpu/wdc65c02/{cpu_65c02,cpu_alu}.sv` in place of `t65/*`.

Old sources preserved on disk: `rtl/t65/*`, `rtl/cpu_65c02.sv`,
`rtl/cpu_alu.sv` (still used by module_tests goldens).

**Validation:**
- `cpu_type=0` (nmos6502): full clean build + `run_verilator.bat
  --smoke-test` → **SMOKE PASS** (frames=6, active_width=559,
  audio_samples=812500, exit 0).
- `cpu_type=1` (wdc65c02, temporary flip in `verilator/sim.v`): rebuild →
  **SMOKE PASS**, identical metrics.
- `sim.v` reverted to `1'b0`, final rebuild + smoke **PASS** — shipped
  `Vemu.exe` matches committed source.

### 1b. Build-environment quirks discovered (workarounds now baked into the Makefile)
1. **TMP does not propagate into MSYS2 `bash.exe`** — exports from the tool
   shell arrive empty in the child, so g++ falls back to `C:\WINDOWS\` and
   fails with "Cannot create temporary file". Fix: set `TMP/TEMP/TMPDIR`
   *inside* the MSYS2 bash (e.g. `/c/msys64/tmp`). The user's normal
   `build_verilator.bat` flow is unaffected (Windows sets TMP there).
2. **Verilator 5.050 MSYS2 `--timing` prefix bug** — it misdetects its
   install prefix (computes `/ucrt64`, a nonexistent POSIX path; real dir
   is `/c/msys64/ucrt64`), so `--timing` std-file lookup fails. Fix:
   `VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator` (wired into the
   level_neg1 Makefile). `-I`/mangled-path workarounds were tried first and
   failed; `VERILATOR_ROOT` is the clean fix.
3. **Two-stage build in Verilator 5** — `verilator_bin --cc --timing -exe`
   only *generates* C++ + `Vtb_cpu.mk`; the actual g++ compile+link is the
   second step `make -C obj_dir -f Vtb_cpu.mk`. (The machine build's
   `verilate.sh` does this already; level_neg1 replicates it.)
4. **Coreutils are not on a regular Windows PATH** — `dirname`/`ls`/`rm`/
   `head`/`mkdir` live in `C:\msys64\usr\bin`, which a PATH inherited from
   Explorer/cmd/PowerShell does not contain (a fresh MSYS2 bash does NOT
   prepend its own dirs when a Windows PATH is inherited). Every entry
   point now exports `PATH=/c/msys64/usr/bin:/c/msys64/ucrt64/bin:$PATH`
   *inside* the MSYS2 shell: `run_neg1.bat` (prepends both Windows dirs
   before launching bash + `pushd`s to its own dir), `run_neg1.sh`, and
   the `run_unit_tests.ps1` one-liner. Verified with a throwaway bat that
   resets PATH to the stock Windows value first.
5. **SDL.h swallows `main` on Windows** — `SDL_main.h` does
   `#define main SDL_main` unless `SDL_MAIN_HANDLED` is set; a GUI main
   that forgets it compiles to `SDL_main`, leaving the exe with no entry
   point. The link failure is misleading: ld pulls the GUI-CRT trampoline
   (`crtexewin.o`) and reports `undefined reference to WinMain`, and
   `--subsystem console` / `-mconsole` do NOT fix it. Fix: `#define
   SDL_MAIN_HANDLED` before `#include <SDL.h>` (see `gui/main_gui.cpp`).
6. **The obj_dir stage runs under NATIVE mingw32-make** — unlike the msys
   bash stage, the `-I` paths and `-D` values inside Verilator's
   `-CFLAGS` reach native g++ UNCONVERTED and UNSTRIPPED: use
   Windows-style include paths (`C:/msys64/...`, not `/c/msys64/...`) and
   never shell-quote `-DNAME=value` (quotes survive as literal characters
   and become a C char-constant error). `GUI_CPU_NAME` is therefore passed
   unquoted and stringified in C++ (`GUI_STR` two-level macro).

### 1c. Design facts established for config −1 (the harness rests on these)
- The cores consume only `clk` + `ce` — **not** the DRAM RAS/CAS/AX
  signals — so a bare-CPU harness with a faithful 2-phase `ce` is safe.
- **1-`ce`-cycle delayed read**: the core presents `addr` in cycle N and
  samples `din` in cycle N+1 (exactly `apple2.v`'s `CPU_DL` latch). Writes
  commit when `we` is high. Replicating this in the behavioral memory is
  mandatory (a same-cycle model gives false negatives).
- **Savestate bus** (both cores): with `stall=1` held, `ss_wren` writes
  `ss_addr=SS_BASE` → {PC, A, X, Y, S, flags, IR}; `SS_BASE+1` →
  {micro-sequencer state/addr, NMI/IRQ latches}; `SS_BASE+2` →
  {SO/IRQ/φ2 latches} (code comment: "core held in stall while these
  apply"). `ss_rdata` is a **combinational** readout of PC/A/X/Y/S/flags —
  the harness can peek CPU state any cycle.
- **Port delta:** `nmos6502` adds `so_n, be, ml_n, phi1o, phi2o, bus_oe,
  dout_oe` (all unused on Apple II); everything else is identical to
  `wdc65c02`.

### 1d. level_neg1 made green, both CPUs (2026-09-05 session)
The accessor issue from the crash is resolved (the committed Makefile uses
plain `-public`; the generated `Vtb_cpu.h` does expose module-scope regs —
`errors()`, `stall()`, `ss_wren()`, …). Four real bugs were then found and
fixed in `tb_cpu.sv` (all TB-side; the CPU cores were never changed):

1. **Harness bug (the big one): the memory model latched read data 2
   `ce` cycles after the address, not 1.** The `mem_rdata` comment said
   "one `ce` after `addr`" but the code latched on `posedge clk` gated by
   `ce` — i.e. at the *end* of the following `ce` cycle. The core (and the
   real machine's `CPU_DL`) samples `din` one `ce` cycle after presenting
   `addr`, so any read-heavy program hung / saw wrong data. Fix: latch on
   `negedge phase_zero` (end of the φ1 half-cycle) — the DRAM CAS→out
   window samples at φ2, i.e. one `ce` after the address was presented.
2. **Test-program bug:** the self-check opcodes did not match their
   comments — `LDX`/`LDY` immediate bytes were swapped and `9D` (STA
   abs,X) was used where `99` (STA abs,Y) was intended. Fixed to
   `A2 34` / `A0 28` / `99 00 04`.
3. **Wrong expectation:** S after reset is `0xFD`, not `0xFF` — S
   initializes to `0x00` and the 7-cycle reset sequence performs three
   phantom stack pushes (documented in the cores; confirmed by the
   pagetable trace).
4. **1-`ce` drift in the save/restore tests:** deasserting `stall` raced
   the core's `ce`-fall advance; entering `run_ce()` mid-φ2 let the
   core's in-flight cycle consume the first counted advance, so checks
   sampled state one cycle late (false `A`/`X` mismatches). Fix:
   `run_ce(n)` is now **phase-independent** — it counts exactly `n`
   core-advancing `ce` cycles from any entry phase; `save_state`/
   `restore_state` leave the core stalled (no mid-pulse release).

**Result (verified):**

```
CPU_NEG1 PASS  cpu=nmos6502  (self-check + save/restore equiv + RAM restore)   errors=0, exit 0
CPU_NEG1 PASS  cpu=wdc65c02  (self-check + save/restore equiv + RAM restore)   errors=0, exit 0
```

**Runner written + validated:** `unit_tests/run_unit_tests.ps1` (roadmap
#4). One MSYS2 bash per (level, CPU): sets PATH/TMP/TEMP/TMPDIR/
VERILATOR_ROOT *inside* the shell, `mingw32-make CPU=x`, runs
`build_x/obj_dir/*.exe` from the level dir, logs to `rebuild_x.log` /
`run_out_x.log`. Exit-code contract: 0 = pass, 201 = build fail, 202 = no
exe, else the exe's own exit code. Summary table + non-zero exit on any
failure. All three paths exercised (real PASS on level_neg1; synthetic
BUILD FAIL and RUN FAIL levels, since deleted).

**PowerShell gotcha found (baked into the runner):** in an expanded
here-string, `` `"$var" `` escapes the *quote*, leaving `$var` expandable —
PS silently substituted an empty string. Keep bash `$` literals as
`"$`var"` (backtick on the dollar). Non-ASCII chars in the .ps1 also get
mangled under PS 5.1 (no-BOM file read as ANSI) — the runner is pure ASCII.

### 1e. level_neg1 GUI (imgui + SDL2): pause/resume + live visual feedback (2026-09-05)
New interactive harness on the same config −1 design, so the core can be
stopped/started by hand and watched while it runs.

**Files:** `tb_cpu_gui.sv` (mirror of `tb_cpu.sv` — same clock/memory/DUT
wiring, but `stall` is now driven exclusively from C++ so the checkbox owns
it with no multi-driver race; no self-check, no `$finish`; a demo DEX loop
at $0800 keeps A/X moving and writes a moving byte pattern into RAM
$0200/$0201 every iteration — the "alive" signal); `gui/main_gui.cpp`
(SDL2 window, GL 3.2, imgui: **Stall (pause core)** checkbox that writes
`tb_cpu_gui__DOT__stall`, live readouts of PC/A/X/Y/S/P, IR, CE state,
bus addr/din/dout/we, the two RAM bytes, a `ce_count` counter and a
"core activity" progress bar that flatlines the moment the core stalls;
Space toggles the checkbox, Esc quits); `gui/imgui/` (vendored Dear ImGui
v1.92.9b core + SDL2/OpenGL3 backends, self-contained GL loader); the
Makefile gains a `gui` target (`build_<cpu>_gui/obj_dir/Vtb_cpu_gui.exe`, links
`-lSDL2 -lopengl32`); `run_neg1.sh` gains `gui` / `--stall-test` /
`--run-frames N` args; `run_neg1_gui.bat` (Windows entry, stock PATH).

**Visual-feedback design:** the demo program keeps A/X stepping and the
RAM bytes cycling while running; with the checkbox ticked every readout
freezes and the activity bar flatlines — the pause is visible in the GUI
itself, and the `--stall-test` headless path proves the same write freezes
/resumes the core's `ce_count` (the checkbox and the test write the same
generated field).

**FPS counter (2026-09-05, added on request):** the window is resizable
(`SDL_WINDOW_RESIZABLE`; the imgui window and the GL viewport already
followed the drawable size each frame, so the flag alone was enough), and
the top of the window shows `frame_count` + `FPS: %f` + per-frame ms — the
same wall-clock-per-frame measurement as the machine build's
`SimVideo::stats_fps` in `verilator/sim/sim_video.cpp` (`GetSystemTime`
on Windows / `gettimeofday` elsewhere, `fps = 1000.0 / frameTime`,
sampled once per presented frame — the GUI equivalent of that code's
per-video-frame vsync sample). Note: this counts GUI render frames
(display-limited, ~60 FPS with vsync), not simulation speed.

**SIM SPEED line (2026-09-05, added on request):** the GUI equivalent of
the headless `CPU_NEG1 SPEED` report. A 1-s wall-clock window over
`ce_count` (the TB's stall-gated core-cycle counter; the core's `ce`
pulses every 100 ns of sim time, so Δce/Δwall is simulated CPU MHz):
`sim speed (1 s window): X.XXXX MHz (=Δce ce / Δsim ns / Δwall ms)`.
Reads ~0 while stalled (context.time() keeps advancing, the core does
not — the raw window shows the sim-time-vs-wall compression) and is
vsync-rate-limited (slots-per-frame x display Hz), so it measures far
below the headless throughput (~0.006 MHz GUI vs ~6.7 MHz headless at the
default 200 slots/frame — the render loop, not the model, is the
bottleneck). The 240-frame heartbeat printf now includes `sim=X.XXXX MHz`
so the number is checkable headlessly.

**Verified:** `CPU_NEG1_GUI STALL_TEST PASS` on nmos and wdc (ce_count
99→174 running, 174→174 frozen, 174→249 released); 120-frame windowed
smoke on both CPUs (PC parked in the DEX loop at $0804, clean exit);
full `.bat` flow re-verified under a stock Windows PATH (including after
the FPS/resizable changes). `--run-frames N` is the headless-ish smoke
mode (still opens the window; a true `SDL_VIDEODRIVER=dummy` mode could be
added later). Build gotchas found: §1b items 5 and 6. (One transient
`0xC000013B` DLL-load failure was seen on a mid-session rebuild; the
identical code rebuilt and validated clean minutes later — not a code
defect.)

---

## 1f. level_0 T3/T4 bisection → level_neg1 INT1/INT2 (2026-09-05, session 2)

**Context.** level_0 (`unit_tests/level_0/tb_l0.sv`, built + running) tests:
T1 reset vector, T2 cold-boot steady loop, T3 NMI, T4 IRQ, T5
save/restore/stomp/restore. **T1/T2/T5 PASS; T3/T4 FAIL with 7 errors**
(reproduced deterministically; `bash run_l0.sh nmos`):

```
  DBG NMI vec rom[1FA]=006 rom[1FB]=024 IRQ vec rom[1FE]=002 rom[1FF]=0a9
  DBG post-NMI PC=00604 S=0eb s_before=0fd
  CHECK FAIL: T3 NMI stub marker (STA $0200)  got=0x00 exp=0xa1
  CHECK FAIL: T3 S restored after RTI  got=0xe8 exp=0xfd   (0xeb in the L0 DBG line)
  CHECK FAIL: T3 NMI: PC=0x0604 not back in the loop after RTI
  CHECK FAIL: T4 IRQ: pushes not captured (int_done=0 s_before=fd pc=0801)
  CHECK FAIL: T4 IRQ stub marker (STA $0201)  got=0x00 exp=0xa2
  CHECK FAIL: T4 S restored after RTI  got=0xd1 exp=0xfd
  CHECK FAIL: T4 IRQ: PC=0x0608 not back in the loop after RTI
```

L0 T3/T4 design: the harness patches the BIOS ROM's interrupt vectors
(`patch_rom_vec` writes `rom[]` directly) to point at RAM stubs
(NMI stub @ $0600: `A9 A1 87 00 02 40` = LDA #$A1 / STA $0200 / RTI;
IRQ stub @ $0610 with marker $A2 → $0201), resets into a payload loop
@$0800 (`EA EA 58 4C 00 08` = NOP NOP CLI JMP $0800), fires the interrupt
**non-invasively** (an always block asserts the line low for exactly 1 `ce`
when the core is at the 1-cycle NOP at $0800), captures the 3 pushed bytes
from RAM when `S == s_before − 3`, and expects the stub to run to RTI with
S restored.

**Bisection (user-directed):** "if a test looks like it may be a CPU issue,
move it to level −1 so the CPU core can be ruled out more fundamentally."
INT1 (NMI) + INT2 (IRQ) were ported into `level_neg1/tb_cpu.sv` with the
identical payload/stubs/fire/capture mechanism, except **every byte is
harness-controlled plain RAM**: vectors written with `mwr(16'hFFFA,...)` /
`mwr(16'hFFFE,...)` (neg1 already enters programs by writing the reset
vector into RAM), no ROM, no `apple2.v` decode, no ROM patching.

**Result: the EXACT same failure reproduces on neg1** (nmos, first run —
wdc not yet run):

```
CPU_NEG1: CPU=nmos6502  (config -1, isolated CPU + memory + savestate)
INT1/INT2: NMI/IRQ vector fetch + stub + RTI...
  CHECK FAIL: INT1 NMI stub marker (STA $0200)  got=0x00 exp=0xa1
  CHECK FAIL: INT1 S restored after RTI  got=0xe8 exp=0xfd
  CHECK FAIL: INT1 NMI: PC=0x0604 not back in the loop after RTI
  CHECK FAIL: INT2 IRQ: pushes not captured (s_before=fd pc=0801)
  CHECK FAIL: INT2 IRQ stub marker (STA $0201)  got=0x00 exp=0xa2
  CHECK FAIL: INT2 S restored after RTI  got=0xd3 exp=0xfd
  CHECK FAIL: INT2 IRQ: PC=0x0608 not back in the loop after RTI
CPU_NEG1 FAIL  cpu=nmos6502  (errors=7)
```

**Signature (both environments, identical):**
- Entry is correct: the 3 pushed bytes ARE captured and correct — pushed
  PC = $0801 (interrupt latched as the NOP at $0800 completes), pushed P
  has I clear (the payload's CLI ran). The vector fetch also worked (PC
  lands in the stub).
- The CPU then **hangs mid-stub at the absolute-STA's address-hi fetch**:
  PC = $0604 (NMI stub) / $0608 (IRQ stub), the STA marker byte is
  **never written** (ram[$0200]/[$0201] stay 0x00), S is corrupted, RTI
  never runs. The core is not dead — it ran 100+ `ce` in the wait loop.
- **S values are the smoking gun:** s_before = $FD. Observed S at the
  hang: $E8 (neg1 NMI), $EB (L0 NMI), $D3 (neg1 IRQ), $D1 (L0 IRQ).
  $FD − $E8 = 21 = 3×7, $FD − $EB = 12 = 3×4, $FD − $D3 = 42 = 3×14 →
  consistent with **repeated 3-byte push groups** (the interrupt sequence
  pushing PCHi/PCLo/P over and over), i.e. the interrupt state machine
  re-entering — NOT a single push triple (which would give $FA).

**Interpretation:**
- The L0 harness (ROM, machine decode, `patch_rom_vec`) is **exonerated**
  as the cause of the functional failure — the failure exists with the
  core + behavioral RAM alone.
- **Prime suspect: the CPU core's interrupt path** (entry re-triggering /
  push-sequence re-entry; or a hang in the interrupt microstate that also
  corrupts S). Note the machine-level smoke test and real hardware pass
  (Total Replay boots, IRQs fire), so if this is a core bug it is subtle
  and/or stimulus-specific (see the P3-suite delta below).
- L0's T4 "pushes not captured" is a **downstream artifact**, not a second
  bug: by the time T4 fires, T3's NMI has left the core hanging in its
  stub (PC=$0604 ≠ $0800, so the T4 fire condition never triggers).
  (neg1 INT2 shows the same: its fire+entry worked — pushed pc=$0801 was
  captured — wait: the neg1 line says "pushes not captured (s_before=fd
  pc=0801)" — int_done=0 but int_pushed_pc shows $0801 because INT1's
  capture wrote it; INT2's own capture window never opened. Same artifact.)

**L0 rom[] value anomaly (separate open thread, NOT the functional cause):**
the post-T3 DBG reads `rom[0x1FA]=06 rom[0x1FB]=24` (NMI vector reads as
$2406) and `rom[0x1FE]=02 rom[0x1FF]=A9` (IRQ vector reads as $A902) —
neither the on-disk original ($FFFA/$FFFB = FB 03, $FFFE/$FFFF = FA C3 —
verified by raw `tail` of `rtl/roms/apple2e.hex`) nor the patched values
(00 06 / 10 06). The CPU nevertheless fetched $0600 as the NMI vector
(proof the patch WAS visible at fetch time), then the array reads back
other values. Unexplained (Verilator `--x-assign fast` + `$readmemh` +
blocking array writes quirk? index math? stale build? — the build was from
the current source, re-run deterministically reproduces). Parked: the
neg1 bisection removed rom[] from the critical path. Cheaper experiment if
revisited: `$display` `rom[0x1FA..0x1FF]` immediately after
`patch_rom_vec` (before any CPU run) to see whether the write lands at
all.

**The existing 65c02 suite's interrupt coverage (reviewed on request):**
`module_tests/cpu_65c02/` has a **Priority-3 directed case set — BRK/RTI/
IRQ/NMI/reset-midstream/RMW-toggle — 12/12 green** (`build/p3/summary.json`,
see `FINAL_VERDICT.md`), run differentially against the R65Cx2 golden
(trace equivalence, "resync comparison" for entry-latency deltas). Two
deltas vs INT1/INT2 that may matter:
1. **Pulse width:** P3 uses `pulse_len: 8` (8-cycle interrupt pulses); our
   non-invasive fire holds the line low for exactly **1 `ce`**. A 1-`ce`
   pulse is artificial — real Apple II peripherals hold IRQ/NMI low for
   many cycles.
2. **Check style:** P3 compares the core to a known-good golden; INT1/INT2
   check absolute architectural completion (stub marker written, S
   restored, PC back in the loop). A core that misbehaves identically in a
   way the golden shares would pass P3 but fail INT1/INT2 — though R65Cx2
   is a proven core, so a golden-shared fault is unlikely.
Conclusion: P3 does NOT prove 1-`ce`-pulse NMI/IRQ entry works; the new
tests exercise genuinely new stimulus. "Is our test wrong" is still open
until the hang is characterized (§3).

**Core interrupt microarchitecture facts (from `rtl/cpu/nmos6502/cpu_65c02.sv`):**
- Level sampling per `ce`: `nmi_sync <= nmi_n; nmi_last <= nmi_sync;` and
  `irq_l1 <= ~irq_n; irq_l2 <= irq_l1` (2-stage latches). NMI edge
  detector `nmi_edge = nmi_last && !nmi_sync` (fires the `ce` after the
  line was sampled low, once per falling edge regardless of pulse length).
- `take_int = !nop1_hold && (nmi_pending || (irq_l2 && !int_i_mask))` —
  evaluated in **S_FETCH**; design comment: IRQ polling deliberately uses
  the end-of-second-to-last-cycle value; `int_i_mask` is the delayed view
  of I (refreshed at every opcode fetch; forced on interrupt entry;
  restored by RTI before polling).
- S_FETCH with `take_int`: discard the fetched opcode, `int_active <= 1`,
  `int_is_nmi <= nmi_pending`, `addr <= reg_pc` (dummy re-read),
  `state <= S_OP2` (the interrupt sequence runs from there; push writes
  use `dout <= int_active ? reg_pc[15:8] : pc_inc[15:8]` at lines ~925-940).
- RTI = microstates S_RTI_P/S_RTI_PL/S_RTI_PH (28/29/30, lines ~1304-1330);
  `nmi_pending <= nmi_edge` also appears at line ~1350 (context not yet
  traced).
- Savestate **word1** (ss_addr=SS_BASE+1) = {dl, ea, state, nmi_pending,
  nmi_last, int_active, int_is_nmi, in_wai, in_stp, idx_carry, idx_reg,
  nop8_cnt, addr} and **word2** = {φ2 latch, so_last, so_sync, irq_l2,
  irq_l1, rst_seq, nmi_sync, nop1_hold, int_i_mask, we, sync, vector_pull,
  dout} — everything needed to characterize the hang is readable via the
  existing savestate readout (`ss_rdata` is a `ss_addr`-muxed combinational
  readout; **word0[63:48]=PC only when ss_addr==0** — the INT monitor
  relies on `peek_pc` leaving ss_addr=0).

**Files changed this session (uncommitted):** `unit_tests/level_neg1/tb_cpu.sv`
(header note #4; `nmi_n`/`irq_n` comments; new `peek_pc`/`peek_s` tasks;
new `load_interrupt_test` task; new non-invasive-interrupt always block +
`int_arm`/`int_reset`/`int_fired`/`int_done`/`int_complete`/`int_deassert`/
`int_s_before`/`int_pushed_pc`/`int_pushed_p`; driver INT1/INT2 section
before the summary; PASS message now says "... + NMI/IRQ vectors". 2026-09-05
session 3 (§1g): stub opcode fix 0x87→0x8D — INT1/INT2 now **pass** on
both CPUs.)
`bash eol_guard.sh` → no CR-count drift. `tb_l0.sv` unchanged this session.
Previous uncommitted state stands: §1d/§1e level_neg1 modifications +
`run_unit_tests.ps1`; `unit_tests/level_0/` + `unit_tests/common/`
untracked.

**Crashed-session reference (session 1):**
`C:\Users\newsdee\.pi\agent\sessions\--E--MiSTer-Apple-II_FPGAdev--\
2026-09-04T19-27-22-019Z_01a06de3-d1a2-739c-a58a-8cd4a9637ee7.jsonl`
(level_0 build + first T3/T4 failures).

---

## 1g. L0 + level_neg1 ALL GREEN — T3/T4 and T2 root causes (2026-09-05, session 3)

The §1f hang thread is **closed: no core bug found in either thread.**

**T3/T4 root cause — test-stub opcode typo (harness, not core).**
Both TBs' interrupt stubs contained `mwr(16'h0602, 8'h87)` / `mwr(16'h0612,
8'h87)` where `8'h8D` (STA absolute) was intended. 0x87 is not STA
absolute; the core executes it as a ZP-mode RMW (addr=$0000), so the stub
never wrote its marker, then fell off the end of the stub into a
BRK→NMI-vector re-fetch loop (the stale `int_is_nmi` latch made the
re-fetch target $0600 → infinite loop, S decrementing 3/loop — exactly
the "S keeps decrementing" symptom). The ce-by-ce trace (`hang_trace.txt`,
neg1) proved the core's NMI entry is textbook-correct: push
$08/$01/$20 to $01FD/$01FC/$01FB, S $FC→$FA, vector $FFFA/$FFFB →
$0600. **Fix: 0x87→0x8D in both TBs** (level_neg1 `tb_cpu.sv` ×2,
level_0 `tb_l0.sv` ×2 + comment). After the fix: neg1 PASS both cores;
L0 T1/T3/T4/T5 PASS both cores.

**T2 wdc root cause — phase-dependent single-sample window (harness,
not core).** wdc's T2 sampled PC=$FCAA at 2500 ce, outside the old
$FCAB-$FCB5 window. A ce-by-ce 2500-ce boot trace diff (nmos vs wdc,
run-length-encoded PC streams) shows the two cores execute the **same
code path for all 2073 distinct PC transitions** and end in the **same
steady loop**: body = exactly $FCAA/$FCAB/$FCAC/$FCAD/$FCAE (~5-6 ce per
pass, S=$F5, no excursions in the last 500 ce) — wdc merely lagged nmos
by 1-2 ce (mode cycle-count differences, e.g. a WDC extra state at $FDF0
during boot) and was sampled at $FCAA. The old window covered only 3 of
the 5 loop addresses → a single sample was a 60% lottery. **Fix: T2 now
asserts the full loop span $FCA8-$FFAF (loop body + $FF80-$FFAF keyboard
routine) on the primary sample AND a 10-sample × 4-ce majority check
(all 10 inside).** T2 PASS both cores.

**L0 `rom[]` anomaly — resolved as a Verilator 5.050 display artifact.
** The harness's `$display` of `rom[14'h01FA]` (constant index) read back
the `$readmemh` initial values even after `patch_rom_vec` wrote the array,
while an **immediate readback inside the task (variable index**
`rom[vaddr[13:0]]`) **shows the correct patched values** — and the core's
read path is variable-indexed (`rom[rom_addr]`), which is why the patched
vectors are visible to the core (T1/T3/T4 pass). Verilator constant-folds
constant-index reads of the 16K array and loses the write tracking. No
functional impact; the misleading constant-index display was removed and
the immediate variable-index readback kept as evidence.

**Files changed (uncommitted):** `unit_tests/level_0/tb_l0.sv` (stub fix
0x87→0x8D ×2; T2 window → $FCA8-$FFAF + 10-sample majority check;
ce-by-ce boot trace block `boot_trace.txt` (2500 ce, armed at T2);
savestate word dump after the sample window; header/timing comments
updated to the measured loop; `patch_rom_vec` immediate readback;
constant-index rom[] display removed). `unit_tests/level_neg1/tb_cpu.sv`
(stub fix 0x87→0x8D ×2; the §1f trace block remains). Scratch:
`level_0/boot_trace{,_nmos,_wdc}.txt`, `pcs_*.txt`, `pcseq_*.txt` (deletable).

**Validation (2026-09-05 session 3, Verilator 5.050, MSYS2 ucrt64):**
`run_l0.sh nmos` → L0 PASS; `run_l0.sh wdc` → L0 PASS; `run_neg1.sh nmos`
→ CPU_NEG1 PASS; `run_neg1.sh wdc` → CPU_NEG1 PASS. `bash eol_guard.sh` →
no CR-count drift. No core RTL changes this session (nothing to re-verify
in Quartus; the §2026-08-31 pending compile state is unchanged). The L0
boot trace (`boot_trace.txt`) is left enabled at T2 — it is cheap (2500
lines) and is the standing instrument for any future cold-boot
bisection; disable by setting `boot_trace_en` initial to 0.

**Decision record (per the "do not silently tune the test" rule):** both
T2 and T3/T4 changes are test-harness corrections (a wrong opcode literal
and a too-narrow phase-dependent window), with the core behavior
positively verified by ce-by-ce traces before and after. No core defect
was masked.

---

## 1h. level_1 (video + keyboard, monochrome) — created, build green, first run partial (2026-09-05)

**Scope redefined (user-confirmed):** level_1 is **native MONOCHROME video +
PS/2 keyboard**, NOT Disk II (Disk II moves to a later level).  DUT = the
full `rtl/apple2.v` core (both CPUs, BIOS ROM, HAL, video pipeline —
unmodified) + `rtl/keyboard.v` (unmodified); the TB samples the native
`VIDEO`/`HBL`/`VBL` ports directly, bypassing the color pipeline
(`vga_controller` lives in `apple2_top` and is NOT pulled in).  This
enables video-ROM-variant testing (`ROMSWITCH` upper/lower 4K halves) +
keyboard-ROM testing, plus a REPORT-only attempt to boot the ROM monitor
with just the BIOS.  (PLAN.md was rewritten 2026-09-05 to match this scope:
video + keyboard, Disk II deferred.)

### Files (new; untracked dir `unit_tests/level_1/`)
- `tb_l1.sv` — the TB; header comment is the design of record (DUT
  composition, machine-parity wiring per `apple2_top` lines, test list
  T1–T7, CWD contract).  One build covers BOTH CPUs (`apple2` muxes on its
  `cpu` input; `+cpu=0` nmos / `+cpu=1` wdc at runtime).
- `main.cpp` — L0 pattern + `--vcd=FILE` (per-run trace file).
- `Makefile` — single build dir `build/`, `Vtb_l1.exe`; sources:
  apple2.v, keyboard.v, timing_generator.v, video_generator.v, rom.v,
  **ramcard.v** (discovered this session: `apple2.v:247` instantiates
  `ramcard` — was missing from the old module inventory; inert here with
  `saturn_5_inslot=0`), 4 CPU files; ROM deps apple2e/keyboard/video2/video.
- `run_l1.sh` / `run_l1.bat` — build once, run twice (`+cpu=0`, `+cpu=1`)
  **from the repo root** (the DUT's `$readmemh` paths are CWD-relative);
  outputs to `unit_tests/level_1/out/`.  Args: `clean`, `--trace`.

### Build: GREEN
`mingw32-make -C unit_tests/level_1` → exit 0.  Warnings: width noise
only (zero-extension of known-small values, `if (fd_*)` 32→1-bit, line
index guarded by `smp<1024`) — no new correctness warnings.

### First run (nmos, 2026-09-05 11:11): reached T6, then aborted. Data:
- **T1 line geometry: perfectly stable — 560 samples/line, 559 HBL-low
  (active)**.  My 200–500 expected-window was wrong (a text line is 560
  master cycles; HBL is a ~1-sample pulse at the line end).
- **T1 VBL: 101 VBL-high lines per 400k cycles (14.1 %)** — does NOT match
  my 24-per-390-lines (6.2 %) prediction from the timing_generator read
  (consistent instead with 48-high/~340-line or 24-high/~170-line).
  → **need a direct V-period measurement, not an analytic assumption.**
- **Video-ROM files (correcting the old "Part1" note):** `video2.hex` =
  343 lines × 24 B → the **COMPLETE 8K video ROM** (old "5488 B" note was a
  byte-width miscount); upper 4K is real data (2640 non-zero entries
  5488+).  `video.hex` = 256 × 16 B = exactly the lower 4K and matches
  `video2.hex[0:4095]` **4096/4096** (measured in-run).  `keyboard.hex` =
  128 × 16 B = 2048 B = exactly fills the 2048-entry (11-bit-addr) keyboard
  ROM.  All three ROM files are complete and self-consistent.
- **T4: ROMSWITCH halves genuinely differ** ('A' diff 39548, '@' 74448) —
  the LOCAL half is a real font, not a blank.  The "restore to 0" check
  failed (76118) — artifact of the mis-aligned capture, see next.
- **T2/T3/T4-restore/T5 large inter-capture diffs (44938 / 62802 / 76186,
  worst line 548 ≈ a full line) = capture window is NOT frame-aligned:**
  the capture starts at an arbitrary HBL edge inside the 2.9M-cycle flash
  window, so the 250-line window lands at a different V position on every
  capture.  T2's cursor-row errors (rows 52–66 and 116–130, diffs 92–470)
  are consistent with the same artifact.  **Likely harness bug, not DUT
  bug — the harness needs a frame anchor.**
- **PC traces mis-armed:** all 4000 boot-trace entries were consumed during
  the ~4.19M-cycle POR hold while the CPU was still in reset (ADDR=0x0100
  = reset-state bus).  Boot/monitor traces are currently useless; arm on
  reset deassertion (first post-reset entry should be $FFFC).
- T6 (keyboard) had just started — no results yet.

### Fix list (next session, in order)
1. **Frame anchor:** start the capture at the **VBL falling edge**
   (retrace done → first active line); keep the flash window for the
   cursor phase.  `cap[]` line 0 = frame line 0, deterministic across runs.
2. **T1:** pin line length 560 (tolerance ±8), active window = 559; add a
   **direct V-period measurement** (VBL fall → count lines to rise = H;
   to next fall = L; report both; assert once stable across runs).
3. **T2:** after alignment, **measure the character-row period P** (try
   offsets 8–24, pick the offset minimizing total row diff), then assert
   period-P repetition except cursor rows.
4. **Move the PBM dump to right after T2** so a failing first run still
   yields `l1_screen_a.pbm` to eyeball.
5. **T3/T4-restore/T5:** re-pin thresholds from aligned captures; if T5
   X-vs-Z (2×2^22 cycles apart) still diffs large, measure the cursor blink
   period empirically (sample the cursor cell at several phases).
6. **PC traces:** arm a one-shot on `reset_sync` 1→0 (boot) and after the
   F2-release POR hold (monitor).
7. **Update the t4files expectation** (video2 = complete 8K, not a Part1
   extract) and the T4 "upper half partially zero" note in tb_l1.sv.
8. Then: wdc run, pin the measured constants in comments, and drive both
   CPUs to green. (Bookkeeping already done 2026-09-05: PLAN.md §3.3/
   §4/§7/§9 rewritten; `run_unit_tests.ps1` level_1 section added.)

### 1h-GUI. level_1 GUI: native video window + headless boot smoke — SMOKE GREEN both CPUs (2026-09-05, session 2)

**Scope:** a level_1 GUI that renders the machine's **native monochrome
video** (one `VIDEO` bit per 14.318 MHz master cycle, 560 px × measured
262-line frames) to an SDL2/OpenGL3/imgui window with FPS + sim speed,
pause (stall), and a **cold reboot** control — plus a headless boot smoke
that runs the full 2^22-cycle power-on hold and checks the screen is not
blank after boot.  DUT is the same unmodified `rtl/apple2.v` +
`rtl/keyboard.v`; one build covers both CPUs (`+cpu=` at runtime).

**Files (new, in the untracked `unit_tests/level_1/` dir):**
- `tb_l1_gui.sv` — GUI TB: same machine wiring as `tb_l1.sv`, no test
  sequence, no `$finish`; C++-driven `stall` / `reset_cold`; a **frame
  packer** anchored on the VBL falling edge copies committed lines into a
  512×1024-bit `frame[]` reg + `frame_valid`/`frame_lines`/`frame_count`;
  `screen_ink` (text-page ink counter); reset-chain + bus diagnostics
  (`flash_div`, `dbg_clk_cnt`, `dbg_addr_last`/`dbg_addr_chg` — REG
  samplers, see the stale-wire lesson below).
- `gui/main_gui.cpp` — SDL2 + OpenGL3 (core profile 3.2) + imgui; video
  blitted with `glDrawPixels` (C++ nearest-neighbour scale, centred),
  overlay: cpu, video FPS, render FPS, 1-s-window SIM SPEED in simulated
  MHz (over `dbg_clk_cnt`), Pause (stall) checkbox, **Cold reboot** button
  (one tick of `reset_cold`, TB holds 100 cycles), live geometry/reset
  readouts; `--headless N` (default 3) = headless boot smoke (runs past
  the POR hold, counts frames **after** release, ink>0 check, PBM dump of
  the last frame to `out/l1_gui_frame.pbm`); `--run-frames N`, `--scale N`.
  `SDL_MAIN_HANDLED` before `#include <SDL.h>` (same lesson as §1b.5).
- `gui/imgui/` — Dear ImGui copied from `level_neg1/gui/imgui` (level
  independence; no cross-level Makefile reference).
- `Makefile` — `gui` target: `build_gui/obj_dir/Vtb_l1_gui.exe`, Verilator
  `-public --trace`, links `-lSDL2 -lopengl32`.
- `run_l1_gui.bat` — Windows entry: `run_l1_gui.bat [nmos|wdc] [clean]
  [--headless N] [--run-frames N] [--scale N]`.

**Verified (2026-09-05):** `L1_GUI SMOKE PASS` on **nmos and wdc**
(`+cpu=0/1 --headless 3`): POR held 2^22 cycles with the CPU in reset
(bus frozen at $0100, `rst=por=1`), POR released at **294,000,000 ns**
(2^22 × 70 ns — exact), ROM then executes (bus active, ROM vector fetches,
`screen_ink` climbing) and the screen is drawn (frame 1 ink=54,523 px;
frames evolve 67,779 → 60,091 → 257 as the ROM fills, clears and starts
the logo/text phase — `out/l1_gui_frame.pbm` = last frame).  Frame period
~14 ms (measured 308/322/336 ms), 262 lines.  The machine **genuinely
cold-boots in simulation**.

**The "boot stall" was a harness artifact, not a DUT defect (three
overlapping misreads, all now fixed in the C++ harness):**
1. **Verilator stale wire readouts:** the C++ field of a pure alias wire
   (`wire x = y;` read from C++) is refreshed only when its driver's eval
   re-runs; for alias wires it stays at the initial value (0), so
   `dbg_por`/`dbg_rst`/`dbg_flash_div`/`dbg_addr` all read 0/frozen even
   though the underlying regs were correct.  **Rule: read the REG (or a
   REG sampler) from C++, never an alias wire.**  The generated model was
   verified correct (reset-chain NBA in `nba_sequent__TOP__4`, hold-copy
   in `TOP__0`, commit ordering + act/inact/nba convergence loop all
   intact).
2. **`context.time()` is in PICOSECONDS** (timescale 1ns/1ps): ns = /1000,
   not /100.  The old display made 7 ms look like 70 ms.
3. **Early headless exit:** the frame-wait ended on the first N frames,
   which complete *during* the 294 ms POR hold (blank pre-boot).  Frames
   are now counted only after `power_on_reset` deasserts, and the slot
   budget is 120M slots (~4.2 s machine time).

**Remaining:** the user's windowed run (`run_l1_gui.bat nmos`) to visually
confirm the Apple logo + controls (software ink checks cannot judge the
final picture); the §1h tb_l1 fix list above is still pending.

### 1h-GUI-VGA. Temporary A/B: whole `vga_controller` + whole-machine video path (2026-09-05, session 4)

**Purpose:** the user reported the level_1 GUI was much slower than the
whole-machine sim and showed no video.  Root cause found: the GUI loop
was vsync-locked (60 FPS) with 500 slots/frame = 30k slots/s vs the
headless throughput of ~3.5M slots/s (~1/118), so the 294 ms power-on
hold (21M slots) took ~12 minutes of blank screen.  To prove the
window can display the machine's image through the KNOWN-GOOD path, the
level_1 harness now has a TEMPORARY variant that reuses the whole
`rtl/vga_controller.v` (same wiring as `rtl/apple2_top.v`) and samples
its output with the whole-machine `SimVideo::Clock` logic.

**Changes:**
- `tb_l1_gui.sv` — `ifdef L1_VGA` block: `vga_controller` instance
  (controls tied to stock defaults, ioctl tied off) + `dbg_vga_r/g/b/hs/vs/hb/vb`
  REGISTERS latched on every master posedge.  **Lesson (extends the
  stale-wire rule):** Verilator also ALIASES/PRUNES top-level wires that
  only C++ reads — the C++ field of such a wire stays at its initial
  value even when the wire has an RTL reader elsewhere.  Always capture
  what C++ must sample into a TB-level register; read the register from
  C++.
- `gui/main_gui.cpp` — `#ifdef L1_VGA`: `VgaSampler` (ported
  `SimVideo::Clock`: line on HBL fall, pixel on `de=!(hb|vb)`, frame on
  VS fall) writing a 640×240 `0x00RRGGBB` buffer, sampled every 2nd
  master cycle (4 slots) from the `dbg_vga_*` regs; GL texture +
  `ImGui::Image` display (the exact whole-machine display call).
  Both variants now: **no vsync** (`SDL_GL_SetSwapInterval(0)`, like
  `sim_video.cpp`), default `steps_per_frame` 500 → 65,000 (slider 1..
  2,000,000 — matches the whole-machine batchSize default), and a
  POWER-ON HOLD readout (console line on release + overlay with machine
  time during the hold).
- `Makefile` — `gui_vga` target (`build_gui_vga/`, `+define+L1_VGA`
  + `-DL1_VGA`); `clean` removes it.
- `run_l1.sh` / `run_l1_gui.bat` — `gui vga` / `run_l1_gui.bat vga`
  selects the variant.  NOTE: the generated makefile/exe are named after
  the TOP MODULE (`Vtb_l1_gui.mk` / `Vtb_l1_gui.exe`), not the target.

**Verified (2026-09-05):** `L1_GUI VGA SMOKE PASS` nmos AND wdc
(`--headless 3`): POR release at 294 ms, then coherent 640×240 RGB
frames (ink 9,429 → 34,368 → 34,368; `out/l1_gui_vga_frame.ppm` = last
frame, visually a structured hi-res ROM pattern, not noise).  Native
variant re-verified: `L1_GUI SMOKE PASS` both behaviours unchanged
(ink 67,779).  EOL: `run_l1_gui.bat` CRLF (49/49), all other files LF;
eol_guard clean.

**Status:** TEMPORARY diagnostic — remove `gui_vga` + the `ifdef L1_VGA`
blocks once the A/B question is answered (the whole-machine path
renders in the level_1 window, so any remaining native-path blank
window points at the `glDrawPixels` blit / native sampler, not the
machine).

### Resume
```sh
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer
sh unit_tests/level_1/run_l1.sh          # incremental (build is green) + both CPUs
```
Single CPU: `export PATH=/c/msys64/usr/bin:/c/msys64/ucrt64/bin:$PATH &&
./unit_tests/level_1/build/obj_dir/Vtb_l1.exe +cpu=0` — MUST run from the
repo root (ROM paths); outputs in `unit_tests/level_1/out/`.

---

## 2. Current state — `unit_tests/level_neg1/` (all green — self-check/save-restore + INT1/INT2, both CPUs — see §1d/§1f/§1g)

| File | Purpose |
|---|---|
| `unit_tests/level_neg1/tb_cpu.sv` | Config −1 TB: behavioral 64K memory with the 1-`ce`-cycle read delay (latched at `negedge phase_zero`), 2-phase `ce`, savestate bus wired, self-check program (JMP loop + `LDX`/`LDY`/`STA` writes), save/restore tests (CPU-state round-trip, RAM restore, execution-equivalence after restore — the killer test), **INT1/INT2 NMI/IRQ vector-fetch tests** (2026-09-05 session 2, §1f: RAM stubs + non-invasive 1-`ce` fire; currently **failing** on nmos — the bisection result, not a harness regression). Module-scope `reg [15:0] errors` counts failures; prints `CPU_NEG1 PASS/FAIL cpu=<name>` and the error list at the end. |
| `unit_tests/level_neg1/main.cpp` | `--timing` main: runs the event loop until `$finish`, then exit status from `top->rootp->tb_cpu__DOT__errors` (module-scope regs are always public members of the generated root class). 2026-09-05: `--trace` option (VCD to `tb_cpu.vcd` via `context.trace(&vcd, 0)` + `VerilatedVcdC`) and a `CPU_NEG1 SPEED` line (simulated us / wall ms / Verilator throughput in MHz). |
| `unit_tests/level_neg1/Makefile` | `CPU=nmos` (default) / `CPU=wdc` selection, `+define+CPU_WDC` for wdc, `VERILATOR_ROOT` set, two-stage build, plain `-public` in `V_OPT`. `gui` target (2026-09-05) builds `tb_cpu_gui` + imgui/SDL2 sources into `build_<cpu>_gui/`. |
| `unit_tests/level_neg1/rebuild_run.sh` | nmos-only convenience rebuild+run (MSYS2). |
| `unit_tests/level_neg1/run_neg1.bat` | **Windows entry point (2026-09-05):** `run_neg1.bat [nmos\|wdc] [--trace] [clean]` — sets MSYS2 PATH + cwd, calls `run_neg1.sh`. Works from a regular Windows console (stock PATH). |
| `unit_tests/level_neg1/run_neg1.sh` | The actual build+run (env export inside the shell; no external `dirname` — pure-shell `cd` fallback). Args now include `gui`, `--stall-test`, `--run-frames N`. |
| `unit_tests/level_neg1/tb_cpu_gui.sv` | GUI config −1 TB (2026-09-05): like `tb_cpu.sv` but `stall` is C++-driven (checkbox owns it), no self-check/`$finish`; demo DEX loop at $0800 writing a moving pattern to RAM $0200/$0201; extra readouts `ce_count`, `ram0200`, `ram0201`. |
| `unit_tests/level_neg1/gui/main_gui.cpp` | SDL2+imgui GUI main: pause/resume checkbox (writes `stall`), live PC/A/X/Y/S/P/IR/CE/bus/RAM readouts + activity bar, render-FPS counter (wall-clock per presented frame, mirrors `sim_video.cpp`'s `stats_fps`), 1-s-window SIM SPEED line in MHz (GUI analogue of the headless `CPU_NEG1 SPEED` report), resizable window; Space/Esc; `--stall-test` (headless verification of the stall control path), `--run-frames N` (smoke). `SDL_MAIN_HANDLED` required — see §1b.5. |
| `unit_tests/level_neg1/gui/imgui/` | Vendored Dear ImGui v1.92.9b (core + SDL2/OpenGL3 backends + self-contained GL loader). Third-party — do not hand-edit. |
| `unit_tests/level_neg1/run_neg1_gui.bat` | **Windows GUI entry point:** `run_neg1_gui.bat [nmos\|wdc] [clean] [--stall-test] [--run-frames N]` — thin wrapper around `run_neg1.sh ... gui`. Stock-PATH safe. |
| `unit_tests/level_neg1/tb_cpu.vcd` | Latest `--trace` output (~580 KB, 299 signals: `tb_cpu`, `dut` core, `dut.alu`) — open in GTKWave. |
| `unit_tests/run_unit_tests.ps1` | **The runner** (2026-09-05): levels × CPUs, see §1d. |

Build artifacts (delete freely / `make clean`): `build_nmos/`, `build_wdc/`,
`build_nmos_gui/`, `build_wdc_gui/` (current, 2026-09-05), `rebuild_*.log`, `run_out_*.log`, `bus_trace.txt`,
plus scratch files from the 2026-09-04 crash session (`build_dbg*`,
`pubtest.sh`, `_sp_out.txt`) — candidates for cleanup.

Residual build warnings: `WIDTHEXPAND` on the `check()` task args
(8-bit signals / 57-bit replicate fed to a 64-bit formal) — benign width
noise, pre-existing style.

---

## 3. Next steps (cheapest first)

**The INT1/INT2 and T2 threads are CLOSED (§1g) — no core defect found.
The ladder resumes at level_1.**

1. **Resume the ladder: level_1 (VIDEO + KEYBOARD, monochrome)** —
   scope changed from Disk II (user-confirmed); design + first-run data +
   fix list in §1h.  The build is green; the next session executes the
   §1h fix list (frame-anchored captures, V-period measurement, PC-trace
   arming), re-pins T1–T5 thresholds, and drives both CPUs to green.
   Disk II becomes the next level after that.
2. **Optional hardening before level_1 (cheap):** the L0 T2 10-sample
   check asserts all-10 inside the $FCA8-$FFAF span; if a future BIOS-
   variant excursion makes that brittle, loosen to a majority. The boot
   trace block is the instrument to check with.
3. **P3 suite re-check (optional):** `module_tests/cpu_65c02/` P3 directed
   interrupt cases were green before this session; no core RTL changed,
   so no re-run is required — only if the core is later touched.

Earlier roadmap (PLAN.md §4) status: #1-#5 done, #7 (level_0) **done
2026-09-05 session 3** (T1/T2/T3/T4/T5 green both CPUs); #8 (level_1)
next. The old level_neg1 hardening item (functional NMI/IRQ latch
coverage) is the now-passing INT1/INT2 tests.

---

## 4. The config-ladder plan (agreed direction with user)

Value proposition: a ladder of **independently buildable/runnable** configs
so a bug can be bisected to the slice that first reproduces it.

- **config −1 (`level_neg1`, in progress):** isolated CPU + faithful 2-phase
  `ce` + 1-`ce`-cycle-delayed behavioral RAM + savestate bus. No machine,
  no video. Behavioral checks: basic fetch/execute self-check, plus the
  save/restore suite (strongest correctness test — proves capture/apply is
  *complete*, not just present).
- **config 0:** CPU + memory + BIOS, no drives. Open question the user
  raised: how to feed test programs — tape-load simulation vs **direct
  memory injection** (the savestate bus is exactly the "inject a known-good
  state" primitive: write registers + RAM, release stall, run, compare).
- **config 1+:** add peripherals one at a time (increasing complexity) until
  the full machine; each level independently runnable, for bisection.

Related open threads (from this session, decided/parked):
- `module_tests/apple2/` differential harness is now **out of sync** with
  the CPU swap (its Verilog side still lists `rtl/t65/*.v`, and its premise
  — VHDL T65 golden vs Verilog CPU — no longer holds 1:1). User: "this is
  now obsolete, I have enough proof that the swap should work."
- Moving old differential harnesses to `old_vhdl_migration/`: agent
  recommended **yes, as one clean bookkeeping-only step, but not now**
  (all `run_equivalence.ps1` compute `$projectRoot = $PSScriptRoot\..\..`
  and `$referenceRoot = ...\Apple-II_MiSTer_newsdee` — moving the harnesses
  requires updating those path bases). **No move done; user pivoted to the
  unit_tests idea. Decision: leave `module_tests/` untouched for now.**
- `SIM_FAST` stubs only slot peripherals (HDD/Mockingboard/Superserial/
  mouse/NSC) — a B&W "minimal" mode would be a *different axis* (bypassing
  the `vga_controller` color pipeline); not started.

---

## 5. Unverified / outstanding

- ~~OPEN BUG THREAD: NMI/IRQ vector-fetch hang~~ — **RESOLVED 2026-09-05
  session 3 (§1g): test-stub opcode typo (0x87 vs 0x8D), not a core bug.**
  Core interrupt path verified correct ce-by-ce; INT1/INT2 pass both
  cores; L0 T3/T4 pass both cores.
- ~~OPEN ANOMALY: L0 `rom[]` reads back neither original nor patch~~ —
  **RESOLVED 2026-09-05 session 3 (§1g): Verilator 5.050 constant-folds
  constant-index reads of the 16K `rom[]` array to the `$readmemh`
  initial value; variable-index reads (core read path, task readback) are
  correct. Cosmetic only; no functional impact.**
- level_neg1 is **simulation-only** validation of the cores' functional
  behavior + the savestate bus; it does not prove cycle accuracy vs
  hardware, and nothing here touches the Quartus project. (The 2026-09-02
  task's hardware boot test remains the only outstanding FPGA item,
  tracked in the repo-root PROGRESS.md.)
- **level_1 (opened 2026-09-05, §1h):** first run reached T6 and is
  aborted; the known harness fixes are listed in §1h (frame-anchored
  captures, V-period measurement, PC-trace arming, threshold re-pinning).
  No core defect suspected — the T2/T3/T5 anomalies are explained by the
  unaligned capture window. (Bookkeeping done 2026-09-05: PLAN.md
  §3.3/§4/§7/§9 now describe level_1 as video + keyboard; the runner has a
  level_1 section; regeneratable artifacts are gitignored.)
- The 2026-09-05 `tb_cpu.sv`/`tb_l0.sv` changes (sessions 1-3) are
  **uncommitted** (as are the runners); the user has not asked for a
  commit. `unit_tests/level_0/` and `unit_tests/common/` are untracked.
