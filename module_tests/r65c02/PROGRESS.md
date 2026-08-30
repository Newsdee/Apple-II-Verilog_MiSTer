# R65C02 Equivalence Test — Progress (self-contained, post-compaction)

Last updated: **EQUIVALENCE PASS** — full pipeline (regenerate → Verilator →
GHDL → compare) is green: 83,906 fields compared, 0 mismatches, coverage
61/61, both interrupt handlers entered, ERRPARK never touched.
Re-run anytime with `module_tests/r65c02/run_equivalence.ps1` (or
`-CompareOnly` to skip the rebuilds).

## 1. Task & status

Build + run the R65C02 cycle-equivalence harness in this directory: Verilog
candidate (`../../rtl/R65Cx2.sv`, module `R65C02`) vs VHDL golden
(`../../../Apple-II_MiSTer_newsdee/rtl/R65Cx2.vhd`, entity `R65C02`), cycle-by-
cycle, directed 6502 test program, GHDL + Verilator, PowerShell CSV comparator
with coverage gates. Model: `module_tests/t65/`.

STATUS: **COMPLETE (v1)**. Both TBs written and passing. Known-good result:
```
R65C02 EQUIVALENCE PASS rows=4000 fields_compared=83906 skipped_meta=4094 coverage=61/61
  skip_breakdown: A=8 P_B=4000 P_C=18 P_N=8 P_V=16 P_Z=8 SP=14 X=10 Y=12
```
All skips are expected metas (P_B permanent; the rest are reset-window values
before the prologue defines them).

## 2. Environment / commands (verified)

- Repo root: `E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer`
- Tools: `$ghdl='C:\msys64\ucrt64\bin\ghdl.exe'`; `$verilator='C:\msys64\ucrt64\bin\verilator_bin.exe'`
- **Every bash invocation is a fresh shell** — export per command:
  `export PATH='/c/msys64/usr/bin:/c/msys64/ucrt64/bin:'$PATH VERILATOR_ROOT='C:/msys64/ucrt64/share/verilator' MAKE='C:\msys64\ucrt64\bin\mingw32-make.exe' SHELL='/c/msys64/usr/bin/sh.exe'`
  (PATH prefix is REQUIRED: without ucrt64/bin on PATH, g++ can't find cc1plus and the Verilator build fails; without it at sim time the exe exits 127.)
- No `-j4`. No `python3`. **Perl IS available** (`perl` on PATH).
- Build (from repo root):
  `'C:\msys64\ucrt64\bin\verilator_bin.exe' --binary --timing -Wno-fatal --top-module r65c02_verilog_tb --Mdir module_tests/r65c02/build/verilog rtl/R65Cx2.sv module_tests/r65c02/r65c02_verilog_tb.sv`
  (`--timing` required for `always #5 clk`). Pre-existing warnings: CASEINCOMPLETE at R65Cx2.sv:1195/1273 (not new).
- Run: `./module_tests/r65c02/build/verilog/Vr65c02_verilog_tb.exe +TOTAL=4000 +IRQPULSE=730 +NMIPULSE=768` (CWD = repo root; plusargs per §8).
- If an interrupted build leaves zero-byte `Vr65c02_verilog_tb__ALL.cpp`, delete before rebuilding.
- File encoding note: `rtl/R65Cx2.sv` uses CRLF; Perl regexes must handle `\r`.

## 3. DUT facts (verified by reading + empirical probes)

Ports (Verilog): `reset` (input, ACTIVE-LOW, async via `negedge reset` on I/D
only), `clk`, `enable` (tie 1), `nmi_n`, `irq_n`, `di[7:0]`, `dout[7:0]`
(output; VHDL calls it `do`), `addr[15:0]` (**OUTPUT** = live myAddr — the
harness reads mem at this address, not at PC), `nwe` (registered output;
commit writes at posedge where nwe==0), `sync` (output = 1 during opcodeFetch
cycle — use for executed-opcode coverage!), `sync_irq` (= irqActive),
`Regs[63:0]`.

**Regs layout (VERIFIED from source line 1320):**
```
Regs = {PC[15:0], 8'b00000001, S[7:0], N,V,R,B,D,I,Z,C, Y[7:0], X[7:0], A[7:0]}
```
PC=[63:48], const=[47:40], S=[39:32], P byte=[31:24] (N=31,V=30,R=29,B=28,
D=27,I=26,Z=25,C=24 — standard 6502 status order), Y=[23:16], X=[15:8], A=[7:0].

**CORRECTED:** the VHDL entity DOES have a 64-bit `Regs` port
(`std_logic_vector(63 downto 0)`), driven at R65Cx2.vhd:1522 with the IDENTICAL
layout to Verilog — the VHDL TB reads it directly, no hierarchical access.

- Reset state: PC=$FFFC, SP undefined ('U'/0), I,D async-reset; B never driven.
- **Boot = standard vector boot**: phantom reset fetch reads mem[$FFFC]/mem[$FFFD]
  as a JMP-abs operand; lands at {hi,lo}. Vectors FFFC/FFFD→$0500 work (verified in sim).
- **INTERRUPTS WORK**: IRQ masked by I; NMI edge-latched, NOT I-gated; both
  BRK-like injection at next fetch, consume 2 bytes; vectors $FFFE/$FFFF (IRQ),
  $FFFA/$FFFB (NMI). Handlers return via explicit `JMP` (never RTI).
- **RTI non-standard** (jump M16[PC+1], status from M[PC+2], C/Z swap, stack
  untouched) — EXCLUDED v1 with BRK.
- PLP/PHP force B set and PLP swaps C/Z → re-establish flags after PHP/PLP or
  interrupt windows. R bit combinational always 1.
- JMP (abs,X) [7C] non-standard; v1 forces X=0 at use.
- Opcode table FULLY DECODED: 44-bit entries [43:40]=AXYS,[39:34]=NVDIZC,
  [33:18]=addrMode,[17:10]=aluIn,[9:0]=aluMode; `analyze.pl` verified 256/256.
  Census in `build/opcode_census.txt` (positional). Do NOT re-reconcile table
  localparam indices — empirical behavior is authoritative.

## 4. Files

| File | State |
|---|---|
| `PLAN.md` | original plan (superseded where this differs) |
| `PROGRESS.md` | this file |
| `build/analyze.pl`, `build/table_dump.txt`, `build/opcode_census.txt` | DONE (table decode, 256/256) |
| `build/probe_tb.sv`, `build/dump_tb.sv`, `build/dbg*.pl` | probe artifacts (keep) |
| `build/gen_mem_array.pl` | generator — WORKING (this session: many fixes, §12) |
| `build/program_table.pl` | directed program v1 — branch block redesigned THIS SESSION |
| `build/r65_mem_init.hex` | 4096 lines × 16 bytes — VERIFIED (vectors at FFFA-FFFF correct) |
| `build/r65_mem_array.vhd` | VHDL package MEM_INIT — generated, tail verified |
| `build/program_listing.md`, `build/coverage_report.txt` | generated; coverage OK (61 mnemonics) |
| `r65c02_verilog_tb.sv` | WRITTEN + BUILDS + RUNS (see §8) |
| `r65c02_vhdl_tb.vhd` | WRITTEN — analyzes/elaborates/runs under GHDL (no wrappers needed: single phase, generics for TOTAL/pulses/TRACE_FILE) |
| `run_equivalence.ps1` | WRITTEN — full pipeline + comparator with all gates; PASSING |
| `build/verilog_trace.csv`, `build/vhdl_trace.csv` | generated by the runner (22 columns each) |

## 5. Generator architecture (current, working)

- Loads `%OP` map (mnemonic[.mode]→opcode; incl. INX=E8 DEX=CA INY=C8 DEY=88
  STZ.ax=9E JMP.i=6C JMP.ix=7C), `%SIZE` per mode, `%SIZE_KEY=('JMP.i'=>3,'JMP.ix'=>3)`.
- `eval`s program_table.pl (engine must declare `our @PROG; our %FIXED;` first).
- `norm($e)`: comment-only → `()` (NOT undef — list context!); leading flat
  label pairs `['L1:'=>'','L2:'=>'', MN, OPS...]` — **multi-label supported**
  (added this session); HASH-ref form kept for legacy.
- Pass 1: labels→$addr at $pc; pc via `insn_size()` (branches=2, implied=1,
  JSR=3 no-suffix, PADTO returns `[$target]` arrayref).
- Pass 2: branches compute SIGNED offset (`die if $raw < -128 || $raw > 127;`
  then `& 0xFF`) — negative offsets supported (backward sentinels); non-branches
  via shared `encode_insn($pcx,$mn,@o)`.
- `encode_insn`: resolve_key (explicit .mode wins; JSR special; infer #xx→.i,
  $xx→.z, other→.a). Mode-aware operand encoding:
  - abs family (a,ax,ay,iy + JMP.i/JMP.ix/JSR): 2 bytes ($xxxx or label)
  - immediate (i): #xx, #lo(LABEL), #hi(LABEL)
  - zp family (z,zx,zy,ix): 1 byte (#xx or low byte of $xxxx)
- Handlers: `%FIXED{IRQH|NMIH}` at fixed addresses via same `encode_insn`.
- Vectors: FFFC/FFFD→0500, FFFE/FFFF→IRQH($1020), FFFA/FFFB→NMIH($1030).
- Image = pattern `($i + int($i/16) + 60) % 256` + overrides.
- Hex emit: 16 bytes/line, newline AFTER each group (no leading blank line).
- `put()` collision diagnostics name both writers via `$putcur`.
- Coverage gate: 61 mnemonics (census non-NOP minus BRK/RTI) used ≥1×.

## 6. Program v1 layout (as of this session)

- Base $0500; overflow guard $0A00. Program ends ~$0912 (330 instructions).
- Prologue: LDA #$05/LDX #$FD/LDY #$A0/TXS/CLV/CLC + flag sets; ALU imm ops;
  transfers (TAX/TAY/TXA/TYA/TSX); INX/DEX/INY/DEY; re-establish flags
  (LDA #7F/SEC) at ~$0520.
- **Branch block (REDESIGNED this session — shared sentinel pattern):**
  - taken test: `BR t_lbl` +5 over [NOP NOP sentinel]; wrong not-take walks into sentinel → ERRPARK.
  - not-taken test: BACKWARD `BR s_lbl` to an EARLIER sentinel slot; wrong take jumps back → ERRPARK; correct path falls through 5 NOPs.
  - Each sentinel `JMP.a ERRPARK` (S1..S8) serves both a taken-test trap and one or two later not-taken targets (S7 carries two labels via multi-label line).
  - Pairs: BEQ (Z), BNE (Z), BCS+BCC (C), BMI+BPL (N), BMI-not-taken, BVS+BVC (V via `LDA #7F/SEC/ADC #01` overflow → V=1 N=1 Z=0 C=0).
  - Layout per pair: `[flag setup] BR t_lbl,NOP,NOP / [s_lbl:]JMP ERRPARK / t_lbl:[next setup] / BR s_lbl,NOP×5`.
- Stack block: PHA/PLA, PHX/PLX, PHY/PLY, PHP/PLP+re-establish, JSR SUB1/RTS.
- Memory-read block: LDA all 8 modes, LDX/LDY modes, CMP/CPX/CPY ×(imm,zp,abs), BIT ×(imm,zp,abs).
- Memory-write block: TSB/TRB, ASL/ROL/LSR/ROR & INC/DEC ×(A,zp,zpX,abs,absX), STA remaining, STX/STY, STZ (z,zx,a,ax).
- Pointer seeding ≈$05D8-$060X: $00E0/$00E1→$0A40, $00E8/$00E9→TJMP2, $00F0/$00F1→TJMP1, $0A50/$0A51→$0A60.
- Tail: TJMP1/TJMP2 markers → JMP($00F0)[6C] → JMP($00E8,X)[7C] (X=0) → SLED1=32×EA (IRQ window) → CONT1=16×EA (NMI window) → TAIL2 → PADTO $08FD → **page-crossing BRA at $08FD: [NOP×3 crossing $08FF/$0900] sentinel JMP ERRPARK @ $0902, PAGE2 @ $0905 (offset +6)** → PARK ($0908) / ERRPARK ($090B) self-loops; SUB1 at $090E.
- Handlers (%FIXED): IRQH $1020 = LDA #$22/STA $90/JMP CONT1; NMIH $1030 = LDA #$33/STA $91/JMP TAIL2.

## 7. Trace schema (22 columns — both TBs MUST match)

`CYCLE,PC,SP,P_N,P_V,P_R,P_B,P_D,P_I,P_Z,P_C,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N,SYNC,SYNC_IRQ`

- P emitted per-bit (B always skipped by comparator; SP meta until TXS).
- SYNC=1 marks opcode-fetch cycles → DI at SYNC gives executed opcodes for the coverage gate.
- RW column = nwe (0 = write cycle).

## 8. Verilog TB (r65c02_verilog_tb.sv) — WRITTEN, BUILDS, RUNS

- Single 64K `reg [7:0] mem[0:65535]` + `$readmemh("module_tests/r65c02/build/r65_mem_init.hex")` (CWD = repo root).
- `assign di = mem[addr];` (addr is the DUT's live address output).
- Write commit: `always @(posedge clk) if (sim_go && !nwe) mem[addr] <= dout;` — `sim_go` guard prevents pre-stimulus writes.
- `always #5 clk = ~clk;` (needs --timing).
- reset_sig low for cycles 0..3 (mirrors t65's 4-cycle window), then high.
- Plusargs: `+IRQPULSE=<n>` / `+NMIPULSE=<n>` (**8-cycle-wide** low windows starting at cycle n, 0=disabled — see the calibration note below for why 1 cycle is not enough), `+TOTAL=<n>` (default 4000).
- Emits 22-column CSV to `module_tests/r65c02/build/verilog_trace.csv`.

**Calibration COMPLETE (pulses enabled):**
- `+IRQPULSE=730 +NMIPULSE=768 +TOTAL=4000` → ERRPARK=0, IRQH@739, NMIH@778,
  first PARK@1789.
- Flow verified: boot $0500 → prologue → branch block (all taken/not-taken
  correct) → stack/JSR-SUB1 → memory blocks → LDX #00 → JMP.i $00F0 [6C] →
  TJMP1 (LDA #$B1) → JMP.ix $00E8 [7C] → TJMP2 (LDA #$B2) → SLED1 ($06D7,
  entered c708) → IRQ pulse c730-737 → IRQH ($1020, c739: LDA #$22/STA $90/
  JMP CONT1) → CONT1 ($06F5) → NMI pulse c768-775 → NMIH ($1030, c778: LDA
  #$33/STA $91/JMP TAIL2) → TAIL2 ($070B, c786) → NOP pad → page-crossing BRA
  $08FD → PAGE2 → PARK ($0908).
- **Pulses are 8-cycle-wide windows** (TB): the DUT samples nmi_n/irq_n only
  when `nextCpuCycle != cycleBranchTaken && != opcodeFetch` (R65Cx2.sv:815-822),
  so a 1-cycle pulse can be missed depending on instruction phase. IRQ worked
  at 1 cycle (lucky phase); NMI did not → widened both to 8.
- Key addresses (current image): SLED1=$06D7, CONT1=$06F5, TAIL2=$070B,
  PARK=$0908, ERRPARK=$090B, SUB1=$090E, IRQH=$1020, NMIH=$1030.
- TXS at $0506 (cycle ~11) → SP defined from there.

## 9. VHDL side (DONE) — GHDL gotchas that cost real time

**R65Cx2.vhd must be analyzed with `--std=93 -C`, NOT `--std=08`:**
- std=08 fails on the opcode table: "type of element is ambiguous" on every
  one of the 256 aggregate entries (string-literal & unsigned concatenation
  assigned into an `unsigned(0 to 43)` element — GHDL 6.0 can't resolve it in
  08 mode). std=93 accepts it.
- std=93 then rejects em-dashes inside comments → add `-C` (disable comment
  syntax checking).
- This is the first time this file has ever been analyzed by GHDL (Quartus
  never needed it).

**VHDL-93 restrictions hit in the TB (all worked around locally, DUT untouched):**
- No `all_defined` in 1164 → local `all_def()` helper; used to guard the mem
  read mux and write commit against meta addresses during reset.
- No `to_hstring` (that's the 2008 numeric_std) and no
  std_logic_vector→unsigned conversion expressions → local `hex_of()`
  (case-on-4-bit-slice; meta bytes emit `?`). Nibble slice of a DOWNTO vector
  moves from v'left DOWNWARD: `v(v'left-4*(i-1) downto v'left-4*(i-1)-3)`.
- No `std.env` → final `wait;` + runner passes `--stop-time=45000ns`.
- No implicit std_logic_vector↔unsigned assignment → explicit casts
  (`unsigned(mem(...))`, `std_logic_vector(do_sig)`).
- For-loop bound must be literal/attribute → precompute `variable n` first.
- Conditional signal assignments in sequential statements are 2008-only →
  if/else.

**Runner:** `run_equivalence.ps1` (this dir). Steps: perl generator → Verilator
build+run (`+TOTAL=4000 +IRQPULSE=730 +NMIPULSE=768`) → GHDL analyze/elab/run
(workdir `build/vhdl`, wiped each run) → compare. `-CompareOnly` skips 1–3.
GHDL run CWD must be the repo root (TRACE_FILE is relative).

**Comparator gates (all implemented and passing):**
- G_ROWS/G_HEADER: equal row counts + identical header.
- G_FIELDS: zero mismatches among compared fields. Field-level meta-skip:
  skip when EITHER side contains U/X/W/Z/-/?; P_B column always skipped.
  (This is what made the pass possible — B is permanently 'U' in VHDL while
  its row is otherwise defined.)
- G_MINCOMPARED: ≥75000 fields actually compared (anti empty-pass).
- G_COVERAGE: all 61 required mnemonics executed in the golden trace on REAL
  opcode fetches only — rows with SYNC=1 AND SYNC_IRQ=0 (interrupt-injected
  fetches carry SYNC_IRQ=1 and bogus DI; counting them would pollute coverage).
- G_ERRPARK: PC≠$090B in either trace. G_PARK: PC=$0908 reached in both.
- G_IRQ/G_NMI: $1020 / $1030 entered in both traces (pulse response proof).

**PowerShell gotcha (bug 22):** `Is-Meta $a -or Is-Meta $b` passes EVERYTHING
after the first name as arguments to that one function call — only $a was
tested. Must write `(Is-Meta $a) -or (Is-Meta $b)`.

## 10. Next steps (if v2 is wanted)

1. v2: add BRK + RTI tests (RTI per the non-standard semantics: jump to
   M16[PC+1], status from M[PC+2], C/Z swap, stack untouched). Update the
   required-mnemonic set and the coverage gate accordingly.
2. Optional: extend the program beyond 4000 cycles / add a second phase with
   different pulse timings to shake out timing-dependent divergence.
3. This harness does NOT prove FPGA behavior — Quartus compile + hardware
   remain separate validation (see AGENTS.md).

## 11. Standing rules

- Preserve user changes, generated artifacts, ROM data, mixed EOLs; no commits
  unless asked; no long Quartus compiles unless asked.
- Verilator is a required validation step for any RTL change (AGENTS.md).
- Generated files live under `module_tests/r65c02/build/`.

## 12. Session bug log (fixed — do not re-debug)

1. `insn_size` PADTO returned scalarref; pass 1 dereferenced as array → return `[$t]`.
2. Missing `_s` sentinel labels for 7 not-taken branches → added.
3. Bare `JSR LABEL` → resolver made 'JSR.a' (unknown) → special-case 'JSR', size 3.
4. `JMP.i`/`JMP.ix` sized 2 via mode table but are 3-byte → `%SIZE_KEY` override.
5. `STA.z '$00E0'`: 4-hex operand matched abs pattern → mode-aware operand encoding (zp takes low byte).
6. 'STZ.ax' missing from %OP → added 0x9E.
7. `JMP.i '$00F0'` hit immediate branch → explicit abs-family check before mode dispatch.
8. Handler assembler was a naive duplicate encoder → shared `encode_insn`.
9. **BRANCH PATTERN STRUCTURAL BUG (found via sim run #1):** not-taken tests used a FORWARD branch to a sentinel placed after the 5 fall-through NOPs — so the correct fall-through path itself walked into the sentinel → ERRPARK. First attempt (sentinel immediately before the branch) also failed: it sat on the linear flow of the preceding taken test. **Final fix:** each taken test's sentinel slot doubles as the backward target for a later not-taken test (shared sentinels S1..S8; multi-label table lines via extended `norm()`); assembler now accepts signed offsets (-128..+127).
10. Hex emit: `print $hf;` prints `$_` (undef) not a newline → `print $hf "\n"`; also moved newline to after each 16-byte group (was emitting a leading blank line).
11. `$off` masking warning in pass-2 branch block → removed leftover `my $off;`.
12. Edit-tool note: my edit calls occasionally get corrupted with `\r` sequences when I include long/multi-line oldText — if an edit fails "Could not find the exact text", re-check the file with sed/grep and retry with a smaller unique anchor.
13. Wrote C-style `;` comments in program_table.pl (a Perl file) → syntax errors on eval; fixed all 8 to `#`. Reminder: the table is Perl — only `#` comments.
14. Tail restructure: TJMP1/TJMP2 were `JMP PARK`/`JMP SLED1` markers placed BEFORE the indirect-jump tests, so landing at TJMP1 parked immediately and JMP.ix/SLED1/CONT1/BRA-PAGE2 were unreachable. New layout: LDX #00 → JMP.i $00F0 → [NOP NOP sentinel jmp1_s] → TJMP1: LDA #$B1 → JMP.ix $00E8 → [NOP NOP sentinel jmp2_s] → TJMP2: LDA #$B2 → JMP SLED1.
15. **Handlers never reached the image**: the %FIXED handler-assembly loop ran AFTER the `%mem`→`@IMG` copy, so `put()` wrote into %mem too late. Moved the handler loop before image build. (Vectors had been written from the same %FIXED hash and were always correct — that's how I caught it.)
16. 1-cycle NMI pulse missed: DUT edge-sampler is gated on `nextCpuCycle != cycleBranchTaken && != opcodeFetch` (R65Cx2.sv:815-822) → widened TB pulses to 8-cycle windows.
17. Hex line-number math: line N of r65_mem_init.hex covers $(N-1)*16; $1020 is line 259, $FFFE-$FFFF is line 4096 (I twice miscounted and chased ghosts).
18. GHDL std=08 "type of element is ambiguous" on R65Cx2.vhd's opcode table → use `--std=93 -C` (see §9). First-ever GHDL analysis of this file.
19. Verilog $fdisplay had 21 format specifiers for 22 columns → sync_irq was silently dropped (Verilator ignores extra args, no error). Traces looked fine at a glance; caught by the column-count check. Always count specifiers against the header.
20. hex_of nibble indexing on a downto vector: I wrote `v'left + 4*(i-1)` (upward) → out-of-range overflow at i=4 (mcode "overflow detected" at runtime, not analyze time). Downto vectors index DOWNWARD from v'left.
21. PowerShell function-call parsing: bare `Func $a -or Func $b` binds all tokens to the first call. Parenthesize each call.
