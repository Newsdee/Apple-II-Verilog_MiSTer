# A2t - v2 sequence evidence: enumerate items + build the runner

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
