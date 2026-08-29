param(
	[string]$CandidatePath = ""
)

$ErrorActionPreference = "Stop"

$testDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $testDir "..\..")
$verilator = "C:\msys64\ucrt64\bin\verilator_bin.exe"
$env:VERILATOR_ROOT = "C:\msys64\ucrt64\share\verilator"
$env:PATH = "C:\msys64\ucrt64\bin;C:\msys64\usr\bin;$env:PATH"
$buildDir = Join-Path $testDir "build"

if(-not (Test-Path $verilator)) {
	throw "Verilator was not found at $verilator"
}

New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
Push-Location $repoRoot
try {
	$utf8NoBom = New-Object System.Text.UTF8Encoding $false
	$referenceSource = [IO.File]::ReadAllText(
		(Join-Path $repoRoot "rtl\virtual_keyboard_overlay.sv"),
		[Text.Encoding]::UTF8).Replace(
		"module virtual_keyboard_overlay #(",
		"module virtual_keyboard_overlay_reference #(")
	if([string]::IsNullOrEmpty($CandidatePath)) {
		$CandidatePath = Join-Path $repoRoot "rtl\osk\virtual_keyboard_overlay.sv"
	} elseif(-not [IO.Path]::IsPathRooted($CandidatePath)) {
		$CandidatePath = Join-Path $repoRoot $CandidatePath
	}
	$candidateSource = [IO.File]::ReadAllText(
		$CandidatePath,
		[Text.Encoding]::UTF8).Replace(
		"module virtual_keyboard_overlay #(",
		"module virtual_keyboard_overlay_candidate #(")
	$referencePath = Join-Path $buildDir "virtual_keyboard_overlay_reference.sv"
	$candidatePath = Join-Path $buildDir "virtual_keyboard_overlay_candidate.sv"
	[IO.File]::WriteAllText($referencePath, $referenceSource, $utf8NoBom)
	[IO.File]::WriteAllText($candidatePath, $candidateSource, $utf8NoBom)

	& $verilator --binary --timing --top-module overlay_equivalence_tb `
		--Mdir $buildDir -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC `
		-Wno-PROCASSINIT -Wno-UNSIGNED -Wno-UNOPTFLAT `
		$referencePath $candidatePath `
		module_tests/virtual_keyboard_overlay/overlay_equivalence_tb.sv
	if($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

	& (Join-Path $buildDir "Voverlay_equivalence_tb.exe")
	if($LASTEXITCODE -ne 0) { throw "Overlay equivalence failed with exit code $LASTEXITCODE" }
} finally {
	Pop-Location
}