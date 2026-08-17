# Validation

## Scope

This validation record covers current ADC and CDR components only. `LinkSim` results are not used as evidence for the current model.

## Evidence levels

1. **Execution check**: script completes without MATLAB error.
2. **Behavioral/visual validation**: plots and statistics are reviewed.
3. **Automated regression**: assertions enforce expected values and tolerances.

Most ADC validation is currently level 1-2. The CDR PD validation contains explicit checks, while the PI validation is primarily visual/behavioral.

## Executed validation

All 13 scripts under `validation/` completed with exit code 0 in independent MATLAB batch sessions during the repository reorganization. The run record is `results/validation_summary.csv`.

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
