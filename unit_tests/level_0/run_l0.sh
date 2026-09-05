#!/bin/sh
# ============================================================================
# unit_tests/level_0/run_l0.sh
#
# Build + run the level_0 (config 0) CPU + real ROM + machine decode
# testbench under MSYS2 (ucrt64).  Thin wrapper for the two-stage Verilator
# build; all env setup (PATH, writable TMP, VERILATOR_ROOT) happens INSIDE
# this shell - parent-shell exports do not propagate (see
# unit_tests/PROGRESS.md 1b).
#
#   run_l0.sh [nmos|wdc] [--trace] [clean]
#
#   nmos|wdc        which CPU core to build/run (default: nmos = nmos6502)
#   --trace         also write tb_l0.vcd (open in GTKWave or similar)
#   clean           remove the build_<cpu> tree before building
#
# Prints the test result (L0 PASS/FAIL) and a speed line (simulated ms /
# wall ms / Verilator throughput in MHz).  The ROM (rtl/roms/apple2e.hex)
# is read at runtime relative to this directory.
# ============================================================================
set -e

CPU=nmos
TRACE=
CLEAN=
while [ $# -gt 0 ]; do
	case "$1" in
		nmos|wdc)       CPU=$1; shift ;;
		--trace)        TRACE=--trace; shift ;;
		clean)          CLEAN=1; shift ;;
		*) echo "unknown arg: $1 (expected nmos|wdc, --trace, clean)"; exit 2 ;;
	esac
done

export PATH=/c/msys64/usr/bin:/c/msys64/ucrt64/bin:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator

# cd to the script directory without external tools: coreutils (dirname,
# ls, rm, head) live in /c/msys64/usr/bin and are absent from the PATH
# inherited from a regular Windows console - the export above is what makes
# them (and the toolchain) available.  The .bat pushd's here already; this
# is a defensive fallback for direct `sh run_l0.sh` use.  The ROM $readmemh
# path is relative to the process CWD, so this cd is load-bearing.
case $0 in
    */*) cd "${0%/*}" 2>/dev/null || true ;;
esac

if [ -n "$CLEAN" ]; then
	rm -rf build_$CPU
fi
mingw32-make CPU=$CPU
exe=$(ls build_$CPU/obj_dir/*.exe 2>/dev/null | head -1)
[ -n "$exe" ] || { echo "ERROR: no exe in build_$CPU/obj_dir (see build log above)"; exit 2; }
echo "run: $exe $TRACE"
"$exe" $TRACE
