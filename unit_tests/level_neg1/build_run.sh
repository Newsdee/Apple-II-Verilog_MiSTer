#!/usr/bin/env bash
set -x
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/unit_tests/level_neg1
export PATH=/c/msys64/ucrt64/bin:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
rm -rf build_nmos
mingw32-make CPU=nmos 2>&1 | tail -40
echo "MAKE_EXIT=${PIPESTATUS[0]}"
echo "--- accessor check ---"
grep -c 'errors' build_nmos/obj_dir/Vtb_cpu.h || true
echo "--- run ---"
if [ -x build_nmos/obj_dir/Vtb_cpu.exe ]; then
  ./build_nmos/obj_dir/Vtb_cpu.exe
  echo "RUN_EXIT=$?"
else
  echo "NO EXECUTABLE"
fi
