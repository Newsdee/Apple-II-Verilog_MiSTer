# One-shot transform: create R65C02_ent.vhd (test-side copy of reference R65Cx2.vhd)
# with the opcodeInfoTable rows resolved to explicit unsigned'("...") literals.
# Reason: reference rows concatenate string literals with unsigned constants, which
# Quartus accepts but GHDL 6.0.0 rejects ("type of element is ambiguous"). All operands
# are compile-time constants, so each resolved row is bit-identical to the original.
# Untouched lines (and their exact line endings) are copied byte-for-byte.
$ErrorActionPreference = 'Stop'
$ref = 'E:\MiSTer\Apple-II_FPGAdev\Apple-II_MiSTer_newsdee\rtl\R65Cx2.vhd'
$out = 'E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\module_tests\apple2\R65C02_ent.vhd'

$text = [System.IO.File]::ReadAllText($ref)
$lines = [regex]::Split($text, '(?<=\n)')   # each element keeps its own terminator

function Split-Eol([string]$s) {
  if ($s -match '^(.*?)(\r\n|\n)?$') { return @($Matches[1], $Matches[2]) }
}

# ---- pass 0: subtype -> width map (for types declared as subtypes) ----
$subW = @{}
foreach ($line in $lines) {
  $body = (Split-Eol $line)[0]
  if ($body.TrimStart() -like '--*') { continue }
  $ms = [regex]::Match($body, '^\s*subtype\s+(\w+)\s+is\s+unsigned\((\d+)\s+to\s+(\d+)\)\s*;')
  if ($ms.Success) { $subW[$ms.Groups[1].Value] = [int]$ms.Groups[3].Value - [int]$ms.Groups[2].Value + 1 }
}

# ---- pass 1: name -> bit-string map from constant definitions ----
$map = @{}
foreach ($line in $lines) {
  $body = (Split-Eol $line)[0]
  if ($body.TrimStart() -like '--*') { continue }
  $m = [regex]::Match($body, '^\s*constant\s+(\w+)\s*:\s*(\w+(?:\(\d+\s+to\s+\d+\))?)\s*:=\s*(.+?);\s*(--.*)?$')
  if (-not $m.Success) { continue }
  $name = $m.Groups[1].Value
  $type = $m.Groups[2].Value
  # only vector-typed constants (addrDef / aluMode* / unsigned ranges) are resolvable
  if ($type -ne 'addrDef' -and $type -notlike 'aluMode*' -and $type -notlike 'unsigned(*)') { continue }
  $val  = $m.Groups[3].Value.Trim()

  $width = 0
  if ($type -match '\((\d+)\s+to\s+(\d+)\)') { $width = [int]$Matches[2] - [int]$Matches[1] + 1 }
  elseif ($subW.ContainsKey($type)) { $width = $subW[$type] }

  if ($val -match "^\(others\s*=>\s*'([01-])'\)$") {
    $map[$name] = $Matches[1] * $width
    continue
  }
  $resolved = ''
  foreach ($part in ($val -split '&')) {
    $p = $part.Trim()
    if ($p -match '^"([01-]+)"$') { $resolved += $Matches[1] }
    elseif ($map.ContainsKey($p)) { $resolved += $map[$p] }
    else { throw "unresolvable part '$p' while resolving constant $name" }
  }
  if ($width -gt 0 -and $resolved.Length -ne $width) {
    throw "constant ${name}: resolved length $($resolved.Length) != type width $width"
  }
  $map[$name] = $resolved
}

# ---- pass 2: rewrite opcodeInfoTable rows ----
$inTable = $false
$dataRows = 0
$rewritten = 0
$otherInTable = @()
$rowRe = [regex]'^(\s*)"(\d{4})"\s*&\s*"(\d{6})"\s*&\s*(\w+)\s*&\s*(\w+)\s*&\s*(\w+)(,)?\s*(--.*)?$'

$outLines = New-Object System.Collections.Generic.List[string]
foreach ($line in $lines) {
  $parts = Split-Eol $line
  $body = $parts[0]; $eol = $parts[1]
  if (-not $inTable) {
    if ($body -match '^\s*constant\s+opcodeInfoTable\s*:\s*opcodeInfoTableDef\s*:=' ) { $inTable = $true }
    $outLines.Add($line)
    continue
  }
  $t = $body.Trim()
  if ($t -eq ');') { $inTable = $false; $outLines.Add($line); continue }
  if ($t -like '--*' -or $t -eq '') { $outLines.Add($line); continue }
  $m = $rowRe.Match($body)
  if (-not $m.Success) { $otherInTable += $body; $outLines.Add($line); continue }
  $dataRows++
  $bits = $m.Groups[2].Value + $m.Groups[3].Value + $map[$m.Groups[4].Value] + $map[$m.Groups[5].Value] + $map[$m.Groups[6].Value]
  if ($bits.Length -ne 44) { throw "row length $($bits.Length) != 44: $body" }
  $comma = if ($m.Groups[7].Success) { ',' } else { '' }
  $cmt   = $m.Groups[8].Value
  $suffix = if ($cmt) { '   ' + $cmt } else { '' }
  $newBody = $m.Groups[1].Value + "unsigned'(`"$bits`")$comma$suffix"
  $outLines.Add($newBody + $eol)
  $rewritten++
}

if ($otherInTable.Count -gt 0) {
  Write-Host "WARNING: non-matching data lines inside table:"
  $otherInTable | ForEach-Object { Write-Host "  $_" }
}
Write-Host "dataRows=$dataRows rewritten=$rewritten"

$headerLines = @(
  '-- R65C02_ent.vhd - test-side copy of Apple-II_MiSTer_newsdee/rtl/R65Cx2.vhd',
  '-- Entity name unchanged (R65C02). No behavioral change.',
  "-- Only difference: rows of constant opcodeInfoTable are written as explicit",
  '--   unsigned' + '("' + '<44 bit pattern>' + '") literals instead of &-chains mixing string',
  '-- literals and unsigned constants. Quartus accepts the mixed chains; GHDL 6.0.0',
  '-- rejects them ("type of element is ambiguous"). Every operand in every row is a',
  '-- compile-time constant, so each resolved row is bit-identical to the original.',
  ''
)
$header = ($headerLines -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($out, $header + ($outLines -join ''))
Write-Host "wrote $out"
