# Validation

## Scope

This validation record covers current TX, channel, AFE, ADC, and CDR components. `LinkSim` results are not used as evidence for the current model.

### CDR: SS-MMPD realized through uniform-weight MMPD in v3 (2026-09-20)

- SS-MMPD is not a separate `cdr_pd` method: sign-derived PAM4 symbols (`0-3`) and error bits (`0/1`) are passed to `mmpd`/`mmpdFast` with `transitionFilter=false`. This uniform-weight path already is the SS-MMPD kernel, so the redundant `ssmmpd` methods were removed.
- `cdr_dlev_cdrffe_sslms_v3.m` now calls `mmpdFast(..., false)` with the same derived inputs. The three SS-MMPD-specific `test_cdr_pd` groups were removed; equivalence is to be re-verified by the parent replay, while the MMPD framework and transition-filter-OFF tests continue to cover the kernel.

## Evidence levels

1. **Execution check**: script completes without MATLAB error.
2. **Behavioral/visual validation**: plots and statistics are reviewed.
3. **Automated regression**: assertions enforce expected values and tolerances.

Most ADC validation is currently level 1-2. The CDR PD validation contains explicit checks, while the PI validation is primarily visual/behavioral.

## Executed validation

All 13 scripts under `validation/` completed with exit code 0 in independent MATLAB batch sessions during the repository reorganization. The run record is `results/validation_summary.csv`.

### CDR: configured `cdr_top` code-domain core and v4 runner (2026-09-23)

`src/CDR/cdr_top.m` gained a config-struct construction path that owns the full code-domain CDR core, and `validation/CDR/test_cdr_dlev_cdrffe/src/cdr_dlev_cdrffe_sslms_v4/cdr_dlev_cdrffe_sslms_v4.m` drives it. The acceptance gate for the refactor was block-level bit exactness against the v3 runner, not a behavioural resemblance.

Equivalence evidence (MATLAB R2025b). Each run pair used identical name/value options, `SaveOutputs=false`, `EyeDiagramEnable=false`, start phases `[20 64]`, and compared 26 result fields with `max(abs(v3 - v4))`:

| Case | Options | Result |
|---|---|---|
| gate | `NumBlock=1500`, gate `100/20`, `FfeFreezeMode='pvt-track'` | 26/26 fields diff 0 |
| freeze | `NumBlock=1500`, gate `100/20`, `FfeFreezeMode='freeze'` | 26/26 fields diff 0 |
| prod | `NumBlock=6000`, gate `500/100`, `FfeFreezeMode='pvt-track'` | 26/26 fields diff 0 |

The compared fields are `PhaseCodeTrace`, `UiSlipTrace`, `UnwrappedPhaseTrace`, `TimingErrorTrace`, `DeltaCodeTrace`, `EdgeCountTrace`, the three dLev traces, `FfeCoeffTrace`, `FfeRawDeltaTrace`, `FfeAppliedDeltaTrace`, `FfeProposedCoefficientTrace`, `FfeAdaptationCalculatedTrace`, `FfeWriteAppliedTrace`, `FfeFrozenTrace`, `FfeFreezeBlock`, `FfeFreezeCenterUnwrapped`, `FfeFreezeEventCount`, `FfeFrozenCoefficients`, `LockedFlag`, `LockedPhaseCode`, `CommonLockPhase`, the dLev finals and `FfeFinalCoefficients`. In the gate case the PVT-track gate fired at block 1455 for start phase 64 in both runners; in the prod case both starts locked.

v4 no-argument default run (PRBS22, `NumBlock=30000`, `StartPhaseStep=16`, 8 start phases), 134.1 s:

- 8/8 start phases locked and `AllPhaseLock = 1`; common lock phase 113, spread 4, modes `[111 112 113 114 111 114 115 112]`, final-window center-touch counts 72..87 against the unchanged 51-event criterion.
- First-capture blocks `[3217 3445 4071 5434 3770 4494 3748 2544]`; the convergence figures select start phase 48 (slowest first capture, block 5434).
- The PVT-track gate engaged on all 8 starts at blocks `[6558 10960 9064 9328 7474 15982 12356 6013]`.
- `DlevConsistent = 1`, inner/outer means 10.019/30.286 code.
- Failing criteria, recorded without retuning: `FfeConsistent = 0` (max coefficient spread 0.04466 > 0.02) and `FfeConstraintHeld = 0` (pre1 = +0.0051 passes, post1 = -0.0218 marginally exceeds 0.02). dLev truth error is -2.231/-6.431 code. These reproduce v3 bit for bit and are therefore pre-existing SS-LMS limits, not refactor regressions.
- Outputs and the required implementation summary are under `validation/CDR/test_cdr_dlev_cdrffe/result/cdr_dlev_cdrffe_sslms_v4/` (`impl_notes.md`, result MAT, 10 figures, two CSV summaries).

Unit regressions rerun in MATLAB R2025b: `test_cdr_top` 6/6 (legacy path unchanged), the new `test_cdr_top_configured` 11/11, `test_cdr_voter` 7/7, `test_cdr_loop` 10/10, `test_loop_monitor` 11/11, `test_cdr_ffe_freeze_integration` 5/5 and `test_cdr_validation_paths` pass. `test_cdr_top_configured` covers default-config synchronisation with v3, the one-block dead time (`phase[k+1]==phase[k]`, `phase[k+2]==phase[k]+delta[k]`), the boundary valid mask and its adaptation skip, `cdr_top.slicePam4` encoding, the `ssmmpd`-to-`mmpd` alias producing identical block traces, `freeze` inhibiting writes while still computing raw deltas, `pvt-track` continuing to write with a collapsed step, the single-shot mu downshift, reset-and-replay determinism, per-field invalid-config rejection, and the legacy path rejecting `flush`.

Follow-up rename (same session): `ffe_freeze_monitor` was renamed to `src/CDR/loop_monitor.m` and absorbed the dLev mu-downshift FSM as a second causal detector (`recordDlevOuter`/`updateDlevSettle`, bounded ring buffer). Behaviour neutrality was proved by snapshotting v3 in the three equivalence configs before the rename and re-running after: 26/26 fields, `max abs diff 0` in every config (`V3_RENAME_NEUTRAL=1`). The v3->v4 equivalence was then re-confirmed unchanged. `test_loop_monitor` adds the dLev-settle one-shot latch, ring-buffer boundedness over 5000 blocks, and disabled-mode/invalid-input rejection.

`checkcode` is clean on `cdr_top.m`, `cdr_voter.m` and `loop_monitor.m`; the v4 runner reports one ISCL advisory and the paths test keeps its pre-existing MSNU/NASGU advisories.

### CDR: three-loop steady state is a dither, not a drift (2026-09-23)

The integer PI code hides sub-code motion: both `LastRawDeltaCode` and the applied `deltaCode` are integers, so a slow drift and a true lock both render as a staircase on the phase-code trace. `cdr_top` therefore exports the loop filter's pre-quantization state per block (`LoopControl = Kp*phaseError + FrequencyState`, `LoopFrequencyState`, `LoopCodeResidue`, `LoopPendingCode`), which v4 stores as four traces plus `cdr_loop_dither_vs_drift.fig`.

Criterion ranking, stated explicitly to avoid over-claiming:

- **Decisive**: `LoopControl` long-window mean (should be about 0) and `FrequencyState` steady value (the sustained drift velocity a real drift would require).
- **Corroborating only**: `LoopCodeResidue`. Its `(-1,1)` range is structural and always filled, so the range proves nothing; only its sign distribution is informative, since a one-directional drift keeps `residueAccum = residue + v` same-signed and `fix()` truncation pins the residue to one side.
- **Disqualifying**: `LoopPendingCode` persistently non-zero means the loop is slew-limited and therefore still chasing.

Measured on the v4 no-argument default run (PRBS22, 15000 blocks, 8 starts, `MaxDeltaCode = 1`), statistics over the last 2000 blocks:

| start | mean `LoopControl` | `FrequencyState(end)` | net drift (UI) |
|---|---|---|---|
| 0 | -3.62e-06 | 4.203e-03 | 0.0000 |
| 16 | 2.157e-04 | 5.571e-03 | 0.0078 |
| 32 | 4.355e-05 | 4.740e-03 | 0.0000 |
| 48 | -2.056e-05 | 3.857e-03 | -0.0078 |
| 64 | 3.080e-04 | 5.248e-03 | -0.0078 |
| 80 | -4.181e-04 | 1.490e-03 | 0.0000 |
| 96 | 3.532e-04 | 6.131e-03 | -0.0078 |
| 112 | -2.367e-04 | 4.218e-03 | -0.0078 |

- Residual phase velocity is order 1e-4 code/block, i.e. about 0.05 ppm — effectively zero.
- `FrequencyState` settles around 5e-3 with no ramp, so there is no unacquired frequency offset.
- `LoopPendingCode` was non-zero on only 5 of 120000 block-phase updates, all during acquisition and none after block 5432, so the one-code slew limit is not what constrains convergence.
- Net tail drift is 0 or +/-0.0078 UI, which is exactly one PI code.

**Conclusion: the converged state is a genuine limit-cycle dither, not a slow drift.** Reusable criterion over the last 2000 blocks: `|mean(LoopControl)| < 1e-3`, sign-flip ratio of non-zero `DeltaCode` `> 0.4`, and `|net drift| < 0.05 UI`.

`MaxDeltaCode` was changed from `12` to `1` in this run to match a real phase interpolator. Lock is unchanged at 8/8 with `AllPhaseLock = 1`, common phase 113 and spread 4. Because v3 still defaults to `12`, equivalence runs pin `MaxDeltaCode` explicitly; with it pinned the v3-to-v4 refactor remained bit-exact in all three configurations, and `test_cdr_top` 6/6, `test_cdr_top_configured` 11/11, `test_cdr_voter` 7/7, `test_cdr_loop` 10/10, `test_loop_monitor` 11/11, `test_cdr_ffe_freeze_integration` 5/5 and `test_cdr_validation_paths` all passed.

### CDR sub-block documentation audit rerun (2026-09-22)

- MATLAB R2025b reran the current digital control-chain regressions: `validation/CDR/test_subBlock/test_cdr_pd.m` passed 13/13 groups, `tests/CDR/test_cdr_voter.m` passed 7/7, `tests/CDR/test_cdr_loop.m` passed 10/10, and `tests/CDR/test_cdr_top.m` passed 6/6. A direct current-signature dLev SS-LMS smoke (`dlevSsLms(d,e)`) passed one four-sample update and produced inner/outer/threshold 1.05/3.05/2.05.
- `tests/CDR/test_cdr_ffe.m` currently fails at line 74 because it expects `cdr_ffe:MainTapUpdate`, but `cdr_ffe.applyCoefficientDelta` accepts and applies a nonzero main-tap delta. `tests/CDR/test_cdr_ffe_loop.m` currently fails at line 132 because it expects `cdr_ffe_loop:MainTapAdaptEnabled`, while the corresponding source validation has been commented out and a custom all-enabled mask is accepted. These are stale test-contract assertions; they do not supersede the separately validated default-mask FFE adaptation results below.
- `validation/CDR/test_subBlock/test_lms_loop.m` is not a current dLev regression: it still calls `dlevLms(rxSamples)` / `dlevSsLms(rxSamples)`, while the source API requires the shared slicer outputs `(d,e)`. The script also has no numerical pass/fail assertions. No claim of dLev convergence is made from that legacy script.
- The source-backed implementation summary and exact boundaries are recorded in `docs/CDR_SUB_BLOCKS.md`. This audit changed no model code, parameter, physical assumption or acceptance criterion.

### TX and S-parameter channel

- MATLAB R2025b automated regression passed 5/5 checks for the default 56 GBd, 128-samples/UI configuration.
- Ideal zero-order hold and row/column orientation were checked exactly.
- The specified four-port Touchstone channel produced finite, nonzero, length-preserving output with a matching time vector.
- The channel output was processed directly by `src/AFE/ctle.m` with preserved shape and finite output.
- Empty, nonfinite, nonvector symbol inputs and invalid rate/oversampling configuration were rejected with stable error identifiers.
- `validation/AFE/test_channel_s21_eye.m` converts the four-port data to differential `Sdd21`, generates 8192 normalized PAM4 symbols from PRBS20, runs the existing TX+Channel model, and plots a 2000-trace 2-UI output eye after discarding 1000 UI.
- The 28 GHz PAM4 Nyquist point is marked on the differential response. Its `Sdd21` magnitude is approximately -14.09 dB, corresponding to a positive insertion loss of 14.09 dB. Without TX or RX equalization, the resulting PAM4 eye is severely closed.
- The saved diagnostics are `results/AFE/channel_sdd21.png` and `results/AFE/channel_output_eye.png`.

### AFE: fixed CTLE

- MATLAB R2025b smoke validation confirmed 0 dB DC gain and exactly 4.5 dB relative gain at the 28 GHz symbol Nyquist frequency for the default 56 GBd configuration.
- Both continuous-time poles were real and in the open left half-plane.
- `lsim` complete-waveform processing preserved row and column orientation, produced finite output, and settled to unity for a DC input.
- `validation/AFE/test_ctle_frequency_response.m` plots the 100 MHz to 100 GHz magnitude response for 128 samples/UI, marks the 28 GHz Nyquist point, asserts the DC and Nyquist gains, and saves `results/AFE/ctle_frequency_response.png`.
- `validation/AFE/test_channel_ctle_cosim.m` passed in MATLAB R2025b using a 2048-symbol preview at 56 GBd and 128 samples/UI. The validation-specific CTLE uses `fz=6 GHz`, `fp1=28 GHz`, `fp2=50 GHz`, and `0 dB` DC gain, giving `9.38 dB` gain at 28 GHz.
- Offline least squares selected TX FFE taps `[0.0214425,-0.144777,0.671335,-0.0844467,0.0698928,-0.00810601]` in `[pre2,pre1,main,post1,post2,post3]` order. Their L1 norm is one and the main tap is positive.
- The final waveform maximum-power phase is 20/128 with label-conditioned separation 1.6543. Scanning true PRBS20 labels selects phase 118/128 with separation 10.3661; therefore maximum power is retained as a diagnostic and is not asserted to equal the best eye center.
- The plotted normalized TX-FFE+Channel+CTLE unit-impulse cursor vector from 3 pre through 6 post is approximately `[0.009373,-0.006758,0.005610,1,-0.314167,0.165436,-0.070889,0.032318,0.008439,-0.003172]`. These impulse-kernel samples differ from the symbol-pulse cursors used by the FFE optimizer because the TX input uses a one-UI zero-order hold.
- The added one-UI symbol-pulse plot is aligned to the optimizer-selected main index. Its normalized `[-3,+6] UI` cursor vector is `[0.00956567,-0.00247827,0.000472663,1,-0.000253635,0.00138516,0.000376327,0.0120371,0.0187156,-0.00855913]`; an assertion matched all plotted cursors to the optimization result within `1.39e-16`.
- A 2048-symbol chunked/batch equivalence check measured maximum absolute errors of `2.89e-15` for the channel and `3.11e-15` for the CTLE.
- A complete cache export contains 524288 PAM4 symbols and exactly 67108864 float32 CTLE samples. The waveform occupies 256 MiB before MAT/HDF5 container overhead.
- Saved outputs include `results/AFE/channel_ctle_cosim/ctle_and_channel_ctle_frequency_response.png`, `tx_ffe_channel_eye.png`, `tx_ffe_channel_ctle_eye.png`, `tx_ffe_channel_ctle_impulse_response.png`, `tx_ffe_channel_ctle_symbol_pulse_response.png`, and `ctle_out_prbs20_full_period.mat`.
- The frequency-response figure is regenerated from the current zero/pole values at the top of the validation script. Exploratory parameter runs may therefore differ from the configuration recorded in an existing waveform cache until that cache is explicitly regenerated.
- Calling `test_channel_ctle_cosim` with no argument runs preview-only eye, impulse, frequency-response, phase-power, and chunk-equivalence checks. Binary MAT cache generation is opt-in through `test_channel_ctle_cosim(true)`.
- MATLAB R2025b binary-cache validation passed with the current `2^16-1`-bit debug setting: 32768 PAM4 symbols produced 4194304 finite `single` final-output samples. Stored TX FFE taps and offsets matched the preview, and `sampleInterval` remained `1.3950892857142857e-13 s` in double precision.

### AFE: Channel, CTLE, TI ADC, and optimized fixed CDR FFE pulse response

- `validation/AFE/test_channel_ctle_ti_adc_cdr_ffe.m` passed in MATLAB R2025b with offline tap optimization, no online LMS adaptation, and no CDR feedback loop.
- The Channel+CTLE pulse was scaled to a `0.24 V` absolute peak and sampled by the ideal 64-lane, 7-bit, `[-0.3,+0.3] V` TI ADC at phase 88 of 128 waveform samples/UI.
- Physical TI ADC lane output was reordered into chronological UI order, its zero-input reconstructed-voltage baseline was removed, and the result was passed through `cdr_ffe`.
- Constrained least squares selected taps `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]` while keeping the main tap fixed at one.
- The normalized cascade output achieved the explicit target `pre1=post1=+0.1`. Other fitted cursors from `-3` through `+8 UI` had approximately `0.01971` RMS and `0.03813` maximum absolute residual.
- `results/AFE/channel_ctle_ti_adc_cdr_ffe/sampled_pulse_response.png` compares the aligned Channel+CTLE analog response, TI ADC sampled response, and CDR FFE output response.
- `results/AFE/channel_ctle_ti_adc_cdr_ffe/cdr_ffe_impulse_response.png` shows the exact standalone FFE unit impulse response.

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

### Caller-assembled CDR FFE window regression

- MATLAB R2025b ran `tests/CDR/test_cdr_ffe.m` and passed 7/7 checks.
- The checks cover the default main-only response, configured six-tap FIR mapping, exact regressor rows, the fixed double row-vector output contract, validated/fast equivalence, fixed-main coefficient update and reset, short or malformed windows, and invalid configuration.
- MATLAB `checkcode` reported no issue for `src/CDR/cdr_ffe.m`.

### CDR FFE block LMS regression

- MATLAB R2025b ran `tests/CDR/test_cdr_ffe_loop.m` and passed 8/8 checks.
- The checks cover the `desired-output` update sign, block-length normalization, validated row/column error inputs and `double` conversion, validated/fast delta equivalence, optional fast-path gradient output and single-output compatibility, fast-path diagnostic-state isolation, arbitrary adaptation masks with a fixed main tap, runtime step-size changes and reset, invalid input/configuration rejection, and minimal integration with `cdr_ffe`.
- MATLAB `checkcode` reported no issue for `src/CDR/cdr_ffe_loop.m` or `tests/CDR/test_cdr_ffe_loop.m`.

### Fixed-phase Channel+CTLE/TI-ADC/CDR-FFE adaptation

- MATLAB R2025b ran `validation/CDR/test_subBlock/test_cdr_ffe_adaptation.m` on 16384 UI from the complete Channel+CTLE fixture at fixed zero-based phase 20. The ideal TI ADC configuration was 64 lanes, 7 bits, and `[-4,+4] V`.
- The bounded delay scan selected 105 UI with normalized correlation 0.922208. Subtracting ADC zero code 64 and fitting the first 4096 aligned training samples produced one frozen PAM4 scale of approximately 0.078439.
- The initial step-size list was `[1e-5,3e-5,1e-4,3e-4,1e-3,3e-3,1e-2,3e-2]`. Supervised-only acceptance selected `mu=0.01` with tail MSE 0.0343438; the primary 8192-supervised/8192-DD split passed, so fallback was not used.
- Final coefficients were approximately `[0.1039,-0.3756,1,0.1728,0.0071,0.0265]`. During the DD half, SER was zero, truth and decision MSE were both approximately 0.0343555, minimum adjacent known-label level opening was 1.89755, final 16-block coefficient span was 0.002199, and maximum tail delta was 0.001158.
- The machine checks enforce the documented supervised ratios/span/delta thresholds and independent DD SER/MSE/opening/span/delta thresholds. MATLAB `checkcode` reported no issue for the validation file.
- Outputs are `mu_scan.png`, `coefficient_convergence.png`, `mse_convergence.png`, `before_after_histogram.png`, and `result.mat` under `validation/CDR/test_subBlock/result/test_cdr_ffe_adaptation`.

### v3 terminal adjacent-pair PI lock regression (2026-09-16)

- `tests/CDR/test_detect_pi_dither_lock.m` passed 9/9 check groups in MATLAB R2025b. Coverage includes exactly 50 versus 51 transitions, dwell counting, constant/monotonic/three-code rejection, historical lock followed by drift, pair reset and relock, whole-UI slips, signed wrap invariance, row/column equivalence, empty/invalid input, and 1000 seeded random traces against an independent exhaustive segment/suffix oracle.
- The criterion is terminal, not historical: only the final contiguous fixed adjacent pair can qualify, with at least 51 actual jumps. Dwell neither counts nor resets; leaving the pair resets. Both `[-1,0]` and `[127,128]` identify wrapped pair `[127,0]` with the same reported integer center. No maximum dwell duration is assumed.
- Before correction, the standalone detector returned true for 59 adjacent-pair transitions followed by monotonic drift to code 80, and false for 59 transitions with three-block dwell per visited code. The new tests cover both failure modes.
- Integration replay explicitly used `DlevOuterInit=36`, `DlevInnerInit=12`, `SaveOutputs=false`, 8000 blocks, and all 32 starts. Runtime was 73.568 s. All eight checked dynamic traces matched the retained MAT exactly: wrapped phase, UI slip, unwrapped phase, phase error, delta code, inner/outer dlev, and FFE coefficients. This demonstrates no change to loop dynamics for the tested configuration.
- The new **convergence result is 0/32**, versus the stored legacy 32/32 result. Every terminal pair contains only one transition; no start meets 51. `AllPhaseLock=false`, claimed lock centers/common phase are `NaN`, and cursor evaluation falls back to reference phase 19. Test success must not be confused with the modeled loop meeting this stricter convergence requirement.
- `checkcode` reports no issue in the detector or its test; v3 retains only the pre-existing `ISCL` suggestion. Existing result MAT/PNG files were not regenerated. Logs and returned replay result are session-scoped under `$PICODE_ARTIFACT_DIR/pi_dither_tests.log`, `pi_dither_integration.log`, and `pi_dither_integration_result.mat`.

### v3 PRBS22 single-start 20000-block observation (2026-09-16)

- MATLAB R2025b execution passed in 18.014 s with `StartPhaseList=20`, `CosimDir='channel_ctle_cosim_prbs22'`, `TxFile='tx_prbs22.mat'`, `AnalysisNumUi=1280512`, anchors outer/inner=36/12, Kp/Ki=8/0.03, dlev mu=0.3/0.1, FFE mu=0.02/1e-4, 500 training blocks, and `SaveOutputs=false`. The complete PRBS22 cache has 2,097,152 PAM4 symbols, and the cached Channel+CTLE impulse exactly matches PRBS20.
- Assertions verified one start at phase 20, exactly 20000 blocks, finite dynamic arrays, and main FFE tap exactly one. Detector regression passed 9/9 after the `StartPhaseList` option was added. Static analysis reports only the existing `ISCL` style suggestion.
- Mean phase in non-overlapping 2000-block windows after the first 2000 blocks: `[13.351,13.1625,12.965,12.7415,12.6055,12.421,12.227,12.097,11.9375]`. Thus a slow center drift remains visible through 20000 blocks despite narrow-band instantaneous jitter.
- Last 2000-block code range is 10..14, mean 11.9375, std 0.760844, and fitted total drift -0.216043 code; last-8000 fitted drift is -0.639896 code. Post-training UI slip remains -1. Strict terminal-pair `LockedFlag=false` (one final 10/11 transition), but the finite-window statistics must be considered separately from that deliberately restrictive pattern criterion.
- Single-start cross-phase consistency flags are vacuous (zero spread with one sample); they do not verify temporal dlev/FFE convergence. The run uses a different PRBS order, not an extension of the exact PRBS20 symbol sequence. Only execution/shape/invariant checks are asserted, not BER, all-start acquisition, or infinite-time stability.
- Evidence: `$PICODE_ARTIFACT_DIR/prbs22_start20_20000blocks.log`, `prbs22_start20_20000blocks_result.mat`, and `prbs22_start20_20000blocks_phase.png`. The plot shows the full trace, post-training trace with 500-block means, and the final 200 blocks. Existing result files were not overwritten.

### v3 terminal modal-center touch/cross trial (2026-09-16)

- The independent diagnostic `results/CDR/pi_center_touch_trial/trial_center_touch_lock.m` evaluates a saved result only: modal center from final 2000 unwrapped codes, counting on those same 2000 blocks, inclusive center +/-3-code band, arrival-at-center or direct-cross events, no extra dwell/departure count, and reset on any band violation. More than 50 retained events passes. Center touches followed by same-side return explicitly qualify per user instruction.
- Synthetic checks passed for touch-and-return, touch-and-cross, repeated center dwell, direct crossing, constant center, repeated visits, upper/lower band violations, inclusive boundaries, exactly 50/51 counts, and negative unwrapped-code coordinates. On the real trace the state-machine event mask and retained count exactly matched an independent vectorized oracle.
- PRBS22, 20000 blocks, initial phase 20, anchors 36/12: only blocks 18001..20000 were evaluated. Center=12 with 1000 occurrences; actual code range=10..14 within permitted 9..15; out-of-band count=0; 168 arrivals + 10 direct crossings = **178 retained events, pass**. Last-200 count=17. Event 51 occurs at block18588 within the selected window, not necessarily the full trace's first lock instant.
- Output PNG/MAT are `results/CDR/pi_center_touch_trial/trial_center_touch_trial.png` and `trial_center_touch_result.mat`; execution log is `$PICODE_ARTIFACT_DIR/trial_center_touch_validation.log`. No new simulation was run and no saved source result or production detector was overwritten. This is a single-start finite-window criterion trial only.

### v3 PRBS22 20000-block 32-start modal-center lock regression (2026-09-16)

- MATLAB R2025b completed the explicitly configured 36/12-anchor run in 213.954 s: `CosimDir='channel_ctle_cosim_prbs22'`, `TxFile='tx_prbs22.mat'`, `AnalysisNumUi=1280512`, `StartPhaseList=0:4:124`, Kp/Ki=8/0.03, dlev mu=0.3/0.1, FFE mu=0.02/1e-4, 500 training blocks. `ResultDir` isolates all outputs under `results/CDR/prbs22_20000blocks_allphase_center_touch/`.
- All 32 per-start phase-lock flags pass the last-2000 modal-center +/-3-code criterion, with 143..186 retained arrival/direct-cross events and zero band violations for every start. `AllStartsConverged=1`, `AllPhaseLock=1`, common code=13, mode range=11..14, and circular spread=3. The lock-phase plot's ordinate is the measured final-window mode, not an average or final instantaneous sample.
- An independent vectorized oracle verifies all 32 modal codes, event masks, retained counts, violation counts, and final flags. The start-20 seven checked phase/error/dlev arrays plus FFE coefficient tensor exactly match the prior single-start run. Its final mode/count are 12/178. New detector tests pass 9/9 groups with 100 seeded oracle cases; historical strict detector tests remain 9/9. New helper `checkcode` is clean; tests have two nonfunctional style/analyzer advisories and v3 retains the existing `ISCL` suggestion.
- One tie exists at start 96: codes 13 and 14 each occur 841 times. The documented deterministic lowest-unwrapped-code convention selects 13. Independent sensitivity check: center13 gives157events, center14 gives150events, both without violations and both pass. A temporary assertion that every mode was unique was therefore removed from the manual verification assumptions; the saved mode array matches MATLAB `mode` exactly.
- Separately, `FfeConsistent=false`: max cross-start coefficient spread=0.0255797 exceeds0.02. `FfeConstraintHeld=false`: pre1=-0.0382, post1=-0.0687 exceed the +/-0.02 cursor limits. Phase-lock success does not imply these FFE precision checks pass.
- Native PNG/MAT outputs and `lock_summary.csv` are in the isolated directory above. Execution log is `$PICODE_ARTIFACT_DIR/prbs22_20000blocks_allphase_center_touch.log`. This covers the 32 sampled starts, not every integer phase, BER, or infinite-time stability.

### v3 slowest first-capture convergence plotting (2026-09-16)

- `tests/CDR/test_select_slowest_pi_capture.m` passed9/9 groups: touch/direct-cross/dwell counting, inclusive bounds, resets before capture, later resets preserving the first timestamp, final-lock eligibility, maximum-time tie order, no eligible case, full-history detection before the last2000 blocks, unwrapped shift invariance, flag shape handling, and invalid inputs. The existing modal-center detector also passes9/9.
- Replay of the full PRBS22/20000-block/36-12-anchor/32-start run completed in146.178s with final phase lock32/32 unchanged. Eight full dynamic trace arrays and three lock-result arrays are exactly equal to the preceding saved all-phase run. Selector output is row25/start96, first capture9849, modal code13; start76 has first capture8569. All32 per-start first-capture times are saved in `first_capture_summary.csv`.
- The phase plot contains one selected phase trace; dlev contains that same start's inner/outer traces; each free-tap FFE subplot contains one trace from that same start. All annotate the PI first-capture block, explicitly not an FFE/dlev settling time. Selection uses final-locked starts only and renders placeholders rather than a falsely selected unlocked trace when no candidate qualifies.
- Output files in `validation/CDR/test_cdr_dlev_cdrffe/result/cdr_dlev_cdrffe_sslms_v3/` were regenerated at the user's request, including a complete MAT with selected-phase metadata and `impl_notes.md`. The old isolated all-phase result under `results/CDR/prbs22_20000blocks_allphase_center_touch/` remains unchanged. Runtime log: `$PICODE_ARTIFACT_DIR/v3_slowest_first_capture_validation.log`.
- FFE cross-start consistency and cursor precision still fail their existing checks. This plotting change makes no additional physical convergence claim, does not alter the final-window phase-lock rule, and changes no loop dynamics/default gains or nominal anchors.

### Phase-96 training-vote replay and frozen-FFE causal control (2026-09-16)

- Reconstructed 501 actual 64-lane ideal ADC blocks from the saved phase/slip trace and the PRBS22 cache, then replayed first500 FFE outputs with the recorded pre-update coefficient state, three-past/two-future window, and105-UI golden delay. Predicted dlev SS-LMS increments match all500 recorded updates (including skipped first-block adaptation) within2.84e-15. Aggregate outer |output| medians for blocks81..160 and221..300 are34.48047 and34.95375; the net outer votes change from negative to positive as the FFE/phase output distribution moves. This verifies the implemented update direction, not an assumption that the terminal amplitude was fixed throughout training.
- Phase-loop replay from recorded timing errors exactly reproduces all20000 `DeltaCodeTrace` values. Maximum pending backlog=0; maximum |delta|=4. The early integral state remains negative after first crossing the final-band neighborhood (about-0.298 at31, -0.204 at150), consistent with the observed transient overshoot.
- Freeze control: start96, all baseline settings preserved except `FfeStepSizeSettle=0`, `SaveOutputs=false`. Execution completed in20.262s; dynamic prefix through499 is identical and all FFE coefficients remain exactly constant from500. Baseline mean phase501..2500 and18001..20000:15.1255/13.4660. Frozen FFE:15.2020/15.1395. Hence most long phase drift disappears when continued FFE adaptation is removed while timing/dlev remain active. This is diagnostic evidence for coupled moving equilibrium, not adoption of frozen adaptation as a solution.
- Same-trace metric sensitivity: choosing tied final mode13 versus14 changes first51-event time from9849 to1522, while both centers pass the final-window lock check. First-capture ranking must therefore be interpreted as the documented retrospective metric, not an invariant physical acquisition-time measurement.
- Logs/MAT evidence are session-scoped `phase96_freeze_ffe_diagnostic.log`, `phase96_frozen_ffe_result.mat`, `phase96_training_votes_retry.log`, and `phase96_training_replay.mat`. The first training replay attempt failed on unsupported MatFile linear indexing; retry reads the impulse variable before reshaping and passes. No production model or saved baseline plots/results were changed.

### Causal FFE write-freeze and fixed-tap 2048-UI eyes (2026-09-17)

- `test_ffe_freeze_monitor` passes9/9 groups, `test_build_cdr_ffe_eye`7/7, `test_build_cdr_ffe_eye_pair`6/6, `test_cdr_ffe_freeze_integration`5/5, `test_select_slowest_pi_capture`9/9, and `test_detect_pi_center_touch_lock`9/9. These cover causal100-occurrence/50-event gates, ties, reset/research, permanence, actual ideal TI-SAR equivalence, tap direction, density conservation, exact freeze+1 block selection, signed-slip physical bounds, short/truncated/not-frozen windows, and real2500-block freeze-on/off prefix/write/proposal invariants. Helpers do not infer lock from future data.
- Full PRBS22/20000-block/36-12-anchor/32-start run completed in227.597s. Every start freezes in1214..1465 with50 events after >=100 modal occurrences, and all32 final phase criteria pass with146..184 events and0 band violations. Common phase14/spread4. Effective coefficients are exactly constant after each freeze; calculated raw deltas remain finite/nonzero. Coefficient prefix before each veto and phase/dlev prefix through the veto block match the unfrozen baseline exactly.
- Recomputed slowest selected start44: first PI capture1222, FFE freeze1465, freeze mode12, final mode13. Freeze eye starts exactly at block1466/segment UI94015 and uses2048 UI; final eye starts segment UI1278207 and ends at the final physical block endpoint. Both grids are128x2048 and each2-UI density contains524032 observations. Replaying the actual64-lane TI-ADC and FFE at phase0, marker,64,127 reproduces both eye grids' first64 outputs with zero error. Markers retain physical cached-UI coordinates rather than shifting the plots.
- Individual/combined eye figures, updated MAT and per-start summaries are in the user-requested v3 result directory. `SaveOutputs=false` is tested without creating files; eye sample count is configurable and insufficient data is not filled using earlier/pre-freeze samples. Logs: `$PICODE_ARTIFACT_DIR/ffe_freeze_integration_tests.log` and `v3_online_freeze_full_validation.log`.
- Final delivery replay after adding native CSV export and freeze-time plot markers completed in164.409s;12 diagnostic/dynamic arrays and both eye grids exactly match the first passing freeze run. Native capture/freeze CSVs match the saved MAT, including selected start44, first capture1222 and freeze1465. A first export attempt used incorrect result-field aliases and failed at `FfeFreezeCenter`; the four CSV field references were corrected, the export block smoke-tested, and the complete rerun passed. Final replay log: `$PICODE_ARTIFACT_DIR/v3_freeze_final_delivery_retry.log`.
- Separate FFE precision failures remain: coefficient spread0.02964>0.02 and pre1/post1=-0.0506/-0.0587. A permanent write freeze trivially removes temporal coefficient variance, which must not be treated as proof of optimum equalization or BER. This test covers32 sampled starts, not every integer initial phase.

### PRBS20/8000-block return with FFE freeze (2026-09-17)

- Same previously validated loop/freeze configuration and explicit36/12 anchors, but `CosimDir='channel_ctle_cosim'`, `TxFile='tx_prbs20.mat'`, `AnalysisNumUi=512512`;32 starts `0:4:124`. The executable defaults already select this cache/length, so no algorithm/source edit was required. Full execution completed in151.295s.
- All32 starts freeze (blocks1229..1573) and pass their individual final-window phase criterion (154..192 retained events,0 violations). `AllStartsConverged=true`, but `AllPhaseLock=false`: common15 with modal span11..17; starts28/32 at11 exceed common+/-3. FFE coefficient spread0.0444016 and cursor checks still fail their existing precision gates.
- Slowest first capture is start36 at1180, freezing1525 with both marker centers16. The latest FFE freeze is separately start64 at1573. Freeze eye starts block1526/segment UI97856, final eye starts510208; each2048UI, exactly524032 density observations, with correct final endpoint512256 and shared frozen taps.
- Independent mode/event and selector verification, post-freeze tap/write invariants, config/shape checks, eye boundary/marker/density checks, and nativeCSV consistency all passed. Monitor9/9, eye-pair6/6 and selector9/9 tests also passed. Existing v3 output files were regenerated as requested, with the current configuration saved in MAT and implementation notes. Log: `$PICODE_ARTIFACT_DIR/v3_prbs20_8000_freeze_validation.log`.

### Fixed48/16 three-loop gain search and all-start validation (2026-09-17)

- Baseline is the actual user working-copy configuration at task entry: PRBS22/16000 blocks,32starts, anchors48/16, Kp/Ki8/0.03, dlev mu0.3/0.6, FFE mu0.02/0.01, training1000, freeze500 occurrences/100events. It gives21/32 individual locks,14/32 freezes, AllPhaseLock=false. This must not be confused with the earlier36/12 fixture.
- Saved21 candidate rows in `tuning_48_16_search.csv`, screened on8/9 representative starts; finalists were checked on all32 starts. CandidateD03 changes dlev settle mu to0.1 and FFE mu to0.0018/0.0002 while keeping all physical assumptions, anchors, phase gains, training length and freeze/final acceptance gates unchanged. Final no-argument run takes159.318s and matches the parameterized finalist in seven checked arrays.
- PRBS22/16000 no-arg:32/32locks,32/32freezes, AllPhaseLock=true, common21/modes20..22/spread2, tail events141..174,0violations. dlev consistency passes; mean inner/outer12.0440/36.2132. FFE coefficient spread0.013181 passes0.02 and pre1/post1+0.003673/-0.010433 pass +/-0.02. Freeze range4867..6027. Selected start104 first captures3973 and freezes5086; both2048UI eye windows are valid, markers22 and21, with density conservation checked.
- Capture caveat verified from unwrapped data: final UiSlip ranges-73..-66, last changes2331..2569, all before freezing. Multiple acquisition slips are permitted by the current fixture and explicitly reported; this is not a rapid/no-slip acquisition or BER validation.
- PRBS20/8000 independent holdout (same anchors/gains/training/freeze) takes51.80s and passes32/32locks/freezes, common21/modes19..21/spread2, min139events/no violations; FFE spread0.013025 and pre1/post1+0.004559/-0.012932 also pass. Per-start data are in `tuning_48_16_prbs20_holdout.csv`. Main saved MAT/PNG remain the current PRBS22/16000 no-argument result.
- All seven regression suites pass54 groups. The real freeze-integration regression pins its original PRBS20,36/12,500-training,.02/1e-4 fixture rather than inheriting new tunable defaults. Evidence logs/MAT intermediates are session-scoped `tune48_baseline`, `tune48_screen_a/b/c/d`, `tune48_full_c05`, `tune48_full_d03`, `tune48_noarg_final`, and `tune48_prbs20_holdout`. Initial background-launch failure produced no usable result and was excluded; foreground batches provide all reported measurements.

### dlev initial-state versus FFE training-target/crop controls (2026-09-17)

- Fixed initial PI124, currentPRBS22/8000, dlev/FFE gains and freeze thresholds unchanged. Original outer/inner20/(20/3),36/12,48/16 lock at123,13,20 respectively;20/7 locks126. Different actual frozen coefficients and output levels were retained. The missing exact inner20 setting in the user report is explicitly handled by testing both20/3 and7 rather than claiming an exact reproduction of an unspecified pair.
- Common waveform control uses segment UI510000 with2048 identical target UI for each equalizer. Known-symbol5-95% adjacent-level opening peaks at123,13,20,126 respectively; independent data labels handle the represented symbol across the phase wrap without shifting waveform coordinates. Holding each tap vector fixed across the four native crop windows gives zero best circular density shift in all16 comparisons. All crop positions and slips are integer UI and raw channel delay is fixed.
- Diagnostic-only copy fixes supervised FFE targets36/12 while preserving varying dlev initial states. Modes become13 for all four pairs. At36/12 the copy exactly matches production's entire phase and FFE trajectories. A separate production planA fixed-FFE control (no training, zero FFE step) produces mode22 for all20/36/48 initial states, mean phases22.138/22.125/22.122. Controls demonstrate the dual initial-state/training-anchor role is the principal cause of the large observed shift, not output-window truncation.
- Eye7/7, eye-window6/6, modal-lock9/9 and first-capture9/9 regressions pass; assertions verify fixed-tap constancy, control-copy equivalence, modal agreement and all zero crop alignment shifts. Finite2048-symbol diagnostic zero decision errors at selected phases are not BER qualification.
- Evidence is isolated under `results/CDR/dlev_init_phase_diagnostic/`: `anchor_phase_comparison.csv`, `anchor_phase_diagnostic_result.mat`, `same_window_different_ffe_eyes.png`, `anchor_phase_causal_comparison.png`, `cdr_anchor_control.m`, `impl_notes.md`. No production v3/source settings or standard result files were changed. The friend's plot is not a verified equivalent implementation; it declares a4x coarser UI/code spacing and has different unknown phase/reference conventions.

### Independent dlev initialization and supervised FFE reference (2026-09-17)

- Production defaults are initial outer/inner48/16 and separate FFE training outer/inner36/12. New `test_cdr_ffe_training_reference` passes5/5 groups: default state/ref metadata and skipped first-block adaptation; independent initialization override through name/value calls; reference-only training effect; exactly identical DD-only trajectories with different unused references; invalid finite/positive/real/scalar/order validation before cache access. Together with the prior seven suites this gives59 passing groups. The freeze integration test explicitly pins its36/12 FFE refs.
- No-arg PRBS22/8000-block/32-start run completes in113.757s, with32/32 locked and frozen, AllPhaseLock=true, common13/spread3, modes11..14 and138..175 final events without violations. Initial trace values are exactly48/16 for all starts and saved programmed references are exactly36/12. Independent event counting verifies every final lock count. Applied coefficients are constant after freeze.
- At start124, seven phase/error/dlev arrays and the FFE tensor exactly match the previous diagnostic-copy48/16 state with fixed36/12 target. A separate run explicitly setting both state and reference36/12 matches eight arrays from the original coupled36/12 production run. This verifies the split itself without assuming every different initialization must have identical real-valued steady state.
- Selected start36 has first capture3076 and freeze4655; freeze/final markers13/13, each eye2048UI and density524032. Main MAT, convergence/lock/eye plots and CSVs in the v3 result directory were regenerated. FFE consistency and cursor checks do NOT pass: coefficient spread0.020369>0.02, pre1/post1=-0.036527/-0.070715. This task did not retune gains or relax any metric.
- `checkcode` reports only the existing v3 `ISCL` suggestion. Logs are session artifacts `split_ffe_reference_tests.log` and `split_ffe_reference_noarg.log`. No automatic commit or new physical gain model was introduced.

### Optional live-dlev supervised FFE reference experiment (2026-09-17)

- Fixed-reference baseline was committed first as0576cff after8 suites/59 groups passed. Working-copy optional `FfeTrainingReferenceMode='live-dlev'` changes only the supervised FFE amplitudes to same-block pre-update live dlev; golden signs/classes and DD behavior are preserved. Default remainsfixed.
- New five-group live-reference regression verifies fixed/default equivalence, canonical mode parsing, exact pre-update reference traces, irrelevance of programmed constants in live mode, no-training invariance and invalid-mode errors before cache access. All9 suites/64 groups pass after correcting a test-only active-trace field alias. Full32-start default fixed rerun exactly reproduces10 baseline arrays.
- No gain tuning was needed for phase lock: original48/16,PRBS22/8000,1000 training,freeze500/100,Kp8/Ki0.03,dlev0.3/0.1,FFE0.0018/0.0002 gives32/32 locks/freezes,common11,modes9..12/spread3,146..172 final events andzero violations. Saved eye-enabled execution103.985s matches seven trace/result arrays from the initial56.57s no-output live run. Independent final-event counts match all32 starts.
- All training dlev levels are positive/finite/ordered, with inner12.0391..16.7172 andouter30.3047..48; no scale collapse was observed. Final FFE precision is not fully passing: coefficient spread0.0222>0.02 and pre1/post1=-0.05186/-0.06914 exceed +/-0.02. Fixed baseline also fails these separate quality gates; live-mode lock alone is not evidence of superior equalization or general/global stability.
- Selected start44 first capture3007,freeze4702,centers10/11; both2048UI eyes valid. Freeze range4244..6755; start72 has one search reset. Final acquisition slips-62..-58UI, last change1858..2091 before freeze. This test does not establish no-slip acquisition, other dlev initial-state invariance, different-channel performance, or no-freeze convergence.
- Outputs are isolated in `results/CDR/live_dlev_training_experiment/` with per-start fixed/live comparisonCSV and implementation notes. Original default result directory remains fixed-reference data. Session logs: `live_dlev_full_saved`, `live_reference_regression_retry`, `live_fixed_equivalence`. The experimental implementation is not included in0576cff and was not automatically committed.

## CDR validation entrypoint reorganization (2026-09-20)

- MATLAB R2025b: all nine existing numerical suites pass **64 check groups** (eye7, eye-pair6, modal-lock9, historical dither9, freeze-monitor9, first-capture9, fixed-reference5, live-reference5, freeze-integration5). Their fixtures, gains, acceptance thresholds and numerical assertions remain unchanged; only path initialization and relocated-helper resolution changed.
- New `tests/CDR/test_cdr_validation_paths.m` passes: setup roots and field-name set, exact v3/helper/TI-SAR resolution, default exclusion of debug/legacy/archive/results, opt-in scopes, idempotence, invalid scopes, and no duplicate root-level v3/helpers. From `repo/src`, with only the v3 entry directory added, a real64-block run resolves the original PRBS22 cache and original suite result metadata path without writing outputs. An additional64-block `cdr_anchor_control` smoke checks its preserved diagnostic-local result metadata and unchanged working directory.
- Full saved-baseline replay from non-root `repo/src`, using saved `RunOptions` with only `SaveOutputs=false` and eye construction enabled: fixed32-start/8000-block run takes55.108s and exactly matches37 result fields; live-dlev32-start/8000-block run takes347.361s and exactly matches40 fields including actual reference traces. Both additionally match cache and output paths. Compared fields include phase/slip/error/dlev/FFE trajectories, raw/proposed/applied updates, write/freeze traces, freeze/capture events, final-lock flags/counts, cursor response, histograms, and complete freeze/final eye structures and metadata. All comparisons use `isequaln`, not a relaxed tolerance.
- Both retain32/32 locks and32/32 freezes. Fixed common phase13/selected start36 and live common11/selected start44 are unchanged; each reconstructed eye uses2048UI. Existing failed FFE consistency/cursor flags are reproduced exactly, not reclassified as passes. This is refactor-equivalence evidence, not new BER/noise/corner coverage.
- Review caught a dropped `testDir` initializer in the external fixed-anchor diagnostic; it was restored and the real short diagnostic run added to the path regression. An initial field-order-sensitive test assertion was corrected to field-name-set comparison. The first batch-log launch was unusable because the shell passed an unexpanded log path; the successful run uses an absolute MATLAB diary path. No loop algorithm was changed to resolve these issues.
- Evidence: `$PICODE_ARTIFACT_DIR/reorganization_regression.log`, `reorganization_regression_final.log` (includes the repaired diagnostic smoke), and `reorganization_equivalence.log`. SHA-256 aggregate checks before/after validation match for all37 suite result files,14 live experiment files, and the single `newtests` file. The suite README documents current invocation. Standard results and live experiment artifacts are not regenerated; task-entry result modifications and four already-deleted diagnostic PNGs are preserved, not restored. The unrelated `newtests` scratch copy remains unmodified and outside the official path. Physical source modules and modeling assumptions are unchanged.

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

### Generated Channel+CTLE+TI ADC+fixed CDR FFE MMPD lock range

`validation/AFE/test_channel_ctle_ti_adc_cdr_ffe_mmpd_lock.m` generates deterministic PRBS20 PAM4, runs the default S-parameter channel and CTLE, scales the settled waveform to `0.27 V`, converts it with the 7-bit TI ADC, and filters chronological ADC samples with the fixed six-tap CDR FFE. It then explicitly closes `mmpdFast -> cdr_voter -> cdr_loop -> cdr_pi` without changing `cdr_top.m`.

MATLAB R2025b batch execution and static analysis passed. The run used 64 UI/block, 80 blocks, all 128 integer initial phases, fixed FFE taps `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]`, and one frozen loop setting selected only from `-3/+3` sample starts:

- Maximum-power reference phase: 34 samples; selected 13-sample-smoothed negative-slope MMPD lock: 25.53125 samples.
- Fixed loop: `Kp=0.256`, `Ki=0.002`, polarity `+1`, group weights `[2,1,2,1]`.
- Continuous passing initial-offset interval: `[-3,+16]` samples, width 19 samples or 0.1484 UI.
- Pass limits: final-20-block absolute mean error at most 3 samples, span at most 8 samples, drift at most 0.25 sample/block, and valid-transition density at least 5%.
- Outputs: `results/AFE/channel_ctle_adc_ffe_mmpd_lock/ctle_eye.png`, `mmpd_convergence.png`, `mmpd_lock_range.png`, and `result.mat`.
- A post-FFE voltage-opening scan over all 128 phases selected phase 74. Its ordered centers are approximately `[-0.174857,-0.059284,+0.051317,+0.168335] V`, midpoint thresholds are `[-0.117070,-0.003983,+0.109826] V`, and the limiting adjacent-center spacing is `0.110601 V`. The common-bin, four-cluster histogram is `results/AFE/channel_ctle_adc_ffe_mmpd_lock/cdr_ffe_voltage_histogram.png`; the phase scan, centers, thresholds, and figure path are retained in `result.mat`.

### Fixed-dlev SS-MMPD phase loop + adaptive CDR-FFE SS-LMS

`validation/CDR/test_cdr_cdrffe/cdr_dlev_sslms.m` closes a dual-adaptive loop over the cached PRBS20 Channel+CTLE segment: the dlev decision levels are held fixed (low/inner=12, high/outer=36 code, threshold 24), the phase loop uses the uniform weight-1 SS-MMPD kernel, and the six-tap CDR FFE adapts with sign-sign LMS (`cdr_ffe_loop.updateSsLms`, main tap fixed) from a cold start `[0 0 1 0 0 0]`. The first `FfeTrainingBlocks=500` blocks are data-aided (TX golden from `tx_prbs20.mat`, aligned by `channelMainCursorUi=105`), then the loop switches to decision-directed blind convergence and the FFE step drops from 0.02 to 0.001.

MATLAB R2025b batch execution passed (no-argument default, 32 start phases `0:4:127`, `AnalysisNumUi=512512` ≈ 8000 blocks, ~90 s):

- All 32 start phases locked (`AllPhaseLock=1`) to common phase code 17 with **0-code spread**; each phase's steady-state phase-code std was within the 1.5-code tolerance. Blind (decision-directed) convergence begins at block 500 for every phase.
- The FFE SS-LMS coefficients converged consistently across phases: max adaptive-tap spread 0.00225 (< 0.01 tolerance). The free taps settled to the true decision-directed MMSE solution (mean pre1 ≈ −0.35, post1 ≈ +0.13), larger than the offline `0.05`-cursor design; SS-MMPD stayed locked throughout, confirming its S-curve does not depend on residual pre1/post1 ISI amplitude.
- Fixed dlev 12/36 matched the offline four-level cluster truth (inner ≈ 12.2, outer ≈ 36.7); the golden `{±3,±1}` map to `{±36,±12}` during training.
- `checkcode` reported only the pre-existing `numel(varargin)==1` style suggestion, matching the sibling scripts.
- Outputs: `cdr_phase_convergence.png`, `cdr_block_timing_error.png`, `cdr_locked_phase_vs_start_phase.png`, `ffe_coeff_convergence.png`, and `cdr_dlev_sslms_result.mat` under `validation/CDR/test_cdr_cdrffe/result/cdr_dlev_sslms/`.
- This validates deterministic all-start acquisition and joint phase/FFE convergence on a static zero-ppm fixture only; it does not measure BER, jitter tolerance, or noise/PVT robustness.

### MMPD-v1 complete CTLE cache and fixed-segment S-curve

- `test_channel_ctle_cosim.m` generated and verified `validation/AFE/test_mmpd_v1/result/channel_ctle_cosim/channel_ctle.mat` in MATLAB R2025b.
- The cache contains one complete `2^20-1`-bit PRBS20 period mapped to 524288 PAM4 symbols and exactly 67,108,864 finite `single` CTLE samples. The MAT container size is approximately 238.4 MiB.
- A separate 2048-symbol batch Channel+CTLE run matched the beginning of the streamed single-precision cache with maximum absolute error `1.19208e-7`.
- `mmpd_s_curve_own_data.m` passed all 128 phases using the same cached 16384-UI range `[512,16896)`; the result explicitly stores `AllPhasesUseSameSegment=true` and the shared sample bounds.
- Each phase processed 256 blocks of 64 UI through the existing 7-bit `ti_adc_top` with `[-4,+4] V` input limits and the optimized 10-tap `cdr_ffe`. Phase-19 output calibrated one fixed linear map from equalized codes to PAM4 amplitudes `[-3,-1,+1,+3]`.
- Constrained optimization selected CDR coefficients `[-0.0213482,0.0673217,-0.212667,1,0.241926,0.0715624,0.102744,0.0373395,0.0156593,0.0131292]`.
- The normalized quantized total unit-UI response over `[-3,+9] UI` was approximately `[-1.53e-6,-8.21e-6,0.1,1,0.1,-1.09e-4,-2.07e-4,-6.19e-4,-6.41e-4,-1.04e-3,-5.94e-3,-2.16e-3,-9.84e-4]`.
- The explicit `pre1/main/post1` checks passed at `0.1/1/0.1`; the remaining cursor RMS was `0.002069` and maximum magnitude was approximately `0.005938`.
- The offline detector now uses the unfiltered live classic equation `d[n-1]e[n]-d[n]e[n-1]`, with signed full-amplitude residuals rather than `cdr_pd.mmpdFast` binary-error decisions. Its nearest-zero integer phase is 116.
- Linear interpolation found six raw crossings near phases `22.71`, `56.73`, `65.53`, `85.23`, `106.37`, and `116.02`; this diagnostic therefore does not assert a unique stable lock point.
- The three-curve comparison is reordered onto a phase-19-centered `[-0.5,+0.5) UI` axis, with one-symbol fixed-decision alignment across the raw ADC phase wrap. The fixed-decision, unfiltered-live, and symmetric-transition-live center-region crossings are `+0.02562`, `+0.02897`, and `+0.02633 UI`, respectively. The symmetric filter retains only `-3<->+3` and `-1<->+1` transitions; its per-phase retained transition count ranges from 2724 through 3863.
- Backend outputs are `mmpd_s_curve.png`, `mmpd_reference_and_symmetric_s_curve.png`, `ctle_output_first_1024_ui_eye.png`, `cdr_ffe_output_unit_ui_response.png`, `cdr_ffe_output_histogram.png`, and `mmpd_s_curve_result.mat` under `validation/AFE/test_mmpd_v1/result/mmpd_s_curve_own_data`.
- The `mmpd_s_curve_own_data_0.05.m` comparison reused phase 19, the same cached UI range `[512,8704)`, and the same ADC/MMPD flow while changing only the constrained normalized CDR-FFE targets to `pre1=post1=0.05` with main one.
- MATLAB R2025b execution passed all 128 phases. The optimized coefficients are approximately `[-0.0463002,0.120119,-0.323510,1,0.211501,0.0631387,0.116410,0.0422674,0.0181705,0.0175457]`; the remaining normalized cursor RMS is `0.002959`, the maximum residual is `0.008366`, and the nearest-zero integer phase is 61.
- The comparison outputs are stored separately under `validation/AFE/test_mmpd_v1/result/mmpd_s_curve_own_data_0.05`.

### Three-loop CDR with +/-100 ppm receiver frequency offset (2026-09-25)

`validation/CDR/test_cdr_three_loop_wi_ppm/src/cdr_three_loop_ppm/cdr_three_loop_ppm.m`
runs the SS-MMPD timing loop, the dLev SS-LMS level loop and the CDR-FFE SS-LMS
coefficient loop concurrently from a planB cold start (`[0 0 1 0 0 0]`) while the
receiver sampling clock carries a frequency offset. MATLAB R2025b, 32 start
phases (`0:4:127`), `NumBlock = 8000`, runner defaults:

| Offset | Locked | AllPhaseLock | Locked-phase spread | `freqStateMean` | Theory |
| --- | --- | --- | --- | --- | --- |
| `-100 ppm` | 32/32 | 1 | 3 code | `+0.8193..+0.8194` | `+0.8192` |
| `+100 ppm` | 32/32 | 1 | 2 code | `-0.8192..-0.8191` | `-0.8192` |
| `0 ppm` | 32/32 | 1 | 3 code | not applicable | 0 |

At `0 ppm` the frequency-state and rotation-period criteria are not applicable
(`rotationApplicable = false`, `FreqLockDiagnostics.MeanValue = NaN`); the lock
decision there comes from the phase-band dwell criterion alone. This is expected
and is not a failed criterion.

The earlier `-100 ppm` result in the same suite was 0/32 with every start phase
driven to the `-4` frequency clamp. That was traced to the stage-1 mu-downshift
detector, not to loop parameters, and the causal chain was verified by disabling
the downshift (0/8 -> 8/8) and by isolating which loop mattered (FFE capture step
only: 8/8; dLev capture step only: 0/8). Details and the full parameter-sweep
history are in
`validation/CDR/test_cdr_three_loop_wi_ppm/result/cdr_three_loop_ppm_m100/impl_notes.txt`
(2026-09-25 section).

Negative results recorded so they are not retried:

- No `(DlevSettleWindow, DlevSettleTol)` pair satisfies all three offsets.
  `128/0.1` and `200/0.05` give `+/-100 ppm` 32/32 but push the `0 ppm`
  locked-phase spread to 13-15 code against a `captureBandHalfWidth = 6` limit.
- A fixed-block stage-1 trigger at block 2001 passes all three offsets over 8
  start phases but drops `-100 ppm` to 31/32 over 32 start phases.
- MMPD transition filtering cannot substitute for opening the eye. Outer-only
  qualification (`transitionFilter = 2`) reduces the open-loop PD bias in the
  critical window from `-0.01586` to `-0.00023` (69x) but halves the PD event
  count, and the closed-loop result is worse (`-50 ppm`: 4/8 with the symmetric
  filter, 0/8 with outer-only). Filtering trades bias against loop gain; it
  cannot create eye opening.
- `FreqAcqPonly` (proportional-only acquisition) does not help while the stage-1
  gate is the legacy one, because the gate releases the integral path at block 84
  anyway.

This validates all-start-phase acquisition and tracking at the IEEE Ethernet
`+/-100 ppm` limit on a static cached Channel+CTLE fixture. It does not measure
BER, jitter tolerance, or combined noise/PVT robustness.

### CDR: switchable stage-2 frequency-state gate (2026-09-26)

The original stage-2 criterion was the code-domain center-touch modal test on
raw unwrapped PI code (`FfeGateMinModeOccurrences = 500`,
`FfeGateMinEvents = 100`, `FfeGateBandHalfWidth = 3`). It was enabled but unable
to trigger under a frequency offset: the PI code ramps continuously rather than
dwelling on one code, so stage 2 fired for **0/32** starts at both -100 and
+100 ppm despite `FfeGateEnable = true` and `FfeGateMode = 'pvt-track'`.

The replacement is criterion-selectable. The ppm runner's default
`FfeGateCriterion = 'auto'` resolves to `'center-touch'` at exactly 0 ppm and
`'freq-state'` otherwise. The online frequency-state gate receives the same
`LockWindowBlocks`, expected frequency state, and
`FreqMeanHalfDiffTol`/`FreqStdTol`/`FreqRateTol` used by the offline frequency
verdict. `loop_monitor.updateFreqStateGate` calls the same static
`detectFrequencyStateLock` on its ordered trailing ring, so online and offline
results are identical by construction on the same window.

The pass/fail verdict is still independent of stage 2. For nonzero-ppm runs,
`Locked` requires **both** `detectFrequencyStateLock` and
`detectRotationPeriodLock`; `LockBlock` is the first verdict-satisfied block,
whereas `Stage2GateBlock` is the actual second downshift. The CDR still has
three step-size tiers and two events (`capture -> settle -> pvt-track`): dLev
`0.5 -> 0.1 -> 0.02`, FFE `0.001 -> 2e-4 -> 2e-4` in the ppm suite, meaning the
second event changes only dLev at those defaults. Stage 1 remains the unchanged
SNR-EWMA settle gate.

Measured A/B used start phases `0/32/64/96` with `SaveOutputs = false`; nothing
was written to result directories:

| ppm | criterion | locked | stage 2 fired | stage-2 blocks | mean `FreqStateMean` |
|---:|---|---:|---:|---:|---:|
| -100 | `center-touch` | 4/4 | 0/4 | none | 0.819187 |
| -100 | `freq-state` | 4/4 | 4/4 | 4977..6070 | 0.819207 |
| +100 | `center-touch` | 4/4 | 0/4 | none | -0.819229 |
| +100 | `freq-state` | 4/4 | 4/4 | 2570..2762 | -0.819238 |

Expected frequency-state magnitude is 0.8192 code/block. The gate now fires,
lock remains 4/4 in every A/B arm, and tracking accuracy changes by only about
`1e-5 code/block`. The timing is asymmetric: -100 ppm fires substantially later
(4977..6070) than +100 ppm (2570..2762).

The zero-ppm regression used the new default: `auto` resolved to
`center-touch`, 2/2 starts locked, and start phase 0 fired at block **3937**,
exactly matching the minimum in the existing p0 artefact. This confirms that the
zero-ppm gate path is unchanged.

Automated results:

- `tests/CDR/test_freq_state_gate.m`: **12/12**, including exact online/offline
  trigger agreement at blocks **161 / 40 / 40 / 59** and agreement on
  never-locking input.
- `test_loop_monitor`: **15/15**.
- `test_cdr_top`: **6/6**.
- `test_cdr_top_configured`: **12/12**.
- Full `tests/CDR`: **16 passed / 2 failed**. The two failures are
  `test_cdr_ffe` expecting `cdr_ffe:MainTapUpdate` and `test_cdr_ffe_loop`
  expecting `cdr_ffe_loop:MainTapAdaptEnabled`. Both fail identically on a clean
  HEAD worktree, so they are pre-existing known failures; they were not fixed by
  this work.

`ppm_lock_summary.csv` was removed. The runner no longer calls `writetable` for
it and no longer returns `result.LockSummaryPath`; the three saved copies were
deleted. `ppm_lock_summary.txt`, written by
`helpers/write_ppm_lock_summary_txt.m`, is the sole lock summary and is a strict
superset of the old CSV columns. Current result MATs supply the authoritative
`result.Stage2GateBlock`; the writer replays center-touch only for older MATs
without that field. `ppm_stage_eye_summary.csv` is a different output from
`make_ppm_stage_eyes.m` and remains in use.

### CDR: center-touch retired from the ppm suite (2026-09-28)

The switchable `FfeGateCriterion` (2026-09-26) was removed from the ppm runner.
The stage-2 downshift is now the frequency-state gate at every offset, and the
0 ppm pass/fail verdict moved from `detect_pi_center_touch_lock` to
`loop_monitor.detectFrequencyStateLock` (expected rate 0, slew-guarded). The
retirement was justified by a no-source-change experiment (32 phases,
`FfeGateCriterion='freq-state'`, `SaveOutputs=false`): the freq-state verdict
matched the center-touch verdict **32/32** at 0 ppm, and the freq-state stage-2
gate fired **32/32** where center-touch fired only **29/32**. Tail freq-state
`|mean| <= 8.9e-5`, `std ~2.5e-3`, far inside `FreqMeanHalfDiffTol`/`FreqStdTol`.

Full regeneration (`StartPhaseStep = 4` -> 32 phases, `NumBlock = 15000`,
`PiNonideal = 'ab_constant'`, freq-state gate). All three directories rewritten
and their three-eye sets rebuilt offline:

| ppm | `LockMode` | locked | all-phase | common / spread | stage-2 fired / blocks | `FreqStateMean` (exp) | eyes |
|---:|---|---:|---:|---|---|---|---|
| -100 | `freq+rotation` | 32/32 | 1 | 107 / 3 | 32/32, 4966..6458 | 0.819166..0.819308 (0.8192) | 1/1/1 |
| 0 | `freq-state` | 32/32 | 1 | 113 / 3 | 32/32, 2000..2782 | -8.86e-5..8.85e-5 (0) | 1/1/1 |
| +100 | `freq+rotation` | 32/32 | 1 | 121 / 3 | 32/32, 2445..2798 | -0.819406..-0.819146 (-0.8192) | 1/1/1 |

Versus 2026-09-26 the only material deltas are at 0 ppm: `LockMode`
`center-touch -> freq-state`, stage-2 fired `29/32 -> 32/32`, locked-phase spread
`2 -> 3`. -100/+100 ppm are unchanged.

Automated results:

- `checkcode` clean on `cdr_three_loop_ppm.m`.
- `test_detect_pi_center_touch_lock`: **9/9** (helper retained for v3/v4).
- `test_freq_state_gate`: all-pass; `test_loop_monitor`: **15/15**;
  `test_cdr_top_configured`: **10/10**.
- Full `tests/CDR`: **15 passed / 2 failed**. The two failures are the
  pre-existing `test_cdr_ffe` (`cdr_ffe:MainTapUpdate`) and `test_cdr_ffe_loop`
  (`cdr_ffe_loop:MainTapAdaptEnabled`), identical on a clean HEAD worktree; not
  touched by this work.

Removed file: `validation/CDR/test_cdr_three_loop_wi_ppm/ab_stage2_gate.m` (the
center-touch-vs-freq-state A/B harness), obsolete once the runner has no
selectable criterion.

### CDR: offline ppm three-eye set and historical stage-2 diagnosis (2026-09-26)

`tests/CDR/test_build_ppm_eye_set.m` passed **9/9** checks using synthetic
fixtures. Coverage includes drift-aware anchored and final windows checked
against direct `build_cdr_ffe_eye` calls, zero-drift reduction, the exact
address-trace consistency guard, marker wrap safety, NaN-anchor and truncation
handling, invalid-input rejection, metadata completeness, variable anchor
counts, and anchor labels. These tests do not replace the real-run measurements
below.

The builder reconstructs each block address as

```text
absSample0(k) = (BaseUi + (k-1)*AdcBlockUi + UiSlipTrace(k))*SamplesPerUi
                + PhaseCodeTrace(k) + DriftSampleTrace(k)
```

and requires exact agreement between `mod(absSample0, SamplesPerUi)` and
`mod(EyePhaseUnwrappedTrace, SamplesPerUi)`. A mismatch raises
`build_ppm_eye_set:InconsistentAddressTrace`; the real `-100 ppm` result had
maximum mismatch zero. `build_ppm_eye_set` accepts N anchors plus a final tail
window, gives every anchor its own block's coefficient snapshot, and gives the
final row the final-block snapshot. These are offline fixed-coefficient views,
not a replay of time-varying taps. The marker is computed from unwrapped tracked
physical eye phase before modulo wrapping, and adjacent columns of the 2-UI
density overlap.

The driver constructs three 2048-UI rows: stage-1 SNR settle, first satisfied
pass/fail lock criterion, and final tail. It replays `SnrDbTrace` exactly as
`loop_monitor.updateSnrSettle` (`alpha = 1/128`, threshold 15 dB, minimum block
200), then tests each trailing `LockWindowBlocks` slice with the verdict's own
detectors and tolerances: `detectFrequencyStateLock`, plus
`detectRotationPeriodLock` when applicable, at nonzero ppm, and
`detect_pi_center_touch_lock` at zero ppm. Because the lock
criterion uses `LockWindowBlocks = 2000`, row 2 cannot precede block 2000 and
means the first block whose trailing 2000-block window satisfies the criterion,
not the instant the loop locked. `CaptureBlock` is context only.

The sliding search passes `seq(k-w+1:k)`, not the whole prefix `seq(1:k)`, to
`detectFrequencyStateLock`, `detectRotationPeriodLock`, and
`detect_pi_center_touch_lock`. This is mathematically identical because each
detector evaluates only its trailing `windowBlocks` samples, but avoids repeated
O(k) validation of growing prefixes and keeps the 32-phase sweep linear. It
reproduced the prefix-based lock blocks 6128 / 2732 / 2593 for the three default
start phases. A complete 32-phase replay takes 22-38 s per result directory.

Measured on the saved 8000-block, 32-start-phase, PRBS22 default runs, selecting
the slowest-capture row:

| ppm | phase index / start | `CaptureBlock` (context) | SNR settle | lock | frequency-only lock | stage-2 fire |
|---:|---:|---:|---:|---:|---:|---:|
| -100 | 4 / 12 | 3787 | 3864 | 6128 | 6128 | `NaN` |
| 0 | 10 / 36 | 768 | 961 | 2732 | `NaN` (centre-touch mode) | `NaN` |
| +100 | 23 / 88 | 511 | 526 | 2593 | 2593 | `NaN` |

| ppm | marker: settle / lock / final | span: settle / lock / final | start UI: settle / lock / final | settle-to-final delta | lock-to-final delta |
|---:|---:|---:|---:|---:|---:|
| -100 | 100.625 / 104.34375 / 104.4375 | 1 / 3 / 2 | 247511 / 392407 / 510231 | 3.8125 | 0.09375 |
| 0 | 113 / 113.78125 / 114.15625 | 0 / 1 / 2 | 61695 / 175039 / 510207 | 1.15625 | 0.375 |
| +100 | 118.96875 / 119.125 / 119.71875 | 2 / 2 / 2 | 33908 / 166196 / 510260 | 0.75 | 0.59375 |

In all three cases the residual cursor walk from the lock block to the end of the
run (`0.09 / 0.375 / 0.59` code) is much smaller than from the stage-1 settle
block to the end (`3.81 / 1.16 / 0.75` code), so by the time the lock criterion
is satisfied the taps have essentially stopped moving. No inference about
adaptation duration, step size, mechanism, or monotonicity across cases is made.

The eye rebuild exposed the original second-stage defect. Those saved MATs and
figures were produced with the center-touch gate: replaying their
`UnwrappedPhaseTrace` rows gave **0/32** fires at -100 ppm, **0/32** at +100 ppm,
and **28/32** at zero ppm (fire blocks 3937..7653). Maximum
`ModeOccurrences` was 75 and 46 at the two offsets against a threshold of 500,
with `EventCount = 0`. The current `auto` policy fixes the live nonzero-ppm path,
but these artefacts were **not regenerated**, so their offset `Stage2Block`
values remain `n/a`. Row 2 still means **after the lock criterion is satisfied**,
not after the second downshift.

Outputs are `cdr_ffe_eye_at_snr_settle_2048ui.fig`,
`cdr_ffe_eye_at_lock_2048ui.fig`, `cdr_ffe_eye_final_2048ui.fig`,
`cdr_ffe_eye_stage_comparison.fig`, `ppm_stage_eye_summary.csv`, and
`ppm_lock_summary.txt`. `ppm_lock_summary.txt` is the sole lock summary; it is
plain ASCII, includes all 32 start phases, and is a strict superset of the
removed CSV's columns. Its main table contains `StartPhase`, `Locked`,
`FreqStateMean`, `RotationPeriod`, `LockPhase`, `Stage1Block`, `Stage1Phase`,
`LockBlock`, `LockPhaseAtBlk`, and `Stage2Block`; a supplementary table keeps
`FreqLock`, `RotationLock`, `SlewSaturated`, `AcquisitionBlock`, `RotationCov`,
`DeltaCodeMeanAbs`, and `PendingCodeMeanAbs`. `LockBlock` and `Stage2Block` are
distinct milestones. The separate `ppm_stage_eye_summary.csv` remains part of
the eye workflow.

### CDR: nonideal PI phase table, 32-start regeneration, and positive-offset headroom (2026-09-26)

**Claim under test.** Does `+/-100 ppm` all-start-phase acquisition survive a
physically nonideal phase interpolator, and what does the nonideality cost?

**Method.** The ppm runner now samples the cached waveform at
`round(top.PhaseInterpolator.getLocalIndex())`, i.e. through the PI phase
table, instead of at the raw `CodeWrapped`, and exposes `PiNonideal`
(`'ideal'` | `'ab_constant'`, default `'ab_constant'`). Under `'ideal'` the
table is the identity, so the address expression is bit-exact with the previous
harness and the two modes are directly comparable. The phase-table INL is a
derived, not assumed, quantity: at `PiNumBit = 7` and 128 samples/UI it is
`+/-1.445352 LSB` (2.890703 LSB pk-pk, 1.037876 LSB RMS), and integer cache
addressing reduces it to `round(localIndex) - code` in `{-1, 0, +1}` over
52/24/52 codes, i.e. 104 of 128 codes displaced by exactly one waveform sample
(`1/128 UI`).

**Evidence 1 - controlled A/B, PI table as the only variable.** 32 start phases
`0:4:127`, `NumBlock = 15000`, `SaveOutputs = false`, all other options default:

| ppm | `PiNonideal` | locked | all-phase | common phase | spread | `FreqStateMean` | stage 1 | stage 2 | `mean|PendingCode|` |
|---:|---|---:|---:|---:|---:|---|---|---|---|
| -100 | `ideal` | 32/32 | 1 | 106 | 3 | 0.819123..0.819264 | 2693..4076 | 4942..6382 | 0.0855..0.1325 |
| -100 | `ab_constant` | 32/32 | 1 | 107 | 3 | 0.819166..0.819308 | 2716..4216 | 4966..6458 | 0.1805..0.2720 |
| +100 | `ideal` | 32/32 | 1 | 120 | 2 | -0.819355..-0.819152 | 338..581 | 2553..2815 | 0.1220..0.1985 |
| +100 | `ab_constant` | 32/32 | 1 | 121 | 3 | -0.819406..-0.819146 | 336..563 | 2445..2798 | 0.3320..0.4625 |

Expected `|FreqStateMean|` is `0.8192 code/block` and is met to better than
`2.6e-4` in every arm. Stage 2 fired 32/32 in all four arms.
`SlewSaturatedFlag` is 0 for all 128 runs. The nonideal table moves the
locked-phase centroid by one code and the spread by at most one code, which is
the expected result of a `+/-1` sample address quantization; it does not cost
all-phase lock.

**Evidence 2 - regenerated artefacts at 32 start phases.** `StartPhaseStep = 4`,
runner default `NumBlock = 15000`, `PiNonideal = 'ab_constant'`,
`FfeGateCriterion = 'auto'`, `SaveOutputs = true`. The three result
directories were rewritten by the runner and their three-eye sets rebuilt
offline from the new MATs:

| ppm | gate | locked | all-phase | common phase / spread | stage 1 | lock | stage 2 fired |
|---:|---|---:|---:|---|---|---|---|
| -100 | `freq-state` | 32/32 | 1 | 107 / 3 | 2716..4216 | 4966..6458 | 32/32, 4966..6458 |
| 0 | `center-touch` | 32/32 | 1 | 113 / 2 | 501..1028 | 2000..2519 | 29/32, 3512..8048 |
| +100 | `freq-state` | 32/32 | 1 | 121 / 3 | 336..563 | 2445..2798 | 32/32, 2445..2798 |

Rotation period is `156.091..156.182 block/UI` at -100 ppm and
`156.167..156.250` at +100 ppm against the expected `156.25`, with rotation CoV
`0.0029..0.0088`. Zero ppm keeps center-touch under the `auto` policy and
**3 of 32** start phases never latch that gate, so they run to the end at the
settle step size; this is the known code-domain limitation of that gate and is
reported as `n/a` rather than hidden. Re-running the identical command
reproduced the same aggregates, so the sweep is deterministic.

**Evidence 3 - positive-offset headroom is materially reduced.** An 8-start
probe (`StartPhaseStep = 16`, `SaveOutputs = false`) at the previously
unexplored boundary:

| ppm | `PiNonideal` | locked | all-phase | `SlewUtilization` | starts flagged saturated | `mean|PendingCode|` |
|---:|---|---:|---:|---:|---:|---|
| +100 | `ideal` | 8/8 | 1 | 0.8192 | 0 | 0.1220..0.1985 |
| +100 | `ab_constant` | 8/8 | 1 | 0.8192 | 0 | 0.3560..0.4060 |
| +110 | `ideal` | 8/8 | 1 | 0.9011 | 0 | 0.3380..0.4530 |
| +110 | `ab_constant` | **0/8** | **0** | 0.9011 | **8/8** | 0.7715..1.0240 |

Two conclusions, both measured rather than inferred. First, `+100 ppm` with the
nonideal PI produces about the same pending-code backlog as `+110 ppm` with the
ideal PI, so the nonideal table consumes on the order of 10 ppm of positive
headroom as measured by this precursor. Second, the positive all-phase ceiling
is PI-dependent: a `+110 ppm` capability holds only for an ideal PI. With the
nonideal default every start phase trips the `SlewSatPendingTol = 0.5` guard
and lock is correctly refused. Note that `mean|DeltaCode|` is
`0.9005..0.9015` in **both** `+110 ppm` arms, so the failure is not the
`MaxDeltaCode = 1` ceiling being hit on average; it is slew backlog, which is
exactly what the pending-code guard exists to detect. The `+/-100 ppm`
requirement is met with the nonideal PI, but the positive-direction margin
above it is now under 10 ppm.

**Limits.** All of the above is on a static cached Channel+CTLE fixture with
PRBS22; no BER, jitter tolerance, or noise/PVT robustness is measured. Integer
cache addressing quantizes INL to `+/-0.5 LSB`, so this harness cannot
represent INL finer than roughly 0.7 LSB pk-pk and represents the 2.891 LSB
pk-pk table as a three-level staircase. The `+110 ppm` rows are an 8-start
probe, not a 32-start all-phase result, and are reported as a margin
measurement only. The negative-direction boundary was not re-probed under the
nonideal PI.

### CDR: trackable frequency-offset range of the ppm suite (2026-09-26)

**Claim under test.** What is the largest frequency offset the suite can track
in the current configuration, i.e. all runner defaults including
`PiNonideal = 'ab_constant'` and `NumBlock = 15000`?

**Method.** `validation/CDR/test_cdr_three_loop_wi_ppm/ppm_tracking_range.m`.
An 8-start ladder brackets the boundary, integer bisection closes it, and the
surviving candidates are re-confirmed at the full 32 starts. Only PASS
candidates need the 32-start re-check: `0:16:112` is a strict subset of
`0:4:127` and each start phase is an independent deterministic run, so a FAIL
at 8 starts implies a FAIL at 32. Every run uses `SaveOutputs = false`. Pass
requires all three of: every start locked, `AllPhaseLock = 1`, and no start
flagged slew-saturated.

**Result A - the suite's own criterion.** 32-start confirmation:

| ppm | locked | all-phase | saturated | `max mean|PendingCode|` | max freq-state error | common phase |
|---:|---:|---:|---:|---:|---:|---:|
| +102 | 32/32 | 1 | 0 | 0.4130 | 1.81e-4 | 121 |
| -105 | 32/32 | 1 | 0 | 0.4340 | 2.02e-4 | 106 |

First failures are `+103` (2/8 locked, 6 saturated) and `-106` (7/8, 1
saturated). **The trackable range is therefore `-105 .. +102 ppm`**, leaving
2 ppm of positive and 5 ppm of negative margin against the `+/-100 ppm`
Ethernet requirement.

**Result B - that boundary is set by the guard, not by tracking loss.** This is
the important qualification. `runner:482-490` computes
`lockedFlag = freqLock && rotationLock && ~slewSaturated`, so the
slew-saturation guard is a **veto inside the lock verdict**; a falling locked
count and a rising saturated count are not independent evidence. Relaxing the
guard as far as the validators allow (`SlewSatPendingTol = 1e9`,
`SlewSatDeltaFrac = 1`; `Inf` is rejected as non-finite) and leaving everything
else at default:

| ppm | freq lock | rotation lock | all-phase | `max mean|PendingCode|` | `max mean|DeltaCode|` | max freq-state error |
|---:|---:|---:|---:|---:|---:|---:|
| +103 | 8/8 | 8/8 | 1 | 0.6070 | 0.8445 | 2.03e-4 |
| +110 | 8/8 | 8/8 | 1 | 1.0240 | 0.9015 | 2.39e-4 |
| +115 | 8/8 | 8/8 | 1 | 1.7195 | 0.9435 | 2.78e-4 |
| +120 | 7/8 | 8/8 | 0 | 12.7570 | 0.9840 | 1.53e-2 |
| -110 | 8/8 | 8/8 | 1 | 0.7270 | 0.9020 | 3.04e-4 |
| -115 | 8/8 | 8/8 | 1 | 1.3405 | 0.9430 | 3.89e-4 |
| -120 | 8/8 | 8/8 | 1 | 6.7635 | 0.9840 | 5.44e-3 |

Both criteria still hold at `+115` and `-120` with frequency-state error under
`4e-4`. Tracking itself only breaks near `+/-120 ppm`. The reason a relaxed
guard still tracks is that a **bounded** backlog forces the applied average
rate to equal the demanded rate in steady state, otherwise the backlog would
grow without bound; `max mean|DeltaCode|` confirms it, equalling the
theoretical demand `ppm/122.07` at every point. The cost is a static phase lag
of roughly `mean|PendingCode|` codes, e.g. `1.02 code = 8 mUI` at `+110`. So
`SlewSatPendingTol = 0.5` (about `3.9 mUI` of lag) is a **design judgement
about acceptable slew lag, not a lock failure point**, and the `-105 .. +102`
figure inherits that judgement.

Backlog growth against utilisation follows the queueing signature: util
`0.8445 / 0.9015 / 0.9435 / 0.9840` gives `maxPend`
`0.607 / 1.024 / 1.720 / 12.757`, tracking `1/(1-util)` (62x at util `0.984`).

**Result C - arithmetic ceiling and the cost of the nonideal PI.** The PI
applies at most `MaxDeltaCode = 1` code once per 64-UI block, and one code is
`1/128 UI`, so the fastest sustainable rate is `1/(128*64) UI per UI`:

```
ppm_max = 1e6 / 8192 = 122.07 ppm        (100 ppm uses 0.8192 code/block = 81.92%)
```

No tuning can exceed this. The ideal-PI contrast under the default guard is
symmetric at `+/-110` pass and `+/-115` fail (8 starts), so the nonideal phase
table costs about 8 ppm positive and 5 ppm negative, and costs it
**asymmetrically**. At equal `|ppm|` the nonideal backlog is larger (`+110`:
`1.024` versus `0.453` ideal), consistent with the `+/-1`-sample INL address
quantisation demanding extra code motion. Why the positive direction is dearer
was not attributed; the two directions lock at different phases (121 versus
106/107), hence different parts of the INL curve.

**Limits.** Static Channel+CTLE cache with PRBS22, no noise, jitter or PVT, so
this is deterministic frequency-offset tracking and not a jitter-tolerance
figure. Only `+102` and `-105` were confirmed at 32 starts; every Result B and
Result C row is an 8-start probe, and an 8-start pass does not imply a 32-start
pass (only the converse holds). Bisection assumes the verdict is monotonic in
`|ppm|`; no tested point violated it, but not every integer ppm was evaluated.
Failure severity is **not** monotonic: `-107` diverged outright
(`maxPend 9259`, freq error `3.72`) while `-106` and `-110` failed cleanly.
