<#
.SYNOPSIS
  unit_tests runner: builds + runs each unit-test level for each CPU variant.

.DESCRIPTION
  Iterates level_* directories (each containing a Makefile) under unit_tests\
  and, for each (level, CPU) pair, runs one MSYS2 (ucrt64) bash that:

    1. sets PATH/TMP/TEMP/TMPDIR/VERILATOR_ROOT INSIDE the MSYS2 shell
       (parent-shell exports do not propagate; see unit_tests/PROGRESS.md 1b),
    2. runs  mingw32-make CPU=<cpu>   (two-stage Verilator build, per-level
       Makefile; outputs under build_<cpu>\),
    3. runs the resulting exe  build_<cpu>\obj_dir\*.exe  (exactly one per
       build) from the level directory, capturing stdout to run_out_<cpu>.log.

  Exit-code contract (from the bash one-liner):
      0   exe ran and the test passed (exe exits non-zero on any CHECK FAIL)
    201   build (make) failed            -> see rebuild_<cpu>.log
    202   no exe produced                -> see rebuild_<cpu>.log
    n     other: the exe's own exit code -> see run_out_<cpu>.log

  The runner prints a PASS/FAIL summary table and exits non-zero if any
  (level, CPU) pair did not pass.

.PARAMETER Levels
  Level directory names (default: every level_* directory with a Makefile).

.PARAMETER Cpus
  CPU variants to build/run (default: nmos, wdc).

.PARAMETER Msys
  MSYS2 install root (default: C:\msys64).

.PARAMETER KeepBuild
  Do not delete an existing build_<cpu> tree before rebuilding.

.EXAMPLE
  .\run_unit_tests.ps1

.EXAMPLE
  .\run_unit_tests.ps1 -Levels level_neg1 -Cpu nmos

.NOTES
  PowerShell 5.1 compatible. Per-level artifacts (rebuild_<cpu>.log,
  run_out_<cpu>.log, bus traces) stay in the level directory.
#>
param(
  [string[]]$Levels = @(),
  [string[]]$Cpus   = @('nmos', 'wdc'),
  [string]  $Msys   = 'C:\msys64',
  [switch]  $KeepBuild
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$bash = Join-Path $Msys 'usr\bin\bash.exe'
if (-not (Test-Path $bash)) {
  Write-Error "MSYS2 bash not found at $bash (override with -Msys)"
  exit 1
}

if ($Levels.Count -eq 0) {
  $Levels = @(
    Get-ChildItem (Join-Path $here 'level_*') -Directory |
      Where-Object { Test-Path (Join-Path $_.FullName 'Makefile') } |
      Select-Object -ExpandProperty Name
  )
}
if ($Levels.Count -eq 0) {
  Write-Warning "no level_* directories with a Makefile under $here"
  exit 1
}

$results = New-Object System.Collections.ArrayList

foreach ($level in $Levels) {
  $levdir = Join-Path $here $level
  if (-not (Test-Path (Join-Path $levdir 'Makefile'))) {
    Write-Warning "skipping $level (no Makefile)"
    continue
  }
  foreach ($cpu in $Cpus) {
    $buildName = "build_$cpu"
    $rebLog    = "rebuild_$cpu.log"
    $runLog    = "run_out_$cpu.log"
    $buildDir  = Join-Path $levdir $buildName

    if (-not $KeepBuild -and (Test-Path $buildDir)) {
      Remove-Item $buildDir -Recurse -Force
    }

    # One MSYS2 bash per (level, cpu). All env setup happens INSIDE the shell.
    $cmd = @"
export PATH=/c/msys64/usr/bin:/c/msys64/ucrt64/bin:`$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator
mingw32-make CPU=$cpu > $rebLog 2>&1 || { echo BUILD_FAIL; exit 201; }
exe=`$(ls $buildName/obj_dir/*.exe 2>/dev/null | head -1)
[ -n "$`exe" ] || { echo NO_EXE; exit 202; }
"$`exe" > $runLog 2>&1
exit `$?
"@

    Write-Host ("== {0} / {1} ==" -f $level, $cpu)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Push-Location $levdir
    try {
      & $bash -c $cmd
      $rc = $LASTEXITCODE
    } finally {
      $sw.Stop()
      Pop-Location
    }

    $status = 'PASS'
    if ($rc -eq 201)      { $status = 'BUILD FAIL' }
    elseif ($rc -eq 202)  { $status = 'NO EXE' }
    elseif ($rc -ne 0)    { $status = "RUN FAIL (exit $rc)" }

    $tail = ''
    if (Test-Path (Join-Path $levdir $runLog)) {
      $tail = @(Get-Content (Join-Path $levdir $runLog) |
                Select-String 'PASS|FAIL' | Select-Object -Last 3) -join ' | '
    }
    [void]$results.Add([pscustomobject]@{
      Level = $level; Cpu = $cpu; Status = $status
      ExitCode = $rc; Seconds = [int]$sw.Elapsed.TotalSeconds; Tail = $tail
    })
    Write-Host ("  {0,-14} {1,-5}  ({2}s)  {3}" -f $status, $cpu, [int]$sw.Elapsed.TotalSeconds, $tail)
  }
}

Write-Host ''
Write-Host 'UNIT TESTS SUMMARY'
Write-Host ('  {0,-16} {1,-6} {2,-18} {3,-9} {4}' -f 'LEVEL', 'CPU', 'STATUS', 'EXIT', 'SECONDS')
foreach ($r in $results) {
  Write-Host ('  {0,-16} {1,-6} {2,-18} {3,-9} {4}' -f $r.Level, $r.Cpu, $r.Status, $r.ExitCode, $r.Seconds)
}

$failed = @($results | Where-Object { $_.Status -ne 'PASS' })
Write-Host ''
if ($failed.Count -eq 0) {
  Write-Host ("RESULT: {0}/{1} PASS" -f $results.Count, $results.Count)
  exit 0
} else {
  Write-Host ("RESULT: {0}/{1} FAILED" -f $failed.Count, $results.Count)
  foreach ($f in $failed) {
    Write-Host ("  failed: {0} / {1} ({2}) - logs: {3}" -f $f.Level, $f.Cpu, $f.Status,
                (Join-Path $here $f.Level))
  }
  exit 1
}
