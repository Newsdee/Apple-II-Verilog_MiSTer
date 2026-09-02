#!/usr/bin/env python3
"""Priority 3 directed-coverage cases: new core vs R65Cx2 golden.

Runs focused stimulus pairs through the two r65-pair testbenches (no TB
changes in phase 1): the shared memory image is swapped per case (backup +
restore), both exes run with the same plusargs, traces are saved under
build/p3/<case>/, and each pair is checked with semantic_compare.py plus
per-case coverage gates.

Cases (phase 1, no TB change):
  p3-brk           BRK status/return-address pushes + IRQ vector entry
  p3-rti           RTI restoration (both cores restore N,V,D,I,Z,C from the
                   stack byte identically in their P columns; R65Cx2's
                   calcT |0x30 forcing shows only transiently in T/dout)
  p3-irq-masked    IRQ pulse while I=1 -> no entry
  p3-irq-unmask    CLI then IRQ pulse -> entry (expect='entry-latency')
  p3-nmi-priority  simultaneous IRQ+NMI pulses -> NMI serviced, IRQ not
                   (expect='entry-latency')
  p3-nmi-during-irq  NMI pulse inside the IRQ handler -> NMI preempts
                   (expect='entry-latency')
  p3-adj-shift     IRQ pulse immediately after ASL abs,X (the G=7c/N=6c
                   length-delta instruction) -> entry at same boundary
                   (expect='entry-latency')
  p3-jmpax         JMP (abs,X) with X!=0 and low-byte wrap with page carry

Phase 2 cases (TB +RESETAT / +WRTOGGLE plusargs, both default-off and
behavior-preserving; see the TB headers for the contracts):
  p3-reset-park    mid-stream reset in the self-JMP park operand phase
                   (control: both cores lockstep before reset)
  p3-reset-midinsn mid-stream reset in a JSR operand phase (no push write
                   landed yet); post-reset re-execution must be equivalent
  p3-reset-midpush mid-stream reset inside a PHA/PHP push sequence with
                   WRTOGGLE=1: any ungated stale commit during the window
                   flips write parity and fails final-memory equality
  p3-rmw-toggle    six RMW instructions (ASL/EOR/INC/TSB/ROL/DEC abs) over
                   scratch RAM with WRTOGGLE=1: golden's old-value pre-write
                   is two strokes (final = initial byte), the new core's
                   single write is one stroke (final = initial^1; under pure
                   toggle semantics dout is discarded, so only stroke parity
                   matters); the harness reconstructs real final memory from
                   stroke parity and checks exact per-address values
                   (expect='rmw-toggle')

Entry-latency model (documented microarchitectural delta, not a bug):
  the golden R65Cx2 registers irqReg/nmiEdge only after a fetch that is not
  branch-taken/opcode-fetch and enters on the NEXT opcode fetch, so it has
  one extra dummy entry-fetch row; the new core samples take_int
  combinationally in S_FETCH and pushes starting one cycle earlier. For
  expect='entry-latency' cases the harness uses a resync comparison instead
  of semantic_compare.py: identical prefix, at most one extra golden fetch
  per entry (whose address must equal that entry's pushed return PC),
  identical park-loop tail (length delta <= 2), paired stack push triples
  with return-PC delta in {0,1,2} (status must match when the boundary is
  shared), and identical final state except PC within the park window.

Exit: 0 all cases as expected, 1 unexpected failure/usage error.

Run from the repo root (Apple-II-Verilog_MiSTer):
  /c/msys64/ucrt64/bin/python module_tests/cpu_65c02/p3_cases.py [--only NAME]
"""
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys

REPO = os.getcwd()
if not os.path.exists(os.path.join(REPO, "module_tests", "r65c02")):
    sys.exit("run from the Apple-II-Verilog_MiSTer repo root")

PY = r"C:\msys64\ucrt64\bin\python.exe"
HEX = os.path.join("module_tests", "r65c02", "build", "r65_mem_init.hex")
G_EXE = os.path.join("module_tests", "r65c02", "build", "verilog", "Vr65c02_verilog_tb.exe")
N_EXE = os.path.join("module_tests", "cpu_65c02", "build", "r65_verilog", "Vcpu65_r65_tb.exe")
G_CSV = os.path.join("module_tests", "r65c02", "build", "verilog_trace.csv")
N_CSV = os.path.join("module_tests", "cpu_65c02", "build", "r65_trace.csv")
CHECKER = os.path.join("module_tests", "cpu_65c02", "semantic_compare.py")
P3DIR = os.path.join("module_tests", "cpu_65c02", "build", "p3")
TOTAL = 400          # trace length per case (program is short; parks at end)
PULSE_LEN = 8        # TB pulse width in cycles
PROG_BASE = 0x0500   # reset vector points here in the base image
PARK = "0908"        # self-JMP park loop present in the base image

# ---------------------------------------------------------------------------
# Case table. prog: {addr: [bytes]} patched over the base image.
# irq_vec/nmi_vec: 16-bit handler entry (patched into $FFFE/$FFFF, $FFFA/B).
# pulses: names of pulse kinds to apply ('irq', 'nmi'); anchors give the
#         address whose fetch cycle centers the pulse window.
# gates: fetch must occur in both traces (semantic_compare.py --gate for
#        positional cases; checked directly for entry-latency cases).
# expect: 'pass' | 'entry-latency' (resync comparison) | 'rmw-toggle'
#         (harness-side real-memory reconstruction under +WRTOGGLE=1).
# Phase 2 keys: wr_toggle (pass +WRTOGGLE=1 to both TBs), anchors['reset']
# (address whose probe fetch cycle starts the +RESETAT window),
# reset_offset (cycles after that fetch), and converge_at (address of the
# fetch at which state-boundary comparison starts -- one fetch after the
# first fully-converged fetch; see semantic_compare.py --compare-from,
# needed because the two cores have different reset contracts).
#
# Stack model (verified empirically on both cores, phase 1):
#   push (PHA/PHP/BRK/interrupt entry): store at [S], then S <- S-1.
#   RTI: P <- [S+1], PC_lo <- [S+2], PC_hi <- [S+3], S <- S+3.
# ---------------------------------------------------------------------------
PROLOGUE = {0x0500: [0xA2, 0xFD], 0x0502: [0x9A]}  # LDX #$FD; TXS (SP=FD both)
HANDLER_PARK = [0x4C, 0x08, 0x09]                  # JMP $0908 (base park loop)

CASES = [
    dict(name="p3-brk", expect="pass",
         prog={**PROLOGUE, 0x0503: [0x00],            # BRK
                                0x0600: [0x4C, 0x08, 0x09]},  # handler: park
         irq_vec=0x0600, nmi_vec=None, pulses=[],
         gates={"brk_entry": "0600", "park": PARK}),

    dict(name="p3-rti", expect="pass",
         prog={**PROLOGUE, 
             0x0503: [0xA9, 0x09],   # LDA #$09  pc hi
             0x0505: [0x48],         # PHA -> [FD] = 09 (pc hi)
             0x0506: [0xA9, 0x05],   # LDA #$05  pc lo
             0x0508: [0x48],         # PHA -> [FC] = 05 (pc lo)
             0x0509: [0xA9, 0x20],   # LDA #$20  status N0V0R1B0D0I0Z0C0
             0x050B: [0x48],         # PHA -> [FB] = 20 (status)
             0x050C: [0x40]},        # RTI -> P=20, PC=0905 (base JMP $0908)
         irq_vec=None, nmi_vec=None, pulses=[],
         gates={"rti_target": "0905", "park": PARK}),

    dict(name="p3-irq-masked", expect="pass", no_entry_at="0600",
         prog={**PROLOGUE, 
             0x0503: [0x78],         # SEI
             0x0504: [0xEA, 0xEA, 0xEA],   # NOP sled <- pulse here (masked)
             0x0507: [0x4C, 0x08, 0x09]},               # park
         irq_vec=0x0600, nmi_vec=None,
         pulses=["irq"], anchors={"irq": 0x0505},
         gates={"park": PARK}),

    dict(name="p3-irq-unmask", expect="entry-latency",
         prog={**PROLOGUE, 
             0x0503: [0x58],         # CLI
             0x0504: [0xEA, 0xEA, 0xEA],   # NOP sled <- pulse here (unmasked)
             0x0507: HANDLER_PARK,         # fallback park (no entry)
             0x0600: HANDLER_PARK},        # IRQ handler: park
         irq_vec=0x0600, nmi_vec=None,
         pulses=["irq"], anchors={"irq": 0x0505},
         gates={"irq_entry": "0600", "park": PARK}),

    dict(name="p3-nmi-priority", expect="entry-latency", no_entry_at="0600",
         prog={**PROLOGUE, 
             0x0503: [0x58],         # CLI
             0x0504: [0xEA, 0xEA, 0xEA],   # NOP sled <- both pulses here
             0x0600: [0xA9, 0x5A],   # IRQ handler (must NOT be reached)
             0x0602: HANDLER_PARK,
             0x0610: [0xA9, 0x5B],   # NMI handler
             0x0612: HANDLER_PARK},
         irq_vec=0x0600, nmi_vec=0x0610,
         pulses=["irq", "nmi"], anchors={"irq": 0x0505, "nmi": 0x0505},
         gates={"nmi_entry": "0610", "park": PARK}),

    dict(name="p3-nmi-during-irq", expect="entry-latency", two_stage=True,
         prog={**PROLOGUE, 
             0x0503: [0x58],         # CLI
             0x0504: [0xEA],         # NOP <- IRQ pulse anchor
             0x0505: [0x4C, 0x08, 0x09]},   # park (fallback if no IRQ entry)
         irq_vec=0x0600, nmi_vec=0x0610,
         pulses=["irq", "nmi"], anchors={"irq": 0x0504},
         # NMI anchor is inside the IRQ handler; resolved in stage 2.
         prog_stage2={0x0600: [0xEA, 0xEA, 0xEA],   # IRQ handler: NOP sled
                      0x0610: [0xA9, 0x5B],        # NMI handler
                      0x0612: HANDLER_PARK},
         gates={"irq_entry": "0600", "nmi_entry": "0610", "park": PARK}),

    dict(name="p3-adj-shift", expect="entry-latency",
         prog={**PROLOGUE, 
             0x0503: [0x58],              # CLI
             0x0504: [0x1E, 0x00, 0x0A],  # ASL $0A00,X (G=7c/N=6c delta insn)
             0x0507: [0xEA],              # NOP <- IRQ pulse anchor
             0x0508: HANDLER_PARK,        # fallback park (no entry)
             0x0600: HANDLER_PARK},       # IRQ handler: park
         irq_vec=0x0600, nmi_vec=None,
         pulses=["irq"], anchors={"irq": 0x0507},
         gates={"irq_entry": "0600", "park": PARK}),

    dict(name="p3-jmpax", expect="pass",
         prog={**PROLOGUE, 
             0x0503: [0xA2, 0x07],      # LDX #$07
             0x0505: [0x7C, 0x00, 0x0A],  # JMP ($0A00,X) EA=0A07 -> ptr1
             0x0A0B: [0xA2, 0xFF],      # stage 2 (scratch filler area)
             0x0A0D: [0x7C, 0x01, 0x0A]},  # JMP ($0A01,X) EA=0B00 (wrap+carry)
         irq_vec=None, nmi_vec=None, pulses=[],
         extra={0x0A07: [0x0B, 0x0A],   # ptr1 @EA=0A07 -> 0A0B (stage 2)
                0x0B00: [0x08, 0x09]},  # ptr2 @EA=0B00 -> 0908 (base park)
         gates={"jmpax1": "0A0B", "jmpax2": PARK, "park": PARK}),

    # ---- phase 2: mid-stream reset (+RESETAT) and side-effecting RMW -------
    # All pre-reset program prefixes use only equal-length instructions so
    # the two cores are lockstep at the reset moment (pre-fetch streams
    # identical); post-reset re-execution is compared positionally by
    # semantic_compare.py --reset-at.
    dict(name="p3-reset-park", expect="pass",
         prog={**PROLOGUE, 0x0503: [0x4C, 0x08, 0x09]},   # JMP $0908
         irq_vec=None, nmi_vec=None, pulses=[],
         anchors={"reset": 0x0908}, reset_offset=1,       # mid self-JMP operand phase
         converge_at=0x0908,                              # first park fetch (state converged after LDX/TXS)
         gates={"prologue": "0500", "park": PARK}),

    dict(name="p3-reset-midinsn", expect="pass",
         prog={**PROLOGUE,
              0x0503: [0xEA, 0xEA],          # NOP sled
              0x0505: [0x20, 0x08, 0x09]},   # JSR $0908 (push not landed yet)
         irq_vec=None, nmi_vec=None, pulses=[],
         anchors={"reset": 0x0505}, reset_offset=1,       # mid JSR operand phase
         converge_at=0x0505,                              # JSR fetch (state converged after LDX/TXS)
         gates={"prologue": "0500", "jsr": "0505", "park": PARK}),

    dict(name="p3-reset-midpush", expect="pass", wr_toggle=1,
         prog={**PROLOGUE,
              0x0503: [0xA9, 0x7E],          # LDA #$7E (visible push data)
              0x0505: [0x48],                # PHA -> [FD]=7E SP=FC
              0x0506: [0x08],                # PHP -> [FC]=30 SP=FB
              0x0507: [0x48],                # PHA <- interrupted before its write
              0x0508: [0x48],                # PHA
              0x0509: HANDLER_PARK},         # park
         irq_vec=None, nmi_vec=None, pulses=[],
         anchors={"reset": 0x0507}, reset_offset=1,
         converge_at=0x0506,                              # PHP fetch (state converged after LDX/TXS/LDA)
         gates={"prologue": "0500", "pha3": "0507", "park": PARK}),

    dict(name="p3-rmw-toggle", expect="rmw-toggle", wr_toggle=1,
         prog={**PROLOGUE,
              0x0503: [0xA9, 0x5A],          # LDA #$5A (operand for EOR/TSB)
              0x0505: [0x18],                # CLC (known carry into ROL)
              0x0506: [0x0E, 0x00, 0x02],    # ASL $0200
              0x0509: [0x4E, 0x01, 0x02],    # EOR $0201
              0x050C: [0xEE, 0x02, 0x02],    # INC $0202
              0x050F: [0x0C, 0x03, 0x02],    # TSB $0203
              0x0512: [0x2E, 0x04, 0x02],    # ROL $0204
              0x0515: [0xCE, 0x05, 0x02],    # DEC $0205
              0x0518: HANDLER_PARK},         # park
         irq_vec=None, nmi_vec=None, pulses=[],
         extra={0x0200: [0x11, 0x6C, 0x23, 0x04, 0x35, 0x88]},
         rmw_init={0x0200: 0x11, 0x0201: 0x6C, 0x0202: 0x23,
                   0x0203: 0x04, 0x0204: 0x35, 0x0205: 0x88},
         # Expected REAL final memory under WRTOGGLE (each stroke flips bit 0
         # of the CURRENT byte; dout is discarded): golden = initial (two
         # strokes cancel), new = initial^1 (one stroke). The computed
         # f(initial) still lands on DO and is covered by the checker's
         # final write-map equality (last-write-wins per address).
         rmw_expect={0x0200: (0x11, 0x10),   # ASL: one stroke -> 11^1
                     0x0201: (0x6C, 0x6D),   # EOR: one stroke -> 6C^1
                     0x0202: (0x23, 0x22),   # INC: one stroke -> 23^1
                     0x0203: (0x04, 0x05),   # TSB: one stroke -> 04^1
                     0x0204: (0x35, 0x34),   # ROL: one stroke -> 35^1
                     0x0205: (0x88, 0x89)},  # DEC: one stroke -> 88^1
         gates={"asl": "0506", "eor": "0509", "inc": "050C",
                "tsb": "050F", "rol": "0512", "dec": "0515", "park": PARK}),
]

# ---------------------------------------------------------------------------


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def load_rows(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    return rows[0], rows[1:]


def fetch_cycle(header, rows, addr):
    """Cycle of the first SYNC=1 row at addr (None if absent)."""
    i = {c: k for k, c in enumerate(header)}
    a = addr.lower()
    for r in rows:
        if r[i["SYNC"]] == "1" and r[i["ADDR"]].lower() == a:
            return int(r[i["CYCLE"]])
    return None


def sync_addrs(header, rows):
    i = {c: k for k, c in enumerate(header)}
    return [r[i["ADDR"]].lower() for r in rows if r[i["SYNC"]] == "1"]


def build_image(case, out_hex):
    """Patch the base image; write 4096 rows x 16 bytes."""
    with open(HEX) as f:
        base = [line.split() for line in f if line.strip()]
    assert len(base) == 4096 and all(len(r) == 16 for r in base), "unexpected hex shape"
    img = [row[:] for row in base]

    def put(addr, data):
        for j, b in enumerate(data):
            off = (addr + j) & 0xFFFF
            img[off >> 4][(off >> 0) & 0xF] = "%02x" % b

    for addr, data in case["prog"].items():
        put(addr, data)
    extra = case.get("extra") or {}
    for addr, data in extra.items():
        put(addr, data)
    if case.get("prog_stage2"):
        for addr, data in case["prog_stage2"].items():
            put(addr, data)
    if case.get("irq_vec"):
        put(0xFFFE, [case["irq_vec"] & 0xFF, case["irq_vec"] >> 8])
    if case.get("nmi_vec"):
        put(0xFFFA, [case["nmi_vec"] & 0xFF, case["nmi_vec"] >> 8])

    with open(out_hex, "w") as f:
        for row in img:
            f.write(" ".join(row) + "\n")


def run_pair(case_dir, irq_pulse, nmi_pulse, reset_at=0, wr_toggle=0):
    """Run both exes (CWD = repo root); copy traces into case dir."""
    args_g = [G_EXE, "+TOTAL=%d" % TOTAL]
    args_n = [N_EXE, "+TOTAL=%d" % TOTAL]
    if irq_pulse:
        args_g.append("+IRQPULSE=%d" % irq_pulse)
        args_n.append("+IRQPULSE=%d" % irq_pulse)
    if nmi_pulse:
        args_g.append("+NMIPULSE=%d" % nmi_pulse)
        args_n.append("+NMIPULSE=%d" % nmi_pulse)
    if reset_at:
        args_g.append("+RESETAT=%d" % reset_at)
        args_n.append("+RESETAT=%d" % reset_at)
    if wr_toggle:
        args_g.append("+WRTOGGLE=1")
        args_n.append("+WRTOGGLE=1")
    env = dict(os.environ, PATH=r"C:\msys64\ucrt64\bin;" + os.environ.get("PATH", ""))
    for exe, args in ((G_EXE, args_g), (N_EXE, args_n)):
        r = subprocess.run(args, cwd=REPO, env=env, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError("%s failed rc=%d\n%s\n%s" % (exe, r.returncode, r.stdout, r.stderr))
    shutil.copy(G_CSV, os.path.join(case_dir, "golden.csv"))
    shutil.copy(N_CSV, os.path.join(case_dir, "new.csv"))


def check_entry_latency(case, cdir):
    """Resync comparison for the documented one-instruction entry-latency
    delta (golden dummy entry fetch vs new-core early push). Returns
    (verdict, problems, notes)."""
    problems, notes = [], []
    gh, dg = load_rows(os.path.join(cdir, "golden.csv"))
    nh, dn = load_rows(os.path.join(cdir, "new.csv"))
    ig = {c: k for k, c in enumerate(gh)}
    inw = {c: k for k, c in enumerate(nh)}

    def fetches(i, d):
        return [(int(r[i["CYCLE"]]), r[i["ADDR"]].lower(), r[i["DI"]].lower())
                for r in d if r[i["SYNC"]] == "1"]

    G = fetches(ig, dg)
    N = fetches(inw, dn)

    # Gates: every required address must be fetched by both cores.
    gset = {a for _, a, _ in G}
    nset = {a for _, a, _ in N}
    for name, addr in sorted(case["gates"].items()):
        a = addr.lower()
        if a not in gset:
            problems.append("gate %s=%s not fetched by golden" % (name, a))
        if a not in nset:
            problems.append("gate %s=%s not fetched by new core" % (name, a))
    no_at = (case.get("no_entry_at") or "").lower()
    if no_at:
        for tag, s in (("golden", gset), ("new", nset)):
            if no_at in s:
                problems.append("handler %s fetched in %s (entry occurred)" % (no_at, tag))

    # Two-pointer resync on (addr, op): identical prefix, at most one extra
    # golden row per mismatch (the dummy entry fetch), identical suffix.
    gi = ni = 0
    extras = []
    while gi < len(G) and ni < len(N):
        if G[gi][1:] == N[ni][1:]:
            gi += 1
            ni += 1
        else:
            extras.append((gi, G[gi]))
            gi += 1
            if gi >= len(G) or G[gi][1:] != N[ni][1:]:
                problems.append("resync failed at golden[%d]=%s:%s vs new[%d]=%s:%s"
                                % (gi - 1, G[gi - 1][1], G[gi - 1][2],
                                   ni, N[ni][1], N[ni][2]))
                break
            gi += 1
            ni += 1
    # When one stream is exhausted first, the other's remainder is park-loop
    # tail (the new core parks earlier in the fixed window and therefore has
    # a few more park fetches); only golden rows the new core never fetched
    # are a real mismatch.
    if gi < len(G) and ni >= len(N):
        problems.append("golden has %d fetches the new core never made: %s"
                        % (len(G) - gi, G[gi:gi + 3]))

    # Tail: both sides must be the park self-JMP loop, length delta <= 2.
    grem, nrem = G[gi:], N[ni:]
    for tag, rem in (("golden", grem), ("new", nrem)):
        bad = [r for r in rem if r[1] != PARK.lower()]
        if bad:
            problems.append("%s tail has non-park fetches: %s" % (tag, bad[:3]))
    if abs(len(grem) - len(nrem)) > 2:
        problems.append("tail length delta %d exceeds 2" % abs(len(grem) - len(nrem)))

    # Stack push triples: three consecutive 01xx writes (hi, lo, status).
    def triples(i, d):
        w = [(int(r[i["CYCLE"]]), r[i["ADDR"]].lower(), r[i["DO"]].lower())
             for r in d if r[i["RW"]] == "0" and r[i["ADDR"]].lower().startswith("01")]
        out, cur = [], []
        for c, a, v in w:
            if cur and c != int(cur[-1][0]) + 1:
                out.append(cur)
                cur = []
            cur.append((c, a, v))
        if cur:
            out.append(cur)
        return [t for t in out if len(t) == 3]

    gt = triples(ig, dg)
    nt = triples(inw, dn)
    if len(gt) != len(nt):
        problems.append("stack push-triple count differs golden=%d new=%d"
                        % (len(gt), len(nt)))
    for k in range(min(len(gt), len(nt))):
        gpc = int(gt[k][0][2] + gt[k][1][2], 16)
        gst = gt[k][2][2]
        npc = int(nt[k][0][2] + nt[k][1][2], 16)
        nst = nt[k][2][2]
        delta = (gpc - npc) & 0xFFFF
        matched = [e for e in extras if e[1][1] == "%04x" % gpc]
        if matched:
            if delta not in (0, 1, 2):
                problems.append("entry %d return-PC delta golden-new=%d outside {0,1,2} (golden=%04x new=%04x)"
                                % (k, delta, gpc, npc))
            elif delta == 0 and gst != nst:
                problems.append("entry %d same-boundary status differs golden=%s new=%s" % (k, gst, nst))
            else:
                notes.append("entry %d: golden interrupted @%04x (status %s), new @%04x (status %s)"
                             % (k, gpc, gst, npc, nst))
        else:
            if delta != 0 or gst != nst:
                problems.append("entry %d boundary mismatch: golden PC=%04x status=%s, new PC=%04x status=%s"
                                % (k, gpc, gst, npc, nst))
            else:
                notes.append("entry %d: same boundary @%04x, status %s" % (k, gpc, gst))
    for _, (cyc, addr, op) in extras:
        if not any(int(t[0][2] + t[1][2], 16) == int(addr, 16) for t in gt):
            problems.append("extra golden fetch %s has no matching push triple" % addr)

    # Final state: everything equal except PC; PC within the park window.
    def last_state(i, d):
        r = d[-1]
        return {c: r[i[c]] for c in ("SP", "P_N", "P_V", "P_D", "P_I", "P_Z",
                                     "P_C", "Y", "X", "A", "PC")}

    gs, ns = last_state(ig, dg), last_state(inw, dn)
    for c in sorted(gs):
        if c != "PC" and gs[c] != ns[c]:
            problems.append("final %s differs golden=%s new=%s" % (c, gs[c], ns[c]))
    park = int(PARK, 16)
    for tag, p in (("golden", int(gs["PC"], 16)), ("new", int(ns["PC"], 16))):
        if not (park <= p <= park + 3):
            problems.append("final PC %s=%04x outside park window" % (tag, p))

    return ("expected" if not problems else "fail"), problems, notes


def run_checker(case_dir, case, reset_at=0):
    args = [PY, CHECKER,
            os.path.join(case_dir, "golden.csv"), os.path.join(case_dir, "new.csv")]
    for name, addr in sorted(case["gates"].items()):
        args += ["--gate", "%s=%s" % (name, addr)]
    if reset_at:
        args += ["--reset-at", str(reset_at)]
    cf = case.get("converge_at")
    if cf is not None:
        args += ["--compare-from", "%04x" % cf]
    jout = os.path.join(case_dir, "semantic_summary.json")
    args += ["--json-out", jout]
    r = subprocess.run(args, cwd=REPO, capture_output=True, text=True)
    summary = json.load(open(jout)) if os.path.exists(jout) else {}
    return r.returncode, summary


def check_rmw_toggle(case):
    """Phase 2 side-effecting-RMW check (both TBs ran with +WRTOGGLE=1).

    The TB write commit is a stateful toggle (mem[addr] ^= 1 per stroke), so
    real final memory = initial ^ parity(write strokes) per address, NOT the
    last written DO. Golden RMW = two strokes (pre-write + final -> initial
    byte restored); new core = one stroke (f(initial)^1). Any stray commit
    (e.g. an ungated stale strobe) flips parity and is caught here.
    Returns (problems, notes)."""
    problems, notes = [], []
    exp = case["rmw_expect"]
    inits = case["rmw_init"]
    finals = {}
    for tag in ("golden", "new"):
        h, rows = load_rows(os.path.join(P3DIR, case["name"], tag + ".csv"))
        i = {c: k for k, c in enumerate(h)}
        counts = {}
        for r in rows:
            if r[i["RW"]] == "0":
                a = int(r[i["ADDR"]], 16)
                counts[a] = counts.get(a, 0) + 1
        f = {a: init ^ (1 if counts.get(a, 0) & 1 else 0)
             for a, init in inits.items()}
        finals[tag] = (counts, f)
        want = {a: (v[0] if tag == "golden" else v[1]) for a, v in exp.items()}
        for a in sorted(exp):
            if f[a] != want[a]:
                problems.append("%s final %04x=%02x (strokes=%d) expected %02x"
                                % (tag, a, f[a], counts.get(a, 0), want[a]))
        notes.append("%s strokes: %s" % (
            tag, {a: c for a, c in sorted(counts.items())}))
    gc, nc = finals["golden"][0], finals["new"][0]
    # Stroke-count sanity: golden 2 per RMW addr (pre-write + final), new 1.
    for a in sorted(exp):
        if gc.get(a, 0) != 2:
            problems.append("golden stroke count at %04x = %d (expected 2)"
                            % (a, gc.get(a, 0)))
        if nc.get(a, 0) != 1:
            problems.append("new stroke count at %04x = %d (expected 1)"
                            % (a, nc.get(a, 0)))
    # Any other written address must have equal stroke parity across cores.
    for a in sorted(set(gc) | set(nc)):
        if a in exp:
            continue
        if (gc.get(a, 0) & 1) != (nc.get(a, 0) & 1):
            problems.append("write parity differs at %04x (golden=%d new=%d strokes)"
                            % (a, gc.get(a, 0), nc.get(a, 0)))
    return problems, notes


def evaluate(case, rc, summary):
    """Return (verdict, notes). verdict in pass|expected|fail."""
    problems = summary.get("problems", [])
    if case["expect"] == "rmw-toggle":
        p2, extra = check_rmw_toggle(case)
        if rc != 0:
            return "fail", (summary.get("problems", []) + p2, extra)
        if p2:
            return "fail", (p2, extra)
        return "pass", ([], extra)
    if case["expect"] == "pass":
        if rc == 0:
            extra = []
            no_at = (case.get("no_entry_at") or "").lower()
            if no_at:
                for tag, path in (("golden", "golden.csv"), ("new", "new.csv")):
                    h, rows = load_rows(os.path.join(P3DIR, case["name"], path))
                    if no_at in sync_addrs(h, rows):
                        extra.append("handler %s fetched in %s (entry occurred)" % (no_at, tag))
            return ("pass" if not extra else "fail"), (summary.get("problems", []), extra)
        return "fail", (summary.get("problems", []), [])
    return "fail", (problems, ["unknown expect=%r" % case["expect"]])


def main():
    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]

    os.makedirs(P3DIR, exist_ok=True)
    # Back up the shared image AND both canonical r65-pair traces: the TBs
    # write to fixed paths, so every case run overwrites them.
    backups = []
    for p in (HEX, G_CSV, N_CSV):
        b = p + ".p3bak"
        shutil.copy(p, b)
        backups.append((b, p))
    results = []
    try:
        for case in CASES:
            if only and case["name"] != only:
                continue
            name = case["name"]
            cdir = os.path.join(P3DIR, name)
            os.makedirs(cdir, exist_ok=True)
            print("=== %s ===" % name)

            # Stage 1 image + plain probe (no pulses) to locate anchors.
            build_image(case, HEX)
            run_pair(cdir, 0, 0)
            shutil.move(os.path.join(cdir, "new.csv"), os.path.join(cdir, "probe_new.csv"))
            shutil.move(os.path.join(cdir, "golden.csv"), os.path.join(cdir, "probe_golden.csv"))
            ph, prows = load_rows(os.path.join(cdir, "probe_new.csv"))

            irq_pulse = nmi_pulse = 0
            for kind in case.get("pulses", []):
                anchor = (case.get("anchors") or {}).get(kind)
                if anchor is None:
                    continue
                cyc = fetch_cycle(ph, prows, "%04x" % anchor)
                if cyc is None:
                    raise RuntimeError("%s: anchor %04x not fetched in probe" % (name, anchor))
                start = max(5, cyc - PULSE_LEN // 2)
                if kind == "irq":
                    irq_pulse = start
                else:
                    nmi_pulse = start

            # Stage 2 (p3-nmi-during-irq): place the NMI pulse inside the
            # IRQ handler, which only exists once the IRQ pulse is applied.
            if case.get("two_stage"):
                build_image(case, HEX)  # now includes prog_stage2
                run_pair(cdir, irq_pulse, 0)
                h2, rows2 = load_rows(os.path.join(cdir, "new.csv"))
                entry = fetch_cycle(h2, rows2, "%04x" % case["irq_vec"])
                if entry is None:
                    raise RuntimeError("%s: IRQ handler not reached in stage 2" % name)
                nmi_pulse = entry + 2
                shutil.move(os.path.join(cdir, "new.csv"), os.path.join(cdir, "stage2_new.csv"))
                shutil.move(os.path.join(cdir, "golden.csv"), os.path.join(cdir, "stage2_golden.csv"))

            # Mid-stream reset anchor (phase 2): probe fetch cycle + offset.
            # The probe itself runs without RESETAT so anchor search stays
            # deterministic; the final run applies it to both cores.
            reset_at = 0
            ra = (case.get("anchors") or {}).get("reset")
            if ra is not None:
                cyc = fetch_cycle(ph, prows, "%04x" % ra)
                if cyc is None:
                    raise RuntimeError("%s: reset anchor %04x not fetched in probe"
                                       % (name, ra))
                reset_at = cyc + case.get("reset_offset", 0)

            # Final run with the full pulse set (+RESETAT/+WRTOGGLE).
            run_pair(cdir, irq_pulse, nmi_pulse,
                     reset_at=reset_at, wr_toggle=case.get("wr_toggle", 0))

            if case["expect"] == "entry-latency":
                verdict, problems, extra = check_entry_latency(case, cdir)
            else:
                rc, summary = run_checker(cdir, case, reset_at=reset_at)
                verdict, (problems, extra) = evaluate(case, rc, summary)
            gates_hit = {g: a for g, a in sorted(case["gates"].items())}
            rec = dict(name=name, expect=case["expect"], verdict=verdict,
                       irq_pulse=irq_pulse, nmi_pulse=nmi_pulse,
                       reset_at=reset_at, wr_toggle=case.get("wr_toggle", 0),
                       gates=gates_hit, problems=problems[:10], extra=extra)
            results.append(rec)
            print("  pulses: irq=%d nmi=%d" % (irq_pulse, nmi_pulse))
            print("  verdict: %s" % verdict.upper())
            for p in problems[:5]:
                print("   problem: %s" % p)
            for e in extra[:5]:
                print("   extra:   %s" % e)
    finally:
        for b, p in backups:
            if os.path.exists(b):
                shutil.move(b, p)

    summary = dict(total=TOTAL, pulse_len=PULSE_LEN,
                   golden_exe_sha256=sha256(G_EXE), new_exe_sha256=sha256(N_EXE),
                   cases=results)
    with open(os.path.join(P3DIR, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)

    print("\n%-22s %-8s %s" % ("case", "expect", "verdict"))
    for r in results:
        print("%-22s %-8s %s" % (r["name"], r["expect"], r["verdict"].upper()))
    bad = [r for r in results if r["verdict"] == "fail"]
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
