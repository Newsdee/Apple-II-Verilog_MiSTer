[CmdletBinding()]
param(
    [string]$Tests = 'all',
    [switch]$CompareOnly,
    [switch]$ContinueOnFailure,
    [switch]$SummaryOnly,
    [switch]$List
)

$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $PSScriptRoot 'test_manifest.json'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $projectRoot

if (!(Test-Path $manifestPath)) {
    throw "Test manifest not found: $manifestPath"
}

$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1) {
    throw "Unsupported test manifest schema version: $($manifest.schemaVersion)"
}

$availableTests = @($manifest.tests)
foreach ($test in $availableTests) {
    $runnerPath = Join-Path $PSScriptRoot ([string]$test.runner)
    if (!(Test-Path $runnerPath)) {
        throw "Runner for '$($test.name)' not found: $runnerPath"
    }
}

if ($List) {
    $availableTests |
        Select-Object name, compareOnly, runner |
        Format-Table -AutoSize
    exit 0
}

$requestedNames = @(
    $Tests.Split(',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' }
)
if ($requestedNames.Count -eq 0 -or ($requestedNames.Count -eq 1 -and $requestedNames[0] -eq 'all')) {
    $selectedTests = $availableTests
} else {
    $knownNames = @($availableTests | ForEach-Object { [string]$_.name })
    $unknownNames = @($requestedNames | Where-Object { $_ -notin $knownNames })
    if ($unknownNames.Count -ne 0) {
        throw "Unknown test(s): $($unknownNames -join ', '). Run with -List to show valid names."
    }
    $selectedTests = @($availableTests | Where-Object { $_.name -in $requestedNames })
}

$powershell = (Get-Process -Id $PID).Path
$results = @()
$suiteStart = Get-Date
$logRoot = Join-Path $PSScriptRoot 'logs'
if ($SummaryOnly) {
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
}

foreach ($test in $selectedTests) {
    $name = [string]$test.name
    $runnerPath = Join-Path $PSScriptRoot ([string]$test.runner)

    if ($CompareOnly -and !$test.compareOnly) {
        Write-Host "=== SKIP ${name}: runner does not support -CompareOnly ===" -ForegroundColor Yellow
        $results += [pscustomobject]@{ Test = $name; Result = 'SKIP'; Seconds = 0 }
        continue
    }

    Write-Host "=== RUN $name ===" -ForegroundColor Cyan
    $testStart = Get-Date
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath)
    if ($CompareOnly) {
        $arguments += '-CompareOnly'
    }

    if ($SummaryOnly) {
        $logPath = Join-Path $logRoot "$name.log"
        $savedErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = @(& $powershell @arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $savedErrorActionPreference
        [System.IO.File]::WriteAllLines(
            $logPath,
            [string[]]@($output | ForEach-Object { $_.ToString() }),
            (New-Object System.Text.UTF8Encoding($false))
        )
        $passLines = @($output | Where-Object { $_.ToString() -match 'EQUIVALENCE PASS' })
        if ($passLines.Count -ne 0) {
            $passLines | ForEach-Object { Write-Host $_ }
        } elseif ($exitCode -ne 0) {
            $output | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
        }
        Write-Host "Log: $logPath"
    } else {
        & $powershell @arguments
        $exitCode = $LASTEXITCODE
    }
    $elapsed = [math]::Round(((Get-Date) - $testStart).TotalSeconds, 2)

    if ($exitCode -eq 0) {
        Write-Host "=== PASS $name (${elapsed}s) ===" -ForegroundColor Green
        $results += [pscustomobject]@{ Test = $name; Result = 'PASS'; Seconds = $elapsed }
    } else {
        Write-Host "=== FAIL $name (${elapsed}s, exit=$exitCode) ===" -ForegroundColor Red
        $results += [pscustomobject]@{ Test = $name; Result = 'FAIL'; Seconds = $elapsed }
        if (!$ContinueOnFailure) {
            break
        }
    }
}

Write-Host ''
Write-Host '=== MODULE TEST SUMMARY ==='
$results | Format-Table -AutoSize
$suiteSeconds = [math]::Round(((Get-Date) - $suiteStart).TotalSeconds, 2)
$failedCount = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
$passedCount = @($results | Where-Object { $_.Result -eq 'PASS' }).Count
$skippedCount = @($results | Where-Object { $_.Result -eq 'SKIP' }).Count
Write-Host "passed=$passedCount failed=$failedCount skipped=$skippedCount seconds=$suiteSeconds"

if ($failedCount -ne 0) {
    exit 1
}
exit 0