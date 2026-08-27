@echo off
setlocal

:: Build the SIM_FAST variant (if needed) and launch the simulator so you
:: can eyeball FPS. Extra args pass through to Vemu, e.g.:
::   run_verilator_fast.bat --floppy "C:\Images\disk1.nib"
::
:: Close a running Vemu.exe before rebuilding (Windows locks the exe).

set "SCRIPT_DIR=%~dp0"
set "UCRT64_BIN=C:\msys64\ucrt64\bin"
set "SIMULATOR=%SCRIPT_DIR%obj_dir\Vemu.exe"

call "%SCRIPT_DIR%build_verilator_fast.bat"
if errorlevel 1 (
	echo Build failed.
	exit /b 1
)

if not exist "%UCRT64_BIN%\SDL2.dll" (
	echo Error: MSYS2 UCRT64 SDL2 was not found at "%UCRT64_BIN%".
	exit /b 1
)

set "PATH=%UCRT64_BIN%;%PATH%"
pushd "%SCRIPT_DIR%"
"%SIMULATOR%" %*
set "RESULT=%ERRORLEVEL%"
popd

exit /b %RESULT%
