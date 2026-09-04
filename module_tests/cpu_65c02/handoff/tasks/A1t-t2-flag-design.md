# A1t - T2 branch-probe: design + build the deterministic runner

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
