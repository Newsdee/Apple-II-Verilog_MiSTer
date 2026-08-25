@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "UCRT64_BIN=C:\msys64\ucrt64\bin"
set "SIMULATOR=%SCRIPT_DIR%obj_dir\Vemu.exe"

if not exist "%UCRT64_BIN%\SDL2.dll" (
	echo Error: MSYS2 UCRT64 SDL2 was not found at "%UCRT64_BIN%".
	exit /b 1
)

if not exist "%SIMULATOR%" (
	echo Error: Vemu.exe has not been built. Run build_verilator.bat first.
	exit /b 1
)

set "PATH=%UCRT64_BIN%;%PATH%"
pushd "%SCRIPT_DIR%"
"%SIMULATOR%" %*
set "RESULT=%ERRORLEVEL%"
popd

exit /b %RESULT%