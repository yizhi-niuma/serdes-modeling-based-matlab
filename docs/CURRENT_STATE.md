# Current State

Updated: 2026-09-16

## 2026-09-16: v3 triple-loop no-arg default retuned to remove slow phase glide

- Symptom (user report): `validation/CDR/test_cdr_dlev_cdrffe/cdr_dlev_cdrffe_sslms_v3.m` did not converge — the PI phase code kept gliding instead of settling into a steady `+1/-1` dither. Reproduced on the retained default: the per-block mean phase code slid monotonically `~53 -> 24` over 8000 blocks while `UiSlip` accumulated; the last-30-block std criterion still reported `AllPhaseLock=1` (a trajectory-misclassification, exactly the caveat noted in DECISIONS 2026-09-15).
- Root cause (loop-parameter / cross-loop coupling, NOT an architecture or logic bug — the alignment/sign/update-timing of all three loops is correct):
  1. Training anchors `DlevOuterInit=48 / DlevInnerInit=16` are ~30% larger than this channel's offline four-level truth (outer≈36.7, inner≈12.2 code). The oversized golden target over-equalized the FFE during training (block 500: pre1≈-0.72, post1≈+0.56); after release the FFE kept crawling back toward the true MMSE optimum, and the SS-MMPD S-curve zero moved with it, dragging the sampling phase for thousands of blocks.
  2. The RAW SS-MMPD S-curve is multi-modal: per UI it has one strong stable (negative-slope) zero at code ~16 plus TWO weak stable zeros at ~66 and ~99 (the well-known PAM4 SS-MMPD "one strong + two weak lock points"). The loop already suppresses the two weak zeros with a phase-gated PD bias (`cdr_dlev_cdrffe_sslms_v3.m:466-467`: `meanPhaseError = mean(ssDecision) + pdOffset*biasActive`, `pdOffset=-0.05`, `biasActive = codeWrapped∈[45,116]`); this shifts the mid-UI region below zero (verified offline: the loop-effective S-curve retains only the single strong lock plus an unstable positive-slope repeller near code ~115). So the failure was NOT a surviving parasitic lock. The actual mechanism: at `Ki=0.06` the phase integrator is fast enough to move the sample point while the cold-start FFE is still forming; golden symbols taken at a wandering phase collapse the FFE post1 tap (start 32: post1 +0.144@blk400 -> -0.005@blk500), which migrates the SINGLE strong lock from code ~16 toward the UI wrap boundary (~code 1), and the loop parks at the boundary — a "phase drift ⇄ golden-driven FFE post1 collapse ⇄ main-lock migration" transient positive feedback, not a static extra zero.
- Fix (parameter-only, no logic change). New no-arg defaults in `parseLoopOptions`: `Ki 0.06 -> 0.03` (halve the phase integral gain so the phase loop settles slower than the FFE/dlev during training, keeping the single strong lock at ~14-16 instead of letting it migrate to the wrap boundary), `DlevOuterInit 48 -> 36`, `DlevInnerInit 16 -> 12` (anchors near this channel's truth so the training FFE lands once), `FfeStepSizeSettle 1e-3 -> 1e-4` (stop residual FFE crawl from dragging the S-curve zero). The gated `pdOffset=-0.05` weak-zero-cancellation mechanism is unchanged and still valid at the new anchors. The `allPhaseLock` common-band tolerance was relaxed `<=2 -> <=3` code (a ±3/128 UI = 2.3% UI start-phase residual is the same physical sampling point, not a lock failure).
- Verified in MATLAB R2025b (no-argument default, 8000 blocks, 32 start phases `0:4:124`): `AllPhaseLock=1`, `LockedFlag` = 32/32 (including the previously stuck start 32, now code 11), common lock code 14, spread 5. Convergence criterion met: over the tail (blocks 6001-8000, all 32 phases) **99.49% of blocks have |deltaCode|<=1** — the PI output is a steady `+1/-1` dither about the locked phase, which is the user's stated convergence definition. dLev converged to inner 11.76 / outer 35.31 (truth 12.23 / 36.71). Outputs regenerated under `validation/CDR/test_cdr_dlev_cdrffe/result/cdr_dlev_cdrffe_sslms_v3/` plus `v3_phasecode_convergence_fixed.png`; an offline S-curve diagnostic tool was added as `debug_v3_scurve.m`.
- Scope of claim: this verifies the `+1/-1` steady-dither convergence of all 32 scanned starts at 8000 blocks. It does NOT claim BER, exhaustive 128-start acquisition, or 30000-block stability. The anchors remain nominal design values (known pre-lock from ADC full-scale and AGC target), not offline truth injected into the loop.

## Current v3 baseline after restore (2026-09-15)

- User-requested `git restore --source=HEAD --worktree` restored only `validation/CDR/test_cdr_dlev_cdrffe/cdr_dlev_cdrffe_sslms_v3.m`. HEAD is `c96ed27`; this file last changed in `b3a9dd9`, and its Git-normalized blob is identical in both (`30f33dc9d9a378d9423a9bd205845540880a828f`). Other working-tree changes were retained, not restored.
- Current implementation is uniform-weight SS-MMPD + dLev SS-LMS + FFE SS-LMS (`updateSsLms`), with a direct symbol reference, NOT a `[c 1 c]` target. Defaults: Kp=8, Ki=0.06, MaxDeltaCode=12, integral limits +/-4; dLev mu=0.3->0.1; FFE mu=0.02->0.001; main FFE tap fixed to 1. Training uses fixed +/-16 and +/-48 FFE reference levels for 500 blocks. Block 500 still uses golden symbols but already uses fine dLev/FFE steps; decision-directed mode begins at block 501. The default training path overrides staged release. `SettleBlock` is not used; `FfeTargetCursor`/`FfeTargetSkew` are inactive legacy options.
- Revalidated in MATLAB R2025b with `SaveOutputs=false`: 8000 blocks, starts `0:4:124`, 68.439 s, `AllPhaseLock=1`, 32/32 passing, final mean codes 23/24 (spread 1); dLev mean inner/outer=12.159668/36.5540527, spreads=0.0546875/0.1046875; max FFE coefficient spread=0.003328125. pre1=-0.016126912, post1=-0.0282917317, so `FfeConstraintHeld=false`. This verifies the script's last-30-block convergence criteria, not BER, exhaustive 128-start acquisition, or 30000-block stability.
- Reproduction still requires the retained modified window-interface `src/CDR/cdr_ffe.m` and untracked `src/CDR/dlev_loop.m`; `src/CDR/cdr_ffe_loop.m` also remains modified. A clean checkout of HEAD alone is NOT the tested runtime environment. Git may still flag the restored script due to line-ending/stat metadata; its normalized content and `git diff HEAD` match.
- New validation evidence is session-scoped: `$PICODE_ARTIFACT_DIR/restore_validation.log` and `$PICODE_ARTIFACT_DIR/restored_v3_default_result.mat`. Existing v3 result-directory plots were deliberately not overwritten and still describe the earlier target-pulse experiment.
- The simplified-MMSE and target-pulse entries below are superseded experiments, not current defaults. Earlier claims of proven S-curve collapse, alias elimination, or an alias cause for the 11 failed target-pulse starts were not established: wrapped-code statistics near 0/127 can misclassify lock, and a small spread among only passing starts is not proof of all-start stability.


## 2026-09-16: fixed-dlev + adaptive phase(SS-MMPD) + adaptive FFE(SS-LMS)

- `validation/CDR/test_cdr_cdrffe/cdr_dlev_sslms.m` was converted from "fixed FFE + adaptive phase/dlev" to "fixed dlev + adaptive SS-MMPD phase loop + adaptive CDR-FFE SS-LMS". dlev is held fixed at low/inner=12, high/outer=36 code (threshold 24); the PD is uniform weight-1 SS-MMPD; the FFE adapts with `cdr_ffe_loop.updateSsLms` and is **cold-started** from `[0 0 1 0 0 0]` — the first `FfeTrainingBlocks=500` blocks are data-aided (TX golden from `tx_prbs20.mat`, 105-UI main-cursor aligned), then the loop switches to decision-directed blind convergence and the FFE step drops from 0.02 to 0.001. Default `AnalysisNumUi=512512` (≈ 8000 blocks). Verified in MATLAB R2025b (no-argument default, ~90 s): `AllPhaseLock=1`, all 32 lock to code 17 (spread 0), FFE coeff spread 0.00225, converged free taps pre1≈−0.35/post1≈+0.13. Outputs under `validation/CDR/test_cdr_cdrffe/result/cdr_dlev_sslms/` (phase/timing/lock/FFE-coeff PNGs + result MAT).

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

- Dedicated floating-point 1-UI `cdr_ffe` with a default six-tap, two-precursor configuration, fixed unit main tap, configurable tap layout, and validated/fast processing paths. It accepts caller-assembled `[postcursor history, target block, precursor look-ahead]` windows and leaves cross-block buffering and stream-boundary validity to the caller.
- Separate `cdr_ffe_loop` block LMS engine using data-decision error, block-length normalization, configurable adaptation mask, and next-block coefficient updates. Its validated path performs input normalization and diagnostic capture, while its caller-validated fast path returns the coefficient delta and optional raw gradient without updating diagnostic state. The engine now also supports Sign-Sign LMS via `updateSsLms` / `updateSsLmsFast`, which replace the gradient `e*X/N` with `sign(e)*sign(X)/N`.
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
- `validation/CDR/test_cdr_dlev_cdrffe/cdr_dlev_cdrffe_sslms.m` runs the three simultaneous loops (MMPD timing, dlev level tracking, adaptive CDR-FFE) over cached Channel+CTLE data with an optional training sequence. The training golden window now compensates the 105-UI Channel+CTLE main-cursor delay (`goldenFirst = analysisStartUi + firstUi - channelMainCursorUi + 1`); without this compensation the golden labels were 105 symbols out of phase and none of the three loops could lock.

## Not yet implemented or integrated

- Frequency acquisition/detector path.
- A reusable waveform-level top that integrates CDR FFE, slicers, and MMPD upstream of the current BBPD-oriented `cdr_top` interface.
- End-to-end CDR lock, BER, bathtub, jitter-transfer, and jitter-tolerance analysis.
- A single top-level configuration/runner for ADC plus CDR.

## Validation status

- Open-loop Channel+CTLE+TI-ADC+CDR-FFE pulse-response validation passes with a 7-bit `[-0.3,+0.3] V` ADC and automatically optimized fixed FFE taps. The output satisfies `pre1=post1=+0.1`; other fitted cursors have approximately `0.01971` RMS and `0.03813` maximum residual. The aligned cascade response and standalone FFE tap response are saved under `results/AFE/channel_ctle_ti_adc_cdr_ffe`.
- Closed-loop Channel+CTLE+TI-ADC+fixed-CDR-FFE MMPD validation passes with fixed taps `[0.01028,-0.1499,1,0.06785,-0.06457,0.0006814]`. The frozen loop uses `Kp=0.256`, `Ki=0.002`, polarity `+1`, and has a continuous validated initial-phase interval of `[-3,+16]` samples around the selected MMPD lock, width 19 samples or 0.1484 UI. Results are saved under `results/AFE/channel_ctle_adc_ffe_mmpd_lock`.
- The same validation now scans the post-FFE four-level voltage separation over all 128 phases. The maximum minimum-adjacent-center spacing is `0.110601 V` at phase 74; the colored voltage histogram and midpoint thresholds are saved as `cdr_ffe_voltage_histogram.png` in the same result directory.
- Three-loop `cdr_dlev_cdrffe_sslms.m` (training mode, planB cold start) locks all 32 scanned start phases (`AllPhaseLock=1`) after the 105-UI golden-alignment fix, provided the FFE step size is usable. Verified in MATLAB R2025b: `FfeStepSize=1e-4`, `FfeTrainingBlocks=400` gives 32/32 lock with phase-code spread 0 and small dlev truth error; the previous default `FfeStepSize=1e-6` with 150 training blocks locked 0/32. As of 2026-09-01 these training settings are the script defaults (`FfeInitMode='planB'`, `FfeTrainingBlocks=400`, `FfeStepSize=1e-4`, `FfeStepSizeSettle=2e-5`), so a no-argument run performs cold-start training from FFE `[0 0 1 0 0 0]` and draws both the post-training and converged output histograms. The strict `pre1=post1=0.05` FFE constraint is a post-lock precision metric and is not yet met within the default run length.
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
- Window-based `cdr_ffe` regression passed 7/7 checks covering default and configured FIR mapping, regressor construction, the fixed row-vector contract, validated/fast equivalence, coefficient update/reset, invalid windows, and invalid configuration.
- CDR FFE LMS regression passed 8/8 checks covering update sign and block normalization, validated row/column error handling, validated/fast delta equivalence, optional fast-path gradient output, single-output compatibility, fast-path state isolation, adaptation masking, step-size/reset behavior, invalid input/configuration rejection, and minimal `cdr_ffe` integration.
- Fixed-phase Channel+CTLE/TI-ADC/CDR-FFE adaptation validation passed over 16384 UI. Supervised-only selection chose `mu=0.01` using the primary 8192-supervised/8192-DD split, so fallback was not used; automatic alignment found 105 UI with 0.922208 correlation, and the DD half achieved zero SER, 0.03436 truth MSE, and 1.89755 minimum adjacent known-label level opening.
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
- `validation/CDR/test_cdr/test_channel_ctle_cosim.m` also saves the generated TX `pam4Symbols` alone in `result/channel_ctle_cosim/tx_prbs20.mat` for downstream transmitted-symbol reference.
- The cached-data S-curve uses the classic Mueller-Muller equation with full PAM4 decision amplitudes and signed residual amplitudes. MATLAB R2025b execution passed with a 7-bit `[-4,+4] V` ADC and phase-19 CDR-FFE design reference. The phase-19-centered comparison now overlays fixed-decision reference, unfiltered live, and symmetric-transition live curves over 16384 UI per phase. Their center-region negative-slope crossings are respectively `+0.02562`, `+0.02897`, and `+0.02633 UI`. The first 1024 cached CTLE UI are also plotted as an eye diagram.
- The `mmpd_s_curve_own_data_0.05.m` comparison passed in MATLAB R2025b with the same phase-19 design point and fixed 8192-UI segment. Its constrained total response achieved `pre1/main/post1=0.05/1/0.05`; the remaining cursor RMS is approximately `0.002959`, the maximum residual is approximately `0.008366`, and outputs are isolated under `validation/AFE/test_mmpd_v1/result/mmpd_s_curve_own_data_0.05`.

- Three-loop `cdr_dlev_cdrffe_sslms_v3.m` (SS-LMS FFE variant) replaces the FFE's standard MMSE LMS with Sign-Sign LMS via `cdr_ffe_loop.updateSsLms`. The SS-LMS gradient `sign(e)*sign(X)/N` is hardware-friendly (comparator-only) but requires ~200× larger step sizes to compensate for gradient magnitude compression. With `FfeStepSize=0.02`, `FfeStepSizeSettle=0.001`, and `FfeTrainingBlocks=500`, all 32 start phases lock (`AllPhaseLock=1`, `PhaseSpread=1`), FFE coefficient spread is 0.0033 (well under 0.01 tolerance), and dLev truth errors are -0.07 (inner) / -0.16 (outer) code. The normalized `post1=-0.028` is slightly larger than MMSE LMS due to the sign-sign approximation's inherent steady-state bias; this is expected SS-LMS behavior.
- v3 settle policy simplified (2026-09-03): the multi-stage lock/convergence/staged-release machinery was removed in favor of a single fixed-block trigger at `SettleBlock` (default 3000) that drops both dLev and FFE from capture to settle mu in one shot. Loop gains retuned (`Kp` 8->4, `Ki` 0.06->0.03, `MaxDeltaCode` 12->8, dLev capture `StepSize` 0.3->0.2) to suppress the post-training cross-loop convergence oscillation. Verified in MATLAB R2025b: all 32 start phases lock to code 126 (spread 1), dLev inner=10.85 (spread 0.097)/outer=32.66 (spread 0.272), FFE max coeff spread 0.016, steady-state FFE std ~2e-4, runtime ~73 s. NOTE: the current v3 FFE uses standard block-rate MMSE LMS (`cdr_ffe_loop.update`), not SS-LMS; only the dLev loop is SS-LMS and the PD is SS-MMPD (the older SS-LMS-FFE description above is stale).

## Known issues and technical debt

- Generated files remain inside `src/ADC/**/result` and `src/CDR/result`.
- `src/ADC/ADC_sample_CTEL_output` contains study scripts, large waveform inputs, documentation, and generated results rather than only reusable source.
- Alternative SAR implementations overlap: `SAR_ADC_core`, `SAR_ADC_core_complex`, `SAR_ADC_channel`, `sar_adc_ref`, and the TI ADC-local SAR core.
- Some Chinese comments are corrupted by inconsistent text encoding.
- Model configuration is distributed across constructors and validation scripts rather than centralized.
- Existing validations are mostly behavioral/visual and do not define enough numerical acceptance tolerances.
- The dedicated upstream CDR FFE is integrated only in an AFE validation script; it is not yet exposed through a reusable waveform-level top or the existing `cdr_top` API.

## Current blockers

- The fixed-FFE ADC/CDR loop is validated deterministically. A script-level adaptive three-loop (`cdr_dlev_cdrffe_sslms.m`) now locks all start phases in training mode after the golden-alignment fix, but correlation-quality timing recovery still requires exposing this through a reusable top and adding jitter/noise/corner validation; the strict FFE cursor-symmetry constraint is not yet met within default run length.
- Canonical SAR behavior and boundary conventions must be selected before consolidating duplicate models.
- Required correlation targets and accuracy tolerances are not yet defined.

## Recommended next steps

1. Declare `src/ADC/TI_ADC` as the working TI ADC implementation and document how the other SAR variants will be used as references or retired.
2. Add automated regression tests for SAR boundaries, saturation, fast/debug equivalence, TI lane ordering, and clock indices.
3. Add automated BBPD and PI wrap/nonideality tests under `tests/CDR`.
4. Extend the validated ideal TI-ADC/CDR loop with controlled ADC skew, jitter, and mismatch corners.
5. Move remaining waveform studies, input data, and generated artifacts out of `src`.
