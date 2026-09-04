# B2 - commit final v2 RTL state (USER-GATED)

- status: review
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
  new_cpu_v2 was the last tracked copy - it is now untracked backup.
- Check `git status` for any further v2-related uncommitted files.

## What the user decides
- Whether new_cpu_original/ belongs in the repo (reference baseline) or
  stays local; whether the v2 commit bundles the A2r evidence (sidecar
  provenance) - recommend yes if A2r is done.
- Commit message convention: match existing campaign commits
  (e.g. "cpu_65c02: ...").

## Acceptance
- A single clean commit (or explicit decision to defer), board updated
  with the commit hash in the log.

## May write
- (git only; no file edits)
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

- 2026-09-04 (pi-session): USER DECISION recorded: rtl/new_cpu_original/
  is SKIPPED - superseded by the newer versions (new_cpu_v2; it is an
  untracked pre-v2 reference copy). It will NOT be committed. Since
  rtl/new_cpu_v2/ is already tracked, no v2 RTL commit is required now;
  if A2r evidence is to be bundled, do it as a follow-up commit after
  A2r completes (per the task's own recommendation). Optional (left to
  user): add `rtl/new_cpu_original/` to .gitignore so it stops showing
  in git status - B2's May-write is git-only, so this was not done by
  the agent.
