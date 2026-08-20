# Decisions

## 2026-08-12: Repository organization

- Reusable models belong in `src/`.
- Behavioral and visual studies belong in `validation/`.
- Automated regression tests belong in `tests/`.
- Fixed input/reference data belongs in `data/`.
- Generated output belongs in `results/`.
- Project paths must resolve from `D:\Work\serdes_modeling`, not a former absolute location.

## 2026-08-13: Current documentation scope

- The current modeling baseline is derived only from `src/ADC` and `src/CDR`.
- `src/LinkSim` is retained as historical reference and must not be presented as the current architecture, current end-to-end implementation, or validated capability.
- Documentation claims must distinguish implemented component behavior from future closed-loop integration.

## 2026-08-13: Current ADC integration path

- `src/ADC/TI_ADC/sar_adc_core.m`, `ti_adc_core.m`, `ti_adc_clock.m`, and `ti_adc_top.m` form the current integrated TI ADC stack.
- Other SAR implementations remain comparison/reference models until an explicit consolidation decision is made.

## 2026-08-13: Digital CDR phase-detector boundary

- Equalization and slicing are outside `cdr_pd`; the PD accepts hard digital data-symbol and edge-bit decisions.
- The PD supports NRZ and PAM4 through the `bbpd` method, with PAM4 as the default mode.
- PAM4 uses `00=-3`, `01=-1`, `10=+1`, and `11=+3`, and only the symmetric `00<->11` and `01<->10` transitions contribute phase decisions.
- The public PAM4 MMPD methods are `mmpd` and `mmpdFast`; they use the reference RTL's binary error-bit decision concept rather than a continuous-amplitude Mueller-Muller equation.
- On branch `codex/mmpd-weighted-transitions-v1`, the behavioral MMPD intentionally does not reproduce the RTL odd/even split and accepts all non-static transitions. Symmetric `0<->3` and `1<->2` transitions use weight 2; asymmetric transitions use weight 1.
- The v1 experiment uses a 64-UI linear voter so that one CDR update matches the 64-lane ADC block cadence. It uses 50 updates over 3200 unique fixture UI and retains unlimited delta code as an isolated experimental choice; unlimited slew does not replace the default one-code slew architecture.
- Initial CTLE MMPD validation treats MMPD as a limited-range tracking detector and, with one-code slew limiting, initializes it 8 samples from its measured statistical lock phase; wide-range acquisition remains the BBPD/FLL responsibility.
- The BBPD/MMPD output is named `phaseDecision` to distinguish the discrete early/late direction from a quantitative phase-error estimate.
- `bbpdFast` is the single stateless block-vectorized BBPD decision kernel. Both public paths return `int8`; `bbpd` delegates to it and adds validation/debug capture, while direct fast-path callers own input validity and block overlap.
- The validated BBPD snapshot stores configuration, digital inputs, `Valid`, and `PhaseDecision`; derived aliases such as early/late/raw/transition/data-side are omitted because they duplicate the decision kernel outputs or can be reconstructed by a debugger.
- Cross-block previous-symbol state belongs to the future CDR top-level, not `cdr_pd`; the top-level must explicitly construct each block's `dataPrev` input using the preceding block's final symbol.

## 2026-08-13: CDR voter boundary

- The initial behavioral CDR uses classic 2x BBPD sampling, with one edge decision per data decision; the 1.25x sparse-edge RTL architecture is deferred.
- One voter call aggregates exactly one parallel block and produces one CDR phase-error update; it does not accumulate across blocks.
- The voter supports `linear` and `constant` modes, with `linear` as the default.
- Linear mode returns the signed phase-decision count. Constant mode returns the sign of that count scaled by configurable `ConstantMagnitude`, which defaults to 8.
- The default block size is 64 and is configurable at construction.
- The voter output uses `int16`. Voter pipeline latency is owned by the future CDR top-level rather than the voter class.
- `voteFast` is the single-block hot path and is called once per 64 UI with the default configuration; cross-block voter aggregation is deferred.

## 2026-08-13: CDR loop-filter boundary

- The behavioral loop filter outputs an integer PI code increment; `cdr_pi` remains responsible for phase accumulation, code wrap, and UI-slip tracking.
- One loop-filter update occurs per 64-UI voter block, and its result affects the following block without additional RTL pipeline delay.
- The loop filter is independent of voter mode and consumes only the numeric `phaseError`; the top level owns voter-mode and gain pairing.
- The current error updates the integral state before the proportional and integral terms form the current output.
- Internal gain, integral, and residual calculations use floating point. Fractional output code is accumulated and only complete integer code is emitted.
- Integral state limits are configurable and default to unbounded. Finite limits saturate and permit recovery under reverse error.
- PI increment limiting belongs to `cdr_loop` because it constrains the loop-filter output delivered to the PI. `MaxDeltaCode` defaults to one code per block; callers may explicitly select `Inf` for an unlimited behavioral study.
- The limiter preserves clipped complete-code demand in an explicit integer `PendingCode` state while `CodeResidue` remains fractional-only. Opposite-direction requests cancel pending code before adding backlog in the reverse direction.
- `PendingCode` is exposed rather than hidden in `CodeResidue`; an independent pending-code bound or anti-windup policy remains deferred until the corresponding RTL behavior is defined.
- RTL fixed-point widths, shift-encoded gains, Gray-code generation, permanent overflow freeze, and a separate FLL are outside the initial behavioral loop-filter scope.

## 2026-08-13: Digital CDR top-level boundary

- `cdr_top` composes configured PD, voter, loop-filter, and PI objects rather than duplicating their configuration.
- The top level owns the previous-symbol state needed to preserve PD transitions across block boundaries.
- The PI phase entering a block is used for that block; its phase-error result updates the PI for the following block.
- The initial previous symbol is supplied explicitly at construction and whenever the top level is reset.
- The validated path exposes a debug snapshot; the fast path omits validation and does not update that snapshot.
- The initial top-level boundary accepts already-sliced digital decisions and does not yet connect to the TI ADC or analog waveform.

## 2026-08-13: CDR equalization and slicing boundary

- The timing-recovery path will use a dedicated CDR FFE rather than sharing the data-recovery FFE/DFE path.
- The CDR timing path does not include the data-path DFE.
- The dedicated CDR FFE and slicers are upstream of the current digital `cdr_top` and are deferred to the waveform-integration stage.
- A fixed-threshold slicer does not require a stateful class. PAM4 symbol slicing uses three thresholds, while the BBPD edge-bit slicing uses only the center threshold.

## Observed model choices pending confirmation

The following values appear in current ADC waveform studies but are not yet permanent project-wide requirements:

- 112 Gb/s PAM4 and 56 GBd.
- 128 samples/UI.
- 64 TI ADC lanes and 8 SAR lanes per TAH group.
- 7-bit conversion.
- Maximum-power/variance phase selection for offline waveform sampling.
- Integer sample-index timing displacement.

## Pending decisions

- Canonical SAR code-boundary and reconstructed-voltage convention.
- Whether PI floating indices will be rounded or used with interpolation.
- Required jitter model composition and units at each block boundary.
- Accuracy/correlation target and numerical regression tolerances.
- Whether large waveform fixtures and generated results should remain version-controlled.

## 2026-08-16: Minimal TI ADC and CDR joint-validation boundary

- The first joint waveform validation uses the existing PAM4 MMPD `data + error-bit` path because it locks a baud-rate ADC sample to the data-eye center.
- DSP decisions consume only 7-bit ADC codes. Four code centers are calibrated before loop startup; three midpoint thresholds produce PAM4 data, and the decided-level center produces the binary MMPD error bit.
- `ti_adc_clock` and `ti_adc_top` expose samples in physical-lane order. The joint DSP explicitly applies the inverse physical-lane-to-time-order mapping before forming adjacent-symbol MMPD inputs.
- The validation retains the existing 64-lane, 8-SAR-per-TAH, 128-samples/UI, 7-bit, `[-0.3,+0.3] V`, integer-index configuration and does not introduce a dedicated CDR FFE.

## 2026-08-17: Minimal fixed CTLE for MMPD debugging

- The active source gains a small `src/AFE` boundary; historical `src/LinkSim` CTLE code is not reused.
- The CTLE directly implements `H(s)=k1*(s+wz)/((s+wp1)*(s+wp2))` with fixed zero/pole frequencies and uses `lsim` for batch waveform processing.
- The constructor accepts samples/UI rather than sample rate; sample rate is derived from the fixed symbol rate.
- The default 4.5 dB Nyquist peaking is a manual debug setting for the 12 dB channel, not an optimized product requirement.
- Adaptation, AGC/VGA, and plotting are outside this implementation.

## 2026-08-19: Maximum-power CTLE fixture and full-period export

- The Channel+CTLE validation overrides, but does not change, the `ctle` class defaults. Its current user-tuned debug configuration is `fz=6 GHz`, `fp1=28 GHz`, `fp2=50 GHz`, and `0 dB` DC gain, corresponding to approximately `9.38 dB` Nyquist peaking.
- A six-tap, two-precursor/three-postcursor TX FFE is implemented only in the validation script. It is optimized offline against the current Channel+CTLE symbol-pulse response, constrained to unit L1 norm and a positive main tap, and is applied consistently to preview and streamed cache generation.
- Symbol-spaced ISI for this validation is reported from the complete one-UI symbol-pulse response because the TX uses a one-UI zero-order hold. The Dirac unit impulse response remains available for analog-kernel inspection but is not used as the TX FFE cursor acceptance metric.
- One PRBS20 bit period is exported. The first bit is appended to the odd-length period solely to complete the final natural-mapped PAM4 pair.
- Full-period output is streamed in causal blocks because the 67108864-sample TX, channel, time, and CTLE arrays cannot safely coexist in available memory. A short waveform must match the existing batch channel and CTLE paths before the export is allowed.
- The exported v7.3 MAT cache contains raw TX-FFE+Channel+CTLE amplitude as float32 with no ADC-range scaling; any later ADC fixture preparation owns that scaling explicitly.
- A full time vector is not cached. Consumers reconstruct it from the stored double-precision sample interval, avoiding both redundant storage and float32 time-resolution loss.
- The co-simulation defaults to preview-only execution so CTLE zero/pole tuning cannot accidentally overwrite the binary waveform cache. Cache export requires an explicit `test_channel_ctle_cosim(true)` call.

## 2026-08-17: Minimal TX and S-parameter channel boundary

- The active source gains `src/TX+Channel`; historical `src/LinkSim` TX and channel classes remain reference material and are not reused as the implementation baseline.
- `tx_channel` accepts already-mapped voltage symbols, performs only ideal zero-order hold, and passes the resulting waveform through one differential four-port S-parameter channel.
- The default interface uses 56 GBd and 128 samples/UI and returns a complete channel waveform plus its time vector for direct CTLE input.
- The four-port channel is interpreted with differential signaling and port order `[1 2 3 4]`. Source and load resistance are 50 ohms, with no added TX or RX termination capacitance.
- PRBS generation, PAM4/NRZ mapping, TX FFE, pre-emphasis, TX analog bandwidth, jitter, noise, and streaming state are outside this minimal boundary.

## 2026-08-17: Dedicated CDR FFE and LMS boundary

- The dedicated CDR equalizer is a floating-point 1-UI FIR, separate from the data-path FFE/DFE.
- The default layout is six taps with two precursor taps, one fixed unit main tap, and three postcursor taps; tap count and precursor count remain configurable.
- One FFE object processes one stream. Data/edge distinction and any coefficient synchronization across separate stream states belong to the calling top level.
- Precursor taps are realized with `PreTapCount` UI of causal output latency and explicit initial-output validity rather than requiring future-block samples at the API.
- LMS adaptation is a separate class. It consumes data-stream decision error and the FFE regressor, normalizes the gradient by the 64-UI block size by default, and never adapts the main tap.
- The coefficient update computed from one block is applied after filtering and therefore affects the following block.
- RTL coefficient widths, arithmetic quantization, saturation, and a default LMS step size are outside the first implementation.

## 2026-08-17: Open-loop ADC and optimized fixed CDR FFE pulse-response validation

- The first AFE-side ADC/FFE integration diagnostic remains open loop and uses no LMS adaptation or MMPD feedback.
- The FFE main tap remains fixed to one. The other five taps are found by a constrained least-squares solve using the actual ADC sampled pulse response.
- The constraints apply to the cascade output rather than the FFE tap vector: normalized output `pre1` and `post1` are each fixed to `+0.1` relative to main cursor one; all other fitted non-main cursor energy is minimized over `[-3,+8] UI`.
- The resulting taps are approximately `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]`. They are held fixed during the plotted open-loop run and are not produced by online LMS.
- The TI ADC samples the scaled Channel+CTLE pulse at its absolute peak phase, then the DSP reorders physical lanes into chronological UI order before applying `cdr_ffe`.
- The ADC input pulse peak is scaled to `0.24 V` inside the ideal 7-bit `[-0.3,+0.3] V` range. ADC zero-input reconstructed voltage is subtracted before cursor normalization.
- The plotted ADC/FFE cascade is labeled a sampled pulse response because ADC quantization prevents treating it as an amplitude-independent LTI unit impulse response.

## 2026-08-17: Fixed-FFE MMPD lock-range validation boundary

- The first full generated-waveform timing loop is implemented as a validation script that explicitly composes MMPD, voter, loop filter, and PI. `cdr_top` remains unchanged because its interface is currently BBPD data/edge oriented.
- The optimized open-loop FFE coefficients are frozen at `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]`; LMS adaptation is deliberately excluded from the lock-range measurement.
- The MMPD characteristic uses `[2,1,2,1]` symmetric transition-group weights and 13-sample circular smoothing to reject narrow noise-induced zero crossings. Dynamic acquisition is accepted only by closed-loop final-window criteria.
- Loop gains and polarity are selected locally from initial offsets `-3` and `+3` samples, then frozen before scanning every integer initial phase over one UI. Per-initial-phase gain retuning is not allowed.
- For the current deterministic fixture the selected fixed loop is `Kp=0.256`, `Ki=0.002`, polarity `+1`; the continuous passing interval is `[-3,+16]` samples around lock, or 0.1484 UI wide.
- For the added post-FFE voltage diagnostic, "maximum eye" means the integer phase that maximizes the minimum adjacent spacing among four unsupervised ordered FFE-output voltage centers. The histogram colors samples by nearest center and does not claim transmitted-symbol labeling or BER.

## 2026-08-20: MMPD-v1 CTLE cache and fixed-segment phase scan

- `test_channel_ctle_cosim.m` owns only PRBS20 generation, the optional TX FFE, Channel, CTLE, and cache export. The 10-tap TX FFE implementation remains under `if false` and the default cache contains the un-equalized Channel+CTLE waveform.
- One complete PRBS20 bit period is cached. The odd final bit is paired with the repeated first bit, producing 524288 PAM4 symbols and 67,108,864 waveform samples at 128 samples/UI.
- The cache is a v7.3 MAT file with `single` `ctleOutput`, PAM4 symbols, Channel+CTLE impulse response, timing/configuration metadata, and TX-FFE status. The complete Channel waveform is not stored.
- `mmpd_s_curve_own_data.m` owns the existing `ti_adc_top`, optimized `cdr_ffe`, amplitude calibration, live PAM4 slicer, and offline classic Mueller-Muller phase scan.
- Every phase from 0 through 127 uses the exact same cached UI interval `[512,16896)`. Phase scanning changes only the sample offset; it never advances to a different data segment.
- The ADC uses 64 lanes, 7-bit conversion, and fixed `[-4,+4] V` input limits. Each phase run resets the ADC and CDR FFE and processes 256 blocks of 64 UI.
- The CDR FFE keeps the 10-tap layout `[-3,+6] UI` and its main coefficient fixed at one. The other nine coefficients are solved from the quantized Channel+CTLE unit-UI response by constrained regularized least squares.
- The two response constraints are normalized `pre1=0.1` and `post1=0.1` relative to main one. The objective minimizes all other cursor energy over `[-3,+9] UI`.
- ADC codes are centered by subtracting midcode 64 before CDR-FFE filtering. The CDR-FFE histogram therefore represents floating-point centered equalized code, not raw integer ADC code.
- CDR-FFE coefficients are designed once at phase 19 and frozen across phases. Phase-19 output centers define one fixed linear code-to-`[-3,-1,+1,+3]` amplitude calibration for the full scan.
- The cached-data diagnostic uses the classic equation `d[n-1]e[n]-d[n]e[n-1]`, with full PAM4 decision amplitudes and signed residual amplitudes. It intentionally does not reuse the binary-error `cdr_pd.mmpdFast` behavior. In addition to the unfiltered live curve, it reports a phase-19 fixed-decision reference and the reference script's symmetric-transition live filter; the outer-transition-only filter remains excluded.
- The fixed-decision comparison is represented on a phase-19-centered `[-0.5,+0.5) UI` axis. When a raw `0:127` ADC phase maps across that centered UI boundary, the fixed decision sequence is shifted by one symbol and edge samples are trimmed rather than circularly reused.
- The Channel+CTLE unit-impulse peak phase is not used as the ADC reference phase. CDR-FFE cursor constraints are formed from the one-UI symbol-pulse response sampled at the retained phase-19 design point.
