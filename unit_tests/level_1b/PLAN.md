# Level 1b - MiSTer save-state plan

## Goal and boundary

Level 1b is a new variant of the working level-1 MiSTer core. It adds native
MiSTer save states without changing level 1 or introducing the AppleWin YAML
format.

The first supported state contains:

- the complete selected CPU state, including in-flight instruction and bus
  state, for both the NMOS 6502 and WDC 65C02 implementations;
- 64 KiB main RAM and 64 KiB auxiliary RAM;
- Apple II memory-map, language-card, display, speaker, and data-path latches;
- machine/video timing phase needed for deterministic continuation;
- the wrapper reset/flash state and the selected CPU type.

Level 1b deliberately has no slots, disks, HDD, mouse, game ports, audio
output, or downloadable ROM. The keyboard decoder is initially treated as an
external input device: pending key and modifier state are not part of v1. A
save is accepted only when no PS/2 event is being consumed, and restore clears
keyboard transient state. Keyboard serialization can be added later if tests
show that this restriction is too surprising.

The implementation follows the architecture in NES_MiSTer's
`rtl/savestates.vhd`, `rtl/regs_savestates.sv`, and
`rtl/bus_savestates.vhd`:

1. A coordinator freezes the emulated machine.
2. A 10-bit address/64-bit data bus snapshots registers owned by individual
   modules.
3. A byte-wide memory walker packs eight RAM bytes into each 64-bit DDR write.
4. A fixed binary header identifies the format and revision.
5. A DDR bridge performs one acknowledged 64-bit transaction at a time.

Do not use hierarchical references to CPU registers or inferred RAM arrays.
Expose explicit synthesizable ports at each ownership boundary.

## Proposed files

Keep level 1 as the baseline and create a sibling implementation:

- `unit_tests/level_1b/` - Verilator save/load tests derived from level 1;
- `unit_tests/level_1b/mister/` - standalone MiSTer project and `Apple-II.sv`;
- `rtl/apple2.v` - expose the register bus and add machine-state words;
- `rtl/timing_generator.v` - expose timing-state words and a clock enable;
- `rtl/video_generator.v` - expose the video pipeline word and a clock enable;
- `rtl/regs_savestates.sv` - level1b register indices and format constants;
- `rtl/bus_savestates.sv` - 10-bit/64-bit register helper, equivalent in
  behavior to NES's VHDL `eReg_SavestateV`;
- `rtl/savestates_l1b.sv` - coordinator, DDR serializer, and RAM walker;
- `rtl/savestate_ui.sv` and the standard MiSTer DDR bridge - import/adapt the
  NES implementations only as required by this variant.

Before sharing changes in common RTL, add a parameter such as
`USE_SAVESTATE=0`. With it disabled, ports may be tied off and level-1 cycle
behavior must remain identical.

## Binary DDR layout

Use four fixed 2 MiB slots, matching NES's MiSTer convention. The MiSTer menu
advertises the region with:

```systemverilog
"Apple-II_L1B;SS3E000000:200000;",
```

The `SS` declaration is a binary save-state DDR area, not an uploadable file
format. The NES state manager's DWORD addresses pass through a separate
conversion layer; this wrapper drives MiSTer's direct 64-bit DDR port:

- framework DDR base: `0x3E000000`;
- slot size: `0x00200000` bytes;
- direct DDR beat base: `0x07C00000` (`0x3E000000 / 8`);
- direct slot stride: `0x00040000` 64-bit beats;
- `DDRAM_ADDR` advances by one for each 64-bit state word;
- `DDRAM_BURSTCNT` is one for each state-word transfer.

Do not copy NES's internal DWORD values onto the direct MiSTer port. Verify
the bridge's address units with a directed first/last-address test before
writing RAM.

### Slot payload

All multi-byte fields are stored as the literal 64-bit bus words produced by
RTL. No YAML, text metadata, or host-side register interpretation is involved.

| 64-bit word | Byte offset | Contents |
|---:|---:|---|
| 0 | `0x0000` | Header: magic/version/size |
| 1 | `0x0008` | Compatibility: CPU type, format feature bits, build ABI |
| 2-15 | `0x0010-0x007F` | Reserved header words, written as zero |
| 16-31 | `0x0080-0x00FF` | Register words 0-15 |
| 32-8223 | `0x0100-0x100FF` | Main RAM, 65536 bytes |
| 8224-16415 | `0x10100-0x200FF` | Auxiliary RAM, 65536 bytes |
| 16416 | `0x20100` | Optional CRC32 and reserved flags |
| 16417 onward | `0x20108` | Reserved, not written in v1 |

The used payload is approximately 256 KiB; the 2 MiB slot leaves room for
future level-2 devices without changing MiSTer's slot allocation.

Proposed header word 0:

- `[63:32]`: magic `0x41324C31` (`A2L1`);
- `[31:24]`: format major, initially `1`;
- `[23:16]`: format minor, initially `0`;
- `[15:0]`: used 64-bit word count, initially `16416` without CRC or `16417`
  with CRC.

Header word 1:

- `[0]`: CPU type, `0=NMOS 6502`, `1=WDC 65C02`;
- `[1]`: PAL mode, fixed zero in level 1b but validated on load;
- `[2]`: keyboard state included, zero in v1;
- `[3]`: CRC present;
- `[15:8]`: register-map revision;
- `[31:16]`: memory-map revision;
- `[63:32]`: build ABI identifier, not a date. Increment only for an
  incompatible serialized-state change.

Reject a load before altering live state when magic, major version, used size,
CPU type, or required feature bits do not match. A rejected load unfreezes the
machine and reports failure; it must not cold-reset or partially restore.

## 64-bit register map

The register bus is 10-bit addressed and wired-OR on reads. Every owner returns
zero for addresses it does not own. Restore writes occur only while the machine
is frozen.

### CPU words

The current NMOS and WDC cores already implement the same three-word map. Wire
only the selected CPU onto the read bus and write only the CPU named in header
word 1. Do not restore both cores.

| Index | Owner | Exact fields |
|---:|---|---|
| 0 | selected CPU | `[63:48] PC`, `[47:40] A`, `[39:32] X`, `[31:24] Y`, `[23:16] S`, `[15] N`, `[14] V`, `[13:12]=11`, `[11] D`, `[10] I`, `[9] Z`, `[8] C`, `[7:0] IR` |
| 1 | selected CPU | `[63:56] DL`, `[55:40] effective address`, `[39:34] sequencer state`, `[33] NMI pending`, `[32] prior NMI`, `[31] interrupt active`, `[30] interrupt is NMI`, `[29] WAI`, `[28] STP`, `[27] index carry`, `[26:19] index register`, `[18:16] NOP counter`, `[15:0] bus address` |
| 2 | selected CPU | `[16] IRQ sync stage 2`, `[15] IRQ sync stage 1`, `[14] reset sequence`, `[13] NMI sync`, `[12] NOP hold`, `[11] interrupt-I mask`, `[10] WE`, `[9] SYNC`, `[8] vector pull`, `[7:0] data out`; all other bits zero |

### Apple machine words

| Index | Owner | Proposed fields |
|---:|---|---|
| 3 | `apple2` switches | `[7:0] soft_switches`, `[8] RAMRD`, `[9] RAMWRT`, `[10] CXROM`, `[11] STORE80`, `[12] C3ROM`, `[13] C8ROM`, `[14] ALTZP`, `[15] ALTCHAR`, `[16] COL80`, `[17] SF_D`, `[18] speaker_sig`, `[19] HRAM_READ`, `[20] HRAM_PRE_WR`, `[21] HRAM_WR_N`, `[22] HRAM_BANK1` |
| 4 | `apple2` data path | `[7:0] CPU_DL`, `[23:8] VIDEO_DL_LATCH`, `[24] PHASE_ZERO_D`, `[25] READ_KEY`; remaining bits zero |
| 5 | timing generator A | `[6:0] H`, `[15:7] V`, `[16] CLK_7M`, `[17] VID7M`, `[18] Q3`, `[19] RAS_N`, `[20] CAS_N`, `[21] AX`, `[22] PHI0`, `[23] COLOR_REF` |
| 6 | timing generator B | `[0] SEGA`, `[1] SEGB`, `[2] SEGC`, `[3] GR1`, `[4] GR2`, `[5] HBLANK`, `[6] VBLANK`, `[7] WNDW_N`, `[8] LDPS_N`; remaining bits zero |
| 7 | video generator | `[7:0]` reserved and zero, `[15:8] video_shiftreg`; remaining bits zero. The current video ROM output is not serialized or restored. |
| 8 | wrapper reset/time | `[22:0] flash_div`, `[23] power_on_reset`, `[24] reset_sync`; remaining bits zero |
| 9 | wrapper presentation | `[1:0] video_div`, `[2] ce_pix`, `[12:3] hblank_cnt`, `[13] hbl_d`, `[20:14] vblank_lines`; remaining bits zero |
| 10 | format/control | `[0] saved CPU type`, `[1] PAL mode`; remaining bits reserved and zero |
| 11-15 | reserved | Read zero in v1; ignore writes |

Combinational decoder signals (`RAM_SELECT`, `aux`, `ioselect`, and similar)
are not serialized because they are derived from restored registered state.
The inactive CPU is not serialized because it is disconnected from the
machine bus and is reset when the CPU option changes.

The table must be reviewed against synthesis-visible registers immediately
before implementation. Any stateful register added to `apple2`,
`timing_generator`, or `video_generator` must be classified as serialized,
derived, reset-on-load, or intentionally irrelevant.

## RAM memory walk

RAM remains owned by the level1b wrapper. During a snapshot the coordinator
arbitrates the existing single-clock inferred arrays away from the machine.

Logical walk:

1. Main bank: memory type 0, addresses `0x00000-0x0FFFF`.
2. Auxiliary bank: memory type 1, addresses `0x00000-0x0FFFF`.
3. Walk ascending addresses and pack byte address `n` into
   `ddr_word[8*(n mod 8) +: 8]`.
4. Issue one 64-bit DDR operation after collecting eight bytes.
5. Advance the DDR DWORD address by two only after acknowledgement.

Save read timing must honor inferred synchronous RAM latency:

1. Present bank and address with `ss_ram_rd` asserted.
2. Wait one `clk_sys` edge for the selected array output to register.
3. Capture the byte on the following coordinator step.
4. Repeat eight times, then submit the packed word.

Load timing:

1. Read one 64-bit word from DDR and wait for acknowledgement.
2. Present each byte and address in order.
3. Pulse `ss_ram_wr` for exactly one `clk_sys` edge per byte.
4. Do not allow normal CPU/video writes while the walker owns RAM.
5. Complete both banks before restoring register words.

The RAM mux must give reset highest priority, then save-state load writes,
then normal machine writes. Save reads occur only after reset is inactive and
the machine is frozen. Preserve the normal dual-bank read/latch behavior when
`ss_active=0` so level-1 timing remains unchanged.

## Freeze and restore protocol

The save controller and DDR bridge run continuously on `clk_sys`; only the
emulated machine advances under `machine_ce`. Do not stop `clk_sys` or gate a
clock net in fabric.

### Entering freeze

1. Latch a save/load request only when no reset is active and no earlier
   request is busy.
2. Assert `freeze_request` into both CPU instances through `STALL`, and hold
   `CPU_WAIT`/RDY low as a second guard against retiring a bus cycle.
3. Wait until the selected CPU is at a stable bus boundary. The preferred
   acknowledgement is `CPU_EN==0` after a completed CPU enable pulse; expose a
   dedicated `cpu_frozen` indication rather than inferring it in the wrapper.
4. Once acknowledged, deassert `machine_ce`. All state-owning sequential
   blocks in `apple2`, `timing_generator`, `video_generator`, wrapper reset and
   presentation counters, and normal RAM access must honor this enable.
5. Wait at least two `clk_sys` cycles and verify the register bus is stable.
   Then assert `ss_frozen` to the coordinator.
6. Set `HDMI_FREEZE=1` for the duration so MiSTer holds a coherent displayed
   frame.

Using RDY alone is insufficient because it only affects CPU progress. Using
`STALL` alone is insufficient because video/timing and wrapper state continue.
Clock enables are required for the atomic phase.

### Save order

1. Freeze and settle.
2. Capture all register words into local 64-bit shadow registers in one
   frozen cycle. This prevents DDR latency from changing the observed image.
3. Write and acknowledge header words.
4. Write register words 0-15.
5. Walk main RAM, then auxiliary RAM.
6. Optionally calculate/write CRC.
7. Clear busy, release `HDMI_FREEZE`, then release `machine_ce`, RDY, and
   `STALL` together on a defined non-CPU edge.

### Load order

1. Freeze and settle.
2. Read and validate both header words. On failure, release without modifying
   machine state.
3. Read register words into shadow storage; do not apply them yet.
4. Walk DDR into main and auxiliary RAM.
5. While still frozen, apply non-CPU machine/timing/video/wrapper words first.
6. Apply the selected CPU words last with three one-cycle register-bus writes.
7. Hold frozen for two more cycles so synchronous outputs settle.
8. Pulse `load_done`, release `HDMI_FREEZE`, and resume on the saved phase.

Do not assert the normal cold/warm reset during restore: it would overwrite
restored soft switches, sequencer state, and RAM. A dedicated save-state reset
may clear only coordinator/shadow bookkeeping, never restored machine state.

### Request collisions

- Cold reset cancels a pending or active save/load and resets the coordinator.
- OSD pause and save-state freeze are ORed, but closing the OSD must not resume
  a busy save-state operation.
- CPU selection is locked while a request is busy. Loading a slot with a
  different CPU type is rejected in v1 rather than silently changing the OSD
  setting.
- A second save/load request while busy is ignored and reported as busy.

## CONF_STR and controls

Proposed level1b menu fragment, retaining the level-1 controls:

```systemverilog
parameter CONF_STR = {
    "Apple-II_L1B;SS3E000000:200000;",
    "-;",
    "O5,CPU,65C02,6502;",
    "O1,OSD Pause,Off,On;",
    "-;",
    "oC,Savestates to SDCard,On,Off;",
    "oDE,Savestate Slot,1,2,3,4;",
    "d7rA,Save state(Alt+F1-F4);",
    "d7rB,Restore state(F1-F4);",
    "R0,Cold Reset;",
    "-;"
};
```

Use NES's `savestate_ui.sv` behavior for keyboard/OSD slot selection and
one-cycle `ss_save`/`ss_load` requests. Feed the selected slot back through
`status_in` and pulse `status_set`, preserving every unrelated status bit.
Expose `info_req/info` feedback for the active slot and save/load result.

Before implementation, verify this level-1 copy of `sys/hps_io.sv` supports
all status and info wiring used by the current NES UI. The `SS` token is parsed
by MiSTer independently of `hps_io`, but UI status updates still pass through
`hps_io`.

## Phased implementation

### Phase 0 - freeze the ABI and build the harness

- Create level1b as a sibling copy/reference of level 1; do not mutate the
  level-1 wrapper or project files.
- Add package constants for the header, register indices, memory regions, and
  DDR address units.
- Add a software DDR model with randomized busy/ack latency and byte-enable
  checking.
- Add tests that reject bad magic, bad version, wrong CPU type, truncated
  state, and out-of-range DDR addresses.

Exit: no machine RTL behavior change; binary layout and DDR transaction
contract are executable assertions.

### Phase 1 - register-bus exposure

- Route `ss_addr`, `ss_wdata`, `ss_wren`, and selected `ss_rdata` through
  `apple2.v` to its existing NMOS/WDC CPU ports.
- Add machine, timing, and video register words from the map above.
- Add save-state restore branches with priority below reset and above normal
  machine updates while frozen.
- Prove unselected modules return zero and no two owners drive nonzero data for
  the same index.

Exit: directed tests perturb every mapped field, restore it, and compare all
register words bit-for-bit for both CPU selections.

### Phase 2 - atomic freeze

- Introduce `machine_ce` enables without creating a generated clock.
- Quiesce at a CPU bus boundary using `STALL` plus RDY/`CPU_WAIT`.
- Freeze timing, video, wrapper counters, and normal RAM arbitration only after
  CPU acknowledgement.
- Assert that no serialized register or RAM location changes from
  `ss_frozen` until resume.

Exit: randomized freeze requests at every CPU microstate settle without an
extra write, missed write, or changing register word.

### Phase 3 - RAM walker and local round trip

- Implement the two-bank synchronous RAM read/write port and 8-byte packer.
- Save register shadows and 128 KiB RAM into the simulated slot, deliberately
  corrupt live state, then load it back.
- Compare every RAM byte and register word.
- Resume for at least 100,000 machine clocks and compare against a control
  instance restored from the same checkpoint.

Exit: deterministic round trip passes for NMOS and WDC CPUs under randomized
DDR latency.

### Phase 4 - MiSTer DDR and UI integration

- Add the standard DDR bridge and remove the level-1 DDR tie-offs.
- Connect `DDRAM_CLK`, address, data, byte enables, read/write strobes, busy,
  and read-data-ready according to the bridge contract.
- Add `CONF_STR`, `savestate_ui`, slot status feedback, info messages, and
  `HDMI_FREEZE`.
- Keep all unrelated external interfaces tied off exactly as level 1 does.

Exit: Quartus Analysis & Synthesis binds all mixed-language/interfaces, and a
DDR bus test confirms first/last address and no access outside the advertised
slot.

### Phase 5 - FPGA validation

- Full Quartus compile of level1b only after Verilator passes.
- Check fitter RAM inference: main/aux RAM must remain block RAM rather than
  exploding into ALMs after adding the walker port/mux.
- Check setup/hold slack on RAM arbitration and DDR paths.
- On hardware, save four distinguishable screens/program states, overwrite
  each state, and restore all four under both CPU modes.
- Test save/load with OSD pause off/on, repeated hotkeys, cold-reset collision,
  and deliberately invalid/empty slots.

Exit: four binary DDR slots survive repeated save/load cycles, restore the
same visible and CPU/RAM state, and never hang the core or corrupt another
slot.

## Validation strategy

The strongest automated test is continuation equivalence, not merely a RAM
checksum:

1. Run to a randomized checkpoint and freeze.
2. Save a state image.
3. Continue the reference instance and record CPU bus transactions, selected
   register words, RAM writes, and video timing for a fixed interval.
4. Load the image into a freshly reset instance.
5. Compare the same interval cycle-for-cycle.

Also retain the existing level-1 boot, reset, keyboard, ROM, and video tests
with `USE_SAVESTATE=0`. This is the disconfirming check for accidental timing
changes in shared RTL.

Required focused checks:

- CPU three-word round trip at every sequencer state for NMOS and WDC;
- save request adjacent to RAM writes and soft-switch accesses;
- main/aux bank boundary and addresses `0x0000`, `0xFFFF`;
- exactly 16384 64-bit transactions for the 128 KiB RAM image (8192 per bank);
- DDR busy asserted before acceptance and delayed read-ready responses;
- no register-bus collisions;
- failed header leaves machine/RAM unchanged;
- CPU mode mismatch is rejected;
- no normal RAM write while walker owns the port;
- save/load while OSD pause is active;
- post-load video phase and first resumed CPU bus cycle match the reference.

## Risks and decisions to resolve

1. **Shared RTL blast radius.** `apple2.v`, timing, and video are used beyond
   level1b. Parameterize save-state behavior and prove the disabled build is
   cycle-identical.
2. **RAM inference.** A naive second read/write path can prevent Quartus from
   inferring M10K RAM. Prefer a single explicitly muxed port while frozen and
   inspect the fitter report.
3. **Freeze deadlock.** Waiting for an instruction boundary can hang in WAI or
   STP. Freeze at a completed bus-cycle boundary, not only `SYNC`, and add a
   bounded acknowledgement assertion.
4. **Partial writes.** A CPU write may already be launched when freeze is
   requested. Quiesce only after that bus cycle commits, then block subsequent
   enables.
5. **Video determinism.** Omitting timing/video pipeline state causes a visible
   phase jump and breaks cycle-exact continuation. Keep words 5-9 in v1.
6. **Asynchronous input.** PS/2 input can change while frozen. Mask event
   consumption during save/load and clear transient keyboard state on load;
   document that held-key state is not restored in v1.
7. **Reset priority.** Normal reset during load can overwrite restored state.
   Define reset cancellation and restore priority explicitly in every owner.
8. **CPU selection.** The inactive CPU has stale state. Reject mismatched slots
   and lock selection while busy rather than attempting an implicit model swap.
9. **Uninitialized legacy latches.** Several Apple II registers lack explicit
   reset values. Save/load can preserve them, but tests must avoid comparing X
   semantics in four-state simulation with Quartus power-up behavior. Add
   deterministic reset only as a separately reviewed behavioral change.
10. **DDR units and bounds.** NES uses DWORD request addresses with 64-bit data
    and increments by two. The bridge conversion must be copied and tested as
    a unit; guessing from `DDRAM_ADDR` width risks slot overlap.
11. **Format evolution.** Never repurpose serialized bits. Use reserved bits,
    bump the minor version for backward-compatible additions, and bump major
    plus ABI for incompatible maps.
12. **Scope growth.** This state is valid only for level1b. Adding disks,
    expansion RAM, keyboard serialization, or peripherals requires new memory
    regions/register words and a format revision.

## Completion criteria

Level1b is complete only when:

- the register and memory maps above are implemented and versioned;
- both CPU variants pass randomized save/load continuation equivalence;
- all 131072 RAM bytes round-trip under randomized DDR latency;
- invalid or mismatched slots are rejected atomically;
- level 1 remains cycle-identical with save-state support disabled;
- Quartus preserves block-RAM inference and meets timing;
- hardware can save and restore all four MiSTer slots repeatedly;
- the final report separates simulator proof, Quartus results, and behavior
  still verified only on physical MiSTer hardware.
