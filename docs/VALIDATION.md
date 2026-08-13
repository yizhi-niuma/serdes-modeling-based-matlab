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
- Mode selection and output/state snapshot.
- Matrix input.
- `bbpdFast` equivalence to `bbpd` for seeded NRZ/PAM4 row, column, and matrix blocks with both polarities, including `int8` output and verification that the stateless fast path does not modify object state.
- Cross-block equivalence for five consecutive 64-symbol blocks using explicit previous-symbol overlap in the caller/top-level.
- Invalid digital mode/symbol/edge/shape rejection.
- Explicit MMPD-not-implemented behavior.
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

The automated regression under `tests/CDR` passed 9/9 checks:

- Current-error proportional/integral update order.
- Positive and negative fractional-code residue accumulation.
- Configurable integral saturation and reverse-error recovery.
- Numeric inputs representing either voter mode without a mode-dependent interface.
- Validated and scalar fast update-path equivalence.
- Integer `deltaCode` compatibility with `cdr_pi`.
- Runtime gain/limit configuration and dynamic-state reset.
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
- No waveform/ADC closed-loop acquisition/tracking test integrating the digital CDR chain and sampler.
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
