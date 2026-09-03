#!/usr/bin/env python3
"""Rebuild every retained sweep summary from its raw results file and compare
against the stored summary.

Raw results live in ../evidence/ (long-generated; see V2_VERDICT.md §9).
Summaries are derived on demand and written to build/.

Usage:
    python regen_all_summaries.py            # dry run: totals diff only
    python regen_all_summaries.py --apply    # write (re)created summaries

Purpose: after a checker change (sst_driver.compare), regenerate all derived
summaries so every artifact agrees with the pinned checker version.
NOTE: a full pass runs compare() on every sampled test (several minutes of wall time on this machine; CPU work is seconds).
"""
import os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MT = os.path.join(HERE, '..')
EVID = os.path.join(HERE, '..', 'evidence')   # long-generated raw results live here
ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
PY = r'C:\msys64\ucrt64\bin\python'

# (suite, raw_results, summary, final_offset, label)
ENTRIES = [
    ('wdc65c02',      'sweep_wdc_results.txt',      'sweep_wdc.txt',      0, 'v1 pre-OptionC'),
    ('wdc65c02',      'sweep_wdc_abxfix_results.txt', 'sweep_wdc_abxfix.txt', 0, 'v1'),
    ('wdc65c02',      'sweep_wdc_golden_results.txt', 'sweep_wdc_golden.txt', 1, 'golden'),
    ('wdc65c02',      'sweep_wdc_v2_results.txt',   'sweep_wdc_v2.txt',   0, 'v2'),
    ('6502',          'sweep_6502_abxfix_results.txt', 'sweep_6502_abxfix.txt', 0, 'v1'),
    ('6502',          'sweep_6502_golden_results.txt', 'sweep_6502_golden.txt', 1, 'golden'),
    ('6502',          'sweep_6502_v2_results.txt',  'sweep_6502_v2.txt',  0, 'v2'),
    ('6502',          'sweep_6502_v2nmos_results.txt', 'sweep_6502_v2nmos.txt', 0, 'v2nmos'),
    ('rockwell65c02', 'sweep_rockwell_v1_results.txt', 'sweep_rockwell_v1.txt', 0, 'v1'),
    ('rockwell65c02', 'sweep_rockwell_golden_results.txt', 'sweep_rockwell_golden.txt', 1, 'golden'),
    ('rockwell65c02', 'sweep_rockwell_v2_results.txt', 'sweep_rockwell_v2.txt', 0, 'v2'),
    ('synertek65c02', 'sweep_synertek_v1_results.txt', 'sweep_synertek_v1.txt', 0, 'v1'),
    ('synertek65c02', 'sweep_synertek_golden_results.txt', 'sweep_synertek_golden.txt', 1, 'golden'),
    ('synertek65c02', 'sweep_synertek_v2_results.txt', 'sweep_synertek_v2.txt', 0, 'v2'),
]

PAT = re.compile(r'=== \S+: (\d+)/(\d+) pass ===')


def total_of(path):
    if not os.path.isfile(path):
        return None
    for line in open(path, encoding='utf-8', errors='replace'):
        m = PAT.search(line)
        if m:
            return (int(m.group(1)), int(m.group(2)))
    return None


def main():
    apply = '--apply' in sys.argv
    all_ok = True
    for suite, raw, summ, off, label in ENTRIES:
        raw_p = os.path.join(EVID, raw)
        summ_p = os.path.join(HERE, summ)
        if not os.path.isfile(raw_p):
            print('!! missing raw %s' % raw)
            all_ok = False
            continue
        tmp = os.path.join(HERE, '.tmp_regen.txt')
        r = subprocess.run([PY, os.path.join(MT, 'rebuild_summary.py'),
                            '--results', raw_p, '--suite', suite,
                            '--sample', '50', '--seed', '1',
                            '--root', ROOT, '--final-offset', str(off),
                            '--out', tmp],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print('!! rebuild failed %s: %s' % (raw, r.stderr[-300:]))
            all_ok = False
            continue
        new = total_of(tmp)
        old = total_of(summ_p)
        same = (old == new)
        marker = 'OK ' if same else 'DIFF'
        if apply:
            with open(tmp, 'rb') as f:
                data = f.read()
            if os.path.isfile(summ_p):
                with open(summ_p, 'rb') as f:
                    olddata = f.read()
            else:
                olddata = b''
            if data != olddata:
                with open(summ_p, 'wb') as f:
                    f.write(data)
                print('   written: %s%s' % (summ,
                      ' (totals changed with new checker)' if not same else ''))
            else:
                print('   (unchanged)')
            os.path.exists(tmp) and os.remove(tmp)
            continue
        if not same:
            all_ok = False
        print('%s %-14s %-10s stored=%s rebuilt=%s' %
              (marker, suite, label,
               ('%d/%d' % old) if old else '?',
               ('%d/%d' % new) if new else '?'))
        os.path.exists(tmp) and os.remove(tmp)
    print()
    print('all stored totals reproduced: %s%s' %
          (all_ok, ' (summaries NOT updated; pass --apply)' if not apply else ''))
    return 0 if all_ok else 1


if __name__ == '__main__':
    sys.exit(main())
