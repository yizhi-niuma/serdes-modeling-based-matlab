# Decisions

## 2026-08-12: Separate implementation, validation, data, and results

- Reusable MATLAB model code belongs in `src/`.
- Plot-oriented and exploratory `test*.m` scripts belong in `validation/`, using a directory hierarchy that mirrors `src/`.
- Automated regression tests with explicit machine-checkable pass/fail criteria belong in `tests/`.
- Fixed inputs and reference datasets belong in `data/`.
- Generated outputs belong in `results/`, using a directory hierarchy that mirrors the related module.
- Validation scripts must resolve paths from their own file location and must not depend on MATLAB's current working directory.
