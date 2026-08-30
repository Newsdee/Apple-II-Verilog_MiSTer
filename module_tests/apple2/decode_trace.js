// decode_trace.js — deterministic trace decoder for the apple2 harness CSVs.
//
// Usage (from repo root or anywhere; paths are given explicitly):
//   node module_tests/apple2/decode_trace.js <trace.csv> [--cpu-en] [--from N] [--to N]
//   node module_tests/apple2/decode_trace.js --diff <a.csv> <b.csv>
//
// Design goals (anti-hallucination):
//  - Column indexes come from the header row, never hard-coded.
//  - T65_REGS is parsed with the layout pinned from source:
//      t65.vhd  : Regs <= PC & S & P & Y(7:0) & X(7:0) & ABC(7:0)   (64 bits, PC = MSB)
//      t65.v    : assign Regs = {PC, S, P, Y[7:0], X[7:0], ABC[7:0]};
//    => string [0:4]=PC [4:8]=S [8:10]=P [10:12]=Y [12:14]=X [14:16]=A
//  - Every parse failure is reported, never silently skipped.
//  - --diff re-verifies field-for-field equivalence independently of the
//    PowerShell harness (same rule: compare all columns row by row).

'use strict';
const fs = require('fs');

function fail(msg) { console.error('ERROR: ' + msg); process.exit(2); }

function parseRegs(s, lineNo) {
  if (!/^[0-9a-fA-FxX]{16}$/.test(s))
    fail(`line ${lineNo}: T65_REGS "${s}" is not 16 hex chars`);
  return {
    PC: s.slice(0, 4), S: s.slice(4, 8), P: s.slice(8, 10),
    Y: s.slice(10, 12), X: s.slice(12, 14), A: s.slice(14, 16),
  };
}

function loadTrace(path) {
  const lines = fs.readFileSync(path, 'utf8').replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  const header = lines[0].split(',');
  const idx = {};
  header.forEach((h, i) => { idx[h.trim()] = i; });
  for (const need of ['CYCLE', 'ADDR', 'PHASE_ZERO', 'T65_REGS', 'T65_DI'])
    if (!(need in idx)) fail(`missing column ${need} in ${path}`);
  const rows = [];
  for (let i = 1; i < lines.length; i++) {
    const f = lines[i].split(',');
    if (f.length !== header.length) fail(`${path} line ${i + 1}: ${f.length} fields, header has ${header.length}`);
    rows.push({
      c: parseInt(f[idx.CYCLE], 10),
      A: f[idx.ADDR].toUpperCase(),
      PZ: f[idx.PHASE_ZERO],
      regs: parseRegs(f[idx.T65_REGS], i + 1),
      DI: f[idx.T65_DI].toUpperCase(),
      D: f[idx.D].toUpperCase(),
      ROM_A: idx.ROM_ADDR !== undefined ? f[idx.ROM_ADDR].toUpperCase() : '-',
      ROM_O: idx.ROM_OUT !== undefined ? f[idx.ROM_OUT].toUpperCase() : '-',
    });
  }
  rows.sort((a, b) => a.c - b.c);
  return rows;
}

function cpuEnEvents(rows) {
  // CPU_EN is high on the cycle where PHASE_ZERO just fell (PZ=0 now, was 1).
  // T65 latches at the rising edge ending that cycle, so the latched byte is
  // T65_DI on this row. Returns rows that are CPU_EN events.
  const out = [];
  for (let i = 0; i < rows.length; i++) {
    if (i > 0 && rows[i].PZ === '0' && rows[i - 1].PZ === '1') out.push(rows[i]);
  }
  return out;
}

function printEvent(r) {
  const g = r.regs;
  console.log(
    `c=${String(r.c).padStart(6)} A=${r.A} DI=${r.DI} Dout=${r.D}` +
    ` | PC=${g.PC} S=${g.S} P=${g.P} Y=${g.Y} X=${g.X} Areg=${g.A}` +
    ` | ROM_A=${r.ROM_A} ROM_O=${r.ROM_O}`
  );
}

function diff(aPath, bPath) {
  const a = fs.readFileSync(aPath, 'utf8').replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  const b = fs.readFileSync(bPath, 'utf8').replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  if (a[0] !== b[0]) fail('header mismatch');
  // Mirror the harness rules exactly (run_equivalence.ps1):
  //  - compare per field (column), case-insensitively
  //  - skip a field when the VHDL value contains a metavalue [UXWZ-]
  const ncols = a[0].split(',').length;
  const n = Math.min(a.length, b.length);
  let mism = 0, ignored = 0, compared = 0;
  for (let i = 1; i < n; i++) {
    const fa = a[i].toUpperCase().split(','), fb = b[i].toUpperCase().split(',');
    for (let c = 0; c < ncols; c++) {
      if (/[UXWZ-]/.test(fa[c])) { ignored++; continue; }
      compared++;
      if (fa[c] !== fb[c]) {
        if (mism < 10) console.log(`row ${i} col ${c} (${a[0].split(',')[c]}): VHDL=${fa[c]} | VERILOG=${fb[c]}`);
        mism++;
      }
    }
  }
  console.log(`diff: rows=${n - 1} compared_fields=${compared} ignored_metavalues=${ignored} mismatches=${mism} (vhdl_lines=${a.length}, verilog_lines=${b.length})`);
  process.exit(mism === 0 && a.length === b.length ? 0 : 1);
}

const args = process.argv.slice(2);
if (args[0] === '--diff') {
  if (args.length < 3) fail('--diff needs two files');
  diff(args[1], args[2]);
  return;
}
if (!args[0]) fail('no input file');
let from = -Infinity, to = Infinity;
const iF = args.indexOf('--from'), iT = args.indexOf('--to');
if (iF >= 0) from = parseInt(args[iF + 1], 10);
if (iT >= 0) to = parseInt(args[iT + 1], 10);
const onlyCpuEn = args.includes('--cpu-en');

const rows = loadTrace(args[0]);
console.log(`# ${args[0]}: rows=${rows.length} first=${rows[0].c} last=${rows[rows.length - 1].c}`);
if (onlyCpuEn) {
  const ev = cpuEnEvents(rows).filter(r => r.c >= from && r.c <= to);
  console.log(`# CPU_EN events in [${from}, ${to}]: ${ev.length}`);
  ev.forEach(printEvent);
} else {
  rows.filter(r => r.c >= from && r.c <= to).forEach(printEvent);
}
