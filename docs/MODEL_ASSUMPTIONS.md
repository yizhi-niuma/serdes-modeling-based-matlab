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
- MMPD has an explicit software interface but no implemented behavior.

## CDR top-level assumptions

- `cdr_top` accepts hard digital data-symbol and edge-bit decisions; equalization, sampling, and slicing remain upstream.
- The future timing-recovery front end uses a dedicated CDR FFE and does not reuse the data-recovery FFE/DFE path.
- No DFE is included in the CDR timing path.
- A stateless slicer is currently treated as a threshold comparison rather than a stateful class. PAM4 data decisions require three thresholds, while the BBPD edge decision uses the center threshold only.
- The previous symbol supplied at construction or reset is explicit initial history for the first block; no hidden default symbol is assumed.
- One top-level call processes exactly one voter block. The phase entering that block is the sampling phase for that block.
- The block's voter and loop-filter result updates the PI after the decisions are processed, so the updated local PI index applies to the following block.
- `processBlockFast` assumes caller-validated digital vectors and intentionally does not update the top-level debug snapshot.

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

## Current validity limits

- The digital CDR component chain is integrated at block rate, but no waveform/ADC closed loop has yet validated acquisition, tracking bandwidth, jitter transfer, jitter tolerance, or BER.
- No sub-sample interpolation is implemented in the TI ADC sampling path.
- No correlation target against transistor simulation, measurement, or a product specification is documented.
- Multiple SAR implementations coexist and may use different state and boundary conventions.
- Offline CTLE phase selection must not be treated as proof of CDR lock.
