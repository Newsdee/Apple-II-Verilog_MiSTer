# A3r - opcode relevance ranking: run the ranking (runner)

- status: review
- kind: runner
- owner: run_board.bat
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

- 2026-09-04 (pi-session): gate cleared - A3t built and tested
  build/op_relevance_ranking.py (mini run retained; full run executed
  once in-session to validate end-to-end: md5
  42fae9c1ea8f8149553cc08d60ecaf95). Offline runner: re-run reproduces
  build/op_relevance_ranking.md byte-for-byte.

- 2026-09-04: run_board.bat started runner (python3 build/op_relevance_ranking.py)

- 2026-09-04: run_board.bat finished runner, exit 0; artifacts + determinism re-run per task protocol; log handoff/logs/A3r.log
