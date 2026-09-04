# A4 - FFFF stray-read mechanism trace (thinking; small)

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
## Safety (all workers)
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
