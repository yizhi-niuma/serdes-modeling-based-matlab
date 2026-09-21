# Debug diagnostics

This directory contains opt-in diagnostic scripts for inspecting the CDR/DLEV/FFE validation flow. These scripts are not part of the default runtime path.

Run a diagnostic from MATLAB after adding the suite root, or let the script bootstrap itself. The scripts call:

```matlab
setup_cdr_dlev_cdrffe_paths('debug')
```

Use the scoped setup rather than adding this tree with `genpath`; the default `runtime` scope intentionally excludes debug and legacy code.

These scripts retain historical, hardcoded diagnostic choices such as phase lists, analysis windows, cache assumptions, and reference values. They are investigative tools, not parameterized production runners, and their fixed values may need review when the active model changes.
