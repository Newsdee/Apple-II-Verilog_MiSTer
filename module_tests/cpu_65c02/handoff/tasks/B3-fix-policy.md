# B3 - NMOS-mode fix-list policy decision (USER-GATED)

- status: blocked
- kind: user
- owner: user
- created: 2026-09-04
- updated: 2026-09-04
- eta: decision ~30 min; input: A3r ranked table (+ A1r flag results)
- gate: A3r done (ranking report exists) - A1r recommended but not
  required
- parallel-safe: n/a

## Decision framing
The MOS-side divergences split into:
1. Adjudicated 12 ops (C1: netlist=suite, cores wrong on bus structure -
   build/new6502_netlist_adjudication.md): if the NMOS-mode cores should
   replicate this netlist, these are the first fix list (C01..C12).
2. C2/C3 (93 tests): suite-A-model outliers - suite-data questions, NOT
   core bugs. Do not "fix" cores for these; instead decide whether the
   suite rows deserve correction (out of scope here).
3. C5 (688): A matches suite, bus/PC/cycle model differs - core bus-model
   work, ranked by A3r.
4. C6 (789): three-way divergence - unreferenced NMOS illegal-op
   behaviour; only worth fixing if A3r shows real software hits the op.
Also: if the cores are 65C02-vendor cores with an MOS emulation mode,
most of this is expected divergence and the policy is "document scope",
not "fix".

## What the user decides
- Scope: which population (1/3/4) and which ops (from the A3r ranking)
  enter the fix list; which C tasks become ready (status ready + owner).
- Target RTL: v2 core (recommended: active core; canonical location
  rtl/cpu/wdc65c02/, version name "new_cpu_v2") vs nmos6502 core
  (canonical location rtl/cpu/nmos6502/).
- Quartus policy: one combined compile after all selected C tasks pass
  (recommended) vs per-op.

## Acceptance
- Decision recorded in this file's log: fix list (op list), target RTL,
  Quartus policy; C tasks set to ready with owners.
- Board updated.

## May write
- this task file (decision + log)
- C task files (status/owner only)
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
