#!/usr/bin/env python3
"""A3: rank both-fail opcodes by real-software relevance (deterministic).

The T1 join (build/new6502_three_way_join.md, section 5) found 4827 MOS
both-fail tests across 105 opcodes. Fixing all 105 is not the goal; this
script ranks them by how often real Apple II software's bytes contain
each opcode, so the user can pick a bounded fix list (B3 input).

Method (v1, static):
  * Byte histogram over whole retained images (Total Replay HD, Mini
    Replay disk, Apple IIe ROM MIF). A byte's presence ANYWHERE in an
    image is an UPPER BOUND on it being executed as an opcode (it may be
    data/operand) - the confidence column says exactly that. A byte with
    ZERO hits in all images is a strong "never executed" signal.
  * The 105-op population + C5/C6 counts + the campaign's own class
    labels are parsed from the committed T1 join report (section 5).
  * No 6502/65C02 opcode table is embedded: legality is NOT a ranking
    input; it stays a user judgment (see report note).
  * Image sha256 is recorded before and after opening each image
    (read-only proof).

Outputs: build/op_relevance_ranking.md  (deterministic; no timestamps)
Usage:
  python3 build/op_relevance_ranking.py          # full run (all images)
  python3 build/op_relevance_ranking.py --mini   # one image (pipeline proof)
"""
import hashlib
import os
import re
import sys

BUILD = os.path.dirname(os.path.abspath(__file__))          # .../cpu_65c02/build
CAMPAIGN = os.path.dirname(BUILD)                           # .../cpu_65c02
REPO = os.path.abspath(os.path.join(CAMPAIGN, '..', '..'))  # Apple-II-Verilog_MiSTer
WORKSPACE = os.path.abspath(os.path.join(REPO, '..'))       # Apple-II_FPGAdev

JOIN_MD = os.path.join(BUILD, 'new6502_three_way_join.md')
OUT_MD = os.path.join(BUILD, 'op_relevance_ranking.md')

IMAGES = [
    ('TR52.hdv', os.path.join(REPO, 'disks', 'Total Replay v5.2.hdv')),
    ('MiniReplay.dsk', os.path.join(REPO, 'disks', 'Mini Replay v1.1.dsk')),
    ('apple2e.rom', os.path.join(WORKSPACE, 'Apple-II_MiSTer_newsdee',
                                 'rtl', 'roms', 'apple2e.mif')),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def load_image_bytes(path, kind):
    with open(path, 'rb') as f:
        data = f.read()
    if kind != 'mif':
        return data
    # MIF: metadata lines (KEY = value;), optional @ADDR, hex data, END;
    text = data.decode('latin-1')
    out = bytearray()
    for ln in text.splitlines():
        s = ln.strip()
        if not s or s.startswith('--') or '=' in s:
            continue
        if s.upper().startswith('END'):
            break
        if s.upper().startswith('@'):
            continue
        for tok in re.split(r'[\s,]+', s):
            if tok and re.fullmatch(r'[0-9A-Fa-f]{1,2}', tok):
                out.append(int(tok, 16))
    return bytes(out)


def histogram(data):
    hist = [0] * 256
    for b in data:
        hist[b] += 1
    return hist


def parse_join_table():
    """Parse section 5 of the T1 join report -> list of per-op rows."""
    with open(JOIN_MD, 'r', encoding='utf-8') as f:
        lines = f.read().splitlines()
    start = None
    for i, ln in enumerate(lines):
        if ln.startswith('## 5.'):
            start = i
            break
    if start is None:
        raise SystemExit('section 5 not found in %s' % JOIN_MD)
    ops = []
    for ln in lines[start + 1:]:
        if not ln.startswith('|'):
            if ops:
                break
            continue
        cells = [c.strip() for c in ln.strip().strip('|').split('|')]
        if cells[0] in ('op',) or set(cells[0]) <= set('-: '):
            continue
        try:
            op = int(cells[0], 16)
            both = int(cells[2])
            c5 = int(cells[7])
            c6 = int(cells[8])
        except ValueError:
            continue
        if both > 0:
            ops.append({'op': op, 'cls': cells[1], 'both': both,
                        'c5': c5, 'c6': c6})
    return ops


def main():
    mini = '--mini' in sys.argv[1:]
    if mini:
        images = [IMAGES[1]]  # one small image (pipeline proof)
        OUT = os.path.join(BUILD, 'op_relevance_ranking_mini.md')
    else:
        images = IMAGES
        OUT = OUT_MD

    ops = parse_join_table()
    if len(ops) < 100:
        raise SystemExit('join table parse yielded %d ops (expect ~105)'
                         % len(ops))

    sha_before = {}
    hist = {}
    sizes = {}
    for name, path in images:
        if not os.path.exists(path):
            raise SystemExit('image missing: %s' % path)
        sha_before[name] = sha256(path)
        kind = 'mif' if path.lower().endswith('.mif') else 'raw'
        data = load_image_bytes(path, kind)
        hist[name] = histogram(data)
        sizes[name] = len(data)
    sha_after = {n: sha256(p) for n, p in images}
    for n in sizes:
        if sha_before[n] != sha_after[n]:
            raise SystemExit('IMAGE MODIFIED: %s (sha changed)' % n)

    # rank population
    rows = []
    for o in ops:
        hits = {n: hist[n][o['op']] for n in hist}
        total = sum(hits.values())
        rows.append(dict(o, hits=hits, total=total))
    nonzero = sorted(r['total'] for r in rows if r['total'] > 0)

    def label(r):
        if r['total'] == 0:
            return 'drop (zero static hits in real images)'
        if not nonzero:
            return 'fix later'
        # percentile among the nonzero-hit ops (rank 1 = most hits)
        rank = sum(1 for t in nonzero if t > r['total']) + 1
        pct = rank / float(len(nonzero))
        if pct <= 0.25:
            return 'fix now (top quartile of real-code hits)'
        return 'fix later'

    rows.sort(key=lambda r: (-r['total'], -(r['c5'] + r['c6']), r['op']))

    out = []
    p = out.append
    p('# A3 - both-fail opcode real-world relevance ranking')
    p('')
    p('Population: the %d opcodes with MOS both-fail tests in the T1 join'
      % len(rows))
    p('(build/new6502_three_way_join.md section 5: %d both-fail tests).'
      % sum(r['both'] for r in rows))
    p('')
    p('## Method')
    p('')
    p('- STATIC byte histogram over whole images. A byte appearing anywhere')
    p('  is an UPPER BOUND on executions as an opcode (it may be data or an')
    p('  operand). ZERO hits across all images is a strong never-executed')
    p('  signal; nonzero hits say plausible, not executed.')
    p('- Confidence: image-wide (code-region boundaries not identified in')
    p('  v1). Refinement path: locate Total Replay boot/OS tracks and')
    p('  re-histogram just those (future pass).')
    p('- No 6502/65C02 opcode table is embedded: legality is not a ranking')
    p('  input. Judge legality against the standard 65C02 table before')
    p('  acting on any row; the campaign `class` column (from the join) is')
    p('  the existing classification.')
    p('- Ranking: (real-code hits desc, C5+C6 desc, op asc).')
    p('- Deterministic; re-run reproduces this file byte-for-byte.')
    p('')
    p('## Images (read-only proof: sha256 before == after for all)')
    p('')
    p('| image | path | bytes | sha256 |')
    p('|-------|------|-------|--------|')
    for name, path in images:
        p('| %s | %s | %d | %s |' % (name, path.replace('\\', '/'),
                                     sizes[name], sha_before[name]))
    p('')
    p('## Ranked table (all %d both-fail ops)' % len(rows))
    p('')
    names = [n for n, _ in images]
    hcells = ['op', 'class', 'both-fail', 'C5', 'C6'] + \
             ['hits(%s)' % n for n in names] + ['total', 'label']
    scells = ['----', '-------', '-----------', '----', '----'] + \
             ['------------'] * len(names) + ['-----------', '-------------']
    p('| ' + ' | '.join(hcells) + ' |')
    p('|' + '|'.join(scells) + '|')
    for r in rows:
        cells = ['%02x' % r['op'], r['cls'], str(r['both']),
                 str(r['c5']), str(r['c6'])] + \
                [str(r['hits'][n]) for n in names] + \
                [str(r['total']), label(r)]
        p('| ' + ' | '.join(cells) + ' |')
    p('')
    p('## Context: most frequent byte values in the HD image')
    p('')
    if 'TR52.hdv' in hist:
        h = hist['TR52.hdv']
        top = sorted(range(256), key=lambda b: (-h[b], b))[:20]
        p('| byte | hits | note |')
        p('|------|------|------|')
        for b in top:
            note = ''
            if b in [r['op'] for r in rows]:
                note = 'in both-fail population'
            p('| %02x | %d | %s |' % (b, h[b], note))
    p('')
    p('## Label rules')
    p('')
    p('- `drop`: zero static hits in every image - no evidence real')
    p('  software executes it; document as suite-only (B3: recommend drop).')
    p('- `fix now`: nonzero hits in the top quartile of the nonzero-hit')
    p('  population - strongest real-world relevance signal.')
    p('- `fix later`: nonzero hits, below the top quartile.')
    p('')
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(out) + '\n')
    print('wrote %s (%d ops ranked; images: %s)'
          % (OUT, len(rows), ', '.join(n for n, _ in images)))


if __name__ == '__main__':
    main()
