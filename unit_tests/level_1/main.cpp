// ============================================================================
// unit_tests/level_1/main.cpp
//
// Minimal --timing main for the level_1 harness (machine core + native
// video + real PS/2 keyboard).  Mirrors level_0/main.cpp; runs the
// Verilator event loop until the testbench calls $finish, then returns
// non-zero if the TB's module-scope `errors` counter is non-zero
// (0 = pass).
//
// Options (command line):
//   --trace       write a VCD waveform to tb_l1.vcd (CWD).  Requires the
//                 binary to be built with `--trace` in the Makefile V_OPT
//                 (signal hookup code is generated at compile time; at
//                 runtime it is a no-op unless a trace file is requested).
//   --vcd=FILE    write the VCD to FILE instead (one of the two CPU runs
//                 can keep its own trace).
//
// Prints a speed line at the end: simulated time vs wall time (Verilator
// throughput in simulated MHz — NOT a CPU speed).
#include "Vtb_l1.h"
#include "Vtb_l1___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <chrono>
#include <cstdio>
#include <cstring>

// Verilator (non-SystemC build, -DVM_SC=0) declares sc_time_stamp() as weak
// (verilated_funcs.h: `extern double sc_time_stamp() VL_ATTR_WEAK;`). The
// harness drives its own clock and exits via $finish.
double sc_time_stamp()
{
	return 0.0;
}

int main(int argc, char** argv)
{
	// This custom main replaces Verilator's generated main, so the trace
	// flags are parsed here (the library's commandArgs only stores argv
	// for $value$plusargs-style lookups).
	bool tracing = false;
	const char* vcdname = "tb_l1.vcd";
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--trace") == 0) {
			tracing = true;
		} else if (strncmp(argv[i], "--vcd=", 6) == 0) {
			tracing = true;
			vcdname = argv[i] + 6;
		}
	}

	VerilatedContext context;
	context.commandArgs(argc, argv);
	context.traceEverOn(true);  // must precede model construction
	Vtb_l1* top = new Vtb_l1(&context);

	VerilatedVcdC vcd;
	if (tracing) {
		context.trace(&vcd, 0);
		vcd.open(vcdname);
		if (!vcd.isOpen()) {
			printf("ERROR: could not open %s for tracing\n", vcdname);
			delete top;
			return 2;
		}
	}

	// Verilator 5 --timing main loop (see level_neg1/main.cpp for the
	// build-specific protocol notes).
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
	printf("L1 SPEED  sim=%0.3f ms  wall=%0.1f ms  ~%.2f MHz "
	       "(Verilator throughput)\n",
	       sim_ps / 1e6, wall_ms, mhz);
	top->final();

	// Module-scope `reg [15:0] errors` (naming: <module>__DOT__<signal>).
	const int status = (top->rootp->tb_l1__DOT__errors != 0) ? 1 : 0;
	delete top;
	return status;
}
