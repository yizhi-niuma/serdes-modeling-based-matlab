# Archived working artifacts

This directory stores non-executable investigation artifacts retained for traceability. The `_scan*.txt` files are historical source-scan outputs and are not inputs to validation.

Archive contents are intentionally outside the default MATLAB runtime path. Do not add the suite recursively with `genpath`; use `setup_cdr_dlev_cdrffe_paths` and its explicit `runtime`, `debug`, `legacy`, or `all` scopes as appropriate.
