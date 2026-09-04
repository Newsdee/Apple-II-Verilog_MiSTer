#!/usr/bin/env python3
"""Generate the cpu_65c02 handoff kanban board.

Emits:
  handoff/README.md
  handoff/tasks/*.md
  handoff/BOARD.md (index regenerated from task-file status headers)

Pure text generation; no simulation, no other file access.

Task kinds:
  runner   - the task body is one deterministic command; no judgment;
             any executor (shell, cron, minimal agent) can run it.
  thinking - needs agent judgment (design, RTL, interpretation).
  user     - human decision or action; agents may only do labelled prep.

The campaign pattern is thinking -> runner: a thinking task designs and
builds a deterministic script; the matching runner task just runs it.
Re-run after editing a task's status to refresh BOARD.md:

  python3 handoff/board_status.py     (thin wrapper: re-emits BOARD.md only)
  python3 handoff/gen_board.py        (full regeneration)
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
TASKS = os.path.join(HERE, 'tasks')

DATE = '2026-09-04'
CWD = 'E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/module_tests/cpu_65c02'

# ---------------------------------------------------------------------------
# task content
# ---------------------------------------------------------------------------

COMMON = '''## Safety (all workers)
- Read AGENTS.md at the workspace root first; it is the operating guide.
- Touch ONLY the paths listed under "May write". No RTL edits (C tasks
  excepted), no git commits, no unrelated cleanup, preserve line endings.
- Windows: use `python3` (MSYS2 ucrt64), not `python`. Stop any running
  Vemu.exe before Verilator rebuilds (Windows locks the linker output).
- Use disposable media copies when writes must not alter originals.
- Deterministic re-runs: every step must be reproducible from the listed
  inputs; keep seeds fixed (record any seed used).
- Report: update this task file's `updated:` field, append a dated line
  to the progress log, list artifacts. Refresh the board with
  `python3 handoff/board_status.py` when done. Do NOT hand-edit BOARD.md.

## Progress log
'''

T = {}

T['A1t-t2-flag-design.md'] = '''# A1t - T2 branch-probe: design + build the deterministic runner

- status: ready
- kind: thinking
- owner: (unset)
- created: 2026-09-04
- updated: 2026-09-04
- eta: 2-4 h
- gate: none - startable now
- parallel-safe: yes

## Goal
The netlist P readout is an A-alias (oracle/OV51_NOTES.md), so the
adjudication report could not verify flag updates. T2 makes P observable
BEHAVIOURALLY: drive P to known states via the stack (PLP), then run
branch-opcode probes and observe branch-taken vs not on the next-fetch PC
(bus-visible). THIS TASK designs the probe matrix and builds the
deterministic runner script `oracle/t2_flag_probe.py` that A1r executes.

## Context (read first)
- AGENTS.md (workspace root)
- oracle/OV51_NOTES.md - oracle v5.1 conventions (12-byte prelude,
  final_offset=-1, P-exempt emit, hex: uppercase everywhere)
- build/new6502_netlist_adjudication.md - what P-related claims are open
- oracle/run_oracle.py + oracle/p6502_oracle.c - spec format, fpe_check/
  late_commit_rescue, spec-file handling, --seed

## Inputs (read-only)
- oracle/p6502_oracle.c / p6502_oracle.exe (rebuild per OV51_NOTES command
  only if needed)
- 65x02 suite data ONLY to verify branch-op encodings/semantics; T2 specs
  are SYNTHETIC (custom spec files), not suite samples.

## Design notes
- The 8 6502 branch ops: BPL $10, BMI $30, BVC $11, BVS $31, BCS $B0,
  BCC $90, BEQ $F0, BNE $D0 (verify against the suite; do not hardcode
  from memory).
- Set P exactly: SP prelude, STA desired P byte at $01xx, LDX #xx / TXS,
  PLP. Per op: P states with the tested flag bit 0 and 1, remaining bits
  at a mid value (e.g. 0x20 base). Choose A so the A-alias
  (P=(A&0x80)|0x34|(A==0?02:0)) does not mimic the intended state on the
  OTHER bits.
- Self-check BEFORE the probe: with P set, run a sanity branch (e.g.
  BEQ/BNE against the known Z) that must pass 100%; a failed self-check
  cell is marked invalid and NOT interpreted.
- Probe: P setup + NOP + branch op with a rel offset to a distinct marker
  PC; next fetch => taken/not-taken.
- Extra matrices: D-bit (decimal ADC: 09+01 with/without C, D set via
  PLP), B-bit (JSR -> RTS, B observable via PLP) - two cases each.

## Procedure
1. Implement oracle/t2_flag_probe.py: generates the spec (retained as
   oracle/t2_flag_spec.txt), runs p6502_oracle.exe (retained sweep
   oracle/t2_flag_sweep.txt), applies the self-check gate, and writes
   build/t2_flag_probe_report.md: per-op verdict table
   ("netlist takes $Bx when F=bit" with trace-row evidence), invalid-cell
   list, and the report's own md5. The script must be deterministic
   (fixed ordering, no timestamps in the report body).
2. Prove the pipeline end-to-end on a 2-3 cell mini subset (retained log);
   do NOT run the full matrix here - that is A1r.
3. Document the full-run command in A1r.

## Acceptance
- oracle/t2_flag_probe.py exists, `python3 -m py_compile` clean, mini
  subset run retained (log in this task's progress log).
- Full matrix NOT yet run (A1r does it); report generator proven on the
  mini subset.
- Board updated (status=review when done; A1r gate note updated).

## May write
- oracle/t2_flag_probe.py, oracle/t2_flag_mini.* (mini-subset artifacts)
- this task file (status/log only)
'''

T['A1r-t2-flag-run.md'] = '''# A1r - T2 branch-probe: run the matrix (runner)

- status: blocked
- kind: runner
- owner: (unset)
- created: 2026-09-04
- updated: 2026-09-04
- eta: < 5 min (oracle sim ~1-2 min + report)
- gate: A1t done (oracle/t2_flag_probe.py exists and passed its mini run)
- parallel-safe: yes
- command: (cwd module_tests/cpu_65c02) python3 oracle/t2_flag_probe.py

## What this is
NO THINKING TASK. The body is one command; any executor (shell, cron,
minimal agent) can run it. Judgment (interpretation of deviations) happens
at review, by the thinking channel.

## Procedure
1. cd to the campaign dir; confirm A1t is review/done.
2. Run: python3 oracle/t2_flag_probe.py
3. Verify: exit 0; oracle/t2_flag_spec.txt, oracle/t2_flag_sweep.txt and
   build/t2_flag_probe_report.md exist; re-run once more and confirm the
   report md5 is identical (determinism); record both hashes in the log.
4. If exit != 0: do NOT debug; set status=blocked with the log tail and
   leave it for the thinking channel.
5. Refresh the board (python3 handoff/board_status.py); status=review.

## Acceptance
- Retained: spec, sweep, report; deterministic hash recorded.
- Board updated.

## May write
- oracle/t2_flag_{spec,sweep}.txt, build/t2_flag_probe_report.md (script outputs)
- this task file (status/log only)
'''

T['A2t-v2-seq-design.md'] = '''# A2t - v2 sequence evidence: enumerate items + build the runner

- status: ready
- kind: thinking
- owner: (unset)
- created: 2026-09-04
- updated: 2026-09-04
- eta: 1-2 h
- gate: none - startable now
- parallel-safe: yes with A1t (separate toolchains: Verilator vs gcc)

## Goal
V2_VERDICT.md section 8 left sequence-level evidence open for
new_cpu_v2. THIS TASK enumerates those exact items and builds the
deterministic runner `build/v2_seq_evidence.py` that A2r executes.

## Context (read first)
- AGENTS.md (workspace root)
- module_tests/cpu_65c02/V2_VERDICT.md section 8 (the item list - do not
  invent items), V2_HANDOVER.md
- evidence/provenance.json - binary-rebuild lesson (the WDC_MODE=1/=0 v2
  binaries once shared one exe name; NEVER reuse a shared output name)
- build/sst_verilog_v2/ - the SST TB (verFiles.dat pins sources)

## Inputs (read-only)
- rtl/cpu/wdc65c02/ (cpu_65c02.sv, cpu_alu.sv)

## Procedure
1. Enumerate the open sequence items from V2_VERDICT.md section 8; list
   them in the report intro (one line each) with a planned sequence.
2. Implement build/v2_seq_evidence.py:
   - aborts with a clear message if Vemu.exe is running (tasklist check);
   - builds the SST TB once, distinct exe name
     (Vcpu65_sst_tb_v2_seq.exe), records its SHA-256;
   - per item: minimal sequence (initial regs + program bytes), capture
     the 16-row bus+reg window in the campaign R-line format;
   - writes evidence/v2_seq_traces.txt + build/v2_sequence_evidence.md
     (per item: sequence, trace, what it proves) + sidecar
     evidence/provenance_v2_seq.json (binary sha256, item list).
     Deterministic (no timestamps in outputs).
3. Prove the pipeline on ONE item (retained mini log); do not run all
   items here - A2r does.

## Acceptance
- Script exists, py_compile clean, 1-item mini run retained.
- Item list frozen in the report intro.
- Board updated (status=review; A2r gate note).

## May write
- build/v2_seq_evidence.py, build/v2_seq_mini.* (mini artifacts)
- this task file (status/log only)
'''

T['A2r-v2-seq-run.md'] = '''# A2r - v2 sequence evidence: run all items (runner)

- status: blocked
- kind: runner
- owner: (unset)
- created: 2026-09-04
- updated: 2026-09-04
- eta: 10-30 min (Verilator build dominates)
- gate: A2t done (build/v2_seq_evidence.py passed its 1-item mini run)
- parallel-safe: yes with A1r (no shared Verilator build)
- command: (cwd module_tests/cpu_65c02) python3 build/v2_seq_evidence.py

## What this is
NO THINKING TASK. One command; any executor can run it. The script
aborts cleanly if Vemu.exe is running - in that case stop Vemu.exe and
re-run, or block with the message.

## Procedure
1. cd to the campaign dir; confirm A2t is review/done.
2. Run: python3 build/v2_seq_evidence.py
3. Verify: exit 0; evidence/v2_seq_traces.txt,
   build/v2_sequence_evidence.md, evidence/provenance_v2_seq.json exist;
   every V2_VERDICT section-8 item appears in the report with a trace or
   a documented no-evidence-needed reason; re-run once, confirm the
   traces md5 is identical (determinism; the TB build may be skipped by
   the script on the second run - record behaviour).
4. If exit != 0: do NOT debug; status=blocked with the log tail.
5. Refresh the board; status=review.

## Acceptance
- Retained traces + report + sidecar provenance; deterministic hash.
- No existing evidence file modified (new files only).
- Board updated.

## May write
- evidence/v2_seq_* (new files), evidence/provenance_v2_seq.json
- build/v2_sequence_evidence.md, build/sst_verilog_v2/ (build outputs)
- this task file (status/log only)
'''

T['A3t-op-ranking-design.md'] = '''# A3t - opcode relevance ranking: methodology + build the runner

- status: ready
- kind: thinking
- owner: (unset)
- created: 2026-09-04
- updated: 2026-09-04
- eta: 2-4 h
- gate: none - startable now
- parallel-safe: yes

## Goal
The T1 join found 4827 MOS both-fail tests across 105 opcodes (C5 688,
C6 789, plus C2/C3). Fixing all 105 is not the goal. Rank the ops by how
likely real Apple II software actually executes them, so the user can
pick a bounded fix list (input for B3). THIS TASK fixes the methodology
and builds the deterministic runner `build/op_relevance_ranking.py`
that A3r executes.

## Context (read first)
- AGENTS.md (workspace root)
- build/new6502_three_way_join.md section 5 (the per-opcode population)
- module_tests/cpu_65c02/FINAL_VERDICT.md, V2_VERDICT.md (what
  both-fail means; which cores are in scope)
- disks/ (Apple-II-Verilog_MiSTer root) - Total Replay v5.2 HD and other
  retained images; Apple-II_MiSTer_newsdee/rtl/roms/ for ROM images

## Procedure
1. Methodology (document in the report):
   - source images: Total Replay HD (locate the system/monitor code
     region; if boundaries are unknown, histogram image-wide and label
     confidence "image-wide"), other disks/ images, Apple II ROM;
   - metric: static opcode histogram (byte frequency); a dynamic pass
     (Verilator opcode log) is OPTIONAL - only if cheap, else SKIP and
     say so (static is the deliverable);
   - ranking: (real-code hits desc, C5+C6 count desc, op asc);
   - labels: fix now / fix later / document as expected divergence /
     drop, with a one-line justification rule each.
2. Implement build/op_relevance_ranking.py: reads the 105-op list with
   C5/C6 counts (from the join script/output - keep it reproducible),
   histograms the images (image sha256 recorded BEFORE and AFTER opening
   - proves read-only), cross-references, and writes
   build/op_relevance_ranking.md (full ranked table + methodology).
   Deterministic.
3. Prove the pipeline on ONE image region (mini log retained).

## Acceptance
- Script exists, py_compile clean, mini run retained.
- All 105 ops classified in the output schema; every "fix now" candidate
  justified by a static hit in named software.
- Board updated (status=review; A3r gate note; B3 gate note).

## May write
- build/op_relevance_ranking.py, build/op_ranking_mini.* (mini artifacts)
- this task file (status/log only)
'''

T['A3r-op-ranking-run.md'] = '''# A3r - opcode relevance ranking: run the ranking (runner)

- status: blocked
- kind: runner
- owner: (unset)
- created: 2026-09-04
- updated: 2026-09-04
- eta: < 5 min
- gate: A3t done (build/op_relevance_ranking.py passed its mini run)
- parallel-safe: yes
- command: (cwd module_tests/cpu_65c02) python3 build/op_relevance_ranking.py

## What this is
NO THINKING TASK. One command; any executor can run it. The ranked table
is the input for the user's B3 fix-policy decision.

## Procedure
1. cd to the campaign dir; confirm A3t is review/done.
2. Run: python3 build/op_relevance_ranking.py
3. Verify: exit 0; build/op_relevance_ranking.md exists; all 105 ops
   present; image sha256 before/after match (read-only proof); re-run,
   confirm md5 identical; record hashes.
4. If exit != 0: do NOT debug; status=blocked with the log tail.
5. Refresh the board; status=review; note "B3 input ready".

## Acceptance
- Retained ranked table; deterministic hash; read-only image proof.
- Board updated.

## May write
- build/op_relevance_ranking.md (script output)
- this task file (status/log only)
'''

T['A4-ffff-forensics.md'] = '''# A4 - FFFF stray-read mechanism trace (thinking; small)

- status: backlog
- kind: thinking
- owner: (unset)
- created: 2026-09-04
- updated: 2026-09-04
- eta: 1-2 h
- gate: A1r done (shares the oracle toolchain conventions; not a hard
  dependency)
- parallel-safe: yes

## Goal
The 12-op "row-11 FFFF family" from the Phase 2 findings: on certain
illegal ops the netlist fetches at $FFFF one row before the suite model's
next fetch (netlist pc = suite+1). Characterize the mechanism (stray read
vs real fetch vs reset-vector poll) so the findings doc can label it
correctly.

## Context (read first)
- oracle/OV51_NOTES.md, oracle/oracle_phase12_findings.md (the FFFF
  family description)
- build/new6502_netlist_adjudication.md (what is already adjudicated)

## Procedure (thinking; the run step is one command)
1. Pick 3 ops from the family (spread across the 12); implement a small
   variant script oracle/ffff_trace.py (do NOT modify the v5.1 oracle
   itself) that re-runs those idx values and dumps full row detail
   (addr/data/rw per row, suite-model cycle marks, netlist PC state per
   row).
2. RUN: python3 oracle/ffff_trace.py (retained output).
3. THINK: per op, identify the FFFF read's position relative to the
   instruction's real cycles; conclude stray-read (netlist fetch-pipeline
   timing artifact) vs real extra cycle, with the evidence rows.
4. Write build/ffff_forensics.md: per-op row tables + mechanism
   conclusion + the 3 sample idx values.

## Acceptance
- build/ffff_forensics.md: row tables + mechanism conclusion + idx list.
- Update oracle_phase12_findings.md ONLY if the conclusion changes an
  existing statement (otherwise point at the new file from it).
- Board updated.

## May write
- build/ffff_forensics.md, oracle/ffff_trace.py + retained outputs
- oracle/oracle_phase12_findings.md (pointer line / FFFF section only)
- this task file (status/log only)
'''

T['A5-p-node-scan.md'] = '''# A5 - locate true P storage nodes in the netlist (thinking; gated)

- status: blocked
- kind: thinking
- owner: (unset)
- created: 2026-09-04
- updated: 2026-09-04
- eta: 2-4 h
- gate: A1r result - if A1's PLP-probes observe P states reliably, this
  task is DROPPED (P observability no longer needs node access).
  Supervisor sets status=ready or dropped after reviewing A1r.
- parallel-safe: yes

## Goal
The p0..p7 readout taps are combinational A-aliases. Find whether the
netlist contains dedicated P storage (flip-flops/latches) by scanning
node values across P transitions (PLP with different P bytes) and
identifying nodes that hold P-like values across both clock phases and
change only on P writes.

## Context (read first)
- oracle/OV51_NOTES.md (the A-alias finding, p5=node 0=ground note)
- oracle/p6502_oracle.c (node access API; the netlist_sim library)

## Procedure (thinking; the scan itself is one long unattended command)
1. Enumerate candidate nodes (the node set is already exported to the
   oracle build; count and record the size).
2. Implement build/p_node_scan.py: run a P-transition sequence (PLP 0x01,
   0x40, 0x20, 0x00, NOP...) sampling ALL nodes each half-cycle for a
   bounded window; filter nodes whose value stream matches the P byte
   stream (allowing a 0-1 cycle commit lag and either polarity) on
   >=80% of samples.
3. RUN: python3 build/p_node_scan.py (may take a while - unattended step,
   log the runtime).
4. THINK: report candidate nodes (id, matched P-stream rows) or a
   negative result with filter stats.

## Acceptance
- build/p_node_scan.md: node count, filter criteria, candidates or
  negative result with stats. Retained deterministic script. If a true P
  storage node is found: note it; do NOT rewire the oracle readout in
  this task (follow-up decision).
- Board updated.

## May write
- build/p_node_scan.py, build/p_node_scan.md, oracle/pnode_* (new scripts)
- this task file (status/log only)
'''

T['B1-quartus-v2-compile.md'] = '''# B1 - Quartus map/fit/timing for new_cpu_v2 (USER-GATED)

- status: blocked
- kind: user
- owner: user
- created: 2026-09-04
- updated: 2026-09-04
- eta: agent prep ~30 min; user compile 30-60 min machine time
- gate: user go-ahead to compile (AGENTS.md: do not start long Quartus
  compiles unless the user asks)
- parallel-safe: yes (prep is read-only)

## What the agent does (prep, thinking-lite, unattended)
1. Verify the Quartus project registers rtl/cpu/wdc65c02/ sources and the
   correct top entity for the v2 build; check files.qip + Apple-II.qsf
   source sections. (This is the FPGA project
   Apple-II_MiSTer_newsdee - a SEPARATE directory; state which
   project/directory is being prepared.)
2. Emit the exact compile command (quartus_sh --flow compile ...) and
   the report checklist (map.summary, fit.summary, sta.summary, asm.rpt)
   with the baseline to compare against
   (Apple-II-Verilog_MiSTer/FPGA_LOGIC_BASELINE.md).
3. Write prep notes to build/quartus_v2_prep.md; set status=ready.

## What the user does
Run the compile; feed back the report summary; record ALM/register/M10K/
timing deltas vs the baseline + new-vs-known warnings in
build/quartus_v2_prep.md.

## Acceptance
- build/quartus_v2_prep.md: command, checklist, (after run) delta table,
  warning delta.
- No .qsf/.qip change without an explicit note of what changed and why.
- Board updated.

## May write
- build/quartus_v2_prep.md
- this task file (status/log only)
'''

T['B2-v2-rtl-commit.md'] = '''# B2 - commit final v2 RTL state (USER-GATED)

- status: blocked
- kind: user
- owner: user
- created: 2026-09-04
- updated: 2026-09-04
- eta: minutes
- gate: user decision (what exactly belongs in the v2 commit)
- parallel-safe: yes

## State
- Canonical CPU cores (2026-09-04): rtl/cpu/wdc65c02/ (v2) and
  rtl/cpu/nmos6502/ (NMOS core) - tracked.
- Superseded copies moved to UNTRACKED backup rtl/old/cpu/ (new_cpu,
  new_cpu_original, new_cpu_v2, new_6502); rtl/old/cpu/ is gitignored.
- Check `git status` for any further v2-related uncommitted files.

## What the user decides
- (2026-09-04 DECIDED: new_cpu_original/ skipped - superseded; kept as
  untracked backup under rtl/old/cpu/.) Remaining: whether a follow-up
  commit bundles the A2r evidence (sidecar provenance) - recommend yes
  if A2r is done.
- Commit message convention: match existing campaign commits
  (e.g. "cpu_65c02: ...").

## Acceptance
- A single clean commit (or explicit decision to defer), board updated
  with the commit hash in the log.

## May write
- (git only; no file edits)
- this task file (status/log only)
'''

T['B3-fix-policy.md'] = '''# B3 - NMOS-mode fix-list policy decision (USER-GATED)

- status: blocked
- kind: user
- owner: user
- created: 2026-09-04
- updated: 2026-09-04
- eta: decision ~30 min; input: A3r ranked table (+ A1r flag results)
- gate: A3r done (ranking report exists) - A1r recommended but not
  required
- parallel-safe: n/a

## Decision framing
The MOS-side divergences split into:
1. Adjudicated 12 ops (C1: netlist=suite, cores wrong on bus structure -
   build/new6502_netlist_adjudication.md): if the NMOS-mode cores should
   replicate this netlist, these are the first fix list (C01..C12).
2. C2/C3 (93 tests): suite-A-model outliers - suite-data questions, NOT
   core bugs. Do not "fix" cores for these; instead decide whether the
   suite rows deserve correction (out of scope here).
3. C5 (688): A matches suite, bus/PC/cycle model differs - core bus-model
   work, ranked by A3r.
4. C6 (789): three-way divergence - unreferenced NMOS illegal-op
   behaviour; only worth fixing if A3r shows real software hits the op.
Also: if the cores are 65C02-vendor cores with an MOS emulation mode,
most of this is expected divergence and the policy is "document scope",
not "fix".

## What the user decides
- Scope: which population (1/3/4) and which ops (from the A3r ranking)
  enter the fix list; which C tasks become ready (status ready + owner).
- Target RTL: v2 core (recommended: active core; canonical location
  rtl/cpu/wdc65c02/, version name "new_cpu_v2") vs nmos6502 core
  (canonical location rtl/cpu/nmos6502/).
- Quartus policy: one combined compile after all selected C tasks pass
  (recommended) vs per-op.

## Acceptance
- Decision recorded in this file's log: fix list (op list), target RTL,
  Quartus policy; C tasks set to ready with owners.
- Board updated.

## May write
- this task file (decision + log)
- C task files (status/owner only)
'''

# C stubs: the 12 adjudicated opcodes
C_OPS = [
    ('C01', '5c', 'SBC (abs,X) - real SBC; page-cross dummy cycle; next fetch at ncyc (suite model; netlist=suite 50/50 both seeds)'),
    ('C02', '80', '2-byte NOP (netlist=suite; cores decode BRA - semantically divergent, invisible in-window)'),
    ('C03', '7c', 'JMP (abs,X) 3-byte MOS (netlist=suite; cores decode 65C02 3-byte with different settle)'),
    ('C04', '23', '8-cyc 2-byte RMW illegal (netlist=suite structure; A preserved by netlist+cores, suite modifies A)'),
    ('C05', '3b', '7-cyc 3-byte RMW illegal (netlist=suite structure; A preserved by netlist+cores, suite modifies A)'),
    ('C06', '63', '8-cyc 2-byte RMW illegal (netlist=suite structure; A-model residue per sample)'),
    ('C07', '73', '8-cyc 2-byte RMW illegal (netlist=suite structure; A-model residue per sample)'),
    ('C08', '7b', '7-cyc 3-byte RMW illegal (netlist=suite structure; A-model residue per sample)'),
    ('C09', '9b', 'netlist=suite 50/50 (structure + bus; A preserved by netlist+cores, suite modifies A)'),
    ('C10', 'c3', 'netlist=suite 50/50 (structure + bus; A preserved by netlist+cores, suite modifies A)'),
    ('C11', 'db', 'netlist=suite 50/50 (structure + bus; A preserved by netlist+cores, suite modifies A)'),
    ('C12', 'f3', '8-cyc 2-byte RMW illegal (netlist=suite structure; A-model residue per sample)'),
]

C_TPL = '''# %s - op $%s fix: %s

- status: blocked
- kind: thinking (RTL writer)
- owner: (unset - assigned at B3)
- created: 2026-09-04
- updated: 2026-09-04
- eta: 0.5-1 d (RTL + differential + sweep slice)
- gate: B3 decision (fix list must include $%s) + one-writer rule: C tasks
  on the same target RTL run SEQUENTIALLY or in separate worktrees
- parallel-safe: no (RTL writer) - see gate

## Goal
Make the target RTL (default: rtl/cpu/wdc65c02/, per B3) reproduce the
netlist=suite behaviour for op $%s, per the adjudication.

## Expected silicon behaviour (from adjudication)
%s
Row-level evidence: build/new6502_netlist_adjudication.md (per-op
section) + oracle/sweep_6502_oracle_results_custom.txt (seed-1 12-op
sweep) + suite rows via select_tests (seed 1, 50 samples).

## Current core behaviour (re-verify at start)
- v2nmos: evidence/sweep_6502_v2nmos_results.txt rows for op $%s
  (both-fail population in build/new6502_three_way_join.md section 5).
- Capture the core's current 16-row trace for 3 sample idx values before
  touching RTL (pre-fix baseline, retained under build/c%s_pre/).

## Procedure (thinking; verification steps are runner commands)
1. Read the expected-behaviour rows; write a minimal failing sequence
   (initial regs + program) that exposes the divergence.
2. Smallest RTL edit in rtl/cpu/wdc65c02/ making the sequence match the
   netlist/suite model (bus addr/R-W rows, cycle count, final PC; A per
   the adjudication - cores preserve A; the suite's A is the outlier on
   A-update ops, so do NOT chase the suite's A).
3. RUN (runner): re-run the pre-fix sequences (must now pass); run the
   op's 50-test slice through the SST TB and through the oracle (the
   silicon check) - both must agree with the suite on bus/cycles/PC.
4. RUN (runner): full Verilator smoke test (run_verilator.bat
   --smoke-test) after the edit; confirm keyboard/vk mirrored files
   untouched (not in this task's scope).
5. Record: files changed, warning delta (new vs known), residual risk.

## Acceptance
- build/c%s_post.md: pre/post traces for the sample idx, sweep-slice
  results (50/50 on the bus/cycles/PC lines), smoke-test result, warning
  delta, files changed.
- NO full Quartus compile in this task (batched per B3 policy); done at
  differential+smoke green.
- Board updated (status=review when acceptance met).

## May write
- rtl/cpu/wdc65c02/ (the target RTL per B3)
- build/c%s_pre/, build/c%s_post/ + build/c%s_post.md
- handoff/ this task file (status/log only)

## Safety (RTL writer)
- AGENTS.md HDL rules apply (widths, signedness, reset semantics, no
  inferred latches, nonblocking in clocked logic).
- One writer per RTL: do not start while another C task is editing the
  same file; supervisor enforces via status=running.
'''

for cid, op, desc in C_OPS:
    num = cid[1:]
    T['%s-op-%s.md' % (cid, op)] = C_TPL % (cid, op, desc, op, op, desc,
                                            op, num, num, num, num, num)

README = '''# cpu_65c02 handoff board

Git-tracked kanban for the 65C02 comparison campaign. Source of truth =
the task files under tasks/ (each carries its own status header);
BOARD.md is a generated index - never hand-edit it.

## Task kinds
- kind: runner - the task body is ONE deterministic command
  (a "command:" field in the header). No judgment needed; any executor
  (shell, cron, a minimal agent, a fresh session with a one-line brief)
  can run it. Acceptance = exit 0 + retained deterministic artifacts.
  On failure: do not debug - set status=blocked with the log tail and
  leave it for the thinking channel.
- kind: thinking - needs agent judgment (probe/sequence/ranking design,
  RTL edits, interpreting results). Thinking tasks PRODUCE the
  deterministic runner scripts that runner tasks execute (the t -> r
  pattern).
- kind: user - human decision or action (Quartus compile, commits,
  policy). Agents may only do explicitly labelled prep.

## Worker protocol (any agent or human, any session)
1. Read AGENTS.md (workspace root) and the task file.
2. Confirm gate conditions; set status=running + owner + updated date.
3. Work within the task's "May write" paths only.
4. On completion: fill acceptance items, set status=review (or blocked
   with the reason), append a dated progress-log line, run
   `python3 handoff/board_status.py` to refresh BOARD.md.
5. Do not commit (supervisor/user commits). Do not edit other task files.

## Statuses
backlog -> ready -> running -> review -> done | blocked | dropped

- ready: gate satisfied, startable now.
- running: a worker is actively working (owner set).
- review: work complete, acceptance claims made, awaiting supervisor.
- done: supervisor verified acceptance (record verifier in log).
- blocked: gate not met (say which task/user decision unblocks).
- dropped: superseded (say by what).

## Execution channels
A. Thinking channel (AI agent): one async subagent workflow, one child
   per thinking task; each child brief = "Read
   E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/module_tests/cpu_65c02/handoff/tasks/<file>
   and execute it per its protocol." Supervisor (main session) polls run
   status, verifies at review, commits.
B. Run channel (dumb executor): runner tasks are one-liners (see the
   "Runner one-liners" section of BOARD.md). Run them from any shell,
   cron, or a minimal fresh session with a one-line brief. They need no
   conversation memory.
C. User channel: B cells (decisions/compiles). Agents do labelled prep
   only.
D. Offline bat (no session, no supervision): handoff/run_board.bat
   - `run_board.bat runners`      run ready runner tasks (the one-liners),
      sequential, logged to handoff/logs/<id>.log; a runner only executes
      when its gate script exists; sets its task to review (exit 0) or
      blocked (exit != 0) automatically.
   - `run_board.bat thinking`     spawn a detached `pi -p --no-session`
      worker per ready A* thinking task (own console window, ephemeral
      session; the task file is the record).
   - `run_board.bat all`          runners, then ready thinking tasks.
   - `--dry-run` previews spawns; `--force` runs runners not status=ready;
     `-- extra args` are appended to the pi command (e.g. `-- --model ...`).
   Workers never commit and never run Quartus (in the brief).

## Concurrency rules
- Thinking tasks A1t/A2t/A3t: parallel-safe (read-only on shared files,
  writes to their own artifact paths + their own task file).
- Runner tasks: parallel-safe among themselves; A2r builds Verilator -
  it aborts if Vemu.exe is running (Windows file lock).
- C tasks: ONE writer on rtl/cpu/wdc65c02/ at a time (sequential lanes or
  git worktrees). The running C task is the only one allowed status
  running.
- BOARD.md conflicts are impossible by construction (single generator).

## Crash/resume safety
Every procedure is deterministic from the task's listed inputs; a worker
restarted from scratch re-runs the same commands. Retained artifacts
(specs/sweeps/reports) plus the progress log tell a fresh worker the
resume point. Runner tasks are inherently crash-safe: re-running the
one-liner reproduces the artifacts (determinism check = md5 compare).

## Board refresh
python3 handoff/board_status.py     (regenerates BOARD.md)
python3 handoff/gen_board.py        (full regeneration from templates)
'''


def main():
    os.makedirs(TASKS, exist_ok=True)
    with open(os.path.join(HERE, 'README.md'), 'w', newline='\n') as f:
        f.write(README)
    for name, content in sorted(T.items()):
        with open(os.path.join(TASKS, name), 'w', newline='\n') as f:
            f.write(content + COMMON)
    import board_status  # noqa: E402 (same dir)
    board_status.write_board()
    print('wrote %d task files + BOARD.md' % len(T))


if __name__ == '__main__':
    main()
