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

V_OPT := -O3 --x-assign fast --x-initial fast --noassert -Wno-fatal -public --trace
# --trace (compile-time) generates the VCD hookup; main.cpp opens tb_cpu.vcd
# only when run with `--trace`.  V_OPT is not a build dependency: after
# changing it, rebuild from clean (run_neg1.bat clean / make clean).
# --timing needs Verilator's built-in std/waiver files.  This MSYS2 build
# misdetects its install prefix (it computes /ucrt64, which is not a valid
# POSIX path here; the real dir is /c/msys64/ucrt64).  Point VERILATOR_ROOT at
# the real share/verilator dir so the std lookup succeeds.
VROOT ?= /c/msys64/ucrt64/share/verilator
V_DEF := +define+debug=1 +define+SIMULATION=1 --timescale-override 1ps/1ps -Wno-TIMESCALEMOD $(CPU_DEF)
EXE   := $(OUT)/obj_dir/Vtb_cpu.exe

# ---------------------------------------------------------------------------
# GUI build: imgui + SDL2 + OpenGL3 window driving tb_cpu_gui (top module
# tb_cpu_gui; gui/main_gui.cpp + the vendored imgui in gui/imgui/).
#   make CPU=nmos gui    -> build_nmos_gui/obj_dir/Vtb_cpu_gui.exe
# The exe opens a window with a "Stall (pause core)" checkbox and live CPU/
# bus/RAM readouts.  Headless control-path check:  Vtb_cpu_gui.exe --stall-test
# V_OPT is not a build dependency; a changed V_OPT needs a clean rebuild.
# ---------------------------------------------------------------------------
GUIOUT    := $(OUT)_gui
GUIEXE    := $(GUIOUT)/obj_dir/Vtb_cpu_gui.exe
GUI_SRC   := gui/main_gui.cpp \
	gui/imgui/imgui.cpp \
	gui/imgui/imgui_draw.cpp \
	gui/imgui/imgui_tables.cpp \
	gui/imgui/imgui_widgets.cpp \
	gui/imgui/backends/imgui_impl_sdl2.cpp \
	gui/imgui/backends/imgui_impl_opengl3.cpp
# imgui_impl_sdl2.cpp includes <SDL.h> directly, so the SDL2 include dir
# must be on the -I path.  Windows-style path (mingw32-make passes -I args
# to native g++ unconverted; POSIX /c/... paths would not resolve).  Override
# with SDL_INC=... if MSYS2 lives elsewhere.
SDL_INC   ?= C:/msys64/ucrt64/include/SDL2
# GUI_CPU_NAME is passed UNQUOTED: the obj_dir make runs under native
# mingw32-make/g++, which would keep shell-style quotes literal.
# main_gui.cpp stringifies it (GUI_STR).
GUI_CFLAGS  := -I$(LEVELDIR)/gui/imgui -I$(LEVELDIR)/gui/imgui/backends -I$(SDL_INC) -DGUI_CPU_NAME=$(CPU)
GUI_LDFLAGS := -lSDL2 -lopengl32

.PHONY: all gui clean run
all: $(EXE)
gui: $(GUIEXE)

$(EXE): tb_cpu.sv main.cpp $(CPU_SRC)
	@mkdir -p $(OUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc --timing -exe $(V_OPT) $(V_DEF) --top-module tb_cpu \
		-Mdir $(OUT)/obj_dir main.cpp tb_cpu.sv $(CPU_SRC)
	VERILATOR_ROOT=$(VROOT) $(MAKE) -C $(OUT)/obj_dir -f Vtb_cpu.mk
	@echo "built $@"

$(GUIEXE): tb_cpu_gui.sv $(GUI_SRC) $(CPU_SRC)
	@mkdir -p $(GUIOUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc --timing -exe $(V_OPT) $(V_DEF) --top-module tb_cpu_gui \
		-CFLAGS "$(GUI_CFLAGS)" -LDFLAGS "$(GUI_LDFLAGS)" \
		-Mdir $(GUIOUT)/obj_dir $(GUI_SRC) tb_cpu_gui.sv $(CPU_SRC)
	VERILATOR_ROOT=$(VROOT) $(MAKE) -C $(GUIOUT)/obj_dir -f Vtb_cpu_gui.mk
	@echo "built $@"

run: all
	$(EXE)

clean:
	rm -rf build_nmos build_wdc build_nmos_gui build_wdc_gui
