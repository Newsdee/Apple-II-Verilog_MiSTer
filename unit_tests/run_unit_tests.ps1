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

  level_1 is special-cased (different build contract: ONE build covers both
  CPUs, and the exe must run from the repo root): the runner delegates to
  level_1\run_l1.sh and derives per-CPU status from the captured
  "L1 PASS/FAIL cpu=..." lines.

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

  if ($level -eq 'level_1') {
    # level_1 special case: ONE build covers both CPUs (the DUT muxes on
    # its `cpu` input, selected at runtime with +cpu=0/1), and the exe must
    # run from the REPO ROOT ($readmemh ROM paths are CWD-relative).
    # Delegate to the level's own runner (it sets the MSYS2 env, cds to the
    # repo root, and writes its outputs to level_1/out/); per-CPU status
    # comes from its captured "L1 PASS/FAIL cpu=..." lines.
    if ($Cpus.Count -eq 1) { $cpuSel = $Cpus[0] } else { $cpuSel = 'both' }
    if ($KeepBuild) { $cleanArg = '' } else { $cleanArg = 'clean' }
    $runLog = 'run_out_level1.log'
    $cmd = @"
export PATH=/c/msys64/usr/bin:/c/msys64/ucrt64/bin:`$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator
sh run_l1.sh $cleanArg $cpuSel > $runLog 2>&1
exit `$?
"@
    Write-Host ("== {0} (one build, cpu={1}) ==" -f $level, $cpuSel)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Push-Location $levdir
    try {
      & $bash -c $cmd
      $rc = $LASTEXITCODE
    } finally {
      $sw.Stop()
      Pop-Location
    }
    if ($cpuSel -eq 'both') { $runCpus = @('nmos','wdc') } else { $runCpus = @($cpuSel) }
    foreach ($cpu in $runCpus) {
      $line = $null
      if (Test-Path (Join-Path $levdir $runLog)) {
        $hit = Select-String -Path (Join-Path $levdir $runLog) -Pattern ('L1 (PASS|FAIL) cpu=' + $cpu + ' ') | Select-Object -Last 1
        if ($hit) { $line = $hit.Line }
      }
      if ($null -ne $line -and $line -match 'L1 PASS')        { $status = 'PASS' }
      elseif ($null -ne $line -and $line -match 'L1 FAIL')    { $status = "RUN FAIL ($($line.Trim()))" }
      elseif ($rc -eq 2)                                      { $status = 'NO EXE' }
      else                                                    { $status = "RUN FAIL (exit $rc)" }
      [void]$results.Add([pscustomobject]@{
        Level = $level; Cpu = $cpu; Status = $status
        ExitCode = $rc; Seconds = [int]$sw.Elapsed.TotalSeconds; Tail = $line
      })
      Write-Host ("  {0,-14} {1,-5}  ({2}s)  {3}" -f $status, $cpu, [int]$sw.Elapsed.TotalSeconds, $line)
    }
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
