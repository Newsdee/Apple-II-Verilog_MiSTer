// unit_tests/level_neg1/main.cpp
//
// Minimal --timing main for the CPU harness.  Runs the Verilator event loop
// until the testbench calls exit()/finish(), then returns the SV exit status
// (0 = pass, non-zero = fail).  Compiled + linked by Verilator via --exe.
#include "Vtb_cpu.h"
#include "verilated.h"

int main(int argc, char** argv)
{
	Verilated::commandArgs(argc, argv);
	Vtb_cpu* top = new Vtb_cpu;

	// --timing: eval() advances the simulation and processes the event queue.
	// Stop when the SV testbench calls exit()/finish (gotFinish).  final() is
	// void in this Verilator build, so it cannot be used as a loop condition;
	// the free-running clock also means the model never settles on its own,
	// so gotFinish() (set by $finish) is the sole exit condition.
	while (!Verilated::gotFinish()) {
		top->eval();
	}

	const int status = (top->errors() != 0) ? 1 : 0;
	delete top;
	return status;
}
