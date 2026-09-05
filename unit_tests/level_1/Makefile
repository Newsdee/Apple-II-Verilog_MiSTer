# ============================================================================
# unit_tests/level_1/Makefile
#
# Level 1 build: the MACHINE CORE (rtl/apple2.v, unmodified - both CPU
# cores, RAM decode, BIOS ROM, timing HAL, native video pipeline) plus the
# real PS/2 keyboard (rtl/keyboard.v, unmodified).  Monochrome video only:
# the TB samples the DUT's native VIDEO + HBL/VBL ports directly; the color
# pipeline (vga_controller in apple2_top) is NOT pulled in.
#
# One build covers BOTH CPU cores (apple2 instantiates nmos6502 and
# wdc65c02 and muxes on its `cpu` input); the TB selects at runtime with
# +cpu=0 (nmos) / +cpu=1 (wdc).
#
# Produces a self-running Verilator C++ binary:
#   build/obj_dir/Vtb_l1.exe
# It MUST run with the process CWD at the REPO ROOT: the DUT's internal
# $readmemh paths (rtl/roms/{apple2e,keyboard,video2}.hex in rom.v /
# video_generator.v / keyboard.v) are CWD-relative.  Output files go to
# unit_tests/level_1/out/ (created by the runner).
#
# Build under MSYS2 (ucrt64).  The runner (run_l1.sh / run_l1.bat) sets
# PATH and working directory; this Makefile assumes `verilator_bin` and a
# C++ toolchain are already on PATH.
# ============================================================================

LEVELDIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO     := $(abspath $(LEVELDIR)/../..)
RTL      := $(REPO)/rtl
V        ?= verilator_bin

# apple2.v instantiates BOTH cores unconditionally
CPU_SRC  := $(RTL)/cpu/nmos6502/cpu_65c02.sv $(RTL)/cpu/nmos6502/cpu_alu.sv \
            $(RTL)/cpu/wdc65c02/cpu_65c02.sv $(RTL)/cpu/wdc65c02/cpu_alu.sv
# machine core + video pipeline + PS/2 keyboard + ROM helper + ramcard
MACH_SRC := $(RTL)/apple2.v $(RTL)/keyboard.v $(RTL)/timing_generator.v \
            $(RTL)/video_generator.v $(RTL)/rom.v $(RTL)/ramcard.v
# ROMs read by the DUT ($readmemh, CWD-relative) and by the TB oracle
ROMS     := $(RTL)/roms/apple2e.hex $(RTL)/roms/keyboard.hex \
            $(RTL)/roms/video2.hex $(RTL)/roms/video.hex

V_OPT := -O3 --x-assign fast --x-initial fast --noassert -Wno-fatal -public --trace
# --trace (compile-time) generates the VCD hookup; main.cpp opens a trace
# file only when run with `--trace` / `--vcd=FILE`.  V_OPT is not a build
# dependency: after changing it, rebuild from clean.
# --timing needs Verilator's built-in std/waiver files; point
# VERILATOR_ROOT at the real share/verilator dir (see level_0/Makefile).
VROOT ?= /c/msys64/ucrt64/share/verilator
V_DEF := +define+debug=1 +define+SIMULATION=1 --timescale-override 1ps/1ps -Wno-TIMESCALEMOD
OUT   := $(LEVELDIR)/build
EXE   := $(OUT)/obj_dir/Vtb_l1.exe

# ---------------------------------------------------------------------------
# GUI build: imgui + SDL2 + OpenGL3 window driving tb_l1_gui (top module
# tb_l1_gui; gui/main_gui.cpp + the vendored imgui in gui/imgui/).  One
# build covers both CPUs (runtime +cpu=, like the headless exe).
#   make gui            -> build_gui/obj_dir/Vtb_l1_gui.exe
# The window shows the machine's native monochrome video (cold boot draws
# the Apple logo) plus video FPS, render FPS and sim speed.  Headless
# smoke (no window):  Vtb_l1_gui.exe +cpu=0 --headless
# V_OPT is not a build dependency; a changed V_OPT needs a clean rebuild.
# ---------------------------------------------------------------------------
GUIOUT    := $(LEVELDIR)/build_gui
GUIEXE    := $(GUIOUT)/obj_dir/Vtb_l1_gui.exe
GUI_SRC   := gui/main_gui.cpp \
	gui/imgui/imgui.cpp \
	gui/imgui/imgui_draw.cpp \
	gui/imgui/imgui_tables.cpp \
	gui/imgui/imgui_widgets.cpp \
	gui/imgui/backends/imgui_impl_sdl2.cpp \
	gui/imgui/backends/imgui_impl_opengl3.cpp
# imgui_impl_sdl2.cpp includes <SDL.h> directly, so the SDL2 include dir
# must be on the -I path.  Windows-style path (mingw32-make passes -I args
# to native g++ unconverted; POSIX /c/... paths would not resolve).  See
# level_neg1/Makefile for the rationale; override with SDL_INC=... if
# MSYS2 lives elsewhere.
SDL_INC   ?= C:/msys64/ucrt64/include/SDL2
GUI_CFLAGS  := -I$(LEVELDIR)/gui/imgui -I$(LEVELDIR)/gui/imgui/backends -I$(SDL_INC)
GUI_LDFLAGS := -lSDL2 -lopengl32

.PHONY: all gui clean run
all: $(EXE)
gui: $(GUIEXE)

$(EXE): tb_l1.sv main.cpp $(MACH_SRC) $(CPU_SRC) $(ROMS)
	@mkdir -p $(OUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc --timing -exe $(V_OPT) $(V_DEF) --top-module tb_l1 \
		-Mdir $(OUT)/obj_dir main.cpp tb_l1.sv $(MACH_SRC) $(CPU_SRC)
	VERILATOR_ROOT=$(VROOT) $(MAKE) -C $(OUT)/obj_dir -f Vtb_l1.mk
	@echo "built $@  (run from the REPO ROOT: +cpu=0 nmos / +cpu=1 wdc)"

$(GUIEXE): tb_l1_gui.sv $(GUI_SRC) $(MACH_SRC) $(CPU_SRC)
	@mkdir -p $(GUIOUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc --timing -exe $(V_OPT) $(V_DEF) --top-module tb_l1_gui \
		-CFLAGS "$(GUI_CFLAGS)" -LDFLAGS "$(GUI_LDFLAGS)" \
		-Mdir $(GUIOUT)/obj_dir $(GUI_SRC) tb_l1_gui.sv $(MACH_SRC) $(CPU_SRC)
	VERILATOR_ROOT=$(VROOT) $(MAKE) -C $(GUIOUT)/obj_dir -f Vtb_l1_gui.mk
	@echo "built $@  (run from the REPO ROOT: +cpu=0 nmos / +cpu=1 wdc)"

# ---------------------------------------------------------------------------
# GUI VGA A/B build (2026-09-05, TEMPORARY): the same GUI, but the TB pulls
# in the real vga_controller (+define+L1_VGA) and the C++ harness samples
# its RGB output with the whole-machine SimVideo::Clock logic and shows it
# via a GL texture + ImGui::Image (the exact verilator/sim video path).
#   make gui_vga       -> build_gui_vga/obj_dir/Vtb_l1_gui_vga.exe
# ---------------------------------------------------------------------------
GUIOUT_VGA := $(LEVELDIR)/build_gui_vga
GUIEXE_VGA := $(GUIOUT_VGA)/obj_dir/Vtb_l1_gui.exe

.PHONY: gui_vga
gui_vga: $(GUIEXE_VGA)

$(GUIEXE_VGA): tb_l1_gui.sv $(GUI_SRC) $(MACH_SRC) $(CPU_SRC) $(RTL)/vga_controller.v
	@mkdir -p $(GUIOUT_VGA)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc --timing -exe $(V_OPT) $(V_DEF) +define+L1_VGA --top-module tb_l1_gui \
		-CFLAGS "$(GUI_CFLAGS) -DL1_VGA" -LDFLAGS "$(GUI_LDFLAGS)" \
		-Mdir $(GUIOUT_VGA)/obj_dir $(GUI_SRC) tb_l1_gui.sv $(MACH_SRC) $(CPU_SRC) $(RTL)/vga_controller.v
	VERILATOR_ROOT=$(VROOT) $(MAKE) -C $(GUIOUT_VGA)/obj_dir -f Vtb_l1_gui.mk
	@echo "built $@  (run from the REPO ROOT: +cpu=0 nmos / +cpu=1 wdc)"

run: all
	$(EXE) +cpu=0

clean:
	rm -rf build build_gui build_gui_vga
