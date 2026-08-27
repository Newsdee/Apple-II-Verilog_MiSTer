@echo off
setlocal

:: Builds the SIM_FAST variant: slot peripherals (mockingboard x2, mouse x2,
:: superserial, clock card, hdd) are compiled out with tie-off stubs for
:: faster interactive simulation. Core, video, keyboard, floppy and disk_ii
:: are unchanged. Switching back to the full build: build_verilator.bat
:: (the manual script detects the mode change and cleans obj_dir itself).
::
:: Close a running Vemu.exe before rebuilding (Windows locks the exe).

set "MSYS2_BASH=C:\msys64\usr\bin\bash.exe"
set "SCRIPT_DIR=%~dp0"

if not exist "%MSYS2_BASH%" (
	echo Error: MSYS2 Bash was not found at "%MSYS2_BASH%".
	exit /b 1
)

"%MSYS2_BASH%" "%SCRIPT_DIR%build_verilator_manual.sh" fast %*

exit /b %ERRORLEVEL%
