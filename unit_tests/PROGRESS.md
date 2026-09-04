# PROGRESS — `unit_tests` ladder / config −1 (isolated CPU + savestate)

**Repo:** `E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer`
**Last updated:** 2026-09-05 — level_neg1 is **green for both CPUs**
(nmos6502 + wdc65c02). The runner `run_unit_tests.ps1` is written and
validated (PASS / BUILD FAIL / RUN FAIL paths all exercised). Next: level_0
(separate `level_0/` directory + `unit_tests/common/` extraction).

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
   On 2026-09-05 the level_neg1 files were **modified in place** (TB bug
   fixes, §1d — uncommitted) and `unit_tests/run_unit_tests.ps1` was added
   (untracked). The repo also holds unrelated pre-existing user changes
   (see `git status`) — leave them untouched.
5. Pick up at level_0 (§3). Full history of the 2026-09-04 crashed
   session, if needed:
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

## 2. Current state — `unit_tests/level_neg1/` (green, both CPUs)

| File | Purpose |
|---|---|
| `unit_tests/level_neg1/tb_cpu.sv` | Config −1 TB: behavioral 64K memory with the 1-`ce`-cycle read delay (latched at `negedge phase_zero`), 2-phase `ce`, savestate bus wired, self-check program (JMP loop + `LDX`/`LDY`/`STA` writes), save/restore tests (CPU-state round-trip, RAM restore, execution-equivalence after restore — the killer test). Module-scope `reg [15:0] errors` counts failures; prints `CPU_NEG1 PASS/FAIL cpu=<name>` and the error list at the end. |
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

Roadmap (PLAN.md §4) status: #1 done, #2 done (nmos green), #3 done
(wdc green), #4 done (runner, 2026-09-05), #5 done (killer test is in the
TB and green). Remaining:

1. **level_0** (roadmap #7) — CPU + memory + BIOS, no drives, no slot,
   no video. Separate `level_0/` directory (never reuse level_neg1's). The
   agreed test-program delivery is **direct memory injection via the
   savestate bus** (write registers + RAM, release stall, run, compare),
   not tape-load simulation. First design decision to settle with the
   user: how level_0 gets the machine's memory map —
   (a) a TB-local copy of `apple2.v`'s address decoding + BIOS ROM,
   (b) instantiate `apple2.v` whole with video/drives disabled, or
   (c) extract the memory map from `apple2.v` into its own module (real
   machine-RTL refactor — bigger, but best long-term). Read
   `rtl/apple2.v`'s memory map / reset / BIOS-rom sections first.
2. **`unit_tests/common/` extraction** (roadmap #6) — do it together with
   level_0: shared bits are the 2-phase `ce` generator + 1-`ce`-delay
   behavioral memory (level_neg1's), the `main.cpp` pattern, and the
   savestate-bus wiring.
3. **level_1** (roadmap #8) — add the first peripheral (Disk II is the
   natural candidate; the module_tests golden infrastructure can feed it).
4. Optional hardening for level_neg1 (low priority): an IRQ-during-run
   save/restore test (NMI/IRQ latch coverage — SS_BASE+1 writes happen but
   are not functionally exercised yet).

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

- level_neg1 is **simulation-only** validation of the cores' functional
  behavior + the savestate bus; it does not prove cycle accuracy vs
  hardware, and nothing here touches the Quartus project. (The 2026-09-02
  task's hardware boot test remains the only outstanding FPGA item,
  tracked in the repo-root PROGRESS.md.)
- level_neg1 save/restore does not yet functionally exercise the NMI/IRQ
  latch state (SS_BASE+1) — see §3 step 4.
- The 2026-09-05 `tb_cpu.sv` fixes are **uncommitted** (as is the runner);
  the user has not asked for a commit.
