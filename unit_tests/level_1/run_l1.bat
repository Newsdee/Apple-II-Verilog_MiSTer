@echo off
rem ============================================================================
rem unit_tests/level_1/run_l1.bat
rem
rem Build + run the level_1 testbench (machine core + native MONOCHROME
rem video + real PS/2 keyboard):
rem   run_l1.bat              build (once) + run both CPU cores
rem   run_l1.bat --trace      also write VCD traces to out/tb_l1_{nmos,wdc}.vcd
rem   run_l1.bat clean        rebuild from scratch first
rem
rem ONE build covers both CPU cores (apple2 muxes on its `cpu` input); the
rem binary runs twice: +cpu=0 (nmos6502) and +cpu=1 (wdc65c02), from the
rem REPO ROOT (the DUT's $readmemh ROM paths are CWD-relative).  Output goes
rem to unit_tests/level_1/out/.  Prints L1 PASS/FAIL plus a speed line per
rem run.  Exits non-zero on test failure.
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
rem coreutils.  Both must precede the inherited Windows PATH.
set "PATH=%UCRT64_BIN%;%MSYS_BIN%;%PATH%"
pushd "%SCRIPT_DIR%"
"%MSYS2_BASH%" run_l1.sh %*
set "RESULT=%ERRORLEVEL%"
popd

pause
exit /b %RESULT%
