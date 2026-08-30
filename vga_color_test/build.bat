@echo off
setlocal

set "MSYS2_BASH=C:\msys64\usr\bin\bash.exe"
set "SCRIPT_DIR=%~dp0"

if not exist "%MSYS2_BASH%" (
	echo Error: MSYS2 Bash was not found at "%MSYS2_BASH%".
	exit /b 1
)

if "%~1"=="" (
	"%MSYS2_BASH%" "%SCRIPT_DIR%build.sh" -j2
) else (
	"%MSYS2_BASH%" "%SCRIPT_DIR%build.sh" %*
)

exit /b %ERRORLEVEL%
