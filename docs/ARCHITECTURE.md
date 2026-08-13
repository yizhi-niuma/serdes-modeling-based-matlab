# Architecture

## Scope

The current modeling scope documented here is limited to:

- `src/ADC`
- `src/CDR`

`src/LinkSim` is historical reference material. It is not the current model architecture and must not be used to infer current implementation status or requirements.

## Current subsystem flow

```text
Oversampled RX waveform
  -> sampling-phase/index generation (TI ADC clock and future CDR loop)
  -> TAH / TI ADC sampling
  -> SAR ADC conversion
  -> ADC code and reconstructed voltage

CDR data sample + edge sample
  -> Alexander bang-bang phase detector
  -> future loop filter (not implemented)
  -> phase-interpolator code update
  -> local sample-index offset
  -> TI ADC clock/sampler
```

The ADC and CDR components exist, but a closed-loop CDR-to-ADC top-level model has not yet been assembled in the current source.

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

### `cdr_pd.m`

Alexander bang-bang phase detector with:

- Previous data, current edge, and current data sample inputs.
- Configurable slicer threshold and output polarity.
- Transition-qualified `+1/-1` phase-error decisions.
- Zero output when no data transition is present.
- Debug state snapshots and array-input support.

### `cdr_pi.m`

Phase-interpolator behavioral model with:

- Configurable PI resolution and samples/UI.
- Wrapped PI code and accumulated full-UI slip.
- Ideal phase table.
- Default `a+b=constant` nonideal phase table.
- User-supplied INL or complete phase tables.
- Phase-to-floating-sample-index lookup.
- Full debug update and reduced-overhead `updateFast` paths.

## Missing top-level CDR blocks

The current `src/CDR` directory does not yet contain:

- Loop filter.
- Frequency detector or acquisition aid.
- CDR controller/top-level state machine.
- Direct closed-loop connection between `cdr_pd`, `cdr_pi`, and `ti_adc_top`.
- BER/jitter-tolerance top-level simulation.

## Repository organization debt within the current scope

- Generated result files remain under `src/ADC/**/result` and `src/CDR/result`.
- CTLE waveform studies and large CSV files remain under `src/ADC/ADC_sample_CTEL_output`.
- Several SAR ADC implementations overlap in responsibility.
- Some Chinese comments have encoding corruption and should be normalized separately.
