#!/usr/bin/env python3
"""Provenance metadata for the retained cpu_65c02 SST results.

Writes build/provenance.json recording, for every retained result:
  - suite revision (git commit of E:/MiSTer/Apple-II_FPGAdev/65x02) and tree state
  - sweep parameters (seed=1, 50 samples/op, deterministic selection rule)
  - the exact sampled test IDs (source-array indices per opcode)
  - SHA-256 of the RTL, testbenches, checker tools, binaries, and result files

This is the "checker version" record requested by
CPU_COMPARISON_RECOMMENDATIONS.md Priority 4: a retained result is only as
trustworthy as the hashes recorded here. Re-run after any rebuild or suite
update to refresh; compare old vs new JSON to see exactly what changed.

Usage (MSYS Python):
    python module_tests/cpu_65c02/provenance.py
Output:
    module_tests/cpu_65c02/build/provenance.json
"""
import hashlib, json, os, random, subprocess, sys
from datetime import datetime, timezone

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
MT = os.path.join(REPO, 'module_tests', 'cpu_65c02')
BUILD = os.path.join(MT, 'build')
SUITE_ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
WDC_DIR = os.path.join(SUITE_ROOT, 'wdc65c02', 'v1')
MOS_DIR = os.path.join(SUITE_ROOT, '6502', 'v1')

# ---- sweep parameters (must match sst_driver.py defaults used for the runs)
SEED = 1
SAMPLE = 50
EMPTY_OPS = ('cb', 'db')          # wdc65c02 JSONs exist but contain no tests
TOTAL_TESTS = 254 * SAMPLE        # 12700 (WDC); MOS has all 256 files -> 12800

# ---- files whose hashes pin a retained result (path relative to repo root)
RTL_FILES = {
    'new_core':     ['rtl/new_cpu/cpu_65c02.sv', 'rtl/new_cpu/cpu_alu.sv'],
    'new_core_v2':  ['rtl/new_cpu_v2/cpu_65c02.sv', 'rtl/new_cpu_v2/cpu_alu.sv'],
    'golden':       ['rtl/R65Cx2.sv'],
    't65':          ['module_tests/t65/t65_verilog_tb.sv'],
}
TOOL_FILES = [
    'module_tests/cpu_65c02/sst_driver.py',
    'module_tests/cpu_65c02/semantic_compare.py',
    'module_tests/cpu_65c02/semantic_whitelist.txt',
    'module_tests/cpu_65c02/p3_cases.py',
    'module_tests/cpu_65c02/rebuild_summary.py',
    'module_tests/cpu_65c02/provenance.py',
    'module_tests/cpu_65c02/cpu65_sst_tb.sv',
    'module_tests/cpu_65c02/r65cx2_sst_tb.sv',
    'module_tests/cpu_65c02/cpu65_r65_tb.sv',
    'module_tests/cpu_65c02/build/fail_sigs.py',
    'module_tests/cpu_65c02/build/four_way.py',
    'module_tests/cpu_65c02/build/three_way.py',
    'module_tests/cpu_65c02/build/mos_analysis.py',
    'module_tests/cpu_65c02/build/bcd_classify.py',
    'module_tests/cpu_65c02/build/bcd_bus_check.py',
    'module_tests/cpu_65c02/build/v2_reconcile.py',
    'module_tests/cpu_65c02/build/v2_compare.py',
    'module_tests/cpu_65c02/build/mos_bothfail_decomp.py',
    'module_tests/cpu_65c02/build/analyze_7c_nmos.py',
    'module_tests/cpu_65c02/build/analyze_bcd_xf.py',
    'module_tests/cpu_65c02/build/regen_all_summaries.py',
    'module_tests/cpu_65c02/build/v2nmos_report.py',
]
BINARY_FILES = {
    'new_core_sst':  'module_tests/cpu_65c02/build/sst_verilog/Vcpu65_sst_tb.exe',
    'new_core_v2_sst': 'module_tests/cpu_65c02/build/sst_verilog_v2/Vcpu65_sst_tb_v2.exe',
    'new_core_v2_sst_nmos': 'module_tests/cpu_65c02/build/sst_verilog_v2nmos/Vcpu65_sst_tb_v2.exe',
    'golden_sst':    'module_tests/cpu_65c02/build/sst_r65/Vr65cx2_sst_tb.exe',
    'pair_new_core': 'module_tests/cpu_65c02/build/r65_verilog/Vcpu65_r65_tb.exe',
}
RESULT_FILES = {
    'new_core_sweep_raw':    'module_tests/cpu_65c02/build/sweep_wdc_abxfix_results.txt',
    'option_c_baseline_raw': 'module_tests/cpu_65c02/build/sweep_wdc_nobcdfix_results.txt',
    'golden_sweep_raw':      'module_tests/cpu_65c02/build/sweep_wdc_golden_results.txt',
    'four_way_report':       'module_tests/cpu_65c02/build/four_way_report.txt',
    'three_way_report':      'module_tests/cpu_65c02/build/three_way_report.txt',
    'fail_sigs_report':      'module_tests/cpu_65c02/build/fail_sigs_report.txt',
    'r65_pair_new_trace':    'module_tests/cpu_65c02/build/r65_trace.csv',
    'r65_pair_golden_trace': 'module_tests/r65c02/build/verilog_trace.csv',
    'r65_pair_vhdl_trace':   'module_tests/r65c02/build/vhdl_trace.csv',
    'p3_summary':            'module_tests/cpu_65c02/build/p3/summary.json',
    'semantic_summary':      'module_tests/cpu_65c02/build/semantic_summary.json',
    'mos_new_sweep_raw':     'module_tests/cpu_65c02/build/sweep_6502_abxfix_results.txt',
    'mos_golden_sweep_raw':  'module_tests/cpu_65c02/build/sweep_6502_golden_results.txt',
    'mos_analysis_report':   'module_tests/cpu_65c02/build/mos_analysis_report.txt',
    'v2_wdc_sweep_raw':      'module_tests/cpu_65c02/build/sweep_wdc_v2_results.txt',
    'v2_mos_sweep_raw':      'module_tests/cpu_65c02/build/sweep_6502_v2_results.txt',
    'v2_mos_nmos_sweep_raw': 'module_tests/cpu_65c02/build/sweep_6502_v2nmos_results.txt',
    'v2_rockwell_sweep_raw': 'module_tests/cpu_65c02/build/sweep_rockwell_v2_results.txt',
    'v2_synertek_sweep_raw': 'module_tests/cpu_65c02/build/sweep_synertek_v2_results.txt',
    'rockwell_v1_sweep_raw': 'module_tests/cpu_65c02/build/sweep_rockwell_v1_results.txt',
    'rockwell_golden_sweep_raw': 'module_tests/cpu_65c02/build/sweep_rockwell_golden_results.txt',
    'synertek_v1_sweep_raw': 'module_tests/cpu_65c02/build/sweep_synertek_v1_results.txt',
    'synertek_golden_sweep_raw': 'module_tests/cpu_65c02/build/sweep_synertek_golden_results.txt',
    'v2_reconcile_report':   'module_tests/cpu_65c02/build/v2_reconcile_report.txt',
    'v2nmos_report':         'module_tests/cpu_65c02/build/v2nmos_report.txt',
    'mos_bothfail_report':   'module_tests/cpu_65c02/build/mos_bothfail_report.txt',
    'analyze_7c_report':     'module_tests/cpu_65c02/build/analyze_7c_nmos_report.txt',
    'v2_mos_newonly_list':   'module_tests/cpu_65c02/build/v2_mos_newonly.txt',
}


def sha256_of(rel):
    p = os.path.join(REPO, rel)
    if not os.path.isfile(p):
        return None
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def line_count(rel):
    p = os.path.join(REPO, rel)
    if not os.path.isfile(p):
        return None
    with open(p, 'rb') as f:
        return sum(1 for _ in f)


def suite_info():
    info = {'path': SUITE_ROOT, 'commit': None, 'tree_clean': None}
    try:
        info['commit'] = subprocess.run(
            ['git', '-C', SUITE_ROOT, 'rev-parse', 'HEAD'],
            capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(
            ['git', '-C', SUITE_ROOT, 'status', '--porcelain'],
            capture_output=True, text=True, check=True).stdout.strip()
        info['tree_clean'] = (dirty == '')
    except Exception as e:
        info['error'] = str(e)
    return info


def sampled_test_ids(suite_dir, empty_ops=()):
    """Replicate sst_driver.py selection exactly; return source-array indices."""
    ids = {}
    for op in range(256):
        hexop = '%02x' % op
        if hexop in empty_ops:
            ids[hexop] = []
            continue
        p = os.path.join(suite_dir, hexop + '.json')
        with open(p) as f:
            tests = json.load(f)
        rng = random.Random(SEED * 1000 + op)
        sel = rng.sample(tests, min(SAMPLE, len(tests)))
        by_id = {id(t): i for i, t in enumerate(tests)}
        ids[hexop] = [by_id[id(t)] for t in sel]
    return ids


def raw_pass_count(suite, raw_rel, off):
    """Recompute the pass total directly from the retained RAW results.

    The sweep summary files (build/sweep_*.txt) are derived on demand by
    build/regen_all_summaries.py and are not stored, so this runs the pinned
    checker (select_tests + parse_results + compare) over the raw file.
    Cost: a few seconds per suite.
    """
    p = os.path.join(REPO, raw_rel)
    if not os.path.isfile(p):
        return None
    if MT not in sys.path:
        sys.path.insert(0, MT)
    from rebuild_summary import select_tests      # noqa: E402
    from sst_driver import parse_results, compare  # noqa: E402
    ops = ['%02x' % i for i in range(256)]
    sel = select_tests(SUITE_ROOT, suite, ops, SAMPLE, SEED)
    res = parse_results(p)
    n = sum(1 for idx, (_op, t) in enumerate(sel)
            if res.get(idx) is not None and not compare(t, res[idx], off))
    return '%d/%d' % (n, len(sel))


def main():
    doc = {
        'generated_at': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'python': sys.version.split()[0],
        'suite': suite_info(),
        'sweep': {
            'seed': SEED,
            'samples_per_op': SAMPLE,
            'selection_rule': ('random.Random(seed*1000+op).sample(tests, 50) '
                               'per opcode 00..ff from wdc65c02/v1/<op>.json; '
                               'cb/db JSONs are empty -> 12700 total'),
            'empty_ops': list(EMPTY_OPS),
            'total_tests': TOTAL_TESTS,
            'mos_total_tests': 256 * SAMPLE,
            'capture_window_cycles': 16,
            'status_mask_pb': '0x6F',
            'final_offset': {'new_core': 0, 'golden': 1},
            'checker_note': ('sst_driver.compare() v2 (2026-09): added the '
                             'instruction-complete check — row ncyc (the next '
                             'opcode fetch row; final_offset shifts only the '
                             'register row for R65Cx2\'s late A/flag commit) '
                             'must be a READ at the expected final PC. The '
                             'sweep summary files (build/sweep_*.txt) are '
                             'derived on demand from the raw results by '
                             'build/regen_all_summaries.py and are NOT stored; '
                             'retained_results pass counts are recomputed '
                             'directly from the raw results here.'),
        },
        'sampled_test_ids': sampled_test_ids(WDC_DIR, EMPTY_OPS),
        'sampled_test_ids_mos': sampled_test_ids(MOS_DIR),
        'sampled_test_ids_rockwell': sampled_test_ids(
            os.path.join(SUITE_ROOT, 'rockwell65c02', 'v1')),
        'sampled_test_ids_synertek': sampled_test_ids(
            os.path.join(SUITE_ROOT, 'synertek65c02', 'v1')),
        'files': {
            'rtl': {k: {r: sha256_of(r) for r in v} for k, v in RTL_FILES.items()},
            'tools_and_tbs': {r: sha256_of(r) for r in TOOL_FILES},
            'binaries': {k: sha256_of(v) for k, v in BINARY_FILES.items()},
            'results': {
                k: {'sha256': sha256_of(v), 'lines': line_count(v)}
                for k, v in RESULT_FILES.items()
            },
        },
        'retained_results': {
            'new_core_sweep': {
                'what': 'WDC 65x02 SST sweep, new core, post Option C (current state)',
                'pass_count': raw_pass_count('wdc65c02', RESULT_FILES['new_core_sweep_raw'], 0),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids',
                               'files.rtl.new_core', 'files.binaries.new_core_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.new_core_sweep_raw'],
            },
            'golden_sweep': {
                'what': 'WDC 65x02 SST sweep, golden R65Cx2 (MOS conventions)',
                'pass_count': raw_pass_count('wdc65c02', RESULT_FILES['golden_sweep_raw'], 1),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids',
                               'files.rtl.golden', 'files.binaries.golden_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.golden_sweep_raw'],
            },
            'mos_new_sweep': {
                'what': ('MOS 6502 SST sweep, new core (step 6; 64 opcode files '
                         'are broken references — see FINAL_VERDICT.md §2.4)'),
                'pass_count': raw_pass_count('6502', RESULT_FILES['mos_new_sweep_raw'], 0),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids_mos',
                               'files.rtl.new_core', 'files.binaries.new_core_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.mos_new_sweep_raw'],
            },
            'mos_golden_sweep': {
                'what': 'MOS 6502 SST sweep, golden R65Cx2 (step 6)',
                'pass_count': raw_pass_count('6502', RESULT_FILES['mos_golden_sweep_raw'], 1),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids_mos',
                               'files.rtl.golden', 'files.binaries.golden_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.mos_golden_sweep_raw'],
            },
            'v2_wdc_sweep': {
                'what': 'WDC 65x02 SST sweep, v2 core (new_cpu_v2), WDC_MODE=1',
                'pass_count': raw_pass_count('wdc65c02', RESULT_FILES['v2_wdc_sweep_raw'], 0),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids',
                               'files.rtl.new_core_v2',
                               'files.binaries.new_core_v2_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.v2_wdc_sweep_raw'],
            },
            'v2_mos_sweep': {
                'what': 'MOS 6502 SST sweep, v2 core, WDC_MODE=1',
                'pass_count': raw_pass_count('6502', RESULT_FILES['v2_mos_sweep_raw'], 0),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids_mos',
                               'files.rtl.new_core_v2',
                               'files.binaries.new_core_v2_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.v2_mos_sweep_raw'],
            },
            'v2_mos_nmos_sweep': {
                'what': ('MOS 6502 SST sweep, v2 core, WDC_MODE=0 '
                         '(NMOS bus-convention mode; 6502 replication only)'),
                'pass_count': raw_pass_count('6502', RESULT_FILES['v2_mos_nmos_sweep_raw'], 0),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids_mos',
                               'files.rtl.new_core_v2',
                               'files.binaries.new_core_v2_sst_nmos',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.v2_mos_nmos_sweep_raw'],
            },
            'v2_rockwell_sweep': {
                'what': 'Rockwell 65C02 SST sweep, v2 core',
                'pass_count': raw_pass_count('rockwell65c02', RESULT_FILES['v2_rockwell_sweep_raw'], 0),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids_rockwell',
                               'files.rtl.new_core_v2',
                               'files.binaries.new_core_v2_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.v2_rockwell_sweep_raw'],
            },
            'v2_synertek_sweep': {
                'what': 'Synertek 65C02 SST sweep, v2 core',
                'pass_count': raw_pass_count('synertek65c02', RESULT_FILES['v2_synertek_sweep_raw'], 0),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids_synertek',
                               'files.rtl.new_core_v2',
                               'files.binaries.new_core_v2_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.v2_synertek_sweep_raw'],
            },
        },
    }
    out = os.path.join(BUILD, 'provenance.json')
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(doc, f, indent=1)
        f.write('\n')
    # sanity report
    all_files = (list(TOOL_FILES) + list(BINARY_FILES.values())
                 + list(RESULT_FILES.values())
                 + [r for v in RTL_FILES.values() for r in v])
    missing = [r for r in all_files if sha256_of(r) is None]
    print('wrote', os.path.relpath(out, REPO))
    print('suite commit:', doc['suite']['commit'], 'clean:', doc['suite']['tree_clean'])
    for k in ('new_core_sweep', 'golden_sweep', 'v2_wdc_sweep', 'v2_mos_nmos_sweep'):
        print(' %s: %s' % (k, doc['retained_results'][k]['pass_count']))
    if missing:
        print('MISSING files:')
        for m in missing:
            print('  ', m)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
