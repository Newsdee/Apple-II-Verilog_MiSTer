# Artifact color + OSD knob plan — Level 2 composite path

Date: 2026-09-08 (local). Written after two crashed sessions (see §2).
Scope: `Apple-II-Verilog_MiSTer/unit_tests/level_2/` (Verilator harness) and
`unit_tests/level_2/mister/` (Quartus/level2 FPGA harness).

## 1. Goal

1. Make NTSC monitor **artifact color / cross-color** actually appear on the real
   FPGA HDMI output, generated the honest way: the source stays 1-bit Apple II
   video; the decoder's chroma path recovers the subcarrier energy the dot
   pattern puts there. No palette LUT, no RGB chroma injection (the 2026-09-07
   pivot — see COMPOSITE_PROGRESS.md 2026-09-07 (c)).
2. Expose the composite knobs (saturation, hue) on the OSD **without polluting
   the menu**: coarse controls now (one option per knob, 16 states = 4 bits),
   finer control later (nonlinear step maps or coarse+fine pairs, same slots).

## 2. Assessment of the crashed sessions

Session `01a07c7c` (2026-09-07 23:29–23:46 UTC local) — composite artifact-color work:

- DONE and verified (unit level): full composite path exists and passes —
  `composite_decoder` (NTSC burst-lock decoder), `apple_composite` (1-bit
  encoder + modulator), `video_mixer_plus` (composite input, RGB passthrough
  byte-identical when composite unused), wrapper wiring in `mister/Apple-II.sv`
  (OSD `O9` → `use_composite`, `comp_sat`/`comp_hue`/`comp_agc`/`comp_luma_gain`
  /`comp_setup`), Verilator L2 matrix: `--composite` (default sat=0) gives
  `nongray=0` (pure gray — correct); `--csat=128` gives `nongray=74256`
  (visible artifact color — the decoder produces cross-color when saturation
  is non-zero). All 7 L2 unit TBs green (2026-09-07 14:55-15:00).
- Where it stopped: the user was looking at **game graphics on the real FPGA
  HDMI output** and saw no proper color. User's lead: "change saturation from
  0 to something". User asked to **save a plan before continuing**; the session
  crashed on that turn (empty assistant reply, no plan file written).

Session `01a07e44` (23:46–23:50 UTC local) — relaunched with the same prompt,
died after ~4 min (mid-review). Also left no plan file. This document is the
first plan written.

## 3. Current state: tree vs flashed RBF (timeline, local time 2026-09-08)

| time (local) | event |
|---|---|
| 05:01 | `sys/build_id.tcl` / build-id update (build05 prep) |
| 07:20 | Quartus Analysis & Synthesis (map report; confirms `apple_composite:comp_enc`, `composite_decoder:u_dec`, `video_mixer_plus:…|comp_dec` in the design) |
| 07:28 | `output_files/level2_build05.rbf` assembled |
| 07:33 | `mister/Apple-II.sv` modified (AFTER the RBF) |

Consequence: **build05 does not contain the 07:33 edit.** What that edit was
cannot be recovered from disk (no snapshot). The current file contains the
composite wiring with `comp_sat = 8'd128` plus the save-state options
(O2/O3) — so the leading hypothesis is that the 07:33 edit was exactly the
`sat 0 → 128` change the user described (see §4).

## 4. Hypotheses (ranked) for "no proper color on the FPGA"

- **H1 (leading): the flashed RBF predates the `comp_sat=128` wiring** (or had
  `comp_sat=0`). Fits the mtimes and the user's own lead. → Fix: rebuild.
- **H2: OSD `O9 "Composite video"` left at Off** (default Off; until toggled the
  hardware is byte-identical to the Sep-6 baseline). → Fix: user toggles O9.
- **H3: content effect** — text-mode / low-frequency content carries little
  subcarrier energy, so cross-color is faint by physics. HI-RES dot graphics
  (games) are the right test content. → Check: same screen, O9 Off vs On.
- H4 (last resort): calibration/lock problem in the decoded path on the real
  timing — would show as `burst` not locking; debuggable only after H1–H3 are
  excluded (probes: `use_composite`, `comp_sample` non-DC, decoder burst lock,
  per-frame `comp_nongray` — tb_l2 already exposes `comp_nongray` for this).

## 5. Design decisions

### 5.1 Artifact color source

Keep the 1-bit source. `apple_composite` encodes luma + color burst only;
the dot pattern's subcarrier energy IS the chroma; `video_mixer_plus`'
decoder recovers it and tints. `comp_sat` scales the recovered chroma
(0 = off/gray, 128 ≈ unity); `comp_hue` rotates the burst reference
(0 = locked, 128 = inverted). The knobs never touch the encoder.

### 5.2 OSD knob mechanism (verified framework facts)

- `hps_io` `status` is **128 bits**; the HPS writes an option's state index
  into the option's bit field. Proven on this exact device by the newsdee
  core (same MiSTer HPS firmware): `O9B` 5 states → `status[11:9]`;
  `o46` 8 states → `status[38:36]`; `OCD` 4 states → `status[13:12]`;
  `OEF` 4 states → `status[15:14]`; `OJK` 4 states → `status[20:19]`.
- ID→bit rule read out of the working newsdee core: **offset = value of the
  first ID character** (0-9 → 0-9, A=10 … Z=35); **lowercase `o` adds 32**;
  the field is the 4-bit window `[offset +: 4]` → **up to 16 states per
  option**. (Uppercase `O`: offset 0–35; lowercase `o`: 32–67.)
- level2 wrapper currently reads only `status[0..9]` → free fields
  `OCD` → `[15:12]` and `OHI` → `[20:17]` are collision-free
  (C=12, H=17; gap at bit 16). `status_menumask(16'd0)` = unrestricted
  (proven working), `status_in(128'd0)` unchanged (no core-modified bits).
- 32 steps per knob = coarse+fine pair = 2 OSD lines per knob. 16 steps =
  1 line per knob. **Decision: 16 steps per knob (2 new OSD lines total)**;
  32-step and nonlinear maps are later extensions into the same slots.

### 5.3 Knob map (16 states each)

| OSD option | CONF_STR | status bits | decode | effect |
|---|---|---|---|---|
| `OCD,Comp sat` | states 0..15 labeled `Off,17,34,…,255` | `[15:12]` | `comp_sat = idx × 17` (0,17,…,255) | 0=Off (gray), 8→136≈unity, 15→255 over-saturated |
| `OHI,Comp hue` | states 0..15 labeled `0,16,…,240` | `[20:17]` | `comp_hue = idx × 16` (0..240) | 0 = burst-locked hue; 128-step ≈ inverted tint |

Default (both state 0) = sat off → composite view is gray until the user
raises `Comp sat`. This preserves "current behavior" by default and mirrors
the harness gate (`comp_sat==0` → `nongray==0`).

Wrapper sketch (level2 `Apple-II.sv`, replacing the hardwired `8'd128`/`8'd0`):

```verilog
// OSD knobs (framework rule: first ID char value = bit offset, 4-bit field).
// "OCD" (C=12) -> status[15:12];  "OHI" (H=17) -> status[20:17].
wire [3:0] comp_sat_idx = status[15:12];
wire [3:0] comp_hue_idx = status[20:17];
wire [8:0] comp_sat = {2'b00, comp_sat_idx} * 9'd17;   // 0..255
wire [7:0] comp_hue = {comp_hue_idx, 4'b0000};          // 0..240 step 16
```

CONF_STR additions (after `"O9,Composite video,Off,On;"`):

```verilog
"OCD,Comp sat,Off,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255;",
"OHI,Comp hue,0,16,32,48,64,80,96,112,128,144,160,176,192,208,224,240;",
```

Verilator mirror: `main_l2.cpp` already takes raw `--csat=/--chue=` (0..255);
add `--csatidx=/--chueidx=` (0..15) applying the same ×17/×16 map so the
harness reproduces the exact FPGA knob positions (cheap, keeps parity honest).

## 6. Steps (S0 first — zero code)

**S0 (user, no rebuild):** on build05, with HI-RES game graphics: toggle OSD
`O9` Off/On and compare.
- If `O9` is absent from the menu → the flashed RBF predates the O9/sat
  wiring; go straight to S1.
- If On shows gray and Off shows the same gray → H1/H2; go to S1.
- If On shows faint/absent color on text but visible on dot graphics → H3,
  path works; knobs (S2) let the user raise saturation.

**S1 (agent prepares, user compiles):** rebuild from the current tree
(comp_sat=128 wiring, no knobs yet) to validate the 07:33 edit and get a
known-good colored baseline (build06).
- User: `quartus_sh --flow compile level2` in `unit_tests/level_2/mister`.
- Agent verifies afterwards: `level2.map.summary` (sources + hierarchy),
  `level2.fit.summary` (headroom; build05 fit: 21,191 ALM used of 42,500,
  timing 5.48 ns / 36.52 ns), `level2.sta.summary`, `level2.asm.rpt`.
- User hardware check: O9 On + game graphics → artifact color expected.

**S2 (agent, code):** implement the knobs per §5.3 in `mister/Apple-II.sv`
(CONF_STR + decode; keep the save-state block and everything else untouched;
mixed-EOL file → byte-safe edit, then `bash eol_guard.sh`, `git diff --check`).
Mirror `--csatidx/--chueidx` in `main_l2.cpp`.

**S3 (agent, Verilator):** validation ladder (see AGENTS.md):
1. `run_composite_unit.ps1` (decoder + encoder TBs) — must stay green.
2. `tb_mixplus` functional harness (`run_tb_mixplus.ps1`) — covers the new
   decode path. KNOWN BLOCKER: host AV/endpoint agent kills freshly linked
   C++ PEs (phase 2 hard block since 2026-09-08 00:40 local: every fresh C++
   PE dies at creation; C PEs and old PEs run). Probe first: build+run a tiny
   C++ hello. If still blocked: chain `rm + make + run` in one command for the
   important tests, document exact re-run commands, fall back to
   `verilator --lint-only -sv` for integration.
3. L2 matrix reproducing knob positions:
   `--disk --composite --csat=0` (expect `nongray=0`), `--csat=136` (≈unity,
   expect `nongray>0`), `--csat=255`, `--chue=64/128/192` with `--csat=136`
   (expect shifted tints, `nongray>0`).

**S4 (user, hardware):** rebuild (build07) with knobs; verify:
- `Comp sat` Off → gray composite; raising it increases color depth;
  `Comp hue` shifts the tint; extreme values (255 / hue 128) look
  over-saturated/inverted as expected (harness behavior, fine).
- O9 Off → byte-identical to baseline (no knob effect; default path untouched).
- Text mode: mostly gray (correct physics); HI-RES: clear cross-color.

**S5 (agent):** log results in COMPOSITE_PROGRESS.md (pass/fail per step,
new vs pre-existing warnings, resource/timing delta from the fitter reports),
update this plan's status, note remaining checks (visual only).

## 7. Risks & pitfalls

- **AV/endpoint C++ PE kill** (see S3.2) — the main Verilator blocker;
  mitigations documented in AGENTS.md (2026-09-08 entries).
- **Mixed-EOL `Apple-II.sv`** — use byte-safe edits; `eol_guard.sh` after.
- **07:33 external edit** — re-read `Apple-II.sv` immediately before S2
  edits; preserve the save-state block; if it changed again since, note it.
- **ID→bit rule is inferred** (from newsdee's proven reads) — S4 hardware
  check is the empirical confirmation; if a knob's bits land in the wrong
  field, the symptom is "option does nothing" → swap to a different unused
  ID (e.g. `OJK`→[23:20], `OOP`→[27:24]) and re-verify; the decode is one
  line each.
- **Do NOT reintroduce palette-RGB chroma** in the encoder — knobs are
  decoder-side only (the pivot decision).
- sat > 128 = over-saturated by design (chroma amplitude exceeds the
  0.3V p-p NTSC norm) — acceptable for a harness, documented.
- `files.qip` — S2 adds no new files (CONF_STR is a string constant), so no
  source registration changes; if any are added, register in `files.qip` AND
  review `level2.qsf`.
- Quartus is user-run (standing preference); agent prepares and verifies
  reports afterwards.

## 8. Completion criteria

1. L2 unit TBs + tb_mixplus + L2 knob-matrix green (or AV-block documented
   with exact re-run commands).
2. build06 (S1) and build07 (S4) map/fit/asm green; new warnings = none
   (pre-existing separated).
3. Hardware: O9+`Comp sat` knob visibly produces artifact color on game
   graphics; `Comp hue` shifts tint; O9 Off unchanged; text stays ~gray.
4. COMPOSITE_PROGRESS.md updated; this plan marked done/partial with
   evidence.

## 9. Re-run commands (for later / AV recovery)

```bat
rem L2 unit TBs (from Apple-II-Verilog_MiSTer, PowerShell):
.\unit_tests\level_2\run_composite_unit.ps1

rem tb_mixplus functional harness:
.\unit_tests\level_2\run_tb_mixplus.ps1

rem L2 matrix knob positions (UCRT64 wrappers):
cd /d E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\verilator
run_verilator.bat --disk --composite --csat=0        rem expect nongray=0
run_verilator.bat --disk --composite --csat=136      rem expect nongray>0
run_verilator.bat --disk --composite --csat=255
run_verilator.bat --disk --composite --csat=136 --chue=64
run_verilator.bat --disk --composite --csat=136 --chue=128

rem Quartus (user):
cd /d E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\unit_tests\level_2\mister
quartus_sh --flow compile level2
```
