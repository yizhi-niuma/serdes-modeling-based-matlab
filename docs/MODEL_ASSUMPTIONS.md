# Model Assumptions

This document is derived only from `src/TX+Channel`, `src/AFE`, `src/ADC`, and `src/CDR`. It records current code behavior, not verified silicon accuracy.

## Common numerical conventions

- UI is the timing unit used by the TI ADC clock and PI models.
- `SamplesPerSymbol`/oversampling converts phase in UI to waveform sample index.
- Timing impairments are ultimately applied as integer sample-index changes in the TI ADC clock path; arbitrary sub-sample interpolation is not modeled there.
- Fixed random seeds are used by validation scripts where repeatability is required.

## Minimal TX and S-parameter channel assumptions

- `src/TX+Channel/tx_channel.m` processes one complete symbol vector per call and retains no streaming state.
- Input values are already-mapped real voltage symbols. The model does not define NRZ/PAM4 symbol coding or voltage normalization.
- The TX is an ideal zero-order hold with no output bandwidth limit, finite rise/fall time, impedance variation, jitter, noise, or nonlinearity.
- The defaults are 56 GBd and 128 samples/UI. The waveform sample interval is `1/(SymbolRate*SamplesPerSymbol)`.
- `data/Channel/DPO_4in_Meg7_THRU.s4p` is interpreted as a differential four-port channel using port order `[1 2 3 4]` and 50-ohm source/load terminations.
- Additional TX and RX termination capacitances are set to zero; package and termination parasitics are not modeled.
- The S-parameter impulse response is generated for 1000 UI, scaled by the sample interval, and applied as a causal FIR response with `fftfilt`.
- The returned waveform is truncated to the TX waveform length. Channel tail energy after the final input sample is not returned.

## Fixed CTLE assumptions

- `src/AFE/ctle.m` is a debug-oriented fixed CTLE, not a circuit-accurate or adaptive AFE model.
- The default configuration assumes 56 GBd PAM4 and 128 samples/UI.
- Sample rate is not a CTLE input; `process` derives it as `SymbolRate*SamplePerSymbol`.
- The transfer function is `H(s)=k1*(s+wz)/((s+wp1)*(s+wp2))` with one zero and two real poles.
- The fixed default frequencies are `fz=7 GHz`, `fp1=14.315815 GHz`, and `fp2=56 GHz`. They produce 4.5 dB gain at the 28 GHz symbol Nyquist frequency relative to DC.
- DC gain defaults to 0 dB, with `k1` selected directly from the DC-gain requirement.
- `process` uses the continuous-time model with Control System Toolbox `lsim` and zero initial state. Any startup transient must be excluded by the consuming debug simulation.
- CTLE adaptation, AGC/VGA amplitude restoration, noise, saturation, and PVT variation are not modeled.

### Channel and CTLE co-simulation assumptions

- `validation/AFE/test_channel_ctle_cosim.m` uses a 2048-symbol PRBS20 preview for eye and impulse-response diagnostics. It discards the first 512 UI and uses the following 1024 UI for the maximum-power phase statistic and 512 non-overlapping 2-UI eye traces.
- The current validation-specific CTLE is `fz=6 GHz`, `fp1=28 GHz`, `fp2=50 GHz`, and `0 dB` DC gain. It is a user-tuned debug setting, not an optimized product CTLE or a noise-aware SNR optimum.
- A validation-local six-tap, symbol-spaced TX FFE is placed before `tx_channel`, with tap offsets `[-2,-1,0,+1,+2,+3] UI`. Its coefficients are solved offline from the Channel+CTLE symbol-pulse response over cursors `[-3,+6] UI`, then normalized so `sum(abs(taps))=1` and the main tap is positive. It does not change `tx_channel.m` and does not model coefficient quantization or adaptation.
- Consecutive PRBS20 bits use natural PAM4 mapping `00/01/10/11 -> -3/-1/+1/+3`.
- When configured with `prbs20PeriodBits=2^20-1`, the binary MAT cache contains one PRBS20 bit period. Because the period length is odd, the first bit is appended once to complete the last PAM4 pair, producing 524288 PAM4 symbols and 67108864 waveform samples at 128 samples/UI. Shorter debug exports retain their requested bit count in `prbs20BitCount` and set `isCompletePrbs20Period=false`.
- Full-period channel processing uses causal FFT blocks with `numel(channelImpulse)-1` samples of input history. CTLE processing carries the continuous-time `lsim` state and the preceding input sample across blocks so its default linear intersample behavior is preserved.
- The v7.3 MAT cache stores the unscaled TX-FFE+Channel+CTLE output waveform as a `1xN single` variable named `ctleOutput`. Time is reconstructed from the double-precision scalar `sampleInterval`; the cache also stores symbol rate, samples/UI, waveform dimensions, PAM4 levels, channel path, CTLE configuration, and TX FFE tap metadata.
- The cached CTLE waveform is not rescaled to the current `[-0.3,+0.3] V` ADC range.
- The channel impulse response is the sample-interval-scaled FIR kernel already used by `tx_channel`; applying the CTLE to that kernel preserves the scaling for the cascade response.
- The TX-FFE-plus-channel-plus-CTLE unit impulse response is aligned to its maximum-absolute-value sample, divided by that signed main-cursor value, and plotted from three precursor UI through six postcursor UI. Integer-UI cursor samples are marked explicitly.
- Because `tx_channel` applies a one-UI zero-order hold, symbol-spaced ISI is evaluated from the one-UI rectangular symbol-pulse response, obtained by convolving the final unit impulse response with `ones(SamplesPerSymbol,1)`. This pulse is aligned to the exact main index selected by the TX FFE optimizer, normalized to main cursor one, and plotted over `[-3,+6] UI`; the unit impulse plot is retained only as an analog-kernel diagnostic.
- Eye diagrams discard the first 512 UI and contain 512 non-overlapping two-UI traces, covering 1024 UI total. No amplitude normalization is applied; the CTLE eye marks the two occurrences of the maximum-power phase in its 2-UI window.

### Channel, CTLE, TI ADC, and CDR FFE pulse-response assumptions

- `validation/AFE/test_channel_ctle_ti_adc_cdr_ffe.m` is an open-loop diagnostic and does not run online LMS adaptation or a CDR feedback loop.
- The channel and CTLE pulse response is scaled so its absolute analog peak is `0.24 V`, leaving headroom inside the ideal 7-bit TI ADC range of `[-0.3,+0.3] V`.
- The ideal 64-lane TI ADC samples once per UI at the absolute peak phase of the channel and CTLE response. Physical-lane outputs are reordered into chronological UI order before entering the DSP FFE.
- The zero-input reconstructed ADC voltage is subtracted from the converted pulse response to remove the quantizer midscale baseline before normalization.
- Because the ADC is quantized and may saturate for other amplitudes, the ADC-plus-FFE result is a specified-amplitude sampled pulse response rather than a unique LTI unit impulse response.
- The six-tap CDR FFE main coefficient is fixed to one. The other five coefficients are solved offline from the ADC sampled pulse response.
- The offline constrained least-squares objective minimizes output cursor energy from `-3` through `+8 UI`, excluding `pre1`, main, and `post1`, while enforcing normalized output targets `pre1=post1=+0.1` relative to main cursor one.
- A small relative Tikhonov regularization of `1e-8` is applied to the variable-tap normal matrix. This stabilizes the solve but is not an RTL or LMS behavior.
- The current optimized tap vector is approximately `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]`. Its standalone unit impulse response is this tap vector at cursor offsets `[-2,-1,0,+1,+2,+3] UI`.

## SAR ADC assumptions

- Resolution is configurable as N bits.
- The nominal LSB is `(VH - VL) / 2^N`.
- Standalone validation commonly uses 7-bit ADCs and reference ranges of either `[-1, 1] V`, `[-0.5, 0.5] V`, or `[-0.3, 0.3] V`, depending on the study.
- Ideal mode removes enabled nonideal terms.
- Unit-capacitor mismatch is modeled with Gaussian random variation.
- Comparator noise is modeled as input-referred Gaussian voltage noise.
- Comparator offset and per-bit decision offsets are input-referred voltage terms; per-bit sigma may be configured in LSB.
- Gain and equivalent offset are applied at the ADC/lane input where supported.
- Quantized reconstructed voltage follows the code mapping implemented by each SAR variant. Different SAR variants may differ at code boundaries and therefore must not be assumed bit-identical without comparison.
- Inputs outside the configured range may saturate and/or issue warnings depending on the implementation.
- Fast APIs deliberately omit some validation and trace work for simulation speed.

## Differential TAH/SAR-channel assumptions

- Inputs are differential `Vip` and `Vin`; the held conversion input is their difference.
- The first clock-high phase starts/updates tracking.
- After tracking stops, subsequent rising edges resolve SAR bits.
- A conversion requires one track/sample phase plus N bit-decision phases.
- Output code and voltage remain held until the final bit decision completes.

## TI ADC assumptions

- The TI ADC has M independent SAR lanes.
- `convertOneBlock` consumes exactly one already-sampled value per lane.
- Lane ordering advances by block according to the internal lane state.
- Lane gain, offset, capacitor mismatch, comparator noise, and bit offsets are independently configurable.
- `LaneSkew` in `ti_adc_core` does not resample a continuous waveform; actual timing displacement is implemented through `ti_adc_clock`/`ti_adc_top` sample indices.
- `ti_adc_top` requires adequate left and right waveform margin when skew or jitter can shift samples outside the nominal local block.
- Current CTLE-based validation uses 64 lanes, 8 SAR lanes per TAH group, 128 samples/UI, and a 7-bit ADC.
- TI ADC block output positions are physical-lane ordered. A downstream serial DSP must reorder them using the clock model's physical-lane-to-time-order mapping before computing adjacent-symbol decisions.

### Joint TI ADC and CDR validation assumptions

- `validation/CDR/test_ti_adc_cdr_joint_ctle.m` models the CDR timing path as CTLE waveform, ideal TI ADC sampling/conversion, code-domain fixed decisions, MMPD, voter, loop filter, and PI; it does not include the deferred dedicated CDR FFE or data-path DFE.
- The ideal 7-bit ADC range remains `[-0.3,+0.3] V`. Fixture samples outside that range use the SAR model's saturation behavior; approximately 1.583% of the complete fixture samples are outside the configured range.
- PAM4 code centers are deterministically calibrated at the offline maximum-power data phase. Adjacent center midpoints are fixed DSP data thresholds for the complete closed-loop run.
- The binary MMPD error bit compares the ADC code with the calibrated center of its decided PAM4 level, using the existing negative/positive-level polarity convention.
- PI floating sample indices are rounded to the nearest integer only at this validation's TI ADC sampling boundary.
- MMPD is treated as a tracking detector and starts eight waveform samples before the ADC-quantized statistical lock phase; this does not demonstrate full-UI acquisition.

## TI ADC clock assumptions

- Fixed skew and random jitter are expressed in UI.
- Random rising-edge and TAH jitter are Gaussian.
- UI offsets are multiplied by samples/UI and rounded to sample indices.
- The clock can operate with common or per-rising-edge-phase skew.
- Data and edge indices are generated as discrete waveform indices; interpolation is left to a future sampler if needed.

## Offline waveform-study assumptions

- The CTLE waveform studies assume 112 Gb/s PAM4, hence 56 GBd and 128 samples/UI.
- `validation/AFE/test_channel_s21_eye.m` uses PRBS20 polynomial `x^20+x^3+1` with an all-ones initial state and takes 16384 bits to form 8192 PAM4 symbols.
- Consecutive PRBS bits are mapped without Gray coding to normalized PAM4 voltage levels `[-1,-1/3,+1/3,+1]`.
- The channel plot converts single-ended four-port data with input pair `(1,3)` and output pair `(2,4)` to differential `Sdd21`.
- The channel eye validation discards the first 1000 UI and overlays 2000 traces of 2 UI each. It does not add TX FFE, CTLE, DFE, noise, or jitter.
- Eye diagrams span two UI.
- Leading delay is estimated either from an amplitude threshold or normalized TX-to-CTLE cross-correlation.
- The threshold method uses 3% of global peak amplitude and requires a run of valid samples.
- Sampling phase may be selected using maximum sampled power or variance. This is an offline eye-center heuristic, not a closed-loop CDR result.
- The CTLE-to-ADC study commonly uses a 7-bit `[-0.3, 0.3] V` SAR range.

## CDR phase-detector assumptions

- `cdr_pd` is a pure digital detector. Equalization and slicing occur upstream, and the PD does not convert amplitude samples into decisions.
- The default modulation mode is PAM4; NRZ is also supported.
- NRZ data and edge decisions use codes `0/1`; every NRZ data transition is valid.
- PAM4 data symbols use `00=-3`, `01=-1`, `10=+1`, and `11=+3`; the edge decision remains one bit at the center threshold.
- PAM4 BBPD decisions use only the symmetric `00<->11` and `01<->10` transitions, matching the core transition-selection behavior of `cdr_bb_logic_lzy.sv`.
- With default polarity, an edge bit equal to the previous NRZ bit or previous PAM4 symbol MSB produces `+1`; the opposite edge decision produces `-1`.
- Invalid/non-selected transitions are forced to zero.
- The public PD output is named `phaseDecision`; it is a discrete early/late direction in `{-1,0,+1}`, not a continuous phase-error estimate in UI or time.
- Both `bbpd` and `bbpdFast` return `int8` phase decisions. The validated `bbpd` delegates to the `bbpdFast` decision kernel and adds input validation plus debug-state capture; `bbpdFast` assumes valid, same-sized digital inputs and does not update object state.
- For block processing, the CDR top-level must construct `dataPrevBlock = [previousSymbol, dataCurrBlock(1:end-1)]` and carry `dataCurrBlock(end)` into the next block. The PD does not own stream-boundary state.
- MMPD is PAM4-only and uses the reference RTL's binary error-bit concept rather than a continuous-amplitude Mueller-Muller formula.
- SS-MMPD is not a separate `cdr_pd` method. It is realized by feeding sign-derived PAM4 symbols (`0-3`) and binary error bits (`0/1`) to `mmpd`/`mmpdFast` with `transitionFilter=false`; every valid same-error, non-static transition then contributes a uniform `+1` or `-1`. The redundant `ssmmpd` methods were removed.
- The experimental branch deliberately omits the RTL odd/even path split. Its `mmpd`/`mmpdFast` methods take an optional trailing `transitionFilter` argument, defaulting OFF; OFF accepts every non-static PAM4 transition when adjacent binary error bits agree, with a uniform magnitude-1 contribution.
- Setting `transitionFilter` ON retains only `-3<->+3` (codes `0<->3`) and `-1<->+1` (codes `1<->2`) transitions. At HEAD the symmetric transitions contributed magnitude 2; per user request all accepted transitions are now uniform magnitude-1 and the `2x` symmetric weighting is removed. Falling transitions use `11` for positive and `00` for negative decisions; rising transitions reverse those signs.

### CTLE-waveform MMPD validation assumptions

- PAM4 symbol centers and thresholds are calibrated from the fixed CTLE fixture using the same deterministic four-level clustering used by the BBPD validation.
- The MMPD error bit is a binary level-error direction derived from the decided symbol center: for negative symbols 0/1, a sample above its center maps to one; for positive symbols 2/3, a sample below its center maps to one.
- The MMPD statistical lock phase is selected from an offline S-curve within +/-0.25 UI of the maximum-power data phase and with at least 5% valid weighted transitions.
- Baud-rate MMPD is treated as a tracking detector with limited acquisition range. With the default one-code output slew limit, the validation starts 8 waveform samples before the measured lock phase rather than claiming acquisition from an arbitrary phase over the full UI.
- The validation directly slices CTLE voltage and does not include the dedicated CDR FFE, TI ADC quantization, or data-path DFE.
- Under the weighted all-transition PD, the limited constant-voter comparison selects `Kp=0.5`, `Ki=0.005`, integral-state limits `[-2,+2]` code/block, and `MaxDeltaCode=1`. It tracks from phase 74 to the measured lock phase 82. These are behavioral validation settings, not product bandwidth requirements.

### Weighted all-transition MMPD v1 assumptions

- `validation/CDR/test_cdr_top_ctle_waveform_mmpd_v1.m` is an experimental comparison, not the baseline 64-UI tracking configuration.
- It uses a 64-UI linear voter and 50 loop updates over 3200 non-repeated fixture UI, matching the 64-lane ADC/CDR block cadence while retaining the same unique waveform length.
- Delta-code limiting is explicitly disabled with `MaxDeltaCode=Inf`.
- The S-curve used by the loop is the unconditional mean weighted decision over all UI; conditional mean and valid density are diagnostics only.
- A deterministic scan over Kp, Ki, polarity, and circular initial offsets selects the farthest initial phase meeting final-window mean-error, span, and drift criteria.
- The earlier 32-UI/update baseline result is retained only as historical context and is not compared directly with the corrected 64-UI/update acquisition result.
- The four-group weight search is a validation-layer experiment and does not change the hard-coded `cdr_pd.mmpdFast` transition weights. The closed-loop study remaps valid decision magnitudes externally while preserving the existing transition-dependent decision signs.
- Search candidates use primitive integer group weights in `[0,4]`. The four group curves are converted to unit-event-weight unconditional contributions before applying candidate weights.
- Stable and unstable zero crossings are classified from a 9-sample circular moving average. With polarity `+1`, negative-slope crossings are treated as stable; the static capture basin is the circular interval between the nearest unstable crossings around the target stable crossing.
- Candidate scoring uses the fixed 3200-UI fixture and combines target-lock distance, static basin width, additional stable-zero count, and target-crossing slope. It is not yet cross-validated across independent fixtures, channels, noise, or PVT corners.
- The selected experimental group weights are `[G1 G2 G3 G4]=[2 1 2 1]`. The smoothed static characteristic has a target stable crossing near phase 83.87 and one stable crossing over the UI. This static result is not interpreted as proven full-UI dynamic acquisition.
- With the selected weights, the corrected 50-update, 64-UI/update scan tests every integer initial offset over one UI. The continuous validated acquisition interval is `[-14,+18]` samples around the 83.87-sample target, corresponding to requested initial phases 69.87 through 101.87 (approximately 70 through 102 after PI/sample quantization). An isolated convergent point at `+21` samples is reported separately and is not treated as part of the continuous acquisition interval.

## CDR top-level assumptions

- `cdr_top` accepts hard digital data-symbol and edge-bit decisions; equalization, sampling, and slicing remain upstream.
- The future timing-recovery front end uses a dedicated CDR FFE and does not reuse the data-recovery FFE/DFE path.
- No DFE is included in the CDR timing path.
- A stateless slicer is currently treated as a threshold comparison rather than a stateful class. PAM4 data decisions require three thresholds, while the BBPD edge decision uses the center threshold only.
- The previous symbol supplied at construction or reset is explicit initial history for the first block; no hidden default symbol is assumed.
- One top-level call processes exactly one voter block. The phase entering that block is the sampling phase for that block.
- The block's voter and loop-filter result updates the PI after the decisions are processed, so the updated local PI index applies to the following block.
- `processBlockFast` assumes caller-validated digital vectors and intentionally does not update the top-level debug snapshot.

### Configured code-domain CDR core assumptions (2026-09-23)

- The configured `cdr_top(config)` path models the receiver DSP in the **code domain only**. Its input is one block of chronological, zero-centred ADC codes; it never samples a waveform and never references `ti_adc_top`. Physical-lane-to-time reordering, absolute UI addressing and UI-slip-driven waveform indexing remain the caller's responsibility.
- The configured path carries **one block of loop dead time**, and this is treated as physical rather than incidental: the CDR FFE needs `PreTapCount` precursor samples from the following block, so a block cannot be equalized until its successor has been sampled. Consequently `phase[k+1] == phase[k]` and `phase[k+2] == phase[k] + delta[k]`. The legacy component-injection path keeps its original zero-dead-time behaviour, so the two paths are not interchangeable for loop-stability statements.
- Boundary blocks are shorter than `BlockSize`: the first processed block loses its leading `PostTapCount` outputs (no past samples) and the `flush()` block loses its trailing `PreTapCount` outputs (no future samples). Invalid samples are discarded, never zero-padded. The phase loop still updates on short blocks, while dLev and FFE adaptation are skipped because both engines normalize by a fixed `BlockSize`.
- The `'mean'` voter divides by the actual number of valid decisions by default, so boundary blocks use 61/62 rather than 64 with the production geometry. A fixed denominator is configurable but changes the boundary-block loop gain.
- The MMPD input is inherently symbolized: `cdr_pd.mmpd` only accepts 0-3 PAM4 symbols and 0/1 error bits, and those come from hard-slicing the FFE output against the live dLev thresholds. There is therefore no separate "SS-MMPD" numerical path, and no amplitude information reaches the phase detector. Modelling a full-precision Mueller-Muller detector would require a new `cdr_pd` method.
- The FFE write gate is a causal, per-instance state machine keyed on the unwrapped PI code observed when the block was sampled, evaluated before any coefficient write. `'freeze'` inhibits writes permanently while still computing raw SS-LMS deltas; `'pvt-track'` keeps writing with a collapsed step size. Neither action stops the phase or dLev loops.
- The mu downshift is a single-shot event gated only on dLev settling (`|DLevOuter[k] - DLevOuter[k-W]| <= tol`). It is not gated on phase lock, because at capture-mu the phase can free-run and a lock-gated downshift would deadlock.
- Supervised golden-symbol training is not modelled in the configured path at all. The FFE reference is always the live decision derived from the live dLev levels, so cold-start behaviour is purely decision-directed.
- The PI advances by at most one code per block (`MaxDeltaCode = 1`) in both `cdr_top.defaultConfig` and the v4 runner, because a real phase interpolator updates one code per update. This replaces the earlier `12`, which was a behavioural-study value and is not physical. Integer demand clipped by this limit is retained in `cdr_loop.PendingCode`, not in `CodeResidue`. Measured impact on the v4 no-argument default run: lock is unchanged at 8/8 with `AllPhaseLock = 1`, common phase 113 and spread 4; the limiter engaged on only 5 of 120000 block-phase updates, all during acquisition and none after block 5432. v3 still defaults to `12`, so v3-versus-v4 comparisons must pass `MaxDeltaCode` explicitly.
- Distinguishing a converged limit-cycle dither from a slow drift requires the loop filter's pre-quantization state, because both `LastRawDeltaCode` and the applied `deltaCode` are integers and the PI code therefore hides sub-code motion. The decisive quantities are `LoopControl` (long-window mean should be about 0) and `FrequencyState` (steady value is the sustained drift velocity). `CodeResidue` is only corroborating evidence: its `(-1,1)` range is structural and always filled, so only its sign distribution is informative.

## Dedicated CDR FFE assumptions

- The CDR timing path uses its own FFE and does not share coefficients or dynamic state with the data-recovery FFE/DFE path.
- `cdr_ffe` is a floating-point, one-sample-per-UI FIR. It models no coefficient quantization, multiplier width, truncation, saturation, or DFE.
- The default coefficient vector is `[0, 0, 1, 0, 0, 0]`, with two precursor taps, one fixed unit main tap, and three postcursor taps. Tap count and precursor count are configurable.
- `cdr_ffe` receives a complete chronological window containing `PostTapCount` past samples, the target block, and `PreTapCount` future samples.
- The class does not retain sample history or mark output validity. The caller owns cross-block window assembly, look-ahead scheduling, and stream-boundary validity.
- The returned output contains only the target block and has length `numel(inputWindow) - PostTapCount - PreTapCount`.
- `cdr_ffe_loop` uses only data-sample decision error, defined by the caller as desired sliced level minus equalizer output. Edge samples do not contribute to adaptation.
- The LMS update is `mu/BlockSize` times the block sum of error multiplied by the input regressor. The main tap is masked from adaptation.
- The current block uses the existing coefficients; the caller applies the returned coefficient delta after the block so the update affects the following block.
- LMS step size is intentionally required at construction because no channel-independent stable or optimal default has been established.
- The validated LMS `update` path accepts row or column error vectors, converts inputs to `double`, and records the latest gradient, applied delta, and update count. `updateFast` assumes a caller-validated `double` `BlockSize`-by-`TapCount` regressor and `1`-by-`BlockSize` error vector, returns the coefficient delta and optional raw gradient, and intentionally does not update diagnostic state.

### Fixed-phase CDR FFE adaptation validation assumptions

- `validation/CDR/test_subBlock/test_cdr_ffe_adaptation.m` reads only the required region of the complete Channel+CTLE MAT cache, samples at fixed zero-based phase 20, and uses the ideal 64-lane, 7-bit TI ADC with `[-4,+4] V` limits. Physical ADC lanes are reordered into chronological UI order before equalization.
- The run uses 16384 target UI in 256 blocks of 64. Every FFE call receives exactly three past samples, 64 target samples, and two future samples; the coefficient delta computed from one block is applied only after that block.
- Automatic symbol alignment scans integer delays from `-64` through `+256 UI`, ignores the first 256 sampled UI, and maximizes absolute normalized correlation over the following 4096 UI. The current fixture selects delay 105 UI with correlation approximately 0.922208.
- ADC codes are centered by subtracting code 64. A single scalar map to the PAM4 `[-3,-1,+1,+3]` domain is fitted from the first 4096 aligned training samples before adaptation and then frozen; the current scale is approximately 0.078439.
- The primary split is 8192 supervised UI followed by 8192 decision-directed UI. A documented fallback of 12288 supervised plus 4096 decision-directed UI is allowed only when no candidate step size passes supervised convergence checks; the current run does not use the fallback.
- Step-size selection uses only supervised data and scans `[1e-5,3e-5,1e-4,3e-4,1e-3,3e-3,1e-2,3e-2]`. A candidate must remain finite with main tap exactly one, have tail/head MSE ratio at most 0.85, tail/previous MSE ratio at most 1.10, final supervised 16-block coefficient span at most 0.05, and tail absolute delta at most 0.005. The passing candidate with minimum supervised tail MSE is selected.
- Independent DD acceptance requires finite state, fixed main tap, final 16-block coefficient span at most 0.08, tail absolute delta at most 0.01, SER at most 0.15, truth MSE at most 1.25, decision-error MSE at most 0.35, and known-label adjacent level opening of at least 1.0. Known symbols are used in DD only for these validation metrics, never for coefficient updates.

### Three-loop (MMPD + dlev + CDR-FFE) training-mode assumptions

- Loop start-up and mu downshift (2026-09-21): the phase, dLev and CDR-FFE loops all start adapting from block 1 (no staged FFE freeze/release; `ffeReleased` is always true, and `FfeReleaseMode`/`FfeSettleDelay` are inert legacy options). The single capture-to-settle mu downshift for both dLev and FFE fires once, gated on `~trainingActive && dlevSettled` — i.e. after golden training ends and dLev has converged (`DlevSettleWindow`/`DlevSettleTol`). It is intentionally NOT gated on the phase-lock counter: at capture-mu the phase free-runs and never reaches `LockWindow` in-band blocks, so a lock-gated downshift deadlocks (the phase can only lock after reaching settle-mu). Golden training opens the eye at capture-mu; the post-training/dLev-settled downshift then drops to settle-mu, the phase locks, and the small settle steps track PVT drift. `lockCounter`/`LockWindow` are still computed but do not gate the downshift. The golden-to-decision-directed switch remains independently gated by `trainingActive = trainingMode && blockIndex <= FfeTrainingBlocks`. Default reference schedule for all-phase lock is `FfeTrainingReferenceMode='fixed'` (refs 36/12), `FfeTrainingBlocks=1000`, `DlevInit=48/16`, planB; this is a control-schedule change, not a new physical approximation.

- The v3 (`src/cdr_dlev_cdrffe_sslms_v3`) phase path derives PAM4 symbol (0-3) and error-bit (0/1) inputs from the shared slicer (`sliceCodePam4` returns them via `pam4SymbolBit`, re-encoded from the golden decision during training) and feeds them to `cdr_pd.mmpdFast(...,transitionFilter=false)` (uniform-weight MMPD = SS-MMPD). The runner carries the previous processed block's last symbol/error-bit into the next block (`dataPrev=[prevSymbol, dataCurr(1:end-1)]`, reset per start phase, first block self-initialized), so the block-boundary transition contributes and each interior block forms 64 candidate MMPD pairs. Earlier code dropped that boundary transition; this correction changes the loop numerics (previous saved baselines no longer bit-match) and was accepted by single-start-phase (64) convergence.

- `validation/CDR/test_cdr_dlev_cdrffe/cdr_dlev_cdrffe_sslms.m` runs the MMPD timing loop, the dlev level-tracking loop, and the adaptive CDR-FFE loop simultaneously over the cached Channel+CTLE waveform, scanning 32 integer start phases (`0:4:127`).
- In training mode the golden TX symbol that aligns with the received/FFE-output sample at global UI `u` is the symbol transmitted at UI `u - channelMainCursorUi`. `channelMainCursorUi` is the integer-UI Channel+CTLE main-cursor group delay, computed with the same convention as `samplePulseAtPhase`: `round((pulsePeakIndex - 1 - referencePhase)/samplePerSymbol)`. For the current cache this equals 105 UI, matching the 105 UI / 0.922208 correlation found by the independent alignment scan of the FFE-adaptation fixture. The golden window is therefore `goldenFirst = analysisStartUi + firstUi - channelMainCursorUi + 1`.
- The FFE output sample index aligns one-to-one with the centered ADC sample index of the same block (main tap at offset 0, symmetric pre/post window via `pendingPast`/`futureSamples`), so a single integer-UI delay compensation on the golden stream aligns all three loops.
- planB (cold-start) training requires an FFE step size much larger than a planA precision-trim value such as `1e-6`. A usable range is `1e-5`..`3e-4` with at least 400 supervised training blocks. All 32 start phases lock under these settings; `1e-6`/150 blocks does not lock.
- As of 2026-09-01 the script defaults were switched to this training baseline: `FfeInitMode='planB'`, `FfeTrainingBlocks=400`, `FfeStepSize=1e-4`, `FfeStepSizeSettle=2e-5`. Running `cdr_dlev_cdrffe_sslms` with no arguments now performs cold-start data-aided training (FFE begins at `[0 0 1 0 0 0]`) and populates the post-training histogram row. To recover the previous decision-directed behaviour pass `'FfeInitMode','planA','FfeTrainingBlocks',0,'FfeStepSize',1e-6,'FfeStepSizeSettle',2e-7`.

### Experimental live-dlev supervised FFE reference (2026-09-17)

- `FfeTrainingReferenceMode='fixed'` remains the default and retains the independent programmed training targets. The optional `'live-dlev'` experiment uses the same block's **pre-update** live inner/outer dlev levels to scale the known golden symbol classes and signs during FFE training. It does not substitute the received-output sign, does not use updated dlev values from the end of the block, and does not inject offline truth.
- Reference mode changes only the supervised FFE error target. Phase/dlev training paths, DD decisions, the SS-LMS formula, fixed unit main tap, waveform alignment, freeze control and final-lock criteria remain unchanged. With training disabled the option has no dynamic effect. Fixed reference values remain recorded/validated configuration, but are not used as amplitudes in live mode.
- `FfeTrainingInnerRefTrace`, `FfeTrainingOuterRefTrace`, and `FfeTrainingActiveTrace` record the actual per-block target amplitudes during training; unused entries are NaN. This separates programmed constants from the values actually consumed by the experimental adapter.
- The live reference is an online amplitude estimate, not independent truth. Its coupling with changing FFE output and timing can introduce initialization/path dependence; successful finite-window lock would not prove unique/global convergence, and a failure of one gain setting would not prove that all live-reference designs fail. Experiments keep48/16 initial state, cache/run length and existing acceptance/freeze thresholds fixed while allowing explicitly recorded loop-rate trials.

### v3 independent dlev initial state and FFE training amplitudes (2026-09-17)

- Current defaults separate initial state48/16 (`DlevOuterInit/DlevInnerInit`) from programmed FFE training references36/12 (`FfeTrainingOuterRef/FfeTrainingInnerRef`). Only the latter map golden symbols into the fixed supervised FFE target. Initial-state sweeps therefore no longer change that target implicitly. Both positive reference values are independently configurable, with outer greater than inner; the current36/12 is a user-approved nominal choice for this fixture, not an injected live estimate or a universal physical truth.
- Phase/dlev training paths continue using their existing live-level decisions. FFE in DD continues using the same live decision as before. Main-tap1, ADC scale, channel/cache, loop gains, training length and freeze/lock metrics are unchanged. This is an explicit parameter-role change, not an additional amplitude-control loop.
- Programmed references are finite positive scalar post-FFE code-domain values; floating-point output may exceed ADC input limits, so no artificial ADC-code cap is applied. The split removes a confounding parameter dependency but does not guarantee exact unique phase/tap convergence across every initial state, channel or finite observation window. Historical coupled-reference tuning sections below describe the preceding model.

### Three-loop v3 (SS-MMPD + dlev SS-LMS + FFE SS-LMS) convergence-tuning assumptions

- `cdr_dlev_cdrffe_sslms_v3.m` uses SS-MMPD timing (uniform weight-1, code-domain), dLev SS-LMS, and FFE SS-LMS with a direct symbol reference. The RAW SS-MMPD S-curve (observed via the offline `debug_v3_scurve.m` diagnostic, which freezes saved per-block FFE/dLev states and sweeps all 128 sampling phases) has the classic PAM4 shape of ONE strong stable (negative-slope) zero (mean-decision amplitude ≈ ±0.28, at code ~16) plus TWO weak stable zeros (amplitude ≈ ±0.01, at codes ~66 and ~99). The two weak lock points are removed by a phase-gated additive PD bias in the timing loop (`meanPhaseError = mean(ssDecision) + pdOffset*biasActive`, `pdOffset=-0.05`, `biasActive` true only for the current sampling `codeWrapped∈[45,116]`), which pushes the mid-UI S-curve below zero; the loop-effective S-curve then retains a single strong lock plus one unstable positive-slope repeller near code ~115 (verified after retune with the 36/12 anchors). Note the diagnostic's own printout shows both the RAW and the bias-applied (loop) curve — only the solid loop curve is what the phase integrator actually sees. Reliable acquisition additionally requires the phase loop to be slow enough that the cold-start FFE/dLev form before the phase integrator can move the sample point, otherwise the golden-driven FFE post1 tap collapses at the wandering phase and migrates the single strong lock toward the UI wrap boundary.
- The dLev training anchors (`DlevOuterInit`, `DlevInnerInit`) are nominal design constants known before lock, not offline truth injected into the loop; they also set the supervised FFE reference. Earlier tuning used36/12 near the roughly36.7/12.2 output clusters. Current user-requested defaults deliberately retain48/16, so correct eventual tracking cannot be inferred from anchor proximity. The validated reduced FFE update rates below permit48/16 acquisition without changing these anchors or the analog scaling; this supersedes the old claim that defaults must be36/12.
- Current48/16 validated configuration (2026-09-17): Kp8, Ki0.03, MaxDeltaCode12, PdOffset-0.05 with the existing phase gate, dlev capture/settle mu0.3/0.1, FFE capture/settle mu0.0018/0.0002,1000 training blocks, online freeze500 modal occurrences/100 events in +/-3 codes, defaultPRBS22/16000 blocks. Only the three update rates were changed from the user's task-entry settings; freeze/final-lock thresholds and algorithms were held fixed during tuning. All32 starts pass phase/dlev/FFE consistency and the existing pre1/post1 checks; PRBS20/8000 with identical settings is an independent passing holdout. The behavioral freeze regression deliberately pins an older numerical fixture rather than inheriting these defaults.
- Acquisition involves substantial allowed integer UI slip: in the main validated run, final slip is-73..-66 UI and the last slip occurs by block2569, before freeze. Tail lock/consistency is therefore not a claim of low-slip or minimum-time acquisition, symbol synchronization, or BER. Mode and band checking remain in unwrapped coordinates so repeated UI motion cannot satisfy final lock merely by modulo aliasing. Frozen temporal coefficient variance alone is not used as evidence of optimum equalization.
- Validation-metric approximation: the `allPhaseLock` common-band tolerance is `±3` code (was `±2`). A ±3/128-UI ≈ 2.3% UI difference between start-phase steady sample points is treated as the same physical sampling instant, absorbing SS-LMS misadjustment and start-phase residual; this is a metric choice and changes no physical model.

### v3 terminal modal-center touch/cross validation criterion (2026-09-16)

- The current v3 final lock metric supersedes the strict adjacent-pair criterion below. Select a fixed modal code from exactly the last 2000 integer unwrapped sampling codes and evaluate events only in that same window. A tie selects the lowest unwrapped code deterministically and exposes the tie count. Shorter traces may report their available mode but cannot establish lock under the 2000-block requirement.
- Permit samples inside the inclusive center +/-3-code band. An arrival from a noncenter code at the center is one event, including a touch followed by a return to the original side. A direct side-to-side crossing that skips the center is also one event. Center dwell and departure do not add another event; the first sample has no inherited previous-window event. Every out-of-band sample clears the retained event count, qualification time, and previous-sample continuity. At least 51 events retained at the end establishes the requested phase-lock flag.
- Use `UiSlip*SamplePerSymbol + PhaseCodeTrace`, without modulo during mode selection/band tests, so full-UI drift cannot be hidden. Wrap only the reported center. `LockedPhaseCode` is this modal value even for rejected starts; plotting must distinguish rejected modes from accepted locks. `AllStartsConverged` is the conjunction of per-start flags; `AllPhaseLock` additionally checks their circular common-center tolerance of +/-3 codes.
- This is an explicitly user-selected finite-window validation tolerance, not proof of stationary mean phase, BER, infinite-time stability, or simultaneous FFE/dlev stationarity. Small drift inside the band is intentionally allowed. The preceding single-start PRBS22 trial produced 178 events without a band violation; full-start validation is recorded separately.

### v3 slowest-first-capture convergence-plot selection (2026-09-16)

- This is a retrospective visualization metric separate from the final 2000-block lock test. Freeze each start's final-window modal unwrapped center, scan from block 1, and record the first time the inclusive center +/-3-code touch/direct-cross counter reaches 51 events. A band exit before qualification resets counting and previous-sample continuity; a later band exit does not erase the historical first-capture timestamp.
- Rank only starts passing the independent final-window lock check. The largest finite first-capture block selects the phase, dlev, and FFE convergence traces, with first-in-scan-order tie breaking. A missing eligible start is reported without claiming a selected locked trajectory. The full sweep and all trace data are still retained.
- Selecting one start by its phase-capture time does not assert that its FFE or dlev has the longest settling time, nor that those loops have settled at the marked block. Final-center hindsight and deterministic mode-tie handling are explicit approximations of this plotting/validation metric; no physical model, adaptation update, or loop setting changes.

### v3 causal FFE-write freeze and fixed-tap eye reconstruction (2026-09-17)

- Optional online FFE freeze monitoring begins at `FfeTrainingBlocks+1`, never during supervised training. Each start has independent causal state. During a search period, each observed unwrapped sampling code contributes one occurrence per processed block. A modal code needs at least `FfeFreezeMinModeOccurrences=100` observations before becoming a fixed candidate center; ties select the lowest unwrapped code. Qualification uses no future or final-window statistics.
- Once qualified, count center arrivals (including touch-and-return) and direct side-to-side crossings inside the inclusive center +/-`FfeFreezeBandHalfWidth=3` band. Center dwell/departure are not extra events. At `FfeFreezeMinEvents=50`, freeze permanently. A candidate-band violation before freeze discards the center, occurrence histogram, event count, and previous-sample continuity; the outlier is not seeded into the next search. The next block restarts search. These thresholds are user-selected behavioral control parameters, not product lock specifications.
- Freeze inhibits coefficient writes starting at the trigger block: the effective coefficients used to process that block are retained. The SS-LMS update and candidate `effectiveCoefficients + rawDelta` are still computed on subsequent valid blocks using the actual frozen-path output; no shadow accumulator or second independently adapted equalizer is introduced. Phase and dlev remain active. This differs from setting the FFE step size to zero. The main coefficient stays one and freeze is not automatically released.
- Eye diagrams use the automatically selected slowest first-capture start from the new full simulation. Default `EyeDiagramUiCount=2048` is a UI count, not a block count. Freeze eye starts at the first complete block **after** `FfeFreezeBlock`, and includes up to the next requested contiguous UI; the final eye uses the last requested contiguous UI ending at the last processed block. UI-slip-aware waveform indices and FIR margins are tracked separately from the count of displayed UI. Short available intervals are explicitly labelled as truncated; unavailable intervals render N/A rather than borrowing pre-freeze data.
- These are offline fixed-tap, post-CDR-FFE centered-code eyes, not online oversampled ADC measurements. Reuse the existing ideal TI-ADC SAR core at every cached sub-UI phase, center by ADC midcode, and apply the symbol-spaced FIR independently to each phase stream. Replacing identically configured ideal lanes by vector calls to the same SAR core is checked for exact code equivalence; this equivalence is not claimed for lane mismatch, skew, noise, or time-varying nonidealities. No voltage rescaling or alternate quantizer is introduced.
- A 2-UI density plot combines overlapping adjacent output UIs. Interior UIs therefore contribute twice; accumulated observations equal `2*SamplesPerSymbol*(UiCountUsed-1)` and must not be interpreted as independent samples. Density uses 0.5-code bins and logarithmic color display, with common vertical/color limits across the freeze/final comparison. Phase coordinates remain anchored to the cached UI boundary; markers appear at `mod(code,128)/128` and one UI later, without artificially centering the eye around the marker.
- Freeze eye uses the recorded frozen coefficients and online freeze modal center; final eye uses actual frozen coefficients and final-window lock center. If the selected start never freezes, freeze eye is N/A and final eye is explicitly a final-live-tap snapshot. If its requested final data window overlaps a pre-freeze interval, the displayed fixed-tap snapshot is not a replay of historical time-varying coefficients. No selected finally locked start means no falsely labelled locked eye. These diagnostic approximations do not modify the online loops.

### Diagnostic comparison of dlev initial state and FFE training target (2026-09-17)

- The isolated `results/CDR/dlev_init_phase_diagnostic` experiments hold initial PI124, code source, waveform phase origin and run settings fixed. Outer20/36/48 is interpreted with inner=outer/3, plus20/7 as an explicit rounding sensitivity case; the user's unspecified exact20-case inner value is not assumed known.
- A common2048UI waveform window is used across different final frozen tap vectors. Eye-opening location is measured by the minimum adjacent-level gap between known-label5th/95th percentile bounds, not by an absolute BER or worst-case eye mask. A0/1UI golden-label choice handles which TX symbol occupies the phase-wrap side without translating the waveform or graph. Finite zero decision errors do not establish BER performance.
- The fixed-training-reference control changes only the FFE supervised amplitude targets to36/12 in a diagnostic copy; production dlev initialization, DD behavior and code are preserved. The fixed-FFE control instead uses common offline planA coefficients with no training/adaptation. These are deliberate causal comparison fixtures, not adopted physical-model changes or a recommendation to remove FFE adaptation.

### Superseded v3 strict terminal adjacent-pair criterion (2026-09-16)

- Evaluate the final contiguous segment confined to one fixed pair of adjacent integer unwrapped PI codes. Lock requires at least 51 actual transitions within that terminal pair (`>50`, not 50 blocks or 50 round trips). Zero-step dwell is permitted without incrementing or clearing the transition count. Leaving the pair resets the candidate, even when an earlier pair already qualified.
- Use the observed sampling-code trace `UiSlip*SamplePerSymbol + PhaseCodeTrace`. Adjacent codes spanning a UI boundary remain adjacent (`127/128` wraps to `127/0`); drift over a whole UI must not be erased by applying modulo before detection. Cross-start common-phase distance is circular, with the retained ±3-code tolerance.
- This is a user-selected finite-observation convergence metric, not a new physical assumption. It intentionally rejects constant-only output and three-code dither. There is no maximum dwell duration: a qualifying terminal pair followed by a constant dwell remains accepted unless the code leaves that pair. It does not guarantee future stability or independently establish dLev/FFE convergence; their standard deviations remain separate diagnostics. Historical maximum transition count cannot establish final lock.

### Fixed-dlev SS-MMPD + adaptive CDR-FFE (SS-LMS) dual-loop assumptions

- `validation/CDR/test_cdr_cdrffe/cdr_dlev_sslms.m` was repurposed from "fixed FFE + adaptive phase/dlev" into "fixed dlev + adaptive phase (SS-MMPD) + adaptive CDR-FFE (SS-LMS)". It scans 32 start phases (`0:4:127`) over the cached PRBS20 Channel+CTLE segment with the same 64-lane 7-bit `[-4,+4] V` TI ADC, `[-2..+3] UI` six-tap CDR FFE, and 64-UI block pipeline as the sibling three-loop script.
- The dlev decision levels are held fixed in the code domain: low/inner `DLevInner=12`, high/outer `DLevOuter=36`, positive threshold `(12+36)/2=24`. These are name-value options; they are not adapted online. They match the offline four-level cluster truth (inner ≈ 12.2, outer ≈ 36.7). During cold-start training the golden `{±3,±1}` map directly to these fixed levels `{±36,±12}`.
- The phase detector is the uniform weight-1 SS-MMPD (identical kernel to `cdr_dlev_cdrffe_sslms_v3`): data symbol 0–3 and error bit are derived from the shared `(decision, sliceError)` in the code domain, and the per-block phase error is `mean(±1/0)` plus a phase-gated bias `PdOffset=-0.05` active for `codeWrapped∈[45,116]` to break SS-MMPD alias degeneracy. Gains act directly on the normalized output with no code-domain `gainScale`: `Kp=8`, `Ki=0.06`, `MaxDeltaCode=12`, integral limits `±4`.
- The CDR FFE adapts with sign-sign LMS (`cdr_ffe_loop.updateSsLms`) from a **cold start** `[0 0 1 0 0 0]` (main tap 1, no equalization). Error is `errorBlock = decision − ffeOutput` (= `−sliceError`); the main-tap delta is forced to zero (`AdaptEnableMask=[1 1 0 1 1 1]`). FFE updates only on fully valid 64-sample blocks.
- Two-stage cold-start schedule: the first `FfeTrainingBlocks=500` processing blocks are data-aided (golden). Because the closed cold-start eye makes real decisions unreliable, the TX PAM4 symbols from `tx_prbs20.mat` replace the decision to feed correct gradients to SS-MMPD and FFE SS-LMS. The golden window compensates the Channel+CTLE main-cursor delay `channelMainCursorUi=105` (same `round((pulsePeakIndex−1−referencePhase)/samplePerSymbol)` convention as the sibling three-loop script): `goldenFirst = analysisStartUi + firstUi − channelMainCursorUi + 1`. After block 500 the loop switches to decision-directed **blind** convergence and drops the FFE step from capture `FfeStepSize=0.02` to settle `FfeStepSizeSettle=0.001` in one shot. The default analysis segment is `AnalysisNumUi=512512` (≈ 8000 blocks), so ≈ 7500 blind blocks follow the 500 training blocks.
- The decision-directed SS-LMS drives the free taps toward the true MMSE solution (converged taps pre1 ≈ −0.35, post1 ≈ +0.13), not the offline `0.05`-cursor design; SS-MMPD stays locked because its S-curve does not depend on residual pre1/post1 ISI. With cold start + golden training over 8000 blocks all 32 start phases lock to the same code (spread 0) and the cross-phase FFE-coefficient spread is ≈ 0.0023, so the consistency tolerance is set to `0.01` (SS-LMS misadjustment margin).

### Ideal-edge convergence validation assumptions

- The NRZ convergence validation uses alternating `0/1` symbols so that every UI contains one valid BBPD transition.
- The PAM4 convergence validation runs the selected outer `0<->3` and inner `1<->2` transition families as two independent cases so that every UI remains a valid BBPD transition.
- Ideal PAM4 symbol levels are `[-3, -1, +1, +3]`; data slicing uses thresholds `[-2, 0, +2]`, and edge-bit slicing uses the center threshold at zero.
- The validation waveform is ideal and piecewise constant, with instantaneous edges, no noise, no jitter, and no ISI.
- The waveform uses 128 samples/UI and places the true edge 24 waveform samples after the nominal UI boundary.
- Only this validation rounds the PI floating local index to the nearest waveform sample before slicing. This does not resolve the project-wide choice between rounding and interpolation.
- The NRZ data/edge slicers and the PAM4 edge slicer use a fixed zero threshold.
- Constant voter mode with magnitude 8 and a proportional-only loop setting is used to expose phase search and the expected one-sample steady-state limit cycle without frequency-acquisition dynamics.

### CTLE-waveform CDR validation assumptions

- `data/ADC/TI_ADC/ctle_out.csv` is interpreted as time in seconds followed by CTLE output voltage in volts. Its measured interval is checked against 56 GBaud PAM4 at 128 samples/UI.
- The fixed waveform contains 5000 UI but the CDR validation uses 4096 UI, organized as 64 blocks of 64 UI.
- The validation samples the CTLE voltage directly. It does not yet include the dedicated CDR FFE, TI ADC quantization, or data-path DFE.
- PAM4 levels are calibrated once from samples at the offline maximum-power data phase using deterministic one-dimensional four-level clustering. The three slicer thresholds are midpoints between those calibrated centers.
- The PAM4 data slicer uses all three calibrated thresholds. The edge-bit slicer uses the calibrated center threshold.
- The offline maximum-power data phase is 84 samples and its half-UI-shifted edge reference is 20 samples for the current fixture.
- Because ISI makes the BBPD statistical zero crossing differ from the power-derived edge reference, the validation measures an offline BBPD S-curve. The selected statistical lock phase is the minimum-magnitude mean valid decision within +/-0.25 UI of the power-derived edge and with at least 5% selected transitions.
- The measured BBPD lock phase for the current fixture is 15 samples. Convergence error is evaluated against this statistical lock point rather than forcing the loop to the power-derived phase at sample 20.
- The default validation gains are `Kp=0.0625` and `Ki=0.0005`, with constant voter magnitude 8 and loop integral-state limits of `[-2, +2]` code/block.
- Those gains are fixture-specific behavioral-validation settings, selected from a small local scan using mean steady-state phase error, phase span, transition density, and residual drift. They are not product loop-bandwidth requirements.
- The CSV does not include transmitted symbol labels, so this validation demonstrates phase acquisition/tracking and slicer-driven CDR operation but does not measure BER.

## CDR voter assumptions

- The initial closed-loop behavioral path assumes classic 2x BBPD sampling: every data decision has a corresponding edge decision.
- Hardware-oriented 1.25x sparse/rotating edge sampling is not modeled in the initial voter path.
- A voter input is one parallel block of `-1/0/+1` phase decisions; zero contributes no vote.
- The default block contains 64 decisions. The voter reduces the block to one phase-error update and holds no history across calls.
- Linear mode preserves the signed net vote count. Constant mode preserves only its sign and uses configurable magnitude 8 by default.
- Voter accumulation and output use `int16`; RTL-specific accumulator overflow and register latency are not modeled.

## CDR loop-filter assumptions

- `cdr_loop` receives one numeric voter output per block and does not know whether the voter used linear or constant mode.
- The initial closed-loop update cadence is one loop-filter update per 64-UI block; the resulting PI code increment affects the following block.
- The loop filter implements a behavioral proportional-integral controller. The current error updates the integral state before both proportional and integral terms form the current control output.
- `Kp`, `Ki`, the integral state, and the code residue use floating-point arithmetic; RTL fixed-point widths, shifts, pipeline registers, and permanent overflow freeze are not modeled.
- The loop-filter output unit is PI code per update. Only complete integer codes are passed to `cdr_pi`; fractional code is retained in `CodeResidue` for later updates.
- `MaxDeltaCode` defaults to one, so the applied PI increment is limited to `-1/0/+1` per block. `Inf` explicitly disables this limit.
- Output limiting is owned by `cdr_loop`, not `cdr_top`, so the loop state and the code actually applied to `cdr_pi` remain consistent. The pre-limit integer request is exposed as `LastRawDeltaCode`.
- `CodeResidue` retains only the fractional remainder below one code. Complete integer demand not yet executed because of `MaxDeltaCode` is retained separately in `PendingCode` and is canceled naturally by later opposite-direction demand.
- `PendingCode` is an explicit slew backlog and is not currently bounded independently. Persistent demand beyond the PI slew capability can therefore accumulate pending code; this behavior must be revisited when RTL anti-windup/backlog limits are defined.
- Integral limits are configurable in code/block and default to `[-Inf, +Inf]`. At a finite limit, outward integration saturates while reverse error can return the state to range.
- `cdr_loop` does not implement a frequency detector, FLL, acquisition state machine, PI code wrap, or UI-slip tracking.

## Phase-interpolator assumptions

- The default PI is 8-bit, giving 256 codes per UI.
- Default sampling resolution is 128 samples/UI.
- PI code is integer-valued and wraps into `[0, NumCode-1]`.
- Full-UI crossings accumulate in `UiSlip` rather than being discarded.
- The default nonideal model uses `a+b=constant` vector interpolation and an `atan2` phase mapping.
- Custom INL and custom phase tables are accepted in UI.
- PI output sample index is floating point. The downstream sampler must decide whether to round, floor, or interpolate.
- `updateFast` updates wrapped code and UI slip but intentionally leaves some debug-derived state stale until a full update/state refresh.

## SS-LMS FFE adaptation assumptions

- `cdr_ffe_loop.updateSsLms` computes the sign-sign LMS gradient: `gradient = sign(errorVector) * sign(dataRegressor) / BlockSize`. The `sign()` function returns `{-1, 0, +1}` following MATLAB semantics; zero-valued inputs map to zero gradient contribution.
- Because both error and regressor amplitudes are discarded, the gradient magnitude per sample is bounded by 1. The effective step size (coefficient delta per block) scales linearly with `StepSize` alone, unlike standard LMS where it also scales with signal power.
- SS-LMS converges to the same Wiener solution as standard LMS in expectation, but the convergence path is noisier and the steady-state misadjustment is larger for a given effective update rate. The normalized post-cursor residual (`post1`) is typically 0.01–0.03 larger than the MMSE LMS result.
- The `StepSize` for SS-LMS must be approximately 100–300× larger than for standard LMS to achieve comparable convergence speed, because the standard LMS gradient magnitude includes a factor of `O(error_rms * regressor_rms)` that SS-LMS removes.

### Offline ppm three-eye assumptions and limitations (2026-09-26)

- `validation/CDR/test_cdr_three_loop_wi_ppm/make_ppm_stage_eyes.m`
  reconstructs an N-anchor-plus-tail eye set from saved waveform and per-block
  state. It does not rerun the CDR or reproduce its coefficient-update
  trajectory.
- The current three rows are stage-1 SNR settle, first satisfied lock criterion,
  and final tail. `CaptureBlock` is retrospective context only and is not an eye
  anchor. SNR settle replays the live EWMA recurrence (`alpha = 1/128`, 15 dB,
  minimum block 200); lock replays the verdict's own detectors and tolerances.
- `LockWindowBlocks = 2000` means the second anchor cannot precede block 2000.
  It is the first complete trailing window that satisfies the criterion, not the
  physical instant at which the loop locked.
- Each row uses exactly one fixed coefficient set across its complete data
  window: each anchor row uses its anchor-block snapshot and the final row uses
  the final-block snapshot. Although the taps were adapting during the original
  run, neither row applies the historical block-by-block tap sequence. Each is
  therefore an offline fixed-coefficient view of that window, not a faithful
  replay of the time-varying equalizer.
- Marker statistics use unwrapped tracked-eye phase (raw unwrapped PI code plus
  drift) before one-UI wrapping. The eye-density matrix is assembled from
  overlapping 2-UI traces. Adjacent density columns/windows reuse samples and
  must not be interpreted as independent observations or used to inflate an
  effective sample count.
- Row 2 is not evidence that the live stage-2 gate fired for the runs that
  produced it historically. Those saved MATs were made with the center-touch
  gate; at `+/-100 ppm`, raw unwrapped PI code ramps at `0.8192 code/block`, so
  that gate fired on 0/32 phases at either offset. Current runner default
  `FfeGateCriterion = 'auto'` selects the frequency-state gate at nonzero ppm
  and retains center-touch at exactly zero. As of the 2026-09-26 32-start
  regeneration the three result directories **were** rerun under `auto`, so
  their stage-2 fields now describe the selected gate (32/32 fired at
  `+/-100 ppm`, 29/32 at 0 ppm); the row-2 label still means "after the lock
  criterion is satisfied" and never "after the second downshift".

### PI nonideality assumptions in the ppm suite

- The suite's default is a nonideal phase interpolator: `PiNonideal =
  'ab_constant'`, the `cdr_pi` `a+b=1`/`atan2` table. `'ideal'` remains
  selectable and is bit-exact with the pre-2026-09-26 harness behaviour.
- PI nonideality is only observable because the harness takes its in-UI
  sampling offset from the phase table (`round(getLocalIndex())`) rather than
  from the raw code. Any future sampler that re-derives the offset from
  `CodeWrapped` silently reverts to an ideal PI regardless of the
  configuration.
- Quantified at `PiNumBit = 7` with 128 samples/UI, where 1 LSB = 1 code = 1
  waveform sample: INL is `+/-1.445352 LSB` (2.890703 LSB pk-pk, 1.037876 LSB
  RMS). The cache is addressed in integer samples, so the offset is rounded and
  INL is quantized to `+/-0.5 LSB`. The surviving perturbation is
  `round(localIndex) - code` in `{-1, 0, +1}` over 52/24/52 codes: 104 of 128
  codes sample one sample away from the ideal-PI address, and 24 codes are
  unperturbed.
- Consequently this harness cannot represent INL below roughly 0.7 LSB pk-pk,
  and it represents the 2.891 LSB pk-pk table only as a three-level staircase
  rather than a smooth curve. Studying finer INL requires fractional
  interpolation of the cached waveform, which is not implemented; this is the
  same limitation already recorded as "no sub-sample interpolation in the TI
  ADC sampling path".
- A nonzero mean `|PendingCode|` under a frequency offset is structural and is
  not by itself evidence of a slew-limited or unconverged loop. The required
  rate at `+/-100 ppm` is `0.8192 code/block`, a fraction, while the PI moves
  whole codes under `MaxDeltaCode = 1`, so a fractional backlog always exists.
  Only the `SlewSatDeltaFrac`/`SlewSatPendingTol` guards distinguish that
  structural backlog from genuine saturation. The 2026-09-23 statement that a
  persistently nonzero pending code implies non-convergence applies to the
  zero-offset case.

### Phase-slew ceiling on trackable frequency offset

- The PI applies at most `MaxDeltaCode` codes once per ADC block. With one code
  equal to `1/128 UI` and one block equal to 64 UI, the fastest sustainable
  phase rate is `MaxDeltaCode/(128*64) UI per UI`, while an offset of `X` ppm
  demands `X*1e-6 UI per UI`. Hence a hard, tuning-independent ceiling:

  ```
  ppm_max = MaxDeltaCode * 1e6 / (PiCodesPerUi * AdcBlockUi) = 1e6/8192 = 122.07 ppm
  ```

  `+/-100 ppm` consumes `0.8192 code/block`, i.e. 81.92% of that budget, which
  is what `result.SlewUtilization` reports. Everything else the phase path must
  do (PD dither, INL correction, acquisition transient, FFE cursor walk) has to
  fit in the remaining `0.1808 code/block`.
- The ceiling moves the counter-intuitive way with PI resolution: at a fixed one
  code per update, a **finer** PI lowers `ppm_max` because one code is a smaller
  phase step. `PiNumBit = 8` would halve it to 61 ppm. Raising it requires a
  larger `MaxDeltaCode`, a shorter block (more updates per UI), or a coarser PI,
  so PI resolution and slew ceiling are in direct conflict at a fixed update
  rate.
- The reasons real designs restrict the PI to one code per update - glitch-free
  and monotonic transitions through the weight encoding, jitter and spur
  generation from instantaneous phase steps, interpolator settling time, and
  DNL under mismatch - are **not modelled here**. `cdr_pi` is an integer-indexed
  phase table with no encoder, no switching transient and no bit skew, so this
  repository cannot be used as evidence for or against any encoding choice
  (thermometer, Gray or binary).
- The measured boundary is not the same quantity as this ceiling, and neither is
  it purely physical. Because `lockedFlag` includes `~slewSaturated` as a veto,
  the reported trackable range `-105 .. +102 ppm` is set by
  `SlewSatPendingTol = 0.5`, i.e. by a judgement that about `3.9 mUI` of static
  phase lag is the acceptable limit. With that guard relaxed the frequency-state
  and rotation-period criteria still hold at `+115`/`-120 ppm`. See
  `docs/VALIDATION.md` and
  `validation/CDR/test_cdr_three_loop_wi_ppm/result/ppm_tracking_range_notes.txt`.

## Current validity limits

- The digital CDR component chain and one validation-only Channel+CTLE+TI-ADC+fixed-FFE+MMPD loop are integrated at block rate. This validates deterministic initial-phase acquisition only; tracking bandwidth, jitter transfer, jitter tolerance, and BER remain unvalidated.
- No sub-sample interpolation is implemented in the TI ADC sampling path.
- No correlation target against transistor simulation, measurement, or a product specification is documented.
- Multiple SAR implementations coexist and may use different state and boundary conventions.
- Offline CTLE phase selection must not be treated as proof of CDR lock.

### Fixed-FFE MMPD lock-range validation assumptions

- `validation/AFE/test_channel_ctle_ti_adc_cdr_ffe_mmpd_lock.m` explicitly composes `cdr_pd.mmpdFast`, `cdr_voter`, `cdr_loop`, and `cdr_pi`; it does not change the BBPD-oriented `cdr_top` interface.
- The timing FFE is open loop with fixed coefficients `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]`, two precursor taps, and a fixed unit main tap. LMS is not active.
- The waveform is deterministic PRBS20 natural-mapped PAM4 at 56 GBd and 128 samples/UI. Channel+CTLE output is scaled to a settled peak of `0.27 V` before the ideal 7-bit `[-0.3,+0.3] V` TI ADC.
- The loop uses 64 UI per update, 80 updates per run, ideal PI phase mapping, integer waveform sampling, and group weights `[2,1,2,1]`.
- The offline MMPD characteristic uses a 13-sample circular moving average only to select a negative-slope zero crossing. Dynamic lock is determined separately from the closed-loop scan.
- One fixed loop configuration is selected from starts at `-3` and `+3` samples around the selected lock, then frozen for all 128 integer initial-phase cases.
- A case passes when its final 20 blocks have absolute mean phase error no greater than 3 samples, phase span no greater than 8 samples, absolute mean drift no greater than 0.25 sample/block, and overall valid-transition density at least 5%.
- The post-FFE maximum-eye diagnostic scans all 128 integer sample phases. At each phase it clusters the valid FFE outputs into four ordered voltage centers and defines eye opening as the minimum of the three adjacent center spacings.
- The histogram assigns each valid FFE output to its nearest center, uses common voltage-bin edges for all four colored traces, and marks the four centers plus their three midpoint thresholds. This is an unlabeled voltage-cluster diagnostic, not a BER or symbol-conditioned eye measurement.

### MMPD-v1 cached Channel+CTLE and fixed-segment S-curve assumptions

- `validation/AFE/test_mmpd_v1/test_channel_ctle_cosim.m` models `PRBS20 PAM4 -> optional TX FFE -> S-parameter channel -> CTLE` only. Its TX FFE code is retained under `if false`, so the default cache has no TX equalization.
- The complete cache contains 524288 natural-mapped PAM4 symbols at 56 GBd and 128 samples/UI. Its 67,108,864-sample CTLE waveform is stored as `single`; the Channel+CTLE impulse response and scalar metadata retain double precision.
- Full waveform generation uses 8192-symbol streaming chunks. Channel input history, CTLE continuous-time state, and the preceding CTLE input sample are carried across chunk boundaries.
- `mmpd_s_curve_own_data.m` reads CTLE UI `[512,16896)` once into memory. All phases use this same 16384-UI vector and differ only in integer sample offset.
- The ADC is ideal except for 7-bit quantization and the `[-4,+4] V` range. Each phase has a fresh ADC/FFE state and processes 256 consecutive 64-UI blocks.
- The CDR FFE uses offsets `[-3,+6] UI` with its coefficient at offset zero fixed to one. The other nine coefficients are solved offline from a quantized one-unit-amplitude Channel+CTLE symbol-pulse response.
- The constrained solve forces normalized total-path `pre1=post1=0.1` relative to main one and minimizes the remaining output cursors over `[-3,+9] UI`. Relative Tikhonov regularization of `1e-8` is applied to the free-tap normal matrix.
- Raw ADC codes are centered by subtracting code 64. CDR-FFE output values are floating-point centered codes; their histogram must not be interpreted as raw 7-bit integer codes.
- The plotted total unit-UI response quantizes a one-unit-amplitude Channel+CTLE symbol pulse at phase 19 before applying the CDR FFE. Because the ADC is nonlinear, this response is amplitude-specific rather than a unique LTI impulse response.
- PAM4 slicer centers are estimated from phase-19 equalized codes. A linear fit maps those centers to full PAM4 amplitudes `[-3,-1,+1,+3]`, and that mapping remains fixed across the scan.
- The offline classic Mueller-Muller diagnostics use signed full-amplitude residuals in `tau[n]=d[n-1]*e[n]-d[n]*e[n-1]`, with `e[n]=y[n]-d[n]`. The unfiltered curve remakes `d` at every phase. A fixed-decision reference instead freezes the phase-19 decision sequence, while a symmetric-live curve retains only current-phase decisions satisfying `d[n]=-d[n-1]` (`-3<->+3` and `-1<->+1`). The comparison axis is centered on phase 19 over `[-0.5,+0.5) UI`; fixed decisions are shifted by one symbol when the raw ADC phase wraps across a UI boundary.
- The CTLE eye diagnostic reads the exact first 1024 cached UI `[0,1024)`; unlike the S-curve analysis segment, it intentionally includes the beginning of the cached waveform.

### Two-stage mu downshift and the eye-quality FOM (2026-09-25)

- The stage-1 (`capture -> settle`) gate uses a **decision-directed** SNR,
  `10*log10(mean(decision^2)/mean(sliceError^2))`, computed per block by
  `cdr_top.blockSnrDb` from the values `slicePam4` already returns. It is
  explicitly **not** truth-referenced: when the eye is closed and a sample is
  sliced to the wrong level, the error is measured against that wrong level, so
  single-block readings can be optimistic. Any conclusion drawn from this FOM
  must therefore rest on its EWMA, never on a per-block value. This was measured,
  not assumed: in a run where no start phase locked, the per-block distribution
  reached 26.56 dB max and 22.55 dB p99, above the 17.50 dB tail minimum of a
  passing run, because a clamped frequency integrator leaves the PI rotating so
  the sampling point periodically sweeps the eye centre.
- `decision` and `sliceError` are already valid-sample-only, since `cdr_top`
  masks the FFE output (`ffeOutput = blockOutput(blockValid)`) before slicing.
  No additional masking is applied when forming the FOM.
- Blocks with no valid samples, or with exactly zero error power, produce a
  non-finite FOM. `loop_monitor.updateSnrSettle` skips those blocks instead of
  folding them into the average, so they can neither poison nor inflate it.
- The EWMA is seeded with the first usable reading rather than with zero, so the
  trigger is not delayed by a ramp-up of order `1/alpha` blocks. `SnrSettleMinBlock`
  is the only warm-up guard.
- Default operating point: `SnrSettleThresholdDb = 15`, `SnrSettleAlpha = 1/128`,
  `SnrSettleMinBlock = 200`. The threshold floor is a measured quantity: 11 dB
  fires inside the closed-eye window and breaks `-100 ppm` acquisition (0/8),
  while `>= 12 dB` works. 15 dB sits ~1.9 dB above the observed closed-eye EWMA
  peak (13.02..13.12 dB) and ~6.6 dB below the open-eye level (21.6..24.4 dB).
- The schedule has three tiers and two events. In the ppm suite dLev uses
  `0.5 -> 0.1 -> 0.02`, while FFE uses `0.001 -> 2e-4 -> 2e-4`; therefore the
  stage-2 (`settle -> PVT tracking`) event changes only dLev at the defaults.
  Its criterion is selectable: center-touch is valid for the stationary
  zero-ppm code path, while frequency-state lock is used by the runner at
  nonzero ppm. This criterion switch does not change the pass/fail lock verdict,
  which additionally requires rotation-period lock for ppm runs.
- The capture-mu FFE step is assumed to be bounded by **cursor walk**, not by
  convergence speed alone: with `FfeAdaptEnableMask = [1 1 0 1 1 1]` the main tap
  is frozen, so the loop can only reshape the pulse through pre/post taps, which
  moves the effective cursor and hence the MMPD zero. Locked-phase spread is
  therefore proportional to the capture step (measured `3/6/12/21` code at 0 ppm
  for `0.001/0.002/0.004/0.008`). The ppm suite uses `0.001`; the `cdr_top`
  library default remains `0.004`.
- `0 ppm` is assumed to be the binding constraint for the downshift *happening*
  and for cursor walk, while `+/-100 ppm` is binding for the downshift *not
  happening too early*. Both directions must be validated together; passing
  either alone does not establish the policy.
