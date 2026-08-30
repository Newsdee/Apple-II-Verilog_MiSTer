@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PATH=C:\msys64\ucrt64\bin;%PATH%"

cd /d "%SCRIPT_DIR%"

if not exist "obj_dir\Vvga_color_test_top.exe" (
	echo Error: obj_dir\Vvga_color_test_top.exe not found. Run build.bat first.
	exit /b 1
)

obj_dir\Vvga_color_test_top.exe %*
exit /b %ERRORLEVEL%
