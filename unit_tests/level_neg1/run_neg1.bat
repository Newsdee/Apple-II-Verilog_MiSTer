@echo off
rem ============================================================================
rem unit_tests/level_neg1/run_neg1.bat
rem
rem Build + run the level_neg1 (config -1) isolated-CPU testbench:
rem   run_neg1.bat               nmos6502
rem   run_neg1.bat wdc           wdc65c02
rem   run_neg1.bat nmos --trace  also write tb_cpu.vcd (open in GTKWave)
rem   run_neg1.bat wdc clean     rebuild from scratch first
rem
rem Prints CPU_NEG1 PASS/FAIL plus a speed line (simulated us / wall ms /
rem Verilator throughput in MHz).  Exits non-zero on test failure.
rem ============================================================================
setlocal

set "MSYS2_BASH=C:\msys64\usr\bin\bash.exe"
set "UCRT64_BIN=C:\msys64\ucrt64\bin"
set "MSYS_BIN=C:\msys64\usr\bin"
set "SCRIPT_DIR=%~dp0"

if not exist "%MSYS2_BASH%" (
	echo Error: MSYS2 Bash was not found at "%MSYS2_BASH%".
	pause
	exit /b 1
)

rem ucrt64\bin = toolchain (make/g++/verilator_bin); usr\bin = POSIX
rem coreutils (ls, rm, head, dirname).  Both must precede the inherited
rem Windows PATH -- a PATH from Explorer/cmd lacks the MSYS2 dirs entirely.
set "PATH=%UCRT64_BIN%;%MSYS_BIN%;%PATH%"
pushd "%SCRIPT_DIR%"
"%MSYS2_BASH%" run_neg1.sh %*
set "RESULT=%ERRORLEVEL%"
popd

pause
exit /b %RESULT%
