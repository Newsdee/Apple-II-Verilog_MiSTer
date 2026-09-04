# A2r - v2 sequence evidence: run all items (runner)

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
