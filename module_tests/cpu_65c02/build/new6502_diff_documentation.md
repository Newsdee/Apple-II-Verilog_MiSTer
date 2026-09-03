# NMOS-mode difference study: rtl/new_6502 vs v2 (WDC_MODE=0)

Prepared for external hardware-expert review of MOS 6502 undefined /
settle behavior. Scope: NMOS mode only (both cores built with
`-GWDC_MODE=0`). No WDC/65C02 vendor material is involved. This document
is self-contained: every case below gives the exact starting state and
program bytes, so each can be reproduced on a real 6502 with a logic
analyzer (capture A0-A15, RW, PHI1/PHI2 for 16 cycles).

## 1. What is being compared

| column | provenance |
|--------|-----------|
| **new6502** | user-supplied “netlist derived” NMOS-specialized 65C02 variant (README: netlist derived, fixed some pin definitions, IRQ timing speculative based on the 6502). cpu_65c02.sv sha256 b97dcbdc8ff48495… / cpu_alu.sv 5232afd91d68079d…
| **v2nmos** | hand-written 65C02 core (v2), WDC_MODE=0 branch. Its NMOS bus behavior is a hand model. |
| **R65Cx2 (golden)** | netlist-derived 65C02 reference core (independent third opinion; commits A/flags one row later, hence sampled one row later). |
| **suite model** | 65x02 SingleStepTests, suite “6502” (MOS) — a reconstruction of the MOS 6502, commit 2f6980a2d9575748. Its models for the opcodes below are the weakest reference in this table, not a ground truth. |

Retained raw traces (sha256, from `evidence/provenance.json`):
- new6502_mos_sweep_raw: 42213e2a5d3ee3b99180b553758f0f53a2ad3c787ff7523ab9a943a1d4ec7298
- v2_mos_nmos_sweep_raw: 178aa386c4147c3025c2c3220f90c84bc9665ca6c8d18a5cf3f0f4668b276bbb
- golden_sweep_raw: 9f51483992e709adf68bedbe3d0a34accfbb345c6698719bff0ef0ee8c95d52b

## 2. Headline (mechanically verified from the retained traces)

- 12 800-test MOS 6502 sweep: pass totals new6502 = v2nmos = 7973,
  R65Cx2 = 7749. fixed=0, regressed=0 between new6502 and v2nmos —
  identical suite verdicts on all 12 800 tests.
- **The per-cycle register snapshots (PC SP A X Y P, every cycle) are
  byte-identical between new6502 and v2nmos on all 12 800 tests.**
  Every one of the 91 differing lines differs **only in bus activity** —
  there are zero register-level differences at any cycle.
- The 91 bus-difference lines fall in three classes:

| class | lines | what differs (new6502 vs v2nmos) |
|-------|-------|----------------------------------|
| A: $5C | 50 | the whole settle region (bus rows 3–7, verified on all 50): new6502 drives $FFbb (bb = low operand byte, 2nd fetched) then $FFFF×4 and first reads the next PC at row 8; v2nmos drives the computed $PPbb (page = high operand byte, 3rd fetched; low = low operand byte, 2nd fetched) then holds the next PC from row 4 |
| B: illegal ops 23 3b 63 73 7b 9b c3 db f3 | 9 | five consecutive settle rows: new6502 = $FFbb (bb = byte at PC+2; op 63 shows $FFEE) then $FFFF; v2nmos = a different page (mostly EE, sometimes 1F/2C/CD) then a PC+4 hold. Both cores: 4-byte fetch, PC+4, A/X/Y/SP unchanged; status bit 4 (break) set on 8 of 9 (op 9b: P unchanged) |
| C: trailing cycles, legal ops | 32 | addresses in unmodelled rows only (row ≥ suite cycle count); identical inside the checked window |

- Class B context: on the other **441/450** sampled tests of those nine
  illegal opcodes, new6502 and v2nmos produce **byte-identical** traces
  (same 4-byte fetch, same PC-sequence settle reads, same $EEEE holds).
  The nine tests in §4 are the only sampled tests where they differ.
- **Outside the 91 diff lines:** all 50 sampled op-$80 tests PASS for both
  cores — and for every core under test — while the cores decode $80 as a
  2-byte relative branch (WDC BRA) and execute past the branch target,
  which the suite never checks (the suite models $80 as a 2-byte NOP).
  See question 11 in §6. This is the concrete case of “finish early or
  late and occasionally appear correct”: the check window ends before the
  branch divergence is observable.
- Class A is the only class where the cores’ *next-PC activity* starts on
  different rows (8 vs 4). Because the cores hold addresses on the bus
  during settle cycles, the bus traces alone do not fix the exact cycle
  count — that is precisely what a silicon capture would settle. R65Cx2
  (the netlist-derived 65C02) agrees with v2nmos on the $5C cycle-3
  phantom and on driving the next PC from row 4 (verified 50/50), which
  is one independent data point against new6502’s $FFbb/$FFFF claim.
- Classes B and C: both cores agree on the functional outcome (width, PC
  update, flags) on every line — they differ only in phantom/settle
  addresses. The suite’s model of the nine illegal ops is a different
  instruction entirely and matches no core (see §4).

## 3. Class A — $5C (50 tests; two shown in full)

Verified on all 50 tests (bus tokens, rows 0–15):
- rows 0–2: identical 3-byte fetch (opcode + 2 operand bytes).
- row 3 (settle phantom): new6502 = `$FFbb` (page FF, bb = low operand
  byte); v2nmos = R65Cx2 = the *computed* `$PPbb` (page = high operand
  byte, low = low operand byte) — verified 50/50.
- rows 4–7: new6502 holds `$FFFF`; v2nmos holds the **next PC** (the
  suite’s expected final PC); R65Cx2 goes next-PC, next-PC+1, next-PC+2,
  then `$EEEE`.
- **Next-opcode-fetch start** (first row pair READ(finalPC),
  READ(finalPC+1) — distinguishes a real fetch from a PC hold):
  R65Cx2 starts the next fetch at row 4 on all 50 (exact on the 27
  4-cycle tests; 1 row early on the 23 5-cycle tests). v2nmos and
  new6502 both start the next fetch at row 8 on all 50 (the next PC is
  already on the bus from row 4 for v2nmos, but the fetch pair — opcode
  read followed by the next byte — forms only at row 8; 3–4 rows late
  against the suite). Verified 50/50 with the same mechanical rule the
  report uses.
- The suite models 27/50 tests as 4 cycles and 23/50 as 5 cycles, with its
  own phantom addresses (neither core’s). Both cores advance PC by +3 and
  leave A/X/Y/SP/P unchanged — their per-cycle register snapshots are
  identical, so the whole difference is the bus activity above.
The open question for the expert: does the real MOS 6502, after the
3-byte $5C fetch, drive `$FFbb`+`$FFFF` with the next fetch ~4 cycles later
(new6502’s claim), or the computed `$PPbb` with the next PC on the bus from
the following row (v2nmos + R65Cx2 claim)? The held-address rows (4–7) are
real bus activity either way; whether they count as cycles of the $5C
instruction or as separate settle cycles is exactly what a silicon capture
or the perfect6502 netlist simulation settles. The two shown tests below
are full reproductions; the remaining 48 are the same structure with
different operand bytes.

### op 5c — evidence line 4600

**Initial state**  PC=$240B  SP=$B4  A=$E3  X=$3D  Y=$CC  P=$BF
**RAM**          $7924=2B   $7824=65   $240D=78   $240C=E7   $240B=5C
**Program**      5C E7 78 (at PC)
**Suite model**  5 cycles, final PC=$240E A=$E3 P=$BF

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $240B R 5C | $240B R 5C | $240B R 5C | $240B R 5C |
|  1 | $240C R E7 | $240C R E7 | $240C R E7 | $240C R E7 |
|  2 | $240D R 78 | $240D R 78 | $240D R 78 | $240D R 78 |
|  3 | $7824 R 65 | $FFE7 R EE | $78E7 R EE | $78E7 R EE |  *
|  4 | $7924 R 2B | $FFFF R EE | $240E R EE | $240E R EE |  *
|  5 | (next fetch @ $240E) | $FFFF R EE | $240E R EE | $240F R EE |
|  6 |  | $FFFF R EE | $240E R EE | $2410 R EE |
|  7 |  | $FFFF R EE | $240E R EE | $EEEE R EF |
|  8 |  | $240E R EE | $240E R EE | $EEEE W EF |
|  9 |  | $240F R EE | $240F R EE | $EEEE W F0 |
| 10 |  | $2410 R EE | $2410 R EE | $2411 R EE |
| 11 |  | $EEEE R EE | $EEEE R EE | $2412 R EE |
| 12 |  | $EEEE W EE | $EEEE W EE | $2413 R EE |
| 13 |  | $EEEE W EF | $EEEE W EF | $EEEE R F0 |
| 14 |  | $2411 R EE | $2411 R EE | $EEEE W F0 |
| 15 |  | $2412 R EE | $2412 R EE | $EEEE W F1 |

(* = rows inside the checked window (cyc < 5) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 5; R65Cx2 commits one row later):
- new6502 : $240E B4 E3 3D CC BF
- v2nmos  : $240E B4 E3 3D CC BF
- R65Cx2  : $2410 B4 E3 3D CC BF
- suite   : $240E $B4 $E3 $3D $CC $BF (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $240E; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 8
- v2nmos  : 4
- R65Cx2  : 4

- new6502 vs suite : cyc3: addr FFE7 != expected 7824; cyc3: data EE != expected 65; cyc3: illegal access FFE7; cyc4: addr FFFF != expected 7924; cyc4: data EE != expected 2B; cyc4: illegal access FFFF; complete: row 5 not a fetch at final pc 240E (got FFFF/R)
- v2nmos  vs suite : cyc3: addr 78E7 != expected 7824; cyc3: data EE != expected 65; cyc3: illegal access 78E7; cyc4: addr 240E != expected 7924; cyc4: data EE != expected 2B; cyc4: illegal access 240E
- R65Cx2  vs suite : cyc3: addr 78E7 != expected 7824; cyc3: data EE != expected 65; cyc3: illegal access 78E7; cyc4: addr 240E != expected 7924; cyc4: data EE != expected 2B; cyc4: illegal access 240E; final pc 2410 != 240E; complete: row 5 not a fetch at final pc 240E (got 240F/R)

**Expert verdict / reference (fill in):** ______________________________

### op 5c — evidence line 4601

**Initial state**  PC=$9284  SP=$F2  A=$D0  X=$8E  Y=$6F  P=$B0
**RAM**          $CFE4=AD   $9286=CF   $9285=56   $9284=5C
**Program**      5C 56 CF (at PC)
**Suite model**  4 cycles, final PC=$9287 A=$D0 P=$B0

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $9284 R 5C | $9284 R 5C | $9284 R 5C | $9284 R 5C |
|  1 | $9285 R 56 | $9285 R 56 | $9285 R 56 | $9285 R 56 |
|  2 | $9286 R CF | $9286 R CF | $9286 R CF | $9286 R CF |
|  3 | $CFE4 R AD | $FF56 R EE | $CF56 R EE | $CF56 R EE |  *
|  4 | (next fetch @ $9287) | $FFFF R EE | $9287 R EE | $9287 R EE |
|  5 |  | $FFFF R EE | $9287 R EE | $9288 R EE |
|  6 |  | $FFFF R EE | $9287 R EE | $9289 R EE |
|  7 |  | $FFFF R EE | $9287 R EE | $EEEE R F1 |
|  8 |  | $9287 R EE | $9287 R EE | $EEEE W F1 |
|  9 |  | $9288 R EE | $9288 R EE | $EEEE W F2 |
| 10 |  | $9289 R EE | $9289 R EE | $928A R EE |
| 11 |  | $EEEE R EE | $EEEE R EE | $928B R EE |
| 12 |  | $EEEE W EE | $EEEE W EE | $928C R EE |
| 13 |  | $EEEE W EF | $EEEE W EF | $EEEE R F2 |
| 14 |  | $928A R EE | $928A R EE | $EEEE W F2 |
| 15 |  | $928B R EE | $928B R EE | $EEEE W F3 |

(* = rows inside the checked window (cyc < 4) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 4; R65Cx2 commits one row later):
- new6502 : $9287 F2 D0 8E 6F B0
- v2nmos  : $9287 F2 D0 8E 6F B0
- R65Cx2  : $9287 F2 D0 8E 6F B0
- suite   : $9287 $F2 $D0 $8E $6F $B0 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $9287; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 8
- v2nmos  : 4
- R65Cx2  : 4

- new6502 vs suite : cyc3: addr FF56 != expected CFE4; cyc3: data EE != expected AD; cyc3: illegal access FF56; complete: row 4 not a fetch at final pc 9287 (got FFFF/R)
- v2nmos  vs suite : cyc3: addr CF56 != expected CFE4; cyc3: data EE != expected AD; cyc3: illegal access CF56
- R65Cx2  vs suite : cyc3: addr CF56 != expected CFE4; cyc3: data EE != expected AD; cyc3: illegal access CF56

**Expert verdict / reference (fill in):** ______________________________

_Remaining 48 $5C tests (same verified structure; evidence line):_
- line 4602 (PC=$3A8D, program 5C 34 25)
- line 4603 (PC=$C5D1, program 5C D0 D6)
- line 4604 (PC=$4C7A, program 5C 83 62)
- line 4605 (PC=$F21F, program 5C 12 1D)
- line 4606 (PC=$7CA0, program 5C BA 5B)
- line 4607 (PC=$F0F1, program 5C DA 6D)
- line 4608 (PC=$3C56, program 5C DF 50)
- line 4609 (PC=$D002, program 5C B3 86)
- line 4610 (PC=$C65E, program 5C 04 E0)
- line 4611 (PC=$374A, program 5C 65 2F)
- line 4612 (PC=$A548, program 5C 0B D9)
- line 4613 (PC=$E5A0, program 5C 41 50)
- line 4614 (PC=$AA60, program 5C 5A 48)
- line 4615 (PC=$E029, program 5C A8 E6)
- line 4616 (PC=$2B0F, program 5C F4 80)
- line 4617 (PC=$7CA8, program 5C 36 0F)
- line 4618 (PC=$FF2F, program 5C 98 2E)
- line 4619 (PC=$DB8F, program 5C 3D C3)
- line 4620 (PC=$F267, program 5C FA 26)
- line 4621 (PC=$AC90, program 5C 88 40)
- line 4622 (PC=$391E, program 5C B4 8C)
- line 4623 (PC=$5238, program 5C 71 C1)
- line 4624 (PC=$D92D, program 5C 1C 7C)
- line 4625 (PC=$C02F, program 5C 29 CB)
- line 4626 (PC=$0DFC, program 5C 69 5B)
- line 4627 (PC=$40F3, program 5C 09 AD)
- line 4628 (PC=$6E5B, program 5C 9F 0E)
- line 4629 (PC=$6C68, program 5C CC 12)
- line 4630 (PC=$E967, program 5C 11 78)
- line 4631 (PC=$09E2, program 5C D2 D7)
- line 4632 (PC=$7F59, program 5C 1D 05)
- line 4633 (PC=$EAF3, program 5C C1 E5)
- line 4634 (PC=$77C7, program 5C 8C 43)
- line 4635 (PC=$CC14, program 5C 4A 1E)
- line 4636 (PC=$5735, program 5C FC BB)
- line 4637 (PC=$64D3, program 5C 3A 89)
- line 4638 (PC=$6A89, program 5C 39 B4)
- line 4639 (PC=$70DE, program 5C E1 76)
- line 4640 (PC=$69D1, program 5C 34 86)
- line 4641 (PC=$E1E3, program 5C 47 2E)
- line 4642 (PC=$A591, program 5C E4 1D)
- line 4643 (PC=$8BCC, program 5C 11 07)
- line 4644 (PC=$C027, program 5C CF 1F)
- line 4645 (PC=$2F5F, program 5C 0B 31)
- line 4646 (PC=$7201, program 5C D1 33)
- line 4647 (PC=$B9AE, program 5C 89 05)
- line 4648 (PC=$901F, program 5C 9D 3B)
- line 4649 (PC=$6340, program 5C FA 95)

## 4. Class B — the 9 illegal-op edge cases (one per op)

Both cores model these nine illegal opcodes the same way — a 4-byte
fetch from PC, PC advances by +4, A/X/Y/SP unchanged, a short settle
sequence; on 8 of the 9 lines both cores also set status bit 4 (the
break flag) in P (op 9b leaves P unchanged) — verified from the
identical register snapshots. On 441/450 sampled tests their traces are
byte-identical.
The nine tests below are the only sampled tests where the first settle
read differs: new6502 drives `$FFbb` (bb = byte at PC+2; op 63 shows
`$FFEE`) then `$FFFF`;
v2nmos drives a different page (often EE, sometimes data-dependent) then a
PC+4 hold. The suite’s model of these opcodes is a *different instruction*
entirely (typically a 2-byte zero-page op with a RAM write-back and flag
changes) and matches no core on any of the 450 tests — this is the case
where the expert input is most valuable: confirm the real MOS 6502 width /
PC update / flag behavior, and the settle-cycle addresses.

### op 23 — evidence line 1754

**Initial state**  PC=$9649  SP=$60  A=$19  X=$A3  Y=$0A  P=$A0
**RAM**          $9649=23   $964A=5C   $964B=E8   $005C=78   $00FF=2C   $0000=BD   $BD2C=C4
**Program**      23 5C E8 (at PC)
**Suite model**  8 cycles, final PC=$964B A=$08 P=$21

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $9649 R 23 | $9649 R 23 | $9649 R 23 | $9649 R 23 |
|  1 | $964A R 5C | $964A R 5C | $964A R 5C | $964A R 5C |
|  2 | $005C R 78 | $964B R E8 | $964B R E8 | $964A R 5C |  *
|  3 | $00FF R 2C | $964C R EE | $964C R EE | $964B R E8 |  *
|  4 | $0000 R BD | $FFE8 R EE | $EEE8 R EE | $964C R EE |  *
|  5 | $BD2C R C4 | $FFFF R EE | $964D R EE | $EEE8 R EE |  *
|  6 | $BD2C W C4 | $FFFF R EE | $964D R EE | $964D R EE |  *
|  7 | $BD2C W 88 | $FFFF R EE | $964D R EE | $964E R EE |  *
|  8 | (next fetch @ $964B) | $FFFF R EE | $964D R EE | $964F R EE |
|  9 |  | $964D R EE | $964D R EE | $EEEE R F1 |
| 10 |  | $964E R EE | $964E R EE | $EEEE W F1 |
| 11 |  | $964F R EE | $964F R EE | $EEEE W F2 |
| 12 |  | $EEEE R F1 | $EEEE R F1 | $9650 R EE |
| 13 |  | $EEEE W F1 | $EEEE W F1 | $9651 R EE |
| 14 |  | $EEEE W F2 | $EEEE W F2 | $9652 R EE |
| 15 |  | $9650 R EE | $9650 R EE | $EEEE R F2 |

(* = rows inside the checked window (cyc < 8) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 8; R65Cx2 commits one row later):
- new6502 : $964D 60 19 A3 0A B0
- v2nmos  : $964D 60 19 A3 0A B0
- R65Cx2  : $9650 60 19 A3 0A B0
- suite   : $964B $60 $08 $A3 $0A $21 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $964B; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 2
- v2nmos  : 2
- R65Cx2  : 3

**First bus READ at the core-agreed final PC** ($964D; the suite expected $964B):
- new6502 : 9
- v2nmos  : 5
- R65Cx2  : 6

- new6502 vs suite : cyc2: addr 964B != expected 005C; cyc2: data E8 != expected 78; cyc3: addr 964C != expected 00FF; cyc3: data EE != expected 2C; cyc3: illegal access 964C; cyc4: addr FFE8 != expected 0000; cyc4: data EE != expected BD; cyc4: illegal access FFE8; cyc5: addr FFFF != expected BD2C; cyc5: data EE != expected C4; cyc5: illegal access FFFF; cyc6: addr FFFF != expected BD2C; cyc6: rw R != expected write; cyc6: data EE != expected C4; cyc6: illegal access FFFF; cyc7: addr FFFF != expected BD2C; cyc7: rw R != expected write; cyc7: data EE != expected 88; cyc7: illegal access FFFF; final pc 964D != 964B; final a  19 != 08; final p B0 != 21 (masked); complete: row 8 not a fetch at final pc 964B (got FFFF/R); final ram[BD2C] = 196 != 136
- v2nmos  vs suite : cyc2: addr 964B != expected 005C; cyc2: data E8 != expected 78; cyc3: addr 964C != expected 00FF; cyc3: data EE != expected 2C; cyc3: illegal access 964C; cyc4: addr EEE8 != expected 0000; cyc4: data EE != expected BD; cyc4: illegal access EEE8; cyc5: addr 964D != expected BD2C; cyc5: data EE != expected C4; cyc5: illegal access 964D; cyc6: addr 964D != expected BD2C; cyc6: rw R != expected write; cyc6: data EE != expected C4; cyc6: illegal access 964D; cyc7: addr 964D != expected BD2C; cyc7: rw R != expected write; cyc7: data EE != expected 88; cyc7: illegal access 964D; final pc 964D != 964B; final a  19 != 08; final p B0 != 21 (masked); complete: row 8 not a fetch at final pc 964B (got 964D/R); final ram[BD2C] = 196 != 136
- R65Cx2  vs suite : cyc2: addr 964A != expected 005C; cyc2: data 5C != expected 78; cyc3: addr 964B != expected 00FF; cyc3: data E8 != expected 2C; cyc4: addr 964C != expected 0000; cyc4: data EE != expected BD; cyc4: illegal access 964C; cyc5: addr EEE8 != expected BD2C; cyc5: data EE != expected C4; cyc5: illegal access EEE8; cyc6: addr 964D != expected BD2C; cyc6: rw R != expected write; cyc6: data EE != expected C4; cyc6: illegal access 964D; cyc7: addr 964E != expected BD2C; cyc7: rw R != expected write; cyc7: data EE != expected 88; cyc7: illegal access 964E; final pc 9650 != 964B; final a  19 != 08; final p B0 != 21 (masked); complete: row 8 not a fetch at final pc 964B (got 964F/R); final ram[BD2C] = 196 != 136

**Expert verdict / reference (fill in):** ______________________________

### op 3b — evidence line 2971

**Initial state**  PC=$0A0A  SP=$01  A=$4A  X=$81  Y=$EB  P=$AC
**RAM**          $0A0A=3B   $0A0B=5C   $0A0C=72   $7247=B2   $7347=4F   $0A0D=CD
**Program**      3B 5C 72 CD (at PC)
**Suite model**  7 cycles, final PC=$0A0D A=$0A P=$2C

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $0A0A R 3B | $0A0A R 3B | $0A0A R 3B | $0A0A R 3B |
|  1 | $0A0B R 5C | $0A0B R 5C | $0A0B R 5C | $0A0B R 5C |
|  2 | $0A0C R 72 | $0A0C R 72 | $0A0C R 72 | $0A0B R 5C |
|  3 | $7247 R B2 | $0A0D R CD | $0A0D R CD | $0A0C R 72 |  *
|  4 | $7347 R 4F | $FF72 R EE | $CD72 R EE | $0A0D R CD |  *
|  5 | $7347 W 4F | $FFFF R EE | $0A0E R EE | $CD72 R EE |  *
|  6 | $7347 W 9E | $FFFF R EE | $0A0E R EE | $0A0E R EE |  *
|  7 | (next fetch @ $0A0D) | $FFFF R EE | $0A0E R EE | $0A0F R EE |
|  8 |  | $FFFF R EE | $0A0E R EE | $0A10 R EE |
|  9 |  | $0A0E R EE | $0A0E R EE | $EEEE R EF |
| 10 |  | $0A0F R EE | $0A0F R EE | $EEEE W EF |
| 11 |  | $0A10 R EE | $0A10 R EE | $EEEE W F0 |
| 12 |  | $EEEE R EE | $EEEE R EE | $0A11 R EE |
| 13 |  | $EEEE W EE | $EEEE W EE | $0A12 R EE |
| 14 |  | $EEEE W EF | $EEEE W EF | $0A13 R EE |
| 15 |  | $0A11 R EE | $0A11 R EE | $EEEE R F0 |

(* = rows inside the checked window (cyc < 7) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 7; R65Cx2 commits one row later):
- new6502 : $0A0E 01 4A 81 EB BC
- v2nmos  : $0A0E 01 4A 81 EB BC
- R65Cx2  : $0A10 01 4A 81 EB BC
- suite   : $0A0D $01 $0A $81 $EB $2C (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $0A0D; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 3
- v2nmos  : 3
- R65Cx2  : 4

**First bus READ at the core-agreed final PC** ($0A0E; the suite expected $0A0D):
- new6502 : 9
- v2nmos  : 5
- R65Cx2  : 6

- new6502 vs suite : cyc3: addr 0A0D != expected 7247; cyc3: data CD != expected B2; cyc4: addr FF72 != expected 7347; cyc4: data EE != expected 4F; cyc4: illegal access FF72; cyc5: addr FFFF != expected 7347; cyc5: rw R != expected write; cyc5: data EE != expected 4F; cyc5: illegal access FFFF; cyc6: addr FFFF != expected 7347; cyc6: rw R != expected write; cyc6: data EE != expected 9E; cyc6: illegal access FFFF; final pc 0A0E != 0A0D; final a  4A != 0A; complete: row 7 not a fetch at final pc 0A0D (got FFFF/R); final ram[7347] = 79 != 158
- v2nmos  vs suite : cyc3: addr 0A0D != expected 7247; cyc3: data CD != expected B2; cyc4: addr CD72 != expected 7347; cyc4: data EE != expected 4F; cyc4: illegal access CD72; cyc5: addr 0A0E != expected 7347; cyc5: rw R != expected write; cyc5: data EE != expected 4F; cyc5: illegal access 0A0E; cyc6: addr 0A0E != expected 7347; cyc6: rw R != expected write; cyc6: data EE != expected 9E; cyc6: illegal access 0A0E; final pc 0A0E != 0A0D; final a  4A != 0A; complete: row 7 not a fetch at final pc 0A0D (got 0A0E/R); final ram[7347] = 79 != 158
- R65Cx2  vs suite : cyc2: addr 0A0B != expected 0A0C; cyc2: data 5C != expected 72; cyc3: addr 0A0C != expected 7247; cyc3: data 72 != expected B2; cyc4: addr 0A0D != expected 7347; cyc4: data CD != expected 4F; cyc5: addr CD72 != expected 7347; cyc5: rw R != expected write; cyc5: data EE != expected 4F; cyc5: illegal access CD72; cyc6: addr 0A0E != expected 7347; cyc6: rw R != expected write; cyc6: data EE != expected 9E; cyc6: illegal access 0A0E; final pc 0A10 != 0A0D; final a  4A != 0A; complete: row 7 not a fetch at final pc 0A0D (got 0A0F/R); final ram[7347] = 79 != 158

**Expert verdict / reference (fill in):** ______________________________

### op 63 — evidence line 4983

**Initial state**  PC=$2F61  SP=$0B  A=$EB  X=$30  Y=$D4  P=$EB
**RAM**          $2F61=63   $2F62=9B   $2F63=5C   $009B=7E   $00CB=00   $00CC=FA   $FA00=FF
**Program**      63 9B 5C (at PC)
**Suite model**  8 cycles, final PC=$2F63 A=$41 P=$A9

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $2F61 R 63 | $2F61 R 63 | $2F61 R 63 | $2F61 R 63 |
|  1 | $2F62 R 9B | $2F62 R 9B | $2F62 R 9B | $2F62 R 9B |
|  2 | $009B R 7E | $2F63 R 5C | $2F63 R 5C | $2F62 R 9B |  *
|  3 | $00CB R 00 | $2F64 R EE | $2F64 R EE | $2F63 R 5C |  *
|  4 | $00CC R FA | $2F65 R EE | $2F65 R EE | $2F63 R 5C |  *
|  5 | $FA00 R FF | $FFEE R EE | $EEEE R EE | $2F64 R EE |  *
|  6 | $FA00 W FF | $FFFF R EE | $2F66 R EE | $2F65 R EE |  *
|  7 | $FA00 W FF | $FFFF R EE | $2F66 R EE | $EEEE R F1 |  *
|  8 | (next fetch @ $2F63) | $FFFF R EE | $2F66 R EE | $2F66 R EE |
|  9 |  | $FFFF R EE | $2F66 R EE | $2F67 R EE |
| 10 |  | $2F66 R EE | $2F66 R EE | $2F68 R EE |
| 11 |  | $2F67 R EE | $2F67 R EE | $EEEE R F1 |
| 12 |  | $2F68 R EE | $2F68 R EE | $EEEE W F1 |
| 13 |  | $EEEE R EE | $EEEE R EE | $EEEE W F2 |
| 14 |  | $EEEE W EE | $EEEE W EE | $2F69 R EE |
| 15 |  | $EEEE W EF | $EEEE W EF | $2F6A R EE |

(* = rows inside the checked window (cyc < 8) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 8; R65Cx2 commits one row later):
- new6502 : $2F66 0B EB 30 D4 FB
- v2nmos  : $2F66 0B EB 30 D4 FB
- R65Cx2  : $2F66 0B EB 30 D4 FB
- suite   : $2F63 $0B $41 $30 $D4 $A9 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $2F63; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 2
- v2nmos  : 2
- R65Cx2  : 3

**First bus READ at the core-agreed final PC** ($2F66; the suite expected $2F63):
- new6502 : 10
- v2nmos  : 6
- R65Cx2  : 8

- new6502 vs suite : cyc2: addr 2F63 != expected 009B; cyc2: data 5C != expected 7E; cyc3: addr 2F64 != expected 00CB; cyc3: data EE != expected 00; cyc3: illegal access 2F64; cyc4: addr 2F65 != expected 00CC; cyc4: data EE != expected FA; cyc4: illegal access 2F65; cyc5: addr FFEE != expected FA00; cyc5: data EE != expected FF; cyc5: illegal access FFEE; cyc6: addr FFFF != expected FA00; cyc6: rw R != expected write; cyc6: data EE != expected FF; cyc6: illegal access FFFF; cyc7: addr FFFF != expected FA00; cyc7: rw R != expected write; cyc7: data EE != expected FF; cyc7: illegal access FFFF; final pc 2F66 != 2F63; final a  EB != 41; final p FB != A9 (masked); complete: row 8 not a fetch at final pc 2F63 (got FFFF/R)
- v2nmos  vs suite : cyc2: addr 2F63 != expected 009B; cyc2: data 5C != expected 7E; cyc3: addr 2F64 != expected 00CB; cyc3: data EE != expected 00; cyc3: illegal access 2F64; cyc4: addr 2F65 != expected 00CC; cyc4: data EE != expected FA; cyc4: illegal access 2F65; cyc5: addr EEEE != expected FA00; cyc5: data EE != expected FF; cyc5: illegal access EEEE; cyc6: addr 2F66 != expected FA00; cyc6: rw R != expected write; cyc6: data EE != expected FF; cyc6: illegal access 2F66; cyc7: addr 2F66 != expected FA00; cyc7: rw R != expected write; cyc7: data EE != expected FF; cyc7: illegal access 2F66; final pc 2F66 != 2F63; final a  EB != 41; final p FB != A9 (masked); complete: row 8 not a fetch at final pc 2F63 (got 2F66/R)
- R65Cx2  vs suite : cyc2: addr 2F62 != expected 009B; cyc2: data 9B != expected 7E; cyc3: addr 2F63 != expected 00CB; cyc3: data 5C != expected 00; cyc4: addr 2F63 != expected 00CC; cyc4: data 5C != expected FA; cyc5: addr 2F64 != expected FA00; cyc5: data EE != expected FF; cyc5: illegal access 2F64; cyc6: addr 2F65 != expected FA00; cyc6: rw R != expected write; cyc6: data EE != expected FF; cyc6: illegal access 2F65; cyc7: addr EEEE != expected FA00; cyc7: rw R != expected write; cyc7: data F1 != expected FF; cyc7: illegal access EEEE; final pc 2F66 != 2F63; final a  EB != 41; final p FB != A9 (masked); complete: row 8 not a fetch at final pc 2F63 (got 2F66/R)

**Expert verdict / reference (fill in):** ______________________________

### op 73 — evidence line 5781

**Initial state**  PC=$A137  SP=$E6  A=$29  X=$04  Y=$FA  P=$AA
**RAM**          $A137=73   $A138=5C   $A139=43   $005C=AF   $005D=CA   $CAA9=2B   $CBA9=0D
**Program**      73 5C 43 (at PC)
**Suite model**  8 cycles, final PC=$A139 A=$36 P=$28

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $A137 R 73 | $A137 R 73 | $A137 R 73 | $A137 R 73 |
|  1 | $A138 R 5C | $A138 R 5C | $A138 R 5C | $A138 R 5C |
|  2 | $005C R AF | $A139 R 43 | $A139 R 43 | $A138 R 5C |  *
|  3 | $005D R CA | $A13A R EE | $A13A R EE | $A139 R 43 |  *
|  4 | $CAA9 R 2B | $FF43 R EE | $EE43 R EE | $A13A R EE |  *
|  5 | $CBA9 R 0D | $FFFF R EE | $A13B R EE | $EE43 R EE |  *
|  6 | $CBA9 W 0D | $FFFF R EE | $A13B R EE | $A13B R EE |  *
|  7 | $CBA9 W 06 | $FFFF R EE | $A13B R EE | $A13C R EE |  *
|  8 | (next fetch @ $A139) | $FFFF R EE | $A13B R EE | $A13D R EE |
|  9 |  | $A13B R EE | $A13B R EE | $EEEE R EF |
| 10 |  | $A13C R EE | $A13C R EE | $EEEE W EF |
| 11 |  | $A13D R EE | $A13D R EE | $EEEE W F0 |
| 12 |  | $EEEE R F0 | $EEEE R F0 | $A13E R EE |
| 13 |  | $EEEE W F0 | $EEEE W F0 | $A13F R EE |
| 14 |  | $EEEE W F1 | $EEEE W F1 | $A140 R EE |
| 15 |  | $A13E R EE | $A13E R EE | $EEEE R F0 |

(* = rows inside the checked window (cyc < 8) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 8; R65Cx2 commits one row later):
- new6502 : $A13B E6 29 04 FA BA
- v2nmos  : $A13B E6 29 04 FA BA
- R65Cx2  : $A13E E6 29 04 FA BA
- suite   : $A139 $E6 $36 $04 $FA $28 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $A139; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 2
- v2nmos  : 2
- R65Cx2  : 3

**First bus READ at the core-agreed final PC** ($A13B; the suite expected $A139):
- new6502 : 9
- v2nmos  : 5
- R65Cx2  : 6

- new6502 vs suite : cyc2: addr A139 != expected 005C; cyc2: data 43 != expected AF; cyc3: addr A13A != expected 005D; cyc3: data EE != expected CA; cyc3: illegal access A13A; cyc4: addr FF43 != expected CAA9; cyc4: data EE != expected 2B; cyc4: illegal access FF43; cyc5: addr FFFF != expected CBA9; cyc5: data EE != expected 0D; cyc5: illegal access FFFF; cyc6: addr FFFF != expected CBA9; cyc6: rw R != expected write; cyc6: data EE != expected 0D; cyc6: illegal access FFFF; cyc7: addr FFFF != expected CBA9; cyc7: rw R != expected write; cyc7: data EE != expected 06; cyc7: illegal access FFFF; final pc A13B != A139; final a  29 != 36; final p BA != 28 (masked); complete: row 8 not a fetch at final pc A139 (got FFFF/R); final ram[CBA9] = 13 != 6
- v2nmos  vs suite : cyc2: addr A139 != expected 005C; cyc2: data 43 != expected AF; cyc3: addr A13A != expected 005D; cyc3: data EE != expected CA; cyc3: illegal access A13A; cyc4: addr EE43 != expected CAA9; cyc4: data EE != expected 2B; cyc4: illegal access EE43; cyc5: addr A13B != expected CBA9; cyc5: data EE != expected 0D; cyc5: illegal access A13B; cyc6: addr A13B != expected CBA9; cyc6: rw R != expected write; cyc6: data EE != expected 0D; cyc6: illegal access A13B; cyc7: addr A13B != expected CBA9; cyc7: rw R != expected write; cyc7: data EE != expected 06; cyc7: illegal access A13B; final pc A13B != A139; final a  29 != 36; final p BA != 28 (masked); complete: row 8 not a fetch at final pc A139 (got A13B/R); final ram[CBA9] = 13 != 6
- R65Cx2  vs suite : cyc2: addr A138 != expected 005C; cyc2: data 5C != expected AF; cyc3: addr A139 != expected 005D; cyc3: data 43 != expected CA; cyc4: addr A13A != expected CAA9; cyc4: data EE != expected 2B; cyc4: illegal access A13A; cyc5: addr EE43 != expected CBA9; cyc5: data EE != expected 0D; cyc5: illegal access EE43; cyc6: addr A13B != expected CBA9; cyc6: rw R != expected write; cyc6: data EE != expected 0D; cyc6: illegal access A13B; cyc7: addr A13C != expected CBA9; cyc7: rw R != expected write; cyc7: data EE != expected 06; cyc7: illegal access A13C; final pc A13E != A139; final a  29 != 36; final p BA != 28 (masked); complete: row 8 not a fetch at final pc A139 (got A13D/R); final ram[CBA9] = 13 != 6

**Expert verdict / reference (fill in):** ______________________________

### op 7b — evidence line 6190

**Initial state**  PC=$33C2  SP=$74  A=$FC  X=$59  Y=$2E  P=$68
**RAM**          $33C2=7B   $33C3=5C   $33C4=63   $638A=BA   $33C5=1F
**Program**      7B 5C 63 1F (at PC)
**Suite model**  7 cycles, final PC=$33C5 A=$BF P=$29

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $33C2 R 7B | $33C2 R 7B | $33C2 R 7B | $33C2 R 7B |
|  1 | $33C3 R 5C | $33C3 R 5C | $33C3 R 5C | $33C3 R 5C |
|  2 | $33C4 R 63 | $33C4 R 63 | $33C4 R 63 | $33C3 R 5C |
|  3 | $638A R BA | $33C5 R 1F | $33C5 R 1F | $33C4 R 63 |  *
|  4 | $638A R BA | $FF63 R EE | $1F63 R EE | $33C5 R 1F |  *
|  5 | $638A W BA | $FFFF R EE | $33C6 R EE | $1F63 R EE |  *
|  6 | $638A W 5D | $FFFF R EE | $33C6 R EE | $33C6 R EE |  *
|  7 | (next fetch @ $33C5) | $FFFF R EE | $33C6 R EE | $33C7 R EE |
|  8 |  | $FFFF R EE | $33C6 R EE | $33C8 R EE |
|  9 |  | $33C6 R EE | $33C6 R EE | $EEEE R F0 |
| 10 |  | $33C7 R EE | $33C7 R EE | $EEEE W F0 |
| 11 |  | $33C8 R EE | $33C8 R EE | $EEEE W F1 |
| 12 |  | $EEEE R EE | $EEEE R EE | $33C9 R EE |
| 13 |  | $EEEE W EE | $EEEE W EE | $33CA R EE |
| 14 |  | $EEEE W EF | $EEEE W EF | $33CB R EE |
| 15 |  | $33C9 R EE | $33C9 R EE | $EEEE R F1 |

(* = rows inside the checked window (cyc < 7) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 7; R65Cx2 commits one row later):
- new6502 : $33C6 74 FC 59 2E 78
- v2nmos  : $33C6 74 FC 59 2E 78
- R65Cx2  : $33C8 74 FC 59 2E 78
- suite   : $33C5 $74 $BF $59 $2E $29 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $33C5; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 3
- v2nmos  : 3
- R65Cx2  : 4

**First bus READ at the core-agreed final PC** ($33C6; the suite expected $33C5):
- new6502 : 9
- v2nmos  : 5
- R65Cx2  : 6

- new6502 vs suite : cyc3: addr 33C5 != expected 638A; cyc3: data 1F != expected BA; cyc4: addr FF63 != expected 638A; cyc4: data EE != expected BA; cyc4: illegal access FF63; cyc5: addr FFFF != expected 638A; cyc5: rw R != expected write; cyc5: data EE != expected BA; cyc5: illegal access FFFF; cyc6: addr FFFF != expected 638A; cyc6: rw R != expected write; cyc6: data EE != expected 5D; cyc6: illegal access FFFF; final pc 33C6 != 33C5; final a  FC != BF; final p 78 != 29 (masked); complete: row 7 not a fetch at final pc 33C5 (got FFFF/R); final ram[638A] = 186 != 93
- v2nmos  vs suite : cyc3: addr 33C5 != expected 638A; cyc3: data 1F != expected BA; cyc4: addr 1F63 != expected 638A; cyc4: data EE != expected BA; cyc4: illegal access 1F63; cyc5: addr 33C6 != expected 638A; cyc5: rw R != expected write; cyc5: data EE != expected BA; cyc5: illegal access 33C6; cyc6: addr 33C6 != expected 638A; cyc6: rw R != expected write; cyc6: data EE != expected 5D; cyc6: illegal access 33C6; final pc 33C6 != 33C5; final a  FC != BF; final p 78 != 29 (masked); complete: row 7 not a fetch at final pc 33C5 (got 33C6/R); final ram[638A] = 186 != 93
- R65Cx2  vs suite : cyc2: addr 33C3 != expected 33C4; cyc2: data 5C != expected 63; cyc3: addr 33C4 != expected 638A; cyc3: data 63 != expected BA; cyc4: addr 33C5 != expected 638A; cyc4: data 1F != expected BA; cyc5: addr 1F63 != expected 638A; cyc5: rw R != expected write; cyc5: data EE != expected BA; cyc5: illegal access 1F63; cyc6: addr 33C6 != expected 638A; cyc6: rw R != expected write; cyc6: data EE != expected 5D; cyc6: illegal access 33C6; final pc 33C8 != 33C5; final a  FC != BF; final p 78 != 29 (masked); complete: row 7 not a fetch at final pc 33C5 (got 33C7/R); final ram[638A] = 186 != 93

**Expert verdict / reference (fill in):** ______________________________

### op 9b — evidence line 7778

**Initial state**  PC=$8802  SP=$E5  A=$E3  X=$16  Y=$10  P=$38
**RAM**          $E26C=C8   $8804=E2   $8803=5C   $8802=9B
**Program**      9B 5C E2 (at PC)
**Suite model**  5 cycles, final PC=$8805 A=$E3 P=$38

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $8802 R 9B | $8802 R 9B | $8802 R 9B | $8802 R 9B |
|  1 | $8803 R 5C | $8803 R 5C | $8803 R 5C | $8803 R 5C |
|  2 | $8804 R E2 | $8804 R E2 | $8804 R E2 | $8803 R 5C |
|  3 | $E26C R C8 | $8805 R EE | $8805 R EE | $8804 R E2 |  *
|  4 | $E26C W 02 | $FFE2 R EE | $EEE2 R EE | $8805 R EE |  *
|  5 | (next fetch @ $8805) | $FFFF R EE | $8806 R EE | $EEE2 R EE |
|  6 |  | $FFFF R EE | $8806 R EE | $8806 R EE |
|  7 |  | $FFFF R EE | $8806 R EE | $8807 R EE |
|  8 |  | $FFFF R EE | $8806 R EE | $8808 R EE |
|  9 |  | $8806 R EE | $8806 R EE | $EEEE R EF |
| 10 |  | $8807 R EE | $8807 R EE | $EEEE W EF |
| 11 |  | $8808 R EE | $8808 R EE | $EEEE W F0 |
| 12 |  | $EEEE R EF | $EEEE R EF | $8809 R EE |
| 13 |  | $EEEE W EF | $EEEE W EF | $880A R EE |
| 14 |  | $EEEE W F0 | $EEEE W F0 | $880B R EE |
| 15 |  | $8809 R EE | $8809 R EE | $EEEE R F0 |

(* = rows inside the checked window (cyc < 5) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 5; R65Cx2 commits one row later):
- new6502 : $8806 E5 E3 16 10 38
- v2nmos  : $8806 E5 E3 16 10 38
- R65Cx2  : $8806 E5 E3 16 10 38
- suite   : $8805 $02 $E3 $16 $10 $38 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $8805; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 3
- v2nmos  : 3
- R65Cx2  : 4

**First bus READ at the core-agreed final PC** ($8806; the suite expected $8805):
- new6502 : 9
- v2nmos  : 5
- R65Cx2  : 6

- new6502 vs suite : cyc3: addr 8805 != expected E26C; cyc3: data EE != expected C8; cyc3: illegal access 8805; cyc4: addr FFE2 != expected E26C; cyc4: rw R != expected write; cyc4: data EE != expected 02; cyc4: illegal access FFE2; final pc 8806 != 8805; final sp E5 != 02; complete: row 5 not a fetch at final pc 8805 (got FFFF/R); final ram[E26C] = 200 != 2
- v2nmos  vs suite : cyc3: addr 8805 != expected E26C; cyc3: data EE != expected C8; cyc3: illegal access 8805; cyc4: addr EEE2 != expected E26C; cyc4: rw R != expected write; cyc4: data EE != expected 02; cyc4: illegal access EEE2; final pc 8806 != 8805; final sp E5 != 02; complete: row 5 not a fetch at final pc 8805 (got 8806/R); final ram[E26C] = 200 != 2
- R65Cx2  vs suite : cyc2: addr 8803 != expected 8804; cyc2: data 5C != expected E2; cyc3: addr 8804 != expected E26C; cyc3: data E2 != expected C8; cyc4: addr 8805 != expected E26C; cyc4: rw R != expected write; cyc4: data EE != expected 02; cyc4: illegal access 8805; final pc 8806 != 8805; final sp E5 != 02; complete: row 5 not a fetch at final pc 8805 (got EEE2/R); final ram[E26C] = 200 != 2

**Expert verdict / reference (fill in):** ______________________________

### op c3 — evidence line 9795

**Initial state**  PC=$D8BF  SP=$E6  A=$CD  X=$0C  Y=$0A  P=$E0
**RAM**          $D8BF=C3   $D8C0=5C   $D8C1=2A   $005C=C6   $0068=CD   $0069=88   $88CD=8D
**Program**      C3 5C 2A (at PC)
**Suite model**  8 cycles, final PC=$D8C1 A=$CD P=$61

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $D8BF R C3 | $D8BF R C3 | $D8BF R C3 | $D8BF R C3 |
|  1 | $D8C0 R 5C | $D8C0 R 5C | $D8C0 R 5C | $D8C0 R 5C |
|  2 | $005C R C6 | $D8C1 R 2A | $D8C1 R 2A | $D8C0 R 5C |  *
|  3 | $0068 R CD | $D8C2 R EE | $D8C2 R EE | $D8C1 R 2A |  *
|  4 | $0069 R 88 | $FF2A R EE | $EE2A R EE | $D8C2 R EE |  *
|  5 | $88CD R 8D | $FFFF R EE | $D8C3 R EE | $EE2A R EE |  *
|  6 | $88CD W 8D | $FFFF R EE | $D8C3 R EE | $D8C3 R EE |  *
|  7 | $88CD W 8C | $FFFF R EE | $D8C3 R EE | $D8C4 R EE |  *
|  8 | (next fetch @ $D8C1) | $FFFF R EE | $D8C3 R EE | $D8C5 R EE |
|  9 |  | $D8C3 R EE | $D8C3 R EE | $EEEE R EF |
| 10 |  | $D8C4 R EE | $D8C4 R EE | $EEEE W EF |
| 11 |  | $D8C5 R EE | $D8C5 R EE | $EEEE W F0 |
| 12 |  | $EEEE R F5 | $EEEE R F5 | $D8C6 R EE |
| 13 |  | $EEEE W F5 | $EEEE W F5 | $D8C7 R EE |
| 14 |  | $EEEE W F6 | $EEEE W F6 | $D8C8 R EE |
| 15 |  | $D8C6 R EE | $D8C6 R EE | $EEEE R F0 |

(* = rows inside the checked window (cyc < 8) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 8; R65Cx2 commits one row later):
- new6502 : $D8C3 E6 CD 0C 0A F0
- v2nmos  : $D8C3 E6 CD 0C 0A F0
- R65Cx2  : $D8C6 E6 CD 0C 0A F0
- suite   : $D8C1 $E6 $CD $0C $0A $61 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $D8C1; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 2
- v2nmos  : 2
- R65Cx2  : 3

**First bus READ at the core-agreed final PC** ($D8C3; the suite expected $D8C1):
- new6502 : 9
- v2nmos  : 5
- R65Cx2  : 6

- new6502 vs suite : cyc2: addr D8C1 != expected 005C; cyc2: data 2A != expected C6; cyc3: addr D8C2 != expected 0068; cyc3: data EE != expected CD; cyc3: illegal access D8C2; cyc4: addr FF2A != expected 0069; cyc4: data EE != expected 88; cyc4: illegal access FF2A; cyc5: addr FFFF != expected 88CD; cyc5: data EE != expected 8D; cyc5: illegal access FFFF; cyc6: addr FFFF != expected 88CD; cyc6: rw R != expected write; cyc6: data EE != expected 8D; cyc6: illegal access FFFF; cyc7: addr FFFF != expected 88CD; cyc7: rw R != expected write; cyc7: data EE != expected 8C; cyc7: illegal access FFFF; final pc D8C3 != D8C1; final p F0 != 61 (masked); complete: row 8 not a fetch at final pc D8C1 (got FFFF/R); final ram[88CD] = 141 != 140
- v2nmos  vs suite : cyc2: addr D8C1 != expected 005C; cyc2: data 2A != expected C6; cyc3: addr D8C2 != expected 0068; cyc3: data EE != expected CD; cyc3: illegal access D8C2; cyc4: addr EE2A != expected 0069; cyc4: data EE != expected 88; cyc4: illegal access EE2A; cyc5: addr D8C3 != expected 88CD; cyc5: data EE != expected 8D; cyc5: illegal access D8C3; cyc6: addr D8C3 != expected 88CD; cyc6: rw R != expected write; cyc6: data EE != expected 8D; cyc6: illegal access D8C3; cyc7: addr D8C3 != expected 88CD; cyc7: rw R != expected write; cyc7: data EE != expected 8C; cyc7: illegal access D8C3; final pc D8C3 != D8C1; final p F0 != 61 (masked); complete: row 8 not a fetch at final pc D8C1 (got D8C3/R); final ram[88CD] = 141 != 140
- R65Cx2  vs suite : cyc2: addr D8C0 != expected 005C; cyc2: data 5C != expected C6; cyc3: addr D8C1 != expected 0068; cyc3: data 2A != expected CD; cyc4: addr D8C2 != expected 0069; cyc4: data EE != expected 88; cyc4: illegal access D8C2; cyc5: addr EE2A != expected 88CD; cyc5: data EE != expected 8D; cyc5: illegal access EE2A; cyc6: addr D8C3 != expected 88CD; cyc6: rw R != expected write; cyc6: data EE != expected 8D; cyc6: illegal access D8C3; cyc7: addr D8C4 != expected 88CD; cyc7: rw R != expected write; cyc7: data EE != expected 8C; cyc7: illegal access D8C4; final pc D8C6 != D8C1; final p F0 != 61 (masked); complete: row 8 not a fetch at final pc D8C1 (got D8C5/R); final ram[88CD] = 141 != 140

**Expert verdict / reference (fill in):** ______________________________

### op db — evidence line 10978

**Initial state**  PC=$B19E  SP=$1E  A=$82  X=$E2  Y=$3F  P=$AF
**RAM**          $B19E=DB   $B19F=5C   $B1A0=61   $619B=36   $B1A1=2C
**Program**      DB 5C 61 2C (at PC)
**Suite model**  7 cycles, final PC=$B1A1 A=$82 P=$2D

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $B19E R DB | $B19E R DB | $B19E R DB | $B19E R DB |
|  1 | $B19F R 5C | $B19F R 5C | $B19F R 5C | $B19F R 5C |
|  2 | $B1A0 R 61 | $B19F R 5C | $B19F R 5C | $B19F R 5C |  *
|  3 | $619B R 36 | $B19F R 5C | $B19F R 5C | $B1A0 R 61 |  *
|  4 | $619B R 36 | $B1A0 R 61 | $B1A0 R 61 | $B1A1 R 2C |  *
|  5 | $619B W 36 | $B1A1 R 2C | $B1A1 R 2C | $2C61 R EE |  *
|  6 | $619B W 35 | $FF61 R EE | $2C61 R EE | $B1A2 R EE |  *
|  7 | (next fetch @ $B1A1) | $FFFF R EE | $B1A2 R EE | $B1A3 R EE |
|  8 |  | $FFFF R EE | $B1A2 R EE | $B1A4 R EE |
|  9 |  | $FFFF R EE | $B1A2 R EE | $EEEE R EF |
| 10 |  | $FFFF R EE | $B1A2 R EE | $EEEE W EF |
| 11 |  | $B1A2 R EE | $B1A2 R EE | $EEEE W F0 |
| 12 |  | $B1A3 R EE | $B1A3 R EE | $B1A5 R EE |
| 13 |  | $B1A4 R EE | $B1A4 R EE | $B1A6 R EE |
| 14 |  | $EEEE R EE | $EEEE R EE | $B1A7 R EE |
| 15 |  | $EEEE W EE | $EEEE W EE | $EEEE R F0 |

(* = rows inside the checked window (cyc < 7) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 7; R65Cx2 commits one row later):
- new6502 : $B1A2 1E 82 E2 3F BF
- v2nmos  : $B1A2 1E 82 E2 3F BF
- R65Cx2  : $B1A4 1E 82 E2 3F BF
- suite   : $B1A1 $1E $82 $E2 $3F $2D (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $B1A1; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 5
- v2nmos  : 5
- R65Cx2  : 4

**First bus READ at the core-agreed final PC** ($B1A2; the suite expected $B1A1):
- new6502 : 11
- v2nmos  : 7
- R65Cx2  : 6

- new6502 vs suite : cyc2: addr B19F != expected B1A0; cyc2: data 5C != expected 61; cyc3: addr B19F != expected 619B; cyc3: data 5C != expected 36; cyc4: addr B1A0 != expected 619B; cyc4: data 61 != expected 36; cyc5: addr B1A1 != expected 619B; cyc5: rw R != expected write; cyc5: data 2C != expected 36; cyc6: addr FF61 != expected 619B; cyc6: rw R != expected write; cyc6: data EE != expected 35; cyc6: illegal access FF61; final pc B1A2 != B1A1; final p BF != 2D (masked); complete: row 7 not a fetch at final pc B1A1 (got FFFF/R); final ram[619B] = 54 != 53
- v2nmos  vs suite : cyc2: addr B19F != expected B1A0; cyc2: data 5C != expected 61; cyc3: addr B19F != expected 619B; cyc3: data 5C != expected 36; cyc4: addr B1A0 != expected 619B; cyc4: data 61 != expected 36; cyc5: addr B1A1 != expected 619B; cyc5: rw R != expected write; cyc5: data 2C != expected 36; cyc6: addr 2C61 != expected 619B; cyc6: rw R != expected write; cyc6: data EE != expected 35; cyc6: illegal access 2C61; final pc B1A2 != B1A1; final p BF != 2D (masked); complete: row 7 not a fetch at final pc B1A1 (got B1A2/R); final ram[619B] = 54 != 53
- R65Cx2  vs suite : cyc2: addr B19F != expected B1A0; cyc2: data 5C != expected 61; cyc3: addr B1A0 != expected 619B; cyc3: data 61 != expected 36; cyc4: addr B1A1 != expected 619B; cyc4: data 2C != expected 36; cyc5: addr 2C61 != expected 619B; cyc5: rw R != expected write; cyc5: data EE != expected 36; cyc5: illegal access 2C61; cyc6: addr B1A2 != expected 619B; cyc6: rw R != expected write; cyc6: data EE != expected 35; cyc6: illegal access B1A2; final pc B1A4 != B1A1; final p BF != 2D (masked); complete: row 7 not a fetch at final pc B1A1 (got B1A3/R); final ram[619B] = 54 != 53

**Expert verdict / reference (fill in):** ______________________________

### op f3 — evidence line 12157

**Initial state**  PC=$F13B  SP=$67  A=$33  X=$0A  Y=$D6  P=$AB
**RAM**          $F13B=F3   $F13C=5C   $F13D=3A   $005C=43   $005D=72   $7219=7D   $7319=BA
**Program**      F3 5C 3A (at PC)
**Suite model**  8 cycles, final PC=$F13D A=$12 P=$28

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $F13B R F3 | $F13B R F3 | $F13B R F3 | $F13B R F3 |
|  1 | $F13C R 5C | $F13C R 5C | $F13C R 5C | $F13C R 5C |
|  2 | $005C R 43 | $F13D R 3A | $F13D R 3A | $F13C R 5C |  *
|  3 | $005D R 72 | $F13E R EE | $F13E R EE | $F13D R 3A |  *
|  4 | $7219 R 7D | $FF3A R EE | $EE3A R EE | $F13E R EE |  *
|  5 | $7319 R BA | $FFFF R EE | $F13F R EE | $EE3A R EE |  *
|  6 | $7319 W BA | $FFFF R EE | $F13F R EE | $F13F R EE |  *
|  7 | $7319 W BB | $FFFF R EE | $F13F R EE | $F140 R EE |  *
|  8 | (next fetch @ $F13D) | $FFFF R EE | $F13F R EE | $F141 R EE |
|  9 |  | $F13F R EE | $F13F R EE | $EEEE R FC |
| 10 |  | $F140 R EE | $F140 R EE | $EEEE W FC |
| 11 |  | $F141 R EE | $F141 R EE | $EEEE W FD |
| 12 |  | $EEEE R EE | $EEEE R EE | $F142 R EE |
| 13 |  | $EEEE W EE | $EEEE W EE | $F143 R EE |
| 14 |  | $EEEE W EF | $EEEE W EF | $F144 R EE |
| 15 |  | $F142 R EE | $F142 R EE | $EEEE R FD |

(* = rows inside the checked window (cyc < 8) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 8; R65Cx2 commits one row later):
- new6502 : $F13F 67 33 0A D6 BB
- v2nmos  : $F13F 67 33 0A D6 BB
- R65Cx2  : $F142 67 33 0A D6 BB
- suite   : $F13D $67 $12 $0A $D6 $28 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $F13D; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 2
- v2nmos  : 2
- R65Cx2  : 3

**First bus READ at the core-agreed final PC** ($F13F; the suite expected $F13D):
- new6502 : 9
- v2nmos  : 5
- R65Cx2  : 6

- new6502 vs suite : cyc2: addr F13D != expected 005C; cyc2: data 3A != expected 43; cyc3: addr F13E != expected 005D; cyc3: data EE != expected 72; cyc3: illegal access F13E; cyc4: addr FF3A != expected 7219; cyc4: data EE != expected 7D; cyc4: illegal access FF3A; cyc5: addr FFFF != expected 7319; cyc5: data EE != expected BA; cyc5: illegal access FFFF; cyc6: addr FFFF != expected 7319; cyc6: rw R != expected write; cyc6: data EE != expected BA; cyc6: illegal access FFFF; cyc7: addr FFFF != expected 7319; cyc7: rw R != expected write; cyc7: data EE != expected BB; cyc7: illegal access FFFF; final pc F13F != F13D; final a  33 != 12; final p BB != 28 (masked); complete: row 8 not a fetch at final pc F13D (got FFFF/R); final ram[7319] = 186 != 187
- v2nmos  vs suite : cyc2: addr F13D != expected 005C; cyc2: data 3A != expected 43; cyc3: addr F13E != expected 005D; cyc3: data EE != expected 72; cyc3: illegal access F13E; cyc4: addr EE3A != expected 7219; cyc4: data EE != expected 7D; cyc4: illegal access EE3A; cyc5: addr F13F != expected 7319; cyc5: data EE != expected BA; cyc5: illegal access F13F; cyc6: addr F13F != expected 7319; cyc6: rw R != expected write; cyc6: data EE != expected BA; cyc6: illegal access F13F; cyc7: addr F13F != expected 7319; cyc7: rw R != expected write; cyc7: data EE != expected BB; cyc7: illegal access F13F; final pc F13F != F13D; final a  33 != 12; final p BB != 28 (masked); complete: row 8 not a fetch at final pc F13D (got F13F/R); final ram[7319] = 186 != 187
- R65Cx2  vs suite : cyc2: addr F13C != expected 005C; cyc2: data 5C != expected 43; cyc3: addr F13D != expected 005D; cyc3: data 3A != expected 72; cyc4: addr F13E != expected 7219; cyc4: data EE != expected 7D; cyc4: illegal access F13E; cyc5: addr EE3A != expected 7319; cyc5: data EE != expected BA; cyc5: illegal access EE3A; cyc6: addr F13F != expected 7319; cyc6: rw R != expected write; cyc6: data EE != expected BA; cyc6: illegal access F13F; cyc7: addr F140 != expected 7319; cyc7: rw R != expected write; cyc7: data EE != expected BB; cyc7: illegal access F140; final pc F142 != F13D; final a  33 != 12; final p BB != 28 (masked); complete: row 8 not a fetch at final pc F13D (got F141/R); final ram[7319] = 186 != 187

**Expert verdict / reference (fill in):** ______________________________

## 5. Class C — trailing-only differences (32 tests, legal opcodes)

The two cores are identical inside the checked window on all 32 lines;
only the unmodelled trailing cycles differ. 25 of the 32 pass for every
core; 7 are both-fail vs the suite (the suite’s own model is inconsistent
there — the same broken-reference class documented in the prior campaign;
the two cores agree with each other). new6502’s trailing pattern is
$FFxx/`$FFFF` (released-bus model); v2nmos drives a `$XXbb`-style read then
a PC hold (which R65Cx2 sometimes matches, e.g. op 08 below).
Representative examples:

### op 08 — evidence line 412 — representative for op 08

**Initial state**  PC=$7294  SP=$FE  A=$BB  X=$72  Y=$05  P=$E4
**RAM**          $7294=08   $7295=5C   $7296=B4
**Program**      08 5C B4 (at PC)
**Suite model**  3 cycles, final PC=$7295 A=$BB P=$E4

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $7294 R 08 | $7294 R 08 | $7294 R 08 | $7294 R 08 |
|  1 | $7295 R 5C | $7295 R 5C | $7295 R 5C | $7295 R 5C |
|  2 | $01FE W F4 | $01FE W F4 | $01FE W F4 | $01FE W F4 |
|  3 | (next fetch @ $7295) | $7295 R 5C | $7295 R 5C | $7295 R 5C |
|  4 |  | $7296 R B4 | $7296 R B4 | $7296 R B4 |
|  5 |  | $7297 R EE | $7297 R EE | $7297 R EE |
|  6 |  | $FFB4 R EE | $EEB4 R EE | $EEB4 R EE |
|  7 |  | $FFFF R EE | $7298 R EE | $7298 R EE |
|  8 |  | $FFFF R EE | $7298 R EE | $7299 R EE |
|  9 |  | $FFFF R EE | $7298 R EE | $729A R EE |
| 10 |  | $FFFF R EE | $7298 R EE | $EEEE R EF |
| 11 |  | $7298 R EE | $7298 R EE | $EEEE W EF |
| 12 |  | $7299 R EE | $7299 R EE | $EEEE W F0 |
| 13 |  | $729A R EE | $729A R EE | $729B R EE |
| 14 |  | $EEEE R EE | $EEEE R EE | $729C R EE |
| 15 |  | $EEEE W EE | $EEEE W EE | $729D R EE |

(* = rows inside the checked window (cyc < 3) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 3; R65Cx2 commits one row later):
- new6502 : $7295 FD BB 72 05 F4
- v2nmos  : $7295 FD BB 72 05 F4
- R65Cx2  : $7295 FD BB 72 05 F4
- suite   : $7295 $FD $BB $72 $05 $E4 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $7295; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 1
- v2nmos  : 1
- R65Cx2  : 1

- new6502 vs suite : PASS
- v2nmos  vs suite : PASS
- R65Cx2  vs suite : PASS

**Expert verdict / reference (fill in):** ______________________________

### op 17 — evidence line 1158 — representative for op 17

**Initial state**  PC=$F14E  SP=$1C  A=$58  X=$25  Y=$C6  P=$A2
**RAM**          $F14E=17   $F14F=4C   $F150=5C   $004C=EB   $0071=77
**Program**      17 4C 5C (at PC)
**Suite model**  6 cycles, final PC=$F150 A=$FE P=$A0

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $F14E R 17 | $F14E R 17 | $F14E R 17 | $F14E R 17 |
|  1 | $F14F R 4C | $F14F R 4C | $F14F R 4C | $F14F R 4C |
|  2 | $004C R EB | $004C R EB | $004C R EB | $F14F R 4C |
|  3 | $0071 R 77 | $004C W EB | $004C W EB | $F150 R 5C |  *
|  4 | $0071 W 77 | $004C W E9 | $004C W E9 | $F151 R EE |  *
|  5 | $0071 W EE | $F150 R 5C | $F150 R 5C | $EE5C R EE |  *
|  6 | (next fetch @ $F150) | $F151 R EE | $F151 R EE | $EE5D R EE |
|  7 |  | $F152 R EE | $F152 R EE | $EE5E R EE |
|  8 |  | $FFEE R EE | $EEEE R EE | $EEEE R EF |
|  9 |  | $FFFF R EE | $F153 R EE | $EEEE W EF |
| 10 |  | $FFFF R EE | $F153 R EE | $EEEE W F0 |
| 11 |  | $FFFF R EE | $F153 R EE | $EE5F R EE |
| 12 |  | $FFFF R EE | $F153 R EE | $EE60 R EE |
| 13 |  | $F153 R EE | $F153 R EE | $EE61 R EE |
| 14 |  | $F154 R EE | $F154 R EE | $EEEE R F0 |
| 15 |  | $F155 R EE | $F155 R EE | $EEEE W F0 |

(* = rows inside the checked window (cyc < 6) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 6; R65Cx2 commits one row later):
- new6502 : $F151 1C 58 25 C6 B2
- v2nmos  : $F151 1C 58 25 C6 B2
- R65Cx2  : $EE5E 1C 58 25 C6 B2
- suite   : $F150 $1C $FE $25 $C6 $A0 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $F150; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 5
- v2nmos  : 5
- R65Cx2  : 3

**First bus READ at the core-agreed final PC** ($F151; the suite expected $F150):
- new6502 : 6
- v2nmos  : 6
- R65Cx2  : 4

- new6502 vs suite : cyc3: addr 004C != expected 0071; cyc3: rw W != expected read; cyc3: data EB != expected 77; cyc4: addr 004C != expected 0071; cyc4: data E9 != expected 77; cyc5: addr F150 != expected 0071; cyc5: rw R != expected write; cyc5: data 5C != expected EE; final pc F151 != F150; final a  58 != FE; final p B2 != A0 (masked); complete: row 6 not a fetch at final pc F150 (got F151/R); final ram[004C] = 233 != 235; final ram[0071] = 119 != 238
- v2nmos  vs suite : cyc3: addr 004C != expected 0071; cyc3: rw W != expected read; cyc3: data EB != expected 77; cyc4: addr 004C != expected 0071; cyc4: data E9 != expected 77; cyc5: addr F150 != expected 0071; cyc5: rw R != expected write; cyc5: data 5C != expected EE; final pc F151 != F150; final a  58 != FE; final p B2 != A0 (masked); complete: row 6 not a fetch at final pc F150 (got F151/R); final ram[004C] = 233 != 235; final ram[0071] = 119 != 238
- R65Cx2  vs suite : cyc2: addr F14F != expected 004C; cyc2: data 4C != expected EB; cyc3: addr F150 != expected 0071; cyc3: data 5C != expected 77; cyc4: addr F151 != expected 0071; cyc4: rw R != expected write; cyc4: data EE != expected 77; cyc4: illegal access F151; cyc5: addr EE5C != expected 0071; cyc5: rw R != expected write; cyc5: illegal access EE5C; final pc EE5E != F150; final a  58 != FE; final p B2 != A0 (masked); complete: row 6 not a fetch at final pc F150 (got EE5D/R); final ram[0071] = 119 != 238

**Expert verdict / reference (fill in):** ______________________________

### op 1e — evidence line 1534 — representative for op 1e

**Initial state**  PC=$12A6  SP=$2F  A=$DF  X=$77  Y=$F1  P=$E5
**RAM**          $12A6=1E   $12A7=F7   $12A8=AA   $AA6E=A3   $AB6E=91   $12A9=5C
**Program**      1E F7 AA 5C (at PC)
**Suite model**  7 cycles, final PC=$12A9 A=$DF P=$65

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $12A6 R 1E | $12A6 R 1E | $12A6 R 1E | $12A6 R 1E |
|  1 | $12A7 R F7 | $12A7 R F7 | $12A7 R F7 | $12A7 R F7 |
|  2 | $12A8 R AA | $12A8 R AA | $12A8 R AA | $12A8 R AA |
|  3 | $AA6E R A3 | $AA6E R A3 | $AA6E R A3 | $AA6E R A3 |
|  4 | $AB6E R 91 | $AB6E R 91 | $AB6E R 91 | $AB6E R 91 |
|  5 | $AB6E W 91 | $AB6E W 91 | $AB6E W 91 | $AB6E W 91 |
|  6 | $AB6E W 22 | $AB6E W 22 | $AB6E W 22 | $AB6E W 22 |
|  7 | (next fetch @ $12A9) | $12A9 R 5C | $12A9 R 5C | $12A9 R 5C |
|  8 |  | $12AA R EE | $12AA R EE | $12AA R EE |
|  9 |  | $12AB R EE | $12AB R EE | $12AB R EE |
| 10 |  | $FFEE R EE | $EEEE R EE | $EEEE R EF |
| 11 |  | $FFFF R EE | $12AC R EE | $12AC R EE |
| 12 |  | $FFFF R EE | $12AC R EE | $12AD R EE |
| 13 |  | $FFFF R EE | $12AC R EE | $12AE R EE |
| 14 |  | $FFFF R EE | $12AC R EE | $EEEE R EF |
| 15 |  | $12AC R EE | $12AC R EE | $EEEE W EF |

(* = rows inside the checked window (cyc < 7) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 7; R65Cx2 commits one row later):
- new6502 : $12A9 2F DF 77 F1 75
- v2nmos  : $12A9 2F DF 77 F1 75
- R65Cx2  : $12A9 2F DF 77 F1 75
- suite   : $12A9 $2F $DF $77 $F1 $65 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $12A9; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 7
- v2nmos  : 7
- R65Cx2  : 7

- new6502 vs suite : PASS
- v2nmos  vs suite : PASS
- R65Cx2  vs suite : PASS

**Expert verdict / reference (fill in):** ______________________________

### op 25 — evidence line 1857 — representative for op 25

**Initial state**  PC=$FB59  SP=$1F  A=$42  X=$D1  Y=$67  P=$27
**RAM**          $FB59=25   $FB5A=A1   $FB5B=5C   $00A1=E6
**Program**      25 A1 5C (at PC)
**Suite model**  3 cycles, final PC=$FB5B A=$42 P=$25

| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |
|----|-------------|---------|--------|-----------------|
|  0 | $FB59 R 25 | $FB59 R 25 | $FB59 R 25 | $FB59 R 25 |
|  1 | $FB5A R A1 | $FB5A R A1 | $FB5A R A1 | $FB5A R A1 |
|  2 | $00A1 R E6 | $00A1 R E6 | $00A1 R E6 | $00A1 R E6 |
|  3 | (next fetch @ $FB5B) | $FB5B R 5C | $FB5B R 5C | $FB5B R 5C |
|  4 |  | $FB5C R EE | $FB5C R EE | $FB5C R EE |
|  5 |  | $FB5D R EE | $FB5D R EE | $FB5D R EE |
|  6 |  | $FFEE R EE | $EEEE R EE | $EEEE R EF |
|  7 |  | $FFFF R EE | $FB5E R EE | $FB5E R EE |
|  8 |  | $FFFF R EE | $FB5E R EE | $FB5F R EE |
|  9 |  | $FFFF R EE | $FB5E R EE | $FB60 R EE |
| 10 |  | $FFFF R EE | $FB5E R EE | $EEEE R EF |
| 11 |  | $FB5E R EE | $FB5E R EE | $EEEE W EF |
| 12 |  | $FB5F R EE | $FB5F R EE | $EEEE W F0 |
| 13 |  | $FB60 R EE | $FB60 R EE | $FB61 R EE |
| 14 |  | $EEEE R EE | $EEEE R EE | $FB62 R EE |
| 15 |  | $EEEE W EE | $EEEE W EE | $FB63 R EE |

(* = rows inside the checked window (cyc < 3) where at least one core differs from the other core or from the suite model)

**State at the row the suite samples** (row 3; R65Cx2 commits one row later):
- new6502 : $FB5B 1F 42 D1 67 35
- v2nmos  : $FB5B 1F 42 D1 67 35
- R65Cx2  : $FB5B 1F 42 D1 67 35
- suite   : $FB5B $1F $42 $D1 $67 $25 (expected final PC SP A X Y P)

**First bus READ at the suite expected final PC** (first row where the bus reads $FB5B; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):
- new6502 : 3
- v2nmos  : 3
- R65Cx2  : 3

- new6502 vs suite : PASS
- v2nmos  vs suite : PASS
- R65Cx2  vs suite : PASS

**Expert verdict / reference (fill in):** ______________________________

_Remaining trailing-only tests (line → op, PC):_
- line 3871: op 4d (PC=$853C)
- line 4017: op 50 (PC=$8501)
- line 4029: op 50 (PC=$58CE)
- line 4345: op 56 (PC=$DA31)
- line 4500: op 5a (PC=$F637)
- line 4515: op 5a (PC=$7EBA)
- line 4692: op 5d (PC=$625E)
- line 5214: op 68 (PC=$BD6C)
- line 5575: op 6f (PC=$D233)
- line 5610: op 70 (PC=$2D34)
- line 5617: op 70 (PC=$5D13)
- line 5629: op 70 (PC=$FACE)
- line 5963: op 77 (PC=$E83E)
- line 6014: op 78 (PC=$8678)
- line 6632: op 84 (PC=$99AD)
- line 6882: op 89 (PC=$4DAD)
- line 7621: op 98 (PC=$63FD)
- line 8367: op a7 (PC=$6E54)
- line 8502: op aa (PC=$5797)
- line 8521: op aa (PC=$4B2E)
- line 8616: op ac (PC=$0847)
- line 10661: op d5 (PC=$2B99)
- line 11105: op de (PC=$EAB7)
- line 11410: op e4 (PC=$D092)
- line 11533: op e6 (PC=$EBB6)
- line 11606: op e8 (PC=$ED10)
- line 11943: op ee (PC=$6461)
- line 12746: op fe (PC=$FAAC)

## 6. Questions for the expert (the 10 adjudications)

For each opcode below, the real MOS 6502 behavior needed to settle this:

1. **$5C** — instruction width? cycle count? bus activity during the
   settle cycles (addresses, R/W, data)? PC update and flag updates?
   Three models on the table. new6502: 3-byte, $FFbb + $FFFF×4, next
   fetch starts at row 8, PC+3, no flag change. v2nmos + R65Cx2: 3-byte,
   computed $PPbb phantom; R65Cx2’s next fetch starts at row 4 (4 bus
   cycles; exact on the 27 4-cycle tests, 1 row early on the 23 5-cycle
   tests), while v2nmos holds the next PC from row 4 and its next fetch
   also starts at row 8. The suite: 4 or 5 cycles (5 when the (a,X)
   effective address crosses a page) with its own phantom addresses.
   $5C is a documented NMOS 6502 opcode (SBC (a,X)), so the perfect6502
   netlist run settles this directly.
2-10. **23, 3b, 63, 73, 7b, 9b, c3, db, f3** — instruction width? PC
   update? flag updates? settle-cycle bus activity? (Both cores agree: 4-byte,
   PC+4, A/X/Y/SP unchanged, status bit 4 (break) set on 8 of 9 (op 9b: P
   unchanged); they differ only on the first settle address in the nine edge
   cases. The suite claims a 2-byte op with write-back — confirm which model
   is right on MOS silicon. All nine are documented NMOS 6502 opcodes
   (SLO/SRE family), so the perfect6502 netlist run settles these too.)
11. **$80 (and $7C)** — the “silent branch” case: the suite’s 6502 model
   for $80 is a 2-byte NOP (2 cycles, final PC = PC+2). Every core under
   test passes all 50 $80 tests, yet every core decodes $80 as a 2-byte
   relative branch (WDC BRA; target = PC+2+signed(offset)) and continues
   execution at the branch target. The suite never sees this: row ncyc is
   a coincidental READ of PC+2 (the expected next-fetch address) and the
   register snapshot at row ncyc is still pre-branch. Questions: (a) is
   $80 a 2-byte NOP on real NMOS 6502 silicon, as the suite models? (b)
   if so, new6502 — despite being NMOS-specialized — still carries the
   65C02 BRA decode for it. (c) same class of question for $7C (JMP
   (abs,X) on W65C02): all five cores fail 50/50 of its tests against
   the suite’s 6502-subset model, which matches no core — the NMOS
   silicon behavior for $7C is exactly what the perfect6502 run (or a
   silicon capture) must settle.)

Each test’s exact starting state (PC/SP/A/X/Y/P, RAM, program bytes) is in
§3-§5, so a real MOS 6502 + logic analyzer (capture A0-A15, RW, PHI1/PHI2,
16 cycles) can reproduce every case directly.

Acceptable references, best first: (a) **perfect6502** — the
transistor-level NMOS 6502 netlist simulation (extracted from Visual6502):
the best non-hardware oracle for NMOS bus cycles, RMW writes, and
undocumented opcodes; running it on these exact tests directly answers
questions 1–10; (b) the netlist the RTL was derived from, simulated on
these exact tests; (c) silicon capture on a machine with a genuine MOS
6502 (Apple II/II Plus, C64/6510, Atari 8-bit, VIC-20); (d) documentation
that actually covers these opcodes on MOS silicon (note: the W65C02S and
Rockwell 65C02 datasheets document their own chips, not MOS 6502 undefined
behavior); (e) the suite’s models are reconstructions and match no core
here — they are a floor, not a reference. Secondary triangulation for
vendor-semantic questions: MAME m6502 and vrEmu6502 (standard/WDC/Rockwell
models).

## 7. How to return answers

Per test, per cycle: `$addr R|W $data`, 16 rows, in the evidence line
format (`R <idx> <bus0> <regs0><bus1> …` — 7-char bus tokens
<addr4><R/W><data2>, 14-char register snapshots <pc4><sp2><a2><x2><y2><p2>).
The existing harness (module_tests/cpu_65c02) compares such traces
mechanically against the suite and the cores.

---
_Generated by build/new6502_diff_doc.py from retained evidence only;_
_all class characterizations re-verified mechanically 2026-09-03._

## 8. Adjudication by the perfect6502 netlist simulation (2026-09-03, appended post-generation)

Reference (a) of section 7 was executed: the perfect6502 NMOS netlist was
simulated by the v5.1 oracle on the same 50-test seed=1 MOS-suite samples
(12796 tests; sweep retained at
`oracle/sweep_6502_oracle_results_full.txt`). Full adjudication report with
row-level evidence for every question:
**`build/new6502_netlist_adjudication.md`** (reproducible via
`python build/netlist_adjudication.py`; pure analysis, no re-simulation).

Outcome of the 11 questions (netlist = silicon-side reference; netlist P is
unobservable in this build, so flag updates - e.g. the break bit - are NOT
adjudicated):

| question | verdict |
|---|---|
| 1 ($5C) | **netlist = suite**: real (a,X) effective-address read (wrong-page dummy on the 23 page-cross tests), next fetch exactly at row ncyc, 50/50 byte-exact. All three cores' settle models are wrong; new6502's next fetch is 3-4 rows late (row 8). |
| 2-10 ($23/$3B/$63/$73/$7B/$9B/$C3/$DB/$F3) | **structure: netlist = suite** - in-window bus (addr/R-W/cycle count) matches the suite on all 450 sampled tests; the RMW write-back at the effective address is real netlist activity. Both Verilog cores pass 0/50 on all nine ops, which refutes the "broken-reference file" (BROKEN64) label for these ops: the cores' 4-byte/PC+4/phantom model is the divergence, not the suite. A update: the netlist (and both cores) leave A unchanged; the suite's A model modifies A (non-standard; +1/+/-0x80 write-data tails). |
| 11a ($80) | **netlist = 2-byte NOP = suite** (next fetch at row 2, 50/50). |
| 11b (new6502 $80) | new6502 keeps the 65C02 BRA decode and executes it; invisible inside the 2-cycle window (both cores pass 50/50) but semantically divergent from this netlist. |
| 11c ($7C) | **netlist = suite's MOS 3-byte model** (next fetch exactly at ncyc, 50/50). All three cores' `JMP (abs,X)` is the 65C02 decode; the V2_VERDICT "expected 65C02-vs-MOS decode divergence" is now silicon-confirmed on the MOS side. |

Deployment note: the MiSTer target is ST2204 (65C02); in the WDC_MODE=1
deployment configuration the cores' $80/$7C decodes are vendor behavior and
the MOS-suite failures on them are expected. This adjudication concerns the
MOS 6502 side (WDC_MODE=0 / new6502), where the netlist is the reference.

_Appended by hand on 2026-09-03; the generator `new6502_diff_doc.py` does not
emit this section - re-appending is required after any regeneration._

_Appended 2026-09-04 - T1 three-way silicon arbitration join (pure analysis,
no simulation): **`build/new6502_three_way_join.md`** (reproducible via
`python build/three_way_join.py`), with the T3 seed-2 robustness section in
section 8 of that report. Headline results over the 4827 MOS both-fail
tests: C1 (netlist passes the suite P-exempt; suite row silicon-faithful,
core-vs-silicon divergence confirmed) = 3246; C2 (final A: netlist = v2nmos
= golden != suite; suite A model outlier) = 88; C3 (netlist trace ~= v2nmos,
A agrees, != suite) = 15; C5 (A matches suite; bus/PC/cycle model differs)
= 688; C6 (three-way divergence, no two references share final A) = 789.
Premise check: 12799/12800 index-aligned (single golden row-0 prelude
artifact, idx 1507); v2nmos row-0 post-state = suite initial state on
12800/12800; the golden TB's row-N register snapshot is the PRE-state of row
N (spec initial-state load lands during row 0), which is exactly what the
campaign's golden final_offset=1 convention compensates for - the retained
golden sweep is therefore the current suite's tests with correct initial
state from row 1 onward, and the sweep-header-vs-compare() pass delta
(8273/7869 vs 7973/7749) is expected-final regeneration between suite
generations, not test misalignment. T3 (12 arbitration opcodes re-run at
seed 2): all six 50/50 verdict opcodes ($5C/$7C/$80/$9B/$C3/$DB) reproduce
50/50; the six A-model opcodes keep their structural netlist=suite verdict
with per-sample A-model residue. The stale "same index != same test" NOTE in
`oracle/run_oracle.py` has been updated with this empirical resolution._