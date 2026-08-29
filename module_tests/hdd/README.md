# hdd equivalence test

Cycle-equivalence (GHDL golden vs Verilator candidate) for the ProDOS HDD
interface (`hdd` + firmware ROM).

- Golden:   `../../Apple-II_MiSTer_newsdee/rtl/hdd.vhd` + `hdd_rom.vhd`
- Candidate: `../../rtl/hdd.v` + `rom.v` + `roms/hdd.hex`

## Run

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Set-Location E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer
.\module_tests\hdd\run_equivalence.ps1
.\module_tests\hdd\run_equivalence.ps1 -CompareOnly   # recheck existing traces
```

Known good result:

```
HDD EQUIVALENCE PASS rows=6416 fields=102387 ignored_metavalues=269 gate_checks=63
```

The 269 ignored metavalue fields are all `RAM_DO` before the first
sector-buffer write (genuinely uninitialized RAM, identical on both sides).

## What is tested

797 deterministic transactions (8 cycles each, one table generated for both
sides by `gen_stim.ps1` → `build/stim_table.{vhd,sv}`):

- Power-on reset, then register setup and readbacks (C0F1..C0F7).
- `sector` output = block_h:block_l.
- Execute (C0F0 read) for all ProDOS commands:
  - STATUS / READ / WRITE with `hdd_mounted=0` → 0x28 (NO_DEVICE)
  - wrong unit (≠0x70) → 0x28
  - READ ok → 0x00 + one-cycle `hdd_read` pulse
  - WRITE ok → 0x00 + one-cycle `hdd_write` pulse; write-protect → 0x2B
  - FORMAT (unhandled) → D_OUT stays 0xFF
- C0F8 sector-buffer walk: 520 CPU writes (9-bit `sec_addr` wraps at 512),
  readback across the wrap, and the **deferred increment** (holding
  DEVICE_SELECT high delays the `sec_addr` increment until the falling edge).
- Dual-port sector buffer: host-port writes (bytes 200..215) read back by
  the CPU; CPU-written bytes (0..7, 504..511) read back by the host port.
- Firmware ROM reads via IO_SELECT (addresses 0x00, 0x01, 0x70, 0xFF,
  0x80). The ROM path has two registered stages
  (`rom_dout <= ROM[A]`, then `D_OUT <= rom_dout`), so the io window holds
  the address for 2 cycles and the byte is visible at P=1.
- Mid-test reset: interface registers clear, sector buffer and `sec_addr`
  survive.

## Coverage gates (runner fails without all of them)

`reset_clear`, `reg_readback` (6 regs), `sector_out`, `no_device` (4),
`read_ok` (pulse in/out), `write_ok` (pulse in/out), `protect`,
`format_others`, `status_ok` (2), `c0f8_points` (12 readback points incl.
wrap + deferred increment + host bytes), `host_ram_do` (16), `rom_read`
(6), `mid_reset` (4), `pulse_width` (hdd_read/hdd_write high exactly once
each), and a >90,000 compared-fields minimum.

## Golden-side transformations (simulation only, RTL untouched)

The runner generates `build/vhdl/hdd_golden.vhd` from the reference
`hdd.vhd` with strictly verified string replacements (exact occurrence
counts + length check). No logic changed:

1. **Case normalization** — the original cases on `unsigned` slices with
   `X"n"` choices (Quartus-legal, not strict VHDL: case choices must be
   discrete). Normalized to `case to_integer(...)` with integer literals.
2. **Process merge (GHDL 6.0.0 codegen bug workaround)** — the original has
   two processes (`cpu_interface`, `sec_storage`) both doing
   computed-index element accesses to `sector_buf`. GHDL 6.0.0 silently
   drops/stales such accesses: with two processes on one array signal the
   writes are lost entirely; within one process, any second element access
   (even a plain `buf(0)` read) makes computed-index reads return stale
   values. Minimal repros: `t3` (works: one process, computed only),
   `t9` (breaks: + one plain read), `t11` (breaks: two processes, computed
   only), `t12` (works: merged single process, computed only). The merge
   puts the `sec_storage` body at the top of the `cpu_interface` clocked
   region and deletes the second process. Both processes are on the same
   clock edge; the merge is behavior-identical for conflict-free port
   operations (the test never writes the same element from both ports in
   one cycle; the original two-process form would be a multiple-driver
   runtime error in that case).

## ROM parity

`hdd_rom.vhd` (golden) is a VHDL constant array; the candidate reads
`rtl/roms/hdd.hex`. The runner verifies all 256 bytes are identical before
simulating and fails on any difference.
