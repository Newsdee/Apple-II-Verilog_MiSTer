# wdc65c02 - WDC 65C02 core (canonical)

The WDC 65C02 (W65C02S-style) core for this project: v2 - the current
intended version. Copy of `rtl/new_cpu_v2/` (cpu_65c02.sv
md5 822591a28cc5e7a4582277ba1a01e4cb, cpu_alu.sv
md5 1d76d132dd02fda46422c5beeeeffc8e) - the source of truth for the
copy; if the two differ, the campaign notes below win.

- WDC_MODE=1: WDC 65C02 behaviour (wdc/rockwell/synertek variants).
- WDC_MODE=0: same core's NMOS-6502 behaviour ("v2nmos" in the sweeps).
- Verdict: `module_tests/cpu_65c02/V2_VERDICT.md` (v2 beats v1 and the
  golden core on all MOS 6502 fronts); handover: `V2_HANDOVER.md`.
- Module name is `cpu_65c02` - like every other core in this repo - so
  only ONE core set can be registered in a single Quartus/Verilator
  build (swap the registered files; do not add both).
- Quartus build state and swap recipe:
  `module_tests/cpu_65c02/build/quartus_v2_prep.md`.

Companion core: `rtl/cpu/nmos6502/` (the NMOS 6502 core, netlist
derived, with its own README).
