# Save-state format v2 — disk machine state map (DRAFT, design-only)

Status: **DRAFT** — written 2026-09-06 as a design sketch for the level-2 disk
machine's save state. It extends the level_1b v1 ABI
(`../level_1b/PLAN.md`, phases 0-3). It changes no RTL and touches no
level_1b file. The parallel session owns the v1 ABI and the in-flight
level_1b modules; this document must be reviewed jointly before any
implementation, and the level_1b hardware loop (phases 4-5) must be proven
first (see `../level_1b/PLAN.md` risk #12 and this repo's PLAN risk section).

## 1. Policy

- **This is a format revision, not a port.** v1 words/bits are not
  repurposed. Header major version bumps 1 -> 2.
- v1 layout facts that stay identical in v2 (no offset changes):
  - 64-bit register bus, 10-bit address, wired-OR reads, owners zero on
    foreign addresses.
  - Header words 0-15; register words at indices 0-15 (payload words 16-31);
    main RAM payload words 32-8223; aux RAM payload words 8224-16415;
    CRC word last.
  - CPU words 0-2 and machine words 3-9 keep their exact v1 fields.
- New content goes only into: v1-reserved register indices 11-15,
  v1-reserved bits of word 10, one new feature bit in header word 1, and
  two new RAM regions appended after aux RAM (before the CRC word).
- Rejected loads must remain atomic (v1 rule): reject before altering live
  state; no cold reset, no partial restore.
- v1 loaders must reject v2 payloads (major mismatch). A v2 loader MAY
  optionally accept v1 payloads for machines without disks (feature bit
  absent); default is reject on size mismatch.

## 2. What the level-2 disk machine owns (state inventory)

Single clock domain: the level-2 wrapper drives `disk_ii.CLK_14M` and both
`drive_ii` instances from `clk_sys` (verified in
`unit_tests/level_2/mister/Apple-II.sv`; `drive_ii` registers are all
`always @(posedge CLK_14M ...)`, `CLK_2M` is an edge-detected *input*).
Therefore the existing single-clock freeze (`machine_ce` / `STALL`) covers
the whole disk path — no CDC freeze work is needed.

Registered state found in RTL (inventoried 2026-09-06 from source; must be
re-verified against the synthesis-visible register list immediately before
implementation, per the v1 PLAN's review rule):

| Owner | Registers (widths) |
|---|---|
| `rtl/disk_ii.v` (shared controller) | `motor_phase[3:0]`, `drive_on`, `drive_real_on`, `drive2_select`, `q6`, `q7`, `D1_STEP_ACTIVE`, `D2_STEP_ACTIVE`, `spindown_delay[23:0]`, `drive_on_old`, `drive_real_on` |
| `rtl/drive_ii.v` (x2, per drive) | `phase[7:0]`, `track_byte_addr[12:0]`, `data_reg[7:0]`, `reset_data_reg`, `rel_phase[3:0]`, `byte_delay[5:0]`, `TRACK_WE`, `CLK_2M_D` |
| `rtl/floppy_track.sv` (x2, per drive) | `sd_rd`, `sd_wr`, `ready`, `busy`, `dirty`, `saving`, `old_ack`, `old_change`, `rel_lba[3:0]`, `cur_track[5:0]`, `lba[31:0]` |
| `unit_tests/level_2/mister/Apple-II.sv` (wrapper) | `disk_mount[1:0]`, `disk_change[1:0]` (latched from `hps_io.img_mounted`) |
| Track buffers (x2) | `dpram #(13,8)` inside each `floppy_track` = 8,192 bytes per drive (6,656 valid per 13-sector track) |

Derived (NOT serialized — recomputed from restored registers):
`D1/D2_ACTIVE`, `D1/D2_MOTOR_ON`, `D1/D2_IO_ACTIVE`, `write_mode` (= `q7`),
`read_disk`, `write_reg`, `data_reg` drive mux, `write_protect_bits`,
`D_OUT`, `rom_dout` (read-only `diskii.hex`, addressed combinationally).

Not serialized by design (media / external, not machine state):
- The host `.nib` image and `hps_io` image state (`img_size`, `img_mounted`).
  The machine's view of the media IS the track buffer + controller state;
  after a load the host image is left as found (documented divergence, same
  class as v1's external-input rule for the keyboard).
- `disk_ii`'s `TRACK1`/`TRACK2` outputs: **undriven vestigial ports** in the
  Verilog port (no `assign`/`reg` driver anywhere in `disk_ii.v`; track
  position actually lives in `floppy_track.cur_track`). Nothing to capture;
  flag for later cleanup, do not wire to anything.

## 3. Register word map (v2)

Words 0-9: unchanged from v1. Word 10 extended; words 11-15 (reserved in
v1) assigned below. All remaining bits of every word read zero and ignore
writes.

### Word 10 — format/control (v2)

| Bits | Contents |
|---|---|
| `[0]` | saved CPU type (v1, unchanged) |
| `[1]` | PAL mode (v1, unchanged) |
| `[3:2]` | reserved, zero |
| `[5:4]` | `disk_mount[1:0]` (wrapper latches) |
| `[7:6]` | `disk_change[1:0]` (wrapper latches) |
| `[63:8]` | reserved, zero |

Rationale: putting the four wrapper latches here keeps the 16-word register
region and all RAM byte offsets identical to v1 (no payload re-layout).
Alternative considered: a dedicated new word 16 with a 17-word register
region (shifts every RAM offset by 8 bytes). Rejected for v2: more
arithmetic to get wrong for 4 bits.

### Word 11 — `disk_ii` shared controller

| Bits | Contents |
|---|---|
| `[3:0]` | `motor_phase` |
| `[4]` | `drive_on` |
| `[5]` | `drive_real_on` |
| `[6]` | `drive2_select` |
| `[7]` | `q6` |
| `[8]` | `q7` |
| `[9]` | `D1_STEP_ACTIVE` (1-cycle pulse; restored for determinism if a freeze lands on it) |
| `[10]` | `D2_STEP_ACTIVE` (same) |
| `[11]` | `drive_on_old` |
| `[35:12]` | `spindown_delay[23:0]` (24-bit motor spin-down countdown) |
| `[63:36]` | reserved, zero |

### Words 12 and 14 — `drive_ii` #1 / #2 (identical layout)

| Bits | Contents |
|---|---|
| `[7:0]` | `phase` |
| `[20:8]` | `track_byte_addr[12:0]` |
| `[28:21]` | `data_reg` |
| `[29]` | `reset_data_reg` |
| `[33:30]` | `rel_phase[3:0]` |
| `[40:34]` | `byte_delay[5:0]` |
| `[41]` | `TRACK_WE` |
| `[42]` | `CLK_2M_D` |
| `[63:43]` | reserved, zero |

### Words 13 and 15 — `floppy_track` #1 / #2 (identical layout)

| Bits | Contents |
|---|---|
| `[0]` | `sd_rd` |
| `[1]` | `sd_wr` |
| `[2]` | `ready` |
| `[3]` | `busy` |
| `[4]` | `dirty` |
| `[5]` | `saving` |
| `[6]` | `old_ack` |
| `[7]` | `old_change` |
| `[11:8]` | `rel_lba[3:0]` |
| `[17:12]` | `cur_track[5:0]` |
| `[49:18]` | `lba[31:0]` |
| `[63:50]` | reserved, zero |

## 4. Header v2

Word 0:

- `[63:32]`: magic `0x41324C31` (`A2L1`) — unchanged (same machine family);
- `[31:24]`: major version = **2**;
- `[23:16]`: minor version = 0;
- `[15:0]`: used 64-bit word count = **18465** (with CRC) / 18464 (without).

Word 1:

- `[0]` CPU type, `[1]` PAL, `[2]` keyboard (zero, as v1), `[3]` CRC present —
  unchanged;
- `[4]`: **disk present = 1** (new feature bit; v1 payloads have no such bit —
  treat v1 as 0 by definition);
- `[15:8]`: register-map revision = **2** (words 10-15 changed);
- `[31:16]`: memory-map revision = **2** (two new track-buffer regions);
- `[63:32]`: build ABI identifier — increment (incompatible serialized-state
  change).

## 5. RAM regions and slot payload (v2)

Walk order (save): registers -> main -> aux -> tbuf1 -> tbuf2 -> CRC.
Restore order: reject header first, then main -> aux -> tbuf1 -> tbuf2,
then register words last (v1 rule "complete all RAM regions before restoring
register words"), then CRC verify, then unfreeze.

Track-buffer walk: byte `n` of a drive's 8,192-byte `dpram` packed as
`ddr_word[8*(n mod 8) +: 8]`, 1,024 64-bit words per drive, ascending
`ram_addr 0x000..0x1FF` on the drive's port B — the same walker mechanism as
main/aux, with the machine frozen so the track bus is quiescent.

| 64-bit words | Byte offset | Contents |
|---:|---:|---|
| 0 | `0x0000` | Header: magic/version/size |
| 1 | `0x0008` | Compatibility: CPU, features (bit 4 = disk), ABI |
| 2-15 | `0x0010-0x007F` | Reserved header words, zero |
| 16-31 | `0x0080-0x00FF` | Register words 0-15 (map above) |
| 32-8223 | `0x0100-0x100FF` | Main RAM, 65,536 B (v1, unchanged) |
| 8224-16415 | `0x10100-0x200FF` | Auxiliary RAM, 65,536 B (v1, unchanged) |
| 16416-17439 | `0x20100-0x230FF` | **NEW** drive 1 track buffer, 8,192 B |
| 17440-18463 | `0x23100-0x260FF` | **NEW** drive 2 track buffer, 8,192 B |
| 18464 | `0x26100` | CRC32 + reserved flags (same position rule as v1) |
| 18465+ | `0x26108` | Reserved, not written in v2 |

Used payload = 18,465 x 8 = 147,720 B ~= 144.2 KiB. (For reference, the v1
PLAN's "approximately 256 KiB" comment does not match its own v1 table —
v1 used payload is 131,328 B ~= 128.2 KiB; the table governs.)

DDR footprint per slot, under the v1 PLAN's DWORD contract (each 64-bit word
advances the DDR DWORD address by 2): 18,465 x 2 = 36,930 DWORD
(= 147,720 B) — fits a 512 KiB slot, far inside the 2 MiB slot stride.
**Caveat:** the per-slot DDR footprint depends on the address-unit question
open in `SAVESTATE_DDR_CONTRACT_CHECK.md`; if the implemented stride
(x8 DWORD per word) is kept, the footprint is 8x (1.17 MiB per slot —
still fits 2 MiB slots but changes the first/last-address test expectations).

## 6. Load validation (v2 additions to the v1 atomic-reject rule)

Reject before altering live state when any of:

- magic, major version, or used-size mismatch (v1 rule);
- CPU type mismatch (v1 rule);
- header bit `[4]` disk-present = 1 but the running machine has no disk
  (level_1b core running a v2 disk payload);
- disk-present = 0 on a disk machine (level_2 running a v1 payload) —
  unless the compatibility option above is implemented;
- register-map or memory-map revision not supported by the loader;
- CRC mismatch when bit `[3]` is set (v1 rule).

On rejection: unfreeze, report, machine continues from pre-load state.

## 7. Out of scope for v2 (future major versions)

HDD, expansion RAM (80-column/alt-character banks beyond the two 64 KiB
banks), keyboard/PS-2, mouse, SuperSerial, cassette, and any new slot
peripheral. Each gets new words/regions + major bump.

## 8. Open items before implementation

1. **Resolve the DDR address-unit/base/burst contract first** — see
   `SAVESTATE_DDR_CONTRACT_CHECK.md` and `tb_ss_ddr.sv`. The word map above
   is independent of it; only the per-slot DDR footprint and the walker's
   "advance by 2" rule depend on it.
2. Re-verify the register inventory against the Quartus Fitter register
   report of the level-2 build before freezing the bit fields (v1 PLAN
   review rule).
3. CRC32 algorithm: whatever the v1 exit (phase 0) standardizes.
4. Decide the v1-payload compatibility option (section 6, last-but-one item).
5. Undriven `TRACK1`/`TRACK2` ports in `disk_ii.v`: leave as-is for v2
   (harmless), flag for a separate cleanup with the Verilog disk_ii owner.
