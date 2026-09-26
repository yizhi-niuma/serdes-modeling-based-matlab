# Architecture

## Scope

The current modeling scope documented here is limited to:

- `src/TX+Channel`
- `src/AFE`
- `src/ADC`
- `src/CDR`

`src/LinkSim` is historical reference material. It is not the current model architecture and must not be used to infer current implementation status or requirements.

## Current subsystem flow

```text
Voltage symbols
  -> ideal zero-order-hold TX waveform
  -> differential S-parameter channel waveform
  -> fixed CTLE waveform filtering
  -> sampling-phase/index generation (TI ADC clock and future CDR loop)
  -> TAH / TI ADC sampling
  -> SAR ADC conversion
  -> ADC code and reconstructed voltage

CDR data-symbol decision + edge-bit decision
  -> digital NRZ/PAM4 bang-bang phase detector
  -> block voter
  -> proportional-integral loop filter
  -> phase-interpolator code update
  -> local sample-index offset
  -> TI ADC clock/sampler
```

The ADC and CDR components exist, but a closed-loop CDR-to-ADC top-level model has not yet been assembled in the current source.

The CDR timing path uses a dedicated FFE rather than reusing the data-recovery
FFE/DFE path. The CDR FFE is implemented as a standalone upstream component;
its slicers and connection to the current digital CDR top level remain external.

## TX and channel module: `src/TX+Channel`

- `tx_channel.m`: minimal batch symbol-source and S-parameter channel model.
  - Accepts already-mapped finite real voltage symbols.
  - Applies ideal zero-order hold at a configurable integer samples/UI value.
  - Uses the configured four-port Touchstone file as a differential channel.
  - Returns a complete channel waveform and matching time vector for direct CTLE input.
  - Does not implement PRBS generation, symbol mapping, TX FFE, pre-emphasis, jitter, noise, or streaming state.

## AFE module: `src/AFE`

- `ctle.m`: minimal fixed one-zero, two-pole CTLE for MMPD debugging.
  - Processes one complete oversampled waveform per call.
  - Uses 0 dB DC gain and configurable gain at the symbol Nyquist frequency.
  - Defaults to 56 GBd, 128 samples/UI, and 4.5 dB Nyquist peaking.
  - Accepts samples/UI and derives sample rate from symbol rate internally.
  - Directly exposes the continuous-time transfer function and uses `lsim` for waveform processing.
  - Does not implement adaptation, AGC/VGA, or plotting.

## ADC modules

### Current TI ADC stack: `src/ADC/TI_ADC`

- `sar_adc_core.m`: single-ended N-bit SAR ADC core.
  - Instantaneous scalar and vector conversion APIs.
  - Debug and fast conversion paths.
  - Capacitor mismatch, gain, comparator offset/noise, and per-bit offset controls.
  - Optional trace capture and input/range validation.
- `ti_adc_core.m`: M-lane time-interleaved ADC wrapper.
  - Owns one SAR ADC object per lane.
  - Converts one M-sample block at a time.
  - Supports lane gain, offset, skew metadata, capacitor mismatch, comparator noise, and bit offsets.
- `ti_adc_clock.m`: converts a CDR phase index into lane sample indices.
  - Supports common and per-phase fixed skew.
  - Supports Gaussian rising-edge jitter.
  - Can generate data and edge sample indices for CDR use.
- `ti_adc_top.m`: integrates `ti_adc_clock` and `ti_adc_core`.
  - Samples a waveform block using generated indices.
  - Supports local input margins for skew/jitter.
  - Adds TAH-group fixed skew and jitter configuration.
  - Exposes full and fast block-conversion paths.

### Clock-driven differential SAR channel: `src/ADC/SAR_ADC_channel`

- `sar_adc_tah.m`: differential track-and-hold state model.
- `sar_adc_core.m`: bit-by-bit differential SAR core driven by clock edges.
- `sar_adc_channel.m`: combines TAH and SAR core.

One conversion consists of a track/sample phase followed by N SAR decision phases. The previous output is held until conversion completes.

### Alternative SAR implementations

- `src/ADC/SAR_ADC_core`: single-ended SAR ADC plus dynamic/static metric utilities.
- `src/ADC/SAR_ADC_core_complex`: differential held-output SAR ADC plus metric utilities.
- `src/ADC/sar_adc_ref/sar_adc_nb.m`: older/reference multi-instance SAR model.

These implementations are retained for comparison. The TI ADC-local `sar_adc_core` is the implementation currently integrated into `ti_adc_core` and `ti_adc_top`.

### ADC waveform studies: `src/ADC/ADC_sample_CTEL_output`

This directory contains CTLE/TX/PRBS waveform inputs, eye-diagram and delay-analysis functions, SAR sampling analysis, and historical generated results. It is validation/study material rather than reusable ADC model code and should eventually move out of `src`.

## CDR modules: `src/CDR`

### `cdr_ffe.m`

Floating-point symbol-spaced FIR for the dedicated CDR path with:

- Default six-tap configuration containing two precursor, one fixed unit main,
  and three postcursor taps.
- Configurable coefficient vector and precursor count.
- Caller-assembled input windows containing postcursor history, the target block,
  and precursor look-ahead.
- Coefficient and FIR state only; cross-block buffering and boundary validity
  remain external.
- Validated and reduced-overhead block processing paths.

### `cdr_ffe_loop.m`

Standalone block LMS adaptation engine with:

- Explicit step size, configurable tap count, main-tap index, block size, and
  adaptation-enable mask.
- Data-decision-error-driven coefficient updates normalized by block size.
- A fixed main tap excluded from adaptation.
- Coefficient deltas applied by the caller after a block, for use by the next block.

### `cdr_pd.m`

Digital bang-bang phase detector with:

- `nrz` and `pam4` modulation modes.
- Digital previous-data, current-edge-bit, and current-data inputs.
- NRZ transition-qualified `+1/-1` phase-error decisions.
- PAM4 encoding `00=-3`, `01=-1`, `10=+1`, and `11=+3`.
- PAM4 phase decisions restricted to the symmetric `00<->11` and `01<->10` transitions used by the reference RTL.
- Configurable output polarity, zero output for invalid transitions, compact input/result debug snapshots, and array-input support.
- A shared vectorized `bbpdFast` decision kernel using numeric mode selection and `int8` phase decisions; validated `bbpd` delegates to it and adds only input checks plus debug-state capture.
- Block-boundary overlap is owned by the future CDR top-level; `cdr_pd` remains stateless apart from its optional debug snapshot.
- The experimental PAM4 `mmpd`/`mmpdFast` paths take an optional trailing `transitionFilter` argument (default `false`): OFF accepts every non-static transition, while ON retains only symmetric `0<->3` and `1<->2` transitions. All accepted transitions have uniform decision magnitude.
- Validated `mmpd` and stateless `mmpdFast` paths with uniform-magnitude `int8` `-1/0/+1` decisions; the `2x` symmetric-transition weighting present at HEAD is intentionally removed here (per user request) so all accepted transitions contribute uniformly, and the weighted-transition path is retired.
- SS-MMPD is not a separate `cdr_pd` method: callers feed sign-derived PAM4 symbols (`0-3`) and error bits (`0/1`) to `mmpd`/`mmpdFast` with `transitionFilter=false`. That uniform-weight path is the SS-MMPD kernel; separate `ssmmpd` methods were redundant and removed.
- CTLE-waveform MMPD validation explicitly composes the PD, voter, loop filter, and PI while carrying symbol/error overlap because the current `cdr_top` public input remains BBPD-specific.

Slicing and equalization are intentionally outside `cdr_pd`; the caller must provide hard digital symbol/edge decisions.

### `cdr_voter.m`

Stateless block voter with:

- One configurable parallel phase-decision block per call; the default block size is 64.
- Linear mode returning the signed sum of the `-1/0/+1` phase decisions.
- Constant mode returning `+K`, `-K`, or zero from the sign of the block sum; the default magnitude is 8.
- Mean mode returning a `double` normalized vote with a configurable denominator: `'auto'` divides by the actual decision count (so boundary blocks shorter than `BlockSize` are handled), or a fixed positive scalar can be supplied. Mean mode accepts `1..BlockSize` decisions; linear and constant keep the strict `== BlockSize` check and `int16` return.
- Validated `vote` and reduced-overhead single-block `voteFast` paths.
- `int16` accumulation and output for linear and constant modes.

The voter does not accumulate across blocks or model the RTL output register. The future CDR top-level owns block scheduling and pipeline latency.

### `cdr_loop.m`

Mode-independent proportional-integral loop filter with:

- One numeric voter error input and one integer PI code-increment output per update.
- Floating-point proportional, integral, and fractional-code residue calculations.
- Configurable integral-state saturation with reverse-error recovery.
- Configurable output slew limit with a default maximum PI increment of one code per block.
- Validated `update` and reduced-overhead scalar `updateFast` paths.

The loop filter does not own voter-mode selection, PI code wrap, UI-slip tracking, RTL fixed-point encoding, or a separate frequency-acquisition path.

### `cdr_pi.m`

Phase-interpolator behavioral model with:

- Configurable PI resolution and samples/UI.
- Wrapped PI code and accumulated full-UI slip.
- Ideal phase table.
- Default `a+b=constant` nonideal phase table.
- User-supplied INL or complete phase tables.
- Phase-to-floating-sample-index lookup.
- Full debug update and reduced-overhead `updateFast` paths.

### `cdr_top.m`

Block-rate digital integration model with:

- Explicit composition of configured `cdr_pd`, `cdr_voter`, `cdr_loop`, and `cdr_pi` objects.
- Cross-block previous-symbol state owned by the top level.
- One PD/voter/loop/PI update per configured voter block.
- The PI phase entering a block exposed separately from the updated phase used by the following block.
- Validated/debug and reduced-overhead fast processing paths.
- Coordinated reset of PD, loop-filter, PI, block index, and previous-symbol state.

The current top-level input is already-sliced digital data-symbol and edge-bit
blocks. It does not yet own waveform sampling, the dedicated CDR FFE, slicers,
or the TI ADC connection. This describes the legacy component-injection path only; the configured mode below owns the CDR FFE and the slicer, but still never the ADC.

### `cdr_top` configured code-domain mode (2026-09-23)

`cdr_top` now also accepts a single configuration struct. That second construction path turns the class into the reusable code-domain CDR DSP core while leaving the legacy five-argument BBPD path byte-for-byte unchanged.

- Owns `cdr_ffe` plus its cross-block window, a static PAM4 slicer (`cdr_top.slicePam4`), `cdr_pd` in MMPD mode, `cdr_voter` in mean mode, `cdr_loop`, `cdr_pi`, `dlev_loop`, `cdr_ffe_loop` and `loop_monitor`.
- Input is one block of chronological, zero-centred ADC codes; output is the next sampling phase through `getSamplingPhase`. The class contains no reference to any ADC model, so the caller keeps waveform access, TI ADC instantiation, lane reordering and absolute UI addressing.
- Models one block of loop dead time caused by the FFE precursor look-ahead: `processBlock` returns `HasOutput = false` while the pipeline fills, and `flush` drains the final pending block with zero future samples.
- Runs the v3 block order exactly: FFE -> slicer -> MMPD -> voter -> loop -> PI -> mu downshift -> dLev -> FFE gate -> FFE SS-LMS write.
- The FFE gate supports `freeze` (stop writing, keep computing raw deltas) and `pvt-track` (keep writing at a collapsed step size). Both the gate and the mu-downshift decisions live in `loop_monitor`, which only reports events; `cdr_top` applies the actions.
- The mu downshift has three step-size tiers and two events: `capture -> settle -> pvt-track`. In the ppm suite, dLev uses `0.5 -> 0.1 -> 0.02`, while the FFE uses `0.001 -> 2e-4 -> 2e-4`; at those defaults the second event changes only dLev. Stage 1 remains gated by `SettleGate`: `'snr'` (default) uses the averaged decision-directed eye SNR through `loop_monitor.updateSnrSettle`, while `'dlev'` selects the legacy outer-dLev displacement test. Stage 2 uses the selectable `FfeGateCriterion`: `'center-touch'` preserves the original unwrapped-PI-code modal test and is the `cdr_top.defaultConfig` value, while `'freq-state'` uses the online frequency-state lock criterion. The per-block eye FOM is `cdr_top.blockSnrDb`, computed from the `decision`/`sliceError` pair `slicePam4` already returns, so no new data path exists.
- `Detector` accepts `bbpd`, `mmpd` and the `ssmmpd` alias; the alias normalizes to `mmpd` because `cdr_pd.mmpd` already requires symbolized inputs and there is no second numerical path.
- Every loop parameter is injected explicitly; missing or invalid fields raise `cdr_top:Invalid<Field>`. `cdr_top.defaultConfig` returns the current v3 aligned starting point.
- Each block output also exports the loop filter's pre-quantization continuous state (`LoopControl`, `LoopFrequencyState`, `LoopCodeResidue`, `LoopPendingCode`). The integer PI code hides sub-code motion, so these are what distinguish a genuine limit-cycle dither from a slow drift.

`ffe_freeze_monitor.m` was renamed to `loop_monitor.m` and moved into `src/CDR`. Besides the FFE write gate it now also owns the causal dLev settle detector (a bounded ring buffer), so `cdr_top` no longer keeps its own `SettleDone` flag or an unbounded dLev history. The monitor only decides; `cdr_top` applies the mu downshift and the gate action.

`loop_monitor` now carries four independent causal detectors: the original FFE center-touch write gate, the legacy dLev settle detector, the eye-quality (SNR) settle detector, and the frequency-state lock gate. The SNR detector is a one-shot EWMA trigger with one scalar of memory; it exists because the dLev displacement test is an implicit drift-rate threshold that a slowly ramping dLev can satisfy while the eye is still closed. The frequency-state gate is enabled separately by `enableFreqStateGate(windowBlocks, expectedRate, meanHalfDiffTol, stdTol, rateTol, minBlock)`. It retains a bounded `windowBlocks` ring, orders the full window oldest-to-newest, and passes that window to the same static `detectFrequencyStateLock` used offline. Thus online and offline frequency-state verdicts are identical by construction for the same trailing window; there is no duplicate criterion. Non-finite samples are skipped and counted in `FreqGateSkippedCount`. Like `enableSnrSettle`, this separate enable call preserves the existing 4/6-argument constructor contract.

`cdr_top` validates `FfeGateCriterion` (`'center-touch'` or `'freq-state'`) plus `FfeGateFreqWindowBlocks`, `FfeGateFreqExpectedRate`, `FfeGateFreqMeanHalfDiffTol`, `FfeGateFreqStdTol`, `FfeGateFreqRateTol`, and `FfeGateFreqMinBlock`. Its private `gateLatched()` selects `Monitor.Frozen` or `Monitor.FreqGateDone` according to the active criterion. Both `GateEngaged` and the `'freeze'`-mode FFE write inhibit use this helper; direct reads of `Monitor.Frozen` would be permanently false for a frequency-state gate.

## CDR/dlev/FFE validation runner layout

The validation suite under `validation/CDR/test_cdr_dlev_cdrffe` is organized around
`setup_cdr_dlev_cdrffe_paths.m`. The setup function derives the suite, CDR-validation,
and repository roots from its own `mfilename('fullpath')`, then adds only explicit,
session-local runtime paths: the suite root, `helpers`, the current runner directory,
`src/CDR`, and `src/ADC/TI_ADC`.

- The current entry point is
  `src/cdr_dlev_cdrffe_sslms_v3/cdr_dlev_cdrffe_sslms_v3.m`, and the thin
  runner that drives the configured `cdr_top` is
  `src/cdr_dlev_cdrffe_sslms_v4/cdr_dlev_cdrffe_sslms_v4.m`. Both runner
  directories are on the runtime path, and v4 writes to
  `result/cdr_dlev_cdrffe_sslms_v4`.
- The five runtime helpers are `detect_pi_center_touch_lock`,
  `select_slowest_pi_capture`, `build_cdr_ffe_eye`,
  `build_cdr_ffe_eye_pair`, and `plot_cdr_ffe_eyes`.
- `debug` and `legacy` are opt-in path scopes; `archive` contains inert historical
  source-search excerpts and is not added to the runtime path.
- The suite's original `result` tree and the cache under
  `validation/CDR/test_cdr/result` remain in their existing locations.
- Canonical tests live under `tests/CDR`; each uses the suite setup it needs rather
  than relying on `genpath`, `savepath`, or changing directory with `cd`.

This reorganization changes paths and file placement only, not model algorithms.
The suite `README.md` is the current invocation and optional-scope guide.

## Ppm offline eye-set layering

The frequency-offset validation suite at
`validation/CDR/test_cdr_three_loop_wi_ppm` has a deliberately thin offline
N-anchor-plus-tail eye path:

```text
make_ppm_stage_eyes.m
  -> helpers/build_ppm_eye_set.m
       -> ../test_cdr_dlev_cdrffe/helpers/build_cdr_ffe_eye.m
  -> helpers/plot_ppm_eye_set.m
  -> helpers/write_ppm_lock_summary_txt.m
```

- `make_ppm_stage_eyes.m` is the saved-result policy driver. It resolves one or
  more result directories, loads `cdr_three_loop_ppm_result.mat` and its
  CTLE cache segment, selects the saved start-phase row, replays
  SNR settle and the pass/fail lock criterion, and supplies those anchors to the
  builder. With `SaveOutputs = true`, it writes three standalone figures, one
  1500x1500 three-row comparison, `ppm_stage_eye_summary.csv`, and the all-phase
  `ppm_lock_summary.txt`; `CaptureBlock` remains context only.
- `helpers/build_ppm_eye_set.m` owns ppm-specific address/window policy. It accepts
  N anchors plus a trailing tail, reconstructs every block address including
  `DriftSampleTrace`, checks its sub-UI code exactly against
  `EyePhaseUnwrappedTrace`, selects all windows,
  and chooses each anchor-block snapshot plus the final-block snapshot.
- The sibling `build_cdr_ffe_eye.m` remains the single implementation of ADC
  quantization, fixed-coefficient FFE application, and 2-UI density formation.
  The ppm suite does not duplicate that numerical layer.
- `helpers/plot_ppm_eye_set.m` is M-row aware and writes M standalone figures plus
  one intentionally large 1500x1500 comparison. Each row carries its own tap
  snapshot and marks tracked physical eye phase rather than the raw PI ramp.
- `helpers/write_ppm_lock_summary_txt.m` writes the sole lock summary,
  `ppm_lock_summary.txt`, as a plain-ASCII human-readable strict superset of the
  former CSV columns: main and supplementary tables, definitions, aggregates,
  and the stage-2 note. For current MATs it uses the recorded
  `result.Stage2GateBlock`; it replays the center-touch gate only for older MATs
  without that field. It owns reporting only and does not alter the simulation.
  The distinct `ppm_stage_eye_summary.csv` is still written by
  `make_ppm_stage_eyes.m`.

The second anchor is a diagnostic replay of the verdict, not a live stage-2
trigger. Since `LockWindowBlocks = 2000`, it means the first block at which the
trailing 2000-block window satisfies the criterion and cannot be less than 2000.
For nonzero ppm, verdict replay uses `detectFrequencyStateLock` and, when
applicable, `detectRotationPeriodLock`; zero ppm uses
`detect_pi_center_touch_lock`.

This separation exposed the former control-path disconnect: pass/fail lock had
moved to the frequency domain for ppm, but stage 2 still used only the raw-code
center-touch gate. That center-touch path is enabled at `+/-100 ppm` yet cannot
fire because the PI code ramps instead of dwelling on one code. The implemented
runner now resolves `FfeGateCriterion = 'auto'` to `'center-touch'` at exactly
0 ppm and `'freq-state'` otherwise, using the same frequency-state window and
tolerances as the verdict. The pass/fail verdict itself remains separate: for
ppm, `Locked` still requires both `detectFrequencyStateLock` and
`detectRotationPeriodLock`, whereas stage 2 consumes only its selected gate.
Consequently `LockBlock` and the recorded `Stage2GateBlock` are distinct
milestones.

The ppm harness owns the sampling address, and that address is now taken through
the PI phase table: the in-UI offset is `round(PhaseInterpolator.getLocalIndex())`
rather than the raw `CodeWrapped`, so `cdr_pi`'s nonideal table actually reaches
the waveform instead of being computed and discarded. `cfg.PiNonideal` is a
runner option (`'ideal'` | `'ab_constant'`, default `'ab_constant'`) forwarded
unchanged to `cdr_top`; the `cdr_pi` table model and the `cdr_top` validation
were already present. Because `'ideal'` is the identity table, that mode is
bit-exact with the previous raw-code addressing, which keeps the two modes
directly A/B-comparable. The `cdr_top` boundary is unaffected: the DSP core
still sees only zero-centred ADC code in and sampling phase out, and knows
nothing about either the cache or the ppm drift.

Per-start convergence figures are annotated by a local `drawStageMarkers`, which
draws the two mu-downshift milestones (`Stage1SettleBlock`, `Stage2GateBlock`)
on any block-axis plot. Both inputs are NaN-safe, so a milestone that never
fired is simply omitted rather than drawn at a fabricated position. The stage-2
label names the armed gate rather than calling the event a lock, because only
the `freq-state` gate is a component of the lock criterion.

`setup_cdr_three_loop_wi_ppm_paths.m` exposes
`paths.HelpersDir = fullfile(paths.Root, 'helpers')`, validates that directory,
and adds it to the session-local runtime path. The setup also adds the sibling
helper directory for shared eye construction and zero-ppm lock selection,
without using `genpath`, changing `pwd`, or calling `savepath`.

## Missing top-level CDR blocks

The current `src/CDR` directory does not yet contain:

- Frequency detector or acquisition aid.
- Direct closed-loop connection between `cdr_pd`, `cdr_pi`, and `ti_adc_top`.
- BER/jitter-tolerance top-level simulation.

## Repository organization debt within the current scope

- Generated result files remain under `src/ADC/**/result` and `src/CDR/result`.
- CTLE waveform studies and large CSV files remain under `src/ADC/ADC_sample_CTEL_output`.
- Several SAR ADC implementations overlap in responsibility.
- Some Chinese comments have encoding corruption and should be normalized separately.
