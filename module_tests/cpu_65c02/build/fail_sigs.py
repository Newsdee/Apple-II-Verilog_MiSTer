#!/usr/bin/env python3
"""Failure-signature classification for the WDC 65x02 SST sweep (Priority 4).

Three sections:

1. AGREED-REFERENCE opcodes: opcodes where the WDC suite and the MOS 6502
   suite agree on the top-level bus pattern (four_way_report.txt, last column
   "same"). For these, a core failure is a deviation from an agreed reference
   (not a suite-convention artifact), so each failing core's distinct
   first-mismatch signatures are reported. This is the "outstanding
   agreed-reference failure signatures" deliverable; it also records the $DE
   dummy-read outcome (de/fe now PASS 50/50 post Option C).

2. GOLDEN-ONLY-FAIL: opcodes failing on golden but passing on the new core,
   with golden's failure signatures (verification of the classification).

3. BOTH-FAIL: opcodes failing on both cores, new-core vs golden signatures,
   so shared conventions (e.g. Category G BCD extra read) are identifiable.

Inputs (all in this build dir):
  sweep_wdc_abxfix.txt            current new-core summary (rebuild_summary.py)
  sweep_wdc_golden.txt            golden summary (driver stdout capture)
  sweep_wdc_abxfix_results.txt    current new-core raw traces
  sweep_wdc_golden_results.txt    golden raw traces
  four_way_report.txt             WDC-vs-6502 pattern comparison (same/DIFF)

Usage:  python fail_sigs.py [--out fail_sigs_report.txt]
Exit 0 on success.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))

NEW_SUM = 'sweep_wdc_abxfix.txt'
GOLD_SUM = 'sweep_wdc_golden.txt'
FOUR_WAY = 'four_way_report.txt'


def load_summary(path):
    """op -> {'fails': int, 'details': [(test_idx, [msgs])]}

    'fails' is the true per-opcode failure count from the summary line; the
    detail list is capped by the driver's --max-fail-detail (3) and is used
    only for signature sampling."""
    out = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^  ([0-9a-f]{2}): (PASS|FAIL)(?: (\d+)/(\d+))?", lines[i])
        if not m:
            i += 1
            continue
        op = m.group(1)
        entry = {'fails': int(m.group(3)) if m.group(3) else 0, 'details': []}
        out[op] = entry
        i += 1
        if m.group(2) == 'FAIL':
            while i < len(lines):
                mm = re.match(r"^    #(\d+) \[(.*)\]$", lines[i].rstrip('\n'))
                if not mm:
                    break
                idx = int(mm.group(1))
                msgs = []
                i += 1
                while i < len(lines) and lines[i].startswith('      '):
                    msgs.append(lines[i].strip())
                    i += 1
                entry['details'].append((idx, msgs))
            continue
    return out


def msgsig(msg):
    """Normalize one failure message to a kind token (no addresses/data)."""
    m = re.match(r"^cyc\d+: (addr|rw|data) ", msg)
    if m:
        return m.group(1)
    if msg.startswith('cyc') and 'illegal access' in msg:
        return 'illegal-access'
    if msg.startswith('final pc'):
        return 'final-pc'
    if msg.startswith('final s '):
        return 'final-sp'
    for reg in ('a', 'x', 'y', 'p'):
        if msg.startswith(f'final {reg} '):
            return f'final-{reg}'
    if msg.startswith('final ram['):
        return 'final-ram'
    if msg.startswith('cycle count'):
        return 'window'
    if msg == 'no result line':
        return 'no-result'
    return msg.split(' !=')[0][:24]


def sigs_for(op_sum, op):
    """Distinct signature tuples across all recorded failing tests of an opcode."""
    out = set()
    for idx, msgs in op_sum.get(op, {'details': []})['details']:
        out.add(tuple(sorted(set(msgsig(m) for m in msgs))))
    return sorted(out)


def main():
    out_path = os.path.join(HERE, 'fail_sigs_report.txt')
    if '--out' in sys.argv:
        out_path = sys.argv[sys.argv.index('--out') + 1]

    new_sum = load_summary(os.path.join(HERE, NEW_SUM))
    gold_sum = load_summary(os.path.join(HERE, GOLD_SUM))

    # agreed opcodes: four_way_report rows whose last column is 'same'
    # (columns may carry multi-variant strings like 'RRRRRR:28 +1')
    agreed = []
    with open(os.path.join(HERE, FOUR_WAY), encoding='utf-8') as f:
        for line in f:
            m = re.match(r"^\s*([0-9a-f]{2})\s*\|([^|]*)\|", line)
            if m and line.rstrip().endswith('same'):
                agreed.append((m.group(1), m.group(2).strip()))  # (op, wdc pattern)

    lines = []
    w = lines.append
    w('fail_sigs.py report -- WDC 65x02 SST sweep, 50 samples/op, seed=1')
    w(f'new-core summary: {NEW_SUM} ({len(new_sum)} opcodes)')
    w(f'golden summary:   {GOLD_SUM} ({len(gold_sum)} opcodes)')
    w('')

    w(f'=== 1. AGREED-REFERENCE opcodes (WDC == MOS 6502 pattern): {len(agreed)} ===')
    w('A failure here deviates from an agreed reference, not a suite quirk.')
    w(f'{"op":>3} | {"agreed pattern":<14} | {"new core":<12} | {"golden":<12} | signatures (NEW / GOLD)')
    n_new_fail = n_gold_fail = 0
    for op, pat in agreed:
        nf = new_sum.get(op, {'fails': 0})['fails']
        gf = gold_sum.get(op, {'fails': 0})['fails']
        n_new_fail += nf
        n_gold_fail += gf
        ns = ' | '.join(' '.join(s) for s in sigs_for(new_sum, op)) or '-'
        gs = ' | '.join(' '.join(s) for s in sigs_for(gold_sum, op)) or '-'
        w(f'{op:>3} | {pat:<14} | {"PASS" if nf == 0 else f"FAIL {nf}/50":<12} | '
          f'{"PASS" if gf == 0 else f"FAIL {gf}/50":<12} | NEW: {ns}  GOLD: {gs}')
    w(f'agreed-reference failures: new core {n_new_fail}, golden {n_gold_fail} (of {len(agreed)*50} tests each)')
    w('')

    all_ops = sorted(set(new_sum) | set(gold_sum))
    new_failed = {op for op in all_ops if new_sum[op]['fails'] > 0}
    gold_failed = {op for op in all_ops if gold_sum[op]['fails'] > 0}

    w('=== 2. GOLDEN-ONLY-FAIL verification (golden failure signatures) ===')
    gold_only = [op for op in all_ops if op in gold_failed and op not in new_failed]
    for op in gold_only:
        sigs = sigs_for(gold_sum, op)
        w(f'  {op}: {" | ".join(" ".join(s) for s in sigs)}')
    w('')

    w('=== 3. NEW-ONLY-FAIL (new core fails where golden passes) ===')
    new_only = [op for op in all_ops if op in new_failed and op not in gold_failed]
    if not new_only:
        w('  (none)')
    for op in new_only:
        sigs = sigs_for(new_sum, op)
        w(f'  {op}: {" | ".join(" ".join(s) for s in sigs)}')
    w('')

    w('=== 4. BOTH-FAIL: new-core vs golden failure signatures ===')
    both = [op for op in all_ops if op in new_failed and op in gold_failed]
    for op in both:
        ns = ' | '.join(' '.join(s) for s in sigs_for(new_sum, op)) or '-'
        gs = ' | '.join(' '.join(s) for s in sigs_for(gold_sum, op)) or '-'
        w(f'  {op}: NEW {new_sum[op]["fails"]}/50 fail [{ns}]  '
          f'GOLD {gold_sum[op]["fails"]}/50 fail [{gs}]')

    text = '\n'.join(lines) + '\n'
    with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print(text)
    print(f'(written to {out_path})')


if __name__ == '__main__':
    main()
