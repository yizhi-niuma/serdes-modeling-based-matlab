# Model Assumptions

This document is derived only from `src/ADC` and `src/CDR`. It records current code behavior, not verified silicon accuracy.

## Common numerical conventions

- UI is the timing unit used by the TI ADC clock and PI models.
- `SamplesPerSymbol`/oversampling converts phase in UI to waveform sample index.
- Timing impairments are ultimately applied as integer sample-index changes in the TI ADC clock path; arbitrary sub-sample interpolation is not modeled there.
- Fixed random seeds are used by validation scripts where repeatability is required.

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

## TI ADC clock assumptions

- Fixed skew and random jitter are expressed in UI.
- Random rising-edge and TAH jitter are Gaussian.
- UI offsets are multiplied by samples/UI and rounded to sample indices.
- The clock can operate with common or per-rising-edge-phase skew.
- Data and edge indices are generated as discrete waveform indices; interpolation is left to a future sampler if needed.

## Offline waveform-study assumptions

- The CTLE waveform studies assume 112 Gb/s PAM4, hence 56 GBd and 128 samples/UI.
- Eye diagrams span two UI.
- Leading delay is estimated either from an amplitude threshold or normalized TX-to-CTLE cross-correlation.
- The threshold method uses 3% of global peak amplitude and requires a run of valid samples.
- Sampling phase may be selected using maximum sampled power or variance. This is an offline eye-center heuristic, not a closed-loop CDR result.
- The CTLE-to-ADC study commonly uses a 7-bit `[-0.3, 0.3] V` SAR range.

## CDR phase-detector assumptions

- `cdr_pd` implements an Alexander bang-bang detector.
- Samples are sliced using `sample > Threshold`; equality produces decision zero.
- A PD decision is valid only when consecutive data decisions differ.
- With default polarity, an edge decision equal to the previous data decision produces `+1`; the opposite transition case produces `-1`.
- Invalid/non-transition decisions are forced to zero.

## Phase-interpolator assumptions

- The default PI is 8-bit, giving 256 codes per UI.
- Default sampling resolution is 128 samples/UI.
- PI code is integer-valued and wraps into `[0, NumCode-1]`.
- Full-UI crossings accumulate in `UiSlip` rather than being discarded.
- The default nonideal model uses `a+b=constant` vector interpolation and an `atan2` phase mapping.
- Custom INL and custom phase tables are accepted in UI.
- PI output sample index is floating point. The downstream sampler must decide whether to round, floor, or interpolate.
- `updateFast` updates wrapped code and UI slip but intentionally leaves some debug-derived state stale until a full update/state refresh.

## Current validity limits

- No closed-loop CDR model has yet validated acquisition, tracking bandwidth, jitter transfer, jitter tolerance, or BER.
- No sub-sample interpolation is implemented in the TI ADC sampling path.
- No correlation target against transistor simulation, measurement, or a product specification is documented.
- Multiple SAR implementations coexist and may use different state and boundary conventions.
- Offline CTLE phase selection must not be treated as proof of CDR lock.
