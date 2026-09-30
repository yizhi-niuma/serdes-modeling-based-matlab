# CDR three-loop capture under a frequency offset (ppm) -- v1 (updated TI ADC)

> **v1 variant.** This suite is a mirror of `test_cdr_three_loop_wi_ppm` with the
> only change being the TI ADC model: the runner loads `ti_adc_top` (and its
> `ti_adc_core` / `ti_adc_clock` / `sar_adc_core` siblings) from
> `src/ADC_model_HSY_2609/TI_ADC` (the intern's updated model) instead of the
> baseline `src/ADC/TI_ADC`. The public ADC interface is unchanged, so the runner
> and helpers are unmodified apart from the path-setup call name. Under the
> runner's ideal ADC configuration (`VL=-4, VH=4, N=7`, no skew/jitter/noise) the
> updated model produces bit-identical codes to the baseline (see
> `result/adc_equivalence/` and `result/consistency/`), so v1 results match the
> baseline. Because the ADC classes share names with the baseline suite, run v1
> in its own MATLAB session.

Validates whether the three concurrent CDR loops (SS-MMPD timing, dLev level,
CDR-FFE SS-LMS) achieve all-initial-phase capture when the receiver sampling
clock has a frequency offset, as required by Ethernet (+/-100 ppm).

## Directory layout

| Location | Purpose |
|---|---|
| `setup_cdr_three_loop_wi_ppm_v1_paths.m` | Session-local explicit path setup anchored to this file (points ADC at `src/ADC_model_HSY_2609/TI_ADC`) |
| `src/cdr_three_loop_ppm/cdr_three_loop_ppm.m` | The ppm runner (derived from `cdr_dlev_cdrffe_sslms_v4`) |
| `result/cdr_three_loop_ppm_p100/` | +100 ppm outputs (figures, `.mat`, `ppm_lock_summary.txt`, notes) |
| `result/cdr_three_loop_ppm_m100/` | -100 ppm outputs |
| `result/cdr_three_loop_ppm_p0/` | 0 ppm baseline / regression-sentinel outputs |

The runner reuses the sibling suite helpers `detect_pi_center_touch_lock` and
`select_slowest_pi_capture` (from `../test_cdr_dlev_cdrffe/helpers`) rather than
duplicating them; the setup adds that directory to the path.

## Frequency-offset injection (scheme A, RX-clock model)

The cached TX waveform is never resampled: one data symbol always occupies
exactly 128 cached samples. The offset appears as the RX sampling step, so each
RX UI the read pointer advances `128*(1+delta)` cached samples with
`delta = FreqOffsetPpm*1e-6`. Because `128*(1+delta)` is not an integer, the
exact cumulative drift is kept in floating point and rounded to the 128x sample
grid only once, when the ADC block start is formed
(`round(driftRatePerBlockCode*(blockIndex-1))`). Rounding the cumulative value
(never the per-block increment) bounds the quantization error to `+/-0.5`
sample `= +/-1/128 UI`, on par with the PI resolution. Within one 64-UI block
the 64 samples are still 128 apart; the `<=0.82` sample block-internal drift is
not modelled. `cdr_top` never sees the offset — it is purely a caller-side
address term, so the DSP core stays frequency-offset agnostic.

At 100 ppm the steady timing rate the loop must supply is
`0.8192 code/block` (one full 128-code PI rotation every `156.25` blocks).

## Lock criteria (switchable; the zero-offset one is retained)

- `FreqOffsetPpm == 0`: the modal center-touch criterion
  (`detect_pi_center_touch_lock`) as in v4 -- the PI code dithers around one
  fixed code.
- `FreqOffsetPpm ~= 0`: two frequency-domain criteria added to
  `src/CDR/loop_monitor.m`:
  1. `loop_monitor.detectFrequencyStateLock` -- the loop integrator frequency
     state has a constant tail-window mean (first/second half agree, low std)
     whose magnitude matches the expected drift rate.
  2. `loop_monitor.detectRotationPeriodLock` -- the PI code rotation period
     (blocks per UI slip) is constant (low coefficient of variation), i.e. the
     loop is tracking rather than still acquiring.

  Both must hold for a start phase to be declared locked.

The `result.PiTrackingErrorTrace` and `cdr_pi_tracking_error.fig` show the PI
actual code minus the ideal offset-compensated code (a diagnostic only, not a
lock criterion): flat once tracked, a ramp while still acquiring.

## Three-tier mu schedule and switchable stage-2 gate

The runner defaults to `FfeInitMode = 'planB'` (cold start `[0 0 1 0 0 0]`) and
still reaches 32/32 at both offset signs. An earlier revision of this file
claimed a warm `planA` start was *required* for negative ppm; that was wrong.
The real obstacle was the stage-1 mu-downshift gate, not the initial taps.

- Stage 1 (`capture -> settle`, both loops) is gated on eye quality:
  `SettleGate = 'snr'` triggers when the EWMA of the per-block decision-directed
  SNR `10*log10(mean(decision^2)/mean(sliceError^2))` crosses
  `SnrSettleThresholdDb` (15 dB, `SnrSettleAlpha = 1/128`,
  `SnrSettleMinBlock = 200`).
  The legacy gate (`SettleGate = 'dlev'`) is an outer-dLev displacement test,
  i.e. an implicit drift-rate threshold `DlevSettleTol/DlevSettleWindow`
  `= 0.031 code/block`. The measured cold-start dLev drift is ~`0.012`, so it
  declared settle at block 84 with 59% of the dLev trajectory still ahead and cut
  the FFE step 20x while the eye was closed -- which is what made `-100 ppm` fail
  from every start phase.
- The schedule has three tiers and two events: `capture -> settle -> pvt-track`.
  At suite defaults, dLev uses `0.5 -> 0.1 -> 0.02`, while FFE uses
  `0.001 -> 2e-4 -> 2e-4`; the second event therefore changes only dLev.
- Stage 2 is criterion-switchable through `FfeGateCriterion`. The runner default
  `'auto'` resolves to `'center-touch'` at exactly 0 ppm and `'freq-state'`
  otherwise. The retained center-touch path is the raw unwrapped-PI-code modal
  test (`500` mode occurrences, `100` events, half-width `3`). It was enabled but
  dead at `+/-100 ppm`, because a ramping PI code never dwells on one code. The
  frequency-state path uses the same window, expected rate, and tolerances as
  the offline frequency-state lock verdict.
- `FfeStepSize` defaults to `0.001` here, 4x below the `cdr_top` library default.
  The main tap is frozen (`FfeAdaptEnableMask = [1 1 0 1 1 1]`), so the loop
  reshapes the pulse only through pre/post taps, which walks the effective cursor
  and moves the MMPD zero. Locked-phase spread scales with the capture step:
  `3/6/12/21` code at 0 ppm for `0.001/0.002/0.004/0.008`.

`0 ppm` must be run alongside `+/-100 ppm`: it is the case most sensitive to the
downshift actually happening and to cursor walk, so it is the regression sentinel
for this policy. Tightening the legacy gate instead passes `+/-100 ppm` while
pushing the `0 ppm` spread to 13-15 code (limit `captureBandHalfWidth = 6`).

## Offline three-stage FFE eyes

`make_ppm_stage_eyes.m` rebuilds three 2048-UI eyes from each saved result
directory without rerunning the CDR simulation:

1. **after the stage-1 SNR mu downshift** -- the first block at or after
   `SnrSettleMinBlock = 200` whose decision-directed SNR EWMA (`alpha = 1/128`)
   reaches `SnrSettleThresholdDb = 15 dB`; the driver replays the saved
   `SnrDbTrace` exactly as `loop_monitor.updateSnrSettle` does;
2. **after the lock criterion is first satisfied** -- the first block `k`
   for which the trailing `LockWindowBlocks` slice satisfies the run's own
   pass/fail detectors and tolerances: `loop_monitor.detectFrequencyStateLock`,
   plus `detectRotationPeriodLock` when `RotationCriterionApplicable`, for
   nonzero ppm, or `detect_pi_center_touch_lock` at zero ppm; and
3. **final** -- the last 2048 UI of the run.

Row 2 is deliberately labelled **after the lock criterion is satisfied**, not
"after the second downshift". `LockWindowBlocks = 2000`, so a faithful sliding
replay cannot decide before block 2000. Its anchor means the first block at which
the trailing 2000-block window satisfies the criterion, not the physical instant
at which the loop locked.

The saved `cdr_three_loop_ppm_result.mat` contains the required per-block state:
`FfeCoeffTrace` (`[nPhase x nBlock x nTap]`), `DriftSampleTrace`,
`PhaseCodeTrace`, `UiSlipTrace`, and `EyePhaseUnwrappedTrace`. New results also
save `AdcBlockUi` and `CdrFfePreTapCount`; the driver retains documented legacy
fallbacks for older MAT files. The ppm builder reconstructs each zero-based
sample address as

```text
absSample0(k) = (BaseUi + (k-1)*AdcBlockUi + UiSlipTrace(k))*SamplesPerUi
                + PhaseCodeTrace(k) + DriftSampleTrace(k)
blockStartUi(k) = floor(absSample0(k)/SamplesPerUi)
```

and checks every block with zero tolerance:

```text
mod(absSample0, SamplesPerUi) ==
    mod(EyePhaseUnwrappedTrace, SamplesPerUi)
```

A disagreement raises `build_ppm_eye_set:InconsistentAddressTrace`. This couples
the offline address reconstruction to the saved physical eye-phase trace rather
than silently accepting a later runner address change. The real `-100 ppm` run
satisfied the guard with maximum error zero.

`helpers/build_ppm_eye_set.m` accepts N anchor blocks and appends one trailing
tail window. Every anchor uses its own block's FFE coefficient snapshot; the
final eye uses the final-block snapshot. These are fixed-coefficient offline
views, not a replay of coefficients adapting block by block. The sibling
`build_cdr_ffe_eye` remains the single implementation of ADC quantization,
fixed-FFE application, and 2-UI density. `helpers/plot_ppm_eye_set.m` writes one
standalone figure per eye and a deliberately large 1500x1500 M-row comparison.
Adjacent 2-UI density columns overlap and are not independent samples.

The marker is the tracked physical eye phase, `EyePhaseUnwrapped = unwrapped PI
code + drift`, not the raw wrapped PI code. Its mean, extrema, and span are
formed in unwrapped coordinates before being wrapped to one UI, so spans remain
valid across the `0/SamplesPerUi` boundary. The layering is:

```text
make_ppm_stage_eyes
  -> helpers/build_ppm_eye_set
       -> sibling build_cdr_ffe_eye
  -> helpers/plot_ppm_eye_set
  -> helpers/write_ppm_lock_summary_txt
```

From the suite directory, rebuild all three saved runs with defaults:

```matlab
make_ppm_stage_eyes();
```

Or select one result directory:

```matlab
make_ppm_stage_eyes('ResultDirs', {'cdr_three_loop_ppm_m100'});
```

Each selected directory receives:

- `cdr_ffe_eye_at_snr_settle_2048ui.fig`
- `cdr_ffe_eye_at_lock_2048ui.fig`
- `cdr_ffe_eye_final_2048ui.fig`
- `cdr_ffe_eye_stage_comparison.fig`
- `ppm_stage_eye_summary.csv`
- `ppm_lock_summary.txt`

When `SaveOutputs` is true, the driver calls
`helpers/write_ppm_lock_summary_txt.m` automatically. Its plain-ASCII,
human-readable output has one row for every start phase (all 32 in the default
sweep) and is a strict superset of the former `ppm_lock_summary.csv` columns.
The CSV was removed and is no longer written by the runner; the text file is the
sole lock summary. A header and column definitions precede the main table
(`StartPhase`, `Locked`, `FreqStateMean`, `RotationPeriod`, `LockPhase`,
`Stage1Block`, `Stage1Phase`, `LockBlock`, `LockPhaseAtBlk`, `Stage2Block`). A
supplementary table retains the other former CSV columns (`FreqLock`,
`RotationLock`, `SlewSaturated`, `AcquisitionBlock`, `RotationCov`,
`DeltaCodeMeanAbs`, `PendingCodeMeanAbs`), followed by aggregates and a closing
stage-2 note. `ppm_stage_eye_summary.csv` is a separate eye-summary file and is
still produced.

Every phase code uses the runner-compatible definition
`mod(round(EyePhaseUnwrappedTrace(i, b)), SamplePerSymbol)`: eye phase is the
unwrapped PI code plus drift, wrapped to one UI. `Stage1Block` is the stage-1
SNR-EWMA settle block; `LockBlock` is the first block where the pass/fail lock
criterion succeeds over a trailing `LockWindowBlocks` window; and `Stage2Block`
is where `FfeGate` actually fired. The last two are different milestones and
must not be conflated.

The driver automatically deletes the retired two-eye artifacts. The existing
center-touch run figures and `cdr_three_loop_ppm_result.mat` were not regenerated
for the gate rewire; the three obsolete `ppm_lock_summary.csv` files were
removed separately.

### Three distinct block markers -- do not conflate them

| marker | domain | definition | what it drives |
| --- | --- | --- | --- |
| `CaptureBlock` | phase | tail-centred retrospective capture-band result retained by the runner | context only; no longer an eye anchor |
| `SnrSettleBlock` | eye quality | first block at or after 200 whose decision-directed SNR EWMA (`alpha = 1/128`) reaches 15 dB | stage-1 mu downshift and row-1 eye anchor |
| `LockBlock` | verdict (`frequency/rotation` at nonzero ppm; centre-touch at zero ppm) | first `k >= LockWindowBlocks` at which the same detectors and tolerances used by pass/fail succeed on the trailing `LockWindowBlocks` slice | row-2 eye anchor; lower-bounded by block 2000 |
| `Stage2GateBlock` | selected stage-2 gate (`center-touch` or `freq-state`) | recorded block where the live selected criterion first triggered, or `NaN` | stage-2 mu downshift status only; **not** the row-2 anchor |

`CaptureBlock` is not an SNR criterion or the lock criterion. It is retained as
context in `ppm_lock_summary.txt`, but does not select any eye window.

Measured on the saved 8000-block, 32-start-phase, PRBS22 default runs; the
default row is the slowest-capture start phase:

| ppm | result directory | phase index | start phase | `CaptureBlock` (context) | SNR-settle anchor | lock anchor | frequency-only lock | stage-2 fire |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| -100 | `cdr_three_loop_ppm_m100` | 4 | 12 | 3787 | 3864 | 6128 | 6128 | `NaN` |
| 0 | `cdr_three_loop_ppm_p0` | 10 | 36 | 768 | 961 | 2732 | `NaN` (centre-touch mode) | `NaN` |
| +100 | `cdr_three_loop_ppm_p100` | 23 | 88 | 511 | 526 | 2593 | 2593 | `NaN` |

| ppm | marker code: settle / lock / final | span: settle / lock / final | start UI: settle / lock / final | settle-to-final delta | lock-to-final delta |
|---:|---:|---:|---:|---:|---:|
| -100 | 100.625 / 104.34375 / 104.4375 | 1 / 3 / 2 | 247511 / 392407 / 510231 | 3.8125 | 0.09375 |
| 0 | 113 / 113.78125 / 114.15625 | 0 / 1 / 2 | 61695 / 175039 / 510207 | 1.15625 | 0.375 |
| +100 | 118.96875 / 119.125 / 119.71875 | 2 / 2 / 2 | 33908 / 166196 / 510260 | 0.75 | 0.59375 |

In all three cases the residual cursor walk from the lock block to the end of the
run (`0.09 / 0.375 / 0.59` code) is much smaller than from the stage-1 settle
block to the end (`3.81 / 1.16 / 0.75` code), so by the time the lock criterion
is satisfied the taps have essentially stopped moving. This observation does
not establish an adaptation duration, step-size explanation, mechanism, or a
monotonic ordering across the three cases.

### Stage-2 gate rewire and measured A/B

The saved 32-phase artefacts above predate the rewire and were produced with the
center-touch gate. Their historical replay therefore remains:

- `-100 ppm`: **0/32** stage-2 fires; maximum `ModeOccurrences = 75`;
- `+100 ppm`: **0/32** stage-2 fires; maximum `ModeOccurrences = 46`;
- `0 ppm`: **28/32** fires at blocks 3937..7653.

At nonzero ppm, center-touch was enabled but dead because the raw unwrapped PI
code ramps continuously. The implemented `freq-state` choice instead keeps a
`LockWindowBlocks` ring and calls the same `detectFrequencyStateLock` used by the
offline verdict. This does **not** wire the complete verdict into stage 2:
nonzero-ppm `Locked` still also requires `detectRotationPeriodLock`. Therefore
`LockBlock` and recorded `Stage2GateBlock` are distinct.

Measured with start phases `0/32/64/96` and `SaveOutputs = false`:

| ppm | criterion | locked | stage 2 fired | stage-2 blocks | mean `FreqStateMean` |
|---:|---|---:|---:|---:|---:|
| -100 | `center-touch` | 4/4 | 0/4 | none | 0.819187 |
| -100 | `freq-state` | 4/4 | 4/4 | 4977..6070 | 0.819207 |
| +100 | `center-touch` | 4/4 | 0/4 | none | -0.819229 |
| +100 | `freq-state` | 4/4 | 4/4 | 2570..2762 | -0.819238 |

Expected magnitude is 0.8192 code/block. Lock is unchanged at 4/4 in every arm,
tracking differs by about `1e-5 code/block`, and -100 ppm fires later than +100
ppm. At zero ppm, `auto` resolves to center-touch; 2/2 locked and start phase 0
fired at block 3937, matching the existing p0 minimum.

`test_freq_state_gate` passes 12/12 (including exact online/offline fire blocks
161/40/40/59 and never-lock agreement), `test_loop_monitor` 15/15,
`test_cdr_top` 6/6, and `test_cdr_top_configured` 12/12. The full `tests/CDR`
sweep is **16 passed / 2 failed**. The failures are the pre-existing
`test_cdr_ffe` (`cdr_ffe:MainTapUpdate`) and `test_cdr_ffe_loop`
(`cdr_ffe_loop:MainTapAdaptEnabled`) failures, reproduced identically on a clean
HEAD worktree; they were not fixed.

## Phase-interpolator nonideality (`PiNonideal`)

`PiNonideal` selects the PI phase table and defaults to `'ab_constant'`, the
`cdr_pi` `a+b=1`/`atan2` model. `'ideal'` restores the exactly linear table.

The option only bites because the harness takes its in-UI sampling offset from
the phase table, `round(PhaseInterpolator.getLocalIndex())`, instead of from the
raw `CodeWrapped`. With the raw code a nonideal table would be built by `cdr_pi`
and then discarded. Under `'ideal'` the table is the identity, so the
expression equals `CodeWrapped` and the addressing is bit-exact with the
pre-2026-09-26 harness.

At `PiNumBit = 7` and 128 samples/UI, where 1 LSB = 1 code = 1 waveform sample,
the `ab_constant` INL is `+/-1.445352 LSB` (2.890703 LSB pk-pk, 1.037876 LSB
RMS). The cache is addressed in integer samples, so the offset is rounded and
`round(localIndex) - code` takes three values `{-1, 0, +1}` across 52/24/52
codes: 104 of 128 codes sample one sample (`1/128 UI`) away from the ideal-PI
address. The same rounding annihilates INL below roughly 0.7 LSB pk-pk, so
sub-LSB INL cannot be studied without fractional interpolation of the cache.

Measured cost, PI table as the only variable (32 starts, `NumBlock = 15000`,
`SaveOutputs = false`):

| ppm | `PiNonideal` | locked | common phase / spread | `mean|PendingCode|` |
|---:|---|---:|---|---|
| -100 | `ideal` | 32/32 | 106 / 3 | 0.0855..0.1325 |
| -100 | `ab_constant` | 32/32 | 107 / 3 | 0.1805..0.2720 |
| +100 | `ideal` | 32/32 | 120 / 2 | 0.1220..0.1985 |
| +100 | `ab_constant` | 32/32 | 121 / 3 | 0.3320..0.4625 |

All-phase lock and tracking accuracy are unaffected; the locked-phase centroid
moves one code. What the nonideal table costs is slew margin. An 8-start probe
shows the positive ceiling is PI-dependent: `+110 ppm` is 8/8 with `'ideal'`
but **0/8 with `'ab_constant'`**, where all eight starts trip
`SlewSatPendingTol = 0.5` (`mean|PendingCode| = 0.7715..1.0240`) while
`mean|DeltaCode|` is `0.9005..0.9015` in both arms, i.e. the failure is slew
backlog rather than the `MaxDeltaCode = 1` ceiling. `+/-100 ppm` is met with the
nonideal PI, with under 10 ppm of positive margin above it.

Convergence figures mark both mu downshifts. The stage-2 label names the armed
gate (`gate: freq-state` or `gate: center-touch`) rather than calling the event
a lock, since only the freq-state gate is part of the lock criterion.

## Run

From the repository root:

```matlab
addpath(fullfile(pwd, 'validation', 'CDR', 'test_cdr_three_loop_wi_ppm_v1'));
setup_cdr_three_loop_wi_ppm_v1_paths();
result = cdr_three_loop_ppm('FreqOffsetPpm',  100);   % +100 ppm, default starts
result = cdr_three_loop_ppm('FreqOffsetPpm', -100);   % -100 ppm
result = cdr_three_loop_ppm('FreqOffsetPpm',    0);   % 0 ppm sentinel
```

Full acceptance sweep (32 start phases), which is what produced the current
artefacts on 2026-09-26 under `PiNonideal = 'ab_constant'` and the `auto` gate.
Re-running it reproduces the same aggregates; both sweeps agreed on all 96
per-start lines:

```matlab
for ppm = [-100, 0, 100]
    cdr_three_loop_ppm('FreqOffsetPpm', ppm, 'StartPhaseStep', 4);
end
make_ppm_stage_eyes();   % offline three-eye rebuild + lock-summary refresh
```

```matlab
for ppm = [-100, 100, 0]
    cdr_three_loop_ppm('FreqOffsetPpm', ppm, 'NumBlock', 8000, ...
        'StartPhaseStep', 4, 'SaveOutputs', true);
end
```

Fast smoke:

```matlab
cdr_three_loop_ppm('FreqOffsetPpm', 100, 'NumBlock', 4000, ...
    'StartPhaseList', [16 64], 'SaveOutputs', false);
```

`NumBlock` derives `AnalysisNumUi` (including the two-sided ppm drift margin)
automatically. `StartPhaseStep` (default 16 -> 8 starts) or an explicit
`StartPhaseList` selects the initial-phase sweep. Cache lookup stays under
`validation/CDR/test_cdr/result/<CosimDir>/channel_ctle.mat`.
