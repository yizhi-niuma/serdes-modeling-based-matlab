# CDR v3 implementation and convergence notes

## 2026-09-17: current results use independent initial48/16 and FFE training reference36/12

### Parameter roles and implementation

The user approved separating the dlev estimator's initial state from the FFE supervised training target:

```matlab
defaults.DlevOuterInit = 48;
defaults.DlevInnerInit = 16;
defaults.FfeTrainingOuterRef = 36;
defaults.FfeTrainingInnerRef = 12;
```

Only the `FfeTraining*Ref` values scale golden symbols for the FFE training error. The existing phase/dlev training paths still use live dlev; after training, FFE still uses the shared live decision. Changing dlev initialization no longer implicitly changes the FFE target. References must be finite real positive scalars with outer>inner, but need not have an exact3:1 ratio. Both programmed values are stored in top-level result fields and `RunOptions`, distinct from offline measured `DlevInnerReference/DlevOuterReference`.

No change was made to main-tap1, SS-LMS equations, gains, cache/time alignment, freeze criterion or final phase-lock checks. This is not an AGC or a new adaptive reference estimator. The default36/12 target is a user-selected nominal reference for this experiment, not asserted as universal truth.

### Run and verification

- Current run: PRBS22,8000 blocks,32 starts `0:4:124`,1000 training blocks; phase Kp/Ki8/0.03, dlev mu0.3/0.1, FFE mu0.0018/0.0002, online freeze500 occurrences/100 events. Runtime113.757s in MATLAB R2025b.
- All32 starts begin with dlev outer48/inner16; all32 final phase locks and FFE freezes pass. `AllPhaseLock=1`, common13, modes11..14, spread3, final-window event counts138..175 and no out-of-band samples.
- Mean final inner/outer dlev11.730664/35.124023; dlev consistency passes. Separate FFE checks fail: max cross-start coefficient spread0.020369 exceeds0.02; normalized pre1/post1=-0.036527/-0.070715 exceed +/-0.02. The successful phase criterion must not be confused with passing all equalization-quality checks.
- Selected slowest first-capture start36, first capture3076, freeze4655. Freeze eye begins at the next complete block4656/segment UI298117. Final eye starts segment UI510149. Both use2048UI and mark phase13. All standard output figures, MAT and CSVs now correspond to this split-reference run; older sections below are historical.
- All eight suites pass59 groups. New reference tests cover state/reference independence, active training behavior, exact DD-only invariance, invalid inputs and struct/name-value options. Existing freeze fixture pins36/12 references independently of future defaults.
- Full start124 trajectory matches the earlier diagnostic copy with initial48/16 and fixed36/12 target. Explicit initial36/12/reference36/12 reproduces eight original coupled36/12 arrays exactly. The numerical comparisons demonstrate correct parameter wiring, not guaranteed convergence uniqueness for arbitrary systems.

### Reproduction

```matlab
addpath('validation/CDR/test_cdr_dlev_cdrffe');
result = cdr_dlev_cdrffe_sslms_v3(); % now initial48/16, training reference36/12

% Equivalent explicit settings, without relying on those defaults:
result = cdr_dlev_cdrffe_sslms_v3( ...
    'DlevOuterInit',48, 'DlevInnerInit',16, ...
    'FfeTrainingOuterRef',36, 'FfeTrainingInnerRef',12);
```

To reproduce historical coupled training, explicitly pass the FFE references equal to the chosen dlev initial values. The two groups are no longer automatically linked. Test/run logs: session artifacts `split_ffe_reference_tests.log` and `split_ffe_reference_noarg.log`. No commit was automatically created.

## 2026-09-17: historical commit snapshot (40/13, PRBS22,8000 blocks)

The user subsequently changed the executable defaults to outer/inner40/13 and `NumBlock=8000`, retaining PRBS22,1000 training blocks, dlev mu0.3/0.1, FFE mu0.0018/0.0002 and freeze500/100. These latest settings are preserved in the requested commit. The existing MAT identifies the same40/13/8000 configuration and reports32/32 phase locks, `AllPhaseLock=1`, modes15..17; it was inspected, not regenerated during the commit task. The current first-capture/freeze CSVs accompany this snapshot. Binary MAT/PNG outputs are intentionally not committed under project policy.

Seven regression suites (54 groups) passed again before commit. Their pinned integration fixture does not establish a new all-default40/13 run. The following48/16/16000 tuning result and its two dedicated tuning CSVs remain historical evidence for that distinct configuration. Executable defaults and `result.RunOptions`, not older comments or reproduction snippets, identify the current run.

## 2026-09-17: historical no-argument48/16 all-start tuning result

### Scope and fixed conditions

The user requested all-phase lock with dlev initial values48/16. These parameters also remain the FFE training anchors. At task entry, the user's working-copy configuration had changed to PRBS22/16000 blocks,1000 training blocks, online freeze500 modal occurrences/100 center events, dlev mu0.3/0.6 and FFE mu0.02/0.01. The initial no-argument baseline produced21/32 individual locks and14/32 freezes. The older36/12 andPRBS20 records below are historical, not this experiment.

All tests retained the SS-MMPD equation, PD offset/polarity, ADC/channel scale, fixed main tap, final2000-block modal-center +/-3 band/51-event count, and common-center +/-3 tolerance. The freeze thresholds500/100 were also fixed rather than relaxed to manufacture a pass. Eight/nine representative starts screened21 candidate configurations; promising cases were rechecked over all32 starts `0:4:124`.

### Applied parameters

Only three numerical defaults changed relative to task entry:

| Parameter | Before | Selected |
|---|---:|---:|
| dlev `StepSizeSettle` | 0.6 | **0.1** |
| FFE `FfeStepSize` | 0.02 | **0.0018** |
| FFE `FfeStepSizeSettle` | 0.01 | **0.0002** |

Retained: `Kp=8`, `Ki=0.03`, `MaxDeltaCode=12`, `StepSize=0.3`, `DlevOuterInit=48`, `DlevInnerInit=16`, `FfeTrainingBlocks=1000`, freeze500 occurrences/100events/+/-3, PRBS22 and `NumBlock=16000`. The lower FFE training rate reduces the high-anchor adaptation excursion, and the lower post-training update rates permit stable detector statistics and eventual freeze. This is measured behavioral tuning, not a proof of global optimality.

### Current result and caveats

- Direct no-argument execution completed in159.318s, matching the parameterized D03 finalist in seven checked arrays. **32/32 locked,32/32 frozen,AllPhaseLock=1**. Common21, modes20..22, spread2. Final-window events141..174 and0 violations.
- dlev final means inner/outer12.0440/36.2132; spreads0.1078125/0.2484375, consistency passes. An initial outer48 is not a commanded final48 level: the live dlev tracks the equalized output.
- FFE coefficient spread0.013181 passes0.02. Normalized pre1/post1+0.003673/-0.010433 pass the existing +/-0.02 tests. These are existing finite-run checks, not BER or exact ISI elimination.
- Slowest first-capture start104: block3973, freeze5086, freeze/final markers22/21. Freeze range4867..6027. Both eyes use2048UI; freeze eye starts5087 at segment UI325692; final eye starts1022140. Selected frozen taps `[0.1142344,-0.3796844,1,0.1651656,0.008615625,0.02570937]`.
- Acquisition is not slip-free: final accumulated slip ranges-73..-66UI, and the last slip occurs2331..2569 before freezing. This tune achieves eventual stable lock but can cycle through many UI during acquisition. Do not interpret it as shortest-acquisition, symbol-sync, jitter-tolerance, or BER qualification.
- The final selected start's mean phase stays around21.5 after freeze. Main plots/MAT/first-capture and freeze CSVs now correspond to this PRBS22/16000,48/16 no-argument configuration.

### Independent PRBS20/8000 holdout

Identical gains/anchors/training/freeze thresholds, changed only code source and run length, give32/32 locks and32/32 freezes,AllPhaseLock=1,common21,modes19..21,spread2,min139events/no violations. FFE spread0.013025 and pre1/post1+0.004559/-0.012932 pass. Runtime51.80s, latest freeze5746. This separate test does not overwrite the primary PRBS22 figures. Per-start results are retained in `tuning_48_16_prbs20_holdout.csv`.

### Reproduction and evidence

```matlab
addpath('validation/CDR/test_cdr_dlev_cdrffe');
result = cdr_dlev_cdrffe_sslms_v3();  % current48/16, PRBS22,16000-block defaults

% Independent shorter-code holdout without overwriting the main output:
prbs20 = cdr_dlev_cdrffe_sslms_v3( ...
    'CosimDir','channel_ctle_cosim', 'TxFile','tx_prbs20.mat', ...
    'AnalysisNumUi',8000*64+512, 'NumBlock',8000, ...
    'SaveOutputs',false, 'EyeDiagramEnable',false);
```

`AnalysisNumUi` remains the actual scheduler input; the user's `NumBlock` is used to derive its default inside the parser, not as a standalone post-parse override. Pass `AnalysisNumUi` explicitly when overriding length as above.

`tuning_48_16_search.csv` contains21 candidate rows; `tuning_48_16_prbs20_holdout.csv` contains the independent32-start result. Session artifacts retain baseline, batch and finalist MAT/logs (`tune48_baseline`, `tune48_screen_a/b/c/d`, `tune48_full_c05`, `tune48_full_d03`, `tune48_noarg_final`, `tune48_prbs20_holdout`). All seven regression suites passed54 groups. The freeze-integration test now pins its original numerical fixture independently of defaults; no assertions were loosened. No commit was created automatically.

## 2026-09-17: outputs switched back to PRBS20/8000 blocks (historical36/12 result)

- User requested PRBS20 and8000 blocks rather than PRBS22/20000. Only run options changed: `CosimDir='channel_ctle_cosim'`, `TxFile='tx_prbs20.mat'`, `AnalysisNumUi=512512`. The same32 initial phases, explicit36/12 anchors, gains, training, online freeze thresholds and2048UI eyes were retained. These cache/length choices already are the script defaults; no source algorithm changed.
- MATLAB R2025b runtime151.295s. All32 FFEs freeze and all32 individual phase-lock criteria pass; event counts154..192, no final-window band violations. Freeze blocks1229..1573. The all-start common-phase check fails: modes11..17, common15, starts28/32 at11 lie outside common15+/-3. Thus `AllStartsConverged=1` but `AllPhaseLock=0`; do not label the whole validation as all metrics passing.
- Recomputed slowest first capture is **start36 at block1180**. This start freezes at1525; freeze/final centers16/16. Latest FFE freeze is start64 at1573, which is a different metric. Previously selected start44 was specific to the preceding PRBS22 result.
- Freeze eye begins at block1526/segment UI97856; final eye begins segment UI510208 and ends at512256. Both contain2048UI and use the selected start's actual frozen taps. phase/dlev/FFE plots, all-phase summary, eyes, MAT and bothCSV summaries now refer to this PRBS20 run.
- Tap constancy/write-inhibition, final-event independent oracle, selector ranking, all eye boundaries/markers/counts, andCSV/MAT consistency checks pass. Monitor9/9, eye-pair6/6 and selector9/9 tests pass. FFE coefficient spread0.0444016>0.02 and pre1/post1=-0.0498/-0.0538 remain separate failed quality checks.
- Reproduce the current run from repository root:

```matlab
addpath('validation/CDR/test_cdr_dlev_cdrffe');
result = cdr_dlev_cdrffe_sslms_v3( ...
    'CosimDir','channel_ctle_cosim', 'TxFile','tx_prbs20.mat', ...
    'AnalysisNumUi',512512, 'StartPhaseList',0:4:124, ...
    'DlevOuterInit',36, 'DlevInnerInit',12, ...
    'FfeFreezeEnable',true, 'EyeDiagramEnable',true, ...
    'EyeDiagramUiCount',2048);
```

No-argument cache/length already equal PRBS20/8000, but no-argument anchors remain48/16. Use the explicit36/12 override above to reproduce these artifacts. The saved `result.RunOptions` contains every setting. Log: `v3_prbs20_8000_freeze_validation.log` in session artifacts. All sections below are historical runs, not the current PNG/MAT values.

## 2026-09-17: online FFE write freeze and freeze/final 2048-UI eyes (historical PRBS22 results)

### Implemented behavior

`ffe_freeze_monitor` is causal and independent for every initial phase. Monitoring starts at `FfeTrainingBlocks+1`. Search-period code occurrences are accumulated in unwrapped coordinates; a modal code needs at least100 observations before it is latched as the candidate center. With that center fixed,50 arrival-at-center or direct-cross events inside inclusive +/-3 codes trigger permanent FFE write inhibition. Dwell/departure do not double count. A candidate-band violation clears both occurrence and event history and discards the outside sample before restarting search.

The trigger block retains the effective coefficients it already used. The FFE still computes SS-LMS raw deltas and `effectiveTaps + rawDelta` proposals on every valid later block, but applies no delta. There is no accumulated shadow equalizer and the FFE step size is not forced to zero. Phase and dlev continue to run. The existing final lock rule (last2000 samples,51 events) and retrospective first-capture ranking remain separate.

Two fixed-tap post-CDR-FFE eyes are reconstructed for the newly selected slowest, finally locked start. Each defaults to2048 UI (`EyeDiagramUiCount`, not a block count):

1. Freeze eye: starts at the first complete block **after** the freeze trigger and uses actual frozen taps; marker is the online freeze center.
2. Final eye: ends at the last physical processed block and uses the same frozen taps; marker is the final-window lock center.

The existing ideal SAR code converter is evaluated across all128 cached sub-UI phases, then the symbol-spaced FIR is applied independently to each phase stream with correct past/future margins. This is an offline fixed-tap reconstruction, not an online128-phase sampler. Two-UI overlapping traces use0.5-code density bins and common vertical/color scales. UI phase axes are not recentered around the markers. Missing or short windows are explicitly N/A/truncated, never filled with pre-freeze data. A not-frozen selected start has no freeze eye and a labelled final-live-tap snapshot.

### Current validation result

- Explicit PRBS22,20000 blocks,32 starts `0:4:124`, nominal anchors36/12, Kp/Ki8/0.03, dlev mu0.3/0.1, FFE mu0.02/1e-4,500 training blocks. Original numeric defaults are unchanged; the new freeze and eye features default enabled.
- Full run: **32/32 freeze,32/32 final phase lock**. Freeze times1214..1465, each50 events after >=100 center occurrences. Final counts146..184, no final band violations. Common phase14, modes12..16, spread4. Initial execution took227.597s in MATLAB R2025b.
- Selected slowest first capture: **initial phase44**, block1222. Its FFE freezes at block1465, center12; final detected center13. These differ because the first-capture metric is retrospective, while freezing waits for online post-training center qualification and50 new events.
- Frozen coefficients: `[0.0788921875,-0.3274484375,1,0.0936609375,0.0146515625,0.0230703125]`.
- Freeze-eye block1466 starts at zero-based segment UI94015/global UI94527; final eye starts at segment UI1278207/global UI1278719. Each uses2048 UI and a128x2048 phase grid. Each two-UI density has524032 observations (interior UI samples appear in two adjacent traces).
- All post-freeze effective coefficient states are exactly constant, while raw calculated deltas remain finite and nonzero. All pre-veto phase/dlev/coefficient prefixes match the preceding unfrozen baseline. The selected start's mean phase in2001..4000,8001..10000,18001..20000 is12.574,12.515,12.5355 rather than a sustained downward glide.
- Actual64-lane TI ADC plus FFE replay at phases0,marker,64,127 matches the first64 UI of each eye grid exactly. Unit/integration groups passed: monitor9/9, eye7/7, eye pair6/6, real freeze-on/off5/5, slowest selector9/9, final lock9/9.
- FFE quality limitations remain: cross-start coefficient spread0.02964 exceeds0.02, pre1/post1=-0.0506/-0.0587 fail their separate +/-0.02 checks. Frozen temporal coefficient variance is not proof of optimum equalization, BER, or infinite-time stability.

### Files and options

Final delivery replay completed in164.409s after native CSV export and freeze markers were added;12 trace/diagnostic arrays and both eye grids match the first passing freeze run exactly. Native CSVs and MAT metadata agree. Convergence figures distinguish red first-PI-capture markers from green FFE-freeze markers. Final replay log: `v3_freeze_final_delivery_retry.log`.

New PNGs: `cdr_ffe_eye_at_freeze_2048ui.png`, `cdr_ffe_eye_final_2048ui.png`, `cdr_ffe_eye_freeze_vs_final.png`. Existing phase/dlev/FFE convergence figures now show selected phase44; the full modal lock summary remains. `ffe_freeze_summary.csv` and `first_capture_summary.csv` refer to this current run. MAT stores raw/proposed/applied deltas, write/frozen/calculated flags, freeze center/time/count/coefficients, eye grids/densities/window coordinates/markers, and all original trajectories. Earlier sections below are historical results, not descriptions of the currently regenerated PNG/MAT files.

Reproduce the current long run from repository root:

```matlab
addpath('validation/CDR/test_cdr_dlev_cdrffe');
result = cdr_dlev_cdrffe_sslms_v3( ...
    'CosimDir','channel_ctle_cosim_prbs22', 'TxFile','tx_prbs22.mat', ...
    'AnalysisNumUi',1280512, 'StartPhaseList',0:4:124, ...
    'DlevOuterInit',36, 'DlevInnerInit',12, ...
    'FfeFreezeEnable',true, 'FfeFreezeMinModeOccurrences',100, ...
    'FfeFreezeMinEvents',50, 'FfeFreezeBandHalfWidth',3, ...
    'EyeDiagramEnable',true, 'EyeDiagramUiCount',2048);
```

Use `'FfeFreezeEnable',false` for the previous continued-adaptation behavior. Use `'EyeDiagramUiCount',1024` to shorten both eye windows or `'EyeDiagramEnable',false` to omit reconstruction. No-argument execution retains PRBS20/8000 blocks/48-16 anchors; that configuration is not the36/12 long-run validation reported here. An alternate `ResultDir` preserves this directory; `SaveOutputs=false` computes results without writing MAT/PNG/CSV files. Execution/test logs: session artifacts `v3_online_freeze_full_validation.log` and `ffe_freeze_integration_tests.log`.

## 2026-09-16: single-start convergence plots selected by slowest first PI capture

### Validation objective and structure

The script `validation/CDR/test_cdr_dlev_cdrffe/cdr_dlev_cdrffe_sslms_v3.m` simulates the Channel+CTLE cache, ideal TI ADC, dedicated CDR FFE, SS-MMPD phase loop, dlev tracking, and FFE SS-LMS adaptation. The complete start-phase sweep and all trace arrays remain in the saved MAT. Only the three phase/dlev/FFE convergence figures select a single start; the all-start modal-phase summary remains unchanged.

### Final lock and first-capture definitions

- Final lock: take the last 2000 unwrapped PI codes, select their fixed modal center, and count events only inside this window. A tie selects the lowest unwrapped modal code.
- The valid band is center +/-3 codes, inclusive. Arrival from a noncenter code at the center counts once, including touch-and-return; a direct crossing that skips the center also counts once. Center dwell and departure do not add an event. An out-of-band sample resets the retained counter and previous-sample continuity. At least 51 events retained at the end is required.
- First capture is a separate retrospective metric: freeze the same final-window modal center and scan the entire trace from block 1. Record the first block reaching 51 events under the same event/reset rules. Later exits do not erase this first-capture timestamp.
- `select_slowest_pi_capture.m` ranks only finally locked starts with a finite first-capture time, selects the largest time, and resolves equal times by the first scan row. It does not use the final-window `OnsetBlock`, the time after the last band exit, or a hard-coded edge phase such as 76.
- The first-capture marker is a PI metric, not a claim that dlev or FFE finishes settling at that block. It uses the final-center estimate retrospectively and is not an online hardware lock declaration.

### Reproduced configuration

- Cache: complete PRBS22, `channel_ctle_cosim_prbs22/channel_ctle.mat`; TX labels: `tx_prbs22.mat`.
- `AnalysisNumUi=1280512`, exactly 20000 processed blocks of 64 UI.
- Starts: `0:4:124` (32 sampled initial phases, not an exhaustive 128-phase scan).
- dlev outer/inner initial values and FFE training anchors: 36/12, explicitly passed.
- Phase gains: Kp=8, Ki=0.03, MaxDeltaCode=12, phase-gated PdOffset=-0.05.
- dlev step sizes: 0.3 capture, 0.1 settle.
- FFE SS-LMS step sizes: 0.02 capture, 1e-4 settle; main tap fixed at one.
- Cold-start FFE, 500 training blocks; the update equations and schedule are unchanged.
- Current no-argument defaults still use 48/16 anchors and the PRBS20/8000-block cache settings. The explicit settings above are required to reproduce these generated results.

### Results and limits

- MATLAB R2025b replay runtime: 146.178 s.
- All 32 starts pass final phase lock. Common modal code=13, modal range=11..14, spread=3 code. Final-window event counts=143..186, with zero band violations for all starts.
- Slowest first capture: **start phase 96**, trace row 25, **block 9849**, selected modal code 13. Start phase 76 first captures at block 8569. Start phase 20 first captures at block 1819.
- Start 96 has tied final-window modes 13 and 14 (841 samples each); this selection uses the documented lower-mode choice 13. First-capture ranking is conditional on that deterministic center rule.
- Eight full dynamic trace arrays plus three final-lock arrays exactly match the preceding all-start result in `results/CDR/prbs22_20000blocks_allphase_center_touch/`. Thus the plotting/selection changes did not alter the tested loop trajectories or final decisions.
- `test_select_slowest_pi_capture` and `test_detect_pi_center_touch_lock` each pass 9/9 test groups. The selector tests cover resets before capture, later resets preserving first capture, final-lock eligibility, ties, absent candidates, full-history counting, unwrapped shifts, and invalid inputs.
- Separate FFE checks still fail: coefficient spread 0.0255797 exceeds 0.02; normalized pre1/post1 are about -0.0382/-0.0687 rather than within +/-0.02. Phase-lock success does not imply full three-loop precision, BER, infinite-time stationarity, or all 128 initial phases have been validated.

### Output contents

- `cdr_phase_convergence.png`: only start 96 phase trajectory, selected modal level, and first-capture marker.
- `dlev_convergence.png`: only start 96 inner/outer dlev traces, with the same PI marker.
- `cdr_ffe_convergence.png`: only start 96, one trace per free FFE tap, with the same PI marker.
- `cdr_locked_phase_vs_start_phase.png`: retained 32-start last-2000 modal-phase summary.
- `cdr_ffe_output_histogram.png`: unchanged histogram convention, using the start closest to reference phase (start 20), not the slowest-capture selection.
- `cdr_total_path_ui_response.png`: unchanged aggregate response convention, using mean final FFE coefficients evaluated at the common modal phase.
- `cdr_dlev_cdrffe_sslms_v3_result.mat`: complete trace arrays and new `FirstCaptureBlock`, `SlowestCapturePhaseIndex`, `SlowestCaptureStartPhase`, `SlowestFirstCaptureBlock`, `ConvergencePlotPhaseIndex`, `ConvergencePlotStartPhase`, and `CaptureTimeCriterion` metadata.
- `first_capture_summary.csv`: per-start first-capture block, final modal code, final lock flag, and final-window event count.
- Execution log: session artifact `v3_slowest_first_capture_validation.log`.

### Reproduction

From the repository root in MATLAB:

```matlab
addpath('validation/CDR/test_cdr_dlev_cdrffe');
result = cdr_dlev_cdrffe_sslms_v3( ...
    'CosimDir', 'channel_ctle_cosim_prbs22', ...
    'TxFile', 'tx_prbs22.mat', ...
    'AnalysisNumUi', 1280512, ...
    'StartPhaseList', 0:4:124, ...
    'DlevOuterInit', 36, 'DlevInnerInit', 12, ...
    'Kp', 8, 'Ki', 0.03, 'MaxDeltaCode', 12, 'PdOffset', -0.05, ...
    'StepSize', 0.3, 'StepSizeSettle', 0.1, ...
    'FfeStepSize', 0.02, 'FfeStepSizeSettle', 1e-4, ...
    'FfeTrainingBlocks', 500, 'SaveOutputs', true);
```

With no `ResultDir` override, outputs go to this directory. Running the script with no arguments still uses its own PRBS20/8000-block/48-16 defaults, but automatically selects the slowest first-capture start from that run. To avoid writing figures/MAT pass `SaveOutputs=false`; to preserve this result use a separate `ResultDir`.

## 2026-09-16 follow-up: training dlev dip and slow phase drift

- Phase96 outer dlev reaches34.378125 at block161, below final35.2484375 by2.47%; inner reaches11.325 at159, below final11.7421875 by3.55%. The dips occur while all three loops are changing and do not represent convergence toward a fixed eventual amplitude.
- An actual ADC/FFE/golden replay reproduces the first500 dlev increments to2.84e-15. During81..160 the true-outer-class |FFE output| median is34.48047 and the mean pre-update outer dlev is34.54746; net votes are downward. During221..300 the output median becomes34.95375 versus dlev34.83773; net votes are upward. SS-LMS tracks a conditional median-type amplitude statistic, not mean absolute amplitude. The fixed FFE training target36/12 is distinct from the live output level that dlev tracks. Fixing the FFE main coefficient does not fix the cascade main-cursor gain.
- Timing reaches the final13+/-3 band at31 but then overshoots to6..9 and recovers. Replayed integral state is about-0.298 code/block at31 and-0.204 at150. There is no pending-code backlog, so early overshoot is not a queued slew demand.
- At500, FFE mu drops0.02->1e-4 (200x), dlev mu0.3->0.1 (3x); block500 still uses golden labels, and DD starts501. FFE reference switches from fixed nominal anchors to live dlev at this boundary. FFE continues adjusting the free taps and hence moves the level distribution and timing-detector equilibrium.
- Diagnostic control (not a fix): run only start96 with the same options but `FfeStepSizeSettle=0` and `SaveOutputs=false`. Prefix through499 matches the original; FFE freezes from500 while phase/dlev remain live. Original mean phase501..2500 ->18001..20000 is15.1255->13.4660, versus15.2020->15.1395 with frozen FFE. This isolates ongoing FFE/dlev/PD coupling as the dominant source of the original long phase glide. Freeze retains a different equilibrium near15 and is not recommended as a blind replacement.
- The capture marker9849 is also strongly metric-dependent: the final histogram ties at13 and14. Selecting13 gives first51-event time9849; selecting14 gives1522 on the same trajectory. The implementation still uses its documented lower-tie center13. Do not interpret9849 as the time before which the physical loop was wholly unlocked.
- These diagnostics change no production code/defaults. Evidence is in session artifacts `phase96_freeze_ffe_diagnostic.log`, `phase96_frozen_ffe_result.mat`, `phase96_training_votes_retry.log`, and `phase96_training_replay.mat`; original figures/MAT remain unchanged.
