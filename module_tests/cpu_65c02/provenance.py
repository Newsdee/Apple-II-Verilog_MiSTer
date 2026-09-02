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
    'new_core': ['rtl/new_cpu/cpu_65c02.sv', 'rtl/new_cpu/cpu_alu.sv'],
    'golden':   ['rtl/R65Cx2.sv'],
    't65':      ['module_tests/t65/t65_verilog_tb.sv'],
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
]
BINARY_FILES = {
    'new_core_sst':  'module_tests/cpu_65c02/build/sst_verilog/Vcpu65_sst_tb.exe',
    'golden_sst':    'module_tests/cpu_65c02/build/sst_r65/Vr65cx2_sst_tb.exe',
    'pair_new_core': 'module_tests/cpu_65c02/build/r65_verilog/Vcpu65_r65_tb.exe',
}
RESULT_FILES = {
    'new_core_sweep_raw':    'module_tests/cpu_65c02/build/sweep_wdc_abxfix_results.txt',
    'new_core_sweep_summary':'module_tests/cpu_65c02/build/sweep_wdc_abxfix.txt',
    'option_c_baseline_raw': 'module_tests/cpu_65c02/build/sweep_wdc_nobcdfix_results.txt',
    'golden_sweep_raw':      'module_tests/cpu_65c02/build/sweep_wdc_golden_results.txt',
    'golden_sweep_summary':  'module_tests/cpu_65c02/build/sweep_wdc_golden.txt',
    'four_way_report':       'module_tests/cpu_65c02/build/four_way_report.txt',
    'three_way_report':      'module_tests/cpu_65c02/build/three_way_report.txt',
    'fail_sigs_report':      'module_tests/cpu_65c02/build/fail_sigs_report.txt',
    'r65_pair_new_trace':    'module_tests/cpu_65c02/build/r65_trace.csv',
    'r65_pair_golden_trace': 'module_tests/r65c02/build/verilog_trace.csv',
    'r65_pair_vhdl_trace':   'module_tests/r65c02/build/vhdl_trace.csv',
    'p3_summary':            'module_tests/cpu_65c02/build/p3/summary.json',
    'semantic_summary':      'module_tests/cpu_65c02/build/semantic_summary.json',
    'mos_new_sweep_raw':     'module_tests/cpu_65c02/build/sweep_6502_abxfix_results.txt',
    'mos_new_sweep_summary': 'module_tests/cpu_65c02/build/sweep_6502_abxfix.txt',
    'mos_golden_sweep_raw':  'module_tests/cpu_65c02/build/sweep_6502_golden_results.txt',
    'mos_golden_summary':    'module_tests/cpu_65c02/build/sweep_6502_golden.txt',
    'mos_analysis_report':   'module_tests/cpu_65c02/build/mos_analysis_report.txt',
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


def summary_pass_count(rel):
    """Parse the '=== wdc65c02: N/M pass ===' line from a summary file."""
    p = os.path.join(REPO, rel)
    if not os.path.isfile(p):
        return None
    with open(p, encoding='utf-8', errors='replace') as f:
        for line in f:
            if ' pass ===' in line or 'pass===' in line:
                num = line.split(':')[1].split('p')[0].strip()
                return num
    return None


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
        },
        'sampled_test_ids': sampled_test_ids(WDC_DIR, EMPTY_OPS),
        'sampled_test_ids_mos': sampled_test_ids(MOS_DIR),
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
                'pass_count': summary_pass_count(RESULT_FILES['new_core_sweep_summary']),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids',
                               'files.rtl.new_core', 'files.binaries.new_core_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.new_core_sweep_raw'],
            },
            'golden_sweep': {
                'what': 'WDC 65x02 SST sweep, golden R65Cx2 (MOS conventions)',
                'pass_count': summary_pass_count(RESULT_FILES['golden_sweep_summary']),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids',
                               'files.rtl.golden', 'files.binaries.golden_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.golden_sweep_raw'],
            },
            'mos_new_sweep': {
                'what': ('MOS 6502 SST sweep, new core (step 6; 64 opcode files '
                         'are broken references — see FINAL_VERDICT.md §2.4)'),
                'pass_count': summary_pass_count(RESULT_FILES['mos_new_sweep_summary']),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids_mos',
                               'files.rtl.new_core', 'files.binaries.new_core_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.mos_new_sweep_raw'],
            },
            'mos_golden_sweep': {
                'what': 'MOS 6502 SST sweep, golden R65Cx2 (step 6)',
                'pass_count': summary_pass_count(RESULT_FILES['mos_golden_summary']),
                'depends_on': ['suite.commit', 'sweep.*', 'sampled_test_ids_mos',
                               'files.rtl.golden', 'files.binaries.golden_sst',
                               'files.tools_and_tbs[module_tests/cpu_65c02/sst_driver.py]',
                               'files.results.mos_golden_sweep_raw'],
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
    print('new core:', doc['retained_results']['new_core_sweep']['pass_count'],
          ' golden:', doc['retained_results']['golden_sweep']['pass_count'])
    if missing:
        print('MISSING files:')
        for m in missing:
            print('  ', m)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
