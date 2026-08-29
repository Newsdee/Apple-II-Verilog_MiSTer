# Disk II VHDL/Verilog equivalence test

This directory contains a black-box differential test for the Disk II controller. The current MiSTer VHDL implementation is the reference model; the active Verilog implementation is the candidate.

Run from PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\module_tests\disk_ii\run_equivalence.ps1
```

To rerun only the comparison and coverage checks against existing traces:

```powershell
.\module_tests\disk_ii\run_equivalence.ps1 -CompareOnly
```

The runner builds each language separately, executes identical deterministic stimuli, and compares cycle traces. It covers the ROM address space, soft switches, drive selection, motor state, write protection, phase stepping to track zero, media readiness/busy inputs, track addresses, write data/enables, and the one-second motor spindown. The long idle interval is sparsely traced to keep output small.

All generated executables, object files, and traces are placed in `module_tests/disk_ii/build`, keeping test collateral out of the core RTL directories.
