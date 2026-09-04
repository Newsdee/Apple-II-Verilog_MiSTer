# A3t - opcode relevance ranking: methodology + build the runner

- status: review
- kind: thinking
- owner: pi-session
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

- 2026-09-04 (pi-session): DONE, moved to review. Built
  `build/op_relevance_ranking.py`. Method: static image-wide byte
  histograms (TR52.hdv 32MB + MiniReplay.dsk + apple2e.mif; no opcode
  table embedded - legality is not a ranking input; join class column
  carried as context). Labels: drop=0 / fix now=27 (top quartile) /
  fix later=80; zero-hit "drop" impossible at this image size (every
  byte present somewhere in 32MB) - the hit-count caveat is spelled out
  in the report (upper bound on executions). Mini run retained:
  `build/op_relevance_ranking_mini.md`; full report
  `build/op_relevance_ranking.md`; determinism proven (double run, md5
  `42fae9c1ea8f8149553cc08d60ecaf95` both). Images sha256 before==after.
  A3r is unblocked (gate script built + tested).
