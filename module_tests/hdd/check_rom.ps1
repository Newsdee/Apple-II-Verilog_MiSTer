param([switch]$Keep)
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$v = Get-Content (Join-Path $root 'Apple-II_MiSTer_newsdee\rtl\hdd_rom.vhd') -Raw
$vhdlBytes = [regex]::Matches($v, 'X"([0-9A-Fa-f]{2})"') | ForEach-Object { $_.Groups[1].Value.ToLower() }
Write-Output ("VHDL constant bytes: " + $vhdlBytes.Count)
$hexLines = Get-Content (Join-Path $root 'Apple-II-Verilog_MiSTer\rtl\roms\hdd.hex')
$hexBytes = @()
foreach ($line in $hexLines) { foreach ($tok in ($line -split '\s+')) { if ($tok -ne '') { $hexBytes += $tok.ToLower() } } }
Write-Output ("hdd.hex bytes: " + $hexBytes.Count)
$mismatch = 0
for ($i = 0; $i -lt [Math]::Min($vhdlBytes.Count, $hexBytes.Count); $i++) {
    if ($vhdlBytes[$i] -ne $hexBytes[$i]) {
        $mismatch++
        if ($mismatch -le 5) { Write-Output ("MISMATCH at " + $i + ": vhdl=" + $vhdlBytes[$i] + " hex=" + $hexBytes[$i]) }
    }
}
if ($vhdlBytes.Count -ne $hexBytes.Count) { Write-Output 'COUNT MISMATCH' }
if ($mismatch -eq 0 -and $vhdlBytes.Count -eq $hexBytes.Count) {
    Write-Output 'ROM CONTENT IDENTICAL (VHDL constant == hdd.hex)'
} else {
    Write-Output ("Total mismatches: " + $mismatch)
}
Write-Output ('first8=' + ($vhdlBytes[0..7] -join ',') + ' last8=' + ($vhdlBytes[-8..-1] -join ','))
