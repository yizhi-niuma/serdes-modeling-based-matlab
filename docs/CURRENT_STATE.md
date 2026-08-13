# Current State

Updated: 2026-08-13

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

- Alexander bang-bang phase detector with threshold, polarity, transition qualification, debug state, and array input.
- Phase interpolator with ideal/default-nonideal/custom phase tables, wrapped code, accumulated UI slip, floating sample-index output, and fast update path.

## Not yet implemented or integrated

- CDR loop filter.
- Frequency acquisition/detector path.
- Closed-loop PD -> loop filter -> PI -> TI ADC sampling simulation.
- End-to-end CDR lock, BER, bathtub, jitter-transfer, and jitter-tolerance analysis.
- A single top-level configuration/runner for ADC plus CDR.

## Validation status

- All 13 scripts under `validation/` ran successfully after the directory reorganization.
- ADC coverage includes SAR core, capacitor mismatch, differential clock-driven single/quad channel, TI ADC sine input, CTLE waveform conversion, and clock-skew/jitter histograms.
- CDR PD validation passed 7/7 internal checks covering truth table, polarity, threshold, output/state, matrix input, invalid input, and waveform behavior.
- CDR PI code/phase/index/wrap behavior has been exercised visually.
- No general automated regression suite currently exists under `tests/`.

## Known issues and technical debt

- Generated files remain inside `src/ADC/**/result` and `src/CDR/result`.
- `src/ADC/ADC_sample_CTEL_output` contains study scripts, large waveform inputs, documentation, and generated results rather than only reusable source.
- Alternative SAR implementations overlap: `SAR_ADC_core`, `SAR_ADC_core_complex`, `SAR_ADC_channel`, `sar_adc_ref`, and the TI ADC-local SAR core.
- Some Chinese comments are corrupted by inconsistent text encoding.
- Model configuration is distributed across constructors and validation scripts rather than centralized.
- Existing validations are mostly behavioral/visual and do not define enough numerical acceptance tolerances.

## Current blockers

- A closed-loop ADC/CDR simulation cannot be completed until the loop filter and top-level scheduling/data-flow logic are defined.
- Canonical SAR behavior and boundary conventions must be selected before consolidating duplicate models.
- Required correlation targets and accuracy tolerances are not yet defined.

## Recommended next steps

1. Declare `src/ADC/TI_ADC` as the working TI ADC implementation and document how the other SAR variants will be used as references or retired.
2. Add automated regression tests for SAR boundaries, saturation, fast/debug equivalence, TI lane ordering, and clock indices.
3. Add automated BBPD and PI wrap/nonideality tests under `tests/CDR`.
4. Define and implement the CDR loop-filter interface.
5. Build a minimal seeded closed-loop CDR + `ti_adc_top` simulation before adding further nonidealities.
6. Move remaining waveform studies, input data, and generated artifacts out of `src`.
