#!/bin/sh
# ============================================================================
# unit_tests/level_neg1/run_neg1.sh
#
# Build + run the level_neg1 (config -1) isolated-CPU testbench under
# MSYS2 (ucrt64).  Thin wrapper for the two-stage Verilator build; all
# env setup (PATH, writable TMP, VERILATOR_ROOT) happens INSIDE this shell
# - parent-shell exports do not propagate (see unit_tests/PROGRESS.md 1b).
#
#   run_neg1.sh [nmos|wdc] [--trace] [clean] [gui] [--stall-test] [--run-frames N]
#
#   nmos|wdc        which CPU core to build/run (default: nmos = nmos6502)
#   --trace         also write tb_cpu.vcd (open in GTKWave or similar;
#                   ignored for gui, which does no VCD)
#   clean           remove the build_<cpu> tree before building
#   gui             build/run the imgui GUI (tb_cpu_gui top; opens a window
#                   with a "Stall (pause core)" checkbox + live readouts)
#   --stall-test    (gui) headless control-path check, no window:
#                   verifies the stall write freezes/resumes ce_count
#   --run-frames N  (gui) quit the GUI after N frames (smoke launches)
#
# Prints the test result (CPU_NEG1 PASS/FAIL) and a speed line
# (simulated us / wall ms / Verilator throughput in MHz).
# ============================================================================
set -e

CPU=nmos
TRACE=
CLEAN=
GUI=
EXE_ARGS=
while [ $# -gt 0 ]; do
	case "$1" in
		nmos|wdc)       CPU=$1; shift ;;
		--trace)        TRACE=--trace; shift ;;
		clean)          CLEAN=1; shift ;;
		gui)            GUI=1; shift ;;
		--stall-test)   EXE_ARGS="$EXE_ARGS --stall-test"; shift ;;
		--run-frames)   EXE_ARGS="$EXE_ARGS --run-frames $2"; shift 2 ;;
		*) echo "unknown arg: $1 (expected nmos|wdc, --trace, clean, gui, --stall-test, --run-frames N)"; exit 2 ;;
	esac
done

export PATH=/c/msys64/usr/bin:/c/msys64/ucrt64/bin:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator

# cd to the script directory without external tools: coreutils (dirname,
# ls, rm, head) live in /c/msys64/usr/bin and are absent from the PATH
# inherited from a regular Windows console - the export above is what makes
# them (and the toolchain) available.  The .bat pushd's here already; this
# is a defensive fallback for direct `sh run_neg1.sh` use.
case $0 in
    */*) cd "${0%/*}" 2>/dev/null || true ;;
esac
if [ -n "$GUI" ]; then
	# imgui GUI build: separate top module + link libs (see Makefile gui)
	if [ -n "$CLEAN" ]; then rm -rf build_${CPU}_gui; fi
	mingw32-make CPU=$CPU gui
	exe=$(ls build_${CPU}_gui/obj_dir/*.exe 2>/dev/null | head -1)
	[ -n "$exe" ] || { echo "ERROR: no exe in build_${CPU}_gui/obj_dir (see build log above)"; exit 2; }
	echo "run: $exe $EXE_ARGS"
	"$exe" $EXE_ARGS
else
	if [ -n "$CLEAN" ]; then
		rm -rf build_$CPU
	fi
	mingw32-make CPU=$CPU
	exe=$(ls build_$CPU/obj_dir/*.exe 2>/dev/null | head -1)
	[ -n "$exe" ] || { echo "ERROR: no exe in build_$CPU/obj_dir (see build log above)"; exit 2; }
	echo "run: $exe $TRACE"
	"$exe" $TRACE
fi
