param(
    [switch]$CompareOnly
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$referenceRoot = (Resolve-Path (Join-Path $projectRoot '..\Apple-II_MiSTer_newsdee')).Path
$buildRoot = Join-Path $PSScriptRoot 'build'
$vhdlBuild = Join-Path $buildRoot 'vhdl'
$verilogBuild = Join-Path $buildRoot 'verilog'
$ghdl = 'C:\msys64\ucrt64\bin\ghdl.exe'
$verilator = 'C:\msys64\ucrt64\bin\verilator_bin.exe'

if (!(Test-Path $ghdl)) {
    throw "GHDL not found at $ghdl"
}
if (!(Test-Path $verilator)) {
    throw "Verilator not found at $verilator"
}

# Locate the Quartus simulation library (official VHDL model of altsyncram).
$simLibCandidates = @(
    'C:\intelFPGA_lite\17.0\quartus\eda\sim_lib',
    'C:\IntelFPGA\17.0\quartus\eda\sim_lib',
    'C:\altera\17.0\quartus\eda\sim_lib'
)
$simLib = $null
foreach ($candidate in $simLibCandidates) {
    if ((Test-Path (Join-Path $candidate 'altera_mf.vhd')) -and (Test-Path (Join-Path $candidate 'altera_mf_components.vhd'))) {
        $simLib = $candidate
        break
    }
}
if ($null -eq $simLib) {
    throw "Quartus sim_lib with altera_mf.vhd not found. Looked in: $($simLibCandidates -join ', ')"
}

$env:VERILATOR_ROOT = 'C:/msys64/ucrt64/share/verilator'
$env:MAKE = 'C:\msys64\ucrt64\bin\mingw32-make.exe'
$env:SHELL = 'C:\msys64\usr\bin\sh.exe'
$env:Path = "C:\msys64\usr\bin;C:\msys64\ucrt64\bin;$env:Path"

New-Item -ItemType Directory -Force -Path $vhdlBuild, $verilogBuild | Out-Null
$verilatorAggregate = Join-Path $verilogBuild 'Vdpram_verilog_tb__ALL.cpp'
if ((Test-Path $verilatorAggregate) -and (Get-Item $verilatorAggregate).Length -eq 0) {
    Remove-Item -Force $verilatorAggregate
}

$goldenDpram = Join-Path $referenceRoot 'rtl\dpram.vhd'
if (!(Test-Path $goldenDpram)) {
    throw "Golden VHDL dpram not found at $goldenDpram"
}
$vhdlTb = Join-Path $PSScriptRoot 'dpram_vhdl_tb.vhd'
$verilogTb = Join-Path $PSScriptRoot 'dpram_verilog_tb.sv'
$candidateDpram = Join-Path $projectRoot 'rtl\dpram.v'
if (!(Test-Path $candidateDpram)) {
    throw "Verilog candidate dpram not found at $candidateDpram"
}

$shimBegin = '--DPRAM_HARNESS_SHIM_BEGIN'
$shimEnd = '--DPRAM_HARNESS_SHIM_END'
$boundDpram = Join-Path $vhdlBuild 'dpram_bound.vhd'
$tbTop = Join-Path $vhdlBuild 'dpram_vhdl_tb_top.vhd'

# Quartus auto-binds the unqualified "altsyncram" component in dpram.vhd to the
# vendor entity, but GHDL only binds components to entities in the same library.
# The bound copy below inserts a strict-IEEE component declaration (marked with
# shim comments) after the architecture header so that work.altsyncram from the
# Quartus simulation model is used. No golden logic is touched: the runner
# verifies that the bound file minus the marked block equals the original file.
$shimLines = @(
    $shimBegin,
    'component altsyncram',
    '  generic (',
    '    address_reg_b : string;',
    '    clock_enable_input_a : string;',
    '    clock_enable_input_b : string;',
    '    clock_enable_output_a : string;',
    '    clock_enable_output_b : string;',
    '    indata_reg_b : string;',
    '    intended_device_family : string;',
    '    lpm_type : string;',
    '    numwords_a : integer;',
    '    numwords_b : integer;',
    '    operation_mode : string;',
    '    outdata_aclr_a : string;',
    '    outdata_aclr_b : string;',
    '    outdata_reg_a : string;',
    '    outdata_reg_b : string;',
    '    power_up_uninitialized : string;',
    '    read_during_write_mode_port_a : string;',
    '    read_during_write_mode_port_b : string;',
    '    widthad_a : integer;',
    '    widthad_b : integer;',
    '    width_a : integer;',
    '    width_b : integer;',
    '    width_byteena_a : integer;',
    '    width_byteena_b : integer;',
    '    wrcontrol_wraddress_reg_b : string',
    '  );',
    '  port (',
    '    address_a : in std_logic_vector(widthad_a - 1 downto 0);',
    '    address_b : in std_logic_vector(widthad_b - 1 downto 0);',
    '    clock0 : in std_logic;',
    '    clock1 : in std_logic;',
    '    clocken0 : in std_logic;',
    '    clocken1 : in std_logic;',
    '    data_a : in std_logic_vector(width_a - 1 downto 0);',
    '    data_b : in std_logic_vector(width_b - 1 downto 0);',
    '    wren_a : in std_logic;',
    '    wren_b : in std_logic;',
    '    q_a : out std_logic_vector(width_a - 1 downto 0);',
    '    q_b : out std_logic_vector(width_b - 1 downto 0)',
    '  );',
    'end component;',
    $shimEnd
)

function New-BoundDpram {
    $origLines = [System.IO.File]::ReadAllLines($goldenDpram)
    $out = New-Object System.Collections.Generic.List[string]
    $inserted = $false
    foreach ($line in $origLines) {
        $out.Add($line)
        if ((-not $inserted) -and ($line.Trim() -eq 'ARCHITECTURE SYN OF dpram IS')) {
            foreach ($shimLine in $shimLines) {
                $out.Add($shimLine)
            }
            $inserted = $true
        }
    }
    if (-not $inserted) {
        throw "Could not find architecture anchor 'ARCHITECTURE SYN OF dpram IS' in golden dpram.vhd"
    }
    [System.IO.File]::WriteAllLines($boundDpram, $out)

    # Verify the transform: bound file minus the marked shim block must equal
    # the original golden file line-for-line.
    $boundLines = [System.IO.File]::ReadAllLines($boundDpram)
    $start = -1
    $end = -1
    for ($idx = 0; $idx -lt $boundLines.Count; $idx++) {
        if ($boundLines[$idx].Trim() -eq $shimBegin) { $start = $idx }
        if ($boundLines[$idx].Trim() -eq $shimEnd) { $end = $idx }
    }
    if (($start -lt 0) -or ($end -lt $start)) {
        throw "Shim markers missing in generated bound file"
    }
    $stripped = @()
    if ($start -gt 0) { $stripped += $boundLines[0..($start - 1)] }
    if (($end + 1) -lt $boundLines.Count) { $stripped += $boundLines[($end + 1)..($boundLines.Count - 1)] }
    if ($stripped.Count -ne $origLines.Count) {
        throw "Bound file verification failed: line count mismatch"
    }
    for ($idx = 0; $idx -lt $origLines.Count; $idx++) {
        if ($stripped[$idx] -cne $origLines[$idx]) {
            throw "Bound file verification failed at original line $($idx + 1)"
        }
    }
}

function New-TbTop([string]$tracePath) {
    # GHDL 6.0 has no --generic-map option, and the TB opens its trace file
    # during elaboration with a path relative to the CWD ($vhdlBuild). This
    # generated wrapper passes an absolute trace path as a generic instead.
    $content = @(
        '-- Generated by run_equivalence.ps1 - do not edit.',
        'library ieee;',
        'use ieee.std_logic_1164.all;',
        '',
        'entity dpram_vhdl_tb_top is',
        'end entity;',
        '',
        'architecture top of dpram_vhdl_tb_top is',
        'begin',
        "    tb : entity work.dpram_vhdl_tb",
        "      generic map (TRACE_FILE => `"$tracePath`");",
        'end architecture;'
    )
    [System.IO.File]::WriteAllLines($tbTop, $content)
}

if (!$CompareOnly) {
    New-BoundDpram

    # GHDL resolves library files from the current working directory, so all
    # analysis/elaboration/run commands execute with CWD = $vhdlBuild.
    Push-Location $vhdlBuild
    try {
        & $ghdl -a --std=08 -fsynopsys "--work=altera_mf" (Join-Path $simLib 'altera_mf_components.vhd')
        if ($LASTEXITCODE -ne 0) { throw "GHDL analysis of altera_mf_components (lib altera_mf) failed" }
        & $ghdl -a --std=08 -fsynopsys (Join-Path $simLib 'altera_mf_components.vhd')
        if ($LASTEXITCODE -ne 0) { throw "GHDL analysis of altera_mf_components (lib work) failed" }
        & $ghdl -a --std=08 -fsynopsys (Join-Path $simLib 'altera_mf.vhd')
        if ($LASTEXITCODE -ne 0) { throw "GHDL analysis of altera_mf model (lib work) failed" }
        & $ghdl -a --std=08 $boundDpram
        if ($LASTEXITCODE -ne 0) { throw "GHDL analysis of bound dpram failed" }
        & $ghdl -a --std=08 $vhdlTb
        if ($LASTEXITCODE -ne 0) { throw "GHDL analysis of dpram_vhdl_tb failed" }

        # The TB opens its trace file during elaboration with a path relative
        # to the CWD ($vhdlBuild), so a generated wrapper passes an absolute
        # trace path as a generic (GHDL 6.0 has no --generic-map option).
        $vhdlTrace = Join-Path $buildRoot 'vhdl_trace.csv'
        New-TbTop ($vhdlTrace -replace '\\', '/')
        & $ghdl -a --std=08 $tbTop
        if ($LASTEXITCODE -ne 0) { throw "GHDL analysis of dpram_vhdl_tb_top failed" }
        & $ghdl -e --std=08 -fsynopsys dpram_vhdl_tb_top
        if ($LASTEXITCODE -ne 0) { throw "GHDL elaboration of dpram_vhdl_tb_top failed" }
        & $ghdl -r --std=08 -fsynopsys dpram_vhdl_tb_top
        if ($LASTEXITCODE -ne 0) { throw "GHDL simulation of dpram_vhdl_tb_top failed" }
    }
    finally {
        Pop-Location
    }

    Push-Location $projectRoot
    try {
        & $verilator --binary --timing -Wno-fatal --top-module dpram_verilog_tb `
            --Mdir $verilogBuild `
            $verilogTb $candidateDpram
        if ($LASTEXITCODE -ne 0) { throw "Verilator build failed" }

        $verilogExe = Join-Path $verilogBuild 'Vdpram_verilog_tb.exe'
        & $verilogExe
        if ($LASTEXITCODE -ne 0) { throw "Verilator simulation failed" }
    }
    finally {
        Pop-Location
    }
}

$vhdlTrace = Join-Path $buildRoot 'vhdl_trace.csv'
$verilogTrace = Join-Path $buildRoot 'verilog_trace.csv'

if (!(Test-Path $vhdlTrace)) {
    throw "VHDL trace not found at $vhdlTrace. Run without -CompareOnly first."
}
if (!(Test-Path $verilogTrace)) {
    throw "Verilog trace not found at $verilogTrace. Run without -CompareOnly first."
}

$vhdlRows = @(Import-Csv $vhdlTrace)
$verilogRows = @(Import-Csv $verilogTrace)

if ($vhdlRows.Count -ne $verilogRows.Count) {
    throw "Row count mismatch: VHDL=$($vhdlRows.Count) Verilog=$($verilogRows.Count)"
}

$compareColumns = @('Q_A', 'Q_B', 'WREN_A', 'WREN_B', 'ADDR_A', 'ADDR_B')
$metavaluePattern = '[UXWZ-]'
$comparedFields = 0
$ignoredMetavalues = 0

# Coverage gate counters (evaluated on the VHDL golden trace).
$initZeroCount = 0
$aReadbackOk = 0
$bReadbackOk = 0
$dualWriteCycles = 0
$conflictXCount = 0
$sweepAOk = 0
$sweepAOk2 = 0
$sweepBOk = 0
$sweepBOk2 = 0

function Get-PatternHex([int]$value) {
    return ('{0:X2}' -f ($value % 256))
}

for ($idx = 0; $idx -lt $vhdlRows.Count; $idx++) {
    $vhdlRow = $vhdlRows[$idx]
    $verilogRow = $verilogRows[$idx]

    if ([string]$vhdlRow.CYCLE -ne [string]$verilogRow.CYCLE) {
        throw "Cycle column mismatch at row $($idx + 1): VHDL=$($vhdlRow.CYCLE) Verilog=$($verilogRow.CYCLE)"
    }

    $cycle = [int]$vhdlRow.CYCLE

    foreach ($column in $compareColumns) {
        # GHDL to_hstring emits uppercase hex; Verilator %X emits lowercase.
        $vhdlValue = ([string]$vhdlRow.$column).ToUpperInvariant()
        $verilogValue = ([string]$verilogRow.$column).ToUpperInvariant()
        if ($vhdlValue -match $metavaluePattern) {
            $ignoredMetavalues++
            continue
        }
        if ($vhdlValue -cne $verilogValue) {
            throw "Mismatch at cycle $cycle, $column : VHDL=$vhdlValue Verilog=$verilogValue"
        }
        $comparedFields++
    }

    # --- Coverage gates (golden trace) -------------------------------------
    if ($cycle -lt 8) {
        if (($vhdlRow.Q_A -ceq '00') -and ($vhdlRow.Q_B -ceq '00')) { $initZeroCount++ }
    }
    elseif ($cycle -ge 24 -and $cycle -lt 40) {
        $i = $cycle - 24
        if ($vhdlRow.Q_B -ceq (Get-PatternHex (160 + $i))) { $aReadbackOk++ }
    }
    elseif ($cycle -ge 56 -and $cycle -lt 72) {
        $i = $cycle - 56
        if ($vhdlRow.Q_A -ceq (Get-PatternHex (176 + $i))) { $bReadbackOk++ }
    }
    elseif ($cycle -ge 72 -and $cycle -lt 96) {
        $i = $cycle - 72
        if (($i % 2) -eq 0) {
            if (($vhdlRow.WREN_A -ceq '1') -and ($vhdlRow.WREN_B -ceq '1')) { $dualWriteCycles++ }
        }
        else {
            if ($vhdlRow.Q_B -match $metavaluePattern) { $conflictXCount++ }
        }
    }
    elseif ($cycle -ge 8288 -and $cycle -lt 16480) {
        $i = $cycle - 8288
        if ($vhdlRow.Q_B -ceq (Get-PatternHex (7 * $i + 3))) { $sweepAOk++ }
        if ($vhdlRow.Q_A -ceq (Get-PatternHex (7 * (($i - 1 + 8192) % 8192) + 3))) { $sweepAOk2++ }
    }
    elseif ($cycle -ge 24672 -and $cycle -lt 32864) {
        $i = $cycle - 24672
        if ($vhdlRow.Q_A -ceq (Get-PatternHex (7 * $i + 3))) { $sweepBOk++ }
        if ($vhdlRow.Q_B -ceq (Get-PatternHex (7 * (($i - 1 + 8192) % 8192) + 3))) { $sweepBOk2++ }
    }
}

if ($initZeroCount -ne 8) {
    throw "Coverage gate failed: expected initial zero readback on both ports for all 8 INIT cycles, observed $initZeroCount"
}
if ($aReadbackOk -ne 16) {
    throw "Coverage gate failed: port A write -> port B readback verified for $aReadbackOk/16 words"
}
if ($bReadbackOk -ne 16) {
    throw "Coverage gate failed: port B write -> port A readback verified for $bReadbackOk/16 words"
}
if ($dualWriteCycles -ne 12) {
    throw "Coverage gate failed: simultaneous dual-port writes observed on $dualWriteCycles/12 cycles"
}
if ($conflictXCount -ne 12) {
    throw "Coverage gate failed: same-address cross-port read/write conflicts produced observable X on $conflictXCount/12 cycles"
}
if (($sweepAOk -ne 8192) -or ($sweepAOk2 -ne 8192)) {
    throw "Coverage gate failed: full port A sweep readback verified for Q_B=$sweepAOk/8192 and Q_A=$sweepAOk2/8192 words"
}
if (($sweepBOk -ne 8192) -or ($sweepBOk2 -ne 8192)) {
    throw "Coverage gate failed: full port B sweep readback verified for Q_A=$sweepBOk/8192 and Q_B=$sweepBOk2/8192 words"
}
if ($comparedFields -lt 100000) {
    throw "Coverage gate failed: only $comparedFields fields compared (minimum 100000); skipped metavalues may have hidden the comparison"
}

Write-Host "DPRAM EQUIVALENCE PASS rows=$($vhdlRows.Count) fields=$comparedFields ignored_metavalues=$ignoredMetavalues init_zero=8 a_readback=16 b_readback=16 dual_write_cycles=12 conflict_x_samples=$conflictXCount sweep_words=8192"
