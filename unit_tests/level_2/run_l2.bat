@echo off
rem ============================================================================
rem unit_tests/level_2/run_l2.bat
rem
rem Build + run the level_2 testbench (machine core + native monochrome
rem video + real PS/2 keyboard + real Disk II slot controller + real
rem floppy_track x2) under MSYS2 (ucrt64). Thin Windows wrapper around
rem run_l2.sh (all env setup - PATH, writable TMP, VERILATOR_ROOT - happens
rem inside that shell):
rem   run_l2.bat                       build (once) + run both CPU cores
rem   run_l2.bat --trace               also write a VCD trace
rem   run_l2.bat clean                 rebuild from scratch first
rem   run_l2.bat nmos | wdc | both     which CPU run(s) (default: both)
rem   run_l2.bat --empty               drive 1 empty (no disk)
rem   run_l2.bat --disk <nib>          mount <nib> on drive 1
rem                                    (default unit_tests/level_2/DOS_3_3.nib)
rem   run_l2.bat --timeout S           sim-time timeout in seconds
rem
rem The binary runs from the REPO ROOT (the DUT's $readmemh ROM paths are
rem CWD-relative). Output goes to unit_tests/level_2/out/. Prints L2
rem PASS/FAIL plus a speed line per run. Exits non-zero on test failure.
rem
rem Any arguments are passed straight through to run_l2.sh.
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
"%MSYS2_BASH%" run_l2.sh %*
set "RESULT=%ERRORLEVEL%"
popd

pause
exit /b %RESULT%
