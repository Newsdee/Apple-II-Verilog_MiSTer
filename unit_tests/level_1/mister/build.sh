#!/bin/sh
# ============================================================================
# Level 1 MiSTer integration-test core - full Quartus compile.
#
# Usage (from anywhere):
#     sh unit_tests/level_1/mister/build.sh
#
# cds to the repo root, refreshes the in-project infrastructure copies
# (newer files only), then runs the full compile flow.  Output:
#     unit_tests/level_1/mister/output_files/level1.rbf
#
# The DUT (rtl/, rtl/cpu/) is referenced live from the repo - that is
# the point of the test.  sys/, jtag.cdf, the PLL QIP package and the
# ROM data are copied into the project so the build works from any CWD
# (sys.tcl's project-relative refs and the DUT's CWD-relative
# $readmemh "rtl/roms/*.hex" paths).
# ============================================================================
cd "$(dirname "$0")/../../.." || exit 1
mkdir -p unit_tests/level_1/mister/rtl/roms unit_tests/level_1/mister/rtl/pll
cp -r -u sys/. unit_tests/level_1/mister/sys/
cp -u jtag.cdf unit_tests/level_1/mister/
cp -u rtl/pll.qip rtl/pll.v unit_tests/level_1/mister/rtl/
cp -r -u rtl/pll/. unit_tests/level_1/mister/rtl/pll/
cp -r -u rtl/roms/. unit_tests/level_1/mister/rtl/roms/
quartus_sh --flow compile unit_tests/level_1/mister/level1
