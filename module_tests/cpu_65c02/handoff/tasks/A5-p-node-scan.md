# A5 - locate true P storage nodes in the netlist (thinking; gated)

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
