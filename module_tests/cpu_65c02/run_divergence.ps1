# run_divergence.ps1 — cpu_65c02 (new GameKing 65C02) cross-core divergence test.
#
# Runs the new core under BOTH existing harness stimuli and diffs its trace
# field-for-field against each harness's Verilog golden:
#   1. r65c02 stimulus: shared 64K image, 4000 cycles, IRQ@730 NMI@768
#      -> cpu_65c02/build/r65_trace.csv        vs r65c02/build/verilog_trace.csv
#   2. t65 phase 0: directed program, 320 cycles, IRQ@120-124 NMI@200-204
#      -> cpu_65c02/build/t65_prog_trace.csv   vs t65/build/verilog_prog.csv
#   3. t65 phase 1: apple2e ROM boot walk, 500 cycles, no interrupts
#      -> cpu_65c02/build/t65_boot_trace.csv   vs t65/build/verilog_boot.csv
#
# This is a diagnostic, not a gate: divergences are reported in detail
# (first divergence point + context, per-column census, cascade analysis,
# final state, address gates) instead of failing the run.
#
# Exit codes: 0 = identical everywhere, 2 = divergences found, 1 = error.
#
# Usage (from anywhere):
#   powershell -NoProfile -ExecutionPolicy Bypass -File module_tests/cpu_65c02/run_divergence.ps1
#   ... -CompareOnly   # skip rebuilds, compare existing traces only

param([switch]$CompareOnly)

$ErrorActionPreference = 'Stop'

$here    = $PSScriptRoot
$repo    = Split-Path (Split-Path $here -Parent) -Parent   # Apple-II-Verilog_MiSTer
$build   = Join-Path $here 'build'
$r65dir  = Join-Path $repo 'module_tests/r65c02'
$t65dir  = Join-Path $repo 'module_tests/t65'
Set-Location $repo

$verilator = 'C:\msys64\ucrt64\bin\verilator_bin.exe'

# --- environment (MSYS2 UCRT64) -------------------------------------------
$env:PATH = 'C:\msys64\ucrt64\bin;' + $env:PATH
$env:VERILATOR_ROOT = 'C:/msys64/ucrt64/share/verilator'
$env:MAKE           = 'C:\msys64\ucrt64\bin\mingw32-make.exe'
$env:SHELL          = 'C:\msys64\usr\bin\sh.exe'

if (-not (Test-Path $build)) { New-Item -ItemType Directory -Path $build | Out-Null }

$total    = 4000
$irqPulse = 730
$nmiPulse = 768

function Test-VerilatorBuild {
    param([string]$Top, [string]$Mdir, [string[]]$Sources)
    $allCpp = Join-Path $Mdir ("V" + $Top + "__ALL.cpp")
    if ((Test-Path $allCpp) -and (Get-Item $allCpp).Length -eq 0) { Remove-Item $allCpp }
    & $verilator --binary --timing -Wno-fatal --top-module $Top --Mdir $Mdir @Sources
    if ($LASTEXITCODE -ne 0) { throw "verilator build failed for $Top ($LASTEXITCODE)" }
}

# ===========================================================================
# 1. r65c02 stimulus: golden (R65C02) + new core
# ===========================================================================
if (-not $CompareOnly) {
    Write-Host "=== [1/6] regenerating r65c02 memory image ==="
    & perl (Join-Path $r65dir 'build/gen_mem_array.pl')
    if ($LASTEXITCODE -ne 0) { throw "gen_mem_array.pl failed ($LASTEXITCODE)" }

    Write-Host "=== [2/6] R65C02 golden: build + run (4000 cycles) ==="
    Test-VerilatorBuild -Top 'r65c02_verilog_tb' -Mdir (Join-Path $r65dir 'build/verilog') `
        -Sources @((Join-Path $repo 'rtl/R65Cx2.sv'), (Join-Path $r65dir 'r65c02_verilog_tb.sv'))
    & (Join-Path $r65dir "build/verilog/Vr65c02_verilog_tb.exe") `
        "+TOTAL=$total" "+IRQPULSE=$irqPulse" "+NMIPULSE=$nmiPulse"
    if ($LASTEXITCODE -ne 0) { throw "R65C02 golden sim failed ($LASTEXITCODE)" }

    Write-Host "=== [3/6] cpu_65c02 under r65c02 stimulus: build + run ==="
    Test-VerilatorBuild -Top 'cpu65_r65_tb' -Mdir (Join-Path $build 'r65_verilog') `
        -Sources @((Join-Path $repo 'rtl/new_cpu/cpu_65c02.sv'),
                   (Join-Path $repo 'rtl/new_cpu/cpu_alu.sv'),
                   (Join-Path $here 'cpu65_r65_tb.sv'))
    & (Join-Path $build "r65_verilog/Vcpu65_r65_tb.exe") `
        "+TOTAL=$total" "+IRQPULSE=$irqPulse" "+NMIPULSE=$nmiPulse"
    if ($LASTEXITCODE -ne 0) { throw "cpu_65c02 r65 sim failed ($LASTEXITCODE)" }
}

# ===========================================================================
# 2. t65 stimulus: golden (T65) + new core, both phases
# ===========================================================================
if (-not $CompareOnly) {
    Write-Host "=== [4/6] regenerating t65 RAM init ==="
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $t65dir 'gen_rom_array.ps1')
    if ($LASTEXITCODE -ne 0) { throw "gen_rom_array.ps1 failed ($LASTEXITCODE)" }

    Write-Host "=== [5/6] T65 golden: build + run (phases 0+1) ==="
    Test-VerilatorBuild -Top 't65_verilog_tb' -Mdir (Join-Path $t65dir 'build/verilog') `
        -Sources @((Join-Path $t65dir 't65_verilog_tb.sv'),
                   (Join-Path $repo 'rtl/t65/t65_pack.v'),
                   (Join-Path $repo 'rtl/t65/t65_mcode.v'),
                   (Join-Path $repo 'rtl/t65/t65_alu.v'),
                   (Join-Path $repo 'rtl/t65/t65.v'))
    & (Join-Path $t65dir 'build/verilog/Vt65_verilog_tb.exe') +PHASE=0
    if ($LASTEXITCODE -ne 0) { throw "T65 golden sim phase 0 failed ($LASTEXITCODE)" }
    & (Join-Path $t65dir 'build/verilog/Vt65_verilog_tb.exe') +PHASE=1
    if ($LASTEXITCODE -ne 0) { throw "T65 golden sim phase 1 failed ($LASTEXITCODE)" }

    Write-Host "=== [6/6] cpu_65c02 under t65 stimulus: build + run (phases 0+1) ==="
    Test-VerilatorBuild -Top 'cpu65_t65_tb' -Mdir (Join-Path $build 't65_verilog') `
        -Sources @((Join-Path $repo 'rtl/new_cpu/cpu_65c02.sv'),
                   (Join-Path $repo 'rtl/new_cpu/cpu_alu.sv'),
                   (Join-Path $here 'cpu65_t65_tb.sv'))
    & (Join-Path $build "t65_verilog/Vcpu65_t65_tb.exe") +PHASE=0
    if ($LASTEXITCODE -ne 0) { throw "cpu_65c02 t65 sim phase 0 failed ($LASTEXITCODE)" }
    & (Join-Path $build "t65_verilog/Vcpu65_t65_tb.exe") +PHASE=1
    if ($LASTEXITCODE -ne 0) { throw "cpu_65c02 t65 sim phase 1 failed ($LASTEXITCODE)" }
}

# ===========================================================================
# Compare
# ===========================================================================
Write-Host ""
Write-Host "================ DIVERGENCE REPORT ================"

function Is-Meta([string]$s) { return ($s -match '[UXWZuxwz\-?]') }

function Compare-Traces {
    param(
        [string]$Name,
        [string]$GoldenCsv,
        [string]$NewCsv,
        [string[]]$ColNames,
        [int]$PcCol,              # column index of PC (for address gates)
        [hashtable]$Gates         # name -> address hex; checked on both traces
    )

    $anyDivergence = $false
    if (-not (Test-Path $GoldenCsv)) { throw "missing golden trace: $GoldenCsv" }
    if (-not (Test-Path $NewCsv))    { throw "missing new-core trace: $NewCsv" }

    $gRows = @(Get-Content $GoldenCsv)
    $nRows = @(Get-Content $NewCsv)
    $NCOL  = $ColNames.Count

    Write-Host ""
    Write-Host "--- $Name ---"
    Write-Host "golden: $GoldenCsv"
    Write-Host "new   : $NewCsv"

    if ($gRows.Count -ne $nRows.Count) {
        Write-Host "ROW COUNT DIFFERS: golden=$($gRows.Count) new=$($nRows.Count)"
        $anyDivergence = $true
    }
    if ($gRows[0] -ne $nRows[0]) {
        Write-Host "HEADER DIFFERS"
        $anyDivergence = $true
    }

    $compared = 0; $mismatches = 0; $skippedMeta = 0
    $mismatchByCol = @{}
    $firstMismatches = @()
    $firstMismatchRow = -1
    $gateHits = @{}   # gate name -> @{g=$false;n=$false}

    foreach ($kv in $Gates.Keys) { $gateHits[$kv] = @{ g = $false; n = $false } }

    $n = [Math]::Min($gRows.Count, $nRows.Count)
    for ($r = 1; $r -lt $n; $r++) {
        $gf = @($gRows[$r] -split ',')
        $nf = @($nRows[$r] -split ',')
        if ($gf.Count -ne $NCOL -or $nf.Count -ne $NCOL) {
            Write-Host "SCHEMA DIFF at data row $($r): golden=$($gf.Count) new=$($nf.Count)"
            $anyDivergence = $true
            continue
        }
        for ($c = 0; $c -lt $NCOL; $c++) {
            $name = $ColNames[$c]
            if ($name -eq 'P_B') { $skippedMeta++; continue }   # convention: always skip
            $a = $gf[$c]; $b = $nf[$c]
            if ((Is-Meta $a) -or (Is-Meta $b)) { $skippedMeta++; continue }
            $compared++
            if ($a.ToUpper() -ne $b.ToUpper()) {
                $mismatches++
                $anyDivergence = $true
                $mismatchByCol[$name] = [int]$mismatchByCol[$name] + 1
                if ($firstMismatchRow -lt 0) { $firstMismatchRow = $r }
                if ($firstMismatches.Count -lt 12) {
                    $firstMismatches += "cycle=$($gf[0]) col=$name golden=$a new=$b"
                }
            }
        }
        foreach ($kv in $Gates.Keys) {
            if ($gf[$PcCol].ToUpper() -eq $Gates[$kv]) { $gateHits[$kv].g = $true }
            if ($nf[$PcCol].ToUpper() -eq $Gates[$kv]) { $gateHits[$kv].n = $true }
        }
    }

    Write-Host "rows=$($n - 1) fields_compared=$compared mismatches=$mismatches skipped_meta=$skippedMeta"

    if ($mismatches -gt 0) {
        Write-Host "FIRST DIVERGENCES:"
        foreach ($m in $firstMismatches) { Write-Host "  $m" }
        $colCensus = ($mismatchByCol.GetEnumerator() | Sort-Object Value -Descending |
            ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
        Write-Host "per-column: $colCensus"

        # Cascade analysis: after the first diverging row, how many rows are
        # fully clean vs still dirty? Distinguishes one-off events from a
        # permanent desync.
        $cleanAfter = 0; $dirtyAfter = 0
        for ($r = $firstMismatchRow + 1; $r -lt $n; $r++) {
            $rowDirty = $false
            $gf = @($gRows[$r] -split ',')
            $nf = @($nRows[$r] -split ',')
            for ($c = 0; $c -lt $NCOL; $c++) {
                if ($ColNames[$c] -eq 'P_B') { continue }
                if ((Is-Meta $gf[$c]) -or (Is-Meta $nf[$c])) { continue }
                if ($gf[$c].ToUpper() -ne $nf[$c].ToUpper()) { $rowDirty = $true; break }
            }
            if ($rowDirty) { $dirtyAfter++ } else { $cleanAfter++ }
        }
        Write-Host "after first divergence (cycle $($gRows[$firstMismatchRow][0])): clean_rows=$cleanAfter dirty_rows=$dirtyAfter"

        # Context around the first divergence: raw rows from both traces.
        $lo = [Math]::Max(1, $firstMismatchRow - 2)
        $hi = [Math]::Min($n - 1, $firstMismatchRow + 3)
        Write-Host "context (golden | new):"
        for ($r = $lo; $r -le $hi; $r++) {
            $mark = '   '
            if ($r -eq $firstMismatchRow) { $mark = ' >>>' }
            Write-Host "$mark G: $($gRows[$r])"
            Write-Host "    N: $($nRows[$r])"
        }
    } else {
        Write-Host "IDENTICAL (all compared fields match)"
    }

    # Final architectural state.
    $gl = @($gRows[$n - 1] -split ',')
    $nl = @($nRows[$n - 1] -split ',')
    $stateCols = @('PC','SP','P_N','P_V','P_R','P_B','P_D','P_I','P_Z','P_C','Y','X','A')
    if ($NCOL -eq 13) { $stateCols = @('PC','SP','P','Y','X','A') }
    $gState = @(); $nState = @()
    foreach ($sc in $stateCols) {
        $ci = [array]::IndexOf($ColNames, $sc)
        if ($ci -ge 0) { $gState += "$sc=$($gl[$ci])"; $nState += "$sc=$($nl[$ci])" }
    }
    Write-Host "final state golden: $($gState -join ' ')"
    Write-Host "final state new   : $($nState -join ' ')"

    if ($Gates.Count -gt 0) {
        foreach ($kv in ($gateHits.Keys | Sort-Object)) {
            $h = $gateHits[$kv]
            Write-Host ("gate {0} (PC={1}): golden={2} new={3}" -f $kv, $Gates[$kv], $h.g, $h.n)
        }
    }

    return $anyDivergence
}

$r65Cols = @('CYCLE','PC','SP','P_N','P_V','P_R','P_B','P_D','P_I','P_Z','P_C',
             'Y','X','A','ADDR','DI','DO','RW','NMI_N','IRQ_N','SYNC','SYNC_IRQ')
$t65Cols = @('CYCLE','PC','SP','P','Y','X','A','ADDR','DI','DO','RW','NMI_N','IRQ_N')

$r65Gates = @{ 'park' = '0908'; 'errpark' = '090B'; 'irq_handler' = '1020'; 'nmi_handler' = '1030' }

$div1 = Compare-Traces -Name 'r65c02 stimulus (4000 cycles, IRQ@730 NMI@768): cpu_65c02 vs R65C02' `
    -GoldenCsv (Join-Path $r65dir 'build/verilog_trace.csv') `
    -NewCsv (Join-Path $build 'r65_trace.csv') `
    -ColNames $r65Cols -PcCol 1 -Gates $r65Gates

$div2 = Compare-Traces -Name 't65 phase 0 (directed program, 320 cycles): cpu_65c02 vs T65' `
    -GoldenCsv (Join-Path $t65dir 'build/verilog_prog.csv') `
    -NewCsv (Join-Path $build 't65_prog_trace.csv') `
    -ColNames $t65Cols -PcCol 1 -Gates @{}

$div3 = Compare-Traces -Name 't65 phase 1 (apple2e boot walk, 500 cycles): cpu_65c02 vs T65' `
    -GoldenCsv (Join-Path $t65dir 'build/verilog_boot.csv') `
    -NewCsv (Join-Path $build 't65_boot_trace.csv') `
    -ColNames $t65Cols -PcCol 1 -Gates @{}

Write-Host ""
if ($div1 -or $div2 -or $div3) {
    Write-Host "RESULT: DIVERGENCES FOUND (see report above)"
    exit 2
} else {
    Write-Host "RESULT: cpu_65c02 matches both goldens on all compared fields"
    exit 0
}
