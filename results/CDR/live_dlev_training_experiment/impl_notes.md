# Live-dlev FFE training-reference experiment

## 2026-09-17: unchanged-gain full-start experiment after baseline commit

### Baseline checkpoint and scope

Commit `0576cff` (`refactor(cdr): separate dlev initialization from FFE training references`) was created before this experiment. It contains the independent dlev initialization and fixed supervised FFE reference, its tests, and textual diagnostic evidence. Generated MAT/PNG files were excluded under project policy. The commit was not pushed.

The experimental option `FfeTrainingReferenceMode='live-dlev'` is added in the working copy; the default remains `'fixed'`. The live-mode implementation, new regression and this experiment are not included in the baseline commit and have not been automatically committed. The standard fixed-reference result directory was not overwritten.

### Exact meaning of live training

- During the first1000 training blocks, the known golden symbol still supplies the sign and inner/outer class.
- The FFE target amplitude is the live dlev state at the beginning of that same processing block, before the current dlev update. It reuses `goldenMagnitude`, already computed for the phase/dlev training path.
- Do not use the received-output sign as the FFE training symbol, and do not use dlev state after the current block update.
- The existing phase/dlev paths, DD FFE reference, SS-LMS update equation, fixed unit main coefficient, input alignment, freeze behavior and lock thresholds are unchanged.
- The programmed `FfeTrainingOuterRef/FfeTrainingInnerRef` remain recorded and validated options, but are unused as target amplitudes in live mode. In fixed mode they continue to supply the training target.
- The saved `FfeTrainingInnerRefTrace`, `FfeTrainingOuterRefTrace` and `FfeTrainingActiveTrace` identify the actual per-block reference. Numeric reference traces are NaN outside training.

### Configuration

| Setting | Value |
|---|---|
| Code source | Existing PRBS22 Channel+CTLE cache |
| Processing length | 8000 blocks,64 UI/block; AnalysisNumUi=512512 |
| Initial PI phases | 0:4:124,32 starts, not exhaustive128-phase coverage |
| dlev initial outer/inner | 48/16 |
| FFE training reference mode | live-dlev |
| Programmed but unused fixed references | 36/12 |
| Kp/Ki | 8/0.03 |
| MaxDeltaCode | 12 |
| PdOffset | -0.05 with existing phase gate |
| dlev capture/settle mu | 0.3/0.1 |
| FFE capture/settle mu | 0.0018/0.0002 |
| Training blocks | 1000 |
| Freeze | 500 modal occurrences,100 center events,+/-3-code band |
| Final lock | Last2000 blocks,modal center,+/-3 band,>=51 retained events |
| Eye data | 2048 UI after freeze and2048 final UI |

No tuning was needed to meet the requested all-start phase-lock criterion. No gains, initial states, freeze gates or acceptance thresholds were changed for this experiment.

### Results and fixed-reference comparison

| Metric | Fixed36/12 reference baseline | Live-dlev reference |
|---|---:|---:|
| Individually locked starts | 32/32 | 32/32 |
| Frozen FFEs | 32/32 | 32/32 |
| AllPhaseLock | 1 | 1 |
| Common modal PI code | 13 | 11 |
| Modal code range / spread | 11..14 /3 | 9..12 /3 |
| Final retained event range | 138..175 | 146..172 |
| Final-window band violations | 0 | 0 |
| Mean inner dlev | 11.730664 | 11.648535 |
| Mean outer dlev | 35.124023 | 34.886670 |
| Max FFE coefficient spread | 0.020369 | 0.022200 |
| Normalized pre1 | -0.036527 | -0.05186 |
| Normalized post1 | -0.070715 | -0.06914 |

Both modes pass the requested phase-lock/common-center metric and the dlev consistency check. Neither passes every FFE-quality check: the live coefficient spread exceeds0.02, and its pre1/post1 exceed the separate +/-0.02 limits. This experiment does not establish that live training improves equalizer quality or is universally superior to fixed references.

All live reference states remained finite, positive and ordered. During training, inner dlev ranged12.0390625..16.7171875 and outer ranged30.3046875..48. No zero-amplitude collapse occurred in this fixture. Final outer/inner ranges were34.6375..35.059375 and11.5609375..11.7125.

Every start froze between blocks4244 and6755. Initial phase72 reset its candidate search once, then froze at6755. The selected slowest first-capture start is44: first capture3007, freeze4702, online freeze center10 and final mode11. Its freeze eye starts at block4703/segment UI301123, while its final eye starts at segment UI510147; both contain2048UI and use the same actual frozen taps.

Acquisition still has substantial integer slips: final slip ranges-62..-58 UI, with the last slip at blocks1858..2091, before freezing. Final lock is therefore not a no-slip acquisition or minimum-time result. This fixture permits such slips and checks unwrapped phase in the final window, rather than hiding continued slips by modulo.

### Verification

- New live-reference regression passes5/5 groups: default/explicit fixed equivalence; case-insensitive mode handling; exact pre-update live references; irrelevance of programmed constants in live mode; mode invariance when training is disabled; invalid mode rejection before cache access.
- The initial regression attempt used a wrong test-field alias, `FfeTrainingReferenceActiveTrace`, and failed before the semantic assertions completed. The test was corrected to the actual `FfeTrainingActiveTrace`; no algorithm change was needed for that failure.
- All nine regression suites pass64 groups.
- The default fixed mode reproduces ten full32-start arrays from the committed fixed-reference result exactly, including phase, UI slip, dlev, FFE/raw delta, freeze times and lock metrics.
- The saved live run reproduces seven arrays from the preceding no-output live experiment exactly. Independent final-window event counting matches every reported count. Applied taps are exactly constant after freezing, write flags are false, and calculated raw deltas remain nonzero afterward.
- All live reference samples in blocks2..1000 exactly equal the corresponding dlev values recorded after blocks1..999; first references equal48/16.
- Both eye windows are valid with2048UI and the existing phase/FFE reconstruction model. Phase/cursor metrics refer to this dedicated CDR FFE, not a complete BER or jitter-tolerance validation.

Runtime: initial no-output run56.57s; saved/eye-enabled run103.985s in MATLAB R2025b. This success with the current code/gains/freeze policy does not contradict a failed older live-reference implementation; it also does not prove every initial state, channel, or no-freeze run converges.

### Reproduction and outputs

From the repository root:

```matlab
addpath('validation/CDR/test_cdr_dlev_cdrffe');
result = cdr_dlev_cdrffe_sslms_v3( ...
    'FfeTrainingReferenceMode','live-dlev', ...
    'DlevOuterInit',48, 'DlevInnerInit',16, ...
    'CosimDir','channel_ctle_cosim_prbs22', ...
    'TxFile','tx_prbs22.mat', ...
    'AnalysisNumUi',8000*64+512, ...
    'StartPhaseList',0:4:124, ...
    'ResultDir',fullfile(pwd,'results','CDR','live_dlev_training_experiment'));
```

The remaining parameters use the values in the table. Pass `'FfeTrainingReferenceMode','fixed'` or omit the option to use the committed baseline behavior. When comparing modes, use different result directories; this avoids replacing the standard fixed-reference figures.

This directory contains the complete live result MAT, all-start modal phase plot, selected phase/dlev/FFE traces, freeze/final eye PNGs and comparison, native freeze/capture CSVs, and `fixed_vs_live_summary.csv`. Session logs: `live_dlev_baseline_run.log`, `live_dlev_full_saved.log`, `live_reference_regression_retry.log`, and `live_fixed_equivalence.log`. The baseline commit is0576cff; experimental changes remain uncommitted pending user review.
