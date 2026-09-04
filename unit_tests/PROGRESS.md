# PROGRESS — `unit_tests` ladder / config −1 (isolated CPU + savestate)

**Repo:** `E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer`
**Last updated:** 2026-09-04 — state captured at the crash of session
`01a069db-5741-71fb-a761-3b8262cdc650` (ended mid-debug of the level_neg1
build, right after the repo-root `PROGRESS.md` had been read).

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
4. **Git state:** the CPU swap (§1a) and this `unit_tests/` tree are
   **committed** (2026-09-04: `3c0c08b` = swap [its `verilator/Makefile`
   half landed earlier in the user's `0876f19`], `755ecd6` = unit_tests).
   The repo also holds unrelated pre-existing user changes (see
   `git status`) — leave them untouched.
5. Pick up at §3 step 1. Full history of the crashed session, if needed:
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

---

## 2. Current state — `unit_tests/level_neg1/` (mid-build, the crash point)

New untracked files:

| File | Purpose |
|---|---|
| `unit_tests/level_neg1/tb_cpu.sv` | Config −1 TB: behavioral 64K memory with the 1-`ce`-cycle delay, 2-phase `ce`, savestate bus wired, self-check program (JMP loop + RAM writes), save/restore tests (CPU-state round-trip, RAM restore, execution-equivalence after restore). Module-scope `reg [15:0] errors` counts failures; prints `CPU_NEG1 PASS/FAIL cpu=<name>` at the end. |
| `unit_tests/level_neg1/main.cpp` | `--timing` main: `while (!Verilated::gotFinish()) top->eval();` then exit status from `top->errors()` (line 23). |
| `unit_tests/level_neg1/Makefile` | `CPU=nmos` (default) / `CPU=wdc` selection, `+define+CPU_WDC` for wdc, `VERILATOR_ROOT` set, two-stage build, `V_OPT` includes `-public-flat-rw`. |
| `unit_tests/level_neg1/build_nmos/obj_dir/` | Generated C++ present (fresh 2026-09-04 10:49); **no `Vtb_cpu.exe`** (link step has never succeeded). |

### The failure (exactly where the session ended)
- Stage 1 (Verilator generate): **succeeds**. Only warnings are
  `WIDTHEXPAND` at `tb_cpu.sv:257–264` (`check` task args: 8-bit signals /
  57-bit replicate fed to a 64-bit formal) — benign width noise.
- Stage 2 (g++ compile): **fails**:
  ```
  ../../main.cpp:23:34: error: 'class Vtb_cpu' has no member named 'errors'
  ```
  The generated `Vtb_cpu.h` exposes **no signal accessors at all** — only
  the default API (`eval/final/eventsPending/nextTimeSlot/trace/...`).
  Verified twice: in the crashed session and again now with a fresh
  generation (exit 0, no complaint about the flag, still 0 occurrences of
  `errors` in the header).

### Fix attempts so far
1. `--public-flat-runs` → not a flag in Verilator 5 (generate failed).
2. `-public-flat-rw` (current `V_OPT` in the Makefile) → generate succeeds,
   no warning, **still no accessors**. Mystery: this build's
   `verilator_bin --help | grep -i public` returns *nothing* — the
   flag/name/behavior for this 5.050 MSYS2 build is unconfirmed.

---

## 3. Next steps (cheapest first)

1. **Try plain `-public`** — swap it for `-public-flat-rw` in
   `unit_tests/level_neg1/Makefile` `V_OPT`, `rm -rf build_nmos`, rebuild,
   `grep -c errors build_nmos/obj_dir/Vtb_cpu.h`.
2. If still empty, confirm what this build actually offers:
   `verilator_bin --help | grep -iE 'flat|public'` and the 5.050 docs for
   the correct public-signal flags.
3. **If no flag exposes module-scope regs, drop the C++ accessor entirely:**
   have the TB write the error count to a file (`$fopen`/`$fwrite` →
   `tb_status.txt` in the CWD) and have `main.cpp` read that file after
   `gotFinish()`. File I/O is the robust path (Verilator's `$finish`
   exit-code propagation in this build is unreliable — `errors()` was the
   original plan precisely to avoid it).
4. Rebuild + run (MSYS2 ucrt64 bash; writable TMP set *inside* it — parent
   exports do not propagate, see §1b.1):
   ```sh
   cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/unit_tests/level_neg1
   export PATH=/c/msys64/ucrt64/bin:$PATH
   export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
   rm -rf build_nmos && mingw32-make CPU=nmos
   ./build_nmos/obj_dir/Vtb_cpu.exe    # expect: CPU_NEG1 PASS cpu=nmos6502 ... exit 0
   ```
5. Then the `CPU=wdc` variant (same TB, `+define+CPU_WDC`).
6. Then create the **runner** `unit_tests/run_unit_tests.ps1` (already
   referenced by the Makefile header comment, not yet written), and start
   config 0.

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

- level_neg1 has **never run** — no harness result exists yet. Nothing in
  this session validates CPU behavior beyond the machine-level smoke tests
  (which do not inspect CPU state).
- Hardware/FPGA: none of this touches the Quartus project; no Quartus
  action is implied. (The 2026-09-02 task's hardware boot test remains the
  only outstanding FPGA item, tracked in the repo-root PROGRESS.md.)
- `unit_tests/level_neg1/build_nmos/` is generated output — delete freely
  (`make clean`).
