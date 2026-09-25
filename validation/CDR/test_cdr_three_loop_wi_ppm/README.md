# CDR three-loop capture under a frequency offset (ppm)

Validates whether the three concurrent CDR loops (SS-MMPD timing, dLev level,
CDR-FFE SS-LMS) achieve all-initial-phase capture when the receiver sampling
clock has a frequency offset, as required by Ethernet (+/-100 ppm).

## Directory layout

| Location | Purpose |
|---|---|
| `setup_cdr_three_loop_wi_ppm_paths.m` | Session-local explicit path setup anchored to this file |
| `src/cdr_three_loop_ppm/cdr_three_loop_ppm.m` | The ppm runner (derived from `cdr_dlev_cdrffe_sslms_v4`) |
| `result/cdr_three_loop_ppm_p100/` | +100 ppm outputs (figures, `.mat`, `ppm_lock_summary.csv`, notes) |
| `result/cdr_three_loop_ppm_m100/` | -100 ppm outputs |
| `result/cdr_three_loop_ppm_p0/` | 0 ppm baseline / regression-sentinel outputs |

The runner reuses the sibling suite helpers `detect_pi_center_touch_lock` and
`select_slowest_pi_capture` (from `../test_cdr_dlev_cdrffe/helpers`) rather than
duplicating them; the setup adds that directory to the path.

## Frequency-offset injection (scheme A, RX-clock model)

The cached TX waveform is never resampled: one data symbol always occupies
exactly 128 cached samples. The offset appears as the RX sampling step, so each
RX UI the read pointer advances `128*(1+delta)` cached samples with
`delta = FreqOffsetPpm*1e-6`. Because `128*(1+delta)` is not an integer, the
exact cumulative drift is kept in floating point and rounded to the 128x sample
grid only once, when the ADC block start is formed
(`round(driftRatePerBlockCode*(blockIndex-1))`). Rounding the cumulative value
(never the per-block increment) bounds the quantization error to `+/-0.5`
sample `= +/-1/128 UI`, on par with the PI resolution. Within one 64-UI block
the 64 samples are still 128 apart; the `<=0.82` sample block-internal drift is
not modelled. `cdr_top` never sees the offset — it is purely a caller-side
address term, so the DSP core stays frequency-offset agnostic.

At 100 ppm the steady timing rate the loop must supply is
`0.8192 code/block` (one full 128-code PI rotation every `156.25` blocks).

## Lock criteria (switchable; the zero-offset one is retained)

- `FreqOffsetPpm == 0`: the modal center-touch criterion
  (`detect_pi_center_touch_lock`) as in v4 -- the PI code dithers around one
  fixed code.
- `FreqOffsetPpm ~= 0`: two frequency-domain criteria added to
  `src/CDR/loop_monitor.m`:
  1. `loop_monitor.detectFrequencyStateLock` -- the loop integrator frequency
     state has a constant tail-window mean (first/second half agree, low std)
     whose magnitude matches the expected drift rate.
  2. `loop_monitor.detectRotationPeriodLock` -- the PI code rotation period
     (blocks per UI slip) is constant (low coefficient of variation), i.e. the
     loop is tracking rather than still acquiring.

  Both must hold for a start phase to be declared locked.

The `result.PiTrackingErrorTrace` and `cdr_pi_tracking_error.fig` show the PI
actual code minus the ideal offset-compensated code (a diagnostic only, not a
lock criterion): flat once tracked, a ramp while still acquiring.

## Two-stage mu downshift (cold `planB` start works)

The runner defaults to `FfeInitMode = 'planB'` (cold start `[0 0 1 0 0 0]`) and
still reaches 32/32 at both offset signs. An earlier revision of this file
claimed a warm `planA` start was *required* for negative ppm; that was wrong.
The real obstacle was the stage-1 mu-downshift gate, not the initial taps.

- Stage 1 (`capture -> settle`, both loops) is gated on eye quality:
  `SettleGate = 'snr'` triggers when the EWMA of the per-block decision-directed
  SNR `10*log10(mean(decision^2)/mean(sliceError^2))` crosses
  `SnrSettleThresholdDb` (15 dB, `SnrSettleAlpha = 1/128`,
  `SnrSettleMinBlock = 200`).
  The legacy gate (`SettleGate = 'dlev'`) is an outer-dLev displacement test,
  i.e. an implicit drift-rate threshold `DlevSettleTol/DlevSettleWindow`
  `= 0.031 code/block`. The measured cold-start dLev drift is ~`0.012`, so it
  declared settle at block 84 with 59% of the dLev trajectory still ahead and cut
  the FFE step 20x while the eye was closed -- which is what made `-100 ppm` fail
  from every start phase.
- Stage 2 (`settle -> PVT tracking`) is the existing phase-band lock gate
  (`FfeGate*`) and drops both loops again, FFE to `FfeStepSizePvtTrack` and dLev
  to `DlevStepSizePvtTrack`.
- `FfeStepSize` defaults to `0.001` here, 4x below the `cdr_top` library default.
  The main tap is frozen (`FfeAdaptEnableMask = [1 1 0 1 1 1]`), so the loop
  reshapes the pulse only through pre/post taps, which walks the effective cursor
  and moves the MMPD zero. Locked-phase spread scales with the capture step:
  `3/6/12/21` code at 0 ppm for `0.001/0.002/0.004/0.008`.

`0 ppm` must be run alongside `+/-100 ppm`: it is the case most sensitive to the
downshift actually happening and to cursor walk, so it is the regression sentinel
for this policy. Tightening the legacy gate instead passes `+/-100 ppm` while
pushing the `0 ppm` spread to 13-15 code (limit `captureBandHalfWidth = 6`).

## Run

From the repository root:

```matlab
addpath(fullfile(pwd, 'validation', 'CDR', 'test_cdr_three_loop_wi_ppm'));
setup_cdr_three_loop_wi_ppm_paths();
result = cdr_three_loop_ppm('FreqOffsetPpm',  100);   % +100 ppm, all 8 starts
result = cdr_three_loop_ppm('FreqOffsetPpm', -100);   % -100 ppm
result = cdr_three_loop_ppm('FreqOffsetPpm',    0);   % 0 ppm sentinel
```

Full acceptance sweep (32 start phases, the configuration the committed results
were produced with -- all three give `AllPhaseLock = 1`):

```matlab
for ppm = [-100, 100, 0]
    cdr_three_loop_ppm('FreqOffsetPpm', ppm, 'NumBlock', 8000, ...
        'StartPhaseStep', 4, 'SaveOutputs', true);
end
```

Fast smoke:

```matlab
cdr_three_loop_ppm('FreqOffsetPpm', 100, 'NumBlock', 4000, ...
    'StartPhaseList', [16 64], 'SaveOutputs', false);
```

`NumBlock` derives `AnalysisNumUi` (including the two-sided ppm drift margin)
automatically. `StartPhaseStep` (default 16 -> 8 starts) or an explicit
`StartPhaseList` selects the initial-phase sweep. Cache lookup stays under
`validation/CDR/test_cdr/result/<CosimDir>/channel_ctle.mat`.
