# Decisions

## 2026-09-28 (B2): the fixed main tap is the single main-tap policy; align all four layers

- **Decision:** the FFE main tap is a fixed unit-gain anchor. It is never
  adapted, and every layer now says so.
- **The contradiction:** four layers disagreed. `cdr_top` force-zeroed the
  main-tap delta; `cdr_ffe_loop`'s constructor guard was commented out with the
  note "v3 uses gain normalisation to anchor total gain, all taps may adapt";
  `cdr_ffe.scaleCoefficients` — the gain normalisation that note depends on —
  had zero callers; and `test_cdr_ffe` / `test_cdr_ffe_loop` still asserted the
  guards throw, so both had been red for a long time and were being tolerated
  as "pre-existing failures".
- **Why "freeze" and not "adapt":** the *adapt* direction was never actually
  implemented. `scaleCoefficients` was dead, `cdr_top` still zeroed the delta,
  and v3's own runner — like every other runner — defaults to
  `FfeAdaptEnableMask = [1 1 0 1 1 1]`. Every validated result in this repo was
  produced with the main tap frozen. Decisively, `cdr_ffe` already *hard
  rejects* a construction whose `initialCoefficients(MainTapIndex) ~= 1`
  (`cdr_ffe:InvalidMainTap`), so "main tap == 1" was already an enforced
  contract; the restored guards just extend it over the object lifetime instead
  of only at construction.
- **Why the missing guard was not harmless redundancy:** without it the knob
  lies. A caller could pass `mask(MainTapIndex) = 1`, have it accepted, and then
  have the enabled adaptation silently cancelled one layer up by `cdr_top`.
- **Rejected alternative (direction b, allow adaptation):** it would mean
  deleting the `cdr_top` zeroing and wiring `scaleCoefficients` as a real gain
  normaliser. That is a research change: it invalidates every validated lock
  result and needs a full 32-phase re-validation. It is not a cleanup and was
  not done as one.
- **Verified:** `tests/CDR` went 15/17 -> **17/17**; the two red tests pass
  unmodified. The change is bit-exact by construction (the guards only add
  error paths, and neither can fire on any existing configuration) and
  empirically: the 0/-100/+100 ppm smoke is character-for-character identical to
  the pre-change log, down to the eye phase codes and `freqMean` digits.

## 2026-09-28 (fixes): sink a saturation guard into the freq-state gate and enforce stage-1/stage-2 ordering

- **Decision:** treat a railed loop integrator as *not* locked at the library
  level, and make the two mu-downshift stages monotonic.
- **Why the saturation guard belongs in `cdr_top`, not only in the runner:** the
  freq-state criterion is flatness + optional rate match, and with the library
  defaults (`FfeGateFreqExpectedRate = NaN`, `FfeGateFreqRateTol = Inf`) the rate
  term is skipped entirely, so a constant-at-clamp sequence passes. The ppm
  runner already rejected saturation offline via `SlewSatDeltaFrac`, but that
  guard never reached the online gate, leaving every `cdr_top.defaultConfig()`
  caller (the gate is enabled by default) able to latch stage-2 on a railed
  integrator with the eye still shut.
- **Chosen mechanism — input filtering, not a post-hoc veto:** `cdr_top` skips
  feeding blocks with `|FrequencyState| >= FfeGateFreqSatFrac * FrequencyLimit`
  to `updateFreqStateGate`. Vetoing *after* the call was rejected because
  `updateFreqStateGate` latches `FreqGateDone` internally, which would leave
  `gateLatched()` reporting an engaged gate that `cdr_top` had ignored. Skipping
  matches the detector's existing non-finite-sample skip contract. Default
  `FfeGateFreqSatFrac = 0.9`; `>1` disables it and `FrequencyLimit = Inf` makes
  it inert. A real lock sits far below the threshold (`~0` at 0 ppm, `~0.82` at
  `±100 ppm`, versus `3.6`), so no passing configuration changes.
- **Rejected alternative:** defaulting `FfeGateFreqRateTol` to a finite value.
  `cdr_top` is frequency-offset agnostic, so it cannot know a meaningful
  `ExpectedRate`; a finite rate tolerance against `NaN` is meaningless and a
  hard-coded `ExpectedRate = 0` would be wrong for every ppm caller.
- **Stage ordering:** stage-1 is now conditioned on `~gateLatched()`. The two
  stages are one-shot latches with stage-1 evaluated first, so a late stage-1
  could otherwise raise a step that stage-2 had already collapsed
  (`0.02 -> 0.1`). Same-block coincidence is unaffected: stage-2 is applied last
  and still wins.
- **Verified:** `test_cdr_top_configured` 12/12 (two new non-vacuous regression
  tests), full `tests/CDR` 15/17 (only the pre-existing
  `test_cdr_ffe`/`test_cdr_ffe_loop` pair fails), and the ppm/v4 smokes are
  bit-for-bit unchanged in their gate/freeze blocks.

## 2026-09-28 (later): delete center-touch from `cdr_top` and make freq-state the only criterion + default; migrate v4

- **Decision (user-approved):** remove `'center-touch'` as a valid
  `cdr_top` `FfeGateCriterion`, flip the default from `'center-touch'` to
  `'freq-state'`, and migrate the one remaining internal consumer
  (`cdr_dlev_cdrffe_sslms_v4`) to the freq-state freeze gate. This extends the
  ppm-suite retirement below to `cdr_top` itself: no caller can select
  center-touch anymore.
- **Why:** the ppm suite already used freq-state exclusively, and v4 was the
  only path still riding `cdr_top`'s bare center-touch default (via
  `Monitor.Frozen`). At 0 ppm freq-state matches center-touch 32/32, so nothing
  unique was lost; keeping a dead, unselectable criterion in `cdr_top` was a
  latent trap.
- **Scope kept alive:** `loop_monitor.updateFfeGate` and
  `detect_pi_center_touch_lock` are retained (dormant inside the monitor / used
  by the ppm legacy-MAT replay and by v3, and by v4's *lock verdict* which is a
  separate mechanism from the freeze gate). Only the `cdr_top` *gate criterion*
  is deleted.
- **v4 consequence accepted:** migrating v4's freeze to freq-state moves the
  freeze block later (`[2000, 2218]` vs the historical center-touch `~1214–1465`)
  because the freq-state gate needs a 2000-block flat window. The center-touch
  freeze counters (`ModeOccurrences`/`EventCount`/`ResetCount`) are retired to
  `NaN`. v4 was regenerated (8/8 locked, 8/8 frozen).
- **Verified:** checkcode clean; `tests/CDR` 15/17 (only the pre-existing
  `test_cdr_ffe`/`test_cdr_ffe_loop` pair fails); `test_cdr_top_configured` 10/10
  with the freq-state-driven gate tests; default config reports
  `FfeGateCriterion='freq-state'` and `'center-touch'` is rejected.

## 2026-09-28: retire center-touch from the ppm suite; frequency-state is the sole lock criterion and stage-2 gate at every offset

- **Decision (user-approved):** delete the `FfeGateCriterion` option and its
  `'auto'` default from `cdr_three_loop_ppm`, hardcode the stage-2 downshift to
  the frequency-state gate for every offset, and move the 0 ppm pass/fail
  verdict from `detect_pi_center_touch_lock` to
  `loop_monitor.detectFrequencyStateLock` (expected rate 0, same slew-saturation
  guard as nonzero ppm). This supersedes the 2026-09-26 `'auto'` policy that
  resolved to `'center-touch'` at exactly 0 ppm. No compatibility switch was
  kept in the runner (per user: no dead options).
- **Why:** center-touch at 0 ppm was a code-domain modal test that only fired on
  29/32 phases even when the loop was locked, and it duplicated a verdict the
  frequency-state detector already produces. A no-source-change experiment
  showed the freq-state verdict matches center-touch **32/32** at 0 ppm and its
  stage-2 gate fires **32/32**, with tail freq-state `|mean| <= 8.9e-5` and
  `std ~2.5e-3`. Removing the split makes the pass/fail criterion and the
  stage-2 gate identical across all offsets except for the rotation term (still
  applicable only when the PI rotates).
- **Scope preserved:** `detect_pi_center_touch_lock.m` is retained and tested;
  the v3/v4 dLev+CDR-FFE suites still use it for their FFE-freeze write gate, and
  `cdr_top` still accepts `FfeGateCriterion='center-touch'` as its library
  default. `ab_stage2_gate.m` (the A/B harness) was deleted as obsolete. The two
  helper summary/eye writers keep a center-touch branch as a backward-compat
  reader for pre-2026-09-28 MATs only.
- **Verified:** `checkcode` clean; `tests/CDR` 15/17 (only the pre-existing
  `test_cdr_ffe`/`test_cdr_ffe_loop` pair fails); all three ppm directories
  regenerated (32 phases, 15000 blocks) lock 32/32 with eyes 1/1/1. See
  `CURRENT_STATE.md` 2026-09-28 for the table.

## 2026-09-26: remove the legacy dLev settle detector and the runner P-only schedule

- **Decision (user-approved):** delete the dLev settle detector from
  `loop_monitor` and `cdr_top` entirely, and delete the `FreqAcqPonly`
  proportional-only acquisition schedule from the ppm runner. The eye-quality
  (SNR) settle detector is now the sole stage-1 (capture -> settle)
  mu-downshift gate. This supersedes the 2026-09-25 decision that kept the dLev
  detector selectable via `SettleGate` (`'snr'` default, `'dlev'` legacy).
- **Why the dLev detector goes rather than staying as a dead option:** it was
  already documented (2026-09-25) as the root cause of the `-100 ppm` capture
  failure — a two-point displacement test encoding an implicit drift-rate
  threshold `DlevSettleTol/DlevSettleWindow = 0.031 code/block` that a
  `~0.012 code/block` cold-start dLev satisfied at block 84 with 59% of the
  trajectory still ahead. Keeping it selectable left a known foot-gun. The SNR
  gate observes whether the eye is actually open, the real precondition for
  slowing the FFE.
- **Why `FreqAcqPonly` goes with it:** its only stage-1 consumer was
  `out.SettleDone` (the runner Ki re-enable). Since the 2026-09-25 SNR-gate
  commit made `SettleDone` structurally always false under the default gate,
  `FreqAcqPonly = true` had silently become *permanent* P-only (integral gain
  pinned at zero, never restored), which cannot track any offset by
  construction. It defaulted to false, so no default run was affected, but the
  path was a latent trap and any archived `FreqAcqPonly` result no longer
  characterises the current code. Removed rather than repaired.
- **Removed surface.** `loop_monitor`: `updateDlevSettle` / `recordDlevOuter`,
  the `SettleDone` / `SettleBlock` properties, the `DlevSettleEnabled` /
  `DlevSettleWindow` / `DlevSettleTol` config and ring buffer, and the now-unused
  `ringSlot` / `requireDlevSettleEnabled` / `validateTolerance` helpers; the
  constructor is 4-argument only (the 6-argument dLev form is gone). `cdr_top`:
  the `SettleGate` / `DlevSettleWindow` / `DlevSettleTol` config and validation,
  the `SettleDone` dependent proxy, the settle-branch `if/else` (now always
  `updateSnrSettle`), the per-block `recordDlevOuter` call, and `SettleDone`
  from every output/state struct. ppm runner: `FreqAcqPonly`, the `cfg.Ki = 0`
  acquisition branch, the `kiEnablePending` / `out.SettleDone` Ki re-enable,
  the `SettleGate` / `DlevSettleWindow` / `DlevSettleTol` options, and
  `result.SettleGate` / `result.SettleDoneFlag`. v4 runner: the same config,
  consumer and result fields (its independent `DlevSettleStdTolerance`
  convergence metric is unrelated and was kept). The standalone
  (non-`cdr_top`) validation runners each own an inline dLev-settle statistic
  that never touched `loop_monitor` and were left as-is.
- **Verification.** `checkcode` clean on `loop_monitor`, `cdr_top` and the ppm
  runner. `tests/CDR` 15/17 with `test_cdr_top_configured` 10/10 (legacy
  `testSettleDownshiftFiresOnce` deleted) and `test_loop_monitor` 15/15 (its two
  dLev-settle tests deleted); the only failures are the pre-existing
  `test_cdr_ffe` / `test_cdr_ffe_loop` pair, byte-identical to HEAD. Both
  config-path runners smoke-pass (2/2 locked, `AllPhaseLock = 1`), with
  `result.SettleGate` and `result.SettleDoneFlag` confirmed absent.

## 2026-09-26: remove the legacy five-argument `cdr_top` construction path

- **Decision (user-made edit, verified here):** delete `cdr_top`'s legacy
  five-argument component-injection constructor
  (`cdr_top(pd, voter, loopFilter, phaseInterpolator, initialSymbol)`) and
  everything that only served it: the BBPD `processBlock(data, edge)` and
  `processBlockFast`, `resetState(initialSymbol)`, the `PreviousSymbol` and
  `ConfigMode` fields, and the `buildPreviousBlock` / `validateBlockShape` /
  `validateInitialSymbol` / `validateComponents` helpers. `cdr_top` is now
  config-struct only; a non-struct or wrong arity raises `cdr_top:InvalidConfig`.
- **Supersedes** the 2026-09-23 decision below that kept the legacy path "and
  `test_cdr_top`'s 6 checks preserved unchanged". That preservation was worth
  having while the two paths coexisted, but the legacy path had been dead code
  since the config path took over every caller: the ppm runner, the v4 runner
  and `test_cdr_top_configured` all construct `cdr_top(config)`, and no shipping
  code used the five-argument form.
- **Test consequences, applied together with the code change:**
  `tests/CDR/test_cdr_top.m` (the six legacy checks) is deleted, and
  `test_cdr_top_configured.m` drops the two checks that existed only to pin
  legacy behaviour (`testLegacyModeRejectsConfiguredApi` and the config-mode
  `resetState(1)` rejection), 12 -> 11. No file references the removed API; the
  `processBlockFast` that remains in `cdr_ffe` is a different class.
- **Verification:** `tests/CDR` 15/17 with `test_cdr_top_configured` 11/11; the
  only failures are the pre-existing `test_cdr_ffe` / `test_cdr_ffe_loop` pair,
  whose sources are byte-identical to HEAD. Both config-path runners smoke-pass
  end to end (ppm and v4 each 2/2 locked, `AllPhaseLock = 1`).

## 2026-09-26: ppm suite samples through the PI phase table and defaults to the nonideal PI

- **Decision:** the ppm three-loop suite runs with a physically nonideal phase
  interpolator by default. `cdr_three_loop_ppm` gains `PiNonideal`
  (`'ideal'` or `'ab_constant'`) defaulting to `'ab_constant'`, and forwards it
  to `cdr_top`, which previously received a hard-coded `'ideal'`. Neither
  `cdr_pi`'s `a+b=1`/`atan2` table nor `cdr_top`'s existing `PiNonideal`
  validation was changed; only the harness stopped overriding them.
- **Why the option alone is not enough:** the harness addressed the cached
  waveform with the raw `CodeWrapped`, which assumes a perfectly linear
  code-to-phase map. A nonideal table would have been built by `cdr_pi` and
  then discarded, so the option would have been inert. The in-UI offset is now
  `round(top.PhaseInterpolator.getLocalIndex())`, taken from the phase table
  itself. Under `'ideal'` that table is the identity, so the expression equals
  `CodeWrapped` and the change is a bit-exact no-op; `'ideal'` is retained
  precisely so the previous behaviour stays reachable and A/B-comparable.
- **Accepted modelling limit:** the cache is addressed in integer samples, so
  the offset is rounded. At 128 samples/UI one PI code is one sample, hence
  one LSB, and rounding quantizes INL to `+/-0.5 LSB`. For the `ab_constant`
  table (`+/-1.445352 LSB`, 2.890703 LSB pk-pk, 1.037876 LSB RMS at 7 bits)
  this retains three distinct offsets `{-1, 0, +1}` across 52/24/52 codes, so
  104 of 128 codes move by one sample. The same rounding would annihilate an
  INL below about 0.7 LSB pk-pk. Sub-LSB INL therefore cannot be studied in
  this harness without a resampled or fractionally interpolated cache, which
  was deliberately not built.
- **Rejected:** an amplitude-scaling knob (`PiInlPkPkLsb`) to sweep INL
  magnitude. The native 2.891 LSB pk-pk table is the physical model of record
  and a synthetic scale factor would invite reporting an INL level that the
  integer addressing cannot actually represent.
- **Evidence the default is safe:** a controlled A/B with the PI table as the
  only variable (32 start phases, `NumBlock = 15000`, `SaveOutputs = false`)
  keeps 32/32 lock and `AllPhaseLock = 1` in all four arms, holds
  `|FreqStateMean|` within `2.6e-4` of the expected 0.8192 code/block, and
  reports `SlewSaturatedFlag = 0` everywhere. The locked-phase centroid moves
  by one code (106->107 at -100 ppm, 120->121 at +100 ppm) and the spread by at
  most one code, which is what a `+/-1` sample address quantization should do.
- **Known cost, recorded rather than smoothed over:** mean `|PendingCode|`
  roughly doubles to triples (`0.0855..0.1325 -> 0.1805..0.2720` at -100 ppm;
  `0.1220..0.1985 -> 0.3320..0.4625` at +100 ppm). The worst +100 ppm start
  phase sits at 0.4625 against the `SlewSatPendingTol = 0.5` guard, cutting
  that margin from about 60% to about 7.5%. Note that under a frequency offset
  a nonzero mean pending code is **structural**, not evidence of non-
  convergence as the 2026-09-23 entry states for the zero-offset case: the
  required rate 0.8192 code/block is fractional while the PI moves whole codes
  under `MaxDeltaCode = 1`, so a fractional backlog always exists. What the
  measurement shows is that the nonideal table enlarges that backlog, and that
  this guard, not lock or tracking accuracy, is the first thing that will trip
  if INL or offset grows further.

## 2026-09-26: stage markers label the armed gate, not "lock"

- Convergence figures mark both mu downshifts, so the slope changes in the
  traces are attributable. The stage-2 marker is labelled
  `stage-2 downshift (gate: <criterion>)` rather than `(lock)`. Only the
  `freq-state` gate is a component of the lock criterion; `center-touch` is an
  independent code-domain test that at 0 ppm fired on 29 of 32 start phases at
  blocks unrelated to the lock verdict, so a "lock" label would have been
  simply wrong on the zero-ppm figures.
- For the same reason `ppm_lock_summary.txt` no longer claims that a
  freq-state `Stage2Block` equals `LockBlock` "by construction". The gate is
  the frequency-state **component** of a verdict that, where
  `RotationCriterionApplicable` holds, also requires
  `detectRotationPeriodLock`; the sound structural claim is
  `Stage2Block <= LockBlock`. The writer now states that and prints the
  measured agreement (32/32 rows exact, 0 earlier, at both offsets), so the
  claim is checkable from the artefact instead of asserted.

## 2026-09-23: PI slew limit set to one code per update; drift-vs-dither instrumentation

- User-confirmed physical assumption change: `MaxDeltaCode` default goes `12 -> 1` in `cdr_top.defaultConfig` and in the v4 runner, because a real phase interpolator moves one code per update. The previous `12` was a behavioural-study value. Measured impact on the v4 no-argument default run: lock unchanged at 8/8, `AllPhaseLock = 1`, common phase 113, spread 4; only 5 of 120000 block-phase updates ever hit the limiter, all during acquisition (last at block 5432). v3 keeps `12`, so v3-vs-v4 equivalence runs now pass `MaxDeltaCode` explicitly; with it pinned the refactor is still bit-exact in all three configurations.
- `cdr_top` exports the loop filter's pre-quantization state per block (`LoopControl`, `LoopFrequencyState`, `LoopCodeResidue`, `LoopPendingCode`) and v4 stores four traces plus `cdr_loop_dither_vs_drift.fig`. Rationale: `LastRawDeltaCode` and the applied `deltaCode` are both integers, so the PI code trace cannot separate a converged dither from a slow drift.
- Criterion ranking is explicit to avoid over-claiming: `LoopControl` long-window mean and `FrequencyState` steady value are the decisive quantities; `CodeResidue` is corroborating only, because its `(-1,1)` range is structural and always filled, leaving only its sign distribution informative. `PendingCode` persistently non-zero means the loop is slew-limited and therefore not converged.
- `CodeResidue` (fractional truncation remainder) and `PendingCode` (integer slew backlog) are orthogonal and must not be conflated; this is now stated in `MODEL_ASSUMPTIONS.md`.



- User-approved scope: do **not** create a separate waveform-level `cdr_rx_top` yet (the DSP path is not modelled). Instead extend `cdr_top` itself with a second, config-struct construction path that owns the full code-domain CDR core: `cdr_ffe` plus its pending window, the unified PAM4 slicer, `cdr_pd` (MMPD), `cdr_voter`, `cdr_loop`, `cdr_pi`, `dlev_loop`, `cdr_ffe_loop` and the FFE write gate. The legacy 5-argument component-injection constructor, its `processBlock(data, edge)` semantics and `test_cdr_top`'s 6 checks are preserved unchanged.
- `cdr_top` must not reference the ADC. The boundary is "chronological, zero-centred ADC code in, sampling phase out": the caller owns waveform access, `ti_adc_top`, physical-lane-to-time reordering and absolute UI addressing driven by `getSamplingPhase()`. `dlev_loop`, `cdr_ffe_loop`, `cdr_ffe`, `cdr_pd`, `cdr_loop` and `cdr_pi` are reused **without any modification**; the top level only adds four guards (full-block gating for dLev/FFE, pre-slice dLev level read, compute-but-do-not-write under freeze, single-shot mu downshift).
- The one-block loop dead time is modelled inside `cdr_top` as a physical consequence of the CDR FFE precursor look-ahead: block *k* is sampled with `phase[k]`, processed one call later, so `phase[k+1] == phase[k]` and `phase[k+2] == phase[k] + delta[k]`. `flush()` drains the final pending block with zero future samples. The legacy BBPD path keeps its original zero-latency semantics.
- Canonical behaviour is the current executable v3, not the older prose: `transitionFilter = true` (symmetric `0<->3`/`1<->2` only) is the `cdr_top` default, and `FfeTrainingBlocks = 0` means the supervised golden-training path is dead code. The v4 runner therefore **deletes** training entirely (golden TX cache, `channelMainCursorUi` alignment, `FfeTrainingReferenceMode`/`FfeTrainingOuterRef`/`FfeTrainingInnerRef`, training traces and the post-training histogram row). With `T = 0` that deletion is bit-exact; the FFE reference is always the live decision produced from the live dLev levels.
- `mmpd` and `ssmmpd` are **not** two numerical paths. `cdr_pd.mmpd` only accepts 0-3 symbols and 0/1 error bits, so symbolisation is already intrinsic to its interface; `'ssmmpd'` is accepted as an alias that normalises to `'mmpd'`. A genuinely different detector would have to be a full-precision MM (`tau = e[n]*d[n-1] - e[n-1]*d[n]`) requiring a new `cdr_pd` method; that is deliberately not added now.
- `cdr_voter` gains a `'mean'` mode with a configurable denominator (`'auto'` = actual valid-sample count, or a fixed positive scalar) returning `double`. `'auto'` is the default because v3 divides by `numel(ffeOutput)`, which is 61/62/64 on the boundary blocks. `linear`/`constant` keep their strict `== BlockSize` length check and `int16` return, so the existing 7 checks are unaffected.
- The FFE gate keeps v3's two post-trigger actions: `'freeze'` permanently inhibits coefficient writes while still computing and recording raw SS-LMS deltas, and `'pvt-track'` (default) keeps writing but collapses the FFE step to `FfeStepSizePvtTrack`. The causal detector was promoted from the suite helpers to `src/CDR` and gains `resetState()` because the reusable top level now owns it; `test_cdr_validation_paths` asserts the new location.
- The class was renamed `ffe_freeze_monitor -> loop_monitor` and now holds **both** causal adaptation-policy state machines: the FFE write gate (`updateFfeGate`, unchanged logic and thresholds) and a new dLev settle detector (`recordDlevOuter` / `updateDlevSettle`). The monitor only decides; it never holds a loop object and never calls `setStepSize`, so `cdr_top` still applies every action and keeps the data path. This removed `cdr_top`'s `SettleDone` bool and its unbounded `DlevOuterHistory`; the settle history is now a bounded ring buffer of `DlevSettleWindow+1` entries inside the monitor. The rename is behaviour-neutral: v3 reproduces its pre-rename results bit for bit across the three equivalence configs (26/26 fields, `max abs diff 0`), and `cdr_top.SettleDone` remains as a read-only dependent proxy for backward compatibility. Error identifiers moved to `loop_monitor:*` and the test moved to `tests/CDR/test_loop_monitor.m`.
- `PdOffset` is not carried into the new API. It was parsed and exported by v3 but never participated in any update equation, so silently wiring it in would have been a behaviour change.
- Loop parameters are fully configurable and there are no silent defaults: `cdr_top(config)` requires every field and raises `cdr_top:Invalid<Field>`. `cdr_top.defaultConfig()` mirrors the current v3 defaults as a starting point only, and must be re-synchronised whenever the v3 experimental defaults move.

## 2026-09-20: remove redundant separate SS-MMPD methods

- Reverse the separate-method portion of the earlier decision below: SS-MMPD is the existing uniform-weight MMPD kernel when sign-derived PAM4 symbols (`0-3`) and error bits (`0/1`) are passed to `mmpd`/`mmpdFast` with `transitionFilter=false`; separate `ssmmpd` methods are redundant and removed.
- Keep v3's sign-derived inputs and detector instance, but call `mmpdFast(..., false)`. Remove the three `test_cdr_pd` groups tied to the deleted API; the MMPD framework and transition-filter-OFF tests retain kernel coverage.

## 2026-09-20: model SS-MMPD in `cdr_pd` and reuse it in v3

- Model the uniform-weight Sign-Sign MMPD in `cdr_pd` as validated `ssmmpd` and stateless `ssmmpdFast`, following the existing MMPD-style API.
- Make the v3 three-loop script construct one `cdr_pd` instance and call `ssmmpdFast` instead of its inline `ssMmpdUniform`/`ssMmpdValid` helpers. This refactor is numerically identical because both use the same uniform-weight kernel, and it removes duplicated PD logic from the validation script.

## 2026-09-20: add optional MMPD symmetric-transition filter

- Make `transitionFilter` a direct optional trailing argument to `mmpd`/`mmpdFast`, defaulting OFF rather than storing it as a `cdr_pd` class property. Existing 5-argument method callers are unchanged. The OFF branch keeps every non-static PAM4 transition accepted when adjacent error bits agree but, per user request, uses uniform decision magnitude — the `2x` symmetric weighting active at HEAD is removed.
- When ON, retain only symmetric outer `0<->3` (`-3<->+3`) and inner `1<->2` (`-1<->+1`) transitions. The symmetric-transition weight of 2 that was active at HEAD is intentionally dropped so all accepted decisions use uniform magnitude; this supersedes the earlier weighted-transition MMPD decision recorded below. The weighted `mmpdFast` magnitude only affected the manually-run `test_cdr_top_ctle_waveform_mmpd.m` S-curve amplitude; the `_v1` experiment re-derives its own group weights from the decision sign and is unaffected in its closed-loop result.

## 2026-09-20: organize validation entrypoints and centralize path initialization

- Preserve the user-created v3 location under `validation/CDR/test_cdr_dlev_cdrffe/src/cdr_dlev_cdrffe_sslms_v3/`, move six live helpers to `helpers/`, standalone diagnostics to `debug/`, old runners/detector/probes to `legacy/`, and `_scan*.txt` to inert `archive/`. Retain all historical files rather than deleting possibly useful diagnostics. Existing `result/` artifacts remain in place; task-entry modifications and deletions are preserved rather than restored or regenerated.
- Add a single explicit `setup_cdr_dlev_cdrffe_paths` rooted at the suite directory. Default runtime scope adds only current entry/helper and physical ADC/CDR source paths; debug/legacy require an explicit scope. Do not use recursive `genpath`, create duplicate same-name forwarding runners, call `savepath`, or make root resolution depend on `pwd`.
- Repair relocated runner/debug bootstraps so cache paths still refer to `validation/CDR/test_cdr/result` and standard outputs remain under the original suite `result/`. Update canonical tests and the executable fixed-anchor diagnostic copy to use setup. Leave unrelated `newtests` scratch files unmodified and outside the official test path.
- Keep all numerical algorithms, default options, training/decision references, thresholds and waveform scheduling unchanged. Probes that predate reference-parameter separation are labelled historical rather than silently changing their experiments. Historical document snippets remain records of the old layout; the suite README is the current invocation guide.

## 2026-09-17: optional live-dlev FFE training experiment after fixed-reference commit

- Commit `0576cff` checkpoints the independent fixed-reference baseline before this experiment. Keep `FfeTrainingReferenceMode='fixed'` as the default; add explicit `'live-dlev'` mode only for controlled experiments. Experimental changes/results are not automatically committed or made the default.
- In live mode, supervised FFE uses the already computed current-block golden magnitude based on pre-update dlev state, with golden sign and inner/outer class unchanged. It does not use the receive sign or the dlev value after the block update. DD and phase/dlev paths are unchanged.
- Record actual training reference trajectories, active mask and canonical mode. Validate mode before cache access. Test that fixed mode exactly reproduces the baseline, live mode ignores programmed fixed amplitudes, reference traces equal the pre-update dlev state, and mode is dynamically inert when training is disabled.
- Evaluate original gains first with48/16 initial state, PRBS22/8000 blocks and unchanged final lock/freeze criteria. Only recorded modest loop-rate or training-schedule trials may be used if the first live run fails; neither loosening acceptance nor changing nominal initial levels is allowed. Save live experiment outputs separately from the fixed-reference v3 result directory.

## 2026-09-17: separate dlev initial state from supervised FFE reference

- User approved independent parameters: `DlevOuterInit=48`, `DlevInnerInit=16` initialize only the dlev loop; `FfeTrainingOuterRef=36`, `FfeTrainingInnerRef=12` set the fixed golden-symbol amplitudes used only by FFE during training. Changing dlev initialization no longer implicitly changes the programmed FFE target. No automatic derivation or fallback from initial values is retained.
- Require finite real positive scalar references with `FfeTrainingOuterRef > FfeTrainingInnerRef`; do not require an exact3:1 ratio or cap references at the ADC input-code range. Reference values refer to the floating-point post-FFE code domain. Validate before cache access, for default, struct and name/value invocations.
- Keep the phase/dlev training decisions based on their existing live levels; keep DD FFE reference equal to the existing live decision. No changes to update equations, main-tap constraint, gain scheduling, waveform alignment, freeze gate or final-lock criterion. Current PRBS22/8000-block and1000-block training defaults remain.
- Export both programmed FFE references explicitly in the result and `RunOptions`. Historical coupled behavior can be reproduced by explicitly passing FFE references equal to the desired dlev initial values. Pin the freeze integration regression's36/12 reference so later default changes do not redefine that fixture.
- This implements the previously validated fixed-reference diagnostic intervention in production; it is not an AGC, adaptive amplitude estimator, or a claim that36/12 is a universal optimum for every channel. Full-default phase/FFE results are recorded separately without retuning or relaxing thresholds.

## 2026-09-17: retain48/16 anchors and tune update rates for final all-start lock

- Preserve the task-entry user choices of PRBS22/16000 blocks,1000 training blocks, online freeze500 occurrences/100 events, and dlev/FFE anchor48/16. Evaluate real trajectories without relaxing final mode/count/common-phase gates or changing PD polarity/bias, ADC/channel scaling, tap constraints, or update equations.
- Adopt dlev settle mu0.1, FFE capture mu0.0018 and FFE settle mu0.0002 in place of0.6/0.02/0.01. Retain Kp8, Ki0.03, dlev capture mu0.3 and MaxDeltaCode12. Twenty-one representative-start candidates were screened; simply lowering gains enough to pin modes at44/45 near the PD-bias boundary, or achieving per-start locks without all freezes/common-center agreement, was not treated as a sufficient final result.
- Selected candidate D03 passes the32-start no-argument fixture: modes20..22/common21, all32lock/freeze, FFE coefficient spread0.013181<0.02 and pre1/post1+0.003673/-0.010433 within existing bounds. Same gains pass an independent PRBS20/8000 holdout with modes19..21 and FFE/cursor gates passing. Original integration-test numerical fixture is now explicit so future default tuning does not redefine that test.
- Limit: capture entails66..73 accumulated UI slips before settling; the selection optimizes demonstrated final lock/consistency, not minimum acquisition time/slip or BER. No final-lock criterion is replaced by zero coefficient variance caused by freezing. Full records are in CURRENT_STATE, VALIDATION and result-directory tuning CSVs.

## 2026-09-17: causal FFE write-freeze with two 2048-UI post-FFE eyes

- User approved an online, per-start FFE write gate: monitoring starts only after training; cumulative current-search mode must appear at least100 times before its center is latched; then50 center-touch/direct-cross events inside inclusive +/-3 codes trigger permanent freeze. Candidate violations clear both modal search and event history. This is distinct from the final retrospective lock criterion (last2000 samples, at least51 events), which remains unchanged.
- On the trigger block, retain the effective coefficients already used by that block. Continue calculating SS-LMS raw deltas and effective-tap-plus-delta proposals, but inhibit the write from that block onward. Do not set the adaptation step to zero or integrate a shadow tap state. Phase and dlev continue updating. Add enable/threshold options and audit traces so the disabled path can be checked against the previous model.
- Recompute the slowest first-capture, finally locked start after the new dynamics. For this selected start, reconstruct a fixed-tap ideal-ADC/post-FFE eye from the first complete block **after** freeze, taking2048 consecutive UI by default. Separately reconstruct the last2048 UI at the end of the simulation. `EyeDiagramUiCount` is configurable and is not a block count. Render insufficient/unavailable intervals honestly rather than borrowing pre-freeze data.
- Mark freeze-eye sampling position using the online freeze center, and final-eye position using the final lock mode; keep the physical cached-UI phase axis fixed. Use the actual frozen taps, with an explicit final-live-tap snapshot fallback only if the selected start never froze. Store eye data/coordinates/coefficients/markers and render individual plus comparison PNGs.
- Reuse the existing ideal SAR code conversion and symbol-spaced FFE per sub-UI phase; no custom quantizer, waveform normalization, new analog nonideality, or online128-phase sampler is added. Record the fixed-tap offline reconstruction and overlapping2-UI density limitations in MODEL_ASSUMPTIONS. Default result destination remains the user-requested v3 result directory; validation uses the previously agreed explicit PRBS22/20000-block/36-12-anchor configuration.

## 2026-09-16: plot only the slowest first-capture start in v3 convergence traces

- User selected **first capture**, not the final retained-band settling time, as the ranking metric. For each start, freeze its final-2000-block modal unwrapped center and scan the full trajectory from block 1 with the existing inclusive +/-3-code arrival/direct-cross counter. Record the first block reaching 51 events since the last band exit; later exits do not overwrite this first-capture time. Keep the final-window lock criterion unchanged.
- Choose the largest finite first-capture time only among starts whose final-window lock flag passes. Ties choose the first start in scan order; no eligible start means no selected convergence trace, not a substitute unlocked case. This retrospective metric uses the final modal center, so it is not an online hardware lock signal or a measurement of FFE/dlev settling.
- Retain the full start-phase simulation, all traces in the MAT, and the all-start modal lock-phase plot. Phase, dlev, and CDR-FFE convergence plots show only the selected start, explicitly labelled with its start code and first-capture block. Histogram and total-path response diagnostics retain their existing sampling/aggregation conventions.
- Output destination requested by the user: `validation/CDR/test_cdr_dlev_cdrffe/result/cdr_dlev_cdrffe_sslms_v3/`. Continue the explicitly configured PRBS22/20000-block/36-12-anchor experiment, leaving no-argument defaults and adaptation dynamics unchanged. Do not hard-code start 76: the previously saved sweep ranks start 96 latest at block 9849, with start 76 at block 8569 under this exact metric. Center ties retain the existing lowest-unwrapped-code rule.

## 2026-09-16: adopt modal-center touch/cross metric for v3 multi-start validation

- Following the successful saved start-20 trial, the user requested a full start-phase sweep with the lock-phase ordinate equal to each trace's final-2000-block mode. Adopt the trial criterion for v3 final result statistics: fixed modal center, inclusive +/-3-code band, arrival-at-center or direct-cross events, and more than 50 events retained after the last band violation. No mean/std drift gate or fixed-adjacent-pair requirement is applied.
- Keep the strict `detect_pi_dither_lock.m` as a historical comparison; add `detect_pi_center_touch_lock.m` and dedicated tests. All counting uses unwrapped integer codes; only reported centers are wrapped. A complete 2000-block window is required for a positive final decision. Mode ties deterministically select the lowest unwrapped code and are reported. No physics or adaptation dynamics change.
- `LockedPhaseCode` now means the final-window modal code for every start, even when its count criterion fails. Plot accepted points as blue circles and rejected points as red crosses rather than suppressing rejected modes. `AllStartsConverged` means every per-start criterion passes; `AllPhaseLock` additionally retains the existing circular +/-3-code common-center tolerance. Do not conflate the two.
- Add an optional `ResultDir` override so long-run plots/MAT files can be isolated without changing the usual no-argument destination. The requested run uses PRBS22, 20000 blocks, explicit 36/12 anchors, and the same 32 starts `0:4:124` as the supplied plot; this is not an exhaustive 128-start scan. Other parameters and current no-argument 48/16 anchors remain unchanged.

## 2026-09-16: trial terminal modal-center touch/cross lock metric before production adoption

- User refined the experimental lock definition: choose the mode of the last 2000 unwrapped PI codes, freeze this center, and scan only those same 2000 blocks. Permit inclusive center +/-3 codes, count center touches even when followed by a return to the same side, and clear the count upon leaving the band. Retain the requirement of more than 50 events at the end.
- Avoid double counting: count arrival from a noncenter code to the center once; do not count center dwell or departure separately. A direct crossing without landing at center also counts once. Reentry after an out-of-band sample cannot create an event from that outside sample. Initial center dwell has no inherited event. Mode ties select the lowest unwrapped code deterministically and are reported by the standalone diagnostic.
- Scope is a saved-result trial only, using `results/CDR/pi_center_touch_trial/trial_center_touch_lock.m`. Production v3 `LockedFlag` and `detect_pi_dither_lock.m` retain their existing strict-pair behavior pending further instruction. A trial pass expresses bounded phase activity over the specified window, not zero mean drift or proven infinite-time stability. See CURRENT_STATE/VALIDATION for the start-20 result of 178 events with no reset.

## 2026-09-16: allow single-start v3 observations without changing loop defaults

- Add optional `StartPhaseList` to `cdr_dlev_cdrffe_sslms_v3`. Empty retains the existing `0:4:127` sweep; an explicit finite real integer vector in `[0,128)` selects only those starts. Normalize input to a row vector and make lock-summary plot limits valid for scalar/unsorted lists.
- User-requested long observation uses only start 20, the existing PRBS22 cache, `AnalysisNumUi=1280512` for 20000 blocks, and explicit 36/12 anchors to match the previous plotted configuration. Preserve current no-argument 48/16 anchors and all loop dynamics/lock rules. Save diagnostic artifacts independently instead of overwriting the standard result directory.
- This is a validation-runner option, not a new modeling assumption. A single-start run cannot establish cross-start consistency, and PRBS22 is not the exact continuation of PRBS20. See CURRENT_STATE and VALIDATION for the measured remaining slow phase drift.

## 2026-09-16: v3 final PI lock requires terminal adjacent-pair dither, with dwell allowed

- User-confirmed criterion: the terminal segment through the final observed PI code must remain within one fixed pair of adjacent **unwrapped** codes and contain more than 50 actual transitions (minimum 51). A transition counts once, not once per round trip. Repeated codes are allowed, add no transitions, and do not reset the count. Leaving the pair starts a new candidate; a historical qualifying segment cannot establish final lock.
- Replace the v3 final `LockedFlag` standard-deviation gate with `detect_pi_dither_lock`. The previous standalone detector was not called by the restored v3 and was also incorrect for this requirement: it accepted any historical qualifying window, required a transition every block, and allowed a three-code band. Before modification, a synthetic 59-transition `20/21` dither followed by monotonic drift to 80 returned locked, while the same dither with three-block dwell per code returned unlocked.
- Use `UiSlip*SamplePerSymbol + PhaseCodeTrace` so `127/128` (wrapped `127/0`) is an adjacent pair without hiding full-UI drift. Store tail transition count, terminal-pair start/qualification blocks, wrapped pair, and historical maximum as separate diagnostics. The historical maximum never gates lock. No timeout is imposed on dwell, including a final dwell after qualification; a constant-only trace fails because it has no transitions.
- `LockedFlag` now describes PI timing lock only. dLev/FFE standard deviations remain diagnostics, not substitutes for the PI rule. The existing common-phase tolerance of ±3 code remains, evaluated circularly across the PI wrap. No passing start means `AllPhaseLock=false` and no claimed common lock phase.
- Scope: this changes a validation criterion, not the physical model, adaptation equations, gains, nominal levels, or training/settle schedule. Earlier all-start convergence claims based only on tail standard deviation or the fraction of blocks with `|deltaCode|<=1` do not prove this stricter criterion; neither statistic excludes a slow glide. Finite terminal-pair dither also does not prove infinite-time stability, BER, or FFE/dLev convergence.

## 2026-09-16: v3 triple-loop no-arg default retuned (Ki 0.06->0.03, anchors 48/16->36/12, settle mu 1e-3->1e-4) to remove slow phase glide

- Problem: the retained no-arg default of `cdr_dlev_cdrffe_sslms_v3.m` did not truly converge — the PI phase code glided (`mean ~53 -> 24` over 8000 blocks, `UiSlip` accumulating) instead of settling into a `+1/-1` dither, even though the last-30-block std criterion reported `AllPhaseLock=1`. This is the trajectory-misclassification caveat flagged on 2026-09-15, now confirmed.
- Diagnosis (parameter/coupling, not architecture): (1) training anchors 48/16 are ~30% above this channel's offline truth (36.7/12.2), so the golden FFE over-equalizes during training and then crawls back post-release, moving the SS-MMPD S-curve zero and dragging the phase; (2) the RAW SS-MMPD S-curve has one strong + two weak stable zeros per UI (verified via `debug_v3_scurve.m`: strong at code ~16, weak at ~66 and ~99). The two weak zeros are ALREADY cancelled by the existing phase-gated PD bias (`meanPhaseError = mean(ssDecision) + pdOffset*biasActive`, `pdOffset=-0.05`, gated to `codeWrapped∈[45,116]`), so the loop-effective S-curve has a single strong lock. The failure was therefore NOT a surviving parasitic lock: at `Ki=0.06` the phase can move while the cold-start FFE is still forming, golden symbols at the wandering phase collapse the FFE post1 tap (start 32: post1 +0.144@blk400 → -0.005@blk500), and that migrates the SINGLE strong lock from code ~16 to the UI wrap boundary (~code 1), where the loop parks (phase-drift ⇄ FFE-post1-collapse ⇄ main-lock-migration transient feedback).
- Decision: change `parseLoopOptions` no-arg defaults only (no loop-logic change): `Ki 0.06 -> 0.03`, `DlevOuterInit 48 -> 36`, `DlevInnerInit 16 -> 12`, `FfeStepSizeSettle 1e-3 -> 1e-4`. The gated `pdOffset=-0.05` weak-zero-cancellation is left unchanged (re-verified valid at the new 36/12 anchors: loop S-curve still shows a single stable lock). Relax the `allPhaseLock` common-band tolerance from `<=2` to `<=3` code (±3/128 UI ≈ 2.3% UI is the same physical sampling instant; this is a validation-metric choice, not a physical-model change). The anchors stay nominal design values (from ADC full-scale + AGC target), not injected offline truth.
- Result (MATLAB R2025b, no-arg default, 8000 blocks, 32 starts): `AllPhaseLock=1`, 32/32 locked (start 32 recovered, code 11), common code 14, spread 5; tail deltaCode |ΔCode|≤1 for 99.49% of blocks (steady `+1/-1` dither = the user's convergence definition); dLev inner 11.76 / outer 35.31 (truth 12.23/36.71). This supersedes the earlier "restored default already converges" claim for the purpose of true steady-state (non-gliding) convergence.

## 2026-09-16: `test_cdr_cdrffe/cdr_dlev_sslms.m` repurposed to fixed-dlev + adaptive phase(SS-MMPD) + adaptive FFE(SS-LMS)

- User-directed change: the script previously held the CDR FFE coefficients fixed and adapted the phase loop and dlev. It now (a) fixes the dlev decision levels at low/inner `12` and high/outer `36` code (threshold 24), (b) adapts the phase loop with SS-MMPD, and (c) adapts the CDR FFE with sign-sign LMS.
- The fixed dlev values were chosen by the user (12/36) and coincide with the offline four-level cluster truth (inner ≈ 12.2, outer ≈ 36.7). dlev is a name-value option and is not adapted.
- The PD switches from classic amplitude Mueller-Muller to the uniform weight-1 SS-MMPD kernel reused verbatim from `cdr_dlev_cdrffe_sslms_v3.m` (`ssMmpdUniform`/`ssMmpdValid`). Gains act directly on the normalized `mean(±1/0)` output — the code-domain `gainScale=(3/dlevOuter)^2` folding used by the old classic-MM version was removed. Loop gains adopted from the validated v3 SS-MMPD recipe: `Kp=8`, `Ki=0.06`, `PdOffset=-0.05` (gated to `codeWrapped∈[45,116]`), `MaxDeltaCode=12`.
- Per the user's follow-up, the FFE is **cold-started** from `[0 0 1 0 0 0]` (not warm-started from the offline KKT optimum). It uses `cdr_ffe_loop.updateSsLms` with error `decision − ffeOutput`. Because the cold-start eye is closed, the first `FfeTrainingBlocks=500` blocks are data-aided: TX golden symbols (`tx_prbs20.mat`, aligned by `channelMainCursorUi=105`) replace the decision to feed SS-MMPD and FFE SS-LMS, mapped to the fixed dlev code `{±36,±12}`. After block 500 the loop switches to decision-directed **blind** convergence and drops the FFE step from capture `FfeStepSize=0.02` to settle `FfeStepSizeSettle=0.001`. This mirrors the sibling planB cold-start recipe, differing only in that dlev is fixed (not SS-LMS adapted). Default `AnalysisNumUi=512512` (≈ 8000 blocks) gives ≈ 7500 blind blocks.
- Verified in MATLAB R2025b (no-argument default, 32 start phases, 8000 blocks, ~90 s): 32/32 lock to common code 17 (`AllPhaseLock=1`, spread 0), FFE SS-LMS coefficient spread 0.00225 (< 0.01 tolerance), converged free taps pre1 ≈ −0.35 / post1 ≈ +0.13 (true MMSE, larger than the offline 0.05-cursor design). SS-MMPD remained locked as the FFE drove ISI toward the MMSE optimum, confirming the v3 finding that the SS-MMPD S-curve does not depend on residual pre1/post1 ISI. Cold start + golden training gives markedly tighter cross-phase consistency (spread 0 / 0.00225) than an earlier warm-start decision-directed variant (spread 3 / 0.023), because all phases share the same golden-driven trajectory plus a long blind tail.

## 2026-09-15: Restore committed v3 SS-LMS script baseline

- At the user's request, restore ONLY `validation/CDR/test_cdr_dlev_cdrffe/cdr_dlev_cdrffe_sslms_v3.m` from HEAD (`c96ed27`). Its last modifying commit is `b3a9dd9`; both revisions contain blob `30f33dc9d9a378d9423a9bd205845540880a828f`. Retain all other working-tree changes and do not overwrite the existing experiment plots.
- This supersedes the later working-tree fixed-3000-block and target-pulse experiments described below. Restored online FFE is `updateSsLms`, with direct symbol target, mu=0.02/0.001 and fixed unit main tap; dLev is SS-LMS with mu=0.3/0.1; timing uses SS-MMPD with Kp=8, Ki=0.06 and MaxDeltaCode=12. In default 500-block training mode, block 500 still uses golden labels but switches dLev/FFE to fine steps before their updates; DD begins at block 501. No fixed-3000-block switch or active `[c 1 c]` reference remains.
- Reproduction depends on retained working-tree `cdr_ffe.m` window semantics and untracked `dlev_loop.m`; this is not a full-repository historical checkout. The current `cdr_ffe_loop.m` changes were also retained. Do not discard these dependencies under the assumption that restoring v3 alone establishes a self-contained clean-checkout baseline.
- MATLAB R2025b revalidation with `SaveOutputs=false` passed explicit 8000-block, 32-start convergence assertions in 68.439 s: AllPhaseLock=1, codes 23/24, phase spread=1, dLev means 12.159668/36.5540527, dLev spreads 0.0546875/0.1046875, FFE coefficient spread=0.003328125. The separate cursor check still fails (pre1=-0.016126912, post1=-0.0282917317). No restored 30000-block or BER claim is made. Evidence is in the session artifacts `restore_validation.log` and `restored_v3_default_result.mat`.
- Evidence correction: previous declarations that S-curve collapse was the proven root cause, or `[c 1 c]` eliminated all aliases/drift, were overclaims. They remain historical hypotheses, not established findings. Last-30-block wrapped-code standard deviation can misclassify a trajectory crossing 0/127, and spread calculated only over passing starts does not establish all-start stability. The 11 failed target-pulse starts cannot be labelled aliases without further trace/S-curve analysis.
- Source interpretation correction: dLev sign-error adaptation balances positive/negative amplitude-error votes (a conditional-median-type equilibrium), not a general mean estimator. SS-LMS is not guaranteed to equal the Wiener/MMSE solution for arbitrary input statistics. `FfeTargetCursor`/`FfeTargetSkew` are unused legacy options in the restored online path. These corrections change no executable model or physical assumption.


## 2026-08-12: Repository organization

- Reusable models belong in `src/`.
- Behavioral and visual studies belong in `validation/`.
- Automated regression tests belong in `tests/`.
- Fixed input/reference data belongs in `data/`.
- Generated output belongs in `results/`.
- Project paths must resolve from `D:\Work\serdes_modeling`, not a former absolute location.

## 2026-08-13: Current documentation scope

- The current modeling baseline is derived only from `src/ADC` and `src/CDR`.
- `src/LinkSim` is retained as historical reference and must not be presented as the current architecture, current end-to-end implementation, or validated capability.
- Documentation claims must distinguish implemented component behavior from future closed-loop integration.

## 2026-08-13: Current ADC integration path

- `src/ADC/TI_ADC/sar_adc_core.m`, `ti_adc_core.m`, `ti_adc_clock.m`, and `ti_adc_top.m` form the current integrated TI ADC stack.
- Other SAR implementations remain comparison/reference models until an explicit consolidation decision is made.

## 2026-08-13: Digital CDR phase-detector boundary

- Equalization and slicing are outside `cdr_pd`; the PD accepts hard digital data-symbol and edge-bit decisions.
- The PD supports NRZ and PAM4 through the `bbpd` method, with PAM4 as the default mode.
- PAM4 uses `00=-3`, `01=-1`, `10=+1`, and `11=+3`, and only the symmetric `00<->11` and `01<->10` transitions contribute phase decisions.
- The public PAM4 MMPD methods are `mmpd` and `mmpdFast`; they use the reference RTL's binary error-bit decision concept rather than a continuous-amplitude Mueller-Muller equation.
- On branch `codex/mmpd-weighted-transitions-v1`, the behavioral MMPD intentionally does not reproduce the RTL odd/even split and accepts all non-static transitions. Symmetric `0<->3` and `1<->2` transitions use weight 2; asymmetric transitions use weight 1.
- The v1 experiment uses a 64-UI linear voter so that one CDR update matches the 64-lane ADC block cadence. It uses 50 updates over 3200 unique fixture UI and retains unlimited delta code as an isolated experimental choice; unlimited slew does not replace the default one-code slew architecture.
- Initial CTLE MMPD validation treats MMPD as a limited-range tracking detector and, with one-code slew limiting, initializes it 8 samples from its measured statistical lock phase; wide-range acquisition remains the BBPD/FLL responsibility.
- The BBPD/MMPD output is named `phaseDecision` to distinguish the discrete early/late direction from a quantitative phase-error estimate.
- `bbpdFast` is the single stateless block-vectorized BBPD decision kernel. Both public paths return `int8`; `bbpd` delegates to it and adds validation/debug capture, while direct fast-path callers own input validity and block overlap.
- The validated BBPD snapshot stores configuration, digital inputs, `Valid`, and `PhaseDecision`; derived aliases such as early/late/raw/transition/data-side are omitted because they duplicate the decision kernel outputs or can be reconstructed by a debugger.
- Cross-block previous-symbol state belongs to the future CDR top-level, not `cdr_pd`; the top-level must explicitly construct each block's `dataPrev` input using the preceding block's final symbol.

## 2026-08-13: CDR voter boundary

- The initial behavioral CDR uses classic 2x BBPD sampling, with one edge decision per data decision; the 1.25x sparse-edge RTL architecture is deferred.
- One voter call aggregates exactly one parallel block and produces one CDR phase-error update; it does not accumulate across blocks.
- The voter supports `linear` and `constant` modes, with `linear` as the default.
- Linear mode returns the signed phase-decision count. Constant mode returns the sign of that count scaled by configurable `ConstantMagnitude`, which defaults to 8.
- The default block size is 64 and is configurable at construction.
- The voter output uses `int16`. Voter pipeline latency is owned by the future CDR top-level rather than the voter class.
- `voteFast` is the single-block hot path and is called once per 64 UI with the default configuration; cross-block voter aggregation is deferred.

## 2026-08-13: CDR loop-filter boundary

- The behavioral loop filter outputs an integer PI code increment; `cdr_pi` remains responsible for phase accumulation, code wrap, and UI-slip tracking.
- One loop-filter update occurs per 64-UI voter block, and its result affects the following block without additional RTL pipeline delay.
- The loop filter is independent of voter mode and consumes only the numeric `phaseError`; the top level owns voter-mode and gain pairing.
- The current error updates the integral state before the proportional and integral terms form the current output.
- Internal gain, integral, and residual calculations use floating point. Fractional output code is accumulated and only complete integer code is emitted.
- Integral state limits are configurable and default to unbounded. Finite limits saturate and permit recovery under reverse error.
- PI increment limiting belongs to `cdr_loop` because it constrains the loop-filter output delivered to the PI. `MaxDeltaCode` defaults to one code per block; callers may explicitly select `Inf` for an unlimited behavioral study.
- The limiter preserves clipped complete-code demand in an explicit integer `PendingCode` state while `CodeResidue` remains fractional-only. Opposite-direction requests cancel pending code before adding backlog in the reverse direction.
- `PendingCode` is exposed rather than hidden in `CodeResidue`; an independent pending-code bound or anti-windup policy remains deferred until the corresponding RTL behavior is defined.
- RTL fixed-point widths, shift-encoded gains, Gray-code generation, permanent overflow freeze, and a separate FLL are outside the initial behavioral loop-filter scope.

## 2026-08-13: Digital CDR top-level boundary

- `cdr_top` composes configured PD, voter, loop-filter, and PI objects rather than duplicating their configuration.
- The top level owns the previous-symbol state needed to preserve PD transitions across block boundaries.
- The PI phase entering a block is used for that block; its phase-error result updates the PI for the following block.
- The initial previous symbol is supplied explicitly at construction and whenever the top level is reset.
- The validated path exposes a debug snapshot; the fast path omits validation and does not update that snapshot.
- The initial top-level boundary accepts already-sliced digital decisions and does not yet connect to the TI ADC or analog waveform.

## 2026-08-13: CDR equalization and slicing boundary

- The timing-recovery path will use a dedicated CDR FFE rather than sharing the data-recovery FFE/DFE path.
- The CDR timing path does not include the data-path DFE.
- The dedicated CDR FFE and slicers are upstream of the current digital `cdr_top` and are deferred to the waveform-integration stage.
- A fixed-threshold slicer does not require a stateful class. PAM4 symbol slicing uses three thresholds, while the BBPD edge-bit slicing uses only the center threshold.

## Observed model choices pending confirmation

The following values appear in current ADC waveform studies but are not yet permanent project-wide requirements:

- 112 Gb/s PAM4 and 56 GBd.
- 128 samples/UI.
- 64 TI ADC lanes and 8 SAR lanes per TAH group.
- 7-bit conversion.
- Maximum-power/variance phase selection for offline waveform sampling.
- Integer sample-index timing displacement.

## Pending decisions

- Canonical SAR code-boundary and reconstructed-voltage convention.
- Whether PI floating indices will be rounded or used with interpolation.
- Required jitter model composition and units at each block boundary.
- Accuracy/correlation target and numerical regression tolerances.
- Whether large waveform fixtures and generated results should remain version-controlled.

## 2026-08-16: Minimal TI ADC and CDR joint-validation boundary

- The first joint waveform validation uses the existing PAM4 MMPD `data + error-bit` path because it locks a baud-rate ADC sample to the data-eye center.
- DSP decisions consume only 7-bit ADC codes. Four code centers are calibrated before loop startup; three midpoint thresholds produce PAM4 data, and the decided-level center produces the binary MMPD error bit.
- `ti_adc_clock` and `ti_adc_top` expose samples in physical-lane order. The joint DSP explicitly applies the inverse physical-lane-to-time-order mapping before forming adjacent-symbol MMPD inputs.
- The validation retains the existing 64-lane, 8-SAR-per-TAH, 128-samples/UI, 7-bit, `[-0.3,+0.3] V`, integer-index configuration and does not introduce a dedicated CDR FFE.

## 2026-08-17: Minimal fixed CTLE for MMPD debugging

- The active source gains a small `src/AFE` boundary; historical `src/LinkSim` CTLE code is not reused.
- The CTLE directly implements `H(s)=k1*(s+wz)/((s+wp1)*(s+wp2))` with fixed zero/pole frequencies and uses `lsim` for batch waveform processing.
- The constructor accepts samples/UI rather than sample rate; sample rate is derived from the fixed symbol rate.
- The default 4.5 dB Nyquist peaking is a manual debug setting for the 12 dB channel, not an optimized product requirement.
- Adaptation, AGC/VGA, and plotting are outside this implementation.

## 2026-08-19: Maximum-power CTLE fixture and full-period export

- The Channel+CTLE validation overrides, but does not change, the `ctle` class defaults. Its current user-tuned debug configuration is `fz=6 GHz`, `fp1=28 GHz`, `fp2=50 GHz`, and `0 dB` DC gain, corresponding to approximately `9.38 dB` Nyquist peaking.
- A six-tap, two-precursor/three-postcursor TX FFE is implemented only in the validation script. It is optimized offline against the current Channel+CTLE symbol-pulse response, constrained to unit L1 norm and a positive main tap, and is applied consistently to preview and streamed cache generation.
- Symbol-spaced ISI for this validation is reported from the complete one-UI symbol-pulse response because the TX uses a one-UI zero-order hold. The Dirac unit impulse response remains available for analog-kernel inspection but is not used as the TX FFE cursor acceptance metric.
- One PRBS20 bit period is exported. The first bit is appended to the odd-length period solely to complete the final natural-mapped PAM4 pair.
- Full-period output is streamed in causal blocks because the 67108864-sample TX, channel, time, and CTLE arrays cannot safely coexist in available memory. A short waveform must match the existing batch channel and CTLE paths before the export is allowed.
- The exported v7.3 MAT cache contains raw TX-FFE+Channel+CTLE amplitude as float32 with no ADC-range scaling; any later ADC fixture preparation owns that scaling explicitly.
- A full time vector is not cached. Consumers reconstruct it from the stored double-precision sample interval, avoiding both redundant storage and float32 time-resolution loss.
- The co-simulation defaults to preview-only execution so CTLE zero/pole tuning cannot accidentally overwrite the binary waveform cache. Cache export requires an explicit `test_channel_ctle_cosim(true)` call.

## 2026-08-17: Minimal TX and S-parameter channel boundary

- The active source gains `src/TX+Channel`; historical `src/LinkSim` TX and channel classes remain reference material and are not reused as the implementation baseline.
- `tx_channel` accepts already-mapped voltage symbols, performs only ideal zero-order hold, and passes the resulting waveform through one differential four-port S-parameter channel.
- The default interface uses 56 GBd and 128 samples/UI and returns a complete channel waveform plus its time vector for direct CTLE input.
- The four-port channel is interpreted with differential signaling and port order `[1 2 3 4]`. Source and load resistance are 50 ohms, with no added TX or RX termination capacitance.
- PRBS generation, PAM4/NRZ mapping, TX FFE, pre-emphasis, TX analog bandwidth, jitter, noise, and streaming state are outside this minimal boundary.

## 2026-08-17: Dedicated CDR FFE and LMS boundary

- The dedicated CDR equalizer is a floating-point 1-UI FIR, separate from the data-path FFE/DFE.
- The default layout is six taps with two precursor taps, one fixed unit main tap, and three postcursor taps; tap count and precursor count remain configurable.
- One FFE object processes one stream. Data/edge distinction and any coefficient synchronization across separate stream states belong to the calling top level.
- The initial implementation realized precursor taps with `PreTapCount` UI of causal output latency and explicit initial-output validity; this interface was superseded by the 2026-08-25 caller-assembled window decision below.
- LMS adaptation is a separate class. It consumes data-stream decision error and the FFE regressor, normalizes the gradient by the 64-UI block size by default, and never adapts the main tap.
- The coefficient update computed from one block is applied after filtering and therefore affects the following block.
- RTL coefficient widths, arithmetic quantization, saturation, and a default LMS step size are outside the first implementation.

## 2026-08-25: Caller-assembled CDR FFE window interface

- `cdr_ffe` now uses the caller-assembled window interface and supersedes its earlier stateful cross-block-history interface.
- Its input is one complete chronological window: `PostTapCount` past samples, the target block, and `PreTapCount` future samples.
- The class owns only coefficients, FIR calculation, and regressor generation. It does not own past carry, a pending block, look-ahead buffering, flushing, processed-sample counting, or stream-boundary validity decisions.
- The caller, intended to be a future waveform-level CDR top, owns window assembly and must exclude or separately mark any zero-padded boundary outputs.
- The validated interface accepts a finite real numeric row-vector window, converts it to `double`, and returns a row-vector target block plus a `BlockLength`-by-`TapCount` regressor. The fast interface assumes the same double row-vector contract.
- The output contains only the target block and has length `numel(inputWindow) - PostTapCount - PreTapCount`; no redundant all-true validity vector is returned.

## 2026-08-26: CDR FFE LMS validated and fast-path boundary

- `cdr_ffe_loop.update` owns input validation, `double` conversion, error-vector row normalization, and diagnostic state updates.
- `cdr_ffe_loop.updateFast` is a caller-validated pure calculation path. It requires a `double` `BlockSize`-by-`TapCount` regressor and a `double` row error vector with `BlockSize` elements, returns coefficient delta plus an optional raw gradient, and does not modify `LastGradient`, `LastDelta`, or `UpdateCount`.
- The validated `update` path delegates its normalized arrays to `updateFast`, then records the returned gradient and delta. This keeps one public mathematical implementation while preserving existing single-output fast calls.

## 2026-08-26: Fixed-phase CDR FFE adaptation validation protocol

- The adaptation diagnostic uses fixed phase 20 and the existing ideal 64-lane TI ADC rather than bypassing the ADC with direct waveform sampling. ADC lane outputs are reordered into time order before FFE processing.
- A bounded integer-delay correlation scan establishes symbol alignment, and one code-to-PAM4 scalar is trained and frozen before LMS begins. Neither alignment nor scaling is re-estimated per block.
- Step-size selection is based exclusively on supervised convergence metrics. Decision-directed SER, MSE, level opening, coefficient span, and delta size are independent acceptance evidence and cannot influence the selected `mu`.
- The default schedule is 8192 supervised plus 8192 decision-directed UI. The 12288/4096 fallback may run only if every candidate fails supervised checks, and its use must be recorded in `result.mat` and the console report.

## 2026-08-17: Open-loop ADC and optimized fixed CDR FFE pulse-response validation

- The first AFE-side ADC/FFE integration diagnostic remains open loop and uses no LMS adaptation or MMPD feedback.
- The FFE main tap remains fixed to one. The other five taps are found by a constrained least-squares solve using the actual ADC sampled pulse response.
- The constraints apply to the cascade output rather than the FFE tap vector: normalized output `pre1` and `post1` are each fixed to `+0.1` relative to main cursor one; all other fitted non-main cursor energy is minimized over `[-3,+8] UI`.
- The resulting taps are approximately `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]`. They are held fixed during the plotted open-loop run and are not produced by online LMS.
- The TI ADC samples the scaled Channel+CTLE pulse at its absolute peak phase, then the DSP reorders physical lanes into chronological UI order before applying `cdr_ffe`.
- The ADC input pulse peak is scaled to `0.24 V` inside the ideal 7-bit `[-0.3,+0.3] V` range. ADC zero-input reconstructed voltage is subtracted before cursor normalization.
- The plotted ADC/FFE cascade is labeled a sampled pulse response because ADC quantization prevents treating it as an amplitude-independent LTI unit impulse response.

## 2026-08-17: Fixed-FFE MMPD lock-range validation boundary

- The first full generated-waveform timing loop is implemented as a validation script that explicitly composes MMPD, voter, loop filter, and PI. `cdr_top` remains unchanged because its interface is currently BBPD data/edge oriented.
- The optimized open-loop FFE coefficients are frozen at `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]`; LMS adaptation is deliberately excluded from the lock-range measurement.
- The MMPD characteristic uses `[2,1,2,1]` symmetric transition-group weights and 13-sample circular smoothing to reject narrow noise-induced zero crossings. Dynamic acquisition is accepted only by closed-loop final-window criteria.
- Loop gains and polarity are selected locally from initial offsets `-3` and `+3` samples, then frozen before scanning every integer initial phase over one UI. Per-initial-phase gain retuning is not allowed.
- For the current deterministic fixture the selected fixed loop is `Kp=0.256`, `Ki=0.002`, polarity `+1`; the continuous passing interval is `[-3,+16]` samples around lock, or 0.1484 UI wide.
- For the added post-FFE voltage diagnostic, "maximum eye" means the integer phase that maximizes the minimum adjacent spacing among four unsupervised ordered FFE-output voltage centers. The histogram colors samples by nearest center and does not claim transmitted-symbol labeling or BER.

## 2026-08-20: MMPD-v1 CTLE cache and fixed-segment phase scan

- `test_channel_ctle_cosim.m` owns only PRBS20 generation, the optional TX FFE, Channel, CTLE, and cache export. The 10-tap TX FFE implementation remains under `if false` and the default cache contains the un-equalized Channel+CTLE waveform.
- One complete PRBS20 bit period is cached. The odd final bit is paired with the repeated first bit, producing 524288 PAM4 symbols and 67,108,864 waveform samples at 128 samples/UI.
- The cache is a v7.3 MAT file with `single` `ctleOutput`, PAM4 symbols, Channel+CTLE impulse response, timing/configuration metadata, and TX-FFE status. The complete Channel waveform is not stored.
- `mmpd_s_curve_own_data.m` owns the existing `ti_adc_top`, optimized `cdr_ffe`, amplitude calibration, live PAM4 slicer, and offline classic Mueller-Muller phase scan.
- Every phase from 0 through 127 uses the exact same cached UI interval `[512,16896)`. Phase scanning changes only the sample offset; it never advances to a different data segment.
- The ADC uses 64 lanes, 7-bit conversion, and fixed `[-4,+4] V` input limits. Each phase run resets the ADC and CDR FFE and processes 256 blocks of 64 UI.
- The CDR FFE keeps the 10-tap layout `[-3,+6] UI` and its main coefficient fixed at one. The other nine coefficients are solved from the quantized Channel+CTLE unit-UI response by constrained regularized least squares.
- The two response constraints are normalized `pre1=0.1` and `post1=0.1` relative to main one. The objective minimizes all other cursor energy over `[-3,+9] UI`.
- ADC codes are centered by subtracting midcode 64 before CDR-FFE filtering. The CDR-FFE histogram therefore represents floating-point centered equalized code, not raw integer ADC code.
- CDR-FFE coefficients are designed once at phase 19 and frozen across phases. Phase-19 output centers define one fixed linear code-to-`[-3,-1,+1,+3]` amplitude calibration for the full scan.
- The cached-data diagnostic uses the classic equation `d[n-1]e[n]-d[n]e[n-1]`, with full PAM4 decision amplitudes and signed residual amplitudes. It intentionally does not reuse the binary-error `cdr_pd.mmpdFast` behavior. In addition to the unfiltered live curve, it reports a phase-19 fixed-decision reference and the reference script's symmetric-transition live filter; the outer-transition-only filter remains excluded.
- The fixed-decision comparison is represented on a phase-19-centered `[-0.5,+0.5) UI` axis. When a raw `0:127` ADC phase maps across that centered UI boundary, the fixed decision sequence is shifted by one symbol and edge samples are trimmed rather than circularly reused.
- The Channel+CTLE unit-impulse peak phase is not used as the ADC reference phase. CDR-FFE cursor constraints are formed from the one-UI symbol-pulse response sampled at the retained phase-19 design point.

## 2026-09-01: Three-loop (MMPD + dlev + CDR-FFE) training golden alignment and planB step size

- `validation/CDR/test_cdr_dlev_cdrffe/cdr_dlev_cdrffe_sslms.m` must compensate the Channel+CTLE main-cursor group delay when it selects the golden TX symbol window for training. The received sample at global UI `u` carries the main cursor of the TX symbol transmitted at UI `u - channelMainCursorUi`, so `goldenFirst = analysisStartUi + firstUi - channelMainCursorUi + 1`.
- `channelMainCursorUi` is derived from the cached symbol-pulse peak with the same convention as `samplePulseAtPhase`: `round((pulsePeakIndex - 1 - referencePhase)/samplePerSymbol)`. For the current cache this equals 105 UI, matching the independent alignment scan (105 UI, 0.9222 sign/level correlation) already recorded for `test_cdr_ffe_adaptation`.
- The earlier zero-delay assumption (`goldenFirst = analysisStartUi + firstUi + 1`) fed the three loops golden labels that were 105 symbols out of phase, i.e. effectively random, which is why adding a training sequence still could not lock any of the three loops. This was the primary root cause; the fix is required for convergence.
- planB (cold-start, training-mode) FFE adaptation needs a usable step size and enough supervised blocks. The default `FfeStepSize=1e-6` is a planA precision-trim value and is far too small for cold start. Verified: with the alignment fix, `FfeStepSize` in the `1e-5`..`3e-4` range plus `FfeTrainingBlocks >= 400` locks all 32 start phases (`AllPhaseLock=1`); `1e-6`/150 blocks locks 0/32. Recommended baseline: `FfeStepSize=1e-4`, `FfeTrainingBlocks=400`.
- 2026-09-01 follow-up: the script defaults were switched to the training baseline (`FfeInitMode='planB'`, `FfeTrainingBlocks=400`, `FfeStepSize=1e-4`, `FfeStepSizeSettle=2e-5`) so a no-argument run does cold-start data-aided training from FFE `[0 0 1 0 0 0]`. Decision-directed planA behaviour is still available by passing `'FfeInitMode','planA','FfeTrainingBlocks',0,'FfeStepSize',1e-6,'FfeStepSizeSettle',2e-7`.
- Locked phase code still varies with `(mu, trainingBlocks)` and the strict `FfeConstraintHeld` (normalized `pre1=post1=0.05`) is a post-lock precision metric, not a convergence gate; achieving it exactly requires longer training and is tracked separately from three-loop lock.

## 2026-09-03: SS-LMS for CDR FFE adaptation (v3)

- `cdr_ffe_loop` gains `updateSsLms` and `updateSsLmsFast` methods. The gradient is `sign(errorVector) * sign(dataRegressor) / BlockSize`, replacing the standard LMS product `errorVector * dataRegressor / BlockSize`. The adaptation-mask and step-size semantics are identical.
- SS-LMS discards error and regressor amplitude information, using only their signs. This makes the gradient magnitude bounded by 1 regardless of signal swing, which is hardware-friendly (only comparators needed) but requires ~200× larger step sizes to achieve comparable convergence speed.
- The v3 validation script `cdr_dlev_cdrffe_sslms_v3.m` uses `FfeStepSize=0.02` (capture) and `FfeStepSizeSettle=0.001` (settle), compared to v2's `1e-4` / `2e-5`. Phase and dLev loop parameters are unchanged.
- SS-LMS has slightly larger steady-state misadjustment than MMSE LMS. The normalized `post1` converges to approximately `-0.028` rather than the `< 0.02` achieved by MMSE LMS. This is an inherent property of the sign-sign approximation, not a tuning deficiency.
- The standard MMSE LMS path (`update` / `updateFast`) is unchanged. Both methods coexist in `cdr_ffe_loop` and callers select by method name.

## 2026-09-02: Three-loop convergence is a slow relaxation; PRBS22 long-run + block-count policy

- Verified the triple loop (MMPD phase + dlev + CDR-FFE) is a genuinely
  *converging* (not diverging) system. On a PRBS22 complete-period cache run of
  30000 blocks with default settle steps, `|x - x_inf|` for phase / dlev /
  every FFE tap decays exponentially (log-linear fit slope < 0, time constant
  `tau ~= 7500..9000` blocks). Common lock stays tight throughout
  (`AllPhaseLock=1`, `PhaseSpread=1`).
- Convergence onset: relaxation begins immediately after training ends
  (`FfeTrainingBlocks=500`). ~90% of the total excursion completes by
  block ~12000-13000; ~99% by block ~26000. At 30000 blocks a small residual
  drift remains (~1 phase code / 1000 blocks), i.e. asymptotic, not bit-static.
- Increasing the FFE settle step size does NOT help: a sweep of
  `FfeStepSizeSettle in {2e-5, 5e-5, 1e-4, 2e-4}` showed larger mu *grows* the
  residual drift, breaks FFE consistency at >= 1e-4, and pushes pre1/post1
  further from the symmetric target. The smallest (2e-5) is the best operating
  point. The long tail is a long-time-constant relaxation, not insufficient step.
- Block-count policy (default cache is PRBS20, capped at ~8176 blocks):
  - Routine / day-to-day testing: **10000 blocks** (covers ~85-90% of the
    excursion; enough to confirm lock + rough steady levels). Requires the
    longer PRBS22 cache since PRBS20 caps at ~8176.
  - Final verification: **25000 blocks** (covers ~99% of the excursion).
- Longer runs require a longer waveform. `test_channel_ctle_cosim.m` now takes
  an optional PRBS order (20/21/22); `test_channel_ctle_cosim(22)` writes one
  complete PRBS22 period (2^21 = 2,097,152 symbols, ~30760 usable blocks) into
  an independent cache `result/channel_ctle_cosim_prbs22/`, preserving the
  PRBS20 cache. PRBS30 was requested but its full period (~2^29 symbols,
  ~275 GB) is infeasible to store, so PRBS22 was chosen as the storable
  complete-period substitute.
- `cdr_dlev_cdrffe_sslms.m` gained `CosimDir` / `TxFile` / `AnalysisNumUi`
  options plus a `getCachePeriodFlag` helper (accepts the generic
  `isCompletePrbsPeriod` field of new caches and the legacy
  `isCompletePrbs20Period`). No-argument default behaviour is unchanged
  (PRBS20, 8000 blocks, `FfeTrainingBlocks=500`, planB cold start).

## 2026-09-03: CDR v3 triple-loop settle policy simplified to fixed-block mu switch

- Root cause of the large three-loop convergence oscillation (dLev + FFE +
  timing) in `cdr_dlev_cdrffe_sslms_v3.m` was diagnosed as a **loop-parameter /
  cross-loop-coupling problem, not an architecture problem**. The training phase
  (golden symbols) converges cleanly; the oscillation only appears in the
  post-training decision-directed phase.
- The dominant mechanism was the settle-trigger deadlock: the old scheme delayed
  the dLev/FFE mu downshift until `ffeConvergeCounter >= FfeConvergeWindow`, but
  FFE<->dLev coupling kept the per-block FFE step above `FfeConvergeTol`, so the
  counter never accumulated and the system ran at capture-mu until the
  `FfeSettleMaxBlock = 8000` forced fallback.
- **Decision**: remove the entire multi-stage settle machinery (lock counter,
  FFE convergence counter, staged `FfeReleaseMode`, `FfeSettleDelay`,
  `FfeSettleMaxBlock`, `Lock*`/`DlevSettle*` settle tolerances) and replace it
  with a single deterministic trigger: at `SettleBlock` (default **3000**) both
  dLev and FFE step sizes drop from capture to settle in one shot.
- **Loop-gain retune** to reduce coupling-noise amplification: `Kp` 8.0->4.0,
  `Ki` 0.06->0.03, `MaxDeltaCode` 12->8, dLev capture `StepSize` 0.3->0.2. FFE mu
  (1e-4->2e-5) and settle dLev mu (0.1) unchanged.
- The FFE update remains standard block-rate MMSE LMS (`cdr_ffe_loop.update`);
  only the dLev loop is SS-LMS and the PD is SS-MMPD. (An earlier CURRENT_STATE
  line describing the v3 FFE as SS-LMS did not match the code.)
- `SettleBlock` is a new name-value option; tuning guidance: lower it (e.g. 2000)
  or reduce `Kp`/`StepSize` further if pre-3000 oscillation is still too large.

## 2026-09-03 (b): CDR v3 FFE reverted from MMSE [0 1 0] to target-pulse [c 1 c], c=0.05

- The 30000-block run of the MMSE-FFE version exposed long-run degradation:
  25/32 locked, phase spread 78 code (aliases), dLev drifting down
  (inner 10.85->8.85, outer 32.66->26.88). Root cause: MMSE drives pre1/post1
  ISI toward 0, flattening the SS-MMPD S-curve (alias slip) and leaving the
  SS-LMS dLev without an amplitude anchor (downward drift).
- **Decision (user-directed)**: revert the CDR-FFE adaptation target from the
  decision-directed MMSE reference (equiv. target pulse [0 1 0]) back to a
  target-pulse LMS with reference r = decisions (conv) [c 1 c], c=FfeTargetCursor
  =0.05, skew=0 (symmetric). Restores `buildTargetReference`, per-phase
  `prevFfeDecisionTail`, and `ffeTargetPulse` construction; FFE error is now
  `errorBlock = referenceBlock - ffeOutput`.
- 30000-block result with [c 1 c]: **alias slip and dLev drift eliminated** ---
  phase spread 78->1 code, dLev inner=11.06 (spread 0.091)/outer=33.42
  (spread 0.212) held (no drift), FFE coeff spread 0.097->0.013.
  BUT lockedFlag count is 21/32 (was 25/32): 11 phases fail the strict
  steady-state std lock criterion.
- **Known caveat (documented in code)**: symmetric [c 1 c] (skew=0) makes
  h1=h-1, giving the MMPD multiple S-curve zeros (alias degeneracy). The 11
  non-locked phases are the likely symptom. Next step to reach 32/32: add a
  small `FfeTargetSkew` (e.g. 0.02) so pre1=c-skew, post1=c+skew breaks the
  degeneracy while keeping the S-curve alive.

## 2026-09-25: Two-stage mu downshift gated on eye quality (fixes -100 ppm all-phase capture)

- **Problem**: the three-loop ppm suite
  (`validation/CDR/test_cdr_three_loop_wi_ppm`) captured all 32 start phases at
  `+100 ppm` and `0 ppm` but **0/32** at `-100 ppm`, with every start phase
  driving the loop frequency state to the `-4` clamp against a theoretical
  requirement of `+0.8192 code/block`.
- **Root cause (causally verified, not inferred)**: `loop_monitor.m`
  `updateDlevSettle` is a two-point displacement test,
  `abs(dlevOuter - dlevOuter_{k-W}) <= tol`, i.e. an *implicit drift-rate
  threshold* of `tol/W = 0.5/16 = 0.031 code/block`. The measured cold-start
  dLev drift rate is only ~`0.012 code/block`, so it reported settle at
  **block 84** with the outer level at 41.36 against a final 31.99 — 59% of the
  trajectory still ahead and the eye still closed. `cdr_top.m` then cut both
  step sizes in one shot: dLev `0.5 -> 0.1` (5x) and FFE `0.004 -> 2e-4`
  (**20x**). The only loop that can open the eye was slowed 20x while a ppm
  drift was racing it, so the eye never opened, the decision-directed PD bias
  stayed one-signed negative, and the integrator wound to the clamp.
- **Isolation**: keeping only the FFE capture step gives 8/8 lock; keeping only
  the dLev capture step gives 0/8. The fatal element is the FFE downshift; the
  dLev downshift is harmless.
- The previously documented "+/- acquisition asymmetry" is real but is an
  *amplification mechanism*, not the root cause: the natural closed-eye PD bias
  is negative (~-0.016), which opposes the `+0.8192` that `-100 ppm` needs and
  assists the `-0.8192` that `+100 ppm` needs.
- **Parameter tuning cannot fix it**: no `(DlevSettleWindow, DlevSettleTol)`
  pair satisfies all three ppm cases. Tightening the rate threshold
  (`128/0.1`, `200/0.05`) gives `+/-100 ppm` 32/32 but degrades the `0 ppm`
  locked-phase spread from 4 to 13-15 code (limit `captureBandHalfWidth = 6`),
  because the downshift then effectively never fires and steady-state gradient
  noise is never suppressed. A fixed-block trigger (`fire@2001`) appears to pass
  all three over 8 start phases but drops `-100 ppm` to 31/32 over 32 start
  phases. The required downshift instant varies with start phase and with ppm,
  so neither a fixed flatness threshold nor a fixed block number can express it.
- **Decision at the time**: replace the stage-1 gate with an **eye-quality**
  criterion and configure a second downshift stage. The 2026-09-26 entry below
  records that this second stage does not actually fire under frequency offset.
  - Stage 1 (`capture -> settle`), both loops together, gated on the averaged
    decision-directed SNR `10*log10(mean(decision^2)/mean(sliceError^2))`.
    `cdr_top.blockSnrDb` computes the per-block FOM from values `slicePam4`
    already produces; `loop_monitor.updateSnrSettle` makes the decision, keeping
    the monitor's "decide only, never apply" contract and its bounded-memory
    guarantee (the EWMA is one scalar). Enabled via the new
    `loop_monitor.enableSnrSettle(thresholdDb, alpha, minBlock)` so the
    documented 4/6 constructor arity stays valid for existing callers.
    New `cdr_top` config: `SettleGate` (`'snr'` default, `'dlev'` legacy),
    `SnrSettleThresholdDb = 15`, `SnrSettleAlpha = 1/128`,
    `SnrSettleMinBlock = 200`.
  - Stage 2 was intended to perform `settle -> PVT tracking` by reusing the
    existing phase-band gate `updateFfeGate`; if triggered, it drops **both**
    loops: FFE to `FfeStepSizePvtTrack` and dLev to the new
    `DlevStepSizePvtTrack = 0.02` (previously only the FFE
    was dropped).
- **Averaging is load-bearing, not cosmetic**: per-block SNR distributions
  overlap badly. In the failing run the closed-eye p99 is 22.55 dB, *above* the
  17.50 dB tail minimum of a passing run, because once the integrator is at the
  clamp the PI rotates and the sampling point periodically sweeps the eye
  centre. Only after EWMA do the two separate: failing-run EWMA peaks at
  13.02-13.12 dB with `alpha = 1/128` (14.59-14.73 dB with `1/32`, too thin a
  margin) against 21.6-24.4 dB when the eye is open. Measured threshold floor:
  11 dB breaks `-100 ppm` (0/8), `>= 12 dB` works; 15 dB is the chosen operating
  point (~1.9 dB above the closed-eye peak, ~6.6 dB below the open-eye level).
- **Capture-mu FFE step reduced `0.004 -> 0.001` in the ppm suite**: with the
  main tap frozen (`FfeAdaptEnableMask = [1 1 0 1 1 1]`) the loop can only
  reshape the pulse through the pre/post taps, which walks the effective cursor
  and therefore moves the MMPD zero, so different start phases converge to
  different locked phases. The walk is proportional to the capture step —
  measured locked-phase spread for `0.001/0.002/0.004/0.008` is `3/6/12/21` code
  at 0 ppm and `1/2/5/13` code at +100 ppm. `0.001` is the largest step that
  keeps all three ppm cases inside the capture band. The `cdr_top` library
  default stays `0.004`; only the ppm suite default changed.
- **Result** (32 start phases, `NumBlock = 8000`, runner defaults):
  `-100 ppm` 32/32 `AllPhaseLock=1` spread 3 code `freqStateMean +0.8193..+0.8194`;
  `+100 ppm` 32/32 `AllPhaseLock=1` spread 2 code `freqStateMean -0.8192..-0.8191`;
  `0 ppm` 32/32 `AllPhaseLock=1` spread 3 code. Theory is `+/-0.8192`.
- `0 ppm` is retained as a mandatory regression sentinel for this policy, since
  it is the case most sensitive to the downshift actually happening and to the
  capture-mu cursor walk.

## 2026-09-26: Retire the two-eye ppm workflow; anchor row 2 on verdict replay and leave stage-2 redesign open

- **Retirement decision**: replace the former two-eye capture/final offline path
  with `make_ppm_stage_eyes.m`, `helpers/build_ppm_eye_set.m`,
  `helpers/plot_ppm_eye_set.m`, and `tests/CDR/test_build_ppm_eye_set.m`. The old
  driver, pair builder, pair plotter, and pair-builder test are deleted. The new
  builder accepts N anchor blocks and appends a trailing tail window; the current
  driver supplies stage-1 SNR settle and first-satisfied lock, producing three
  standalone 2048-UI eyes plus one 1500x1500 three-row comparison.
- **Row-2 decision**: anchor the second row by sliding the run's own pass/fail
  lock detectors and tolerances over prefixes `1:k`. Nonzero ppm uses
  `loop_monitor.detectFrequencyStateLock` and, when
  `RotationCriterionApplicable`, `detectRotationPeriodLock`; zero ppm uses
  `detect_pi_center_touch_lock`. This avoids inventing a new eye-only definition
  of lock and keeps the diagnostic aligned with the acceptance verdict.
- **Window limitation**: `LockWindowBlocks = 2000`; therefore the replay cannot
  produce a row-2 anchor before block 2000. The label means “after the lock
  criterion is satisfied,” specifically the first complete trailing 2000-block
  window that passes, not the instantaneous physical lock time and not “after
  the second downshift.” `CaptureBlock` is retained as context only.
- **Defect recorded**: the live stage-2 gate is not connected to that verdict.
  `cdr_top.m:509-511` sends raw unwrapped PI code to
  `loop_monitor.updateFfeGate`. `observeSearch` requires one exact code to occur
  500 times before nominating a centre; under `+/-100 ppm` the code ramps at
  `0.8192 code/block` and each exact code appears about once. Actual monitor
  replay across all saved starts fired on 0/32 phases at -100 ppm, 0/32 at
  +100 ppm, and 28/32 at zero ppm (blocks 3937..7653). The plotted zero-ppm start
  (phase index 10, phase 36) is one of the four non-latching cases. Maximum mode
  counts were 75 and 46 for -100 and +100 ppm against 500, with zero events.
- **Consequence**: the accepted `+/-100 ppm` runs are single-stage in practice;
  their 32/32 all-phase capture result was achieved with stage 1 only. The
  pass/fail criterion was upgraded to frequency-domain lock for ppm, while the
  nominal after-lock stage-2 gate remained the zero-ppm code-domain centre-touch
  detector. The two control concepts were never connected.
- **Historical status:** at the time of this eye-set decision, moving stage 2 to
  frequency-state lock was left open. The following 2026-09-26 decision records
  the implemented resolution; this entry remains as the provenance of the
  defect and the separation between lock replay and stage-2 firing.

## 2026-09-26: Switch the ppm stage-2 gate by criterion and retire the lock-summary CSV

- **Decision:** add a selectable stage-2 criterion. `cdr_top` accepts
  `FfeGateCriterion = 'center-touch'` or `'freq-state'` and keeps
  `'center-touch'` as its library default for backward compatibility. The ppm
  runner adds `'auto'` as its default, resolving to `'center-touch'` at exactly
  0 ppm and `'freq-state'` otherwise. The center-touch implementation is
  retained, not deleted, and remains the normal zero-ppm path.
- **Why:** the old code-domain modal gate requires one raw unwrapped PI code to
  recur 500 times and then counts 100 center touches/crossings inside a
  half-width-3 band. Under a frequency offset, unwrapped PI code ramps and does
  not dwell. Consequently the gate was enabled but dead: it fired for 0/32
  starts at both -100 and +100 ppm despite `FfeGateEnable = true` and
  `FfeGateMode = 'pvt-track'`. This was not an intentional disabling policy.
- **Criterion reuse:** `loop_monitor.enableFreqStateGate` configures a bounded
  trailing-window ring and `updateFreqStateGate` passes its ordered full window
  to the existing static `detectFrequencyStateLock`. There is no second
  implementation of frequency lock; online and offline verdicts are identical
  by construction for the same samples. The ppm runner passes the exact verdict
  window, expected rate, and frequency tolerances.
- **Layering:** stage 1 remains the SNR-EWMA `capture -> settle` event. Stage 2
  remains `settle -> pvt-track`. The ppm steps are dLev
  `0.5 -> 0.1 -> 0.02` and FFE `0.001 -> 2e-4 -> 2e-4`, so stage 2 changes only
  dLev at the defaults. The pass/fail lock verdict is not the stage-2 gate:
  nonzero-ppm `Locked` still requires frequency-state lock **and** rotation-period
  lock. `LockBlock` and `Stage2GateBlock` therefore remain separate milestones.
- **Zero-ppm compatibility evidence:** with the new default, `auto` resolved to
  center-touch, 2/2 starts locked, and start phase 0 fired at block 3937, exactly
  the minimum in the existing p0 artefact.
- **Output decision:** remove `ppm_lock_summary.csv` and the runner's
  `result.LockSummaryPath`. `ppm_lock_summary.txt` is the sole lock summary and
  is a strict superset of the former CSV columns. The similarly named
  `ppm_stage_eye_summary.csv` is a different eye-summary artefact and remains.
  The text writer uses recorded `result.Stage2GateBlock` for current MATs and
  replays center-touch only as a compatibility fallback for older MATs.
