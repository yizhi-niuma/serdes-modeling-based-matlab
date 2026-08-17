# Architecture

## Scope

The current modeling scope documented here is limited to:

- `src/ADC`
- `src/CDR`

`src/LinkSim` is historical reference material. It is not the current model architecture and must not be used to infer current implementation status or requirements.

## Current subsystem flow

```text
Oversampled RX waveform
  -> sampling-phase/index generation (TI ADC clock and future CDR loop)
  -> TAH / TI ADC sampling
  -> SAR ADC conversion
  -> ADC code and reconstructed voltage

CDR data-symbol decision + edge-bit decision
  -> digital NRZ/PAM4 bang-bang phase detector
  -> block voter
  -> proportional-integral loop filter
  -> phase-interpolator code update
  -> local sample-index offset
  -> TI ADC clock/sampler
```

The ADC and CDR components exist, but a closed-loop CDR-to-ADC top-level model has not yet been assembled in the current source.

The CDR timing path will use a dedicated FFE rather than reusing the data-recovery
FFE/DFE path. That CDR FFE and its downstream slicers remain upstream of the
current digital CDR top level and are not yet implemented in the current source.

## ADC modules

### Current TI ADC stack: `src/ADC/TI_ADC`

- `sar_adc_core.m`: single-ended N-bit SAR ADC core.
  - Instantaneous scalar and vector conversion APIs.
  - Debug and fast conversion paths.
  - Capacitor mismatch, gain, comparator offset/noise, and per-bit offset controls.
  - Optional trace capture and input/range validation.
- `ti_adc_core.m`: M-lane time-interleaved ADC wrapper.
  - Owns one SAR ADC object per lane.
  - Converts one M-sample block at a time.
  - Supports lane gain, offset, skew metadata, capacitor mismatch, comparator noise, and bit offsets.
- `ti_adc_clock.m`: converts a CDR phase index into lane sample indices.
  - Supports common and per-phase fixed skew.
  - Supports Gaussian rising-edge jitter.
  - Can generate data and edge sample indices for CDR use.
- `ti_adc_top.m`: integrates `ti_adc_clock` and `ti_adc_core`.
  - Samples a waveform block using generated indices.
  - Supports local input margins for skew/jitter.
  - Adds TAH-group fixed skew and jitter configuration.
  - Exposes full and fast block-conversion paths.

### Clock-driven differential SAR channel: `src/ADC/SAR_ADC_channel`

- `sar_adc_tah.m`: differential track-and-hold state model.
- `sar_adc_core.m`: bit-by-bit differential SAR core driven by clock edges.
- `sar_adc_channel.m`: combines TAH and SAR core.

One conversion consists of a track/sample phase followed by N SAR decision phases. The previous output is held until conversion completes.

### Alternative SAR implementations

- `src/ADC/SAR_ADC_core`: single-ended SAR ADC plus dynamic/static metric utilities.
- `src/ADC/SAR_ADC_core_complex`: differential held-output SAR ADC plus metric utilities.
- `src/ADC/sar_adc_ref/sar_adc_nb.m`: older/reference multi-instance SAR model.

These implementations are retained for comparison. The TI ADC-local `sar_adc_core` is the implementation currently integrated into `ti_adc_core` and `ti_adc_top`.

### ADC waveform studies: `src/ADC/ADC_sample_CTEL_output`

This directory contains CTLE/TX/PRBS waveform inputs, eye-diagram and delay-analysis functions, SAR sampling analysis, and historical generated results. It is validation/study material rather than reusable ADC model code and should eventually move out of `src`.

## CDR modules: `src/CDR`

### `cdr_pd.m`

Digital bang-bang phase detector with:

- `nrz` and `pam4` modulation modes.
- Digital previous-data, current-edge-bit, and current-data inputs.
- NRZ transition-qualified `+1/-1` phase-error decisions.
- PAM4 encoding `00=-3`, `01=-1`, `10=+1`, and `11=+3`.
- PAM4 phase decisions restricted to the symmetric `00<->11` and `01<->10` transitions used by the reference RTL.
- Configurable output polarity, zero output for invalid transitions, compact input/result debug snapshots, and array-input support.
- A shared vectorized `bbpdFast` decision kernel using numeric mode selection and `int8` phase decisions; validated `bbpd` delegates to it and adds only input checks plus debug-state capture.
- Block-boundary overlap is owned by the future CDR top-level; `cdr_pd` remains stateless apart from its optional debug snapshot.
- An experimental PAM4 `mmpd` path using every non-static transition without RTL odd/even filtering; symmetric `0<->3` and `1<->2` transitions have weight 2 and all asymmetric transitions have weight 1.
- Validated `mmpd` and stateless `mmpdFast` paths with `int8` `-1/0/+1` decisions.
- CTLE-waveform MMPD validation explicitly composes the PD, voter, loop filter, and PI while carrying symbol/error overlap because the current `cdr_top` public input remains BBPD-specific.

Slicing and equalization are intentionally outside `cdr_pd`; the caller must provide hard digital symbol/edge decisions.

### `cdr_voter.m`

Stateless block voter with:

- One configurable parallel phase-decision block per call; the default block size is 64.
- Linear mode returning the signed sum of the `-1/0/+1` phase decisions.
- Constant mode returning `+K`, `-K`, or zero from the sign of the block sum; the default magnitude is 8.
- Validated `vote` and reduced-overhead single-block `voteFast` paths.
- `int16` accumulation and output.

The voter does not accumulate across blocks or model the RTL output register. The future CDR top-level owns block scheduling and pipeline latency.

### `cdr_loop.m`

Mode-independent proportional-integral loop filter with:

- One numeric voter error input and one integer PI code-increment output per update.
- Floating-point proportional, integral, and fractional-code residue calculations.
- Configurable integral-state saturation with reverse-error recovery.
- Configurable output slew limit with a default maximum PI increment of one code per block.
- Validated `update` and reduced-overhead scalar `updateFast` paths.

The loop filter does not own voter-mode selection, PI code wrap, UI-slip tracking, RTL fixed-point encoding, or a separate frequency-acquisition path.

### `cdr_pi.m`

Phase-interpolator behavioral model with:

- Configurable PI resolution and samples/UI.
- Wrapped PI code and accumulated full-UI slip.
- Ideal phase table.
- Default `a+b=constant` nonideal phase table.
- User-supplied INL or complete phase tables.
- Phase-to-floating-sample-index lookup.
- Full debug update and reduced-overhead `updateFast` paths.

### `cdr_top.m`

Block-rate digital integration model with:

- Explicit composition of configured `cdr_pd`, `cdr_voter`, `cdr_loop`, and `cdr_pi` objects.
- Cross-block previous-symbol state owned by the top level.
- One PD/voter/loop/PI update per configured voter block.
- The PI phase entering a block exposed separately from the updated phase used by the following block.
- Validated/debug and reduced-overhead fast processing paths.
- Coordinated reset of PD, loop-filter, PI, block index, and previous-symbol state.

The current top-level input is already-sliced digital data-symbol and edge-bit
blocks. It does not yet own waveform sampling, the dedicated CDR FFE, slicers,
or the TI ADC connection.

## Missing top-level CDR blocks

The current `src/CDR` directory does not yet contain:

- Frequency detector or acquisition aid.
- Direct closed-loop connection between `cdr_pd`, `cdr_pi`, and `ti_adc_top`.
- BER/jitter-tolerance top-level simulation.

## Repository organization debt within the current scope

- Generated result files remain under `src/ADC/**/result` and `src/CDR/result`.
- CTLE waveform studies and large CSV files remain under `src/ADC/ADC_sample_CTEL_output`.
- Several SAR ADC implementations overlap in responsibility.
- Some Chinese comments have encoding corruption and should be normalized separately.
