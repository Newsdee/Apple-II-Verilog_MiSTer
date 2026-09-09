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

# ---------------------------------------------------------------------------
# MSYS2 make env quirk (2026-09-07, lesson learned, root-caused the same day):
# the canonical build path is NATIVE mingw32-make (see run_l2.sh and
# unit_tests/PROGRESS.md 1b.1/1b.6). Two traps for the TMP the link stage
# needs, both verified with probe makefiles on this host:
#  1. MSYS /usr/bin/make does NOT propagate the outer shell's TMP/TEMP/TMPDIR
#     into recipe child envs (they arrive empty), so g++ falls back to
#     C:\WINDOWS, which this host denies writes to -> "Cannot create temporary
#     file in C:\WINDOWS: Permission denied" / Error 127.
#  2. The `export` directives below fix (1), but the value MUST be a Windows
#     drive path (C:/msys64/tmp). A POSIX-style /c/msys64/tmp is re-converted
#     by native g++ relative to the current drive -> E:\c\msys64\tmp (absent)
#     -> g++ fast-fails -> "Error -1073740791" (0xC0000409) at the link.
#     Windows-form TMP links fine under native make; MSYS make also accepts it.
# Harmless under mingw32-make when the outer shell already exports a good TMP.
# ---------------------------------------------------------------------------
export TMP    := C:/msys64/tmp
export TEMP   := C:/msys64/tmp
export TMPDIR := C:/msys64/tmp

# apple2.v instantiates BOTH cores unconditionally
CPU_SRC  := $(RTL)/cpu/nmos6502/cpu_65c02.sv $(RTL)/cpu/nmos6502/cpu_alu.sv \
            $(RTL)/cpu/wdc65c02/cpu_65c02.sv $(RTL)/cpu/wdc65c02/cpu_alu.sv
# machine core + video pipeline + PS/2 keyboard + ROM helper + ramcard
MACH_SRC := $(RTL)/apple2.v $(RTL)/keyboard.v $(RTL)/timing_generator.v \
            $(RTL)/video_generator.v $(RTL)/rom.v $(RTL)/ramcard.v
# Disk II slot controller + per-drive MFM + track buffer (level_2 addition)
DISK_SRC := $(RTL)/disk_ii.v $(RTL)/drive_ii.v $(RTL)/floppy_track.sv \
            $(RTL)/dpram.v
# Composite video path (encoder + SPC=4 decoder, 2026-09-07)
COMP_SRC := $(RTL)/apple_composite.sv mister/composite_decoder.sv
# Save-state (level_1b port, 2026-09-08): coordinator + direct 64-bit
# DDRAM bridge, referenced LIVE from unit_tests/level_1b/ (the same
# modules the level_2 mister build uses).
SS_SRC   := ../level_1b/savestate_manager_l1b.sv ../level_1b/savestate_ddr_l1b.sv
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

# Composite video unit tests (2026-09-07, see COMPOSITE_PROGRESS.md):
# encoder + SPC=4 decoder against a synthetic NTSC line stream, no machine.
# Separate obj dirs so the l2 build/clean never clobbers them (the level_2
# Makefile has been shared with other work in the same dir - keep it that
# way; do not build the composite unit exes into build/).
COMPOUT   := $(LEVELDIR)/build_comp
COMPEXE   := $(COMPOUT)/obj_dir/Vtb_composite.exe
COMPDBG   := $(LEVELDIR)/build_comp_dbg
COMPDBGE  := $(COMPDBG)/obj_dir/Vtb_composite_dbg.exe
MIXOUT    := $(LEVELDIR)/build_mixplus
MIXEXE    := $(MIXOUT)/obj_dir/Vtb_mixplus.exe
VBOUT     := $(LEVELDIR)/build_vblend
VBEXE     := $(VBOUT)/obj_dir/Vtb_vblend.exe
# --binary (not --exe): a pure self-driving TB has no C++ main, so
# Verilator's auto main is required - it also provides the sc_time_stamp()
# stub that --timing links need (a bare --exe link fails with undefined
# sc_time_stamp + WinMain on this toolchain; level_1b uses --binary the
# same way).  Verified 2026-09-07.
COMP_VFLAGS := --cc --binary -O2 -Wno-fatal -Wno-WIDTH --timing
# hq2x.sv (framework, Quartus-compiled) procedurally assigns a wire
# (Result) - a Verilator strict-mode error, harmless here: hq2x is
# instantiated but never selected (hq2x=0).
MIX_VFLAGS := $(COMP_VFLAGS) -Wno-PROCASSWIRE

.PHONY: all gui clean run composite composite_dbg vblend
all: $(EXE)
gui: $(GUIEXE)
composite: $(COMPEXE)
composite_dbg: $(COMPDBGE)
# Composite wrapper-block harness (2026-09-08): drives the Apple-II.sv
# COMPOSITE VIDEO section (2-FF sync + CLK_VIDEO-domain sync derivation +
# encoder + video_mixer_plus A/B) from a 4x clock with a ce_pix divider.
mixplus: $(MIXEXE)
# NTSC vertical blend module unit TB (2026-09-11): self-driving, ce=1,
# no CWD-relative files - runs from anywhere.
vblend: $(VBEXE)

$(EXE): tb_l2.sv main_l2.cpp l2_disk_host.h $(MACH_SRC) $(CPU_SRC) $(DISK_SRC) $(COMP_SRC) $(SS_SRC) $(ROMS)
	@mkdir -p $(OUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc -exe $(V_OPT) $(V_DEF) --top-module tb_l2 \
		-CFLAGS "$(HOSTINC)" \
		-Mdir $(OUT)/obj_dir main_l2.cpp tb_l2.sv $(MACH_SRC) $(CPU_SRC) $(DISK_SRC) $(COMP_SRC) $(SS_SRC)
	$(MAKE) -C $(OUT)/obj_dir -f Vtb_l2.mk
	@echo "built $@  (run from the REPO ROOT: +cpu=0 nmos / +cpu=1 wdc)"

$(GUIEXE): tb_l2.sv l2_disk_host.h $(GUI_SRC) $(MACH_SRC) $(CPU_SRC) $(DISK_SRC) $(COMP_SRC) $(SS_SRC) $(ROMS)
	@mkdir -p $(GUIOUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc -exe $(V_OPT) $(V_DEF) --top-module tb_l2 \
		-CFLAGS "$(GUI_CFLAGS)" -LDFLAGS "$(GUI_LDFLAGS)" \
		-Mdir $(GUIOUT)/obj_dir $(GUI_SRC) tb_l2.sv $(MACH_SRC) $(CPU_SRC) $(DISK_SRC) $(COMP_SRC) $(SS_SRC)
	$(MAKE) -C $(GUIOUT)/obj_dir -f Vtb_l2.mk
	@echo "built $@  (run from the REPO ROOT: +cpu=0 nmos / +cpu=1 wdc; see run_l2.sh gui)"

run: all
	$(EXE) +cpu=0

$(COMPEXE): tb_composite.sv $(COMP_SRC)
	@mkdir -p $(COMPOUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) $(COMP_VFLAGS) --top-module tb_composite \
		-Mdir $(COMPOUT)/obj_dir tb_composite.sv $(COMP_SRC)
	$(MAKE) -C $(COMPOUT)/obj_dir -f Vtb_composite.mk
	@mv -f $(COMPOUT)/obj_dir/Vtb_composite $(COMPOUT)/obj_dir/Vtb_composite.exe
	@echo "built $@  (run from the REPO ROOT)"

$(COMPDBGE): tb_composite_dbg.sv $(COMP_SRC)
	@mkdir -p $(COMPDBG)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) $(COMP_VFLAGS) --top-module tb_composite_dbg \
		-Mdir $(COMPDBG)/obj_dir tb_composite_dbg.sv $(COMP_SRC)
	$(MAKE) -C $(COMPDBG)/obj_dir -f Vtb_composite_dbg.mk
	@mv -f $(COMPDBG)/obj_dir/Vtb_composite_dbg $(COMPDBG)/obj_dir/Vtb_composite_dbg.exe
	@echo "built $@  (run from the REPO ROOT)"

$(MIXEXE): mister/tb_mixplus.sv $(COMP_SRC) mister/video_mixer_plus.sv \
		mister/ntsc_vertical_blend.sv \
		mister/composite_decoder.sv mister/sys/video_freezer.sv \
		mister/sys/gamma_corr.sv mister/sys/hq2x.sv mister/sys/scandoubler.v
	@mkdir -p $(MIXOUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) $(MIX_VFLAGS) --top-module tb_mixplus \
		-Mdir $(MIXOUT)/obj_dir mister/tb_mixplus.sv $(COMP_SRC) \
		mister/video_mixer_plus.sv mister/ntsc_vertical_blend.sv \
		mister/composite_decoder.sv \
		mister/sys/video_freezer.sv mister/sys/gamma_corr.sv mister/sys/hq2x.sv \
		mister/sys/scandoubler.v
	$(MAKE) -C $(MIXOUT)/obj_dir -f Vtb_mixplus.mk
	@if [ -f $(MIXEXE) ]; then :; elif [ -f $(MIXOUT)/obj_dir/Vtb_mixplus ]; then mv -f $(MIXOUT)/obj_dir/Vtb_mixplus $(MIXEXE); else echo "ERROR: $(MIXEXE) missing after build" >&2; exit 1; fi
	@echo "built $@  (run from the REPO ROOT)"

$(VBEXE): mister/tb_vblend.sv mister/ntsc_vertical_blend.sv
	@mkdir -p $(VBOUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) $(COMP_VFLAGS) --top-module tb_vblend \
		-Mdir $(VBOUT)/obj_dir mister/tb_vblend.sv mister/ntsc_vertical_blend.sv
	$(MAKE) -C $(VBOUT)/obj_dir -f Vtb_vblend.mk
	@if [ -f $(VBEXE) ]; then :; elif [ -f $(VBOUT)/obj_dir/Vtb_vblend ]; then mv -f $(VBOUT)/obj_dir/Vtb_vblend $(VBEXE); else echo "ERROR: $(VBEXE) missing after build" >&2; exit 1; fi
	@echo "built $@  (run from anywhere - no CWD-relative files)"

clean:
	rm -rf build build_gui build_comp build_comp_dbg build_mixplus build_vblend
