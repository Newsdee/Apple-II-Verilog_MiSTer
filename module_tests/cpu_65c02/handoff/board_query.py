#!/usr/bin/env python3
"""Offline board execution helper for run_board.bat (no session needed).

Modes (called by run_board.bat, also usable directly):
  list                          - print the task table
  refresh                       - regenerate BOARD.md
  runners [--force]             - run runner tasks sequentially (logged);
                                  default requires status=ready; --force
                                  runs any runner whose gate script exists
  thinking [ids...] [--dry-run] [-- extra pi args...]
                                - spawn detached `pi -p` console windows
                                  for thinking tasks (default: ready A*
                                  tasks; explicit ids allowed)

Each spawned thinking worker is an ephemeral `pi -p --no-session` process
in its own console window; the task file (progress log + status fields)
is the record, not the pi session.
"""
import datetime
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CAMPAIGN = os.path.dirname(HERE)
TASKS = os.path.join(HERE, 'tasks')
LOGS = os.path.join(HERE, 'logs')
sys.path.insert(0, HERE)
import board_status  # noqa: E402

AGENTS_MD = r'E:\MiSTer\Apple-II_FPGAdev\AGENTS.md'
TODAY = datetime.date.today().isoformat()


def pi_available():
    try:
        r = subprocess.run('where pi', shell=True, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE)
        return r.returncode == 0
    except Exception:
        return False


def all_tasks():
    out = []
    for name in sorted(os.listdir(TASKS)):
        if name.endswith('.md'):
            out.append(board_status.parse_task(os.path.join(TASKS, name)))
    return out


def tid_of(t):
    return t['file'].split('-', 1)[0]


def clean_command(t):
    c = t.get('command', '').strip()
    return re.sub(r'^\(cwd[^)]*\)\s*', '', c)


def script_of(cmd):
    parts = cmd.split()
    for i, p in enumerate(parts):
        if p in ('python3', 'python') and i + 1 < len(parts):
            return parts[i + 1]
    return None


def update_task(path, status=None, owner=None, log_line=None):
    with open(path, 'r', encoding='utf-8') as f:
        text = f.read()
    lines = text.splitlines()

    def setfield(name, val):
        for i, ln in enumerate(lines):
            if re.match(r'- %s:' % name, ln):
                lines[i] = '- %s: %s' % (name, val)
                return
        lines.insert(2, '- %s: %s' % (name, val))

    if status:
        setfield('status', status)
    if owner:
        setfield('owner', owner)
    setfield('updated', TODAY)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + ('\n' if text.endswith('\n') else ''))
    if log_line:
        with open(path, 'a', encoding='utf-8', newline='\n') as f:
            f.write('\n- %s: %s\n' % (TODAY, log_line))


def do_list():
    for t in all_tasks():
        cmd = clean_command(t) if t.get('kind', '').startswith('runner') else ''
        print('%-4s %-18s %-24s %-24s %s'
              % (tid_of(t), t.get('kind', '?'), t.get('status', '?'),
                 t.get('owner', '-')[:24], cmd))
    board_status.write_board()


def do_runners(force=False):
    os.makedirs(LOGS, exist_ok=True)
    ran = ok = 0
    for t in all_tasks():
        if not t.get('kind', '').startswith('runner'):
            continue
        tid = tid_of(t)
        cmd = clean_command(t)
        if not cmd:
            print('SKIP  %-4s: no command field' % tid)
            continue
        script = script_of(cmd)
        spath = os.path.join(CAMPAIGN, script) if script else None
        if not spath or not os.path.exists(spath):
            print('SKIP  %-4s: gate script missing (%s)' % (tid, script))
            continue
        if not force and t.get('status') != 'ready':
            print('SKIP  %-4s: status=%s (not ready; rerun with --force)'
                  % (tid, t.get('status')))
            continue
        log = os.path.join(LOGS, tid + '.log')
        print('RUN   %-4s: %s  (log: handoff/logs/%s.log)' % (tid, cmd, tid))
        update_task(os.path.join(TASKS, t['file']), status='running',
                    owner='run_board.bat',
                    log_line='run_board.bat started runner (%s)' % cmd)
        with open(log, 'w', encoding='utf-8') as lf:
            rc = subprocess.call(cmd, shell=True, cwd=CAMPAIGN,
                                 stdout=lf, stderr=subprocess.STDOUT)
        ran += 1
        if rc == 0:
            ok += 1
            update_task(os.path.join(TASKS, t['file']), status='review',
                        log_line='run_board.bat finished runner, exit 0; '
                                 'artifacts + determinism re-run per task '
                                 'protocol; log handoff/logs/%s.log' % tid)
            print('PASS  %-4s (exit 0) - task set to review' % tid)
        else:
            update_task(os.path.join(TASKS, t['file']), status='blocked',
                        log_line='run_board.bat runner FAILED exit %d - '
                                 'no debugging per protocol; log '
                                 'handoff/logs/%s.log' % (rc, tid))
            print('FAIL  %-4s (exit %d) - task set to blocked' % (tid, rc))
    board_status.write_board()
    print('runners: %d run, %d ok' % (ran, ok))
    return 0


def spawn_line(tid, taskfile, extra):
    brief = ('You are an offline kanban worker for the cpu_65c02 handoff '
             'board. Read %s and the task file %s, then execute the task '
             'exactly per its protocol (gate check, May write paths, '
             'acceptance, progress log, board refresh). Work autonomously '
             'to completion. Do not commit to git. Do not run Quartus. '
             'When finished, update your task file status to review (or '
             'blocked with the reason) and run python3 handoff\\board_status.py.'
             % (AGENTS_MD, taskfile))
    return 'title pi-%s & pi -p --no-session "%s"%s' % (tid, brief, extra)


def do_thinking(ids=None, dry=False, extra=''):
    if not pi_available():
        print('ERROR: pi CLI not found (where pi failed).')
        print('       thinking tasks need pi; runners do NOT (python3 only).')
        print('       Install/fix pi, or run: run_board.bat runners')
        return 1
    spawned = 0
    for t in all_tasks():
        if not t.get('kind', '').startswith('thinking'):
            continue
        tid = tid_of(t)
        if ids:
            if tid not in ids:
                continue
        elif not tid.startswith('A') or t.get('status') != 'ready':
            continue
        if t.get('status') not in ('ready', 'running'):
            print('REFUSE %s: status=%s (gate not met%s)'
                  % (tid, t.get('status'),
                     '; C tasks are gated on B3' if tid.startswith('C')
                     else ''))
            continue
        line = spawn_line(tid, os.path.join('handoff', 'tasks', t['file']),
                          extra)
        if dry:
            print('DRY   %s: %s' % (tid, line))
            continue
        subprocess.Popen(line, shell=True, cwd=CAMPAIGN,
                         creationflags=subprocess.CREATE_NEW_CONSOLE)
        spawned += 1
        print('SPAWN %s: new console window "pi-%s" (detached)' % (tid, tid))
    return 0


def main(argv):
    mode = argv[0] if argv else 'list'
    rest = argv[1:]
    force = '--force' in rest
    dry = '--dry-run' in rest
    args = [a for a in rest if a not in ('--force', '--dry-run')]
    extra = ''
    if '--' in args:
        i = args.index('--')
        extra = ' ' + ' '.join(args[i + 1:])
        args = args[:i]
    if mode == 'list':
        return do_list()
    if mode == 'refresh':
        board_status.write_board()
        return 0
    if mode == 'runners':
        return do_runners(force)
    if mode == 'thinking':
        return do_thinking(ids=args or None, dry=dry, extra=extra)
    if mode == 'all':
        rc = do_runners(force)
        if pi_available():
            rc = do_thinking(ids=args or None, dry=dry, extra=extra) or rc
        else:
            print('notice: pi not found - thinking tasks skipped '
                  '(runners ran; see `thinking` for how to enable)')
        return rc
    print('unknown mode: %s' % mode)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
