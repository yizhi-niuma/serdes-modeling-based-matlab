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

### CDR FFE implementation smoke check

- MATLAB R2025b loaded `cdr_ffe` and `cdr_ffe_lms`, processed one 64-sample row block, produced a `64-by-6` regressor, and reported 62 valid outputs for the default two-precursor startup latency.
- A zero-error LMS update preserved the fixed unit main tap.
- Existing CDR regressions remained unchanged and passed: voter 7/7, loop filter 10/10, digital top level 6/6, and PD including MMPD 10/10.
- No dedicated CDR FFE test or validation function was added in this minimal implementation.

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
