# Level 1b MiSTer wrapper

This is a sibling MiSTer project for testing the Apple II level-1 machine with
save-state infrastructure.

## Current hardware scope

The wrapper currently provides:

- the level-1 Apple II machine, keyboard, and monochrome video path;
- `Apple-II_L1B` OSD identity and save/load request controls;
- one atomic coordinator for freeze, headers, registers, and RAM;
- header/version/CPU compatibility validation before load side effects;
- a direct 64-bit DDRAM transaction adapter;
- ordered restore of RAM, machine state, then selected CPU state.

The RAM client is now connected to the wrapper's main and auxiliary RAM arrays.
Quartus RAM inference and hardware persistence still need validation.

## Build

From the repository root:

```bat
unit_tests\level_1b\mister\build.bat
```

The build uses the copied level-1 MiSTer infrastructure and live RTL sources.
The RBF is written under `unit_tests/level_1b/mister/output_files/`.

The DDR slot adapter maps framework byte base `0x3E000000` to direct 64-bit
beat base `29'h07C00000`. Each state word advances `DDRAM_ADDR` by one and uses
`DDRAM_BURSTCNT=1`.

## Hardware test

1. Build and load `level1b.rbf`.
2. Boot the Apple II and open the OSD.
3. Use `Save State`, close the OSD, change the machine state, then use `Load State`.
4. Confirm CPU register/mode continuation and that the display freezes during
   the transaction.
5. Confirm both CPU state and RAM contents persist across save/load.
