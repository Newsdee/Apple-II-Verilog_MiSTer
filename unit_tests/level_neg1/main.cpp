// unit_tests/level_neg1/main.cpp
//
// Minimal --timing main for the CPU harness.  Runs the Verilator event loop
// until the testbench calls $finish, then returns non-zero if the TB's
// module-scope `errors` counter is non-zero (0 = pass).
//
// Options (command line):
//   --trace     write a VCD waveform to tb_cpu.vcd (CWD).  Requires the
//               binary to be built with `--trace` in the Makefile V_OPT
//               (signal hookup code is generated at compile time; at
//               runtime it is a no-op unless --trace is given).
//
// Prints a speed line at the end: simulated time vs wall time (Verilator
// throughput in simulated MHz — NOT a CPU speed).
#include "Vtb_cpu.h"
#include "Vtb_cpu___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <chrono>
#include <cstdio>
#include <cstring>

// Verilator (non-SystemC build, -DVM_SC=0) declares sc_time_stamp() as weak
// (verilated_funcs.h: `extern double sc_time_stamp() VL_ATTR_WEAK;`). The user
// program must provide it; the harness drives its
// own clock and exits via $finish. Signature must be `double sc_time_stamp()`
// to match the weak declaration.
double sc_time_stamp()
{
	return 0.0;
}

int main(int argc, char** argv)
{
	// This custom main replaces Verilator's generated main, so the --trace
	// flag is parsed here (the library's commandArgs only stores argv for
	// $value$plusargs-style lookups).
	bool tracing = false;
	for (int i = 1; i < argc; i++)
		if (strcmp(argv[i], "--trace") == 0) tracing = true;

	VerilatedContext context;
	context.commandArgs(argc, argv);
	context.traceEverOn(true);  // must precede model construction
	Vtb_cpu* top = new Vtb_cpu(&context);

	VerilatedVcdC vcd;
	if (tracing) {
		// Wire this thread's models (built with --trace) into the tracer,
		// then open the file.  No per-cycle cost unless the file is open.
		context.trace(&vcd, 0);
		vcd.open("tb_cpu.vcd");
		if (!vcd.isOpen()) {
			printf("ERROR: could not open tb_cpu.vcd for --trace\n");
			delete top;
			return 2;
		}
	}

	// Verilator 5 --timing main loop.  eval() alone only re-evaluates the
	// current time slot and NEVER advances time, so a free-running clock
	// would spin the process at t=0 forever.  The correct pattern:
	//   - eval_step()      drains one pass of the current slot's events
	//   - eval_end_step()  settles the slot
	//   - nextTimeSlot()   advances time to the next scheduled event
	// Loop until the SV testbench calls $finish (context.gotFinish()).
	// Verilator 5 --timing protocol for THIS build (5.050 MSYS2, rev vUNKNOWN):
	//   - the FIRST eval_step() runs the design's initial blocks (they suspend
	//     on their first clock edge / delay); before that the delay queue is
	//     empty, so nextTimeSlot() would abort and eventsPending() is false.
	//   - eventsPending() here means "the delay queue has a FUTURE event"
	//     (!__VdlySched.empty() && !gotFinish), not "active-slot events pending",
	//     so it must gate the advance, not an inner drain loop (that would spin
	//     at t=0 forever).
	//   - nextTimeSlot() moves context time to the next scheduled event;
	//     eval_step() then resumes the due coroutines and evaluates triggers.
	//   - $finish sets gotFinish and empties the queue; never call
	//     nextTimeSlot() after it ("There is no next time slot scheduled").
	// Wall-clock the simulation so we can report Verilator throughput.
	const auto wall0 = std::chrono::steady_clock::now();
	top->eval_step();  // prime: run initial blocks at t=0
	while (!context.gotFinish()) {
		if (!top->eventsPending()) break;  // nothing scheduled; rely on $finish/errors
		const uint64_t next = top->nextTimeSlot();  // read-only in this build!
		if (next > context.time()) {
			context.time(next);  // advance to the next scheduled event
		}
		// eval_step() re-evaluates triggers; delayed coroutines resume only
		// once context time reaches their timestamp (awaitingCurrentTime).
		// If next == current time, this drains same-timestamp events.
		top->eval_step();
		if (tracing) vcd.dump(context.time());
	}
	// (The loop already dumped at the final time on the iteration where
	// $finish fired, so no extra dump is needed here — a second dump at the
	// same timestamp only produces a "previous dump" warning.)
	if (tracing) {
		vcd.close();
	}
	const auto wall1 = std::chrono::steady_clock::now();
	const double wall_ms =
	    std::chrono::duration<double, std::milli>(wall1 - wall0).count();
	// Timescale is 1ps/1ps (Makefile --timescale-override), so time() is ps.
	const uint64_t sim_ps = context.time();
	const double mhz = (sim_ps / 1e12) / (wall_ms / 1e3) * 1e6;
	printf("CPU_NEG1 SPEED  sim=%0.3f us  wall=%0.1f ms  ~%.2f MHz "
	       "(Verilator throughput)\n",
	       sim_ps / 1e3, wall_ms, mhz);
	top->final();

	// This Verilator 5.050 MSYS2 build silently ignores -public/-public-flat-rw
	// (no signal accessors are generated on the top class), but module-scope
	// signals are always public members of the generated root class, reachable
	// via the public rootp pointer.  tb_cpu__DOT__errors is the TB's module-
	// scope `reg [15:0] errors` (naming: <module>__DOT__<signal>).
	const int status = (top->rootp->tb_cpu__DOT__errors != 0) ? 1 : 0;
	delete top;
	return status;
}
