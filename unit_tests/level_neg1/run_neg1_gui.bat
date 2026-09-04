@echo off
rem ============================================================================
rem unit_tests/level_neg1/run_neg1_gui.bat
rem
rem Build + launch the imgui GUI for the level_neg1 (config -1) CPU harness:
rem   run_neg1_gui.bat               nmos6502
rem   run_neg1_gui.bat wdc           wdc65c02
rem   run_neg1_gui.bat nmos clean    rebuild from scratch first
rem
rem The window shows a "Stall (pause core)" checkbox (same `stall` reg the
rem headless TB's save/restore path drives) plus live PC/A/X/Y/S/P, bus and
rem RAM readouts; the stall-gated ce_count counter and activity bar freeze
rem while stalled.  Space toggles stall, Esc quits.
rem
rem Headless control-path check (no window):
rem   run_neg1_gui.bat nmos --stall-test
rem ============================================================================
setlocal

set "MSYS2_BASH=C:\msys64\usr\bin\bash.exe"
set "UCRT64_BIN=C:\msys64\ucrt64\bin"
set "MSYS_BIN=C:\msys64\usr\bin"
set "SCRIPT_DIR=%~dp0"

if not exist "%MSYS2_BASH%" (
	echo Error: MSYS2 Bash was not found at "%MSYS2_BASH%".
	exit /b 1
)

rem ucrt64\bin = toolchain (make/g++/verilator_bin/SDL2.dll); usr\bin =
rem POSIX coreutils (ls, rm, head).  Both must precede the inherited
rem Windows PATH -- a PATH from Explorer/cmd lacks the MSYS2 dirs entirely.
set "PATH=%UCRT64_BIN%;%MSYS_BIN%;%PATH%"
pushd "%SCRIPT_DIR%"
"%MSYS2_BASH%" run_neg1.sh %* gui
set "RESULT=%ERRORLEVEL%"
popd

exit /b %RESULT%
