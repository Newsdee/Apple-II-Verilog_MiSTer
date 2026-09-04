#!/usr/bin/env bash
# rebuild + run level_neg1 (nmos) with the fixed reset-vector TB
export PATH=/c/msys64/ucrt64/bin:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/unit_tests/level_neg1 || exit 9
rm -rf build_nmos
mingw32-make CPU=nmos > rebuild.log 2>&1
echo "MAKE_EXIT=$?"
if [ -x build_nmos/obj_dir/Vtb_cpu.exe ]; then
  ./build_nmos/obj_dir/Vtb_cpu.exe > run_out.log 2>&1
  echo "RUN_EXIT=$?"
  echo '--- run_out.log (last 30 lines) ---'
  tail -30 run_out.log
  echo '--- bus_trace.txt head (12 lines, if any) ---'
  head -12 bus_trace.txt 2>/dev/null || echo '(no trace file)'
else
  echo 'NO EXE - build failed; tail of rebuild.log:'
  tail -25 rebuild.log
fi
