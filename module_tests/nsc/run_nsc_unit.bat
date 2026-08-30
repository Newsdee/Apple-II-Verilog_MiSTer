@echo off
setlocal

rem NSC unit test: rtl/no_slot_clock.sv + rtl/nsc_ticker.sv
rem Build with the MSYS2 UCRT64 Verilator and run. Expect "NSC UNIT PASS".
rem Requires C:\msys64 (ucrt64 verilator + make on PATH via usr\bin).

set "VERILATOR_ROOT=C:\msys64\ucrt64\share\verilator"
set "PATH=C:\msys64\ucrt64\bin;C:\msys64\usr\bin;%PATH%"

cd /d "%~dp0"
if not exist build mkdir build

"C:\msys64\ucrt64\bin\verilator_bin.exe" --timing --binary -Wno-fatal -Wno-lint ^
  --top-module nsc_tb -o v_nsc -Mdir build\obj_dir ^
  nsc_unit_tb.sv ..\..\rtl\no_slot_clock.sv ..\..\rtl\nsc_ticker.sv
if errorlevel 1 exit /b 1

build\obj_dir\v_nsc.exe
exit /b %ERRORLEVEL%
