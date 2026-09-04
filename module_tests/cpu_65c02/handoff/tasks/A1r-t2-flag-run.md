# A1r - T2 branch-probe: run the matrix (runner)

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
