# dlev initial-state versus training-reference phase diagnostic

## 2026-09-17: controlled diagnosis (production v3 unchanged)

### Question and fixed fixture

Why do different dlev initial values produce different final PI codes while the reported samples all look near the center of their corresponding post-CDR-FFE eyes? Does truncating different channel-output intervals introduce a different fractional channel delay?

Controls use the current committed production v3, PRBS22, 8000 blocks (`AnalysisNumUi=512512`), fixed initial PI code124, Kp/Ki8/0.03, dlev mu0.3/0.1, FFE mu0.0018/0.0002,1000 training blocks and freeze500 occurrences/100 events. No default or physical model changed. The single initial PI phase is deliberate, to avoid comparing different automatically selected slowest starts. The main sweep uses outer/inner20/(20/3),36/12,48/16;20/7 is also tested because the user's exact inner value for outer20 was not provided.

### Reproduction of the phase difference

| Outer/inner init | Final mode | Signed near-zero phase | Final mean phase | Freeze block | Final UI slip | Native final-eye start UI |
|---|---:|---:|---:|---:|---:|---:|
|20/6.6666667|123|-5|123.0225|7316|-140|510068|
|36/12|13|13|12.4680|4658|-58|510150|
|48/16|20|20|20.1475|5324|-71|510137|
|20/7|126|-2|126.3810|5688|-99|510109|

All four pass the unchanged final phase criterion. The absolute numerical difference must be interpreted on the PI ring:123 is equivalent to-5 code, not a123-code separation from phase0.

Frozen coefficients, in [pre2,pre1,main,post1,post2,post3] order:

-20/(20/3): `[0.043034375,-0.237703125,1,-0.068484375,0.072665625,0.003128125]`
-36/12: `[0.082390625,-0.324328125,1,0.094628125,0.016640625,0.024415625]`
-48/16: `[0.109190625,-0.370753125,1,0.155321875,0.009140625,0.025253125]`
-20/7: `[0.0491625,-0.25273125,1,-0.03421875,0.05681875,0.01035]`

The actual output levels differ too: final outer/inner about32.2672/10.7620,35.1375/11.7625,36.1594/12.0438 for the first three runs. These are different equalizer working points, not merely the same output shifted on a plot.

### Control1: identical waveform and physical phase axis

Reconstructed all four frozen FFE eyes from exactly the same cached2048UI window: segment start510000, global start510512, same ADC, same phase grid, no graph recentering. Applied each coefficient vector to this identical input independently.

Using known PAM4 labels, define vertical opening as the minimum among three adjacent-level gaps between the upper5%-95% interval endpoint of the lower level and the lower endpoint of the higher level. Only labels are used for this diagnostic; they do not update any loop. A0/1UI label alignment is checked across the phase wrap to identify the represented symbol, not to shift waveform phases.

Maximum labelled opening occurs at phase123,13,20,126 respectively, equal to the corresponding lock modes. Openings at the lock points are17.0832,18.1932,18.2709,17.3860 centered codes. This independently confirms that different frozen equalizers place their best vertical opening at different positions on the SAME time axis.

For each fixed coefficient vector, also rebuilt eyes at all four native final-window starts in the table. Density cross-correlation against the shared-window eye reports best circular shift0 in every one of the16 combinations. Window changes alter which data symbols contribute, but no fractional-UI rotation was observed. All start indices are integer UI; `AnalysisStartUi=512`, block UI origin and waveform cache are unchanged. The channel+CTLE is not rerun/reset per dlev initial condition.

The cached unquantized symbol-pulse peak is always at sample13443 (zero-based), and the isolated quantized symbol-pulse peak after each of these four FFEs happens to be at13451. Therefore a pulse-peak index alone is not an adequate measure of the observed eye-center/PD-equilibrium differences: residual precursor/postcursor composition and data-dependent opening matter. No varying raw channel delay was measured.

### Control2: hold the supervised FFE target fixed, vary only dlev initial state

`cdr_anchor_control.m` is a diagnostic-only copy of the production runner. Its only numerical-model difference is that the FFE golden reference uses fixed inner12/outer36 instead of `DlevInnerInit/DlevOuterInit`. Name/path bootstrap and forced `SaveOutputs=false`, `EyeDiagramEnable=false` are the remaining copy differences. The production script was not edited.

| Initial outer/inner | Fixed FFE training target | Final mode | Final mean phase | Freeze block |
|---|---|---:|---:|---:|
|20/(20/3)|36/12|13|12.9330|4416|
|36/12|36/12|13|12.4680|4658|
|48/16|36/12|13|12.5300|4607|
|20/7|36/12|13|12.8235|4397|

At36/12, the copy's entire phase and FFE traces exactly equal the production run, checking the copy/path intervention itself. The other runs now differ only modestly in residual coefficients/occupancy and all report modal13. This is the strongest evidence that the production initial-value parameters' second role as FFE training targets is the dominant source of the original large phase difference. It does not prove exact real-valued equilibrium uniqueness for every initial state or initial phase.

### Control3: fixed identical FFE, only dlev and phase adaptive

Production runner with `FfeInitMode='planA'`, `FfeTrainingBlocks=0`, concurrent release, FFE capture/settle steps0 and freeze disabled. The same offline-designed coefficient vector is used for all three initial levels:

`[0.11097988,-0.32087832,1,0.21359094,0.055862304,0.12171401]`

All initial outer20/36/48 cases lock at22. Tail mean phase22.138,22.125,22.122; final outer level36.686..36.694. Final UI slip0/1/1 differs by whole symbols but does not produce a fractional phase difference. This control is a different fixed-equalizer fixture, not a claim that production should lock at22 or that FFE adaptation is unnecessary.

### Root cause and interpretation

In production, the same `DlevInnerInit/OuterInit` values both initialize the dlev estimator and scale the supervised FFE target (v3 lines468-483). Changing them is consequently not an initial-state-only experiment: it changes what the equalizer is trained to produce. Different resulting taps change the residual pulse/eye shape and SS-MMPD equilibrium; the causal write-freeze then retains that path-dependent tap vector. Fixing the main FFE coefficient at1 does not fix the cascade response or its best sampling phase.

Current evidence does NOT support fractional channel delay being introduced by output cropping. Integer UI slips/crop offsets reflect differing acquisition histories and selected data windows; they do not change the sampling phase modulo one UI. The stronger statement that different data sequences can never affect a finite-window mode is not made.

The friend's image shows fixed initial PI124, final codes mostly125 with124 and126 outliers, and a label0.03125UI/code. The current model is1/128UI/code; if that label is correct their phase quantization is4x coarser. Their absolute phase origin, PI span, tap adaptation/freeze policy and whether dlev initial values also change an FFE training target are unknown. The screenshot alone cannot establish implementation equivalence, and resolution alone does not account for the full original phase separation here.

### Files, verification, and limits

- `anchor_phase_comparison.csv`: compact before/control table.
- `same_window_different_ffe_eyes.png`: same cached data and phase origin, original three different frozen equalizers.
- `anchor_phase_causal_comparison.png`: original versus two controls, and labelled opening versus phase.
- `anchor_phase_diagnostic_result.mat`: all run structures, fixed-target/fixed-FFE controls and common-window grids/opening metrics.
- `cdr_anchor_control.m`: isolated diagnostic copy; do not substitute it for production v3.

Relevant tests pass: eye reconstruction7/7, eye-window6/6, modal detector9/9, first-capture selector9/9. Control-copy equivalence, zero crop phase shifts, common-input opening data and identical-mode control assertions pass. Finite2048-symbol empirical decision error was0 at the diagnostic lock points; this is not BER qualification and thresholds/labels are diagnostic only.

Primary intermediates/logs remain in session artifacts: `anchor_phase_baselines`, `anchor_phase_fixed_ffe`, `anchor_phase_fixed_anchor`, `anchor_phase_common_window`, `anchor_phase_labelled_opening`. The existing production MAT/PNG/defaults were not overwritten and `git diff --exit-code` confirms production v3 is unchanged. No production fix or commit is applied. A potential future fix is to expose distinct programmed FFE training references and dlev initial-state parameters, with user-approved nominal targets; do not replace the fixed target with live dlev without evaluating its scale-coupling risk.
