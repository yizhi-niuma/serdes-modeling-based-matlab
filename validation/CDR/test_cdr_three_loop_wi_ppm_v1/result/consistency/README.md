# v1 (new TI ADC) vs baseline consistency verification

This directory records the check requested for `test_cdr_three_loop_wi_ppm_v1`:
after swapping the TI ADC model from `src/ADC/TI_ADC` (baseline) to
`src/ADC_model_HSY_2609/TI_ADC` (the intern's update), are the simulation
results consistent with the original ADC results?

**Answer: yes — bit-identical.** The updated ADC produces the exact same output
codes in the runner's configuration, and because the whole ppm pipeline is
deterministic (no RNG), every numeric simulation output matches to the bit.

## Interface compatibility (no runner edit required)

The public interface is unchanged; the two additive changes are backward
compatible with how the runner calls the ADC:

| aspect | baseline `src/ADC/TI_ADC` | v1 `src/ADC_model_HSY_2609/TI_ADC` | effect on runner |
|---|---|---|---|
| `ti_adc_top(M,VL,VH,N,SarPerTah,Oversample[,SampleRateHz])` | 6 args | 7th optional arg `SampleRateHz` (default 56e9) | runner passes 6 args → default |
| `convertOneBlockFast(w,phase)` | returns `Dout_dec` | returns `[Dout_dec, sampling]` | runner takes 1 output → `Dout_dec` |
| clock `generateSampleIndex` | integer (rounded) index | fractional index (no rounding) | ideal clock + phase=1 → integer → same |
| `sampleInput` | integer indexing | linear interpolation | fraction = 0 → same sample |
| SAR DAC scale | `(VH-VL)/C_tot`, C_tot=128·Cu (dummy) | `(2^N-1)·lsb/C_tot`, C_tot=127·Cu (no dummy) | both = 0.0625 exactly (VL=-4,VH=4,N=7) |
| sampling thermal noise | absent | present but **default off**, consumes no RNG when off | no effect |

Runner call sites (all with `setInputMargin(0)`, `convertOneBlockFast(w,1)`):
`src/cdr_three_loop_ppm/cdr_three_loop_ppm.m:334-367`, `:1343-1355`, `:1414-1420`.

## Layer 1 — ADC unit equivalence probe (`../adc_equivalence/`)

`probe_adc_equiv.m` builds the runner's ideal ADC (`M=64, VL=-4, VH=4, N=7,
SarPerTah=8, Oversample=128, InputMargin=0`) and quantizes an identical battery
of **1,157,162** input voltages through the baseline and the v1 ADC:

- a fine ramp over `[-4.5, 4.5]` (beyond range, exercises every code boundary
  and both clip rails),
- the exact code-threshold ladder `VL+code*lsb` plus tight neighbours
  (`±1e-12/±eps/±1e-9/±1e-6`),
- 256,000 real cached CTLE samples.

Result: **0 mismatches, max abs code diff = 0.** (`adc_probe_old.mat`,
`adc_probe_new.mat`.)

## Layer 2 — full-pipeline comparison (this directory)

`cdr_three_loop_ppm` was run under the baseline suite and the v1 suite in
separate MATLAB sessions with identical options, and the saved `result` structs
were deep-compared with `compare_ppm_results.m`.

Config: `FreqOffsetPpm ∈ {-100, +100, 0}`, `NumBlock = 8000`,
`StartPhaseStep = 16` (8 phases), `SaveOutputs = false`. All three lock 8/8.

| ppm | leaves compared | identical | differing | differing fields |
|---:|---:|---:|---:|---|
| -100 | 344 | 335 | 9 | 9 self-referential output-path strings |
| +100 | 344 | 335 | 9 | 9 self-referential output-path strings |
| 0 | 296 | 287 | 9 | 9 self-referential output-path strings |

The 9 differing leaves in every case are `*FigurePath` / `ResultMatPath`
strings that point at each suite's own `result/` directory (expected by design).
**Every numeric/logical trace is bit-identical**: lock flags, frequency-state
mean/traces, rotation period, eye-phase, FFE coefficient traces, dLev, SNR,
slew utilization, stage-gate blocks, and all diagnostics. Per-run reports:
`consistency_report_{m100,p100,p0}_8000.txt` and
`consistency_report_p100_1500.txt`.

## Reproduce

```matlab
% Layer 1 (two clean sessions):
addpath('validation/CDR/test_cdr_three_loop_wi_ppm_v1/result/adc_equivalence');
probe_adc_equiv('src/ADC/TI_ADC',                 '.../adc_probe_old.mat');   % session A
probe_adc_equiv('src/ADC_model_HSY_2609/TI_ADC',  '.../adc_probe_new.mat');   % session B
% then load both and compare `codes`.

% Layer 2 (two clean sessions), then compare:
% session A: addpath test_cdr_three_loop_wi_ppm;    setup_cdr_three_loop_wi_ppm_paths();    cdr_three_loop_ppm(...)
% session B: addpath test_cdr_three_loop_wi_ppm_v1; setup_cdr_three_loop_wi_ppm_v1_paths(); cdr_three_loop_ppm(...)
compare_ppm_results('.../cmp_base_p100.mat', '.../cmp_v1_p100.mat', '.../report.txt');
```
