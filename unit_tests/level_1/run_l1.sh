#!/bin/sh
# ============================================================================
# unit_tests/level_1/run_l1.sh
#
# Build + run the level_1 testbench (machine core + native MONOCHROME video
# + real PS/2 keyboard) under MSYS2 (ucrt64).  Thin wrapper for the
# two-stage Verilator build; all env setup (PATH, writable TMP,
# VERILATOR_ROOT) happens INSIDE this shell - parent-shell exports do not
# propagate (see unit_tests/PROGRESS.md 1b).
#
#   run_l1.sh [clean] [--trace] [nmos|wdc|both] [gui [vga]] [--headless [N]] [--run-frames N] [--scale N]
#
#   clean           remove the build tree before building
#   --trace         write VCD traces (out/tb_l1_nmos.vcd, out/tb_l1_wdc.vcd)
#   nmos|wdc|both   which CPU run(s) to execute (default: both; for gui
#                   a single launch uses nmos unless wdc is requested)
#   gui             build/run the imgui GUI (tb_l1_gui top): native
#                   monochrome video window + FPS/sim-speed readouts
#   vga             (gui, TEMPORARY A/B) build/run the VGA variant: the
#                   machine video routed through the real vga_controller,
#                   shown with the whole-machine SimVideo/GL-texture path
#                   (Makefile gui_vga)
#   --headless [N]  (gui) headless smoke, no window: PASS after N video
#                   frames (default 3) if the last frame is not blank
#   --run-frames N  (gui) quit the GUI after N rendered frames
#   --scale N       (gui) video scale factor in the window (default 2)
#
# ONE build covers both CPU cores (the DUT muxes on its `cpu` input); the
# script runs the binary once per selected core: +cpu=0 (nmos6502) and/or
# +cpu=1 (wdc65c02).
#
# LOAD-BEARING: the DUT's $readmemh ROM paths (rtl/roms/*.hex) resolve
# against the process CWD, so the binary runs from the REPO ROOT.  Output
# (report, traces, PBM screens) goes to unit_tests/level_1/out/.
#
# Exits non-zero if either CPU run fails.
# ============================================================================
set -e

CLEAN=
TRACE=
CPUSEL=both
GUI=
VGA=
EXE_ARGS=
while [ $# -gt 0 ]; do
	case "$1" in
		clean)      CLEAN=1; shift ;;
		--trace)    TRACE=1; shift ;;
		nmos|wdc)   CPUSEL=$1; shift ;;
		both)       CPUSEL=both; shift ;;
		gui)        GUI=1; shift
		            if [ "$1" = "vga" ]; then VGA=1; shift; fi ;;
		--headless) EXE_ARGS="$EXE_ARGS --headless"; shift
		            if [ $# -gt 0 ] && [ "$1" -ge 1 ] 2>/dev/null; then
		                EXE_ARGS="$EXE_ARGS $1"; shift
		            fi ;;
		--run-frames) EXE_ARGS="$EXE_ARGS --run-frames $2"; shift 2 ;;
		--scale)      EXE_ARGS="$EXE_ARGS --scale $2"; shift 2 ;;
		*) echo "unknown arg: $1 (expected clean, --trace, nmos|wdc|both, gui, --headless [N], --run-frames N, --scale N)"; exit 2 ;;
	esac
done

export PATH=/c/msys64/usr/bin:/c/msys64/ucrt64/bin:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator

# cd to the script directory (the .bat pushd's here already; this is a
# defensive fallback for direct `sh run_l1.sh` use)
case $0 in
    */*) cd "${0%/*}" 2>/dev/null || true ;;
esac

# repo root = two levels up (unit_tests/level_1 -> repo root)
cd ../..

if [ -n "$GUI" ]; then
	# imgui GUI build: separate top module + link libs (Makefile gui).
	# One launch per CPU: nmos unless wdc was explicitly requested.
	# `gui vga` (temporary A/B) builds the gui_vga target instead.
	GUITARGET=gui
	GUIBUILDDIR=unit_tests/level_1/build_gui
	if [ -n "$VGA" ]; then
		GUITARGET=gui_vga
		GUIBUILDDIR=unit_tests/level_1/build_gui_vga
	fi
	if [ -n "$CLEAN" ]; then
		rm -rf unit_tests/level_1/build_gui unit_tests/level_1/build_gui_vga
	fi
	mingw32-make -C unit_tests/level_1 $GUITARGET
	gexe=$(ls $GUIBUILDDIR/obj_dir/*.exe 2>/dev/null | head -1)
	[ -n "$gexe" ] || { echo "ERROR: no exe in $GUIBUILDDIR/obj_dir (see build log above)"; exit 2; }
	CPUIDX=0
	if [ "$CPUSEL" = wdc ]; then CPUIDX=1; fi
	echo "run: $gexe +cpu=$CPUIDX $EXE_ARGS"
	# LOAD-BEARING: runs from the repo root (ROM $readmemh paths).
	exec "$gexe" +cpu=$CPUIDX $EXE_ARGS
fi

if [ -n "$CLEAN" ]; then
	rm -rf unit_tests/level_1/build
fi
mingw32-make -C unit_tests/level_1
exe=$(ls unit_tests/level_1/build/obj_dir/*.exe 2>/dev/null | head -1)
[ -n "$exe" ] || { echo "ERROR: no exe in unit_tests/level_1/build/obj_dir (see build log above)"; exit 2; }
mkdir -p unit_tests/level_1/out

VCD_N=
VCD_W=
if [ -n "$TRACE" ]; then
	VCD_N="--vcd=unit_tests/level_1/out/tb_l1_nmos.vcd"
	VCD_W="--vcd=unit_tests/level_1/out/tb_l1_wdc.vcd"
fi

# Per-CPU runs. Exit status: 1 = nmos run failed, 2 = wdc run failed
# (2 wins if both fail); the per-CPU verdict is the "L1 PASS/FAIL cpu=..."
# line printed by the exe for each run.
STATUS=0
if [ "$CPUSEL" = both ] || [ "$CPUSEL" = nmos ]; then
	echo "=== run cpu=0 (nmos6502) ==="
	"$exe" +cpu=0 $VCD_N || STATUS=1
fi
if [ "$CPUSEL" = both ] || [ "$CPUSEL" = wdc ]; then
	echo "=== run cpu=1 (wdc65c02) ==="
	"$exe" +cpu=1 $VCD_W || STATUS=2
fi
exit $STATUS
