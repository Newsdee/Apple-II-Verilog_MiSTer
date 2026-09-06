#!/bin/sh
# ============================================================================
# unit_tests/level_2/run_l2.sh
#
# Build + run the level_2 testbench (machine core + native monochrome video
# + real PS/2 keyboard + real Disk II slot controller + real floppy_track
# x2) under MSYS2 (ucrt64).  Thin wrapper for the two-stage Verilator build;
# all env setup (PATH, writable TMP, VERILATOR_ROOT) happens INSIDE this
# shell (see unit_tests/PROGRESS.md 1b).
#
#   run_l2.sh [clean] [--trace] [nmos|wdc|both] (--empty | --disk <nib> |
#              --write-test [--disk <nib>]) [--timeout S]
#
#   clean           remove the build tree before building
#   --trace         write a VCD trace (out/tb_l2.vcd)
#   nmos|wdc|both   which CPU run(s) to execute (default: both)
#   --empty         drive 1 is empty (no disk) - the machine should boot to
#                   the ROM monitor with no disk activity
#   --disk <nib>    mount <nib> on drive 1 - the machine should boot DOS
#                   3.3 from it (default: unit_tests/level_2/DOS_3_3.nib)
#   --write-test    directed dirty-track flush: boot from a scratch copy,
#                   force a 16-byte debug write into ft1's track RAM and
#                   require the DUT's own flush to persist the track to the
#                   scratch copy (source image never written)
#   --timeout S     per-scenario sim-time timeout in seconds (default:
#                   1.5 for empty, 6.0 for preloaded)
#
#   gui             build/run the imgui GUI (same tb_l2 top; Makefile gui):
#                   native monochrome video window + Disk II / DOS-boot
#                   readouts + real PS/2 keyboard forwarding
#   --headless [N]  (gui) headless smoke, no window: boot N video frames
#                   (default 5) + disk-activity pass + stall check; PASS
#                   -> exit 0
#   --selfkey       (gui, headless) synthetic PS/2 'A' press/release, verify
#                   the keyboard chain reports it (akd climbs)
#   --reboot        (gui, headless) cold-reboot the machine exactly the way
#                   the GUI button does; verify POR re-asserts/releases and
#                   a fresh non-blank frame
#   --run-frames N  (gui) quit the GUI after N rendered frames
#   --scale N       (gui) video scale factor in the window (default 2)
#
#   NOTE (gui): without --empty/--disk the GUI mounts the level_2
#   DOS_3_3.nib by default (watching the DOS boot is the point); the
#   headless path keeps its --empty default.
#
#   run_l2.sh gui [clean] [--headless [N]] [--selfkey] [--reboot] [nmos|wdc]
#               (--empty | --disk <nib>) [--run-frames N] [--scale N]
#
# ONE build covers both CPU cores (the DUT muxes on its `cpu` input); the
# script runs the binary once per selected core: +cpu=0 (nmos6502) and/or
# +cpu=1 (wdc65c02).
#
# LOAD-BEARING: the DUT's $readmemh ROM paths (rtl/roms/*.hex, incl.
# diskii.hex) resolve against the process CWD, so the binary runs from the
# REPO ROOT.  Output goes to unit_tests/level_2/out/.
#
# Exits non-zero if either CPU run fails.
# ============================================================================
set -e

CLEAN=
TRACE=
GUI=
CPUSEL=both
SCENARGS="--empty"
SCENGIVEN=
WT=
EXE_ARGS=
while [ $# -gt 0 ]; do
	case "$1" in
		clean)      CLEAN=1; shift ;;
		--trace)    TRACE=1; shift ;;
		gui)        GUI=1; shift ;;
		nmos|wdc)   CPUSEL=$1; shift ;;
		both)       CPUSEL=both; shift ;;
		--empty)    SCENARGS="--empty"; SCENGIVEN=1; shift ;;
		--disk)     if [ $# -gt 0 ] && [ "$2" != "" ] && [ "${2#-}" = "$2" ]; then
		                if [ "$SCENARGS" != "--empty" ] && [ -n "$SCENARGS" ]; then
		                    SCENARGS="$SCENARGS --disk $2"
		                else
		                    SCENARGS="--disk $2"
		                fi; SCENGIVEN=1; shift 2
		            else
		                SCENARGS="--disk unit_tests/level_2/DOS_3_3.nib"; SCENGIVEN=1; shift
		            fi ;;
		--write-test) WT=1; SCENGIVEN=1; shift ;;
		--timeout)  TIMEOUT=$2; shift 2 ;;
		--headless) EXE_ARGS="$EXE_ARGS --headless"; shift
		            if [ $# -gt 0 ] && [ "$1" -ge 1 ] 2>/dev/null; then
		                EXE_ARGS="$EXE_ARGS $1"; shift
		            fi ;;
		--selfkey)  EXE_ARGS="$EXE_ARGS --selfkey"; shift ;;
		--reboot)   EXE_ARGS="$EXE_ARGS --reboot"; shift ;;
		--run-frames) EXE_ARGS="$EXE_ARGS --run-frames $2"; shift 2 ;;
		--scale)    EXE_ARGS="$EXE_ARGS --scale $2"; shift 2 ;;
		*) echo "unknown arg: $1 (expected clean, --trace, gui, nmos|wdc|both, --empty, --disk <nib>, --write-test, --timeout S, --headless [N], --selfkey, --reboot, --run-frames N, --scale N)"; exit 2 ;;
	esac
done

if [ -n "$WT" ]; then
	if [ -z "$SCENGIVEN" ] || [ "$SCENARGS" = "--empty" ]; then
		SCENARGS="--write-test"
	else
		SCENARGS="$SCENARGS --write-test"
	fi
fi

export PATH=/c/msys64/usr/bin:/c/msys64/ucrt64/bin:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator

# cd to the script directory, then the repo root (two levels up).
case $0 in
    */*) cd "${0%/*}" 2>/dev/null || true ;;
esac
cd ../..

if [ -n "$GUI" ]; then
	# imgui GUI build: same top module (tb_l2), separate link libs
	# (Makefile gui).  One launch: nmos unless wdc was explicitly
	# requested (a single window).
	if [ -z "$SCENGIVEN" ]; then
		SCENARGS=   # GUI default: mount the DOS 3.3 nib (see the header)
	fi
	if [ -n "$CLEAN" ]; then
		rm -rf unit_tests/level_2/build_gui
	fi
	mingw32-make -C unit_tests/level_2 gui
	gexe=$(ls unit_tests/level_2/build_gui/obj_dir/*.exe 2>/dev/null | head -1)
	[ -n "$gexe" ] || { echo "ERROR: no exe in unit_tests/level_2/build_gui/obj_dir (see build log above)"; exit 2; }
	mkdir -p unit_tests/level_2/out
	CPUIDX=0
	if [ "$CPUSEL" = wdc ]; then CPUIDX=1; fi
	echo "run: $gexe +cpu=$CPUIDX $SCENARGS $EXE_ARGS"
	# LOAD-BEARING: runs from the repo root (ROM $readmemh paths, and the
	# default .nib path is CWD-relative too).
	exec "$gexe" +cpu=$CPUIDX $SCENARGS $EXE_ARGS
fi

if [ -n "$CLEAN" ]; then
	rm -rf unit_tests/level_2/build
fi
mingw32-make -C unit_tests/level_2
exe=$(ls unit_tests/level_2/build/obj_dir/*.exe 2>/dev/null | head -1)
[ -n "$exe" ] || { echo "ERROR: no exe in unit_tests/level_2/build/obj_dir (see build log above)"; exit 2; }
mkdir -p unit_tests/level_2/out

VCD=
if [ -n "$TRACE" ]; then
	VCD="--vcd=unit_tests/level_2/out/tb_l2.vcd"
fi
TOPT=
if [ -n "$TIMEOUT" ]; then
	TOPT="--timeout $TIMEOUT"
fi

# Per-CPU runs. Exit status: 1 = nmos run failed, 2 = wdc run failed
# (2 wins if both fail); the per-CPU verdict is the "L2 ... PASS/FAIL" line.
STATUS=0
if [ "$CPUSEL" = both ] || [ "$CPUSEL" = nmos ]; then
	echo "=== run cpu=0 (nmos6502) $SCENARGS ==="
	"$exe" +cpu=0 $SCENARGS || STATUS=1
fi
if [ "$CPUSEL" = both ] || [ "$CPUSEL" = wdc ]; then
	echo "=== run cpu=1 (wdc65c02) $SCENARGS ==="
	"$exe" +cpu=1 $SCENARGS || STATUS=2
fi
exit $STATUS
