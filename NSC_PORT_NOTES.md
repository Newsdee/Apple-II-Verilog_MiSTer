# NSC (No-Slot Clock) Port — Progress Notes

Work-in-progress log for TODO item 1: replace `clock_card` (slot 1) with a port of
jtflanagan/AppleTini's `no_slot_clock.sv`. Verilog repo first; copy to newsdee only
when Quartus is not compiling.

## Status snapshot

| Item | State |
|---|---|
| Audio 3.1/3.2/3.3 (mixer, speaker avg) | Done, staged in BOTH repos (`rtl/apple2_top.v` / `.vhd`) |
| Track clamp (`rtl/floppy_track.sv`, track>34→34) | Done, unit PASS + full smoke PASS, staged in Verilog repo; copy to newsdee pending Quartus |
| NSC port | **DONE, synced to newsdee** (byte-identical copies). Unit PASS (12 checks) + full smoke PASS with the NSC modules actually in the Verilator file list (Makefile fixed, see item 15). Rewritten for Quartus 17 synthesis (modification 7: plain vector instead of packed struct/enum). newsdee `apple2_top.vhd` VHDL wiring fixed. Pending: user's Quartus compile. See session log items 11-15. |

## Session log (2026-08, NSC implementation)

1. Deep-dived Appletini's ticker FSM: `UPDATE_PUB` self-hold is intentional
   pacing (one carry evaluation per tick window), NOT a bug; INC_HOUR is
   correct 24-hour logic (only 23→00 takes INC_DAY). Ported as-is.
2. Confirmed PHASE_ZERO = PHI0 (~1 MHz, HAL ring in timing_generator.v);
   `PHASE_ZERO_R` = one CLK_14M pulse per CPU cycle (same pattern the core's
   softswitches process uses). NSC runs on CLK_14M with that strobe; all NSC
   paths (incl. HPS RTC writer) are in the 14.318 MHz domain → no CDC.
3. Wrote `rtl/nsc_ticker.sv` (new, ours): BCD calendar on CLK_14M, fixes
   clock_card's hour-wrap bug (date advanced 3×/day) and missing month
   lengths; leap year y%4==0 (exact 2000–2099); HPS reload on RTC[64] edge.
4. Wrote `rtl/no_slot_clock.sv` (BSD-2 port, 6 documented modifications,
   CSEC_WRAP=143181 → exact 10 ms at 14.318 MHz).
5. Wired `apple2_top.v`: nsc_ticker + no_slot_clock replace clock_card
   instance; `nsc_slot_sel = IO_SELECT[6:1] | IO_STROBE`; CLOCK_DO/OE from
   NSC outputs (PD mux priority unchanged — CLOCK above HDD/SSC/DISK).
6. Verified core decode (apple2.vhd): $C3xx is ROM-shadowed by default
   (C3ROM=0), so the stock driver's slot-3 probe fails and it finds the NSC
   at $C1xx (slot 1, ioselect) — no C3ROM dependency. $Dxxx is all-motherboard
   ROM in this core, so the driver's $D1xx fallback can't find a card there
   either.
7. Resolved the unlock "discrepancy": hex byte-order slip on our side; stock
   driver stream (C5,3A,A3,5C ×2 LSB-first) == bits 0..63 of
   64'h5CA33AC55CA33AC5. Port is protocol-correct. (Details in section below.)
8. Unit TB written: `/e/tmp/nscport/nsc_tb.sv` — Part A ticker rollover
   (23:59:58 + 3 s → next day, tests the fixed hour-wrap), Part B protocol
   (no-data-before-unlock, mismatch reject, stray-read immunity [!rw write
   gate], re-unlock after readout, offset guard), Part C integration (ticker
   feeds NSC live, free-run ~1.5 s, readout h/m/s vs ticker with +1 s boundary
   tolerance).
9. Verilator build quirks discovered (this MSYS2 v5.050 custom build): tasks
   MUST end with `endtask` (`... end` is a syntax error; `task void` rejected);
   standalone builds need `--binary`; set VERILATOR_ROOT. Recorded in
   newsdee `lessons_learned.md` (new section) + notes below.
10. A `sed 's/^end$/endtask/'` pass to fix the TB over-reached and converted
    column-0 initial-block `end`s to `endtask`; all three reverted by hand.
11. Unit TB first run exposed TWO real RTL bugs (both fixed, both re-tested):
    a. `nsc_ticker.sv` day_last: compared only the BCD ONES digit against
       month_len-1 (off-by-one AND missing tens digit) → Jan 31 rolled to
       Jan 32. Fixed with binary conversion:
       `day_bin = {2'b00,day_tens}*6'd10 + {2'b00,day_ones};
        day_last = (day_bin == month_len);`
    b. `no_slot_clock.sv` offset guard: `addr[3:1]==0` only admits offsets
       $00-$03 — it EXCLUDED the driver's read offset $04 (A2=1, bit2 set).
       The re-arm read at $C3xx+4 was invisible to the module, so unlock
       could never complete. Fixed to `addr[3]==0` (offsets $00-$07), which
       admits $00/$01 (writes) and $04 (read) while still excluding other
       slot software's higher offsets.
12. Third bug, found by Part C integration: same-domain reload race. The
    ticker pulsed `time_en` on the very posedge that updates `time_bcd`, so
    the NSC (same clock) sampled the PRE-tick BCD — published seconds lagged
    reality by exactly 1 s. Fixed in `nsc_ticker.sv`: `time_en` is now a
    one-cycle-delayed strobe (`reload_d <= sec_tick | rtc_reload`), honoring
    the input_time-stable-while-en-high contract.
13. TB wiring bug (ours, not RTL): driving a `wire` both procedurally and
    via continuous assign in Verilator silently never pulses — Part B's time
    load was a no-op. Replaced with regs driven by a single always block.
14. Validation: `module_tests/nsc/run_nsc_unit.bat` → NSC UNIT PASS (12
    checks); full `verilator/build_verilator.bat` + `run_verilator.bat
    --smoke-test` → SMOKE PASS exit 0. TB persisted in-repo as
    `module_tests/nsc/nsc_unit_tb.sv`.
15. newsdee Quartus compile exposed three integration issues (file had never
    been through Quartus before):
    a. Error 10794 at apple2_top.vhd(759): the merged port map wired
       `wr_data => std_logic_vector(CLOCK_DO)` — a type-conversion on an
       OUTPUT actual (illegal VHDL; NSC wr_data/wr_data_en are outputs that
       drive the bus during DS1216E readout, exactly like the old clock_card
       DATA_OUT/OE). Fixed: `CLOCK_DO` is now `std_logic_vector(7 downto 0)`,
       connected directly (`wr_data => CLOCK_DO`), with the conversion moved
       into the PD mux (`unsigned(CLOCK_DO) when CLOCK_OE = '1'`). PD mux
       priority unchanged.
    b. Error 10166 at no_slot_clock.sv(252): "always_comb construct does not
       infer purely combinational logic" (first reported against the
       struct/enum version; suspected trigger was Quartus 17's limited SV
       support for procedural packed-struct field assignments and enum case).
       Rewrote (modification 7 in the file header): `nsc_time_t` struct →
       plain `logic [83:0]` with explicit part-selects (identical bit layout,
       table in the header comment); `carry_sm` enum → nine 4-bit localparams.
       No behavioral change. The rewrite was necessary (Q17 then parsed the
       whole file), but 10166 persisted — item e is the actual trigger.
    d. Error 10768 at no_slot_clock.sv(367): "range must be the final index
       in the indexed name" — one line escaped the mechanical transform:
       `cur_time_q.year_lo[1:0]` (member + sub-range, legal on a struct) became
       the illegal double part-select `cur_time_q[59:56][1:0]`. Fixed to
       `cur_time_q[58:57]` (low two bits of year_lo). Re-validated: NSC UNIT
       PASS + full SMOKE PASS, then re-synced byte-identical to newsdee.
    e. Error 10166 persisted at line 255 after the rewrite, with the real tell
       this time: Warning 10240 "inferring latch(es) for variable month_byte /
       day_byte" — both were assigned only inside the INC_MONTH branch, so
       Quartus inferred latches in the always_comb block, which fails its
       "purely combinational" check. Fixed by moving them to continuous
       assigns (`wire [7:0] month_byte = {cur_time_q[55:52], cur_time_q[51:48]};`
       etc.) — identical values, since they are read only in that branch and
       depend only on cur_time_q. Also made the BCD increment literals
       explicitly sized (`+ 4'd1`, `+ 20'd1`) to clear the Warning 10230s
       (truncated value size 32 → target width). Re-validated: NSC UNIT PASS +
       full SMOKE PASS (LATCH warnings gone), synced byte-identical to newsdee.
    f. Two more Warning 10230s surfaced at the next compile (lines 479/483,
       INC_YEAR branch: year_hi/year_lo `+ 1`) — missed in item e because the
       grep listing them was truncated before reaching them. Sized to `+ 4'd1`
       (BCD digit ≤ 9, +1 ≤ 10, fits 4 bits). Re-validated: NSC UNIT PASS +
       full SMOKE PASS; file now has zero unsized literal arithmetic; synced
       byte-identical to newsdee.
    c. Latent bug found while re-validating: `verilator/Makefile` still listed
       `$(RTL)/clock_card.v` and never listed `no_slot_clock.sv` /
       `nsc_ticker.sv` — so the "full smoke PASS" of item 14 did NOT compile
       the NSC modules (unknown-module instantiations in apple2_top.v). Fixed:
       replaced the clock_card.v line with the two NSC files. Full build +
       `--smoke-test` re-run after the rewrite → SMOKE PASS exit 0, this time
       genuinely covering the NSC in the full machine.
    Validation after all fixes: NSC UNIT PASS (12 checks; readout
    2503300117510000 == fake_time, bit layout confirmed) + full SMOKE PASS.
    Rewritten no_slot_clock.sv copied byte-identical to newsdee
    (`diff` clean); nsc_ticker.sv unchanged and still identical in both repos.

### Verilator build quirks (MSYS2 ucrt64, v5.050 rev vUNKNOWN-built20260702)

- `task ...; ... end` → "syntax error, unexpected end". Use `endtask`.
  Functions with `endfunction` are fine. (Proven via minimal repros.)
- Standalone executable: `--binary` required. Set
  `VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator` or it looks for
  verilated_std.sv at a mangled mixed-separator path.
- Working command:
  ```
  "C:/msys64/ucrt64/bin/verilator_bin.exe" --timing --binary -Wno-fatal \
    -Wno-lint --top-module nsc_tb -o v_nsc nsc_tb.sv no_slot_clock.sv nsc_ticker.sv
  ```

### Remaining steps (in order)

1. ~~Unit TB~~ DONE (NSC UNIT PASS). ~~Full sim~~ DONE (SMOKE PASS).
2. ~~Stage in Verilog repo~~ DONE: `rtl/no_slot_clock.sv`, `rtl/nsc_ticker.sv`,
   `rtl/apple2_top.v`, `NSC_PORT_NOTES.md`, `module_tests/nsc/` (README +
   runner + TB) all staged; user's unrelated changes left unstaged.
   Commit when user says. Note: SIM_FAST variant (`build_verilator_fast.bat`)
   not rebuilt — its branch is structurally unchanged (2-line stub assigns);
   full variant (the one that ran the smoke test) includes and exercises NSC.
3. When Quartus is idle: copy to newsdee — add both .sv files to
   `Apple-II_MiSTer_newsdee/rtl/`, register in files.qip + Apple-II.qsf,
   bind via VHDL component declarations in `apple2_top.vhd` (replace the
   clock_card instantiation, keep the existing RTC wiring from Apple-II.sv),
   delete `rtl/clock_card.v` (+ `rtl/roms/clock.a65` if unused elsewhere),
   update README slot table. Then user runs Quartus map/full compile.
4. Hardware check (user): NS.CLOCK.SYSTEM driver on real MiSTer — readout
   should show current date/time; set time via HPS.

## ✅ RESOLVED — unlock sequence verified (driver ↔ AppleTini MATCH)

While re-verifying the stock driver's unlock loop line-by-line I briefly thought
the byte orders disagreed; that was a hex-digit-ordering error on my side. The
correct derivation:

- **Stock SMT driver** (`/e/tmp/nsc/nsc_driver.s`, `ClockDrv`): reads its table
  with `ldx #$08; lda DSUnlk,X; ... dex; bne ubytlp`; `DSUnlk = * - 1` points ONE
  byte before the `.byte $5C,$A3,$3A,$C5,$5C,$A3,$3A,$C5` array, so X=8..1 walks
  it backwards: bytes written **$C5,$3A,$A3,$5C** ×2. Within each byte, the
  `sec/ror a` + (`pha; lda #0; rol a; tay; sta SLOT3ROM,Y; pla; lsr a; bne`) loop
  emits bits **LSB first** (the sec/ror only forces exactly 8 iterations; traced
  with $C5: writes C5[0],C5[1],...,C5[7]).
  → driver serial stream = C5,3A,A3,5C ×2, LSB-first per byte.
- **AppleTini module**: cmp_reg preloaded with `64'h5CA33AC55CA33AC5`, compares
  `addr[0]` against cmp_reg[0], right-shifts. The RIGHTMOST hex byte of that
  literal is 0xC5 = bits[7:0]. So expected stream = bits 0..63 =
  [7:0]=C5, [15:8]=3A, [23:16]=A3, [31:24]=5C, then repeated
  → **identical to the driver's stream.** ✓ (First bit: driver writes C5 LSB=1;
  module expects bit0 of 0x...C5 = 1 ✓.)

Conclusion: the ported module is protocol-correct against the stock driver.
No change needed; proceed to build + unit TB.

Also confirmed from the driver: unlock writes go to base+{0,1} (A2=0, A0=data
bit), read-out at base+4 (A2=1, A0=0), data bit in bit 0 of the read byte
(`ror a` into the buffer) — all matching the ported module's decode.

## Implementation written (not yet validated)

- `rtl/no_slot_clock.sv` — faithful port of Appletini's module. BSD-2 header +
  attribution included. Adaptations (all documented in-file): globals:: types →
  plain ports; dropped unused `enabled`; bus gated by `strobe`(PHASE_ZERO_R)+
  `slot_sel`+`addr[3:1]==0`; write path now requires `!rw`; CSEC_WRAP parameter
  = 143181 (10 ms @ 14.31818 MHz); UPDATE_PUB hold is intentional pacing (NOT a
  bug — one carry eval per tick window); upstream blocking `cmp_reg_cnt_q=0` in
  reset made nonblocking.
- `rtl/nsc_ticker.sv` — our own BCD time/date source (replaces clock_card's
  ticker). CLK_14M domain. 1 s tick = counter to 14318182; full calendar carry
  with month lengths + leap year (y%4, exact for 2000-2099); HPS RTC reload on
  rtc[64] edge using clock_card.v's bit positions. Fixed clock_card's hour-wrap
  bug (it wrapped at x9→x+1:00 too, advancing date 3×/day) — wrap only at 23→00.
- `rtl/apple2_top.v` — replaced the `clock_card` instance (kept SIM_FAST ifdef
  shape) with `nsc_ticker` + `no_slot_clock`. `CLOCK_DO/CLOCK_OE` ← NSC
  wr_data/wr_data_en. `nsc_slot_sel = IO_SELECT[6:1] | IO_STROBE`. PD mux already
  favors CLOCK_OE over SSC/DISK, so no mux change needed.

### Decode facts confirmed (apple2.vhd address_decoder)
- $C1xx,$C2xx,$C4xx-$C7FF → ioselect(n) when CXROM=0 (default). IO by default.
- $C3xx → ROM_SELECT when C3ROM=0 (DEFAULT); only IO_SELECT[3] if C3ROM set.
  So stock driver's slot-3-first probe hits ROM; it finds our NSC at $C1xx next.
- $C8xx-$CFFF → IO_STROBE when CXROM=0 & C8ROM=0 (default). (Note: a read of
  $C3xx while C3ROM=0 sets C8ROM=1 — existing core quirk, doesn't block NSC.)
- $Dxxx → all motherboard ROM in this core (no D-range slot IO).
- `IO_STROBE` is set at exactly one site (apple2.vhd:347), confirming it is only
  the $C8xx-$CFFF slot-ROM window.

### Clock-domain conclusion
PHASE_ZERO = 6502 φ0 (~1.023 MHz, HAL ring in timing_generator.v, free-running).
PHASE_ZERO_R = PHI0_EN_R = one CLK_14M-cycle pulse per CPU cycle — the same
strobe apple2.vhd's softswitches process uses to sample the bus once per access.
NSC + ticker both run on CLK_14M (14.31818 MHz); HPS RTC is written in that same
domain (hps_io on clk_sys = PLL outclk_1) → **no CDC anywhere in the NSC path.**

## Source material (fetched to /e/tmp/nsc/)

- `nsc_v513.sv`, `nsc_v52.sv` — identical copies of `no_slot_clock.sv`.
  Upstream path (branch `v5_2`, NOT on main):
  `v5/verilog/v5_1_3/v5_1_3.srcs/sources_1/new/no_slot_clock.sv`
- `globals.sv` — the AppleTini package defining all types the module uses.
- `au_top.sv` — shows the instantiation (see below).
- Repo: https://github.com/jtflanagan/AppleTini
- **License: BSD 2-Clause, Copyright (c) 2023 jtflanagan.** User has explicit
  permission to use. Ported file MUST carry the full BSD-2 text + attribution.

## Module facts (from source reading)

Ports: `clk, rst, enabled, input_time(NSC_time), input_time_en, ab_read(AppleBus_read),
sss(SoftSwitchState), ab_write(AppleBus_write)`.

AppleTini instantiation (au_top.sv):
```
no_slot_clock nsc(
    .clk(mig_ui_clk),            // their DDR UI clock — NOT a timebase choice we can copy
    .rst(mig_sync_rst),
    .enabled(1),
    .input_time(nsc_input_time), // driven by top_utility_regs (ARM writes it)
    .input_time_en(nsc_input_time_en),
    .ab_read(ab_read),           // shared bus read snapshot
    .sss(sss),                   // soft-switch state: .slot_access flag
    .ab_write(nsc_ab_write)      // into a 3-client write arbiter
);
```

### NSC_time struct (packed, first member = MSB, 84 bits total)

| Bits | Field |
|---|---|
| [83:64] | centisecond_ticks (20-bit free counter, wraps at 999999) |
| [63:60]/[59:56] | year_hi / year_lo (BCD) |
| [55:52]/[51:48] | month_hi / month_lo |
| [47:44]/[43:40] | day_hi / day_lo |
| [39:36]/[35:32] | day_of_week_hi / day_of_week_lo |
| [31:28]/[27:24] | hour_hi / hour_lo |
| [23:20]/[19:16] | minute_hi / minute_lo |
| [15:12]/[11:8] | second_hi / second_lo |
| [7:4]/[3:0] | centisecond_hi / centisecond_lo |

The module publishes `input_time[63:0]` (BCD fields only; ticks field is internal).

### Bus protocol (DS1216E-style)

- Active when `enabled && sss.slot_access && ab_read.addr[15:8] == 8'hc2`
  → i.e. $C200–$C2FF inside a slot ROM window. A2 = addr[2] (0=write, 1=read),
  A0 = addr[0] carries the serial bit.
- Unlock: 64 consecutive write bits matching pattern `5CA33AC55CA33AC5` (LSB-first
  into cmp_reg shift register). On match: clock_reg ← pub_time, reads enabled.
- Read: each read cycle emits clock_reg[0] on ab_write.wr_data and shifts right;
  after 64 bits, register disabled. A fresh (non-enabled) read resets the compare
  state → re-unlock required for every read burst (matches real DS1216E).
- **Readout byte order (byte 0 first): {centisecond, second, minute, hour, dow, day,
  month, year}** — AppleTini's extended format. A plain DS1216E returns seconds
  first; stock-driver compatibility is alanswx's claim → flag for hardware check.

### Timebase analysis (important)

- Internal ticker: `centisecond_ticks` +1 per clk; at 999999 → wrap + increment BCD
  centisecond pair. So the BCD csec pair advances every 1e6 clk cycles.
- For real time (csec pair = true centiseconds, i.e. 10 ms period): **clk must be
  100 MHz**. AppleTini clocks it at mig_ui_clk and hides drift because their ARM
  periodically rewrites the whole time via input_time_en. We have no ARM.

## Our integration plan (design decisions)

1. **Port** `no_slot_clock.sv` → `rtl/no_slot_clock.sv`, BSD-2 header + attribution.
   Replace `globals::` types with plain wires:
   `addr[15:0]`, `rw`, `slot_access`, `wr_data[7:0]`, `wr_data_en`.
2. **Time source**: no ARM → use the BCD ticker already in `rtl/clock_card.v:176-250`
   (lift it): 1 Hz second tick (V_SYNC @ ~60/s from CLK_2M divider, debounced by
   DEB_COUNTER 0..59 on PH_2 negedge) + full BCD date/time fields + reload on
   `RTC[64]` edge (HPS time). Feeds the NSC_time struct's BCD fields.
3. **Sub-second**: pulse `input_time_en` on each second change with the lifted BCD
   value; the module's internal ticker fills centiseconds between reloads.
   → parameterize the 999999 wrap (or prescale) so csec is real-time at OUR clock.
4. **Clock choice**: TBD — check which clocks apple2_top has (14.31818 MHz clk_sys,
   57.27262 MHz video; possibly 50 MHz HPS ref). 57.27262 MHz → wrap 572726 gives
   10 ms with ~0.0003% error (acceptable); 50 MHz → wrap 499999 exact.
5. **Slot ROM detect**: our core already generates per-slot selects
   (`IO_SELECT[5:0]`, `DEVICE_SELECT[5:0]` — clock_card uses DEVICE_SELECT[1]).
   NSC "any slot" = OR of the ROM-page selects. MUST read the actual slot-ROM decode
   in apple2_top.v/apple2.vhd to confirm which net covers $C800–$DFFF reads.
6. **Wiring**: replace the `clock_card` instance (apple2_top.v ~lines 714-727, inside
   an `ifdef`) with `no_slot_clock`; OR its wr_data_en into the existing ROM data-out
   path (CLOCK_DO/CLOCK_OE pattern). Delete `rtl/clock_card.v` + `rtl/roms/clock.a65`
   (hex only in newsdee) once verified; free slot 1; update README slot table.
7. **RTC input**: RESOLVED — see "Resolved questions" above. Chain exists; no wrapper
   changes needed for time source.

## Resolved questions (verified in tree)

1. **RTC net: EXISTS and is fully wired.** `sys/hps_io.sv` has
   `output reg [64:0] RTC` ("MSM6242B layout") + `output reg [32:0] TIMESTAMP`
   (seconds since 1970). HPS writes 4×16-bit chunks via ioctl cmd 0x22
   (`RTC[(byte_cnt-1)<<4 +:16] <= io_din`), then a bare 0x22 toggles RTC[64]
   as the set-strobe. Chain already in place:
   hps_io instance (Apple-II.sv:230, `.RTC(RTC)` at line 271) → `wire [64:0] RTC`
   → apple2_top (`.RTC(RTC)` line ~465) → clock_card (`.RTC(RTC)`).
   **→ No Apple-II.sv changes needed for the time source.**
   Bit layout = exactly what clock_card expects (sec_ones[3:0], sec_tens[6:4],
   min_ones[11:8], min_tens[14:12], hour_ones[19:16], hour_tens[21:20],
   day_ones[27:24], day_tens[29:28], month_ones[35:32], month_tens[36],
   year_ones[43:40], year_tens[47:44], dow[50:48], strobe[64]).
   Reuse the same positions in the NSC BCD builder (guaranteed consistent).
2. **Clock choice: run the whole NSC subsystem in the PH_2 domain** (57.27262 MHz
   video-phase clock — same domain clock_card's IO logic and the lifted ticker use;
   also the domain where slot-ROM reads occur). Parameterize the centisecond wrap:
   10 ms × 57.27262 MHz = 572726.2 → use **572726** (3.5 ns error per csec tick,
   irrelevant since input_time_en reloads every second and resets csec to 0).
   No CDC at all: ticker, NSC core, and bus protocol share PH_2.
   (apple2_top does also have CLK_50M, but PH_2 avoids a 64-bit strobe CDC.)
3. **Reload strategy confirmed**: pulse `input_time_en` for ~1 µs in PH_2 domain
   whenever the lifted ticker's seconds change (DEB_COUNTER 59→0 wrap) or on
   RTC[64] edge; internal 57.27 MHz ticker fills centiseconds between reloads.

## Driver protocol VERIFIED against original SMT NS.CLOCK.SYSTEM source

Fetched `nsc_driver.s` (full disassembly of stock driver, bobbimanners/ProDOS-Utils).

- **Probe addresses**: driver checks slot 3 first ($C3xx), then slots 1,2,4,5,6,7
  ($C1xx,$C2xx,$C4xx-$C7xx), then "internal" $C8xx. Access = base + {0,1} for
  unlock writes (A2=0, A0=data bit) and base + 4 for reads (A2=1, A0=0).
  → **NSC lives at offsets $00-$07 of each slot's $Cnxx window** (n=1..6 in our
  core = IO_SELECT[1..6] when CXROM shadow off). $Dnxx is not usable (our core
  decodes all $Dxxx as motherboard ROM).
- **Unlock pattern**: driver writes bytes $C5,$3A,$A3,$5C ×2, MSB-first per byte
  (= bit-reversal symmetry: $C5 rev = $A3, $3A rev = $5C). This is the IDENTICAL
  64-bit serial stream as AppleTini's `64'h5CA33AC55CA33AC5` compared LSB-first.
  → AppleTini's module is protocol-correct vs the stock driver. ✓
- **Read data bit**: driver takes bit 0 of each read byte (`ror a`) → module's
  `wr_data = {7'h0, clock_reg[0]}` matches. ✓
- **Timing**: PD path in apple2_top is combinational into the core's D_IN mux;
  CPU samples at PHI1 ~56 video clocks after address valid. NSC's one-cycle
  registered output (ab_write_q) settles within 2 PH_2 clocks → safe. ✓
- **UPDATE_PUB stuck-state quirk** in upstream: carry FSM never leaves UPDATE_PUB
  until the tick counter wraps again → BCD csec advances every 2×1e6 clks. At
  their 200 MHz UI clock that coincidentally = real centiseconds. In our port:
  FIX the stuck state (UPDATE_PUB → IDLE) and parameterize wrap = 572726
  (10 ms at 57.27262 MHz PH_2). Document in header.
- **Write-path rw check**: upstream records unlock bits on ANY cycle at A2=0
  (reads included). Add `&& !rw` to the record path — cannot break the stock
  driver (it only writes there), prevents spurious state from unrelated reads.

## Final port design

1. `rtl/no_slot_clock.sv` — BSD-2 header + jtflanagan attribution; globals:: types
   replaced with plain wires: `addr[15:0]`, `rw`, `nsc_sel` (any slot 1-6 window),
   `time_bcd[83:0]` (NSC_time layout, ticks=0/csec=0 from our ticker), `time_en`
   (1 Hz reload pulse), outputs `wr_data[7:0]`, `wr_data_en`. PH_2 domain.
   Gate: `nsc_sel && addr[3:1]==3'b000` (offsets 0-7 only). Wrap param 572726.
2. `rtl/nsc_ticker.sv` — lifted from clock_card.v (our code, not BSD): V_SYNC
   (CLK_2M ÷16667 ≈ 60 Hz) + DEB_COUNTER 0..59 on PH_2 negedge → 1 s tick;
   BCD sec/min/hour/day/month/year/dow registers; RTC[64] edge reload (HPS time,
   same bit positions clock_card used); outputs 64-bit BCD + `time_changed` pulse
   (on second increment and on RTC reload). No centisecond field (NSC internal
   ticker fills sub-second).
3. `apple2_top.v`: replace clock_card instance (keep SIM_FAST ifdef shape) with
   nsc_ticker + no_slot_clock; CLOCK_DO/CLOCK_OE ← NSC wr_data/wr_data_en.
4. Delete rtl/clock_card.v (+ rtl/roms/clock.hex if present) after validation;
   frees slot 1's $C09x BCD read interface (accepted per TODO — NSC replaces it).
5. newsdee side (after Quartus idle): copy both new .sv, apple2_top.VHD component
   declarations + instance swap (disk_ii binding pattern), files.qip registration,
   delete clock_card.vhd?? (check: newsdee has rtl/clock_card.v — same file),
   update README slot table.

## Remaining open questions

- Confirm nothing in smoke-test program / user workflow reads $C09x (old clock
  card interface) before deleting it.
- newsdee side: apple2_top.VHD needs VHDL component declarations for both new
  Verilog modules; swap instance there too.

## Validation plan

- Unit TB: unlock sequence (64 writes of 5CA33AC55CA33AC5) → 64 reads return the
  expected BCD bytes in order; re-unlock required after burst; time ticks at 1 Hz
  (accelerated in sim); input_time_en reload works.
- Full Verilator build + `--smoke-test` (sim side: free-running ticker from a fixed
  epoch; no HPS in sim).
- Stage in Verilog repo; when Quartus is idle: copy to newsdee, register in
  files.qip/qsf if needed, wire any new HPS input in Apple-II.sv, delete clock_card
  + clock.a65, update README slot table.
- Hardware-only checks (user): stock NSC driver read on real machine; verify byte
  order claim against a known NSC software package.

## Environment reminders

- Verilator: `C:\msys64\ucrt64\bin\verilator_bin.exe` v5.050, needs
  `VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator`, no `-j` flag, --timing for TBs.
- Quartus was running (quartus_map PID 19884) — do NOT copy to newsdee or touch
  Apple-II.qsf / output_files until it finishes.
- User rule: modify Verilog repo first; copy to newsdee only when Quartus is idle.
