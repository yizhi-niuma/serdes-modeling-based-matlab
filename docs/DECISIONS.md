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
