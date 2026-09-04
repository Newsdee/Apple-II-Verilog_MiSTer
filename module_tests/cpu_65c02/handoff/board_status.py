#!/usr/bin/env python3
"""Regenerate handoff/BOARD.md from the task files' status headers.

BOARD.md is generated - never hand-edit it. Workers update their own
task file's header fields; run this to refresh the index:

  python3 handoff/board_status.py
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
TASKS = os.path.join(HERE, 'tasks')

FIELDS = ('status', 'owner', 'created', 'updated', 'eta', 'gate',
          'kind', 'command')
CWD = 'E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/module_tests/cpu_65c02'


def parse_task(path):
    with open(path, 'r', encoding='utf-8') as f:
        lines = f.read().splitlines()
    info = {'file': os.path.basename(path), 'title': '?'}
    if lines and lines[0].startswith('# '):
        info['title'] = lines[0][2:].strip()
    for ln in lines[:14]:
        m = re.match(r'- (%s):\s*(.+)$' % '|'.join(FIELDS), ln)
        if m:
            info[m.group(1)] = m.group(2).strip()
    return info


def write_board():
    tasks = []
    for name in sorted(os.listdir(TASKS)):
        if name.endswith('.md'):
            tasks.append(parse_task(os.path.join(TASKS, name)))
    by = lambda pref: [t for t in tasks
                       if t['file'].startswith(pref)]
    groups = [
        ('A - unattended analysis (agents may run, in parallel)', 'A'),
        ('B - user-gated decisions / user actions', 'B'),
        ('C - RTL fixes (one writer at a time; gated on B3)', 'C'),
    ]
    counts = {}
    for t in tasks:
        counts[t.get('status', '?')] = counts.get(t.get('status', '?'), 0) + 1
    out = []
    out.append('# cpu_65c02 handoff board (generated - do not edit)')
    out.append('')
    out.append('Source of truth: the task files under `tasks/`. Refresh with')
    out.append('`python3 handoff/board_status.py`. Protocol: `handoff/README.md`.')
    out.append('')
    out.append('Status: ' + ', '.join('%s=%d' % (k, v) for k, v in sorted(counts.items())))
    out.append('')
    for title, pref in groups:
        rows = by(pref)
        if not rows:
            continue
        out.append('## %s' % title)
        out.append('')
        out.append('| id | task | kind | status | owner | eta | gate |')
        out.append('|----|------|------|--------|-------|-----|------|')
        for t in rows:
            tid = t['file'].split('-', 1)[0]
            gate = t.get('gate', '-').replace('\n', ' ')
            if len(gate) > 60:
                gate = gate[:57] + '...'
            owner = t.get('owner', '-').replace('\n', ' ')
            if len(owner) > 24:
                owner = owner[:21] + '...'
            out.append('| %s | [%s](tasks/%s) | %s | %s | %s | %s | %s |'
                       % (tid, t['title'][:70], t['file'],
                          t.get('kind', '?'), t.get('status', '?'), owner,
                          t.get('eta', '-'), gate))
        out.append('')
    runners = [t for t in tasks if t.get('kind', '').startswith('runner')]
    if runners:
        out.append('## Runner one-liners (no thinking needed; any shell/agent)')
        out.append('')
        out.append('cwd: %s' % CWD)
        out.append('')
        out.append('| id | command | eta | status |')
        out.append('|----|---------|-----|--------|')
        for t in runners:
            cmd = t.get('command', '?').replace('\n', ' ')
            out.append('| %s | `%s` | %s | %s |'
                       % (t['file'].split('-', 1)[0], cmd,
                          t.get('eta', '-'), t.get('status', '?')))
        out.append('')
    ready = [t['file'].split('-', 1)[0] for t in tasks
             if t.get('status') == 'ready']
    blocked = ['%s (gate: %s)' % (t['file'].split('-', 1)[0],
                                  t.get('gate', '?').split('\n')[0])
               for t in tasks if t.get('status') == 'blocked']
    out.append('Ready now: ' + (', '.join(ready) if ready else 'none'))
    out.append('')
    out.append('Waiting on: ' + (', '.join(blocked) if blocked else 'none'))
    out.append('')
    with open(os.path.join(HERE, 'BOARD.md'), 'w', newline='\n') as f:
        f.write('\n'.join(out))
    print('BOARD.md: %d tasks (%s)'
          % (len(tasks), ', '.join('%s=%d' % (k, v) for k, v in sorted(counts.items()))))


if __name__ == '__main__':
    write_board()
