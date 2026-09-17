# Validation

## Scope

This validation record covers current TX, channel, AFE, ADC, and CDR components. `LinkSim` results are not used as evidence for the current model.

## Evidence levels

1. **Execution check**: script completes without MATLAB error.
2. **Behavioral/visual validation**: plots and statistics are reviewed.
3. **Automated regression**: assertions enforce expected values and tolerances.

Most ADC validation is currently level 1-2. The CDR PD validation contains explicit checks, while the PI validation is primarily visual/behavioral.

## Executed validation

All 13 scripts under `validation/` completed with exit code 0 in independent MATLAB batch sessions during the repository reorganization. The run record is `results/validation_summary.csv`.

### TX and S-parameter channel

- MATLAB R2025b automated regression passed 5/5 checks for the default 56 GBd, 128-samples/UI configuration.
- Ideal zero-order hold and row/column orientation were checked exactly.
- The specified four-port Touchstone channel produced finite, nonzero, length-preserving output with a matching time vector.
- The channel output was processed directly by `src/AFE/ctle.m` with preserved shape and finite output.
- Empty, nonfinite, nonvector symbol inputs and invalid rate/oversampling configuration were rejected with stable error identifiers.
- `validation/AFE/test_channel_s21_eye.m` converts the four-port data to differential `Sdd21`, generates 8192 normalized PAM4 symbols from PRBS20, runs the existing TX+Channel model, and plots a 2000-trace 2-UI output eye after discarding 1000 UI.
- The 28 GHz PAM4 Nyquist point is marked on the differential response. Its `Sdd21` magnitude is approximately -14.09 dB, corresponding to a positive insertion loss of 14.09 dB. Without TX or RX equalization, the resulting PAM4 eye is severely closed.
- The saved diagnostics are `results/AFE/channel_sdd21.png` and `results/AFE/channel_output_eye.png`.

### AFE: fixed CTLE

- MATLAB R2025b smoke validation confirmed 0 dB DC gain and exactly 4.5 dB relative gain at the 28 GHz symbol Nyquist frequency for the default 56 GBd configuration.
- Both continuous-time poles were real and in the open left half-plane.
- `lsim` complete-waveform processing preserved row and column orientation, produced finite output, and settled to unity for a DC input.
- `validation/AFE/test_ctle_frequency_response.m` plots the 100 MHz to 100 GHz magnitude response for 128 samples/UI, marks the 28 GHz Nyquist point, asserts the DC and Nyquist gains, and saves `results/AFE/ctle_frequency_response.png`.
- `validation/AFE/test_channel_ctle_cosim.m` passed in MATLAB R2025b using a 2048-symbol preview at 56 GBd and 128 samples/UI. The validation-specific CTLE uses `fz=6 GHz`, `fp1=28 GHz`, `fp2=50 GHz`, and `0 dB` DC gain, giving `9.38 dB` gain at 28 GHz.
- Offline least squares selected TX FFE taps `[0.0214425,-0.144777,0.671335,-0.0844467,0.0698928,-0.00810601]` in `[pre2,pre1,main,post1,post2,post3]` order. Their L1 norm is one and the main tap is positive.
- The final waveform maximum-power phase is 20/128 with label-conditioned separation 1.6543. Scanning true PRBS20 labels selects phase 118/128 with separation 10.3661; therefore maximum power is retained as a diagnostic and is not asserted to equal the best eye center.
- The plotted normalized TX-FFE+Channel+CTLE unit-impulse cursor vector from 3 pre through 6 post is approximately `[0.009373,-0.006758,0.005610,1,-0.314167,0.165436,-0.070889,0.032318,0.008439,-0.003172]`. These impulse-kernel samples differ from the symbol-pulse cursors used by the FFE optimizer because the TX input uses a one-UI zero-order hold.
- The added one-UI symbol-pulse plot is aligned to the optimizer-selected main index. Its normalized `[-3,+6] UI` cursor vector is `[0.00956567,-0.00247827,0.000472663,1,-0.000253635,0.00138516,0.000376327,0.0120371,0.0187156,-0.00855913]`; an assertion matched all plotted cursors to the optimization result within `1.39e-16`.
- A 2048-symbol chunked/batch equivalence check measured maximum absolute errors of `2.89e-15` for the channel and `3.11e-15` for the CTLE.
- A complete cache export contains 524288 PAM4 symbols and exactly 67108864 float32 CTLE samples. The waveform occupies 256 MiB before MAT/HDF5 container overhead.
- Saved outputs include `results/AFE/channel_ctle_cosim/ctle_and_channel_ctle_frequency_response.png`, `tx_ffe_channel_eye.png`, `tx_ffe_channel_ctle_eye.png`, `tx_ffe_channel_ctle_impulse_response.png`, `tx_ffe_channel_ctle_symbol_pulse_response.png`, and `ctle_out_prbs20_full_period.mat`.
- The frequency-response figure is regenerated from the current zero/pole values at the top of the validation script. Exploratory parameter runs may therefore differ from the configuration recorded in an existing waveform cache until that cache is explicitly regenerated.
- Calling `test_channel_ctle_cosim` with no argument runs preview-only eye, impulse, frequency-response, phase-power, and chunk-equivalence checks. Binary MAT cache generation is opt-in through `test_channel_ctle_cosim(true)`.
- MATLAB R2025b binary-cache validation passed with the current `2^16-1`-bit debug setting: 32768 PAM4 symbols produced 4194304 finite `single` final-output samples. Stored TX FFE taps and offsets matched the preview, and `sampleInterval` remained `1.3950892857142857e-13 s` in double precision.

### AFE: Channel, CTLE, TI ADC, and optimized fixed CDR FFE pulse response

- `validation/AFE/test_channel_ctle_ti_adc_cdr_ffe.m` passed in MATLAB R2025b with offline tap optimization, no online LMS adaptation, and no CDR feedback loop.
- The Channel+CTLE pulse was scaled to a `0.24 V` absolute peak and sampled by the ideal 64-lane, 7-bit, `[-0.3,+0.3] V` TI ADC at phase 88 of 128 waveform samples/UI.
- Physical TI ADC lane output was reordered into chronological UI order, its zero-input reconstructed-voltage baseline was removed, and the result was passed through `cdr_ffe`.
- Constrained least squares selected taps `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]` while keeping the main tap fixed at one.
- The normalized cascade output achieved the explicit target `pre1=post1=+0.1`. Other fitted cursors from `-3` through `+8 UI` had approximately `0.01971` RMS and `0.03813` maximum absolute residual.
- `results/AFE/channel_ctle_ti_adc_cdr_ffe/sampled_pulse_response.png` compares the aligned Channel+CTLE analog response, TI ADC sampled response, and CDR FFE output response.
- `results/AFE/channel_ctle_ti_adc_cdr_ffe/cdr_ffe_impulse_response.png` shows the exact standalone FFE unit impulse response.

### ADC: SAR core

- Ideal sine conversion and reconstructed output.
- Capacitor-mismatch comparison using a fixed random seed.
- Differential SAR conversion with held output and saved internal/result data.
- Scalar/vector and fast-path behavior exercised by the available studies.

### ADC: clock-driven SAR channel

- Single-channel TAH plus SAR sequencing.
- Four-channel interleaved sequencing.
- Completed-conversion timing, code output, held voltage, and channel ordering are plotted/saved.

### ADC: TI ADC

- Four-lane ideal sine-wave block conversion.
- 64-lane conversion of `data/ADC/TI_ADC/ctle_out.csv`.
- Sampling-phase scan and code/reconstructed-voltage distributions.
- Ideal, fixed-skew, and Gaussian-jitter clock cases.
- CTLE validation successfully reads from top-level `data/` and writes to top-level `results/`.

### CDR: phase detector

The current validation script passed 10/10 checks:

- NRZ BBPD truth table.
- PAM4 symmetric-edge selection and early/late decisions.
- Polarity inversion.
- Mode selection and exact compact output/state snapshot fields.
- Matrix input.
- Strict value-and-type equivalence between `bbpdFast` and `bbpd` for seeded NRZ/PAM4 row, column, and matrix blocks with both polarities, including verification that the stateless fast path does not modify object state.
- Cross-block equivalence for five consecutive 64-symbol blocks using explicit previous-symbol overlap in the caller/top-level.
- Invalid digital mode/symbol/edge/shape rejection.
- PAM4 MMPD all-transition weighted truth tables, binary-error agreement filtering, polarity, validated/fast equivalence, column orientation, state isolation, unsupported NRZ mode, and invalid-input rejection.
- Waveform decision sequence with slicing performed outside the digital PD.

### CDR: phase interpolator

- Code wrapping across multiple UI.
- Wrapped and accumulated phase/index behavior.
- UI-slip tracking.
- Default nonideal phase-table visualization.

### CDR: voter

The automated regression under `tests/CDR` passed 7/7 checks:

- Default 64-decision linear vote and `int16` output.
- Constant-mode positive, negative, and tied votes.
- Row/column-vector equivalence.
- `voteFast` equivalence for linear and constant modes.
- Runtime mode update.
- Invalid shape, block length, decision value, and nonfinite-input rejection.
- Invalid mode, block size, and constant magnitude rejection.

### CDR: loop filter

The automated regression under `tests/CDR` passed 10/10 checks:

- Current-error proportional/integral update order.
- Positive and negative fractional-code residue accumulation.
- Configurable integral saturation and reverse-error recovery.
- Numeric inputs representing either voter mode without a mode-dependent interface.
- Validated and scalar fast update-path equivalence.
- Integer `deltaCode` compatibility with `cdr_pi`.
- Runtime gain/limit configuration and dynamic-state reset.
- Default one-code output limiting, raw-versus-applied delta observability, explicit pending-code retention/cancellation, configurable limits, and reset behavior.
- Invalid gain, limit, and phase-error rejection.

### CDR: digital top level

The automated regression under `tests/CDR` passed 6/6 checks:

- PD, voter, loop-filter, and PI component scheduling.
- Current-block sampling index versus next-block PI update timing.
- Previous-symbol preservation across consecutive blocks.
- Row- and column-vector block handling.
- Coordinated reset of top-level, loop-filter, and PI dynamic state.
- Validated/fast path equivalence and invalid input/configuration rejection.

### CDR: NRZ/PAM4 ideal-edge top-level convergence

`validation/CDR/test_cdr_top_convergence_nrz.m` closes the digital CDR around
an ideal 128-samples/UI NRZ waveform using external zero-threshold data and
edge slicing. Alternating symbols provide one transition per UI, and the true
edge is offset by 24 waveform samples from the nominal boundary.

The NRZ validation passed its numerical checks:

- All 64 decisions were valid in every 64-UI block.
- The voter output changed sign after the PI crossed the true edge.
- The PI sampling phase moved from sample 0 to the target and remained between samples 23 and 24 over the final 16 blocks.
- The saved convergence plot is `results/CDR/cdr_top_phase_convergence_nrz.png`.

`validation/CDR/test_cdr_top_convergence_pam4.m` independently exercises both
PAM4 transition families selected by the current BBPD: outer `0<->3` and inner
`1<->2`. Each case contains 64 blocks of 64 UI and uses ideal PAM4 levels with
three-threshold data slicing and center-threshold edge slicing.

The PAM4 validation passed its numerical checks for both cases:

- Every UI produced a valid selected transition.
- Both voter outputs reversed sign after crossing the true edge.
- Both PI phase traces converged from sample 0 to the 23/24-sample limit cycle around the true edge at sample 24.
- The saved comparison plot is `results/CDR/cdr_top_phase_convergence_pam4.png`.

Nearest-sample rounding is local to this validation and is not evidence for a
project-wide sampler rounding decision.

### CDR: CTLE waveform acquisition and tracking

`validation/CDR/test_cdr_top_ctle_waveform.m` reads the PAM4 CTLE output from
`data/ADC/TI_ADC/ctle_out.csv`. The fixture contains 640000 samples, equivalent
to 5000 UI at 128 samples/UI; the closed-loop test uses 4096 UI in 64 blocks.

The script performs fixture-local calibration and reference measurement before
starting the CDR from phase zero:

- Calibrated PAM4 centers: approximately `[-0.22934, -0.07477, 0.07905, 0.22904] V`.
- Calibrated slicer thresholds: approximately `[-0.15205, 0.00214, 0.15404] V`.
- Maximum-power data phase: sample 84; corresponding power-derived edge phase: sample 20.
- BBPD S-curve statistical lock phase: sample 15.

A local gain scan compared `Kp={0.0625, 0.125, 0.25}` with
`Ki={0, 0.0005}`. The default `Kp=0.0625`, `Ki=0.0005` combination retained a
small integral path while producing a mean final-16-block phase error of about
`-0.344` sample and a 1-sample steady-state span, the best combined result in
that scan.

The automated checks passed:

- 1032 selected PAM4 transitions were available across 4096 UI.
- The voter output changed direction around the tracked edge.
- The final 16 blocks remained between PI phases 14 and 15 samples.
- Mean final-16-block error relative to the BBPD statistical lock phase was approximately `-0.344` sample.
- No excessive steady-state phase drift was detected.
- The saved diagnostic plot is `results/CDR/cdr_top_ctle_convergence.png`.

This validation directly slices CTLE voltage and does not include the future
dedicated CDR FFE or TI ADC quantization. The fixture has no transmitted symbol
labels, so BER is not evaluated.

### CDR: CTLE waveform MMPD tracking

`validation/CDR/test_cdr_top_ctle_waveform_mmpd.m` uses the same fixed CTLE
fixture and calibrated PAM4 levels to derive symbol decisions and binary
level-error directions. It measures an offline baud-rate MMPD S-curve and
explicitly composes `cdr_pd.mmpd`, voter, loop filter, and PI over 4096 UI.

The measured maximum-power data phase is 84 samples and the selected weighted
MMPD statistical lock phase is 82 samples. Because the baud-rate detector is
used as a limited-range tracker, the one-code-slew-limited constant-voter loop
starts at sample 74. A deterministic scan selected `Kp=0.5`, `Ki=0.005`, and
polarity `+1`.

The automated checks passed:

- Sufficient weighted PAM4 transitions were available.
- The voter output reversed direction around lock.
- The final 16-block mean phase error was -0.25 sample.
- The final 16-block phase span was 0.5 sample with no excessive drift.
- The diagnostic plot is `results/CDR/cdr_top_ctle_convergence_mmpd.png`.

### CDR: weighted all-transition MMPD v1

`validation/CDR/test_cdr_top_ctle_waveform_mmpd_v1.m` exercises all PAM4
transitions with 2x weight for the symmetric pairs and 1x weight for all
asymmetric pairs. It uses a 64-UI linear voter, 50 loop updates over the same
3200 unique UI, and explicitly unlimited delta code.

The offline loop S-curve is normalized over all UI rather than only valid
events. The corrected scan evaluates every integer initial phase over one UI;
its continuous acquisition result is recorded below. The convergence result is
saved to `results/CDR/cdr_top_ctle_convergence_mmpd_v1.png`.

The same validation also separates the characteristic into all 12 directed
non-static PAM4 transition classes. For each class it records the weighted
unconditional contribution, conditional mean decision, and valid-event count.
An automated assertion verifies that summing the 12 unconditional class
contributions reconstructs the aggregate loop S-curve to numerical precision.
The per-transition diagnostic is saved to
`results/CDR/cdr_top_ctle_mmpd_v1_transition_scurves.png`.

The 12 directed classes are also combined, without changing their existing
decision polarity or weights, into four PAM4-symmetric groups: adjacent outer
(`0<->1` and `2<->3`), skip-one (`0<->2` and `1<->3`), outer symmetric
(`0<->3`), and inner symmetric (`1<->2`). A second reconstruction assertion
checks that the four group contributions sum to the aggregate characteristic.
The group diagnostic is saved to
`results/CDR/cdr_top_ctle_mmpd_v1_symmetric_group_scurves.png`.

A validation-layer exhaustive search then applies primitive integer group
weights in `[0,4]` to unit-weight group contributions. Zero crossings are
classified after a 9-sample circular moving average; negative-slope crossings
are stable for the tested polarity. The score favors a stable crossing near the
maximum-power phase, a wider interval between surrounding unstable crossings,
fewer additional stable crossings, and larger local slope.

The selected weights are `[G1 G2 G3 G4]=[2 1 2 1]`, versus the earlier
`[1 1 2 2]`. The smoothed offline characteristic has one stable crossing at
phase 83.87, 0.13 sample from the maximum-power phase 84. Its static basin spans
the circular UI except for the opposing unstable crossing, but this is not
treated as demonstrated dynamic acquisition. With the corrected 64-UI cadence,
the closed-loop scan tests every integer initial offset over one UI. Its
continuous passing interval is `[-14,+18]` samples around lock, or requested
initial phases 69.87 through 101.87; the width is 32 samples (0.25 UI). An
isolated passing point at phase 104.87 (`+21` samples) is excluded from the
continuous acquisition range because the intervening `+19` and `+20` cases
fail. The farthest isolated case selects `Kp=0.5`, `Ki=0.001`, and polarity
`+1`, with a final-window mean error of about 0.905 sample, a 4.5-sample span,
and drift of about 0.237 sample/update. The weight comparison is saved to
`results/CDR/cdr_top_ctle_mmpd_v1_group_weight_search.png`.


## Source-side studies not treated as regression tests

`src/ADC/ADC_sample_CTEL_output` contains:

- Threshold-based leading-delay estimation.
- Normalized TX-to-CTLE cross-correlation delay estimation.
- Two-UI eye-diagram plotting.
- Maximum-power phase selection.
- CTLE sampling through SAR ADC fast interfaces.
- ADC code and reconstructed-voltage distribution plots.

These studies provide useful diagnostics, but they currently live in `src`, depend on large waveform fixtures, and mostly lack numerical pass/fail limits.

### Caller-assembled CDR FFE window regression

- MATLAB R2025b ran `tests/CDR/test_cdr_ffe.m` and passed 7/7 checks.
- The checks cover the default main-only response, configured six-tap FIR mapping, exact regressor rows, the fixed double row-vector output contract, validated/fast equivalence, fixed-main coefficient update and reset, short or malformed windows, and invalid configuration.
- MATLAB `checkcode` reported no issue for `src/CDR/cdr_ffe.m`.

### CDR FFE block LMS regression

- MATLAB R2025b ran `tests/CDR/test_cdr_ffe_loop.m` and passed 8/8 checks.
- The checks cover the `desired-output` update sign, block-length normalization, validated row/column error inputs and `double` conversion, validated/fast delta equivalence, optional fast-path gradient output and single-output compatibility, fast-path diagnostic-state isolation, arbitrary adaptation masks with a fixed main tap, runtime step-size changes and reset, invalid input/configuration rejection, and minimal integration with `cdr_ffe`.
- MATLAB `checkcode` reported no issue for `src/CDR/cdr_ffe_loop.m` or `tests/CDR/test_cdr_ffe_loop.m`.

### Fixed-phase Channel+CTLE/TI-ADC/CDR-FFE adaptation

- MATLAB R2025b ran `validation/CDR/test_subBlock/test_cdr_ffe_adaptation.m` on 16384 UI from the complete Channel+CTLE fixture at fixed zero-based phase 20. The ideal TI ADC configuration was 64 lanes, 7 bits, and `[-4,+4] V`.
- The bounded delay scan selected 105 UI with normalized correlation 0.922208. Subtracting ADC zero code 64 and fitting the first 4096 aligned training samples produced one frozen PAM4 scale of approximately 0.078439.
- The initial step-size list was `[1e-5,3e-5,1e-4,3e-4,1e-3,3e-3,1e-2,3e-2]`. Supervised-only acceptance selected `mu=0.01` with tail MSE 0.0343438; the primary 8192-supervised/8192-DD split passed, so fallback was not used.
- Final coefficients were approximately `[0.1039,-0.3756,1,0.1728,0.0071,0.0265]`. During the DD half, SER was zero, truth and decision MSE were both approximately 0.0343555, minimum adjacent known-label level opening was 1.89755, final 16-block coefficient span was 0.002199, and maximum tail delta was 0.001158.
- The machine checks enforce the documented supervised ratios/span/delta thresholds and independent DD SER/MSE/opening/span/delta thresholds. MATLAB `checkcode` reported no issue for the validation file.
- Outputs are `mu_scan.png`, `coefficient_convergence.png`, `mse_convergence.png`, `before_after_histogram.png`, and `result.mat` under `validation/CDR/test_subBlock/result/test_cdr_ffe_adaptation`.

### v3 terminal adjacent-pair PI lock regression (2026-09-16)

- `tests/CDR/test_detect_pi_dither_lock.m` passed 9/9 check groups in MATLAB R2025b. Coverage includes exactly 50 versus 51 transitions, dwell counting, constant/monotonic/three-code rejection, historical lock followed by drift, pair reset and relock, whole-UI slips, signed wrap invariance, row/column equivalence, empty/invalid input, and 1000 seeded random traces against an independent exhaustive segment/suffix oracle.
- The criterion is terminal, not historical: only the final contiguous fixed adjacent pair can qualify, with at least 51 actual jumps. Dwell neither counts nor resets; leaving the pair resets. Both `[-1,0]` and `[127,128]` identify wrapped pair `[127,0]` with the same reported integer center. No maximum dwell duration is assumed.
- Before correction, the standalone detector returned true for 59 adjacent-pair transitions followed by monotonic drift to code 80, and false for 59 transitions with three-block dwell per visited code. The new tests cover both failure modes.
- Integration replay explicitly used `DlevOuterInit=36`, `DlevInnerInit=12`, `SaveOutputs=false`, 8000 blocks, and all 32 starts. Runtime was 73.568 s. All eight checked dynamic traces matched the retained MAT exactly: wrapped phase, UI slip, unwrapped phase, phase error, delta code, inner/outer dlev, and FFE coefficients. This demonstrates no change to loop dynamics for the tested configuration.
- The new **convergence result is 0/32**, versus the stored legacy 32/32 result. Every terminal pair contains only one transition; no start meets 51. `AllPhaseLock=false`, claimed lock centers/common phase are `NaN`, and cursor evaluation falls back to reference phase 19. Test success must not be confused with the modeled loop meeting this stricter convergence requirement.
- `checkcode` reports no issue in the detector or its test; v3 retains only the pre-existing `ISCL` suggestion. Existing result MAT/PNG files were not regenerated. Logs and returned replay result are session-scoped under `$PICODE_ARTIFACT_DIR/pi_dither_tests.log`, `pi_dither_integration.log`, and `pi_dither_integration_result.mat`.

### v3 PRBS22 single-start 20000-block observation (2026-09-16)

- MATLAB R2025b execution passed in 18.014 s with `StartPhaseList=20`, `CosimDir='channel_ctle_cosim_prbs22'`, `TxFile='tx_prbs22.mat'`, `AnalysisNumUi=1280512`, anchors outer/inner=36/12, Kp/Ki=8/0.03, dlev mu=0.3/0.1, FFE mu=0.02/1e-4, 500 training blocks, and `SaveOutputs=false`. The complete PRBS22 cache has 2,097,152 PAM4 symbols, and the cached Channel+CTLE impulse exactly matches PRBS20.
- Assertions verified one start at phase 20, exactly 20000 blocks, finite dynamic arrays, and main FFE tap exactly one. Detector regression passed 9/9 after the `StartPhaseList` option was added. Static analysis reports only the existing `ISCL` style suggestion.
- Mean phase in non-overlapping 2000-block windows after the first 2000 blocks: `[13.351,13.1625,12.965,12.7415,12.6055,12.421,12.227,12.097,11.9375]`. Thus a slow center drift remains visible through 20000 blocks despite narrow-band instantaneous jitter.
- Last 2000-block code range is 10..14, mean 11.9375, std 0.760844, and fitted total drift -0.216043 code; last-8000 fitted drift is -0.639896 code. Post-training UI slip remains -1. Strict terminal-pair `LockedFlag=false` (one final 10/11 transition), but the finite-window statistics must be considered separately from that deliberately restrictive pattern criterion.
- Single-start cross-phase consistency flags are vacuous (zero spread with one sample); they do not verify temporal dlev/FFE convergence. The run uses a different PRBS order, not an extension of the exact PRBS20 symbol sequence. Only execution/shape/invariant checks are asserted, not BER, all-start acquisition, or infinite-time stability.
- Evidence: `$PICODE_ARTIFACT_DIR/prbs22_start20_20000blocks.log`, `prbs22_start20_20000blocks_result.mat`, and `prbs22_start20_20000blocks_phase.png`. The plot shows the full trace, post-training trace with 500-block means, and the final 200 blocks. Existing result files were not overwritten.

### v3 terminal modal-center touch/cross trial (2026-09-16)

- The independent diagnostic `results/CDR/pi_center_touch_trial/trial_center_touch_lock.m` evaluates a saved result only: modal center from final 2000 unwrapped codes, counting on those same 2000 blocks, inclusive center +/-3-code band, arrival-at-center or direct-cross events, no extra dwell/departure count, and reset on any band violation. More than 50 retained events passes. Center touches followed by same-side return explicitly qualify per user instruction.
- Synthetic checks passed for touch-and-return, touch-and-cross, repeated center dwell, direct crossing, constant center, repeated visits, upper/lower band violations, inclusive boundaries, exactly 50/51 counts, and negative unwrapped-code coordinates. On the real trace the state-machine event mask and retained count exactly matched an independent vectorized oracle.
- PRBS22, 20000 blocks, initial phase 20, anchors 36/12: only blocks 18001..20000 were evaluated. Center=12 with 1000 occurrences; actual code range=10..14 within permitted 9..15; out-of-band count=0; 168 arrivals + 10 direct crossings = **178 retained events, pass**. Last-200 count=17. Event 51 occurs at block18588 within the selected window, not necessarily the full trace's first lock instant.
- Output PNG/MAT are `results/CDR/pi_center_touch_trial/trial_center_touch_trial.png` and `trial_center_touch_result.mat`; execution log is `$PICODE_ARTIFACT_DIR/trial_center_touch_validation.log`. No new simulation was run and no saved source result or production detector was overwritten. This is a single-start finite-window criterion trial only.

### v3 PRBS22 20000-block 32-start modal-center lock regression (2026-09-16)

- MATLAB R2025b completed the explicitly configured 36/12-anchor run in 213.954 s: `CosimDir='channel_ctle_cosim_prbs22'`, `TxFile='tx_prbs22.mat'`, `AnalysisNumUi=1280512`, `StartPhaseList=0:4:124`, Kp/Ki=8/0.03, dlev mu=0.3/0.1, FFE mu=0.02/1e-4, 500 training blocks. `ResultDir` isolates all outputs under `results/CDR/prbs22_20000blocks_allphase_center_touch/`.
- All 32 per-start phase-lock flags pass the last-2000 modal-center +/-3-code criterion, with 143..186 retained arrival/direct-cross events and zero band violations for every start. `AllStartsConverged=1`, `AllPhaseLock=1`, common code=13, mode range=11..14, and circular spread=3. The lock-phase plot's ordinate is the measured final-window mode, not an average or final instantaneous sample.
- An independent vectorized oracle verifies all 32 modal codes, event masks, retained counts, violation counts, and final flags. The start-20 seven checked phase/error/dlev arrays plus FFE coefficient tensor exactly match the prior single-start run. Its final mode/count are 12/178. New detector tests pass 9/9 groups with 100 seeded oracle cases; historical strict detector tests remain 9/9. New helper `checkcode` is clean; tests have two nonfunctional style/analyzer advisories and v3 retains the existing `ISCL` suggestion.
- One tie exists at start 96: codes 13 and 14 each occur 841 times. The documented deterministic lowest-unwrapped-code convention selects 13. Independent sensitivity check: center13 gives157events, center14 gives150events, both without violations and both pass. A temporary assertion that every mode was unique was therefore removed from the manual verification assumptions; the saved mode array matches MATLAB `mode` exactly.
- Separately, `FfeConsistent=false`: max cross-start coefficient spread=0.0255797 exceeds0.02. `FfeConstraintHeld=false`: pre1=-0.0382, post1=-0.0687 exceed the +/-0.02 cursor limits. Phase-lock success does not imply these FFE precision checks pass.
- Native PNG/MAT outputs and `lock_summary.csv` are in the isolated directory above. Execution log is `$PICODE_ARTIFACT_DIR/prbs22_20000blocks_allphase_center_touch.log`. This covers the 32 sampled starts, not every integer phase, BER, or infinite-time stability.

### v3 slowest first-capture convergence plotting (2026-09-16)

- `tests/CDR/test_select_slowest_pi_capture.m` passed9/9 groups: touch/direct-cross/dwell counting, inclusive bounds, resets before capture, later resets preserving the first timestamp, final-lock eligibility, maximum-time tie order, no eligible case, full-history detection before the last2000 blocks, unwrapped shift invariance, flag shape handling, and invalid inputs. The existing modal-center detector also passes9/9.
- Replay of the full PRBS22/20000-block/36-12-anchor/32-start run completed in146.178s with final phase lock32/32 unchanged. Eight full dynamic trace arrays and three lock-result arrays are exactly equal to the preceding saved all-phase run. Selector output is row25/start96, first capture9849, modal code13; start76 has first capture8569. All32 per-start first-capture times are saved in `first_capture_summary.csv`.
- The phase plot contains one selected phase trace; dlev contains that same start's inner/outer traces; each free-tap FFE subplot contains one trace from that same start. All annotate the PI first-capture block, explicitly not an FFE/dlev settling time. Selection uses final-locked starts only and renders placeholders rather than a falsely selected unlocked trace when no candidate qualifies.
- Output files in `validation/CDR/test_cdr_dlev_cdrffe/result/cdr_dlev_cdrffe_sslms_v3/` were regenerated at the user's request, including a complete MAT with selected-phase metadata and `impl_notes.md`. The old isolated all-phase result under `results/CDR/prbs22_20000blocks_allphase_center_touch/` remains unchanged. Runtime log: `$PICODE_ARTIFACT_DIR/v3_slowest_first_capture_validation.log`.
- FFE cross-start consistency and cursor precision still fail their existing checks. This plotting change makes no additional physical convergence claim, does not alter the final-window phase-lock rule, and changes no loop dynamics/default gains or nominal anchors.

### Phase-96 training-vote replay and frozen-FFE causal control (2026-09-16)

- Reconstructed 501 actual 64-lane ideal ADC blocks from the saved phase/slip trace and the PRBS22 cache, then replayed first500 FFE outputs with the recorded pre-update coefficient state, three-past/two-future window, and105-UI golden delay. Predicted dlev SS-LMS increments match all500 recorded updates (including skipped first-block adaptation) within2.84e-15. Aggregate outer |output| medians for blocks81..160 and221..300 are34.48047 and34.95375; the net outer votes change from negative to positive as the FFE/phase output distribution moves. This verifies the implemented update direction, not an assumption that the terminal amplitude was fixed throughout training.
- Phase-loop replay from recorded timing errors exactly reproduces all20000 `DeltaCodeTrace` values. Maximum pending backlog=0; maximum |delta|=4. The early integral state remains negative after first crossing the final-band neighborhood (about-0.298 at31, -0.204 at150), consistent with the observed transient overshoot.
- Freeze control: start96, all baseline settings preserved except `FfeStepSizeSettle=0`, `SaveOutputs=false`. Execution completed in20.262s; dynamic prefix through499 is identical and all FFE coefficients remain exactly constant from500. Baseline mean phase501..2500 and18001..20000:15.1255/13.4660. Frozen FFE:15.2020/15.1395. Hence most long phase drift disappears when continued FFE adaptation is removed while timing/dlev remain active. This is diagnostic evidence for coupled moving equilibrium, not adoption of frozen adaptation as a solution.
- Same-trace metric sensitivity: choosing tied final mode13 versus14 changes first51-event time from9849 to1522, while both centers pass the final-window lock check. First-capture ranking must therefore be interpreted as the documented retrospective metric, not an invariant physical acquisition-time measurement.
- Logs/MAT evidence are session-scoped `phase96_freeze_ffe_diagnostic.log`, `phase96_frozen_ffe_result.mat`, `phase96_training_votes_retry.log`, and `phase96_training_replay.mat`. The first training replay attempt failed on unsupported MatFile linear indexing; retry reads the impulse variable before reshaping and passes. No production model or saved baseline plots/results were changed.

### Causal FFE write-freeze and fixed-tap 2048-UI eyes (2026-09-17)

- `test_ffe_freeze_monitor` passes9/9 groups, `test_build_cdr_ffe_eye`7/7, `test_build_cdr_ffe_eye_pair`6/6, `test_cdr_ffe_freeze_integration`5/5, `test_select_slowest_pi_capture`9/9, and `test_detect_pi_center_touch_lock`9/9. These cover causal100-occurrence/50-event gates, ties, reset/research, permanence, actual ideal TI-SAR equivalence, tap direction, density conservation, exact freeze+1 block selection, signed-slip physical bounds, short/truncated/not-frozen windows, and real2500-block freeze-on/off prefix/write/proposal invariants. Helpers do not infer lock from future data.
- Full PRBS22/20000-block/36-12-anchor/32-start run completed in227.597s. Every start freezes in1214..1465 with50 events after >=100 modal occurrences, and all32 final phase criteria pass with146..184 events and0 band violations. Common phase14/spread4. Effective coefficients are exactly constant after each freeze; calculated raw deltas remain finite/nonzero. Coefficient prefix before each veto and phase/dlev prefix through the veto block match the unfrozen baseline exactly.
- Recomputed slowest selected start44: first PI capture1222, FFE freeze1465, freeze mode12, final mode13. Freeze eye starts exactly at block1466/segment UI94015 and uses2048 UI; final eye starts segment UI1278207 and ends at the final physical block endpoint. Both grids are128x2048 and each2-UI density contains524032 observations. Replaying the actual64-lane TI-ADC and FFE at phase0, marker,64,127 reproduces both eye grids' first64 outputs with zero error. Markers retain physical cached-UI coordinates rather than shifting the plots.
- Individual/combined eye figures, updated MAT and per-start summaries are in the user-requested v3 result directory. `SaveOutputs=false` is tested without creating files; eye sample count is configurable and insufficient data is not filled using earlier/pre-freeze samples. Logs: `$PICODE_ARTIFACT_DIR/ffe_freeze_integration_tests.log` and `v3_online_freeze_full_validation.log`.
- Final delivery replay after adding native CSV export and freeze-time plot markers completed in164.409s;12 diagnostic/dynamic arrays and both eye grids exactly match the first passing freeze run. Native capture/freeze CSVs match the saved MAT, including selected start44, first capture1222 and freeze1465. A first export attempt used incorrect result-field aliases and failed at `FfeFreezeCenter`; the four CSV field references were corrected, the export block smoke-tested, and the complete rerun passed. Final replay log: `$PICODE_ARTIFACT_DIR/v3_freeze_final_delivery_retry.log`.
- Separate FFE precision failures remain: coefficient spread0.02964>0.02 and pre1/post1=-0.0506/-0.0587. A permanent write freeze trivially removes temporal coefficient variance, which must not be treated as proof of optimum equalization or BER. This test covers32 sampled starts, not every integer initial phase.

### PRBS20/8000-block return with FFE freeze (2026-09-17)

- Same previously validated loop/freeze configuration and explicit36/12 anchors, but `CosimDir='channel_ctle_cosim'`, `TxFile='tx_prbs20.mat'`, `AnalysisNumUi=512512`;32 starts `0:4:124`. The executable defaults already select this cache/length, so no algorithm/source edit was required. Full execution completed in151.295s.
- All32 starts freeze (blocks1229..1573) and pass their individual final-window phase criterion (154..192 retained events,0 violations). `AllStartsConverged=true`, but `AllPhaseLock=false`: common15 with modal span11..17; starts28/32 at11 exceed common+/-3. FFE coefficient spread0.0444016 and cursor checks still fail their existing precision gates.
- Slowest first capture is start36 at1180, freezing1525 with both marker centers16. The latest FFE freeze is separately start64 at1573. Freeze eye starts block1526/segment UI97856, final eye starts510208; each2048UI, exactly524032 density observations, with correct final endpoint512256 and shared frozen taps.
- Independent mode/event and selector verification, post-freeze tap/write invariants, config/shape checks, eye boundary/marker/density checks, and nativeCSV consistency all passed. Monitor9/9, eye-pair6/6 and selector9/9 tests also passed. Existing v3 output files were regenerated as requested, with the current configuration saved in MAT and implementation notes. Log: `$PICODE_ARTIFACT_DIR/v3_prbs20_8000_freeze_validation.log`.

### Fixed48/16 three-loop gain search and all-start validation (2026-09-17)

- Baseline is the actual user working-copy configuration at task entry: PRBS22/16000 blocks,32starts, anchors48/16, Kp/Ki8/0.03, dlev mu0.3/0.6, FFE mu0.02/0.01, training1000, freeze500 occurrences/100events. It gives21/32 individual locks,14/32 freezes, AllPhaseLock=false. This must not be confused with the earlier36/12 fixture.
- Saved21 candidate rows in `tuning_48_16_search.csv`, screened on8/9 representative starts; finalists were checked on all32 starts. CandidateD03 changes dlev settle mu to0.1 and FFE mu to0.0018/0.0002 while keeping all physical assumptions, anchors, phase gains, training length and freeze/final acceptance gates unchanged. Final no-argument run takes159.318s and matches the parameterized finalist in seven checked arrays.
- PRBS22/16000 no-arg:32/32locks,32/32freezes, AllPhaseLock=true, common21/modes20..22/spread2, tail events141..174,0violations. dlev consistency passes; mean inner/outer12.0440/36.2132. FFE coefficient spread0.013181 passes0.02 and pre1/post1+0.003673/-0.010433 pass +/-0.02. Freeze range4867..6027. Selected start104 first captures3973 and freezes5086; both2048UI eye windows are valid, markers22 and21, with density conservation checked.
- Capture caveat verified from unwrapped data: final UiSlip ranges-73..-66, last changes2331..2569, all before freezing. Multiple acquisition slips are permitted by the current fixture and explicitly reported; this is not a rapid/no-slip acquisition or BER validation.
- PRBS20/8000 independent holdout (same anchors/gains/training/freeze) takes51.80s and passes32/32locks/freezes, common21/modes19..21/spread2, min139events/no violations; FFE spread0.013025 and pre1/post1+0.004559/-0.012932 also pass. Per-start data are in `tuning_48_16_prbs20_holdout.csv`. Main saved MAT/PNG remain the current PRBS22/16000 no-argument result.
- All seven regression suites pass54 groups. The real freeze-integration regression pins its original PRBS20,36/12,500-training,.02/1e-4 fixture rather than inheriting new tunable defaults. Evidence logs/MAT intermediates are session-scoped `tune48_baseline`, `tune48_screen_a/b/c/d`, `tune48_full_c05`, `tune48_full_d03`, `tune48_noarg_final`, and `tune48_prbs20_holdout`. Initial background-launch failure produced no usable result and was excluded; foreground batches provide all reported measurements.

### dlev initial-state versus FFE training-target/crop controls (2026-09-17)

- Fixed initial PI124, currentPRBS22/8000, dlev/FFE gains and freeze thresholds unchanged. Original outer/inner20/(20/3),36/12,48/16 lock at123,13,20 respectively;20/7 locks126. Different actual frozen coefficients and output levels were retained. The missing exact inner20 setting in the user report is explicitly handled by testing both20/3 and7 rather than claiming an exact reproduction of an unspecified pair.
- Common waveform control uses segment UI510000 with2048 identical target UI for each equalizer. Known-symbol5-95% adjacent-level opening peaks at123,13,20,126 respectively; independent data labels handle the represented symbol across the phase wrap without shifting waveform coordinates. Holding each tap vector fixed across the four native crop windows gives zero best circular density shift in all16 comparisons. All crop positions and slips are integer UI and raw channel delay is fixed.
- Diagnostic-only copy fixes supervised FFE targets36/12 while preserving varying dlev initial states. Modes become13 for all four pairs. At36/12 the copy exactly matches production's entire phase and FFE trajectories. A separate production planA fixed-FFE control (no training, zero FFE step) produces mode22 for all20/36/48 initial states, mean phases22.138/22.125/22.122. Controls demonstrate the dual initial-state/training-anchor role is the principal cause of the large observed shift, not output-window truncation.
- Eye7/7, eye-window6/6, modal-lock9/9 and first-capture9/9 regressions pass; assertions verify fixed-tap constancy, control-copy equivalence, modal agreement and all zero crop alignment shifts. Finite2048-symbol diagnostic zero decision errors at selected phases are not BER qualification.
- Evidence is isolated under `results/CDR/dlev_init_phase_diagnostic/`: `anchor_phase_comparison.csv`, `anchor_phase_diagnostic_result.mat`, `same_window_different_ffe_eyes.png`, `anchor_phase_causal_comparison.png`, `cdr_anchor_control.m`, `impl_notes.md`. No production v3/source settings or standard result files were changed. The friend's plot is not a verified equivalent implementation; it declares a4x coarser UI/code spacing and has different unknown phase/reference conventions.

### Independent dlev initialization and supervised FFE reference (2026-09-17)

- Production defaults are initial outer/inner48/16 and separate FFE training outer/inner36/12. New `test_cdr_ffe_training_reference` passes5/5 groups: default state/ref metadata and skipped first-block adaptation; independent initialization override through name/value calls; reference-only training effect; exactly identical DD-only trajectories with different unused references; invalid finite/positive/real/scalar/order validation before cache access. Together with the prior seven suites this gives59 passing groups. The freeze integration test explicitly pins its36/12 FFE refs.
- No-arg PRBS22/8000-block/32-start run completes in113.757s, with32/32 locked and frozen, AllPhaseLock=true, common13/spread3, modes11..14 and138..175 final events without violations. Initial trace values are exactly48/16 for all starts and saved programmed references are exactly36/12. Independent event counting verifies every final lock count. Applied coefficients are constant after freeze.
- At start124, seven phase/error/dlev arrays and the FFE tensor exactly match the previous diagnostic-copy48/16 state with fixed36/12 target. A separate run explicitly setting both state and reference36/12 matches eight arrays from the original coupled36/12 production run. This verifies the split itself without assuming every different initialization must have identical real-valued steady state.
- Selected start36 has first capture3076 and freeze4655; freeze/final markers13/13, each eye2048UI and density524032. Main MAT, convergence/lock/eye plots and CSVs in the v3 result directory were regenerated. FFE consistency and cursor checks do NOT pass: coefficient spread0.020369>0.02, pre1/post1=-0.036527/-0.070715. This task did not retune gains or relax any metric.
- `checkcode` reports only the existing v3 `ISCL` suggestion. Logs are session artifacts `split_ffe_reference_tests.log` and `split_ffe_reference_noarg.log`. No automatic commit or new physical gain model was introduced.

## Validation gaps

- No exact quantizer-boundary and saturation regression shared by all SAR implementations.
- No formal cross-comparison tolerance among SAR variants.
- No automated TI ADC lane-rotation and impairment-index golden vectors.
- No test of fractional PI index integration with an interpolating sampler.
- No jitter transfer, jitter tolerance, bathtub, or BER validation.
- No correlation against circuit simulation or measured ADC/CDR data.

## Recommended automated regression set

1. SAR codes at rails, midscale, every selected code boundary, and saturation points.
2. Debug/fast and scalar/vector equivalence under deterministic ideal conditions.
3. Seeded nonideal repeatability.
4. TI ADC lane order and block rotation.
5. Clock indices for ideal, common skew, per-phase skew, and seeded jitter.
6. `ti_adc_top` input-margin and out-of-range behavior.
7. Complete NRZ/PAM4 BBPD truth tables, polarity, transition selection, and array-shape behavior.
8. Voter linear/constant golden vectors across supported block sizes and integration with PD block output.
9. PI positive/negative wrap, multiple-UI slip, ideal LUT linearity, custom LUT, and `updateFast` contract.
10. Minimal closed-loop PD/voter/loop-filter/PI/TI-ADC smoke test.

Every regression should state the input, expected result, tolerance, random seed, and physical rationale.

### Joint TI ADC and CDR CTLE tracking

`validation/CDR/test_ti_adc_cdr_joint_ctle.m` reads the fixed CTLE fixture and closes a baud-rate timing loop through `ti_adc_top`. Each block contains 64 UI sampled by 64 physical ADC lanes. The output codes are reordered into chronological UI order before the DSP produces PAM4 data and binary error decisions for the MMPD.

The automated checks passed in MATLAB batch mode:

- All ADC codes stayed within the 7-bit range and all DSP data decisions stayed within `0..3`.
- The ADC-code-domain MMPD statistical lock phase was sample 82; the loop started at sample 74 and ended at sample 83.
- 1662 valid MMPD events were observed over 4096 UI, and the voter output reversed direction around lock.
- The final 16 blocks had -0.656-sample mean phase error, 2.5-sample phase span, and 0.133 sample/block mean drift.
- The diagnostic plot is `results/CDR/ti_adc_cdr_joint_ctle_convergence.png`; the numerical result is `results/CDR/test_ti_adc_cdr_joint_ctle_result.mat`.

### Generated Channel+CTLE+TI ADC+fixed CDR FFE MMPD lock range

`validation/AFE/test_channel_ctle_ti_adc_cdr_ffe_mmpd_lock.m` generates deterministic PRBS20 PAM4, runs the default S-parameter channel and CTLE, scales the settled waveform to `0.27 V`, converts it with the 7-bit TI ADC, and filters chronological ADC samples with the fixed six-tap CDR FFE. It then explicitly closes `mmpdFast -> cdr_voter -> cdr_loop -> cdr_pi` without changing `cdr_top.m`.

MATLAB R2025b batch execution and static analysis passed. The run used 64 UI/block, 80 blocks, all 128 integer initial phases, fixed FFE taps `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]`, and one frozen loop setting selected only from `-3/+3` sample starts:

- Maximum-power reference phase: 34 samples; selected 13-sample-smoothed negative-slope MMPD lock: 25.53125 samples.
- Fixed loop: `Kp=0.256`, `Ki=0.002`, polarity `+1`, group weights `[2,1,2,1]`.
- Continuous passing initial-offset interval: `[-3,+16]` samples, width 19 samples or 0.1484 UI.
- Pass limits: final-20-block absolute mean error at most 3 samples, span at most 8 samples, drift at most 0.25 sample/block, and valid-transition density at least 5%.
- Outputs: `results/AFE/channel_ctle_adc_ffe_mmpd_lock/ctle_eye.png`, `mmpd_convergence.png`, `mmpd_lock_range.png`, and `result.mat`.
- A post-FFE voltage-opening scan over all 128 phases selected phase 74. Its ordered centers are approximately `[-0.174857,-0.059284,+0.051317,+0.168335] V`, midpoint thresholds are `[-0.117070,-0.003983,+0.109826] V`, and the limiting adjacent-center spacing is `0.110601 V`. The common-bin, four-cluster histogram is `results/AFE/channel_ctle_adc_ffe_mmpd_lock/cdr_ffe_voltage_histogram.png`; the phase scan, centers, thresholds, and figure path are retained in `result.mat`.

### Fixed-dlev SS-MMPD phase loop + adaptive CDR-FFE SS-LMS

`validation/CDR/test_cdr_cdrffe/cdr_dlev_sslms.m` closes a dual-adaptive loop over the cached PRBS20 Channel+CTLE segment: the dlev decision levels are held fixed (low/inner=12, high/outer=36 code, threshold 24), the phase loop uses the uniform weight-1 SS-MMPD kernel, and the six-tap CDR FFE adapts with sign-sign LMS (`cdr_ffe_loop.updateSsLms`, main tap fixed) from a cold start `[0 0 1 0 0 0]`. The first `FfeTrainingBlocks=500` blocks are data-aided (TX golden from `tx_prbs20.mat`, aligned by `channelMainCursorUi=105`), then the loop switches to decision-directed blind convergence and the FFE step drops from 0.02 to 0.001.

MATLAB R2025b batch execution passed (no-argument default, 32 start phases `0:4:127`, `AnalysisNumUi=512512` ≈ 8000 blocks, ~90 s):

- All 32 start phases locked (`AllPhaseLock=1`) to common phase code 17 with **0-code spread**; each phase's steady-state phase-code std was within the 1.5-code tolerance. Blind (decision-directed) convergence begins at block 500 for every phase.
- The FFE SS-LMS coefficients converged consistently across phases: max adaptive-tap spread 0.00225 (< 0.01 tolerance). The free taps settled to the true decision-directed MMSE solution (mean pre1 ≈ −0.35, post1 ≈ +0.13), larger than the offline `0.05`-cursor design; SS-MMPD stayed locked throughout, confirming its S-curve does not depend on residual pre1/post1 ISI amplitude.
- Fixed dlev 12/36 matched the offline four-level cluster truth (inner ≈ 12.2, outer ≈ 36.7); the golden `{±3,±1}` map to `{±36,±12}` during training.
- `checkcode` reported only the pre-existing `numel(varargin)==1` style suggestion, matching the sibling scripts.
- Outputs: `cdr_phase_convergence.png`, `cdr_block_timing_error.png`, `cdr_locked_phase_vs_start_phase.png`, `ffe_coeff_convergence.png`, and `cdr_dlev_sslms_result.mat` under `validation/CDR/test_cdr_cdrffe/result/cdr_dlev_sslms/`.
- This validates deterministic all-start acquisition and joint phase/FFE convergence on a static zero-ppm fixture only; it does not measure BER, jitter tolerance, or noise/PVT robustness.

### MMPD-v1 complete CTLE cache and fixed-segment S-curve

- `test_channel_ctle_cosim.m` generated and verified `validation/AFE/test_mmpd_v1/result/channel_ctle_cosim/channel_ctle.mat` in MATLAB R2025b.
- The cache contains one complete `2^20-1`-bit PRBS20 period mapped to 524288 PAM4 symbols and exactly 67,108,864 finite `single` CTLE samples. The MAT container size is approximately 238.4 MiB.
- A separate 2048-symbol batch Channel+CTLE run matched the beginning of the streamed single-precision cache with maximum absolute error `1.19208e-7`.
- `mmpd_s_curve_own_data.m` passed all 128 phases using the same cached 16384-UI range `[512,16896)`; the result explicitly stores `AllPhasesUseSameSegment=true` and the shared sample bounds.
- Each phase processed 256 blocks of 64 UI through the existing 7-bit `ti_adc_top` with `[-4,+4] V` input limits and the optimized 10-tap `cdr_ffe`. Phase-19 output calibrated one fixed linear map from equalized codes to PAM4 amplitudes `[-3,-1,+1,+3]`.
- Constrained optimization selected CDR coefficients `[-0.0213482,0.0673217,-0.212667,1,0.241926,0.0715624,0.102744,0.0373395,0.0156593,0.0131292]`.
- The normalized quantized total unit-UI response over `[-3,+9] UI` was approximately `[-1.53e-6,-8.21e-6,0.1,1,0.1,-1.09e-4,-2.07e-4,-6.19e-4,-6.41e-4,-1.04e-3,-5.94e-3,-2.16e-3,-9.84e-4]`.
- The explicit `pre1/main/post1` checks passed at `0.1/1/0.1`; the remaining cursor RMS was `0.002069` and maximum magnitude was approximately `0.005938`.
- The offline detector now uses the unfiltered live classic equation `d[n-1]e[n]-d[n]e[n-1]`, with signed full-amplitude residuals rather than `cdr_pd.mmpdFast` binary-error decisions. Its nearest-zero integer phase is 116.
- Linear interpolation found six raw crossings near phases `22.71`, `56.73`, `65.53`, `85.23`, `106.37`, and `116.02`; this diagnostic therefore does not assert a unique stable lock point.
- The three-curve comparison is reordered onto a phase-19-centered `[-0.5,+0.5) UI` axis, with one-symbol fixed-decision alignment across the raw ADC phase wrap. The fixed-decision, unfiltered-live, and symmetric-transition-live center-region crossings are `+0.02562`, `+0.02897`, and `+0.02633 UI`, respectively. The symmetric filter retains only `-3<->+3` and `-1<->+1` transitions; its per-phase retained transition count ranges from 2724 through 3863.
- Backend outputs are `mmpd_s_curve.png`, `mmpd_reference_and_symmetric_s_curve.png`, `ctle_output_first_1024_ui_eye.png`, `cdr_ffe_output_unit_ui_response.png`, `cdr_ffe_output_histogram.png`, and `mmpd_s_curve_result.mat` under `validation/AFE/test_mmpd_v1/result/mmpd_s_curve_own_data`.
- The `mmpd_s_curve_own_data_0.05.m` comparison reused phase 19, the same cached UI range `[512,8704)`, and the same ADC/MMPD flow while changing only the constrained normalized CDR-FFE targets to `pre1=post1=0.05` with main one.
- MATLAB R2025b execution passed all 128 phases. The optimized coefficients are approximately `[-0.0463002,0.120119,-0.323510,1,0.211501,0.0631387,0.116410,0.0422674,0.0181705,0.0175457]`; the remaining normalized cursor RMS is `0.002959`, the maximum residual is `0.008366`, and the nearest-zero integer phase is 61.
- The comparison outputs are stored separately under `validation/AFE/test_mmpd_v1/result/mmpd_s_curve_own_data_0.05`.
