# NSC (No-Slot Clock) unit test

Unit + integration test for the NSC port (TODO item 1):

- `rtl/no_slot_clock.sv` — BSD-2 port of jtflanagan/AppleTini's
  `no_slot_clock.sv` (unlock/read protocol, centisecond carry FSM).
- `rtl/nsc_ticker.sv` — free-running BCD time/date source on CLK_14M
  (HPS RTC reload, month lengths + leap year, delayed `time_en`).

## Run

```bat
cd /d E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\module_tests\nsc
run_nsc_unit.bat
```

Expected final line: `NSC UNIT PASS` (exit 0).

## What it covers

- **Part A — ticker rollover**: load 23:59:58 via the HPS RTC layout, run
  3 s + margin; expect 00:00:01 next day with day-of-week carry. This is
  the regression test for the old `clock_card.v` hour-wrap bug (date
  advanced at 10:00, 20:00 AND 24:00) and for missing month-length
  handling (Jan 31 must roll to Feb 01).
- **Part B — unlock protocol** (stock SMT NS.CLOCK.SYSTEM semantics):
  - no data before unlock; a read re-arms the compare state
  - a single mismatched bit disables the sequence (no partial unlock)
  - stray reads at A2=0 offsets do not record bits (`!rw` write gate)
  - full 64-bit read-out returns the loaded time LSB-first
  - read-out exhaustion disables emission; re-unlock works
  - accesses outside offsets $00-$07 are ignored (addr[3] guard)
  - write cycles at A2=1 offsets do not record bits
- **Part C — integration**: the live ticker feeds `input_time`/
  `input_time_en`; after ~1.5 s free-run, unlock + read-out must match the
  ticker's h/m/s (±1 s boundary tolerance) with valid BCD centiseconds.
  This catches the same-clock-domain race where a reload pulse on the tick
  edge samples the PRE-tick BCD (published seconds lag by one second).

## Known-good result

```text
NSC UNIT PASS
```

(12 checks: A, B1-B6b, C×3.)

The full simulator smoke test (`verilator/run_verilator.bat --smoke-test`)
also builds `apple2_top.v` with both modules and must stay green.
