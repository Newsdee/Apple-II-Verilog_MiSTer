/*
 * p6502_oracle.c (v5.1) — run cpu_6502 suite test cases on the perfect6502
 * transistor-level NMOS 6502 netlist and emit raw result lines in the
 * exact format of the Verilator sweeps (sst_driver.parse_results()).
 *
 * State injection (all silicon-faithful — the chip runs its own
 * instructions to reach the test boundary; NO node patching. v5.1 change:
 * v5 still patched A/X/Y/SP storage nodes at the boundary; writeNodes()
 * sets STATIC pullup/pulldown topology (netlist_sim.c: set_nodes_pullup /
 * set_nodes_pulldown bits persist across every later recalc), so the
 * patched bits stay forced across all future cycles and defeat real
 * commits (observed: patched A=00 stuck after LDA #$7F). The prelude
 * below now sets every register it can set with real instructions.)
 *
 *   Memory: 0xEE fill (the Verilator TB sentinel) + the test's initial
 *   ram + a fixed 12-byte prelude at a free base (prebase):
 *       prebase+0:  A2 sp0    LDX #sp0      (2 cyc)
 *       prebase+1:  sp0
 *       prebase+2:  9A        TXS  SP:=X    (2 cyc)
 *       prebase+3:  A2 x      LDX #x        (2 cyc)
 *       prebase+4:  x
 *       prebase+5:  A0 y      LDY #y        (2 cyc)
 *       prebase+6:  y
 *       prebase+7:  A9 a      LDA #a        (2 cyc)
 *       prebase+8:  a
 *       prebase+9:  4C lo hi  JMP startpc   (3 cyc)
 *       prebase+10: startpc & 0xFF
 *       prebase+11: startpc >> 8
 *   Net register state at the boundary: A=a X=x Y=y SP=sp0 (= spec sp,
 *   chosen by the Python runner) PC=startpc. The prelude touches no
 *   memory other than the prebase area, so there are no stack-byte
 *   collision constraints.
 *
 *   P REGISTER — NETLIST LIMITATION (proven by the t_p_* diagnostics):
 *   in this netlist build the p0..p7 nodes are NOT the P storage. They
 *   read as a function of A only (P(a=00)=10, P(a=55)=55, P(a=80)=90,
 *   P(a=ff)=df — independent of any loaded byte, stable on both clock
 *   phases). PLP/PHP do not load P (internal or node); PHA pushes A
 *   (not P) to the stack. The branch logic (JEQ/JNE) DOES work on the
 *   instruction-updated flags. Consequences:
 *     - the initial P is not settable: it is whatever the netlist
 *       produces after reset (observed 0x16 = B|D|I) plus the prelude's
 *       flag updates (final Z/N from a);
 *     - readP() is an A alias: the p= field of R lines is emitted for
 *       completeness but must NOT be compared against the suite's
 *       expected P (the report generator treats netlist P as advisory);
 *     - tests whose expected behavior depends on initial P bits (Jcc on
 *       initial flags, PHA/PHP, final-P-only diffs) are netlist-out-of-
 *       scope; the report classifies them p-limited instead of failing
 *       them.
 *
 *   Reset vector (FFFC/FFFD) points at prebase. (For the few tests
 *   whose initial ram pins FFFC/FFFD to other values and whose cycles
 *   never touch the vector, the runner overwrites the vector with the
 *   prebase target — the vector bytes are only read at boot, before
 *   the test window, so the final-RAM check cannot see them.)
 *
 *   Alignment: step half-cycles until the prelude's JMP high-byte
 *   fetch (the read at prebase+6, a rising/access half-cycle) has
 *   completed, then take the following falling half-cycle. That is a
 *   clean instruction boundary: the next rising half-cycle fetches
 *   the test opcode at startpc. Timing contract (verified against
 *   the golden suite traces and the netlist itself): one suite/golden
 *   cycle == one full chip cycle == one rising (memory-access)
 *   half-cycle + one falling (commit) half-cycle. The netlist, like
 *   the real NMOS 6502 and the golden model, performs a memory read
 *   every cycle (e.g. NOP = R pc then R pc+1; PLA = R op, R next,
 *   R [oldSP], R [newSP]).
 *
 *   At the boundary, while the clock is low, patch the A, X, Y and SP
 *   register storage nodes bit by bit with writeNodes(). PC comes from
 *   the JMP target and P was set by PLP, so neither is patched.
 *   (Patching the P nodes directly is impossible: only the B and I
 *   nodes hold a forced value; C/V/D/N/Z are re-driven by the
 *   netlist. p6502_probe.c / p6502_flagprobe2.c document this.)
 *
 *   Sanity: read PC (== startpc), A, X, Y, SP (exact) and P bits
 *   V/B/D/I/C (mask 0x59; N and Z were chosen from A in the pushed
 *   byte and are masked out by the checker anyway). Emit a U line if
 *   any of these fail.
 *
 *   Output: one line per test:
 *     R %08d <bus0> <r0><b1> <r1><b2> ... <r14><b15> <r15>  (raw line)
 *     U %08d <reason>   (unrepresentable state)
 *     F %08d <reason>   (alignment/setup failure)
 *
 *   Raw line semantics (identical to the Verilator TB):
 *     token 0 = the phantom pre-fetch sample the TB takes while
 *       stalled: bus0 = R startpc mem[startpc], regs0 = the injected
 *       initial register state (the suite values, P with bits 5:4
 *       forced to 1 — the TB emits {n,v,2'b11,d,i,z,c}, which the
 *       retained sweeps confirm: every one of the 409600 P bytes in
 *       the golden/new6502 raw files has bits 5:4 set).
 *     tokens 1..15 = the 15 real cycles after the boundary. For each,
 *       the rising half-cycle is the memory access (bus token = ab,
 *       R/W, db at the access moment, sampled before any db forcing)
 *       and the falling half-cycle is the commit; the register
 *       snapshot is taken after the falling step (end of cycle).
 *       P is emitted as readP | 0x30 (force U and B to 1, as the TB
 *       does).
 *
 *   hstep() replicates step() exactly — setNode(clk0, !old) [which
 *   internally recalcs] + recalcNodeList + memory handling on the
 *   rising edge (the access half-cycle, per step()'s `if (!clk)
 *   handleMemory`) + cycle++ — samples AB/RW/DB at the access moment,
 *   then performs the memory handling itself with handleMemory's
 *   semantics (read: writeDataBus(memory[ab]); write:
 *   memory[ab] = readDataBus()).
 *
 * Spec file: one line per test
 *   <idx> <sp> <a> <x> <y> <p> <startpc> <prebase> <sp0> <addr=byte>...
 * (hex fields; idx is the 10-decimal batch index of the raw files)
 *
 * perfect6502 upstream: github.com/mist64/perfect6502 (MIT).
 * Local patch: netlist_sim.c groupcount init (upstream issue #17).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "types.h"
#include "netlist_6502_enum.h"   /* node-name enum only (no netlist data) */
#include "netlist_sim.h"
#include "perfect6502.h"

#define WCYC 16

/* One half-cycle, replicating step() exactly (see file header).
 * On the rising (access) half-cycle the bus is reported *before* the
 * db forcing; the memory handling is then performed by hand with the
 * same semantics as handleMemory(). */
static void
hstep(void *state, uint16_t *ab, char *rwc, uint8_t *db)
{
	BOOL old = isNodeHigh(state, clk0);
	setNode(state, clk0, !old);
	recalcNodeList(state);
	if (!old) {   /* rising edge: the memory-access half-cycle */
		uint16_t a = readAddressBus(state);
		if (isNodeHigh(state, rw)) {
			uint8_t d = memory[a];
			writeDataBus(state, d);
			if (ab)
				*ab = a;
			if (rwc)
				*rwc = 'R';
			if (db)
				*db = d;
		} else {
			uint8_t d = readDataBus(state);
			memory[a] = d;
			if (ab)
				*ab = a;
			if (rwc)
				*rwc = 'W';
			if (db)
				*db = d;
		}
	}
	cycle++;
}

/* One full cycle: the rising step is the memory access (bus token);
 * the falling step is the commit. The register snapshot is taken after
 * the falling step (end of the cycle) = the state BEFORE the next cycle,
 * matching the TB convention (row c's regs = state before cycle c; row
 * ncyc's regs = state after the last expected cycle). P is emitted with
 * bits 5:4 (U:B) forced to 1, exactly as the Verilator TB does. */
static void
full_cycle(void *state, char *bus, char *regs)
{
	uint16_t ab;
	char rwc;
	uint8_t db;

	hstep(state, &ab, &rwc, &db);
	snprintf(bus, 8, "%04x%c%02x", ab, rwc, db);
	hstep(state, NULL, NULL, NULL);

	uint16_t pc = readPC(state);
	uint8_t sp = readSP(state), a = readA(state), x = readX(state);
	uint8_t y = readY(state), p = readP(state) | 0x30;
	snprintf(regs, 15, "%04x%02x%02x%02x%02x%02x", pc, sp, a, x, y, p);
}

int
main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s <specfile>\n", argv[0]);
		return 2;
	}
	FILE *spec = fopen(argv[1], "rb");
	if (!spec) {
		fprintf(stderr, "cannot open %s\n", argv[0]);
		return 2;
	}

	char line[8192];
	while (fgets(line, sizeof line, spec)) {
		if (line[0] == '#' || line[0] == '\n')
			continue;

		int idx, sp, a, x, y, p, startpc, prebase, sp0;
		if (sscanf(line, "%d %x %x %x %x %x %x %x %x",
				   &idx, &sp, &a, &x, &y, &p, &startpc,
				   &prebase, &sp0) != 9) {
			fprintf(stderr, "bad spec header: %s", line);
			return 1;
		}

		/* apply memory image (sentinel 0xEE, as the TB uses) */
		memset(memory, 0xEE, sizeof memory);
		/* skip the 9 header fields, then apply addr=byte pairs */
		char *q = line;
		for (int n = 0; n < 9; n++) {
			q = strchr(q, ' ');
			if (!q) {
				fprintf(stderr, "short spec line: %s", line);
				return 1;
			}
			q++;
		}
		while (*q) {
			char *end;
			long a1 = strtol(q, &end, 16);
			if (end && *end == '=') {
				long b1 = strtol(end + 1, &end, 16);
				if (a1 >= 0 && a1 <= 0xFFFF)
					memory[a1] = (uint8_t)b1;
				q = end;
			} else if (*q) {
				q++;
			}
		}

		/* the prelude (over anything the spec put there — the
		 * prebase area is chosen by the runner to be free of all
		 * test-touched addresses; 12 fixed bytes, see file header) */
		memory[prebase + 0] = 0xA2;          /* LDX #sp0 */
		memory[prebase + 1] = (uint8_t)sp0;
		memory[prebase + 2] = 0x9A;          /* TXS  SP := X */
		memory[prebase + 3] = 0xA2;          /* LDX #x */
		memory[prebase + 4] = (uint8_t)x;
		memory[prebase + 5] = 0xA0;          /* LDY #y */
		memory[prebase + 6] = (uint8_t)y;
		memory[prebase + 7] = 0xA9;          /* LDA #a */
		memory[prebase + 8] = (uint8_t)a;
		memory[prebase + 9] = 0x4C;          /* JMP abs startpc */
		memory[prebase + 10] = (uint8_t)(startpc & 0xFF);
		memory[prebase + 11] = (uint8_t)(startpc >> 8);

		void *state = initAndResetChip();

		/* --- alignment: wait for the prelude JMP's high-byte fetch --- */
		int aligned = 0;
		for (int h = 0; h < 96 && !aligned; h++) {
			BOOL clk_before = isNodeHigh(state, clk0);
			hstep(state, NULL, NULL, NULL);
			if (!clk_before) {   /* that step was the access half-cycle */
				uint16_t ab = readAddressBus(state);
				if (ab == (uint16_t)(prebase + 11))
					aligned = 1;
			}
		}
		if (!aligned) {
			printf("F %08d align-fail\n", idx);
			destroyChip(state);
			continue;
		}
		/* that step was the rising/access step; the next step is the
		 * falling half-cycle. Take it -> clean boundary: the next
		 * access (rising) step is the test opcode fetch. */
		hstep(state, NULL, NULL, NULL);

		/* --- sanity / representability (no patching; the prelude
		 * already landed A/X/Y/SP/PC). P is NOT verified here: in
		 * this netlist build P is neither settable nor observable
		 * (see the P REGISTER section of the file header). --- */
		uint16_t pc = readPC(state);
		uint8_t ra = readA(state), rx = readX(state), ry = readY(state);
		uint8_t rs = readSP(state);
		if (pc != (uint16_t)startpc || ra != (uint8_t)a ||
		    rx != (uint8_t)x || ry != (uint8_t)y ||
		    rs != (uint8_t)sp) {
			printf("F %08d patch pc=%04x a=%02x x=%02x y=%02x sp=%02x (want pc=%04x a=%02x x=%02x y=%02x sp=%02x)\n",
			       idx, pc, ra, rx, ry, rs,
			       startpc, a, x, y, sp);
			destroyChip(state);
			continue;
		}

		/* --- emit the raw line ---
		 * Format (matches sst_driver.parse_results): parts[2] = bus0
		 * (cycle 0's fetch sample), parts[2+c] = regs_{c-1}+bus_c
		 * (c=1..15, 14+7 chars), parts[18] = regs_15. bus0 is the REAL
		 * first-fetch sample (v5.1 fix: the earlier handcrafted
		 * phantom c0 duplicated cycle 0 and shifted every later cycle
		 * by one — the apparent "opcode re-fetch at c1" in 600/600
		 * tests was this duplication, not netlist behaviour). */
		char bus[8], regs[15], regs_prev[15];
		char out[512];
		int pos;

		/* boundary register state = state before cycle 0 (regs_0) */
		snprintf(regs, 15, "%04x%02x%02x%02x%02x%02x", readPC(state),
			 readSP(state), readA(state), readX(state), readY(state),
			 (uint8_t)(readP(state) | 0x30));
		memcpy(regs_prev, regs, 15);

		/* cycle 0: the test opcode fetch */
		full_cycle(state, bus, regs);
		snprintf(out, sizeof out, "R %08d %s", idx, bus);
		pos = strlen(out);

		for (int t = 1; t < WCYC; t++) {
			full_cycle(state, bus, regs);
			pos += snprintf(out + pos, sizeof out - pos, " %s%s",
					regs_prev, bus);
			memcpy(regs_prev, regs, 15);
		}
		snprintf(out + pos, sizeof out - pos, " %s", regs_prev);
		printf("%s\n", out);
		destroyChip(state);
	}
	fclose(spec);
	return 0;
}