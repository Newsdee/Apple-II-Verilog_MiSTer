@echo off
rem ============================================================================
rem unit_tests/level_1/run_l1_gui.bat
rem
rem Build + launch the imgui GUI for the level-1 machine harness:
rem   run_l1_gui.bat                 nmos6502 (default)
rem   run_l1_gui.bat wdc             wdc65c02
rem   run_l1_gui.bat nmos clean      rebuild from scratch first
rem   run_l1_gui.bat nmos --headless headless smoke, no window
rem   run_l1_gui.bat nmos --scale 3  video scale in the window (default 2)
rem   run_l1_gui.bat vga ...         TEMPORARY A/B variant: video through
rem                                  the real vga_controller, shown with the
rem                                  whole-machine SimVideo/GL-texture path
rem
rem The window shows the machine's NATIVE monochrome video: on start it
rem cold-boots (a ~294 ms sim power-on hold: 2^22 master cycles, then the
rem BIOS draws the Apple logo).  Readouts: video FPS, render FPS, sim speed.
rem Space / checkbox pauses the CPU (video keeps scanning); the
rem "Cold reboot" button re-runs the full cold power-on sequence;
rem Esc quits.
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
rem A `vga` first arg selects the temporary VGA A/B variant (run_l1.sh
rem expects the argument order: gui vga).
if /i "%~1"=="vga" (
	"%MSYS2_BASH%" run_l1.sh gui vga %2 %3 %4 %5 %6 %7 %8
) else (
	"%MSYS2_BASH%" run_l1.sh %* gui
)
set "RESULT=%ERRORLEVEL%"
popd

exit /b %RESULT%
