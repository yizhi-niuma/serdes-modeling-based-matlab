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

The current validation script passed 7/7 checks:

- Alexander truth table.
- Polarity inversion.
- Threshold behavior.
- Output/state snapshot.
- Matrix input.
- Invalid-input rejection.
- Waveform decision sequence.

### CDR: phase interpolator

- Code wrapping across multiple UI.
- Wrapped and accumulated phase/index behavior.
- UI-slip tracking.
- Default nonideal phase-table visualization.

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
- No CDR loop filter or closed-loop acquisition/tracking test.
- No jitter transfer, jitter tolerance, bathtub, or BER validation.
- No correlation against circuit simulation or measured ADC/CDR data.

## Recommended automated regression set

1. SAR codes at rails, midscale, every selected code boundary, and saturation points.
2. Debug/fast and scalar/vector equivalence under deterministic ideal conditions.
3. Seeded nonideal repeatability.
4. TI ADC lane order and block rotation.
5. Clock indices for ideal, common skew, per-phase skew, and seeded jitter.
6. `ti_adc_top` input-margin and out-of-range behavior.
7. Complete BBPD truth table, threshold equality, polarity, and array-shape behavior.
8. PI positive/negative wrap, multiple-UI slip, ideal LUT linearity, custom LUT, and `updateFast` contract.
9. Minimal closed-loop PD/PI/TI-ADC smoke test after a loop filter is implemented.

Every regression should state the input, expected result, tolerance, random seed, and physical rationale.
