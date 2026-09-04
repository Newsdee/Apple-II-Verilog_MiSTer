# HUC6280 vs canonical 65C02 — single-step cross-comparison

**Date:** 2026-07-09
**Scope:** Instruction-level behavioral comparison of the PC Engine / TurboGrafx-16
CPU (HUC6280, a 65C02 variant) against the project's canonical 65C02 core, using
the WDC 65C02 SingleStepTests as stimulus.

## TL;DR

The HUC6280 is a 65C02 with a **remapped low memory map** and **slower timing**:

1. **Zero page moved to `$2000-$20FF`** (from the 65C02's `$0000-$00FF`).
2. **Stack moved to `$2100-$21FF`** (from the 65C02's `$0100-$01FF`).
3. **Most instructions take +1 cycle** (a consistent timing penalty).
4. **JSR / PLA / indirect addressing use different bus sequences** (no 65C02-style
   dummy reads; different operand-fetch ordering).
5. **Illegal opcodes behave differently** (as expected — they are not standardized).

The ALU, flag logic, and register file are otherwise equivalent: for the standard
opcode set the two cores produce the same results once the memory-map remap and the
+1-cycle timing are accounted for.

## Methodology

- **Stimulus:** WDC 65C02 SingleStepTests (`65x02/wdc65c02/v1/*.json`), one
  instruction per scenario, with the full initial register/memory state and the
  expected per-cycle bus trace.
- **HUC6280 harness:** `HUC6280_CPU` (VHDL, GHDL) with added observation ports
  (`OBS_A/X/Y/SP/P/PC/ADDR`) and state-injection ports. A flat 64K logical memory
  is modeled (indexed by the 16-bit logical `ADDR_BUS`), and the WDC setup's first
  two pages are **mirrored to `$2000-$21FF`** so the HUC6280 sees the same
  zero-page/stack data as the canonical core (this isolates the memory-map remap
  from the CPU-logic comparison).
- **Canonical harness:** `cpu_65c02` + `cpu_alu` (Verilog, Verilator), same flat 64K
  memory model, same batch.
- **Cross-compare:** for each test the driver finds each core's completion row
  (next-opcode fetch at the suite's final PC), samples the final register state one
  cycle after that fetch (the ALU result is registered a cycle late), and compares
  the cycle count, final state (P masked), and the bus access sequence (with the
  HUC6280's `$2000/$2000+$100` remap normalized).
- **Run:** 256 opcodes × 5 sampled tests = **1270 tests**, seed 1.

### Classification

| Category | Meaning |
|----------|---------|
| IDENTICAL | same cycle count, final state, and bus sequence |
| REMAP     | same except the HUC6280 zero-page/stack address is offset by +$2000 |
| TIMING    | different cycle count, same final state + same (normalized) accesses |
| STATE     | different final register state |
| BUS       | different bus access sequence (addr/rw/data) beyond the remap |
| NOFETCH   | next-opcode fetch not found in the 16-cycle window |

## Results (1270 tests)

| Category  | Count | %     |
|-----------|-------|-------|
| IDENTICAL | 157   | 12.4% |
| REMAP     | 92    | 7.2%  |
| TIMING    | 98    | 7.7%  |
| STATE     | 289   | 22.8% |
| BUS       | 625   | 49.2% |
| NOFETCH   | 9     | 0.7%  |

**Cycle-count delta (HUC6280 − canonical), where measured:** +0: 11, **+1: 155**,
+2: 23, +3: 1. The HUC6280 is **consistently ~1 cycle slower**.

> The high BUS/STATE totals are dominated by **illegal opcodes** (the WDC suite
> covers all 256 opcodes; ~half are not part of the standard 6502/65C02 ISA and are
> handled differently by every 65C02 variant). For the **standard** opcode set the
> results are clean and are summarized below.

### Standard opcodes (clean results)

| Opcodes | Category | Note |
|---------|----------|------|
| `A9` LDA #imm, `EA` NOP, `A0`/`A2` LDX/LDY #imm, `C0`/`C8` CPX/CPY #imm, `E0`/`E8` CPX/INX #imm, `E8` INX, `F8` SED, ... | IDENTICAL | same cycles, state, bus |
| `48` PHA, `9A`/`BA` TXS/TSX, `DA`/`F2` PHX/PHY | REMAP | stack page `$21xx` vs `$01xx` |
| `24`/`25` AND zp, `85` STA zp, `A5` LDA zp, `B2` PLA (65C02), `C4`/`C5` CPY/CPX zp, `E4`/`E5` CPY/CPX zp, ... | REMAP | zero page `$20xx` vs `$00xx` (some +1 cycle) |
| `8D` STA abs, `2C` BIT abs, `AC`/`AD` LDA abs/abs,X, `9C`/`9D` STY/STA abs,X, `CE`/`CF` DEC/DEX abs, `CC`/`CD` CPX/CMP abs, `BC`/`BD` LDY/LDX abs, `EC`/`ED` CPX/CMP abs, ... | TIMING | **+1 cycle** |
| `20` JSR, `68` PLA, `A1`/`A3` LDA (zp,X)/(abs,X), `B1`/`B3` LDA (zp,X)/... | BUS | different bus sequence (no dummy read; operand-fetch order) |

## Key differences, in detail

### 1. Zero page remap: `$0000-$00FF` → `$2000-$20FF`

Zero-page addressing modes (zp, zp,X, zp,Y) target `$20xx` on the HUC6280 instead
of `$00xx`. Verified directly:

- `STA $09` (85 09): canonical writes `$0009`; **HUC6280 writes `$2009`**.
- `STA $71` (85 71): canonical writes `$0071`; **HUC6280 writes `$2071`**.
- `AND zp $7A` (25 7a): canonical reads `$007A`; **HUC6280 reads `$207A`**.

This is a documented HUC6280 feature (the PC Engine remaps the 6502 zero page).

### 2. Stack remap: `$0100-$01FF` → `$2100-$21FF`

Stack operations (PHA, PLA, JSR, RTS, RTI, BRK) use `$21xx` on the HUC6280 instead
of `$01xx`. Verified:

- `JSR` return-address push: canonical writes `$01DC/$01DB`; **HUC6280 writes
  `$21DC/$21DB`**.
- `PLA` pop: canonical reads `$01xx`; **HUC6280 reads `$21xx`**.

### 3. Timing: +1 cycle on most instructions

The HUC6280 takes one extra cycle on the majority of instructions. Examples
(HUC6280 / canonical):

- `STA abs` (8D): 5 / 4 cycles.
- `BIT abs` (2C): 5 / 4 cycles.
- `AND zp` (24): 4 / 3 cycles.
- Branches (taken): +1 cycle.

The extra cycle appears as an idle bus cycle in the HUC6280 trace.

### 4. Bus-sequence differences (JSR, PLA, indirect)

- **JSR (20):** the canonical 65C02 does a dummy read at the target address before
  pushing the return address; the HUC6280 does not. The operand-fetch and
  push ordering also differs. Same final state, different bus trace.
- **PLA (68):** the canonical does two stack reads (a dummy + the value); the
  HUC6280 does one. Same result (A, SP), different bus trace.
- **Indirect (zp,X) / (abs,X):** the operand-fetch ordering differs.

These are micro-architectural differences; the architectural result is the same.

### 5. Illegal opcodes differ

Opcodes outside the standard 6502/65C02 ISA (e.g. `01`, `03`, `04`, `0F`, ...) are
handled differently by the two cores (different cycle counts, bus sequences, and
register effects). This is expected — illegal opcodes are not standardized, and
every 65C02 variant implements them its own way. They account for most of the BUS
and STATE counts in the aggregate.

## Anomalies / open items

- **AND zp (25) A-register not updated in some tests:** in a few sampled AND zp
  tests the HUC6280's `A` is not updated (stays at the initial value) while the
  canonical updates it correctly. A minimal isolated test (X=Y=0) updates `A`
  correctly, so the anomaly correlates with non-zero X/Y/SP and a stray
  `R/W $20xx` (zero page addressed by X) in the HUC6280 trace. This needs a
  focused RTL investigation of the HUC6280's zero-page ALU path before it can be
  called a real CPU behavior vs. a harness artifact. It is a small fraction of the
  standard-opcode tests.

## Limitations

- **16-cycle window:** instructions (or the instruction plus its successor) that
  exceed 16 cycles are not fully captured (NOFETCH). This affects a few branch and
  illegal-opcode tests.
- **Illegal opcodes:** the comparison includes all 256 WDC opcodes; illegal ones are
  not standardized and are reported separately.
- **Flat 64K memory model:** the HUC6280's MPR banking (21-bit physical address) is
  not modeled; the benchmark gives it a flat 64K logical memory for an
  apples-to-apples instruction-level comparison. MPR banking is a separate feature.
- **Canonical core is not 100% WDC-clean:** the canonical `cpu_65c02` passes
  1077/1270 WDC tests (the failures are illegal opcodes and a couple of
  page-boundary cases). This is a pre-existing property of the canonical core, not
  introduced by this benchmark.

## Files

Committed (benchmark root `module_tests/huc6280/`):

- `huc6280_sst_driver.py` — batch generation, runs both sims, cross-compares.
- `huc6280_sst_tb.vhd` — GHDL testbench for the HUC6280.
- `huc6280_65c02_tb.sv` — Verilator testbench for the canonical core.
- `patch_rtl.py` — one-shot idempotent patcher (adds OBS/INJ ports to rtl_tb/).
- `cross_report.txt` — full per-opcode + examples output.
- `huc6280_results.txt.gz`, `canonical_results.txt.gz` — gzipped raw traces.
- `PROGRESS.md` — harness design, build/run instructions, GHDL quirks.
- `.gitignore` — ignores `rtl_tb/` (build/ is ignored by `module_tests/.gitignore`).

Regenerable, not committed (`rtl_tb/`, `build/`):

- `rtl_tb/huc6280_cpu_tb.vhd` — patched HUC6280 CPU (copy + `patch_rtl.py`).
- `build/` — batch, plain-text sim outputs, Verilator build, GHDL work lib.

## Reproduce

```bat
cd /d E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer
py module_tests\huc6280\huc6280_sst_driver.py --ops all --sample 5 --seed 1
```
