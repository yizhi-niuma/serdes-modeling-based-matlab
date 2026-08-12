# Validation

## 2026-08-12 directory-migration validation

- MATLAB static syntax checking completed successfully for all scripts under `validation/`.
- All 13 moved validation scripts were run in separate MATLAB batch sessions and returned exit code 0.
- TI ADC validation successfully loaded `data/ADC/TI_ADC/ctle_out.csv`.
- Newly generated plots, MAT files, and text reports were written under the corresponding module paths in `results/`.
- The run summary is available at `results/validation_summary.csv`.

These scripts provide behavioral and visual validation. Unless a script contains
explicit assertions or other machine-checkable acceptance limits, a successful
execution alone does not make it an automated regression test.
