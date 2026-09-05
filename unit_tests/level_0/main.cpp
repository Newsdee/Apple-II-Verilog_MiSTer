// ============================================================================
// unit_tests/level_0/main.cpp
//
// Minimal --timing main for the level_0 harness (CPU + real ROM + machine
// decode).  Mirrors level_neg1/main.cpp; runs the Verilator event loop
// until the testbench calls $finish, then returns non-zero if the TB's
// module-scope `errors` counter is non-zero (0 = pass).
//
// Options (command line):
//   --trace     write a VCD waveform to tb_l0.vcd (CWD).  Requires the
//               binary to be built with `--trace` in the Makefile V_OPT
//               (signal hookup code is generated at compile time; at
//               runtime it is a no-op unless --trace is given).
//
// Prints a speed line at the end: simulated time vs wall time (Verilator
// throughput in simulated MHz — NOT a CPU speed).
#include "Vtb_l0.h"
#include "Vtb_l0___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <chrono>
#include <cstdio>
#include <cstring>

// Verilator (non-SystemC build, -DVM_SC=0) declares sc_time_stamp() as weak
// (verilated_funcs.h: `extern double sc_time_stamp() VL_ATTR_WEAK;`). The user
// program must provide it; the harness drives its own clock and exits via
// $finish. Signature must be `double sc_time_stamp()` to match the weak
// declaration.
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
	Vtb_l0* top = new Vtb_l0(&context);

	VerilatedVcdC vcd;
	if (tracing) {
		// Wire this thread's models (built with --trace) into the tracer,
		// then open the file.  No per-cycle cost unless the file is open.
		context.trace(&vcd, 0);
		vcd.open("tb_l0.vcd");
		if (!vcd.isOpen()) {
			printf("ERROR: could not open tb_l0.vcd for --trace\n");
			delete top;
			return 2;
		}
	}

	// Verilator 5 --timing main loop (see level_neg1/main.cpp for the
	// build-specific protocol notes: eval_step/nextTimeSlot ordering,
	// eventsPending semantics, $finish handling).
	const auto wall0 = std::chrono::steady_clock::now();
	top->eval_step();  // prime: run initial blocks at t=0
	while (!context.gotFinish()) {
		if (!top->eventsPending()) break;  // nothing scheduled; rely on $finish/errors
		const uint64_t next = top->nextTimeSlot();  // read-only in this build!
		if (next > context.time()) {
			context.time(next);  // advance to the next scheduled event
		}
		top->eval_step();
		if (tracing) vcd.dump(context.time());
	}
	if (tracing) {
		vcd.close();
	}
	const auto wall1 = std::chrono::steady_clock::now();
	const double wall_ms =
	    std::chrono::duration<double, std::milli>(wall1 - wall0).count();
	// Timescale is 1ps/1ps (Makefile --timescale-override), so time() is ps.
	const uint64_t sim_ps = context.time();
	const double mhz = (sim_ps / 1e12) / (wall_ms / 1e3) * 1e6;
	printf("L0 SPEED  sim=%0.3f ms  wall=%0.1f ms  ~%.2f MHz "
	       "(Verilator throughput)\n",
	       sim_ps / 1e6, wall_ms, mhz);
	top->final();

	// Module-scope `reg [15:0] errors` (naming: <module>__DOT__<signal>).
	const int status = (top->rootp->tb_l0__DOT__errors != 0) ? 1 : 0;
	delete top;
	return status;
}
