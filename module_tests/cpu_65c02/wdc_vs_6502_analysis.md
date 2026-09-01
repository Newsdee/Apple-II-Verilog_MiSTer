# WDC 65C02 vs original MOS 6502 — attribution of the SST divergences

Date: 2026-09-01 (continuation of the 65c02 three-way comparison)
Updated: 2026-09-02 — policy (a) adopted (W65C02S/WDC reference authoritative
for bus conventions); Category C resolved by the Option C M_ABX change;
Category G re-attributed from "D=1 BCD" to the **I-flag** convention; new
Category I (illegal-opcode decode mismatch).
Question answered: *Where the new core / golden R65Cx2 disagree with the WDC
SingleStepTests reference, is it the WDC suite that diverges from original MOS
6502 behavior? Would a faithful-6502 core (e.g. T65) track the 6502 suite more
closely?*

## Method

For every opcode in the three-way divergence set (`build/three_way_report.txt`,
109 opcodes), the expected bus pattern was taken from **both** SST reference
suites:

- `E:/MiSTer/Apple-II_FPGAdev/65x02/wdc65c02/v1/*.json` (WDC 65C02 model)
- `E:/MiSTer/Apple-II_FPGAdev/65x02/6502/v1/*.json` (original MOS 6502 model)

and compared against the observed R/W patterns of both cores from the clean
sweeps (`build/sweep_wdc_results.txt`, `build/sweep_wdc_golden_results.txt`).

Scripts: `build/four_way.py` (suite-vs-suite-vs-cores pattern table →
`build/four_way_report.txt`), `build/addr_model.py` (cycle-by-cycle address
decoding of reference tests), `build/cross_check.py` (per-opcode, per-page-cross
subgroup pass rates).

**Headline: 79 of the 109 divergent opcodes have a different expected bus
pattern in the WDC suite than in the MOS 6502 suite.** The remaining 30 agree
between suites; their failures are core-vs-reference issues (see category D).

## Harness fact that had to be fixed first

`wdc65c02/v1/cb.json` (WAI) and `db.json` (STP) ship **empty** → the batch has
12700 tests, not 12800. Verified empirically against *both* result files by
matching each opcode's sample[0] PC (0 mismatches):

```
opcode 00..ca : base index = op*50
cb            : absent
opcode cc..da : base index = op*50 - 50
db            : absent
opcode dc..ff : base index = op*50 - 100
```

Any per-index analysis must use this piecewise mapping (earlier uniform-shift
assumptions produced garbage for the cc..da band). The three-way category table
itself is unaffected — it uses the driver's own per-opcode summary lines.

## Category A — RMW bus protocol (22 GOLDEN-ONLY-FAIL opcodes)

`04 0c 14 1c 06 0e 16 26 2e 36 46 4e 56 66 6e 76 c6 ce d6 e6 ee f6`
(TSB/TRB, ASL/ROL/LSR/ROR, INC/DEC in zp/abs/zp,x)

| source | zp pattern | abs pattern |
|---|---|---|
| WDC suite | `RRRRW` (read, re-read EA, write new) | `RRRRRW` |
| MOS 6502 suite | `RRRWW` (read EA, **write old**, **write new**) | `RRRRWW` |
| new core | follows WDC → passes | |
| golden R65Cx2 | follows MOS → fails vs WDC | |

**Attribution: genuine WDC-vs-MOS divergence.** The original-6502 reference
models the classic double-write RMW cycle; WDC models a re-read. **A faithful
6502 such as T65 would agree with the golden core here, not the new core.**
Final memory state is identical in all variants — pure bus-protocol difference.

## Category B — unassigned-opcode conventions (20 GOLDEN-ONLY-FAIL opcodes)

`07 17 27 37 47 57 67 77 87 97 a7 b7 c7 d7 e7 f7` and `44 54 d4 f4`

Both suites model these as ZP-touching operations (neither suite treats them as
implied NOPs), but the exact WDC vs MOS patterns differ (e.g. `$87`: WDC
`RRRRW`, MOS `RRW`; `$x4` column: both `RRR`/`RRRR`). Golden R65Cx2's table
lists them as implied NOPs (`// 87 NOP ----- 65C02`) → it matches **neither**
suite. New core follows the WDC convention → passes.

**Attribution: vendor/reference conventions for undocumented opcodes.** Not a
functional bug in either core; only matters to software using undocumented
opcodes. T65's choice would follow whatever its own decode table says.

## Category C — indexed 16-bit page-cross (BOTH-FAIL, abs,X / abs,Y)

`1d 3d 5d 7d bc bd` (abs,X), `19 39 59 79 b9 d9 f9 be` (abs,Y)

Per-subgroup pass rates (new core = golden in every group):

- page-cross tests: **0/N pass**
- no-cross tests: **N/N pass** (except the SBC family, see open items)

Cycle-by-cycle decode of the cross case ($BD example, b1=C4 b2=5D X=FF):

```
WDC suite : fetch, R b1, R b2, R b2 (re-read pc+2),   R ea_carry
MOS suite : fetch, R b1, R b2, R ea_nocarry,          R ea_carry
both cores: fetch, R b1, R b2, R ea_nocarry,          R ea_carry
```

**Attribution: WDC diverges from the original 6502; both cores already match
the MOS reference** (dummy read of the non-carry EA during the penalty cycle).
Exactly the situation the user predicted: a faithful-6502 core tracks the
cores here, and it is the WDC suite that is the outlier.

### Resolution (2026-09-02, policy (a))

The project adopted **policy (a): the W65C02S/WDC reference model is
authoritative for bus conventions** (see `CPU_COMPARISON_RECOMMENDATIONS.md`
decision policy). The new core was therefore changed to follow the WDC
convention ("Option C"): in `rtl/new_cpu/cpu_65c02.sv`, `S_ABS_HI` now latches
`addr <= reg_pc` (a re-read of b2 at `pc+2`) for the M_ABX forced-fix cycle
(stores, INC/DEC abs,X — unconditional) and the M_ABX cross-penalty cycle
(all other M_ABX accesses — only on page cross). M_ABY keeps the no-carry-EA
dummy (unchanged). The `"both cores"` line in the decode example above is now
stale for the new core: it dummies at `pc+2`, matching the WDC suite; golden
R65Cx2 still dummies at the no-carry EA.

Full WDC re-sweep (`build/sweep_wdc_abxfix_results.txt`, 12700 tests, seed 1):
**10302 → 10798 pass, zero regressions** (per-test gate:
`build/regress_check.py`). Changed opcodes, all M_ABX:

| opcode | pre | post | class |
|---|---|---|---|
| `1d 3d 5d bc bd dd` | 22/21/27/24/26/23 of 50 | **50/50** | reads |
| `1e 3e 5e 7e` | 27/25/32/26 of 50 | **50/50** | shift RMW |
| `9d 9e` | 0/50 | **50/50** | stores |
| `de fe` | 0/50 | **50/50** | INC/DEC RMW |
| `3c` (JMP abs,X) | 27/50 | **50/50** | indirect jump (routes through M_ABX) |
| `7d fd` | 10/18 of 50 | 23/31 of 50 | ADC/SBC — remainder is Category G (I flag) |

No opcode outside the M_ABX family changed at all.

## Category D — the SST indirect-indexed-row convention (BOTH-FAIL)

This is a **shared quirk of the SST reference generator**, present in *both*
the wdc65c02 and 6502 suites, not a WDC-specific divergence:

1. **$B1 "LDA (zp),X" is modeled as LDA (zp),Y-style** — verified 50/50 in
   both suites: the lo pointer byte is read from `zp` itself (not `(zp+X) mod
   256`), EA = `{mem[zp+1], mem[zp]} + Y`, with a dummy re-read of `pc+1` on
   Y page-cross. R65Cx2's own table encodes the same convention:
   `// B1 LDA (zp),y` (`readIndY`). The new core decodes $B1 into its `M_IZY`
   mode, i.e. it implements the same convention. Both cores therefore fail
   only on the Y-cross dummy-cycle address (suite dummies at `pc+1`, cores
   dummy at EA) → ~25/50 pass.
2. **$91 "STA (zp),X" is also (zp),Y-style** (50/50 in WDC; MOS presumably the
   same) and *always* carries the `pc+1` re-read dummy → both cores 0/50.
3. **$D1/$F1 are modeled as read-only (zp),Y-style operations** — 50/50 of
   both suites' $D1 tests end in a READ at `{mem[zp+1], mem[zp]} + Y` with no
   store cycle at all. Both cores fail accordingly.

**Attribution: SST generator table convention shared by all its 65xx suites.**
Textbook 6502 semantics differ, but *both reference models agree with each
other* here, so a T65-vs-SST comparison would show the same "failures" for any
core implementing textbook (zp),X — including T65. This is not evidence about
WDC vs MOS at all.

## Category E — $5E/$7E WDC-specific quirk (BOTH-FAIL-diff-count)

WDC's `$5E` is **not** ADC (zp),Y. Decoded from the JSON (8/8 tests): it
performs an LSR-like RMW at a hybrid effective address:

```
EA = { b2 + carry(zp+X),  mem[(zp+X) mod 256] }     (no Y at all)
mem' = mem >> 1 ;  C = old bit0 ;  A unchanged
cycles: fetch, R zp byte, R pc+2 byte, R EA, R EA, W EA>>1
```

No real 65xx CPU has this mode; it is a WDC-reference-specific modeling of an
otherwise-unassigned-looking entry. The **new core implements exactly this**
(traces match cycle-for-cycle on passing tests, e.g. `5e 2b 72`: fetch, R zp,
R pc+2, R 72DF, R 72DF, W 45 = 8A>>1) — its decode path routes $5E through the
WDC-convention behavior rather than plain ADC (zp),Y. The MOS suite models
$5E differently again (`RRRRRWW`). Golden R65Cx2 implements plain ADC (zp),Y.

## Category G — ADC/SBC I-flag extra-cycle convention (re-attributed 2026-09-02)

The WDC suite models **every ADC/SBC with an extra read cycle when I=1**
(P bit 3 set) that the MOS-lineage suites do not have. The earlier "D=1 BCD"
label was wrong: the WDC SST generator **pins D per opcode family** — every
ADC-family test (`69 65 6d 7d 79 71` …) is generated with D=0 and every
SBC-family test (`e9 e5 ed fd f9 f1` …) with D=1 (verified: 10000/10000 in
each file), so "D=1 tests" and "I=1 tests" could not be told apart at a
coarse level. A per-bit correlation over 2000 sampled `7d` tests is exact:
extra read ⟺ P[3]=1 (1017/1017 vs 0/976; no other bit or feature correlates).

Exact location of the extra read, by mode (WDC suite, I=1):

| mode | WDC suite cycles (I=1) | extra read |
|---|---|---|
| immediate `69` | 3 | fixed address **$007F** |
| immediate `e9` | 3 | fixed address **$0000** |
| zp `65`/`e5` | 4 | EA re-read |
| abs `6d`/`ed` | 5 | EA re-read |
| abs,X `7d`/`fd`, abs,Y `79`/`f9` | base + cross + 1 | EA re-read (on top of the b2 re-read penalty) |

Lineage evidence: the pattern is present in **all three WDC-lineage suites**
(wdc65c02, rockwell65c02, synertek65c02 — same ~50/50 I=1 split in each) and
absent from both MOS-lineage suites (6502, nes6502: ADC imm = 2 cycles and
ADC abs,X = 4/5 cycles regardless of I). No real-silicon documentation
supports an I-dependent ADC/SBC cycle count; the fixed `$007F`/`$0000`
immediate-mode addresses are a tell-tale reference-model artifact.

Earlier evidence that remains valid (`build/bcd_matrix.py`, fresh `+DBG=0`
runs in `build/bcd_dbg*.txt`):

- **Golden R65Cx2 has no BCD extra cycle in any mode.** The decimal
  correction is purely combinational in its ALU (9-bit sum + nibble
  corrections); the per-cycle FSM dump for `69` D=1 shows fetch → operand →
  plain final fetch, `procIrq=0`, no stack traffic. (The old raw trace in
  `sst_progress.md` showing SP decrement + `$FFFA` vector fetch was an
  artifact of the pre-fix TB — synthetic BRK from `calcInterrupt` before the
  `nmiReg`/`irqReg`/`processIrq` injection existed.)
- **The new core's committed A/P/S on D=1 tests is identical to golden's**
  (checked across imm/abs/abs,X/zp/indirect samples) — no functional BCD
  bug, only the bus-cycle difference.
- The new core had an `S_DEC_FIX` state inserting a dummy read at pc+2
  (immediate/zp/indirect) or pc+3 (abs/indexed) for D=1 ADC/SBC — matching
  neither the suite's addresses nor golden. **Removed 2026-09-02** from
  `rtl/new_cpu/cpu_65c02.sv` (two transitions + state body). After the fix,
  a full re-sweep (`build/sweep_wdc_nobcdfix_results.txt`) showed **zero
  per-test pass/fail divergence between new core and golden on all 18 BCD
  opcodes** and zero changes to any non-BCD test.

**Attribution: WDC-suite reference-model convention, not silicon behavior.**
Real 65xx decimal adjust is internal to the ALU on the result cycle; golden
and the MOS suites agree. **Policy decision (2026-09-02, policy (a)): this
convention is documented but NOT emulated** — no hardware evidence, absent
from the MOS lineage, and the immediate-mode fixed addresses show it is a
model artifact rather than datasheet behavior. The cores therefore still fail
the I=1 half of every ADC/SBC opcode in the WDC suite (e.g. `7d` 23/50,
`fd` 31/50 post-Option-C) while passing all I=0 tests.

(The `$DE` 0/50 in the old open-items list was *not* this: `$DE` is DEC
abs,X — resolved by the Option C change, Category C.)

## Category H — $F1 = SBC (zp),y: the two independent dummy conditions
(root-caused 2026-09-02)

The old "cyc5=16 / cyc6=23" note was a partial view; the full split of the 50
sampled F1 tests is **cyc5=16, cyc6=23, cyc7=11**, produced by two
*independent* +1-cycle conditions (scripts: `build/f1_split.py`,
`build/f1_groups.py`, `build/f1_cond.py`, `build/f1_sbc.py`,
`build/f1_decomp.py`):

| condition | extra cycle | verified |
|---|---|---|
| Y page-cross of EA = {mem[zp+1], mem[zp]} + Y | re-read of **pc+1** | 50/50 exact |
| initial D=1 | re-read of **EA** (the Category G BCD convention) | 50/50 exact |

The WDC suite models **$F1 as a 2-byte `SBC (zp),y`**: fetch, pc+1 (zero-page
pointer byte), lo@zp, hi@zp+1, [pc+1 dummy on Y-cross], EA read, [EA re-read
on D=1]; A = A − mem[EA] − ~C (BCD-corrected when D=1); final pc = pc+2. This
is exactly R65Cx2's own decode-table entry (`// F1 SBC (zp),y`,
`readIndY`/`aluSbc`) and the new core's `M_IZY` routing — both cores implement
the same model.

Per-group failure decomposition (new core = golden, identical in every group):

| D | Y-cross | n | result |
|---|---|---|---|
| 0 | no | 16 | **PASS** |
| 0 | yes | 10 | cyc4 addr: suite dummies at pc+1, cores at no-carry EA (same pattern as $B1, Category D) |
| 1 | no | 13 | cyc5 addr: missing D=1 EA re-read (core instead fetches next opcode) + final-pc off by 1 (timing consequence of the same missing cycle) |
| 1 | yes | 11 | cyc4 + cyc6 addr mismatches + final-pc off by 1 |

On all 24 D=1 tests the cores' committed **A and P match the suite exactly** —
the WDC BCD SBC model equals standard BCD correction on these samples; only
the extra-cycle convention (Category G) and the Y-cross dummy address
(Category D pattern) differ.

**Attribution / policy:** no core change. The Y-cross dummy address is a shared
SST generator convention (both suites), and the D=1 re-read is Category G's
WDC-only convention — same decision as $B1 and the ADC/SBC family: cores keep
golden/MOS/silicon behavior.

## Category I — illegal-opcode decode mismatch (`bf`, `df`)

The WDC suite models the unassigned opcodes `$BF` and `$DF` as **2-byte
zero-page operations** (cycle 3 reads a zero-page address), while the new
core decodes them per the classic table as LDA abs,X (`$BF`) and DEC abs,X
(`$DF`). Both cores fail 0/50 on each, unchanged before and after the Option
C change; golden R65Cx2's table also treats them differently from the suite.
Pre-existing decode-level mismatch for undocumented opcodes — same family as
Category B. Not addressed by any bus-convention change; would require a
decode-table decision if illegal-opcode parity with the WDC reference is ever
wanted.

## Category F — open items (not yet root-caused)

- ~~SBC indexed family nocross partials~~ **RESOLVED (Category G,
  re-attributed):** the I=1 half of `7d`/`f9` fails because of the WDC
  I-flag extra-cycle convention; I=0 passes.
- ~~`$DE`/`$FE` DEC/INC abs,X 0/50~~ **RESOLVED (Category C, Option C,
  2026-09-02):** both now 50/50 on the new core; golden R65Cx2 still fails
  them against the WDC suite (double-write RMW + no-carry-EA dummy vs the
  WDC single-write + b2 re-read model).
- ~~`$F1` subgroup split (cyc5=16/cyc6=23)~~ **RESOLVED (Category H,
  2026-09-02).**
- The 30 divergent opcodes where WDC and MOS patterns *agree* (e.g. the
  $x4-column NOPs, some JMP-indirect variants) still fail in both cores for
  address/data reasons — covered by Categories D/E conventions or ordinary
  core-vs-reference deltas; per-opcode signatures are in `build/fail_sigs.py`
  output.

## Answer to the original question

- **Yes, WDC has real divergences from the MOS 6502 reference** on 79 of the
  109 opcodes where anything diverges at all — most notably the RMW bus
  protocol (Category A), the abs,X page-cross/forced-fix dummy address
  (Category C), and the ADC/SBC I-flag extra cycle (Category G).
- **Policy (a) note (2026-09-02):** the project follows the WDC reference for
  bus conventions, so the new core now matches WDC on Category C as well;
  golden R65Cx2 remains the MOS-convention implementation. The T65
  prediction below is unchanged.
- **Where WDC diverges, the split is clean**: the new core follows WDC, the
  golden R65Cx2 follows MOS. So a faithful-6502 core (T65) would be expected
  to agree with the **golden** on RMW protocol and page-cross dummies — i.e.
  T65 would score *better* than the new core against the WDC suite on those
  opcodes, and *worse* on Categories B/E where the new core deliberately
  follows WDC conventions.
- **The indirect-indexed-row behavior ($B1/$91/$D1/$F1) is an SST generator
  convention shared by both suites** — not a WDC-vs-MOS difference, and one
  that no textbook-6502 core (including T65) would pass.

## Reproduction

```bash
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/module_tests/cpu_65c02/build
/c/msys64/ucrt64/bin/python3 four_way.py      # suite-vs-suite pattern table
/c/msys64/ucrt64/bin/python3 cross_check.py   # per-opcode page-cross subgroups
/c/msys64/ucrt64/bin/python3 addr_model.py    # reference cycle decoding
/c/msys64/ucrt64/bin/python3 regress_check.py # per-test pre/post Option C gate
```

Sweep artifacts (raw per-test trace lines, 12700 tests, seed 1):
`sweep_wdc_results.txt` (pre-DEC_FIX-removal), `sweep_wdc_nobcdfix_results.txt`
(baseline for Option C), `sweep_wdc_abxfix_results.txt` (current new-core
state, post Option C), `sweep_wdc_golden_results.txt` (golden R65Cx2).
