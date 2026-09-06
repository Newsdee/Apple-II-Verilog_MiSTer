#include "Vtb_cpu_ss.h"
#include "verilated.h"

double sc_time_stamp()
{
    return 0.0;
}

int main(int argc, char** argv)
{
    VerilatedContext context;
    context.commandArgs(argc, argv);
    Vtb_cpu_ss top(&context);
    top.eval_step();
    while (!context.gotFinish()) {
        if (!top.eventsPending()) break;
        const uint64_t next = top.nextTimeSlot();
        if (next > context.time()) context.time(next);
        top.eval_step();
    }
    top.final();
    return 0;
}
