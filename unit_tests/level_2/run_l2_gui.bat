@echo off
rem ============================================================================
rem unit_tests/level_2/run_l2_gui.bat
rem
rem Build + launch the imgui GUI for the level_2 machine harness (imgui +
rem SDL2 + OpenGL3; built from the SAME tb_l2 top as the headless harness
rem via the Makefile gui target - see run_l2.sh gui for the MSYS2 build):
rem   run_l2_gui.bat                    nmos6502 + DOS 3.3 disk (the default:
rem                                     watching the DOS boot is the point)
rem   run_l2_gui.bat wdc                wdc65c02
rem   run_l2_gui.bat clean              rebuild from scratch first
rem   run_l2_gui.bat --headless [N]     headless smoke, no window: boot N
rem                                     video frames (default 5) + disk
rem                                     activity + stall check; PASS -> 0
rem   run_l2_gui.bat --headless --selfkey
rem                                     + synthetic PS/2 'A' chain check
rem   run_l2_gui.bat --headless --reboot
rem                                     + cold-reboot check (the GUI button
rem                                     path, exactly)
rem   run_l2_gui.bat --empty            no disk (ROM-monitor boot)
rem   run_l2_gui.bat --disk <path>      another .nib on drive 1
rem   run_l2_gui.bat --run-frames N     quit the window after N frames
rem   run_l2_gui.bat --scale N          video scale in the window (default 2)
rem
rem The window shows the machine's NATIVE monochrome video: on start it
rem cold-boots (a ~294 ms sim power-on hold: 2^22 master cycles).  With
rem a disk mounted the real Disk II controller reads the boot block and
rem DOS 3.3 boots.  Readouts: video FPS, sim speed (14.3 MHz master),
rem disk sectors/LBA, drive-1 track/ready/motor, DOS boot-block checksum,
rem CPU address, keyboard chain counters, reset state.
rem
rem The window controls:
rem   F9 / Pause checkbox  - stall the CPU (video keeps scanning, the drive
rem                          keeps spinning)
rem   Cold reboot button   - full cold power-on sequence again (with a disk
rem                          mounted: the DOS boot re-runs)
rem   all other keys       - Apple //e scan codes to the machine's PS/2 port
rem                          (letters/digits/Enter/Backspace/Space/Tab/Esc/
rem                          arrows/F2=soft reset; with DOS up they land at
rem                          the READY. prompt)
rem   Alt+Q / window close - quit
rem
rem Exit code: non-zero on a failed headless smoke.
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
"%MSYS2_BASH%" run_l2.sh gui %*
set "RESULT=%ERRORLEVEL%"
popd

exit /b %RESULT%
