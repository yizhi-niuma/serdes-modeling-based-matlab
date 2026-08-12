# Current State

Updated: 2026-08-12

## Current status

- Existing reusable SerDes model code is organized under `src/`.
- All 13 existing `test*.m` visualization and behavioral-check scripts were moved from `src/` to the mirrored `validation/` hierarchy.
- The TI ADC CTLE input is stored at `data/ADC/TI_ADC/ctle_out.csv`.
- Validation outputs are written to the mirrored module hierarchy under `results/`.

## Validation status

- MATLAB syntax checking passed for all moved validation scripts.
- All 13 validation scripts completed successfully in independent MATLAB batch sessions on 2026-08-12.
- Per-script exit codes are recorded in `results/validation_summary.csv`.

## Current blockers

- No blocker is known for the completed directory migration.

## Recommended next step

- Add true automated regression tests under `tests/` with explicit assertions and numeric tolerances for key model behavior.
