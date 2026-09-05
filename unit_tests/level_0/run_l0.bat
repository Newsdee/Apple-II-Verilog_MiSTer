@echo off
rem ============================================================================
rem unit_tests/level_0/run_l0.bat
rem
rem Build + run the level_0 (config 0) CPU + real ROM + machine decode
rem testbench:
rem   run_l0.bat               nmos6502
rem   run_l0.bat wdc           wdc65c02
rem   run_l0.bat nmos --trace  also write tb_l0.vcd (open in GTKWave)
rem   run_l0.bat wdc clean     rebuild from scratch first
rem
rem Prints L0 PASS/FAIL plus a speed line (simulated ms / wall ms /
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
"%MSYS2_BASH%" run_l0.sh %*
set "RESULT=%ERRORLEVEL%"
popd

pause
exit /b %RESULT%
