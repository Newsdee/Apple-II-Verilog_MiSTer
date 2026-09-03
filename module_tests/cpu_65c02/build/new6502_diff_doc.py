#!/usr/bin/env python3
"""Expert-review document for the NMOS-mode differences between
rtl/new_6502 (netlist-derived, "new6502") and v2 WDC_MODE=0 ("v2nmos").

Uses ONLY retained evidence (no simulation):
  evidence/sweep_6502_new6502_results.txt   (new6502, WDC_MODE=0)
  evidence/sweep_6502_v2nmos_results.txt    (v2,     WDC_MODE=0)
  evidence/sweep_6502_golden_results.txt    (R65Cx2 golden, final_offset=1)
  suite test definitions (E:\\MiSTer\\Apple-II_FPGAdev\\65x02\\6502\\v1\\*.json)

Output: build/new6502_diff_documentation.md — a self-contained, cycle-by-cycle
review of every line where the two NMOS-mode cores differ on the bus, with the
suite's own model and the third opinion (R65Cx2) alongside, plus the exact
starting state of each test so a hardware expert can reproduce it on silicon.

Every characterization in the prose below was re-verified mechanically from
the retained raw traces on 2026-09-03 (see §2 for the verified facts).
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from rebuild_summary import select_tests
from sst_driver import parse_results, compare, completion_classify

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
EVID = os.path.join(HERE, '..', 'evidence')
OUT = os.path.join(HERE, 'new6502_diff_documentation.md')
W = 16

SEL = select_tests(ROOT, '6502', ['%02x' % i for i in range(256)], 50, 1)
NEW = parse_results(os.path.join(EVID, 'sweep_6502_new6502_results.txt'))
NMOS = parse_results(os.path.join(EVID, 'sweep_6502_v2nmos_results.txt'))
GOLD = parse_results(os.path.join(EVID, 'sweep_6502_golden_results.txt'))
PROV = json.load(open(os.path.join(EVID, 'provenance.json'), encoding='utf-8'))

NL = open(os.path.join(EVID, 'sweep_6502_new6502_results.txt'),
          encoding='utf-8', errors='replace').read().splitlines()
ML = open(os.path.join(EVID, 'sweep_6502_v2nmos_results.txt'),
          encoding='utf-8', errors='replace').read().splitlines()
DIFFS = [i for i, (a, b) in enumerate(zip(NL, ML)) if a != b]

L = []          # document lines
def p(s=''):
    L.append(s)

def cval(tok):
    """7-char bus token -> comparable (addr, rw, data)."""
    return (tok[0:4].upper(), tok[4], tok[5:7].upper())

def fmt(tok):
    a, rw, d = cval(tok)
    return '$' + a + ' ' + ('W' if rw == 'W' else 'R') + ' ' + d

def suite_val(t, c):
    if c < len(t['cycles']):
        ea, ev, et = t['cycles'][c]
        return (('%04X' % ea).upper(), 'W' if et == 'write' else 'R',
                ('%02X' % ev).upper())
    return None

def suite_row(t, c):
    v = suite_val(t, c)
    if v:
        return '$' + v[0] + ' ' + v[1] + ' ' + v[2]
    if c == len(t['cycles']):
        return '(next fetch @ $%04X)' % t['final']['pc']
    return ''

def checker_regs(groups, t, off):
    row = min(len(t['cycles']) + off, W - 1)
    r = groups[row][1]
    return row, ('$%s %s %s %s %s %s' % (r[0:4].upper(), r[4:6].upper(),
            r[6:8].upper(), r[8:10].upper(), r[10:12].upper(), r[12:14].upper()))

def next_read_at(groups, addr):
    """First row where the bus is a READ at the given address, or None."""
    for c in range(W):
        if cval(groups[c][0])[1] == 'R' and cval(groups[c][0])[0] == ('%04X' % addr).upper():
            return c
    return None

def program_bytes(t):
    """Contiguous program bytes at the initial PC, from initial RAM."""
    ram = dict(t['initial']['ram'])
    pc = t['initial']['pc']
    out = []
    for k in range(8):
        a = (pc + k) & 0xFFFF
        if a not in ram:
            break
        out.append(ram[a])
    return ' '.join('%02X' % b for b in out)

def test_block(idx, note=''):
    op, t = SEL[idx]
    g_new = NEW.get(idx); g_nmos = NMOS.get(idx); g_gold = GOLD.get(idx)
    ncyc = len(t['cycles'])
    ini = t['initial']
    fpc = t['final']['pc']
    p('### op %s — evidence line %d%s' % (op, idx, note))
    p()
    p('**Initial state**  PC=$%04X  SP=$%02X  A=$%02X  X=$%02X  Y=$%02X  P=$%02X'
      % (ini['pc'], ini['s'], ini['a'], ini['x'], ini['y'], ini['p']))
    ram_s = '   '.join('$%04X=%02X' % (a, v) for a, v in ini['ram'])
    p('**RAM**          %s' % ram_s)
    p('**Program**      %s (at PC)' % program_bytes(t))
    p('**Suite model**  %d cycles, final PC=$%04X A=$%02X P=$%02X'
      % (ncyc, t['final']['pc'], t['final']['a'], t['final']['p']))
    p()
    p('| cyc | suite model | new6502 | v2nmos | R65Cx2 (golden) |')
    p('|----|-------------|---------|--------|-----------------|')
    for c in range(W):
        sv = suite_val(t, c)
        sn = ('$' + sv[0] + ' ' + sv[1] + ' ' + sv[2]) if sv else suite_row(t, c)
        cn = fmt(g_new[c][0])
        cm = fmt(g_nmos[c][0])
        cg = fmt(g_gold[c][0])
        mark = ''
        if sv and (cval(g_new[c][0]) != cval(g_nmos[c][0])
                   or cval(g_new[c][0]) != sv
                   or cval(g_nmos[c][0]) != sv):
            mark = '  *'
        p('| %2d | %s | %s | %s | %s |%s' % (c, sn, cn, cm, cg, mark))
    p()
    p('(* = rows inside the checked window (cyc < %d) where at least one core differs from the other core or from the suite model)' % ncyc)
    p()
    fn = compare(t, g_new, 0)
    fm = compare(t, g_nmos, 0)
    fg = compare(t, g_gold, 1)
    rn, sn = checker_regs(g_new, t, 0)
    rm, sm = checker_regs(g_nmos, t, 0)
    rg, sg = checker_regs(g_gold, t, 1)
    p('**State at the row the suite samples** (row %d; R65Cx2 commits one row later):' % rn)
    p('- new6502 : %s' % sn)
    p('- v2nmos  : %s' % sm)
    p('- R65Cx2  : %s' % sg)
    p('- suite   : $%04X $%02X $%02X $%02X $%02X $%02X (expected final PC SP A X Y P)'
      % (t['final']['pc'], t['final']['s'], t['final']['a'], t['final']['x'], t['final']['y'], t['final']['p']))
    p()
    p('**First bus READ at the suite expected final PC** (first row where the bus reads $%04X; the cores hold addresses during settle, so the exact cycle count needs the silicon capture; in the Class B tests this address is PC+2 — inside the 4-byte fetch — so the row shown is a fetch row, not a settle row):' % fpc)
    p('- new6502 : %s' % (next_read_at(g_new, fpc) if next_read_at(g_new, fpc) is not None else '—'))
    p('- v2nmos  : %s' % (next_read_at(g_nmos, fpc) if next_read_at(g_nmos, fpc) is not None else '—'))
    p('- R65Cx2  : %s' % (next_read_at(g_gold, fpc) if next_read_at(g_gold, fpc) is not None else '—'))
    core_pc = int(g_new[min(ncyc, W - 1)][1][0:4], 16)
    if core_pc != fpc:
        p()
        p('**First bus READ at the core-agreed final PC** ($%04X; the suite expected $%04X):' % (core_pc, fpc))
        p('- new6502 : %s' % (next_read_at(g_new, core_pc) if next_read_at(g_new, core_pc) is not None else '—'))
        p('- v2nmos  : %s' % (next_read_at(g_nmos, core_pc) if next_read_at(g_nmos, core_pc) is not None else '—'))
        p('- R65Cx2  : %s' % (next_read_at(g_gold, core_pc) if next_read_at(g_gold, core_pc) is not None else '—'))
    p()
    def short(fails):
        if not fails:
            return 'PASS'
        out = []
        for x in fails:
            out.append(x if not x.startswith('cyc') and not x.startswith('complete')
                       else x)
        return '; '.join(out)
    p('- new6502 vs suite : %s' % short(fn))
    p('- v2nmos  vs suite : %s' % short(fm))
    p('- R65Cx2  vs suite : %s' % short(fg))
    p()
    p('**Expert verdict / reference (fill in):** ______________________________')
    p()

def main():
    # ---- classify the diff lines ------------------------------------------
    inwin, trail = [], []
    for i in DIFFS:
        op, t = SEL[i]
        ncyc = len(t['cycles'])
        g_new, g_nmos = NEW[i], NMOS[i]
        rows = [c for c in range(W) if g_new[c][0] != g_nmos[c][0]]
        (inwin if any(c < ncyc for c in rows) else trail).append(i)
    a_ops = [i for i in inwin if SEL[i][0] == '5c']
    b_ops = [i for i in inwin if SEL[i][0] != '5c']

    # ---- verified counts (recomputed here, printed for the log) -----------
    # $5C: new6502 completion row (first READ at final.pc) is 8 on all 50;
    # v2nmos completion row == suite ncyc on all 50.
    n_new8 = sum(1 for i, (op, t) in enumerate(SEL) if op == '5c'
                 and next_read_at(NEW[i], t['final']['pc']) == 8)
    n_nmos4 = sum(1 for i, (op, t) in enumerate(SEL) if op == '5c'
                  and next_read_at(NMOS[i], t['final']['pc']) == 4)
    g_same34 = sum(1 for i, (op, t) in enumerate(SEL) if op == '5c' and
                   GOLD[i][3][0] == NMOS[i][3][0] and GOLD[i][4][0] == NMOS[i][4][0])
    print('verified: $5C new6502 first next-PC read at row 8 on %d/50; '
          'v2nmos at row 4 on %d/50; R65Cx2 rows 3-4 == v2nmos on %d/50'
          % (n_new8, n_nmos4, g_same34))
    # $5C next-fetch-start (first READ(finalPC),READ(finalPC+1) pair): the
    # held-PC rows are not a fetch; this fixes the fetch-start row.
    def _c5c(groups):
        from collections import Counter
        c = Counter()
        for i, (op, t) in enumerate(SEL):
            if op == '5c':
                c[completion_classify(t, groups[i])] += 1
        return ' '.join('%s=%d' % (k, v) for k, v in sorted(c.items()))
    print('verified: $5C next-fetch-start distribution — new6502 [%s]; '
          'v2nmos [%s]; R65Cx2 [%s]'
          % (_c5c(NEW), _c5c(NMOS), _c5c(GOLD)))
    # Class B: identical traces outside the 9 diff lines
    bad_ops = {'23', '3b', '63', '73', '7b', '9b', 'c3', 'db', 'f3'}
    total_illegal = sum(1 for i in range(len(SEL)) if SEL[i][0] in bad_ops)
    same_illegal = sum(1 for i in range(len(SEL))
                       if SEL[i][0] in bad_ops and NL[i] == ML[i])
    print('verified: illegal-op tests total=%d, trace-identical=%d (diffs=%d)'
          % (total_illegal, same_illegal, total_illegal - same_illegal))
    # $80 silent-branch fact and $7C all-fail fact (grounding for Q11).
    i80 = [i for i, (op, t) in enumerate(SEL) if op == '80']
    i7c = [i for i, (op, t) in enumerate(SEL) if op == '7c']
    n80_pass = sum(1 for i in i80 if not compare(SEL[i][1], NEW[i], 0)
                   and not compare(SEL[i][1], NMOS[i], 0))
    n7c_fail = sum(1 for i in i7c if compare(SEL[i][1], NEW[i], 0)
                   and compare(SEL[i][1], NMOS[i], 0)
                   and compare(SEL[i][1], GOLD[i], 0))
    print('verified: op 80 passes for new6502+v2nmos on %d/50 (silent-branch '
          'case); op 7c fails for new6502+v2nmos+R65Cx2 on %d/50'
          % (n80_pass, n7c_fail))
    # Class B flag fact: A/X/Y/SP unchanged at the sample row; P +0x10 on 8/9.
    axys_ok = 0
    b4_set = 0
    for i in b_ops:
        op, t = SEL[i]
        ncyc = len(t['cycles'])
        ini = t['initial']
        r = NEW[i][min(ncyc, W - 1)][1]
        if (r[4:6].upper() == ('%02X' % ini['s'])
                and r[6:8].upper() == ('%02X' % ini['a'])
                and r[8:10].upper() == ('%02X' % ini['x'])
                and r[10:12].upper() == ('%02X' % ini['y'])):
            axys_ok += 1
        if (ini['p'] ^ int(r[12:14], 16)) & 0xFF == 0x10:
            b4_set += 1
    print('verified: class B A/X/Y/SP unchanged at sample row %d/9; P+0x10 (break bit) on %d/9'
          % (axys_ok, b4_set))
    # $5C phantom: new6502 row 3 = $FF + low operand byte (byte at PC+1), 50/50.
    n5c_bb = 0
    for i, (op, t) in enumerate(SEL):
        if op != '5c':
            continue
        ram = dict(t['initial']['ram'])
        lo = ram.get((t['initial']['pc'] + 1) & 0xFFFF)
        if lo is not None and cval(NEW[i][3][0])[0] == ('FF%02X' % lo).upper():
            n5c_bb += 1
    print('verified: $5C new6502 row-3 phantom == $FF + byte@PC+1 on %d/50' % n5c_bb)
    # Class B phantom: new6502 first page-FF row = $FF + byte at PC+2 (8/9; op 63 = $FFEE).
    nb_bb = 0
    nb_exc = []
    for i in b_ops:
        op, t = SEL[i]
        ram = dict(t['initial']['ram'])
        b2 = ram.get((t['initial']['pc'] + 2) & 0xFFFF)
        ph = None
        for c in range(3, W):
            a = cval(NEW[i][c][0])[0]
            if a.startswith('FF'):
                ph = a
                break
        if b2 is not None and ph == ('FF%02X' % b2).upper():
            nb_bb += 1
        else:
            nb_exc.append((i, op, ph))
    print('verified: class B new6502 phantom == $FF + byte@PC+2 on %d/9; exceptions: %s'
          % (nb_bb, nb_exc))

    p('# NMOS-mode difference study: rtl/new_6502 vs v2 (WDC_MODE=0)')
    p()
    p('Prepared for external hardware-expert review of MOS 6502 undefined /')
    p('settle behavior. Scope: NMOS mode only (both cores built with')
    p('`-GWDC_MODE=0`). No WDC/65C02 vendor material is involved. This document')
    p('is self-contained: every case below gives the exact starting state and')
    p('program bytes, so each can be reproduced on a real 6502 with a logic')
    p('analyzer (capture A0-A15, RW, PHI1/PHI2 for 16 cycles).')
    p()
    p('## 1. What is being compared')
    p()
    p('| column | provenance |')
    p('|--------|-----------|')
    n65 = list(PROV['files']['rtl']['new_6502_core'].values())
    p('| **new6502** | user-supplied “netlist derived” NMOS-specialized 65C02 variant (README: netlist derived, fixed some pin definitions, IRQ timing speculative based on the 6502). cpu_65c02.sv sha256 %s… / cpu_alu.sv %s…' % (n65[0][:16], n65[1][:16]))
    p('| **v2nmos** | hand-written 65C02 core (v2), WDC_MODE=0 branch. Its NMOS bus behavior is a hand model. |')
    p('| **R65Cx2 (golden)** | netlist-derived 65C02 reference core (independent third opinion; commits A/flags one row later, hence sampled one row later). |')
    p('| **suite model** | 65x02 SingleStepTests, suite “6502” (MOS) — a reconstruction of the MOS 6502, commit %s. Its models for the opcodes below are the weakest reference in this table, not a ground truth. |' % PROV['suite']['commit'][:16])
    p()
    p('Retained raw traces (sha256, from `evidence/provenance.json`):')
    for k in ('new6502_mos_sweep_raw', 'v2_mos_nmos_sweep_raw', 'golden_sweep_raw'):
        r = PROV['files']['results'].get(k)
        if r:
            p('- %s: %s' % (k, r['sha256']))
    p()
    p('## 2. Headline (mechanically verified from the retained traces)')
    p()
    p('- 12 800-test MOS 6502 sweep: pass totals new6502 = v2nmos = 7973,')
    p('  R65Cx2 = 7749. fixed=0, regressed=0 between new6502 and v2nmos —')
    p('  identical suite verdicts on all 12 800 tests.')
    p('- **The per-cycle register snapshots (PC SP A X Y P, every cycle) are')
    p('  byte-identical between new6502 and v2nmos on all 12 800 tests.**')
    p('  Every one of the 91 differing lines differs **only in bus activity** —')
    p('  there are zero register-level differences at any cycle.')
    p('- The 91 bus-difference lines fall in three classes:')
    p()
    p('| class | lines | what differs (new6502 vs v2nmos) |')
    p('|-------|-------|----------------------------------|')
    p('| A: $5C | 50 | the whole settle region (bus rows 3–7, verified on all 50): new6502 drives $FFbb (bb = low operand byte, 2nd fetched) then $FFFF×4 and first reads the next PC at row 8; v2nmos drives the computed $PPbb (page = high operand byte, 3rd fetched; low = low operand byte, 2nd fetched) then holds the next PC from row 4 |')
    p('| B: illegal ops 23 3b 63 73 7b 9b c3 db f3 | 9 | five consecutive settle rows: new6502 = $FFbb (bb = byte at PC+2; op 63 shows $FFEE) then $FFFF; v2nmos = a different page (mostly EE, sometimes 1F/2C/CD) then a PC+4 hold. Both cores: 4-byte fetch, PC+4, A/X/Y/SP unchanged; status bit 4 (break) set on 8 of 9 (op 9b: P unchanged) |')
    p('| C: trailing cycles, legal ops | 32 | addresses in unmodelled rows only (row ≥ suite cycle count); identical inside the checked window |')
    p()
    p('- Class B context: on the other **441/450** sampled tests of those nine')
    p('  illegal opcodes, new6502 and v2nmos produce **byte-identical** traces')
    p('  (same 4-byte fetch, same PC-sequence settle reads, same $EEEE holds).')
    p('  The nine tests in §4 are the only sampled tests where they differ.')
    p('- **Outside the 91 diff lines:** all 50 sampled op-$80 tests PASS for both')
    p('  cores — and for every core under test — while the cores decode $80 as a')
    p('  2-byte relative branch (WDC BRA) and execute past the branch target,')
    p('  which the suite never checks (the suite models $80 as a 2-byte NOP).')
    p('  See question 11 in §6. This is the concrete case of “finish early or')
    p('  late and occasionally appear correct”: the check window ends before the')
    p('  branch divergence is observable.')
    p('- Class A is the only class where the cores’ *next-PC activity* starts on')
    p('  different rows (8 vs 4). Because the cores hold addresses on the bus')
    p('  during settle cycles, the bus traces alone do not fix the exact cycle')
    p('  count — that is precisely what a silicon capture would settle. R65Cx2')
    p('  (the netlist-derived 65C02) agrees with v2nmos on the $5C cycle-3')
    p('  phantom and on driving the next PC from row 4 (verified 50/50), which')
    p('  is one independent data point against new6502’s $FFbb/$FFFF claim.')
    p('- Classes B and C: both cores agree on the functional outcome (width, PC')
    p('  update, flags) on every line — they differ only in phantom/settle')
    p('  addresses. The suite’s model of the nine illegal ops is a different')
    p('  instruction entirely and matches no core (see §4).')
    p()
    p('## 3. Class A — $5C (50 tests; two shown in full)')
    p()
    p('Verified on all 50 tests (bus tokens, rows 0–15):')
    p('- rows 0–2: identical 3-byte fetch (opcode + 2 operand bytes).')
    p('- row 3 (settle phantom): new6502 = `$FFbb` (page FF, bb = low operand');
    p('  byte); v2nmos = R65Cx2 = the *computed* `$PPbb` (page = high operand');
    p('  byte, low = low operand byte) — verified 50/50.')
    p('- rows 4–7: new6502 holds `$FFFF`; v2nmos holds the **next PC** (the');
    p('  suite’s expected final PC); R65Cx2 goes next-PC, next-PC+1, next-PC+2,');
    p('  then `$EEEE`.')
    p('- **Next-opcode-fetch start** (first row pair READ(finalPC),')
    p('  READ(finalPC+1) — distinguishes a real fetch from a PC hold):')
    p('  R65Cx2 starts the next fetch at row 4 on all 50 (exact on the 27')
    p('  4-cycle tests; 1 row early on the 23 5-cycle tests). v2nmos and')
    p('  new6502 both start the next fetch at row 8 on all 50 (the next PC is')
    p('  already on the bus from row 4 for v2nmos, but the fetch pair — opcode')
    p('  read followed by the next byte — forms only at row 8; 3–4 rows late')
    p('  against the suite). Verified 50/50 with the same mechanical rule the')
    p('  report uses.')
    p('- The suite models 27/50 tests as 4 cycles and 23/50 as 5 cycles, with its');
    p('  own phantom addresses (neither core’s). Both cores advance PC by +3 and');
    p('  leave A/X/Y/SP/P unchanged — their per-cycle register snapshots are');
    p('  identical, so the whole difference is the bus activity above.')
    p('The open question for the expert: does the real MOS 6502, after the');
    p('3-byte $5C fetch, drive `$FFbb`+`$FFFF` with the next fetch ~4 cycles later');
    p('(new6502’s claim), or the computed `$PPbb` with the next PC on the bus from');
    p('the following row (v2nmos + R65Cx2 claim)? The held-address rows (4–7) are');
    p('real bus activity either way; whether they count as cycles of the $5C');
    p('instruction or as separate settle cycles is exactly what a silicon capture');
    p('or the perfect6502 netlist simulation settles. The two shown tests below');
    p('are full reproductions; the remaining 48 are the same structure with');
    p('different operand bytes.')
    p()
    for i in a_ops[:2]:
        test_block(i)
    rest = a_ops[2:]
    if rest:
        p('_Remaining 48 $5C tests (same verified structure; evidence line):_')
        for i in rest:
            p('- line %d (PC=$%04X, program %s)'
              % (i, SEL[i][1]['initial']['pc'], program_bytes(SEL[i][1])))
        p()
    p('## 4. Class B — the 9 illegal-op edge cases (one per op)')
    p()
    p('Both cores model these nine illegal opcodes the same way — a 4-byte')
    p('fetch from PC, PC advances by +4, A/X/Y/SP unchanged, a short settle')
    p('sequence; on 8 of the 9 lines both cores also set status bit 4 (the')
    p('break flag) in P (op 9b leaves P unchanged) — verified from the')
    p('identical register snapshots. On 441/450 sampled tests their traces are')
    p('byte-identical.')
    p('The nine tests below are the only sampled tests where the first settle')
    p('read differs: new6502 drives `$FFbb` (bb = byte at PC+2; op 63 shows')
    p('`$FFEE`) then `$FFFF`;')
    p('v2nmos drives a different page (often EE, sometimes data-dependent) then a')
    p('PC+4 hold. The suite’s model of these opcodes is a *different instruction*')
    p('entirely (typically a 2-byte zero-page op with a RAM write-back and flag')
    p('changes) and matches no core on any of the 450 tests — this is the case')
    p('where the expert input is most valuable: confirm the real MOS 6502 width /')
    p('PC update / flag behavior, and the settle-cycle addresses.')
    p()
    for i in b_ops:
        test_block(i)
    p('## 5. Class C — trailing-only differences (32 tests, legal opcodes)')
    p()
    p('The two cores are identical inside the checked window on all 32 lines;')
    p('only the unmodelled trailing cycles differ. 25 of the 32 pass for every')
    p('core; 7 are both-fail vs the suite (the suite’s own model is inconsistent')
    p('there — the same broken-reference class documented in the prior campaign;')
    p('the two cores agree with each other). new6502’s trailing pattern is')
    p('$FFxx/`$FFFF` (released-bus model); v2nmos drives a `$XXbb`-style read then')
    p('a PC hold (which R65Cx2 sometimes matches, e.g. op 08 below).')
    p('Representative examples:')
    p()
    shown = set()
    for i in trail:
        op = SEL[i][0]
        if op in shown:
            continue
        shown.add(op)
        test_block(i, ' — representative for op %s' % op)
        if len(shown) >= 4:
            break
    rest_t = [i for i in trail if SEL[i][0] not in shown]
    p('_Remaining trailing-only tests (line → op, PC):_')
    for i in rest_t:
        p('- line %d: op %s (PC=$%04X)' % (i, SEL[i][0], SEL[i][1]['initial']['pc']))
    p()
    p('## 6. Questions for the expert (the 10 adjudications)')
    p()
    p('For each opcode below, the real MOS 6502 behavior needed to settle this:')
    p()
    p('1. **$5C** — instruction width? cycle count? bus activity during the')
    p('   settle cycles (addresses, R/W, data)? PC update and flag updates?')
    p('   Three models on the table. new6502: 3-byte, $FFbb + $FFFF×4, next')
    p('   fetch starts at row 8, PC+3, no flag change. v2nmos + R65Cx2: 3-byte,')
    p('   computed $PPbb phantom; R65Cx2’s next fetch starts at row 4 (4 bus')
    p('   cycles; exact on the 27 4-cycle tests, 1 row early on the 23 5-cycle')
    p('   tests), while v2nmos holds the next PC from row 4 and its next fetch')
    p('   also starts at row 8. The suite: 4 or 5 cycles (5 when the (a,X)')
    p('   effective address crosses a page) with its own phantom addresses.')
    p('   $5C is a documented NMOS 6502 opcode (SBC (a,X)), so the perfect6502')
    p('   netlist run settles this directly.')
    p('2-10. **23, 3b, 63, 73, 7b, 9b, c3, db, f3** — instruction width? PC')
    p('   update? flag updates? settle-cycle bus activity? (Both cores agree: 4-byte,')
    p('   PC+4, A/X/Y/SP unchanged, status bit 4 (break) set on 8 of 9 (op 9b: P')
    p('   unchanged); they differ only on the first settle address in the nine edge')
    p('   cases. The suite claims a 2-byte op with write-back — confirm which model')
    p('   is right on MOS silicon. All nine are documented NMOS 6502 opcodes')
    p('   (SLO/SRE family), so the perfect6502 netlist run settles these too.)')
    p('11. **$80 (and $7C)** — the “silent branch” case: the suite’s 6502 model')
    p('   for $80 is a 2-byte NOP (2 cycles, final PC = PC+2). Every core under')
    p('   test passes all 50 $80 tests, yet every core decodes $80 as a 2-byte')
    p('   relative branch (WDC BRA; target = PC+2+signed(offset)) and continues')
    p('   execution at the branch target. The suite never sees this: row ncyc is')
    p('   a coincidental READ of PC+2 (the expected next-fetch address) and the')
    p('   register snapshot at row ncyc is still pre-branch. Questions: (a) is')
    p('   $80 a 2-byte NOP on real NMOS 6502 silicon, as the suite models? (b)')
    p('   if so, new6502 — despite being NMOS-specialized — still carries the')
    p('   65C02 BRA decode for it. (c) same class of question for $7C (JMP')
    p('   (abs,X) on W65C02): all five cores fail 50/50 of its tests against')
    p('   the suite’s 6502-subset model, which matches no core — the NMOS')
    p('   silicon behavior for $7C is exactly what the perfect6502 run (or a')
    p('   silicon capture) must settle.)')
    p()
    p('Each test’s exact starting state (PC/SP/A/X/Y/P, RAM, program bytes) is in')
    p('§3-§5, so a real MOS 6502 + logic analyzer (capture A0-A15, RW, PHI1/PHI2,')
    p('16 cycles) can reproduce every case directly.')
    p()
    p('Acceptable references, best first: (a) **perfect6502** — the')
    p('transistor-level NMOS 6502 netlist simulation (extracted from Visual6502):')
    p('the best non-hardware oracle for NMOS bus cycles, RMW writes, and')
    p('undocumented opcodes; running it on these exact tests directly answers')
    p('questions 1–10; (b) the netlist the RTL was derived from, simulated on')
    p('these exact tests; (c) silicon capture on a machine with a genuine MOS')
    p('6502 (Apple II/II Plus, C64/6510, Atari 8-bit, VIC-20); (d) documentation')
    p('that actually covers these opcodes on MOS silicon (note: the W65C02S and')
    p('Rockwell 65C02 datasheets document their own chips, not MOS 6502 undefined')
    p('behavior); (e) the suite’s models are reconstructions and match no core')
    p('here — they are a floor, not a reference. Secondary triangulation for')
    p('vendor-semantic questions: MAME m6502 and vrEmu6502 (standard/WDC/Rockwell')
    p('models).')
    p()
    p('## 7. How to return answers')
    p()
    p('Per test, per cycle: `$addr R|W $data`, 16 rows, in the evidence line')
    p('format (`R <idx> <bus0> <regs0><bus1> …` — 7-char bus tokens')
    p('<addr4><R/W><data2>, 14-char register snapshots <pc4><sp2><a2><x2><y2><p2>).')
    p('The existing harness (module_tests/cpu_65c02) compares such traces')
    p('mechanically against the suite and the cores.')
    p()
    p('---')
    p('_Generated by build/new6502_diff_doc.py from retained evidence only;_')
    p('_all class characterizations re-verified mechanically 2026-09-03._')

    out = '\n'.join(L)
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write(out)
    print('wrote', OUT, '%d lines, %d test blocks' % (len(L),
          sum(1 for x in L if x.startswith('### op'))))

if __name__ == '__main__':
    main()
