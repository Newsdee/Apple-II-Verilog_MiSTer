# ============================================================================
# unit_tests/level_neg1/Makefile
#
# Config -1 build: isolated CPU testbench (tb_cpu) + one CPU core + a
# behavioral 64K memory model + the savestate bus.  No machine context.
#
#   make CPU=nmos   (default)  -> builds nmos6502
#   make CPU=wdc               -> builds wdc65c02
#
# Produces a self-running Verilator C++ binary:
#   build_<cpu>/obj_dir/Vtb_cpu
# Run it directly; it prints CPU_NEG1 PASS/FAIL and exits non-zero on failure.
#
# Build under MSYS2 (ucrt64).  The runner (unit_tests/run_unit_tests.ps1) sets
# PATH and working directory; this Makefile assumes `verilator_bin` and a
# C++ toolchain are already on PATH.
# ============================================================================

CPU      ?= nmos
LEVELDIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO     := $(abspath $(LEVELDIR)/../..)
RTL      := $(REPO)/rtl
V        ?= verilator_bin

ifeq ($(CPU),wdc)
  CPU_SRC := $(RTL)/cpu/wdc65c02/cpu_65c02.sv $(RTL)/cpu/wdc65c02/cpu_alu.sv
  CPU_DEF := +define+CPU_WDC
  OUT     := $(LEVELDIR)/build_wdc
else
  CPU_SRC := $(RTL)/cpu/nmos6502/cpu_65c02.sv $(RTL)/cpu/nmos6502/cpu_alu.sv
  CPU_DEF :=
  OUT     := $(LEVELDIR)/build_nmos
endif

V_OPT := -O3 --x-assign fast --x-initial fast --noassert -Wno-fatal -public-flat-rw
# --timing needs Verilator's built-in std/waiver files.  This MSYS2 build
# misdetects its install prefix (it computes /ucrt64, which is not a valid
# POSIX path here; the real dir is /c/msys64/ucrt64).  Point VERILATOR_ROOT at
# the real share/verilator dir so the std lookup succeeds.
VROOT ?= /c/msys64/ucrt64/share/verilator
V_DEF := +define+debug=1 +define+SIMULATION=1 --timescale-override 1ps/1ps -Wno-TIMESCALEMOD $(CPU_DEF)
EXE   := $(OUT)/obj_dir/Vtb_cpu.exe

.PHONY: all clean run
all: $(EXE)

$(EXE): tb_cpu.sv main.cpp $(CPU_SRC)
	@mkdir -p $(OUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc --timing -exe $(V_OPT) $(V_DEF) --top-module tb_cpu \
		-Mdir $(OUT)/obj_dir main.cpp tb_cpu.sv $(CPU_SRC)
	VERILATOR_ROOT=$(VROOT) $(MAKE) -C $(OUT)/obj_dir -f Vtb_cpu.mk
	@echo "built $@"

run: all
	$(EXE)

clean:
	rm -rf build_nmos build_wdc
