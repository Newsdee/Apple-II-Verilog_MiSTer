#!/usr/bin/env bash
export PATH=/c/msys64/ucrt64/bin:/c/msys64/ucrt64/lib:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/unit_tests/level_neg1
rm -rf build_nmos
mingw32-make CPU=nmos > build_dbg.log 2>&1
echo "MAKE_EXIT=$?"
cd build_nmos/obj_dir
timeout 60 ./Vtb_cpu.exe > run_dbg.log 2>&1
echo "RUN_EXIT=$?"
echo "=== run_dbg.log (first 40 lines) ==="
head -40 run_dbg.log
