# run_equivalence.ps1 — R65C02 VHDL/Verilog cycle-equivalence runner.
#
# Golden  : Apple-II_MiSTer_newsdee/rtl/R65Cx2.vhd (entity R65C02, GHDL)
# Candidate: Apple-II-Verilog_MiSTer/rtl/R65Cx2.sv (module R65C02, Verilator)
#
# Both testbenches drive the same 64K image (build/r65_mem_array.vhd /
# build/r65_mem_init.hex), the same stimulus timeline (reset low for
# cycles 0..3, 8-cycle IRQ window at cycle 730, 8-cycle NMI window at
# cycle 768, 4000 total cycles) and emit the same 22-column CSV trace:
#
#   CYCLE,PC,SP,P_N,P_V,P_R,P_B,P_D,P_I,P_Z,P_C,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N,SYNC,SYNC_IRQ
#
# Comparison rules (field-level meta skip — NOT row-level, because the B
# flag is permanently 'U' in VHDL while the rest of its row is defined):
#   * A field is skipped when either side contains a metavalue char
#     (U/X/W/Z/-/?, upper or lower case). This covers SP before TXS,
#     P_V before CLV, and DO/ADDR metas during reset.
#   * Column P_B is ALWAYS skipped (B is never driven in VHDL).
#
# Gates:
#   G_ROWS      both traces have the same row count (TOTAL+1)
#   G_FIELDS    zero mismatches among compared fields
#   G_MINCOMPARED  enough fields actually compared (anti empty-pass)
#   G_COVERAGE  every required mnemonic (61 = non-NOP minus BRK/RTI) was
#               executed in the golden trace on a real opcode fetch
#               (SYNC=1 and SYNC_IRQ=0; DI column is the opcode)
#   G_ERRPARK   PC never equals $090B in either trace
#   G_PARK      PC reaches $0908 in both traces before the end
#   G_IRQ/G_NMI IRQ handler ($1020) and NMI handler ($1030) entered in both
#
# Usage:
#   .\run_equivalence.ps1               # full rebuild + run + compare
#   .\run_equivalence.ps1 -CompareOnly  # compare existing traces only

param([switch]$CompareOnly)

$ErrorActionPreference = 'Stop'

$here   = $PSScriptRoot
$repo   = Split-Path (Split-Path $here -Parent) -Parent   # Apple-II-Verilog_MiSTer
$fpga   = Join-Path (Split-Path $repo -Parent) 'Apple-II_MiSTer_newsdee'
$build  = Join-Path $here 'build'
Set-Location $repo

$ghdl      = 'C:\msys64\ucrt64\bin\ghdl.exe'
$verilator = 'C:\msys64\ucrt64\bin\verilator_bin.exe'
$vwork     = Join-Path $build 'vhdl'

# --- environment (MSYS2 UCRT64) -------------------------------------------
$env:PATH = 'C:\msys64\ucrt64\bin;' + $env:PATH
$env:VERILATOR_ROOT = 'C:/msys64/ucrt64/share/verilator'
$env:MAKE           = 'C:\msys64\ucrt64\bin\mingw32-make.exe'
$env:SHELL          = 'C:\msys64\usr\bin\sh.exe'

# Test parameters (must match both TB defaults).
$total   = 4000
$irqPulse = 730
$nmiPulse = 768
$stopNs  = [int]($total * 10) + 5000

$vTrace = Join-Path $build 'verilog_trace.csv'
$hTrace = Join-Path $build 'vhdl_trace.csv'

# --- 1. regenerate the shared memory image --------------------------------
if (-not $CompareOnly) {
    Write-Host "=== [1/4] regenerating memory image (perl generator) ==="
    & perl (Join-Path $build 'gen_mem_array.pl')
    if ($LASTEXITCODE -ne 0) { throw "gen_mem_array.pl failed ($LASTEXITCODE)" }
}

# --- 2. Verilator build + run ---------------------------------------------
if (-not $CompareOnly) {
    Write-Host "=== [2/4] Verilator: build + run ==="
    # Remove a zero-byte aggregate left by an interrupted generation.
    $allCpp = Join-Path $build 'verilog/Vr65c02_verilog_tb__ALL.cpp'
    if ((Test-Path $allCpp) -and (Get-Item $allCpp).Length -eq 0) { Remove-Item $allCpp }

    & $verilator --binary --timing -Wno-fatal --top-module r65c02_verilog_tb `
        --Mdir (Join-Path $build 'verilog') `
        (Join-Path $repo 'rtl/R65Cx2.sv') `
        (Join-Path $here 'r65c02_verilog_tb.sv')
    if ($LASTEXITCODE -ne 0) { throw "verilator build failed ($LASTEXITCODE)" }

    & (Join-Path $build 'verilog/Vr65c02_verilog_tb.exe') `
        "+TOTAL=$total" "+IRQPULSE=$irqPulse" "+NMIPULSE=$nmiPulse"
    if ($LASTEXITCODE -ne 0) { throw "verilog sim failed ($LASTEXITCODE)" }
}

# --- 3. GHDL analyze + elaborate + run -------------------------------------
if (-not $CompareOnly) {
    Write-Host "=== [3/4] GHDL: analyze + elaborate + run ==="
    # R65Cx2.vhd must be analyzed with --std=93 -C:
    #  * std=08 trips GHDL's "type of element is ambiguous" on the opcode
    #    table (string-literal & unsigned concatenation in an aggregate).
    #  * -C disables comment syntax checking (the file uses em-dashes).
    $ghdlArgs = @('--std=93','-C','-fsynopsys',"--workdir=$vwork")
    # Wipe the workdir so stale entities from a previous run don't produce
    # -Wlibrary double-definition warnings.
    if (Test-Path $vwork) { Remove-Item (Join-Path $vwork '*') -Force }
    else { New-Item -ItemType Directory -Path $vwork | Out-Null }

    & $ghdl -a @ghdlArgs `
        (Join-Path $build 'r65_mem_array.vhd') `
        (Join-Path $fpga 'rtl/R65Cx2.vhd') `
        (Join-Path $here 'r65c02_vhdl_tb.vhd')
    if ($LASTEXITCODE -ne 0) { throw "ghdl analyze failed ($LASTEXITCODE)" }

    & $ghdl -e @ghdlArgs r65c02_vhdl_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl elaborate failed ($LASTEXITCODE)" }

    # CWD must be the repo root: TRACE_FILE is relative to it.
    & $ghdl -r @ghdlArgs r65c02_vhdl_tb "--stop-time=${stopNs}ns"
    if ($LASTEXITCODE -ne 0) { throw "ghdl run failed ($LASTEXITCODE)" }
}

# --- 4. compare -------------------------------------------------------------
Write-Host "=== [4/4] comparing traces ==="

if (-not (Test-Path $vTrace)) { throw "missing $vTrace" }
if (-not (Test-Path $hTrace)) { throw "missing $hTrace" }

$vRows = @(Get-Content $vTrace)
$hRows = @(Get-Content $hTrace)

function Is-Meta([string]$s) {
    return ($s -match '[UXWZuxwz\-?]')
}

# Census: opcode byte -> mnemonic (from the generator's table decode).
$census = @{}
foreach ($line in (Get-Content (Join-Path $build 'opcode_census.txt'))) {
    if ($line -match '^([0-9A-Fa-f]{2})\s+(\S+)') {
        $census[$matches[1].ToUpper()] = $matches[2]
    }
}
$required = @{}
foreach ($mn in $census.Values) {
    if ($mn -ne 'NOP' -and $mn -ne 'BRK' -and $mn -ne 'RTI') { $required[$mn] = $true }
}

$NCOL = 22
$colNames = @('CYCLE','PC','SP','P_N','P_V','P_R','P_B','P_D','P_I','P_Z','P_C',
              'Y','X','A','ADDR','DI','DO','RW','NMI_N','IRQ_N','SYNC','SYNC_IRQ')

$rowCount = $vRows.Count - 1
$failures = @()

# G_ROWS
if ($vRows.Count -ne $hRows.Count) {
    $failures += "G_ROWS: verilog=$($vRows.Count) vhdl=$($hRows.Count)"
}
if ($vRows[0] -ne $hRows[0]) {
    $failures += "G_HEADER: headers differ"
}

$mismatchCount = 0
$comparedFields = 0
$skippedMeta = 0
$skipByCol = @{}
$firstMismatches = @()
$executedOp = @{}          # golden trace, real opcode fetches only
$vErrpark = 0; $hErrpark = 0
$vPark = $false; $hPark = $false
$vIrh = $false; $hIrh = $false
$vNmh = $false; $hNmh = $false

$n = [Math]::Min($vRows.Count, $hRows.Count)
for ($r = 1; $r -lt $n; $r++) {
    $vf = @($vRows[$r] -split ',')
    $hf = @($hRows[$r] -split ',')
    if ($vf.Count -ne $NCOL -or $hf.Count -ne $NCOL) {
        $failures += "G_SCHEMA: row $($r+1) has verilog=$($vf.Count) vhdl=$($hf.Count) fields"
        continue
    }
    for ($c = 0; $c -lt $NCOL; $c++) {
        $name = $colNames[$c]
        if ($name -eq 'P_B') {            # B flag: permanently meta in VHDL
            $skippedMeta++; $skipByCol[$name] = [int]$skipByCol[$name] + 1
            continue
        }
        $a = $vf[$c]; $b = $hf[$c]
        if ((Is-Meta $a) -or (Is-Meta $b)) {
            $skippedMeta++; $skipByCol[$name] = [int]$skipByCol[$name] + 1
            continue
        }
        $comparedFields++
        if ($a.ToUpper() -ne $b.ToUpper()) {
            $mismatchCount++
            if ($firstMismatches.Count -lt 20) {
                $firstMismatches += "row=$($r+1) cycle=$($vf[0]) col=$name verilog=$a vhdl=$b"
            }
        }
    }
    # Coverage from the golden (VHDL) trace: real opcode fetches only.
    if ($hf[20] -eq '1' -and $hf[21] -eq '0') { $executedOp[$hf[15].ToUpper()] = $true }
    # Address gates on both traces.
    if ($vf[1].ToUpper() -eq '090B') { $vErrpark++ }
    if ($hf[1].ToUpper() -eq '090B') { $hErrpark++ }
    if ($vf[1].ToUpper() -eq '0908') { $vPark = $true }
    if ($hf[1].ToUpper() -eq '0908') { $hPark = $true }
    if ($vf[1].ToUpper() -eq '1020') { $vIrh = $true }
    if ($hf[1].ToUpper() -eq '1020') { $hIrh = $true }
    if ($vf[1].ToUpper() -eq '1030') { $vNmh = $true }
    if ($hf[1].ToUpper() -eq '1030') { $hNmh = $true }
}

# G_FIELDS
if ($mismatchCount -gt 0) {
    $failures += "G_FIELDS: $mismatchCount field mismatches; first: $($firstMismatches[0])"
}
# G_MINCOMPARED — anti empty-pass (88000 total fields, ~4000 P_B + a few metas)
if ($comparedFields -lt 75000) {
    $failures += "G_MINCOMPARED: only $comparedFields fields compared (< 75000)"
}
# G_COVERAGE
$missing = @()
foreach ($mn in ($required.Keys | Sort-Object)) {
    $covered = $false
    foreach ($op in $executedOp.Keys) {
        if ($census[$op] -eq $mn) { $covered = $true; break }
    }
    if (-not $covered) { $missing += $mn }
}
if ($missing.Count -gt 0) {
    $failures += "G_COVERAGE: not executed: $($missing -join ', ')"
}
# G_ERRPARK
if ($vErrpark -gt 0 -or $hErrpark -gt 0) {
    $failures += "G_ERRPARK: entered verilog=$vErrpark vhdl=$hErrpark"
}
# G_PARK
if (-not $vPark -or -not $hPark) {
    $failures += "G_PARK: reached verilog=$($vPark.ToString().ToLower()) vhdl=$($hPark.ToString().ToLower())"
}
# G_IRQ / G_NMI
if (-not $vIrh -or -not $hIrh) {
    $failures += "G_IRQ: handler entered verilog=$($vIrh.ToString().ToLower()) vhdl=$($hIrh.ToString().ToLower())"
}
if (-not $vNmh -or -not $hNmh) {
    $failures += "G_NMI: handler entered verilog=$($vNmh.ToString().ToLower()) vhdl=$($hNmh.ToString().ToLower())"
}

$skipDetail = ($skipByCol.GetEnumerator() | Sort-Object Name |
    ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
$coverageGot = $required.Count - $missing.Count

if ($failures.Count -gt 0) {
    Write-Host "R65C02 EQUIVALENCE FAIL rows=$rowCount compared=$comparedFields skipped_meta=$skippedMeta coverage=$coverageGot/$($required.Count)"
    foreach ($f in $failures) { Write-Host "  FAIL: $f" }
    exit 1
}

Write-Host "R65C02 EQUIVALENCE PASS rows=$rowCount fields_compared=$comparedFields skipped_meta=$skippedMeta coverage=$coverageGot/$($required.Count)"
Write-Host "  skip_breakdown: $skipDetail"
exit 0
