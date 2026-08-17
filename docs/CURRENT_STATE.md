# Current State

Updated: 2026-08-16

## Current modeling scope

- Active implementation scope: `src/ADC` and `src/CDR`.
- `src/LinkSim` is historical reference material and is not the current modeling baseline.

## Implemented ADC capabilities

- Single-ended SAR ADC conversion with scalar/vector and debug/fast interfaces.
- Differential clock-driven TAH + SAR channel conversion.
- Configurable capacitor mismatch, gain/offset, comparator noise/offset, and per-bit offsets across the applicable ADC variants.
- ADC trace capture and dynamic/static metric utilities.
- M-lane TI ADC block conversion.
- TI ADC sampling-clock generation with common/per-phase skew and Gaussian jitter.
- Integrated `ti_adc_top` combining waveform indexing, clock impairment, TAH grouping, and TI ADC conversion.
- Offline CTLE waveform delay, eye-diagram, sampling-phase, ADC-code, and voltage-distribution studies.

## Implemented CDR capabilities

- Pure digital NRZ/PAM4 bang-bang phase detector with polarity, transition qualification, compact input/result debug state, and array input.
- PAM4 BBPD transition selection aligned to the reference RTL's symmetric `00<->11` and `01<->10` edges.
- Vectorized `int8` BBPD decision kernel with numeric mode selection; the validated path reuses the same kernel and adds only input validation plus debug-state updates, with strict value/type equivalence covered by tests.
- Explicit top-level block-overlap convention validated for preserving transitions between consecutive ADC/CDR blocks; the PD itself remains stateless.
- Experimental PAM4 MMPD validated/fast paths using every non-static transition, weight 2 for symmetric pairs and weight 1 for asymmetric pairs, without RTL odd/even filtering.
- Stateless configurable block voter with linear/constant modes, default 64-decision blocks, default constant magnitude 8, `int16` output, and a validated interface that reuses the single-block fast calculation path.
- Mode-independent proportional-integral loop filter with floating internal state, fractional code residue, explicit pending integer-code backlog, configurable integral limits, saturation recovery, default one-code output slew limiting, and scalar fast update.
- Phase interpolator with ideal/default-nonideal/custom phase tables, wrapped code, accumulated UI slip, floating sample-index output, and fast update path.
- Block-rate `cdr_top` integration of PD, voter, loop filter, and PI with explicit cross-block symbol history, next-block PI timing, coordinated reset, and validated/fast paths.
- `cdr_top` source documentation now explains its block scheduling, state ownership, update-before/after phase semantics, validated/fast contracts, reset behavior, units, and row/column block handling in detailed UTF-8 Chinese comments.
- `cdr_top` executable statements no longer use MATLAB ellipsis continuation; complex validation expressions are split into named boolean checks while preserving the original interfaces and behavior.
- `test_cdr_top_ctle_waveform.m` now contains detailed UTF-8 Chinese comments covering the validation boundary, offline phase/threshold calibration, BBPD statistical lock reference, constant-voter and PI-loop configuration, current/next-block timing, error-signal units, acceptance checks, and helper-function behavior; executable behavior is unchanged.
- `validation/CDR/test_ti_adc_cdr_joint_ctle.m` now closes the CTLE waveform through the 64-lane 7-bit TI ADC, code-domain PAM4 data/error decisions, MMPD, voter, loop filter, and PI. The script explicitly reorders physical TI lanes into time order before the DSP.

## Not yet implemented or integrated

- Frequency acquisition/detector path.
- Dedicated CDR-path FFE and the data/edge slicers upstream of the digital PD.
- End-to-end CDR lock, BER, bathtub, jitter-transfer, and jitter-tolerance analysis.
- A single top-level configuration/runner for ADC plus CDR.

## Validation status

- All 13 scripts under `validation/` ran successfully after the directory reorganization.
- ADC coverage includes SAR core, capacitor mismatch, differential clock-driven single/quad channel, TI ADC sine input, CTLE waveform conversion, and clock-skew/jitter histograms.
- CDR PD validation passed 10/10 internal checks covering NRZ/PAM4 BBPD behavior, polarity, mode/state, matrix input, fast-path equivalence/state isolation, cross-block transition preservation, invalid input, PAM4 inner/outer MMPD behavior, and external-slicer waveform behavior.
- CDR voter automated regression passed 7/7 checks covering defaults, linear/constant decisions, ties, row/column input, single-block fast-path equivalence, mode updates, invalid input, and invalid configuration.
- CDR loop-filter automated regression passed 10/10 checks covering PI update order, positive/negative residual quantization, integral saturation and recovery, voter-mode-independent numeric input, scalar fast-path equivalence, PI interface compatibility, default/configurable delta-code limiting, runtime configuration/reset, and invalid inputs.
- CDR top-level automated regression passed 6/6 checks covering component scheduling, next-block PI update timing, cross-block symbol overlap, row/column handling, coordinated reset, fast-path equivalence, and invalid inputs/configuration.
- Seeded-free deterministic ideal-edge validation demonstrated `cdr_top` phase search on a 128-samples/UI NRZ waveform, converging from 0 to a true edge at sample 24 and remaining in a 23/24-sample limit cycle.
- Independent 128-samples/UI PAM4 convergence cases validated both supported symmetric transition families, outer `0<->3` and inner `1<->2`; both converged to the same 23/24-sample limit cycle around the edge at sample 24.
- CTLE-waveform PAM4 validation now reads the 5000-UI fixture from `data/ADC/TI_ADC/ctle_out.csv`, calibrates slicer thresholds, measures the BBPD S-curve, and closes `cdr_top` over 4096 UI. With `Kp=0.0625` and `Ki=0.0005`, the PI converged from sample 0 to a 14-15 sample steady-state range around the measured BBPD lock phase at sample 15.
- CTLE-waveform weighted PAM4 MMPD tracking validation measures a lock phase of 82 samples and converges from sample 74 over 4096 UI with constant voter and `MaxDeltaCode=1`. The selected `Kp=0.5`, `Ki=0.005` settings produce a -0.25-sample final-window mean error and 0.5-sample span.
- Weighted all-transition v1 now uses the architecture-consistent 64-UI linear voter, 50 updates over the same 3200 unique fixture UI, and unlimited delta code.
- The joint TI-ADC/CDR CTLE regression uses 64 blocks of 64 UI, 128 samples/UI, a 7-bit `[-0.3,+0.3] V` ADC, and code-domain MMPD decisions. It converged from phase 74 to the ADC-quantized statistical lock at phase 82, with a final-16-block mean error of -0.656 sample, 2.5-sample span, 0.133 sample/block drift, and 1662 valid MMPD events.
- Weighted all-transition v1 now decomposes the aggregate MMPD characteristic into all 12 directed non-static PAM4 transition classes. It reports each class's conditional S-curve and valid density, retains the weighted unconditional contribution in the returned result, and asserts that the 12 contributions exactly reconstruct the aggregate loop S-curve.
- The 12 directed MMPD classes are additionally combined into four polarity-preserving PAM4-symmetric groups: adjacent outer (`0<->1`, `2<->3`), skip-one (`0<->2`, `1<->3`), outer symmetric (`0<->3`), and inner symmetric (`1<->2`). Their summed unconditional contributions are asserted to reconstruct the aggregate S-curve.
- A validation-only integer search over the four symmetric group weights selected `[G1 G2 G3 G4]=[2 1 2 1]`, compared with the previous `[1 1 2 2]`. After 9-sample circular smoothing, the selected characteristic has one stable crossing at phase 83.87, 0.13 sample from the maximum-power phase 84. With 64 UI/block and exhaustive 1-sample initial-phase steps, the continuous validated acquisition interval is phase 69.87 through 101.87 (`-14` to `+18` samples around lock, width 0.25 UI). Phase 104.87 (`+21`) is an isolated passing point and is not counted as part of the continuous range.
- CDR PI code/phase/index/wrap behavior has been exercised visually.
- `tests/CDR` now contains the first automated CDR component regression; broader ADC/CDR regression coverage is still incomplete.

## Known issues and technical debt

- Generated files remain inside `src/ADC/**/result` and `src/CDR/result`.
- `src/ADC/ADC_sample_CTEL_output` contains study scripts, large waveform inputs, documentation, and generated results rather than only reusable source.
- Alternative SAR implementations overlap: `SAR_ADC_core`, `SAR_ADC_core_complex`, `SAR_ADC_channel`, `sar_adc_ref`, and the TI ADC-local SAR core.
- Some Chinese comments are corrupted by inconsistent text encoding.
- Model configuration is distributed across constructors and validation scripts rather than centralized.
- Existing validations are mostly behavioral/visual and do not define enough numerical acceptance tolerances.
- The dedicated upstream CDR FFE and NRZ/PAM4 data/edge slicers are not yet implemented or integrated with the digital PD.

## Current blockers

- The minimal ADC/CDR loop is validated without a dedicated CDR FFE; correlation-quality timing recovery remains blocked on defining and integrating that FFE and its adaptation requirements.
- Canonical SAR behavior and boundary conventions must be selected before consolidating duplicate models.
- Required correlation targets and accuracy tolerances are not yet defined.

## Recommended next steps

1. Declare `src/ADC/TI_ADC` as the working TI ADC implementation and document how the other SAR variants will be used as references or retired.
2. Add automated regression tests for SAR boundaries, saturation, fast/debug equivalence, TI lane ordering, and clock indices.
3. Add automated BBPD and PI wrap/nonideality tests under `tests/CDR`.
4. Extend the validated ideal TI-ADC/CDR loop with controlled ADC skew, jitter, and mismatch corners.
5. Move remaining waveform studies, input data, and generated artifacts out of `src`.
