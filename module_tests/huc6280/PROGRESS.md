# HUC6280 vs canonical 65C02 benchmark — PROGRESS / HANDOVER

> Saved 2026-09-03, mid-session. Read this first when resuming.

## Task

Compare the PC Engine HUC6280 (65C02 **variant**, VHDL, from
`E:\MiSTer\Apple-II_FPGAdev\TurboGrafx16_MiSTer\rtl\HUC6280\`) against the
canonical 65C02 core (`Apple-II-Verilog_MiSTer\rtl\cpu_65c02.sv` +
`cpu_alu.sv`, the core integrated in `apple2.v`). **No parity expected** —
the deliverable is a report of how they differ. Methodology follows the
`module_tests/cpu_65c02` SST campaign (WDC SingleStepTests, per-cycle bus
traces + final state). Work lives in `module_tests/huc6280/`.

## Design (decided, working)

- **Stimulus**: WDC 65C02 suite at `E:\MiSTer\Apple-II_FPGAdev\65x02\wdc65c02\v1\*.json`
  (256 files × 10000 tests). Per-opcode sampling with seed 1.
- **Address filter**: only tests where *all* addresses (initial/final PC,
  cycle addrs, ram addrs) ≤ `$1FFF`. Reason: HUC6280's physical address bus
  is 13 bits + MPR bank select (`A_OUT(20:13) = MPR[ADDR_BUS(15:13)]`,
  `A_OUT(12:0) = ADDR_BUS(12:0)`). With MPR=0 (reset, kept by injection)
  every logical address aliases into `$0000-$1FFF` (identity there).
  Stack `$21xx` aliases to `$01xx` — same physical region as the canonical
  core's `$01xx` stack. Interrupt vectors `$FFFx` alias to `$1FFx`.
- **Two DUTs, one batch file, identical result-line format** (so one parser
  serves both and cross-comparison is per-test):
  - canonical: Verilator TB `huc6280_65c02_tb.sv` (NOT YET WRITTEN — see
    "Next steps"), modeled on `module_tests/cpu_65c02/cpu65_sst_tb_v2.sv`.
  - HUC6280: GHDL TB `huc6280_sst_tb.vhd` (WRITTEN, runs, has a timing bug —
    see "Current bug").
- **State injection**: HUC6280 is VHDL → hierarchical *writes* are illegal.
  Solution: test-adapter copies in `rtl_tb/` (originals untouched) with a
  `TB_INJ` port (like the canonical core's savestate bus):
  - `rtl_tb/huc6280_cpu_tb.vhd` — HUC6280_CPU + TB_INJ/INJ_{A,X,Y,SP,P,PC}
    ports + **OBS_{A,X,Y,SP,P,PC} observation output ports** + TB_INJ
    branches in every register process (A/X/Y, T, SP, P, SH/DH/LH, MPR +
    MPR_LAST reset added, DR, TALT, NMI sync, interrupt latches GOT_INT=0,
    CS=1).
  - `rtl_tb/huc6280_ag_tb.vhd` — AG copy, TB_INJ/INJ_PC (PCr load, AAL/AAH/
    SavedCarry clear).
  - `rtl_tb/alu_tb.vhd` — ALU copy, TB_INJ (SavedC clear).
  - `HUC6280_MC.vhd`, `HUC6280_PKG.vhd`, `AddSubBCD.vhd` used **unmodified**
    from the TurboGrafx16 dir (MI reset value = fetch microcode, which is
    exactly the clean-fetch start we want).
  - Patcher: `build/patch_rtl.py` (idempotent, per-file EOL preserving).
- **Per-test sequence (GHDL TB)**: rst_n=0 ×2 edges → rst_n=1 → 1 edge →
  load INJ_* + tb_inj=1 → 1 edge (latched) → tb_inj=0 → sample row 0 →
  ce=1 → sample rows 1..15 after each posedge. Row c = bus cycle c of the
  instruction, registers = state after c-1 cycles (same convention as
  cpu65_sst_tb_v2.sv). Idle (non-MCYCLE) cycles → sentinel bus token
  `FFFFRFF`. P emitted with R/B forced 1 (`{N,V,1,1,D,I,Z,C}`) so the
  canonical driver's MASK_PB=0x6F applies.
- **Batch format** (fixed width, LF): `<idx:8d> <pc:4h> <sp:2h> <a:2h>
  <x:2h> <y:2h> <p:2h> <ncyc:3d> <npatch:3d> <AAAAVV...>`; result line:
  `R <idx:8d>` + per cycle `<addr4><R|W><data2> <pc4><sp2><a2><x2><y2><p2>`.

## Files created so far

```
module_tests/huc6280/
  huc6280_sst_tb.vhd        GHDL testbench (runs; timing bug, see below)
  rtl_tb/huc6280_cpu_tb.vhd patched HUC6280_CPU (LF EOL, like original)
  rtl_tb/huc6280_ag_tb.vhd  patched HUC6280_AG (CRLF, like original)
  rtl_tb/alu_tb.vhd         patched ALU (CRLF)
  build/patch_rtl.py        one-shot idempotent patcher
  build/sst_batch.txt       3-test smoke batch (currently)
  build/huc6280_results.txt last GHDL run output
  build/ (work-obj05.cf lives at Apple-II-Verilog_MiSTer root — GHDL work lib)
```

## GHDL build/run commands (from Apple-II-Verilog_MiSTer root)

```
G=C:/msys64/ucrt64/bin/ghdl.exe
T=E:/MiSTer/Apple-II_FPGAdev/TurboGrafx16_MiSTer/rtl/HUC6280
H=module_tests/huc6280
rm -f work-obj05.cf
$G -a $T/HUC6280_PKG.vhd $T/AddSubBCD.vhd $T/HUC6280_MC.vhd \
      $H/rtl_tb/alu_tb.vhd $H/rtl_tb/huc6280_ag_tb.vhd \
      $H/rtl_tb/huc6280_cpu_tb.vhd $H/huc6280_sst_tb.vhd
$G -e huc6280_sst_tb
$G -r huc6280_sst_tb
```
TB reads `module_tests/huc6280/build/sst_batch.txt`, writes
`module_tests/huc6280/build/huc6280_results.txt` (cwd = repo root).

## Bugs found & FIXED (smoke test now runs clean, exit=0)

1. **Off-by-one row shift** — ROOT CAUSE: GHDL process resumption order. At a
   posedge time step my TB process resumes *before* the DUT's clocked process,
   so sampling right after `rising_edge(clk)` saw the pre-latch state (row 0 =
   pre-injection, injection appeared at row 1). **FIX: sample at the FALLING
   edge** (`wait until falling_edge(clk)` in the sample loop) — mid-cycle, all
   DUT signals stable regardless of resumption order. Row c then = bus of
   cycle c + registers before cycle c (matches cpu65_sst_tb_v2.sv). VERIFIED:
   registers now correct (test0 PC 0100→0101→0102, P=30; test1 PC 0200→0201;
   test2 PC 0300→0301→0302).
2. **GHDL never exits** — the infinite clock process keeps the event queue
   alive. This GHDL 6.0 build has NO `std.env` (VHDL-2008), NO `--stop-at`, NO
   `--std` flag (VHDL-93 only). **FIX: finite clock process** — reads the batch
   file at t=0 to count tests, toggles `ntests*60+100` half-periods (≈300ns/
   test, well over the ~200ns/test the main loop needs), then holds. When main
   finishes and the clock stops, the event queue drains and GHDL exits.
3. **di always 0xCC** — TWO causes, the second is the real one:
   - (a) `assign_di` compared `a_out(20 downto 15)` (a **6-bit** slice) against
     the **7-char** literal `"0000000"`. (Fix: 6-char literal — but see (b).)
   - (b) **A_OUT only carries the lower 13 bits of the logical address.**
     `A_OUT(12:0) = ADDR_BUS(12:0)`; `A_OUT(20:13) = MPR[ADDR_BUS(15:13)]`.
     With MPR=0 (reset/injected), A_OUT(20:13)=0, so any logical address ≥
     $2000 aliases into the lower 13 bits. Indexing a flat 64K by
     `a_out(14:0)` is therefore WRONG for the full benchmark.
   - **CHosen FIX (in progress): expose the full 16-bit logical address
     `ADDR_BUS` as a new `OBS_ADDR` output port on the patched CPU and index
     the flat 64K memory by it** — matching the WDC model and the canonical
     core (apples-to-apples; MPR banking becomes a documented architectural
     difference, not a memory-model artifact). ADDR_BUS is combinational
     (sensitive to MC/PC/AA/SP/...), stable at the falling edge → safe to
     sample.
   - NOTE: until di is fixed the DUT fetches 0xCC (not the real opcode), so it
     executes the wrong instruction and A/X/Y never update — the register
     trace looks "plausible" (PC advances) but is actually running 0xCC.
     Expect the full trace to become correct once di is fixed.

## VHDL-93 / GHDL-6.0 quirks hit this session (all worked around)
- `file` objects must be declared with the `file` keyword in a process
  declarative region (NOT `variable x : text`).
- Use `readline(f, l)` (93), not `read_line` (2008).
- `time'img` unavailable → `integer'image(now/1 ns)`.
- std_logic_1164 has NO `image` in this build → local `dbgimg(v)` helper
  (in the arch declarative region) for debug reports.
- `report` + string concat works; `write(file, character)` does NOT.
- No `std.env`, no `--std=08`, no `--stop-at` (VHDL-93-only stripped build).
- `bus` is a reserved word; `in '0'..'9'` membership is a parser error.

## FIXED: di / address aliasing (smoke test now fully correct)

### Root causes found & fixed
1. **A_OUT only carries 13 address bits** (`A_OUT(12:0)=ADDR_BUS(12:0)`,
   `A_OUT(20:13)=MPR[ADDR_BUS(15:13)]`). Added `OBS_ADDR` (16-bit
   `ADDR_BUS`) port to the patched CPU; the TB now indexes a flat 64K
   logical memory by `obs_addr` (matches WDC + canonical core). Bus token
   prints the 16-bit logical address.
2. **GHDL mcode bug (the big one): a signal array whose elements are written
   by 2+ processes does NOT settle its init** (stays 'U'). Reproduced in
   isolation (memtest4-11 in build/). Reader-only is fine; a single writer
   process is fine; 2 writer processes (e.g. init process + clocked write-back
   process) corrupts the array. Affects arrays of ANY size (even 64 elem).
   **Workaround: model memory as a read-only base image.** All element writes
   (init loop + per-test patches) live in the MAIN process (the single
   writer); `assign_di` is the only reader; the clocked write-back process
   was REMOVED. This is valid because WDC tests are single-instruction (no
   read-after-write within an instruction). Writes are still captured in the
   bus trace via `do_o`/`we_n`. wr_log/wr_n/restore logic removed.
3. **RES_INT blocked the first instruction's writes.** `RES_INT` starts '1'
   after reset/injection and only drops to '0' after the first instruction
   completes; `WE_N<='0'` requires `RES_INT='0'`. Changed the TB_INJ branch to
   set `RES_INT<='0'` (normal operation) so writes work from the first
   instruction. (Patcher updated too.)

### Smoke test now PASSES (build/sst_batch.txt, 3 tests)
- test0 A9 42 @0100 (LDA #42): c0 R0100(a9) c1 R0101(42) → A=42, PC=0102, P=30 ✓
- test1 EA @0200 (NOP): c0 R0200(ea) → PC=0201 ✓
- test2 8D 0134 @0300 A=55 (STA $3401): c0 R0300(8d) c1 R0301(01) c2 R0302(34)
  c3 idle c4 **W3401(55)** → PC=0303 ✓

### NOTE on patcher completeness
`build/patch_rtl.py` adds the TB_INJ/INJ_* injection branches + AG/ALU ports,
but the CPU's OBS_* / INJ_* / TB_INJ PORT DECLARATIONS and `OBS_ADDR` were
hand-edits (not in the patcher). The patched files in rtl_tb/ are the source of
truth; the patcher skips already-patched files so the hand edits persist. If
regenerating from scratch, re-apply: CPU entity ports (TB_INJ, INJ_A/X/Y/SP/P/
PC, OBS_A/X/Y/SP/P/PC/ADDR), the OBS assignments, and RES_INT<='0' in the
TB_INJ branch.

## (superseded) The one remaining bug to fix NOW: di / address aliasing

### DONE (this session): CPU half
- `rtl_tb/huc6280_cpu_tb.vhd`: added `OBS_ADDR : out std_logic_vector(15
  downto 0);` right after the `OBS_PC` port, and `OBS_ADDR <= ADDR_BUS;` right
  after `OBS_PC <= PC;`. Confirmed `OBS_ADDR` is the full 16-bit logical
  address (ADDR_BUS is a combinational mux on MC.ADDR_BUS, stable at the
  falling edge). CPU copy re-saves fine (LF eol). NOTE: `build/patch_rtl.py`
  does NOT emit OBS_ADDR — it was a hand edit; the patcher skips already
  patched files so it is preserved, but mirror it into the patcher later for
  reproducibility.

### REMAINING (do this next, exact sites in huc6280_sst_tb.vhd):
Line numbers from the current file (grep-verified):
- L78 `signal a_out` / L89 `signal obs_pc` → add
  `signal obs_addr : std_logic_vector(15 downto 0);` near L89.
- L175-176 DUT port map `OBS_SP => obs_sp, OBS_P => obs_p, OBS_PC => obs_pc`
  → append `, OBS_ADDR => obs_addr`.
- L205-213 `assign_di` process → index by obs_addr, drop the 6-vs-7 bank
  sentinel branch:
    ```
    assign_di : process (obs_addr, mem, rst_n)
    begin
        if rst_n = '0' then di <= (others => '0');
        else di <= mem(to_integer(unsigned(obs_addr)));
        end if;
    end process assign_di;
    ```
- L219-224 write process → `mem(to_integer(unsigned(obs_addr))) <= do_o;`
  and `wr_log(wr_n) <= obs_addr;` (wr_log is already 16-bit; restore at L351
  `mem(to_integer(unsigned(wr_log(i)))) <= x"EE";` stays valid).
- L324 bus token → `bstok(1 to 4) := hstr16(obs_addr);` (was
  `hstr16('0' & a_out(14 downto 0))`).
- `a_out` signal may become unused → keep it (still mapped) or drop the map;
  leaving it is harmless.

Then: rebuild (ghdl -a/-e/-r, commands above) and rerun the 3-test smoke
batch. EXPECT: test0 A9 42 @0100 → c0 R0100(d=A9) c1 R0101(d=42), final A=42
PC=0102 P=30; test1 EA @0200 → c0 R0200, PC=0201; test2 8D 0134 @0300 A=55 →
c0 R0300 c1 R0301(01) c2 R0302(34) c3 W0134(55), PC=0303. Remove/gate the DBG
`report` lines once green. Then proceed to the canonical Verilator TB
(next steps #2 below).

Smoke expectations once fixed (batch currently in build/sst_batch.txt):
- test 0 `A9 42 @0100`: c0 R 0100, c1 R 0101 d=42, final A=42, PC=0102, P=30.
- test 1 `EA @0200`: c0 R 0200, final PC=0201 (1 cycle).
- test 2 `8D 0134 @0300, A=55`: c0 R 0300, c1 R 0301 (01), c2 R 0302 (34),
  c3 W 0134 (55), final PC=0303. (Batch says ncyc=3 — STA abs is 4 cycles;
  ncyc is driver-side only, harmless.)

## Next steps (in order)

1. ~~Fix di / address aliasing~~ **DONE** — GHDL harness passes the 3-test smoke
   batch (see "FIXED" section above).
2. ~~Write huc6280_65c02_tb.sv~~ **DONE** — see below.

## DONE: canonical Verilator TB + both harnesses verified end-to-end

- `huc6280_65c02_tb.sv` written (modeled on cpu65_sst_tb_v2.sv, but drives the
  v1 core `rtl/cpu_65c02.sv` whose working-register set is smaller: no
  nmi_sync/rst_seq/int_i_mask/nop1_hold/irq_l1/irq_l2). Injects reg_pc/s/a/x/y,
  fl_*, ir/dl/ea/state/int_active/int_is_nmi/nmi_pending/nmi_last/nop8_cnt/
  idx_carry/idx_reg + outputs. nmi_last=1 (no spurious edge). Writes committed
  to mem (Verilator mem is fine) + wr_log restore.
- **Build (PowerShell, NOT the bash tool — see invocation quirk below):**
  ```
  $env:PATH='C:\msys64\ucrt64\bin;'+$env:PATH
  $env:VERILATOR_ROOT='C:/msys64/ucrt64/share/verilator'
  $env:MAKE='C:\msys64\ucrt64\bin\mingw32-make.exe'
  $env:SHELL='C:\msys64\usr\bin\sh.exe'
  & 'C:\msys64\ucrt64\bin\verilator_bin.exe' --binary --timing -Wno-fatal \
     --top-module huc6280_65c02_tb -Irtl rtl/cpu_65c02.sv rtl/cpu_alu.sv \
     module_tests/huc6280/huc6280_65c02_tb.sv \
     --Mdir module_tests/huc6280/build/sst_verilog -o huc6280_65c02_tb
  ```
  (Needs `-Irtl` attached form, `--timing`, VERILATOR_ROOT set; core instantiates
  cpu_alu so both files are required.)
- **INVOCATION QUIRK (important):** running the .exe directly from the bash tool
  or `powershell -Command "& exe"` crashes with 0xC0000139 (even the
  known-good cpu_65c02 v2 binary does). It runs fine via **Python subprocess**
  (the way sst_driver.py does it): `subprocess.run([bin, '+TESTS=..', '+OUT=..'],
  env={PATH: C:\msys64\ucrt64\bin prepended}, cwd=repo_root)`. So the driver MUST
  launch both sims via Python subprocess.
- **BOTH harnesses verified on the 3-test smoke batch.** Result files:
  - GHDL: build/huc6280_results.txt
  - canonical: build/canonical_results.txt
- **FIRST REAL DIFFERENCE FOUND (cross-compare, test2 STA abs $3401):**
  - canonical 65C02: c0 R0300(8d) c1 R0301(01) c2 R0302(34) **c3 W3401(55)** →
    4 cycles, PC=0303.
  - HUC6280: c0 R0300(8d) c1 R0301(01) c2 R0302(34) **c3 idle** **c4 W3401(55)**
    → 5 cycles (extra idle cycle before the write), PC=0303.
  - LDA #imm and NOP are identical. So the per-opcode cycle-count + bus-sequence
    cross-compare is meaningful and already productive.

## (was next) Write `huc6280_65c02_tb.sv` — superseded, see DONE above.

### (reference) original key points for the Verilator TB:
   - DUT `cpu_65c02` from `rtl/cpu_65c02.sv` (+ `rtl/cpu_alu.sv` needed).
   - Never reset; power-on (all-zero) = S_FETCH clean pipeline (same trick
     as cpu65_sst_tb_v2.sv). Inject at negedge with stall=1: reg_pc, reg_s,
     reg_a, reg_x, reg_y, fl_n/v/d/i/z/c, ir=0, dl=0, ea=0, state=0,
     int_active=0, nmi_pending=0, nmi_last=0, idx_carry=0, nop8_cnt=0,
     idx_reg=0, addr=t_pc, we/sync/vector_pull/in_wai/in_stp=0, dout=0.
     (This core has NO nmi_sync/rst_seq/int_i_mask/nop1_hold/irq_l1/irq_l2 —
     those are v2-only; don't inject them.)
   - Ports: ce=1, ce_n=0, reset=0, irq_n=1, nmi_n=1, rdy=1, stp_nop=1,
     ss_addr=0, ss_wdata=0, ss_wren=0.
   - 64K mem sentinel 0xEE, wr_log restore, W=16, same batch/result format
     (result file `build/canonical_results.txt`).
   - Build: `C:/msys64/ucrt64/bin/verilator_bin.exe --binary -j4 -Wno-fatal
     --top-module huc6280_65c02_tb -I rtl rtl/cpu_65c02.sv rtl/cpu_alu.sv
     module_tests/huc6280/huc6280_65c02_tb.sv -Mdir
     module_tests/huc6280/build/sst_verilog -o huc6280_65c02_tb` (run from
     repo root; +TESTS=/+OUT= plusargs like the v2 TB).
   - Run both DUTs on the 3-test smoke batch first; cross-check that the
     canonical results match the smoke expectations exactly.
3. **NOW: Write `huc6280_sst_driver.py`** (see design below). Then #4, #5.
   - load suite JSONs; filter (all addrs ≤ 0x1FFF, ncyc ≤ 16, patch ≤ 64);
     sample N/opcode (default ~20, seed 1) — expect a few thousand tests.
   - write batch; run Verilator bin; run GHDL bin; parse both (copy
     parse_results/compare/completion_classify from
     module_tests/cpu_65c02/sst_driver.py — note P bit 5: suite always has
     it 1; canonical hardwires it; HUC6280 bit5 = T flag (extra cycle on
     memory ops) → **clear bit 5 in the injected P for the HUC6280 TB**
     (do it in the TB: `inj_p(5) <= '0'`), document in report; optionally a
     second HUC6280 run with T=1 to document the extra-cycle behavior.
   - suite-compare per core (for HUC6280 skip/relax the illegal-access
     check: vector reads $FFFx alias to $1FFx, stack $21xx→$01xx);
   - cross-core compare per test: completion row (fetch-pair heuristic at
     suite final PC) per core, final state at each core's completion row,
     cycle-count delta, bus access-sequence diff (addr/rw/data, idle
     sentinel excluded); aggregate per opcode + examples.
   - Python: use `py` (3.13.14) — bare `python` is permission-denied.
4. `run_huc6280_benchmark.ps1` orchestrator (GHDL build, Verilator build,
   driver).
5. Full sweep → write `REPORT.md`: structural differences (MPR 13-bit
   physical addr + bank, 4 interrupt sources NMI/IRQ1/IRQ2/IRQT with
   vectors FFFC/D, FFFA/B, FFF8/9, FFF6/7 vs 65C02's FFF2/3+FFFC/D, 0x00=BRK
   vs NOP, 0xD4=SLEEP/CS vs NOP, 0x53/0x73=TAMi/TAMo MPR ops vs SLO, T-flag
   extra cycle on memory ops, CS slow/full clock divider in the outer
   HUC6280 wrapper (6 vs 24 master clocks), VDC wait states, BCD via
   AddSubBCD.vhd, stack page $21 vs $01, WAIT_N handling) + measured
   per-opcode differences from the sweep.

## Environment quirks learned (this machine)

- **GHDL 6.0.0 (mcode JIT) at C:\msys64\ucrt64\bin\ghdl.exe has real bugs**:
  - hierarchical references rejected outright ("component instance cannot be
    be selected by name") even through entity instances → use observation
    ports instead;
  - `write(file, character)` overload missing → build strings, write strings;
  - `x in '0'..'9'` membership test is a parser error → use `>= and <=`;
  - `bus` is a reserved word (can't name a variable/record field `bus`).
- `py` = Python 3.13.14 (works); `python`/`python3` in PATH are blocked
  WindowsApps stubs.
- Verilator 5.050 at C:\msys64\ucrt64\bin\verilator_bin.exe.
- EOLs: HUC6280_CPU.vhd original = LF; HUC6280_AG/ALU originals = CRLF;
  patched copies preserve per-file EOL (patcher handles it).
- The existing WDC campaign artifacts for reference:
  `module_tests/cpu_65c02/{FINAL_VERDICT.md, sst_driver.py,
  cpu65_sst_tb_v2.sv, wdc_vs_6502_analysis.md}`.
- HUC6280 outer wrapper (HUC6280.vhd) clocking, for the report: CPU runs at
  CLK/6 when CS=1 (full speed) or CLK/24 when CS=0 (slow, set by 0xD4
  SLEEP); IO/PSG/Timer at CLK/6; WAIT_N stalls the CE divider; VDC/VCE
  accesses force RDY low (wait states); IO decode: VDC $0000-03FF, VCE
  $0400-07FF, PSG $0800-0BFF, TMR $0C00-0FFF, IOP $1000-13FF, INT
  $1400-17FF, RAM $F800-FBFF (CER_N). The benchmark tests the CPU core
  directly (CE continuous, RDY=1), i.e. full-speed mode.

## RTL facts worth remembering (from reading the HUC6280 source)

- Microcode: HUC6280_MC.vhd (574KB generated tables M_TAB1/2/3, indexed
  IR&STATE(2:0), STATE(4:3) selects table; STATE=0 always = fetch MI with
  PC++ and MEM_CYCLE).
- Interrupts: NMI edge-synced (NMI_SYNC/NMI_ACTIVE), IRQ1/IRQ2/IRQT
  level, all masked by I flag except NMI; BRK vector FFF6/7 (shared with
  IRQ2), IRQT FFFA/B, IRQ1 FFF8/9, NMI FFFC/D.
- 0x00 = BRK (BRK_INT when IR=00); 0xD4 (IR(6:0)="1010100", IR(7)=1) sets
  CS=1 (sleep/slow); 0x54 (CLI) sets CS=0.
- T flag (P bit 5): set by some ops (LOAD_P "110"), auto-cleared on next
  fetch; when T=1 all MEM_INST opcodes (long list in HUC6280_CPU.vhd) take
  one extra cycle (STATE jumps to "01000").
- TAMi (0x53): MPR(i)<=A for each T(i)=1, on last cycle; TAMo (0x73):
  A<=MPR(T) (via MPR_OUT / MPR_LAST).
- Stack: $21xx (ADDR_BUS "010"); vectors via ADDR_BUS "100" (upper 12 bits
  = FFF).
- VDC access: ADDR_BUS "101" → A_OUT(20:13)=FF (physical $FF8000-ish),
  A_OUT(12:0) = 0000_0000_VDCNUM_00_xx.
- AG (HUC6280_AG.vhd): AAL/AAH + SavedCarry carry-save effective address
  (page-cross carry saved for abs,X / (zp),Y fixups); PC_CTRL 001 = PC++
  (skipped while GOT_INT).
- ALU (HUC6280_ALU.vhd + AddSubBCD.vhd): BCD add/sub with own carry/VO
  logic; INC/DEC MSB uses SavedC (hence the TB clears it on injection).

## STATUS: BENCHMARK COMPLETE (2026-07-09)

The full cross-comparison benchmark is done. See **REPORT.md** for the findings.

### What was built (all working end-to-end)
- `huc6280_sst_tb.vhd` — GHDL testbench for the HUC6280 (flat 64K logical memory
  indexed by the 16-bit `ADDR_BUS`; first two WDC pages mirrored to `$2000-$21FF`
  to match the HUC6280 zero-page/stack remap; falling-edge sampling; finite clock).
- `huc6280_65c02_tb.sv` — Verilator testbench for the canonical `cpu_65c02`.
- `huc6280_sst_driver.py` — loads WDC tests, writes one batch, runs BOTH sims via
  subprocess, cross-compares (cycle count, final state one cycle after the
  next-fetch, remap-normalized bus sequence), aggregates per opcode.
- `rtl_tb/huc6280_cpu_tb.vhd` — patched HUC6280 CPU (OBS_* + INJ_* ports).
- `build/cross_report.txt` — full per-opcode + examples output.

### Final results (256 opcodes × 5 tests = 1270, seed 1)
IDENTICAL 12.4% / REMAP 7.2% / TIMING 7.7% / STATE 22.8% / BUS 49.2% / NOFETCH 0.7%.
Cycle delta: +1 (155), +2 (23), +3 (1), +0 (11). High BUS/STATE = mostly illegal
opcodes. Standard opcodes are clean: zero-page remap ($20xx), stack remap ($21xx),
+1 cycle on most, JSR/PLA/indirect bus-sequence differences.

### Key driver fixes made this session
- idx parsed as **decimal** (`ival`), not hex (`hval`) — the batch writes `%08d`.
- Mirror offset `addr + 8192` ($2000), not `addr + 4096`.
- `norm_addr` / `bus_remap_match`: an HUC6280 access matches the canonical if equal
  OR `+$2000` (zero-page/stack remap), not a blanket page map.
- Final state sampled at `completion_row + 1` (ALU result registers a cycle late).
- `completion_row` fallback: first non-idle read of `fpc` (handles JSR-next cases
  where the fetch pair is broken by the HUC6280's JSR bus order).

### Open item
- AND zp (25): in a few tests the HUC6280 `A` is not updated (stays at initial
  value) while the canonical updates it; correlates with non-zero X/Y/SP and a
  stray `R/W $20xx`. Minimal isolated test (X=Y=0) works. Needs a focused RTL
  look at the HUC6280 zero-page ALU path before calling it real vs. harness.
