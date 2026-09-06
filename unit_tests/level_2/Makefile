# ============================================================================
# unit_tests/level_2/Makefile
#
# Level 2 build: the level_1 machine core (rtl/apple2.v, unmodified - both
# CPU cores, RAM decode, BIOS ROM, timing HAL, native video) + the real PS/2
# keyboard (rtl/keyboard.v) + the real Disk II slot controller (rtl/disk_ii.v,
# unmodified - two drive_ii MFM decoders + controller ROM) + one real
# floppy_track per drive (rtl/floppy_track.sv + rtl/dpram.v, unmodified).
#
#   drive 1 : the disk under test (mounted by the C++ host for the
#             "preloaded" scenario; unmounted for the "empty" scenario)
#   drive 2 : always unmounted / empty (the Disk II is a 2-drive controller;
#             only one drive is populated, mirroring "add one Disk II drive")
#
# The C++ harness (main_l2.cpp) owns the host side of the floppy_track
# SD/blkdev interface - it serves .nib track data on sd_rd, mirroring
# verilator/sim/sim_blkdevice.cpp (read-only; DOS 3.3 boot is read-only).
#
# One build covers BOTH CPU cores (+cpu=0 nmos / +cpu=1 wdc).
#
# Produces a self-running Verilator C++ binary:
#   build/obj_dir/Vtb_l2.exe
# It MUST run with the process CWD at the REPO ROOT: the DUT's internal
# $readmemh paths (rtl/roms/*.hex, incl. diskii.hex) are CWD-relative.
#
# GUI build (`make gui`): imgui + SDL2 + OpenGL3 window that drives the
# SAME top module tb_l2 (gui/main_gui.cpp + the vendored imgui in
# gui/imgui/) -> build_gui/obj_dir/Vtb_l2.exe.  It is the SAME legacy
# (non-timing) build as the headless exe - the C++ DiskHost REQUIRES
# legacy eval (NOTE below) - so the GUI drives the 14.3 MHz clock by
# port toggle + eval() and reuses the DiskHost protocol from
# main_l2.cpp verbatim.  run_l2.sh gui / run_l2_gui.bat wrap it.
#
# Build under MSYS2 (ucrt64); the runner (run_l2.sh) sets PATH + CWD.
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
# Disk II slot controller + per-drive MFM + track buffer (level_2 addition)
DISK_SRC := $(RTL)/disk_ii.v $(RTL)/drive_ii.v $(RTL)/floppy_track.sv \
            $(RTL)/dpram.v
# ROMs read by the DUT ($readmemh, CWD-relative) and by the TB oracle
ROMS     := $(RTL)/roms/apple2e.hex $(RTL)/roms/keyboard.hex \
            $(RTL)/roms/video2.hex $(RTL)/roms/video.hex \
            $(RTL)/roms/diskii.hex

V_OPT := -O3 --x-assign fast --x-initial fast --noassert -Wno-fatal -public --trace
# NOTE: no --timing.  The legacy eval() model is REQUIRED so the C++
# harness can drive top-level inputs (clk_14m + the SD host bus) by
# plain field writes; --timing mode moves purely input-driven
# combinational cones (e.g. the dpram wren_a/data_a nets) into the
# stable region, which Verilator 5.050 only evaluates once at init,
# freezing those nets at 0.
# --timing would also need Verilator's built-in std/waiver files;
# VERILATOR_ROOT points at the real share/verilator dir (legacy build
# (legacy build also uses it to find verilated_std.sv / waiver files).
VROOT ?= /c/msys64/ucrt64/share/verilator
V_DEF := +define+debug=1 +define+SIMULATION=1 --timescale-override 1ps/1ps -Wno-TIMESCALEMOD
OUT   := $(LEVELDIR)/build
EXE   := $(OUT)/obj_dir/Vtb_l2.exe

# ---------------------------------------------------------------------------
# GUI build: imgui + SDL2 + OpenGL3 window (see the header).  The SAME
# top module (tb_l2) and the SAME legacy V_OPT as the headless exe.
# imgui_impl_sdl2.cpp includes <SDL.h> directly, so the SDL2 include dir
# must be on -I (not just the DLL path at runtime).  MSYS2 ucrt64
# default; override with SDL_INC=... if MSYS2 lives elsewhere.
# ---------------------------------------------------------------------------
GUIOUT    := $(LEVELDIR)/build_gui
GUIEXE    := $(GUIOUT)/obj_dir/Vtb_l2.exe
GUI_SRC   := gui/main_gui.cpp \
	gui/imgui/imgui.cpp \
	gui/imgui/imgui_draw.cpp \
	gui/imgui/imgui_tables.cpp \
	gui/imgui/imgui_widgets.cpp \
	gui/imgui/backends/imgui_impl_sdl2.cpp \
	gui/imgui/backends/imgui_impl_opengl3.cpp
SDL_INC   ?= C:/msys64/ucrt64/include/SDL2
# sim_blkdev_engine.h (the shared host-side protocol engine) lives in the
# full-sim directory; both TUs include it through l2_disk_host.h
HOSTINC   := -I$(REPO)/verilator/sim -I$(LEVELDIR)
GUI_CFLAGS  := -I$(LEVELDIR)/gui/imgui -I$(LEVELDIR)/gui/imgui/backends -I$(SDL_INC) $(HOSTINC)
GUI_LDFLAGS := -lSDL2 -lopengl32

.PHONY: all gui clean run
all: $(EXE)
gui: $(GUIEXE)

$(EXE): tb_l2.sv main_l2.cpp l2_disk_host.h $(MACH_SRC) $(CPU_SRC) $(DISK_SRC) $(ROMS)
	@mkdir -p $(OUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc -exe $(V_OPT) $(V_DEF) --top-module tb_l2 \
		-CFLAGS "$(HOSTINC)" \
		-Mdir $(OUT)/obj_dir main_l2.cpp tb_l2.sv $(MACH_SRC) $(CPU_SRC) $(DISK_SRC)
	$(MAKE) -C $(OUT)/obj_dir -f Vtb_l2.mk
	@echo "built $@  (run from the REPO ROOT: +cpu=0 nmos / +cpu=1 wdc)"

$(GUIEXE): tb_l2.sv l2_disk_host.h $(GUI_SRC) $(MACH_SRC) $(CPU_SRC) $(DISK_SRC) $(ROMS)
	@mkdir -p $(GUIOUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc -exe $(V_OPT) $(V_DEF) --top-module tb_l2 \
		-CFLAGS "$(GUI_CFLAGS)" -LDFLAGS "$(GUI_LDFLAGS)" \
		-Mdir $(GUIOUT)/obj_dir $(GUI_SRC) tb_l2.sv $(MACH_SRC) $(CPU_SRC) $(DISK_SRC)
	$(MAKE) -C $(GUIOUT)/obj_dir -f Vtb_l2.mk
	@echo "built $@  (run from the REPO ROOT: +cpu=0 nmos / +cpu=1 wdc; see run_l2.sh gui)"

run: all
	$(EXE) +cpu=0

clean:
	rm -rf build build_gui
