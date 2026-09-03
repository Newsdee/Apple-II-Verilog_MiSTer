# perfect6502 netlist adjudication of the 10+1 open questions

Adjudicates `new6502_diff_documentation.md` (NMOS-mode difference study
new6502 vs v2nmos) using reference (a) from its own "acceptable
references" list: the transistor-level NMOS 6502 netlist (perfect6502,
extracted from Visual6502), simulated on the exact same 50-test seed=1
samples of the 65x02 "6502" (MOS) suite by the v5.1 oracle
(`oracle/p6502_oracle.c`, retained sweep `oracle/sweep_6502_oracle_results_full.txt`).

Mechanical basis: same test selection across all five references (zero
bus0-address mismatches over the 12796 common idx); the netlist sweep
is in the exact evidence-line format the diff document asks for in its
section 7. Netlist metrics: `compare(t, g, final_offset=-1)` + P-exempt
final-state check (netlist P readout is an A alias, unobservable) +
signature-gated late-commit rescue (A/X/Y/SP commit at row ncyc for the
B=1-row family). Core metrics: `compare(t, g, 0)` new6502/v2nmos,
`compare(t, g, 1)` R65Cx2 (offsets per the campaign checker).

## 1. Verdict table (questions 1-11)

| op | suite (MOS) model | new6502 | v2nmos | R65Cx2 | **netlist (silicon)** | verdict |
|----|-------------------|---------|--------|--------|----------------------|---------|
| $5c | SBC (a,X), 4/5 cyc (page-cross = 5), EA reads | 0/50 | 0/50 | 0/50 | **50/50 P-exempt** | **netlist = suite** (50/50, byte-exact in window). All three cores wrong on settle bus. |
| $80 | 2-byte NOP (2 cyc, PC+2) | 50/50 | 50/50 | 50/50 | **50/50 P-exempt** | **netlist = suite** (2-byte NOP; next fetch at row 2, 50/50). Cores' BRA = 65C02 carry-over (invisible in window, semantically divergent). |
| $7c | 3-byte MOS op, 4/5 cyc, PC+3 | 0/50 | 0/50 | 0/50 | **50/50 P-exempt** | **netlist = suite** (MOS 3-byte model, 50/50). All three cores' JMP (abs,X) = 65C02 decode. |
| $23 | 8 cyc, 2-byte fetch, settle reads + RMW write-back at EA, PC+2, A updated | 0/50 | 0/50 | 0/50 | **29/50 P-exempt** | **structure: netlist = suite** (width/PC/settle/RMW rows byte-exact). A update: netlist (and both cores) leave A unchanged; suite modifies A. |
| $3b | 7 cyc, 3-byte fetch, RMW write-back at EA, PC+3, A updated | 0/50 | 0/50 | 0/50 | **26/50 P-exempt** | same as $23 (3-byte form) |
| $63 | 8 cyc, 2-byte fetch, settle reads + RMW at EA, PC+2, A updated | 0/50 | 0/50 | 0/50 | **15/50 P-exempt** | same as $23 (3-byte form) |
| $73 | 8 cyc, 2-byte fetch, settle reads + RMW at EA, PC+2, A updated | 0/50 | 0/50 | 0/50 | **10/50 P-exempt** | same as $23 (3-byte form) |
| $7b | 7 cyc, 3-byte fetch, RMW at EA, PC+3, A updated | 0/50 | 0/50 | 0/50 | **14/50 P-exempt** | same as $23 (3-byte form) |
| $9b | 5 cyc, 3-byte fetch, RMW at EA, PC+3, A unchanged | 0/50 | 0/50 | 0/50 | **50/50 P-exempt** | **netlist = suite, all rows, 50/50**. Cores 0/50. |
| $c3 | 8 cyc, 2-byte fetch, settle reads + RMW at EA, PC+2, A unchanged | 0/50 | 0/50 | 0/50 | **50/50 P-exempt** | **netlist = suite, all rows, 50/50**. Cores 0/50. |
| $db | 7 cyc, 3-byte fetch, RMW at EA, PC+3, A unchanged | 0/50 | 0/50 | 0/50 | **50/50 P-exempt** | **netlist = suite, all rows, 50/50**. Cores 0/50. |
| $f3 | 8 cyc, 2-byte fetch, settle reads + RMW at EA, PC+2, A updated | 0/50 | 0/50 | 0/50 | **17/50 P-exempt** | same as $23 (3-byte form) |

Residuals on the A-update ops ($23/$3B/$63/$73/$7B/$F3): the netlist
passes the in-window bus of every test but keeps A unchanged while the
suite's A model modifies A (residual final-A and write-data +/-1/+/-0x80
class). The netlist is the standard-behavior side; the suite's A model is
the non-standard one (see `oracle/oracle_phase12_findings.md` for the
$E9/SBC evidence of the same class).

## 2. Question 1 - $5C: the netlist executes a real SBC (a,X)

Mechanical rule (same as the diff document): next-fetch start = first row
with a READ at the suite final PC. Verified on all 50 tests:

| reference | next-fetch start row | result |
|-----------|---------------------|--------|
| suite cycle model | ncyc = 4 on 27 tests, 5 on 23 tests (5 = (a,X) page-cross) | - |
| **netlist** | row 4 on the 27 4-cycle tests, row 5 on the 23 5-cycle tests | **exactly at ncyc, 50/50** |
| new6502 | row 8 on all 50 | 3-4 rows late |
| v2nmos | row 4 on all 50 | exact on the 27, 1 row early on the 23 |
| R65Cx2 | row 4 on all 50 | same as v2nmos |

Settle-row (row 3) address - the row the diff document classifies:

- new6502: `$FFbb` (page FF, low operand byte) - its claim;
- v2nmos = R65Cx2: computed `$PPbb` (page = high operand byte) - their claim;
- **netlist: the real effective address (a+X)** - on the 23 page-cross tests a
  wrong-page dummy read (low byte of (a,X), page of a), then the true EA read
  one row later - textbook NMOS (a,X) page-cross behavior.

Byte-exact evidence (suite vs netlist, rows 0-4; all OK):

### op 5c - evidence line 4600 (ncyc=5, final PC=$240E)

| row | suite | netlist | v2nmos | new6502 |
|-----|-------|---------|--------|---------|
| 0 | 240B R 5C | $240B R 5C | $240B R 5C | $240B R 5C |
| 1 | 240C R E7 | $240C R E7 | $240C R E7 | $240C R E7 |
| 2 | 240D R 78 | $240D R 78 | $240D R 78 | $240D R 78 |
| 3 | 7824 R 65 | $7824 R 65 | $78E7 R EE | $FFE7 R EE |
| 4 | 7924 R 2B | $7924 R 2B | $240E R EE | $FFFF R EE |
| 5 | (next fetch @ $240E) | $240E R EE | $240E R EE | $FFFF R EE |
| 6 | - | $240F R EE | $240E R EE | $FFFF R EE |
| 7 | - | $2410 R EE | $240E R EE | $FFFF R EE |

### op 5c - evidence line 4601 (ncyc=4, final PC=$9287)

| row | suite | netlist | v2nmos | new6502 |
|-----|-------|---------|--------|---------|
| 0 | 9284 R 5C | $9284 R 5C | $9284 R 5C | $9284 R 5C |
| 1 | 9285 R 56 | $9285 R 56 | $9285 R 56 | $9285 R 56 |
| 2 | 9286 R CF | $9286 R CF | $9286 R CF | $9286 R CF |
| 3 | CFE4 R AD | $CFE4 R AD | $CF56 R EE | $FF56 R EE |
| 4 | (next fetch @ $9287) | $9287 R EE | $9287 R EE | $FFFF R EE |
| 5 | - | $9288 R EE | $9287 R EE | $FFFF R EE |
| 6 | - | $9289 R EE | $9287 R EE | $FFFF R EE |
| 7 | - | $EEEE R EE | $9287 R EE | $FFFF R EE |

Idx 4600 is the page-cross test: operand a=$78E7, X=$3D, (a,X)=$7924.
Netlist row 3 = $7824 (wrong-page dummy), row 4 = $7924 (true EA read);
v2nmos never reads the true EA and starts the next fetch at row 4 while the
netlist (and the suite) take row 5. Idx 4601 (no cross): netlist row 3 =
$CFE4 = (a+X) read; v2nmos row 3 = $CF56 = base a (no X).

**Adjudication:** the netlist matches the suite's cycle model byte-exactly
on all 50 tests. The diff document's "three models on the table" resolves to
two: (suite = netlist) vs (all three cores). new6502's `$FFbb`+`$FFFF`/row-8
model is not what this netlist does; v2nmos/R65Cx2's `$PPbb` model is also
not the netlist's row-3/row-4 activity (the netlist reads the true EA).

## 3. Questions 2-10 - the nine ops ($23/$3B/$63/$73/$7B/$9B/$C3/$DB/$F3)

Suite model summary (from the 50-test samples):

| op | ncyc | final-PC delta | suite writes A | netlist P-exempt | new6502 | v2nmos | R65Cx2 |
|----|------|----------------|----------------|------------------|---------|--------|--------|
| $23 | 8 | +2 | 49/50 | 29/50 | 0/50 | 0/50 | 0/50 |
| $3b | 7 | +3 | 47/50 | 26/50 | 0/50 | 0/50 | 0/50 |
| $63 | 8 | +2 | 50/50 | 15/50 | 0/50 | 0/50 | 0/50 |
| $73 | 8 | +2 | 50/50 | 10/50 | 0/50 | 0/50 | 0/50 |
| $7b | 7 | +3 | 50/50 | 14/50 | 0/50 | 0/50 | 0/50 |
| $9b | 5 | +3 | 0/50 | 50/50 | 0/50 | 0/50 | 0/50 |
| $c3 | 8 | +2 | 0/50 | 50/50 | 0/50 | 0/50 | 0/50 |
| $db | 7 | +3 | 0/50 | 50/50 | 0/50 | 0/50 | 0/50 |
| $f3 | 8 | +2 | 50/50 | 17/50 | 0/50 | 0/50 | 0/50 |

The netlist's in-window bus (address, R/W, cycle count) matches the suite
**100% on all 450 sampled tests** (the oracle's per-cycle address/R-W
checks for these ops, incl. the settle reads and the EA RMW addresses); the
write DATA matches except the +1/+/-0x80 A-model class on the A-update ops
(120 of the 300 tests on $23/$3B/$63/$73/$7B/$F3, see section 1). The
cores pass **0/50** on every one of them. The suite model is therefore
silicon-faithful in structure: 2/3-byte fetch, PC+2/+3, settle reads
(including zero-page/vector-area reads), an RMW write-back at the effective
address, next fetch exactly at row ncyc. Both Verilog cores' model
(4-byte fetch, PC+4, phantom holds, no EA RMW) is wrong against this netlist
on all nine ops.

Byte-exact row evidence for the nine section-4 edge lines (rows 0-7; the
next fetch is row 8/7/5 as per ncyc):

### op 23 - evidence line 1754 (suite ncyc=8)

| row | suite | netlist | new6502 | v2nmos |
|-----|-------|---------|---------|--------|
| 0 | 9649 R 23 | $9649 R 23 | $9649 R 23 | $9649 R 23 |
| 1 | 964A R 5C | $964A R 5C | $964A R 5C | $964A R 5C |
| 2 | 005C R 78 | $005C R 78 | $964B R E8 | $964B R E8 |
| 3 | 00FF R 2C | $00FF R 2C | $964C R EE | $964C R EE |
| 4 | 0000 R BD | $0000 R BD | $FFE8 R EE | $EEE8 R EE |
| 5 | BD2C R C4 | $BD2C R C4 | $FFFF R EE | $964D R EE |
| 6 | BD2C W C4 | $BD2C W C4 | $FFFF R EE | $964D R EE |
| 7 | BD2C W 88 | $BD2C W 88 | $FFFF R EE | $964D R EE |

### op 3b - evidence line 2971 (suite ncyc=7)

| row | suite | netlist | new6502 | v2nmos |
|-----|-------|---------|---------|--------|
| 0 | 0A0A R 3B | $0A0A R 3B | $0A0A R 3B | $0A0A R 3B |
| 1 | 0A0B R 5C | $0A0B R 5C | $0A0B R 5C | $0A0B R 5C |
| 2 | 0A0C R 72 | $0A0C R 72 | $0A0C R 72 | $0A0C R 72 |
| 3 | 7247 R B2 | $7247 R B2 | $0A0D R CD | $0A0D R CD |
| 4 | 7347 R 4F | $7347 R 4F | $FF72 R EE | $CD72 R EE |
| 5 | 7347 W 4F | $7347 W 4F | $FFFF R EE | $0A0E R EE |
| 6 | 7347 W 9E | $7347 W 9E | $FFFF R EE | $0A0E R EE |
| 7 | (next fetch @ $0A0D) | $0A0D R CD | $FFFF R EE | $0A0E R EE |

### op 63 - evidence line 4983 (suite ncyc=8)

| row | suite | netlist | new6502 | v2nmos |
|-----|-------|---------|---------|--------|
| 0 | 2F61 R 63 | $2F61 R 63 | $2F61 R 63 | $2F61 R 63 |
| 1 | 2F62 R 9B | $2F62 R 9B | $2F62 R 9B | $2F62 R 9B |
| 2 | 009B R 7E | $009B R 7E | $2F63 R 5C | $2F63 R 5C |
| 3 | 00CB R 00 | $00CB R 00 | $2F64 R EE | $2F64 R EE |
| 4 | 00CC R FA | $00CC R FA | $2F65 R EE | $2F65 R EE |
| 5 | FA00 R FF | $FA00 R FF | $FFEE R EE | $EEEE R EE |
| 6 | FA00 W FF | $FA00 W FF | $FFFF R EE | $2F66 R EE |
| 7 | FA00 W FF | $FA00 W 7F | $FFFF R EE | $2F66 R EE |

### op 73 - evidence line 5781 (suite ncyc=8)

| row | suite | netlist | new6502 | v2nmos |
|-----|-------|---------|---------|--------|
| 0 | A137 R 73 | $A137 R 73 | $A137 R 73 | $A137 R 73 |
| 1 | A138 R 5C | $A138 R 5C | $A138 R 5C | $A138 R 5C |
| 2 | 005C R AF | $005C R AF | $A139 R 43 | $A139 R 43 |
| 3 | 005D R CA | $005D R CA | $A13A R EE | $A13A R EE |
| 4 | CAA9 R 2B | $CAA9 R 2B | $FF43 R EE | $EE43 R EE |
| 5 | CBA9 R 0D | $CBA9 R 0D | $FFFF R EE | $A13B R EE |
| 6 | CBA9 W 0D | $CBA9 W 0D | $FFFF R EE | $A13B R EE |
| 7 | CBA9 W 06 | $CBA9 W 06 | $FFFF R EE | $A13B R EE |

### op 7b - evidence line 6190 (suite ncyc=7)

| row | suite | netlist | new6502 | v2nmos |
|-----|-------|---------|---------|--------|
| 0 | 33C2 R 7B | $33C2 R 7B | $33C2 R 7B | $33C2 R 7B |
| 1 | 33C3 R 5C | $33C3 R 5C | $33C3 R 5C | $33C3 R 5C |
| 2 | 33C4 R 63 | $33C4 R 63 | $33C4 R 63 | $33C4 R 63 |
| 3 | 638A R BA | $638A R BA | $33C5 R 1F | $33C5 R 1F |
| 4 | 638A R BA | $638A R BA | $FF63 R EE | $1F63 R EE |
| 5 | 638A W BA | $638A W BA | $FFFF R EE | $33C6 R EE |
| 6 | 638A W 5D | $638A W 5D | $FFFF R EE | $33C6 R EE |
| 7 | (next fetch @ $33C5) | $33C5 R 1F | $FFFF R EE | $33C6 R EE |

### op 9b - evidence line 7778 (suite ncyc=5)

| row | suite | netlist | new6502 | v2nmos |
|-----|-------|---------|---------|--------|
| 0 | 8802 R 9B | $8802 R 9B | $8802 R 9B | $8802 R 9B |
| 1 | 8803 R 5C | $8803 R 5C | $8803 R 5C | $8803 R 5C |
| 2 | 8804 R E2 | $8804 R E2 | $8804 R E2 | $8804 R E2 |
| 3 | E26C R C8 | $E26C R C8 | $8805 R EE | $8805 R EE |
| 4 | E26C W 02 | $E26C W 02 | $FFE2 R EE | $EEE2 R EE |
| 5 | (next fetch @ $8805) | $8805 R EE | $FFFF R EE | $8806 R EE |
| 6 | - | $8806 R EE | $FFFF R EE | $8806 R EE |
| 7 | - | $8807 R EE | $FFFF R EE | $8806 R EE |

### op c3 - evidence line 9795 (suite ncyc=8)

| row | suite | netlist | new6502 | v2nmos |
|-----|-------|---------|---------|--------|
| 0 | D8BF R C3 | $D8BF R C3 | $D8BF R C3 | $D8BF R C3 |
| 1 | D8C0 R 5C | $D8C0 R 5C | $D8C0 R 5C | $D8C0 R 5C |
| 2 | 005C R C6 | $005C R C6 | $D8C1 R 2A | $D8C1 R 2A |
| 3 | 0068 R CD | $0068 R CD | $D8C2 R EE | $D8C2 R EE |
| 4 | 0069 R 88 | $0069 R 88 | $FF2A R EE | $EE2A R EE |
| 5 | 88CD R 8D | $88CD R 8D | $FFFF R EE | $D8C3 R EE |
| 6 | 88CD W 8D | $88CD W 8D | $FFFF R EE | $D8C3 R EE |
| 7 | 88CD W 8C | $88CD W 8C | $FFFF R EE | $D8C3 R EE |

### op db - evidence line 10978 (suite ncyc=7)

| row | suite | netlist | new6502 | v2nmos |
|-----|-------|---------|---------|--------|
| 0 | B19E R DB | $B19E R DB | $B19E R DB | $B19E R DB |
| 1 | B19F R 5C | $B19F R 5C | $B19F R 5C | $B19F R 5C |
| 2 | B1A0 R 61 | $B1A0 R 61 | $B19F R 5C | $B19F R 5C |
| 3 | 619B R 36 | $619B R 36 | $B19F R 5C | $B19F R 5C |
| 4 | 619B R 36 | $619B R 36 | $B1A0 R 61 | $B1A0 R 61 |
| 5 | 619B W 36 | $619B W 36 | $B1A1 R 2C | $B1A1 R 2C |
| 6 | 619B W 35 | $619B W 35 | $FF61 R EE | $2C61 R EE |
| 7 | (next fetch @ $B1A1) | $B1A1 R 2C | $FFFF R EE | $B1A2 R EE |

### op f3 - evidence line 12157 (suite ncyc=8)

| row | suite | netlist | new6502 | v2nmos |
|-----|-------|---------|---------|--------|
| 0 | F13B R F3 | $F13B R F3 | $F13B R F3 | $F13B R F3 |
| 1 | F13C R 5C | $F13C R 5C | $F13C R 5C | $F13C R 5C |
| 2 | 005C R 43 | $005C R 43 | $F13D R 3A | $F13D R 3A |
| 3 | 005D R 72 | $005D R 72 | $F13E R EE | $F13E R EE |
| 4 | 7219 R 7D | $7219 R 7D | $FF3A R EE | $EE3A R EE |
| 5 | 7319 R BA | $7319 R BA | $FFFF R EE | $F13F R EE |
| 6 | 7319 W BA | $7319 W BA | $FFFF R EE | $F13F R EE |
| 7 | 7319 W BB | $7319 W BB | $FFFF R EE | $F13F R EE |

On the A-update ops ($23/$3B/$63/$73/$7B/$F3) the netlist leaves A
unchanged (write-back rows write the read byte and/or the A value; the
final A register is untouched), while the suite's model modifies A - the
residual P-exempt failures on those ops (21-40 of 50 tests each) are
exactly this A-model class (+1/+/-0x80 write-data tails). $9B/$C3/$DB
pass the netlist 50/50, all rows. Flag updates (the cores' "status bit 4
(break)" claim) are NOT adjudicated: the netlist P readout is unobservable in
this build (A alias); only the internal flags that drive branches are
observable, and they are functional (branch-direction verification in
`oracle/oracle_phase12_findings.md` section 4).

## 4. Question 11 - $80 and $7C

$80: the suite model is a 2-byte NOP (ncyc=2, PC+2; 50/50 tests). Netlist:
next fetch at row 2 (PC+2) on **all 50** - the netlist executes $80 as a
2-byte NOP, byte-exactly the suite. Both Verilog cores decode $80 as the
65C02 relative branch and execute past the branch target; this is invisible
inside the 2-cycle window (both cores pass 50/50, as does the netlist), so
the suite cannot see it - but the netlist's row-2 next-fetch settles the
semantics: on this netlist $80 is a NOP. Answers the document's question
11(a): yes, 2-byte NOP; 11(b): new6502, despite being NMOS-specialized,
diverges from this netlist on $80 (it keeps the 65C02 BRA decode).

$7C: the suite model is the 3-byte MOS op (ncyc=4 on 20 tests, 5 on 30,
PC+3). Netlist: next fetch exactly at ncyc on **all 50** - the netlist
executes the suite's MOS model, not the 65C02 `JMP (abs,X)` that all three
cores implement (all cores 0/50 on the MOS suite). The v2 verdict's
"expected 65C02-vs-MOS decode divergence" is now silicon-confirmed: the
MOS side of the question resolves to the suite's model.

## 5. Caveats

- **P unobservable**: netlist p0..p7 are combinational A-alias taps
  (P = (A&0x80)|0x34|(A==0?0x02:0)); every final-P check is exempted.
  Flag-update adjudications (e.g. the break bit on the nine ops) are out of
  scope; the P-exempt metric is the netlist-valid one.
- **Late-commit convention**: for the B=1-row family the netlist commits
  A/X/Y/SP at row ncyc (one row after PC); final-state comparison uses the
  signature-gated `late_commit_rescue()` (values match the suite; only the
  commit row differs). PC is never rescued.
- **2-state simulation, harness RAM model**: the netlist has no RAM; bus
  reads (including the settle/vector-area rows) are driven by the oracle's
  external-RAM model from the test's initial RAM. The settle reads are
  real netlist bus activity, but their silicon mechanism is not asserted
  here - only that the netlist does them and the suite models them.
- **16-row window, 50-test seed=1 sample**: a reproducible sample, not an
  exhausted space (wording per V2_VERDICT section 6).
- **The netlist is a build**: perfect6502 (Visual6502-extracted). It
  adjudicates "what THIS netlist does", which for NMOS bus behavior is the
  best non-hardware reference available; silicon capture remains the final
  arbiter for the rows marked here as netlist-specific.

## 6. Implications

1. **The MOS suite is silicon-faithful on all 11 adjudicated opcodes** (bus
   structure, cycle counts, PC updates, EA RMW rows), except its A-update
   model on $23/$3B/$63/$73/$7B/$F3 (netlist leaves A unchanged). The
   "broken-reference file" label from `mos_bothfail_decomp.py` (BROKEN64) is
   refuted for all nine ops in question 2-10: the netlist passes their
   structural models; the cores' 0/50 is a genuine core-vs-silicon
   divergence, not suite garbage. (The broader BROKEN64 set is not covered
   by this adjudication.)
2. **new6502 ("netlist derived") diverges from this netlist on all 11
   questions** - $5C settle model, the nine ops' width/PC/RMW model, and
   the $80/$7C decodes. If it was derived from this netlist, the derivation
   is wrong for these opcodes; if from another source, the provenance should
   be checked. Its NMOS-specialized $80/$7C behavior is 65C02, not NMOS.
3. **v2nmos (WDC_MODE=0 "NMOS bus-convention mode")** does not replicate
   this netlist on $5C (no true-EA read on page-cross; `$PPbb` phantom;
   early next-fetch) or on the nine ops (phantom/PC+4 model). If the stated
   purpose of WDC_MODE=0 is MOS 6502 replication, these are the divergence
   classes to fix (or the mode's scope should be documented as a hand
   model, not a netlist replica).
4. **Deployment note**: the MiSTer target CPU is ST2204 (65C02). In the
   deployment configuration (WDC_MODE=1) the cores' $80-BRA and $7C-JMP
   (abs,X) decodes are the vendor behavior and the MOS-suite failures on
   them are expected. This adjudication concerns the MOS 6502 side (NMOS
   mode / new6502), where the netlist - not the vendor datasheets - is the
   reference.

## 7. Reproduction

```
cd E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/module_tests/cpu_65c02
python build/netlist_adjudication.py
```

Inputs (retained, untouched): `oracle/sweep_6502_oracle_results_full.txt`
(12796 R lines, 4 vector-area-collision specs skipped: idx 2786 op $37,
5490 op $6D, 6749 op $86, 12060 op $F1), the three `evidence/sweep_6502_*`
core files, the suite definitions, and `oracle/OV51_NOTES.md` +
`oracle/oracle_phase12_findings.md` for the oracle method and the P proof.

---
_Generated by build/netlist_adjudication.py from retained evidence only._
_All tables mechanically computed 2026-09-03._
