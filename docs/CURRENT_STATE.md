# Current State

Updated: 2026-08-20

## Current modeling scope

- Active implementation scope: `src/TX+Channel`, `src/AFE`, `src/ADC`, and `src/CDR`.
- `src/LinkSim` is historical reference material and is not the current modeling baseline.

## Implemented TX and channel capabilities

- Minimal complete-waveform TX and differential S-parameter channel model in `src/TX+Channel/tx_channel.m`.
- Already-mapped voltage symbols are expanded with ideal zero-order hold at 56 GBd and 128 samples/UI by default.
- The default `data/Channel/DPO_4in_Meg7_THRU.s4p` four-port channel uses explicit differential signaling, `[1 2 3 4]` port order, 50-ohm source/load terminations, and no additional termination capacitance.
- Channel output preserves row/column orientation and is directly accepted by the current CTLE `process` interface.

## Implemented AFE capabilities

- Minimal fixed one-zero, two-pole CTLE for complete oversampled waveforms.
- Default 56 GBd, 128-samples/UI configuration with 0 dB DC gain and 4.5 dB gain at Nyquist for 12 dB-channel MMPD debugging.
- Constructor input is samples/UI; waveform sample rate is derived internally from symbol rate and samples/UI.
- Direct continuous-time transfer-function implementation using Control System Toolbox `tf` and `lsim`, without CTLE adaptation, AGC/VGA, or plotting.

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

- Dedicated floating-point 1-UI CDR FFE with default six-tap, two-precursor configuration, fixed unit main tap, configurable tap layout, cross-block history, and fast block processing.
- Separate block LMS engine using data-decision error, block-length normalization, configurable adaptation mask, and next-block coefficient updates.
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
- `validation/AFE/test_channel_ctle_ti_adc_cdr_ffe_mmpd_lock.m` closes the generated Channel+CTLE waveform through the 7-bit TI ADC, the fixed six-tap CDR FFE, PAM4 MMPD, voter, loop filter, and PI, then scans all 128 integer initial phases with one frozen loop configuration.

## Not yet implemented or integrated

- Frequency acquisition/detector path.
- A reusable waveform-level top that integrates CDR FFE, slicers, and MMPD upstream of the current BBPD-oriented `cdr_top` interface.
- End-to-end CDR lock, BER, bathtub, jitter-transfer, and jitter-tolerance analysis.
- A single top-level configuration/runner for ADC plus CDR.

## Validation status

- Open-loop Channel+CTLE+TI-ADC+CDR-FFE pulse-response validation passes with a 7-bit `[-0.3,+0.3] V` ADC and automatically optimized fixed FFE taps. The output satisfies `pre1=post1=+0.1`; other fitted cursors have approximately `0.01971` RMS and `0.03813` maximum residual. The aligned cascade response and standalone FFE tap response are saved under `results/AFE/channel_ctle_ti_adc_cdr_ffe`.
- Closed-loop Channel+CTLE+TI-ADC+fixed-CDR-FFE MMPD validation passes with fixed taps `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]`. The frozen loop uses `Kp=0.256`, `Ki=0.002`, polarity `+1`, and has a continuous validated initial-phase interval of `[-3,+16]` samples around the selected MMPD lock, width 19 samples or 0.1484 UI. Results are saved under `results/AFE/channel_ctle_adc_ffe_mmpd_lock`.
- The same validation now scans the post-FFE four-level voltage separation over all 128 phases. The maximum minimum-adjacent-center spacing is `0.110601 V` at phase 74; the colored voltage histogram and midpoint thresholds are saved as `cdr_ffe_voltage_histogram.png` in the same result directory.
- AFE TX-FFE+Channel+CTLE co-simulation uses a 2048-symbol tuning preview, discards 512 UI, and uses 1024 UI for phase diagnostics. Its offline six-tap TX FFE is `[0.0214425,-0.144777,0.671335,-0.0844467,0.0698928,-0.00810601]` for offsets `[-2,-1,0,+1,+2,+3] UI`, with unit L1 norm and positive main. The optimized one-UI symbol-pulse cursors over `[-3,+6] UI` are `[0.009566,-0.002478,0.000473,1,-0.000254,0.001385,0.000376,0.012037,0.018716,-0.008559]`. The best label-conditioned eye phase is 118/128 with separation 10.3661; the maximum-power phase is 20/128 with separation 1.6543. Plots and the opt-in float32 final-output MAT cache are under `results/AFE/channel_ctle_cosim`.
- AFE channel validation plots the differential `Sdd21` of `DPO_4in_Meg7_THRU.s4p` and a 2-UI channel-output eye using PRBS20 PAM4 at 56 GBd and 128 samples/UI. The 28 GHz Nyquist point is marked with a measured differential insertion loss of approximately 14.09 dB; both plots are saved under `results/AFE`.
- AFE CTLE frequency-response validation confirms 0 dB DC gain and 4.5 dB gain at the 28 GHz Nyquist frequency for 56 GBd and 128 samples/UI; the diagnostic plot is saved under `results/AFE`.
- TX+Channel automated regression passed 5/5 checks covering defaults, zero-order hold, row/column behavior, finite channel output and time base, CTLE connection, and invalid input/configuration rejection.
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
- The MMPD-v1 validation is split at the CTLE output. `test_channel_ctle_cosim.m` runs one complete PRBS20 period with TX FFE preserved under `if false` and stores 524288 PAM4 symbols plus 67,108,864 `single` CTLE samples in `channel_ctle.mat`. `mmpd_s_curve_own_data.m` loads a single fixed 16384-UI segment `[512,16896)` and reuses that exact segment for all 128 ADC phases before CDR FFE processing.
- The cached-data S-curve uses the classic Mueller-Muller equation with full PAM4 decision amplitudes and signed residual amplitudes. MATLAB R2025b execution passed with a 7-bit `[-4,+4] V` ADC and phase-19 CDR-FFE design reference. The phase-19-centered comparison now overlays fixed-decision reference, unfiltered live, and symmetric-transition live curves over 16384 UI per phase. Their center-region negative-slope crossings are respectively `+0.02562`, `+0.02897`, and `+0.02633 UI`. The first 1024 cached CTLE UI are also plotted as an eye diagram.
- The `mmpd_s_curve_own_data_0.05.m` comparison passed in MATLAB R2025b with the same phase-19 design point and fixed 8192-UI segment. Its constrained total response achieved `pre1/main/post1=0.05/1/0.05`; the remaining cursor RMS is approximately `0.002959`, the maximum residual is approximately `0.008366`, and outputs are isolated under `validation/AFE/test_mmpd_v1/result/mmpd_s_curve_own_data_0.05`.

## Known issues and technical debt

- Generated files remain inside `src/ADC/**/result` and `src/CDR/result`.
- `src/ADC/ADC_sample_CTEL_output` contains study scripts, large waveform inputs, documentation, and generated results rather than only reusable source.
- Alternative SAR implementations overlap: `SAR_ADC_core`, `SAR_ADC_core_complex`, `SAR_ADC_channel`, `sar_adc_ref`, and the TI ADC-local SAR core.
- Some Chinese comments are corrupted by inconsistent text encoding.
- Model configuration is distributed across constructors and validation scripts rather than centralized.
- Existing validations are mostly behavioral/visual and do not define enough numerical acceptance tolerances.
- The dedicated upstream CDR FFE is integrated only in an AFE validation script; it is not yet exposed through a reusable waveform-level top or the existing `cdr_top` API.

## Current blockers

- The fixed-FFE ADC/CDR loop is validated deterministically, but correlation-quality timing recovery remains blocked on adaptive FFE integration and jitter/noise/corner validation.
- Canonical SAR behavior and boundary conventions must be selected before consolidating duplicate models.
- Required correlation targets and accuracy tolerances are not yet defined.

## Recommended next steps

1. Declare `src/ADC/TI_ADC` as the working TI ADC implementation and document how the other SAR variants will be used as references or retired.
2. Add automated regression tests for SAR boundaries, saturation, fast/debug equivalence, TI lane ordering, and clock indices.
3. Add automated BBPD and PI wrap/nonideality tests under `tests/CDR`.
4. Extend the validated ideal TI-ADC/CDR loop with controlled ADC skew, jitter, and mismatch corners.
5. Move remaining waveform studies, input data, and generated artifacts out of `src`.
