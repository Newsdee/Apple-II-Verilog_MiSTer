#!/usr/bin/env python3
"""Inspect one BCD A-value both-fail (fd idx 0x316F) and the two xF ops."""
import sys
sys.path.insert(0, r'E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\module_tests\cpu_65c02')
from rebuild_summary import select_tests          # noqa: E402
from sst_driver import parse_results, compare     # noqa: E402

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
B = r'E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\module_tests\cpu_65c02\build'
EVID = r'E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\module_tests\cpu_65c02\evidence'
sel = select_tests(ROOT, '6502', ['%02x' % i for i in range(256)], 50, 1)
res = parse_results(EVID + r'\sweep_6502_v2nmos_results.txt')
resg = parse_results(EVID + r'\sweep_6502_golden_results.txt')

# which A0-BF ops have both-fail?
both_fail_xf = {}
for idx, (op, t) in enumerate(sel):
    if not (0xA0 <= int(op, 16) <= 0xBF):
        continue
    fn = compare(t, res.get(idx), 0) if res.get(idx) else ['no line']
    fg = compare(t, resg.get(idx), 1) if resg.get(idx) else ['no line']
    if fn and fg:
        both_fail_xf.setdefault(op, []).append((idx, fn))
print('A0-BF both-fail ops:')
for op, v in both_fail_xf.items():
    print('  %s: %d  e.g. %s' % (op, len(v), '; '.join(v[0][1][:3])))
print()

# fd idx 0x316F detail
for idx, (op, t) in enumerate(sel):
    if idx == 0x316F:
        i, f = t['initial'], t['final']
        pc = i['pc']
        ram = {a: v for a, v in i['ram']}
        lo = ram.get(pc + 1, 0); hi = ram.get(pc + 2, 0)
        absaddr = (hi << 8) | lo
        ea = (absaddr + i['x']) & 0xFFFF
        m_ = ram.get(ea, 0)
        print('fd test idx 316F: pc=%04X p=%02X D=%d A=%02X X=%02X C=%d' %
              (pc, i['p'], (i['p'] >> 6) & 1, i['a'], i['x'], i['p'] & 1))
        print('  abs=%04X ea=%04X M=%02X (valid BCD: %s)' %
              (absaddr, ea, m_, (m_ >> 4) <= 9 and (m_ & 0xF) <= 9))
        print('  A valid BCD: %s' % ((i['a'] >> 4) <= 9 and (i['a'] & 0xF) <= 9))
        a_dec = (i['a'] >> 4) * 10 + (i['a'] & 0xF)
        m_dec = (m_ >> 4) * 10 + (m_ & 0xF)
        r = a_dec - m_dec + (i['p'] & 1)
        print('  decimal: %d - %d + %d = %d (borrow=%s)' %
              (a_dec, m_dec, i['p'] & 1, r, r < 0))
        print('  suite final a=%02X p=%02X' % (f['a'], f['p']))
        # core final from register row (offset 0 -> row ncyc)
        rn = res.get(idx)
        if rn:
            print('  v2nmos last reg rows: ' +
                  ' | '.join(r for r in rn[-3:]))
        rg = resg.get(idx)
        if rg:
            print('  golden  last reg rows: ' +
                  ' | '.join(r for r in rg[-3:]))
        # binary (non-BCD) SBC result for contrast
        s_bin = (i['a'] + (~m_ & 0xFF) + (i['p'] & 1)) & 0xFF
        print('  binary SBC would give a=%02X' % s_bin)
        print()
        # show suite trace vs actual first rows
        print('  suite trace: ' +
              ' '.join('%04X/%s' % (a, rw) for a, v, rw in t['cycles']))
        if rn:
            print('  v2nmos trace: ' +
                  ' '.join('%04X/%s' % (int(r[0:4], 16), r[4])
                           for r in [x[0] for x in rn[:6]]))
        break
