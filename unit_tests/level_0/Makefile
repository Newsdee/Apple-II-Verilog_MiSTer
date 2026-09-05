# ============================================================================
# unit_tests/level_0/Makefile
#
# Config 0 build: CPU core + REAL machine ROM + behavioral 64K memory + the
# rtl/apple2.v memory-map decode (ROM gating, softswitch latches, C01X
# readbacks, IIe C3-page/C8ROM quirk).  No video, no slots, no drives.
#
#   make CPU=nmos   (default)  -> builds nmos6502
#   make CPU=wdc               -> builds wdc65c02
#
# Produces a self-running Verilator C++ binary:
#   build_<cpu>/obj_dir/Vtb_l0
# Run it directly; it prints L0 PASS/FAIL and exits non-zero on failure.
# The ROM ($readmemh of ../../rtl/roms/apple2e.hex) is read at RUNTIME
# relative to the process CWD, so the runners cd into this directory.
#
# Build under MSYS2 (ucrt64).  The runner (run_l0.sh / run_l0.bat) sets
# PATH and working directory; this Makefile assumes `verilator_bin` and a
# C++ toolchain are already on PATH.
# ============================================================================

CPU      ?= nmos
LEVELDIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO     := $(abspath $(LEVELDIR)/../..)
RTL      := $(REPO)/rtl
COMMON   := $(REPO)/unit_tests/common
ROM_HEX  := $(RTL)/roms/apple2e.hex
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

V_OPT := -O3 --x-assign fast --x-initial fast --noassert -Wno-fatal -public --trace
# --trace (compile-time) generates the VCD hookup; main.cpp opens tb_l0.vcd
# only when run with `--trace`.  V_OPT is not a build dependency: after
# changing it, rebuild from clean (run_l0.bat clean / make clean).
# --timing needs Verilator's built-in std/waiver files.  This MSYS2 build
# misdetects its install prefix (it computes /ucrt64, which is not a valid
# POSIX path here; the real dir is /c/msys64/ucrt64).  Point VERILATOR_ROOT at
# the real share/verilator dir so the std lookup succeeds.
VROOT ?= /c/msys64/ucrt64/share/verilator
V_DEF := +define+debug=1 +define+SIMULATION=1 --timescale-override 1ps/1ps -Wno-TIMESCALEMOD $(CPU_DEF)
EXE   := $(OUT)/obj_dir/Vtb_l0.exe

# Shared ladder infrastructure (unit_tests/common/): 2-phase ce generator,
# 1-ce-delayed behavioral RAM, savestate field-extraction package.
COMMON_SRC := $(COMMON)/tb_ce_gen.sv $(COMMON)/tb_ram_mem.sv $(COMMON)/tb_ss_pkg.sv

.PHONY: all clean run
all: $(EXE)

$(EXE): tb_l0.sv main.cpp $(COMMON_SRC) $(CPU_SRC) $(ROM_HEX)
	@mkdir -p $(OUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc --timing -exe $(V_OPT) $(V_DEF) --top-module tb_l0 \
		-Mdir $(OUT)/obj_dir main.cpp tb_l0.sv $(COMMON_SRC) $(CPU_SRC)
	VERILATOR_ROOT=$(VROOT) $(MAKE) -C $(OUT)/obj_dir -f Vtb_l0.mk
	@echo "built $@"

run: all
	$(EXE)

clean:
	rm -rf build_nmos build_wdc
