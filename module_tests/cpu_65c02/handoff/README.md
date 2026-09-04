# cpu_65c02 handoff board

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
- C tasks: ONE writer on rtl/new_cpu_v2/ at a time (sequential lanes or
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
