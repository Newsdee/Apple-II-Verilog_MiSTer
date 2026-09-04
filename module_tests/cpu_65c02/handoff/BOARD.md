# cpu_65c02 handoff board (generated - do not edit)

Source of truth: the task files under `tasks/`. Refresh with
`python3 handoff/board_status.py`. Protocol: `handoff/README.md`.

Status: backlog=1, blocked=16, ready=2, review=3, running=1

## A - unattended analysis (agents may run, in parallel)

| id | task | kind | status | owner | eta | gate |
|----|------|------|--------|-------|-----|------|
| A1r | [A1r - T2 branch-probe: run the matrix (runner)](tasks/A1r-t2-flag-run.md) | runner | blocked | (unset) | < 5 min (oracle sim ~1-2 min + report) | A1t done (oracle/t2_flag_probe.py exists and passed its m... |
| A1t | [A1t - T2 branch-probe: design + build the deterministic runner](tasks/A1t-t2-flag-design.md) | thinking | ready | (unset) | 2-4 h | none - startable now |
| A2r | [A2r - v2 sequence evidence: run all items (runner)](tasks/A2r-v2-seq-run.md) | runner | blocked | (unset) | 10-30 min (Verilator build dominates) | A2t done (build/v2_seq_evidence.py passed its 1-item mini... |
| A2t | [A2t - v2 sequence evidence: enumerate items + build the runner](tasks/A2t-v2-seq-design.md) | thinking | ready | (unset) | 1-2 h | none - startable now |
| A3r | [A3r - opcode relevance ranking: run the ranking (runner)](tasks/A3r-op-ranking-run.md) | runner | review | run_board.bat | < 5 min | A3t done (build/op_relevance_ranking.py passed its mini run) |
| A3t | [A3t - opcode relevance ranking: methodology + build the runner](tasks/A3t-op-ranking-design.md) | thinking | review | pi-session | 2-4 h | none - startable now |
| A4 | [A4 - FFFF stray-read mechanism trace (thinking; small)](tasks/A4-ffff-forensics.md) | thinking | backlog | (unset) | 1-2 h | A1r done (shares the oracle toolchain conventions; not a ... |
| A5 | [A5 - locate true P storage nodes in the netlist (thinking; gated)](tasks/A5-p-node-scan.md) | thinking | blocked | (unset) | 2-4 h | A1r result - if A1's PLP-probes observe P states reliably... |

## B - user-gated decisions / user actions

| id | task | kind | status | owner | eta | gate |
|----|------|------|--------|-------|-----|------|
| B1 | [B1 - Quartus map/fit/timing for new_cpu_v2 (USER-GATED)](tasks/B1-quartus-v2-compile.md) | user | running | user | agent prep ~30 min; user compile 30-60 min machine time | user go-ahead to compile (AGENTS.md: do not start long Qu... |
| B2 | [B2 - commit final v2 RTL state (USER-GATED)](tasks/B2-v2-rtl-commit.md) | user | review | user | minutes | user decision (what exactly belongs in the v2 commit) |
| B3 | [B3 - NMOS-mode fix-list policy decision (USER-GATED)](tasks/B3-fix-policy.md) | user | blocked | user | decision ~30 min; input: A3r ranked table (+ A1r flag results) | A3r done (ranking report exists) - A1r recommended but not |

## C - RTL fixes (one writer at a time; gated on B3)

| id | task | kind | status | owner | eta | gate |
|----|------|------|--------|-------|-----|------|
| C01 | [C01 - op $5c fix: SBC (abs,X) - real SBC; page-cross dummy cycle; next](tasks/C01-op-5c.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $5c) + one-writer rule... |
| C02 | [C02 - op $80 fix: 2-byte NOP (netlist=suite; cores decode BRA - semant](tasks/C02-op-80.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $80) + one-writer rule... |
| C03 | [C03 - op $7c fix: JMP (abs,X) 3-byte MOS (netlist=suite; cores decode ](tasks/C03-op-7c.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $7c) + one-writer rule... |
| C04 | [C04 - op $23 fix: 8-cyc 2-byte RMW illegal (netlist=suite structure; A](tasks/C04-op-23.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $23) + one-writer rule... |
| C05 | [C05 - op $3b fix: 7-cyc 3-byte RMW illegal (netlist=suite structure; A](tasks/C05-op-3b.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $3b) + one-writer rule... |
| C06 | [C06 - op $63 fix: 8-cyc 2-byte RMW illegal (netlist=suite structure; A](tasks/C06-op-63.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $63) + one-writer rule... |
| C07 | [C07 - op $73 fix: 8-cyc 2-byte RMW illegal (netlist=suite structure; A](tasks/C07-op-73.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $73) + one-writer rule... |
| C08 | [C08 - op $7b fix: 7-cyc 3-byte RMW illegal (netlist=suite structure; A](tasks/C08-op-7b.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $7b) + one-writer rule... |
| C09 | [C09 - op $9b fix: netlist=suite 50/50 (structure + bus; A preserved by](tasks/C09-op-9b.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $9b) + one-writer rule... |
| C10 | [C10 - op $c3 fix: netlist=suite 50/50 (structure + bus; A preserved by](tasks/C10-op-c3.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $c3) + one-writer rule... |
| C11 | [C11 - op $db fix: netlist=suite 50/50 (structure + bus; A preserved by](tasks/C11-op-db.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $db) + one-writer rule... |
| C12 | [C12 - op $f3 fix: 8-cyc 2-byte RMW illegal (netlist=suite structure; A](tasks/C12-op-f3.md) | thinking (RTL writer) | blocked | (unset - assigned at B3) | 0.5-1 d (RTL + differential + sweep slice) | B3 decision (fix list must include $f3) + one-writer rule... |

## Runner one-liners (no thinking needed; any shell/agent)

cwd: E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/module_tests/cpu_65c02

| id | command | eta | status |
|----|---------|-----|--------|
| A1r | `(cwd module_tests/cpu_65c02) python3 oracle/t2_flag_probe.py` | < 5 min (oracle sim ~1-2 min + report) | blocked |
| A2r | `(cwd module_tests/cpu_65c02) python3 build/v2_seq_evidence.py` | 10-30 min (Verilator build dominates) | blocked |
| A3r | `(cwd module_tests/cpu_65c02) python3 build/op_relevance_ranking.py` | < 5 min | review |

Ready now: A1t, A2t

Waiting on: A1r (gate: A1t done (oracle/t2_flag_probe.py exists and passed its mini run)), A2r (gate: A2t done (build/v2_seq_evidence.py passed its 1-item mini run)), A5 (gate: A1r result - if A1's PLP-probes observe P states reliably, this), B3 (gate: A3r done (ranking report exists) - A1r recommended but not), C01 (gate: B3 decision (fix list must include $5c) + one-writer rule: C tasks), C02 (gate: B3 decision (fix list must include $80) + one-writer rule: C tasks), C03 (gate: B3 decision (fix list must include $7c) + one-writer rule: C tasks), C04 (gate: B3 decision (fix list must include $23) + one-writer rule: C tasks), C05 (gate: B3 decision (fix list must include $3b) + one-writer rule: C tasks), C06 (gate: B3 decision (fix list must include $63) + one-writer rule: C tasks), C07 (gate: B3 decision (fix list must include $73) + one-writer rule: C tasks), C08 (gate: B3 decision (fix list must include $7b) + one-writer rule: C tasks), C09 (gate: B3 decision (fix list must include $9b) + one-writer rule: C tasks), C10 (gate: B3 decision (fix list must include $c3) + one-writer rule: C tasks), C11 (gate: B3 decision (fix list must include $db) + one-writer rule: C tasks), C12 (gate: B3 decision (fix list must include $f3) + one-writer rule: C tasks)
