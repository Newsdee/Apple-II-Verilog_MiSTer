@echo off
REM ============================================================================
REM Level 1 MiSTer integration-test core - full Quartus compile.
REM
REM Usage (from anywhere):
REM     unit_tests\level_1\mister\build.bat
REM
REM cds to the repo root, refreshes the in-project infrastructure copies
REM (newer files only), then runs the full compile flow.  Output:
REM     unit_tests\level_1\mister\output_files\level1.rbf
REM
REM The DUT (rtl/, rtl/cpu/) is referenced live from the repo - that is
REM the point of the test.  sys/, jtag.cdf, the PLL QIP package and the
REM ROM data are copied into the project so the build works from any CWD
REM (sys.tcl's project-relative refs and the DUT's CWD-relative
REM $readmemh "rtl/roms/*.hex" paths).
REM ============================================================================
cd /d "%~dp0..\..\.." || exit /b 1
if not exist unit_tests\level_1\mister\rtl\roms mkdir unit_tests\level_1\mister\rtl\roms
if not exist unit_tests\level_1\mister\rtl\pll mkdir unit_tests\level_1\mister\rtl\pll
xcopy /E /Y /D sys unit_tests\level_1\mister\sys\ >nul
copy /Y /D jtag.cdf unit_tests\level_1\mister\ >nul
copy /Y /D rtl\pll.qip unit_tests\level_1\mister\rtl\ >nul
copy /Y /D rtl\pll.v unit_tests\level_1\mister\rtl\ >nul
xcopy /E /Y /D rtl\pll unit_tests\level_1\mister\rtl\pll\ >nul
xcopy /Y /D rtl\roms unit_tests\level_1\mister\rtl\roms\ >nul
quartus_sh --flow compile unit_tests\level_1\mister\level1
