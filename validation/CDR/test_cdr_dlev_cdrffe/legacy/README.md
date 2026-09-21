# Legacy validation code

This directory preserves superseded CDR/DLEV/FFE runners, a historical lock detector, and anchor-probe utilities for comparison and provenance. It is excluded from the default runtime path.

Legacy runners bootstrap the opt-in scope with:

```matlab
setup_cdr_dlev_cdrffe_paths('legacy')
```

Use this scoped setup rather than adding the suite recursively with `genpath`. The normal `runtime` scope is intended for the current implementation.

The anchor probes describe experiments from an earlier coupling between DLEV initialization and the FFE training reference. That split has changed, so these probes may not represent current behavior unless explicit `FfeTraining*Ref` settings are reviewed. Each probe emits a historical-use warning for that reason.
