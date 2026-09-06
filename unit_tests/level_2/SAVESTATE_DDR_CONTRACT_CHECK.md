# Save-state DDR contract cross-check (DRAFT, design-only)

Status: **DRAFT** — written 2026-09-06. Audits `../level_1b/savestate_ddr_l1b.sv`
and `../level_1b/mister/Apple-II.sv` against the DDR contract that the
level_1b PLAN freezes. No RTL touched. Companion test: `tb_ss_ddr.sv`
(same directory).

## 1. Sources of the contract

1. **Frozen by the level_1b PLAN** (`../level_1b/PLAN.md`, "Binary DDR
   layout" section — the only source-cited unit specification available):
   - framework DDR base: `0x3E000000` (bytes, HPS DDR window);
   - slot size: `0x00200000` bytes (2 MiB); four fixed slots;
   - internal statemanager base: `0x03800000` **DWORD** (32-bit word) addresses;
   - internal slot stride: `0x00080000` DWORD addresses (= 2 MiB per slot);
   - "the save engine's address is a 32-bit-word address; a 64-bit transfer
     advances that address by two";
   - "Do not directly drive `DDRAM_ADDR` from byte offsets. Verify the
     bridge's address units with a directed first/last-address test before
     writing RAM."
   - risk #10 (same file): "NES uses a DWORD request address, 64-bit data,
     and increments by 2. Guessing the units of `DDRAM_ADDR` can risk slot
     overlap."
2. **Locally verifiable (FPGA side, this project's `sys/` copy)**:
   `sys_top.v` binds the core's DDRAM ports to 29-bit `DDRAM_ADDR`, 64-bit
   `DDRAM_DIN`/`DDRAM_DOUT`, 8-bit `DDRAM_BURSTCNT`/`DDRAM_BE`, and routes
   them through `sysmem.sv` as `f2h_sdram1_*` (29-bit address). Standard
   MiSTer DDRAM widths. **The HPS-side semantics (byte mapping of a DDRAM
   address, `SS<base>:<size>` units, burst handling) are NOT in the local
   reference trees** (`/e/MiSTer/Main_MiSTer` and `Main_MiSTer_ND` are
   pre-save-state HPS; `menu.cpp` there does not parse `SS`). Those items
   are flagged below as HPS-side verification.
3. **The module under audit** (`savestate_ddr_l1b.sv`, 94 lines, read fully):
   - `address_latched <= BASE_ADDR + {slot_addr, 3'b000}` (stride x8 DWORD per
     8-byte word);
   - `ddram_burstcnt = 8'd1` (constant); `ddram_be = 8'hFF`;
   - single clock (`ddram_clk = clk`); rd gated by `!ddram_busy`, data via
     `ddram_dout_ready`; write completes on `!ddram_busy`.
   The wrapper instantiates it with `BASE_ADDR = 29'h1F00000`.

## 2. Contract table (PLAN vs implementation)

| Item | PLAN contract | Implementation | Verdict |
|---|---|---|---|
| Address unit | 32-bit DWORD | `{slot_addr,3'b000}` — 8 DWORD per 64-bit word | **Mismatch** (contract says advance by 2) |
| Burst per 64-bit xfer | 2 DWORD (burstcnt = 2) | `8'd1` | **Mismatch** vs the NES convention the PLAN cites; if the HPS transfers only `burstcnt` DWORD, the upper 4 bytes of every 64-bit word are silently dropped |
| Base | `0x03800000` DWORD (= `0xF000000` bytes) | `29'h1F00000` (= `0x7C00000` bytes if DWORD units; 32 MiB if byte units) | **Matches neither interpretation** |
| Slot stride / selection | `0x00080000` DWORD; four slots | no slot selection at all — single stream | **Missing** (Phase 5 requirement) |
| SS window declaration | `SS3E000000:200000` | present in `CONF_STR` | declared; **units of base/size unverifiable locally** |
| Byte enables | full word | `8'hFF` | OK |
| Handshake | one acknowledged transaction at a time | implemented in-module | no TB coverage yet |
| Clocking | DDRAM synchronous to core clock in this sys | `ddram_clk = clk` | OK |

The implementation also carries the session's own flag in
`../level_1b/mister/README.md`: "The DDR slot adapter currently uses a
configurable internal base of `29'h1F00000`. Verify the platform's DDR
address unit and adjust the base before relying on slot placement across
cores." This audit is the directed first/last-address test the PLAN's risk
#10 and Phase 4 exit demand; it confirms the base/stride/burst items are
still open.

Note: the v1 PLAN's DDR section is internally inconsistent in one place —
"four fixed 2 MiB slots" (8 MiB total) inside a `SS...:200000` region reads
as 2 MiB if the size unit is bytes. If the `SS` size unit is DWORD, the
region is 8 MiB and the table is consistent. Either way this is an
HPS-side item (see section 3), and it does not affect the per-word map in
`SAVESTATE_V2_DISK_MAP.md`.

## 3. HPS-side items that need external verification

1. Units of `SS<base>:<size>` in `CONF_STR` (bytes vs words).
2. Whether the current HPS DDRAM controller moves `burstcnt` DWORDs per
   transaction (NES convention: a 64-bit transfer uses burst 2).
3. The actual HPS DDR window base for the current sys (the PLAN's
   `0x3E000000` framework base).
4. Whether an address outside the declared `SS` region is rejected, aliased,
   or silently corrupts another core's data (slot-overlap risk #10).

Ways to resolve: (a) run the hardware smoke test once with a corrected
bridge and observe save/load persistence; (b) consult the current MiSTer
HPS source / core developer docs (not available in the local reference
trees); (c) check a known-good DDRAM core (e.g. NES) if one is ever
checked out locally.

## 4. `tb_ss_ddr.sv` — directed first/last-address test

Location: `unit_tests/level_2/tb_ss_ddr.sv` (new file; builds
`../level_1b/savestate_ddr_l1b.sv` unmodified).

What it does:

- Models the HPS DDRAM side **per the PLAN contract** (memory indexed in
  DWORD units; a transaction moves `burstcnt` DWORD starting at the
  presented address; window = `[0x03800000, 0x03800000 + 4 x 0x00080000)`
  DWORD; busy/ready latency modeled so the DUT's handshake is exercised).
- Drives the bridge the way the RAM walker does: a full v1 save sequence
  (16,417 64-bit words, unique per-byte pattern) followed by a full readback.
- Checks (contract-encoded):
  - **T1 region**: every accepted address inside the declared window;
  - **T2 first/last**: first accepted address = window base; last =
    base + 2 x (N-1) (contract stride);
  - **T3 stride**: every consecutive accepted address advances by exactly 2;
  - **T4 burst**: every transaction presents `burstcnt == 2`;
  - **T5 integrity**: full 64-bit readback of all N words (catches
    upper-half loss from a burst-1 write);
  - **T6 handshake**: no transaction accepted while the previous one is
    still in flight.

Expected result against the **current** bridge (this is the point — the
test encodes the target contract, not the DUT's assumptions):

- T1 FAIL: `BASE_ADDR 0x1F00000` is below the window base;
- T2/T3 FAIL: stride is 8, not 2, and the first address is `0x1F00000`;
- T4 FAIL: burst is 1;
- T5 FAIL: upper 32 bits of every written word are lost by the model;
- T6 PASS expected (the in-module handshake is sound).

Measured 2026-09-06 against the current bridge (full run, 0.1 s):
T1 oob=32834, T2 first=0x1F00000 last=0x1F20100 (want
0x3800000..0x3808040), T3 mismatch=32834 (tx=32834, exactly 2N),
T4 bad=32834, T5 mismatch=16417, T6 double=0 — i.e. T1-T5 FAIL, T6
PASS, exit code 1, exactly as predicted. The test exits non-zero
(`$fatal`) until the bridge is contract-conforming.

Driver note (observed DUT contract): `slot_wr`/`slot_rd` are
level-sensitive requests — the DUT accepts them only on an edge where
`!ddram_busy`, so the walker must hold the request until `slot_ready`.
The TB models this; a single-cycle request pulse times out.

A contract-conforming bridge should pass all six. If the HPS-side checks
(section 3) later revise the window or the burst convention, only the
window constants in the test change — T3/T4/T5 encode the 64-bit-word
contract, which the PLAN fixes independently of the window.

Run (ad-hoc; not in any Makefile — the level_1b Makefile belongs to the
parallel session):

```
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/unit_tests/level_2
verilator_bin --binary --timing -O3 --x-assign fast --x-initial fast \
  -Wno-fatal -Wno-TIMESCALEMOD --top-module tb_ss_ddr \
  -Mdir build/ss_ddr_obj_dir tb_ss_ddr.sv ../level_1b/savestate_ddr_l1b.sv
./build/ss_ddr_obj_dir/Vtb_ss_ddr
```

## 5. Fix guidance (for the session's bridge — not implemented here)

A contract-conforming `savestate_ddr_l1b` would:

- keep `slot_addr` as the 64-bit-word index (walker unchanged);
- latch `ddram_addr = SLOT_BASE + slot_addr * 2` (DWORD units) — stride 2;
- present `ddram_burstcnt = 8'd2` for both read and write;
- take `SLOT_BASE` from a parameter set at the wrapper from the HPS-verified
  per-slot DWORD base (slot n = window base + n x 0x00080000 DWORD),
  selected by the slot-arbiter slot index once four-slot selection lands;
- keep `ddram_be = 8'hFF` and the existing ready/busy handshake.

Estimated blast radius: the bridge module only (walker, arbiter, coordinator,
and all passing TBs are unaffected — the walker's `slot_addr` index is
unit-independent by design).
