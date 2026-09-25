# CDR / dlev / CDR-FFE validation

## Directory layout

| Location | Purpose |
|---|---|
| `setup_cdr_dlev_cdrffe_paths.m` | Session-local, explicit MATLAB path setup anchored to this file, not the current working directory |
| `src/cdr_dlev_cdrffe_sslms_v3/` | Current v3 runner, including fixed/live training-reference options |
| `helpers/` | Six current runtime helpers: modal lock, first-capture selection, freeze monitor, eye construction and rendering |
| `debug/` | Standalone front-end scale, phase/eye and frozen-state S-curve diagnostics |
| `legacy/` | Older runners, superseded adjacent-pair detector, and historical anchor probes; opt-in only |
| `archive/` | Inert old `_scan*.txt` source-search excerpts |
| `result/` | Existing generated outputs and versioned implementation notes; locations are unchanged |

No duplicate v3 function is left in the root directory. Do not use recursive `genpath` over this entire tree: it would also expose historical scripts, result-local diagnostic copies and potentially duplicate names. The canonical automated tests are in the repository's `tests/CDR`, not the separate untracked `newtests` scratch area.

## Start current v3

From the repository root:

```matlab
addpath(fullfile(pwd, 'validation', 'CDR', 'test_cdr_dlev_cdrffe'));
paths = setup_cdr_dlev_cdrffe_paths();  % default scope: runtime
result = cdr_dlev_cdrffe_sslms_v3();
```

From another working directory, use an absolute path to the suite root:

```matlab
addpath('C:\Work\MatLab_Lib\validation\CDR\test_cdr_dlev_cdrffe');
paths = setup_cdr_dlev_cdrffe_paths();
result = cdr_dlev_cdrffe_sslms_v3('SaveOutputs', false);
```

The relocated v3 can also bootstrap itself when only its entry directory is on the MATLAB path. The setup function does not change `pwd`, call `savepath`, modify user settings, or write results. It adds only explicit runtime paths plus the repository's TI-ADC and CDR source directories; it does not recursively add the repository's other ADC implementations.

Default output remains:

```text
validation/CDR/test_cdr_dlev_cdrffe/result/cdr_dlev_cdrffe_sslms_v3/
```

It does **not** move under `src/` or depend on MATLAB's current directory. `ResultDir` and `SaveOutputs` keep their existing semantics. Cache lookup remains under `validation/CDR/test_cdr/result/`.

## Optional diagnostic / legacy scope

```matlab
setup_cdr_dlev_cdrffe_paths('debug');   % runtime + standalone debug functions
setup_cdr_dlev_cdrffe_paths('legacy');  % runtime + historical runners/detector
setup_cdr_dlev_cdrffe_paths('all');     % runtime + debug + legacy
```

Scopes add paths to the current MATLAB session; they are not a path sandbox and do not remove paths the caller added earlier. In a fresh session, default runtime setup does not add debug, legacy, archive or result directories. Check actual resolution if other copies were previously added:

```matlab
which cdr_dlev_cdrffe_sslms_v3 -all
which sar_adc_core -all
```

The expected v3 location is `src/cdr_dlev_cdrffe_sslms_v3/cdr_dlev_cdrffe_sslms_v3.m`. The expected SAR implementation is the repository's `src/ADC/TI_ADC/sar_adc_core.m`.

Debug functions are independent studies, not automatically executed by the runner. Their own hard-coded cache or detector choices must be reviewed for the intended experiment. Legacy anchor probes predate independent `FfeTrainingOuterRef/FfeTrainingInnerRef`; changing only `Dlev*Init` no longer changes the current FFE training reference. See the category READMEs before using them as evidence.

## Automated tests

From the repository root:

```matlab
addpath(fullfile(pwd, 'tests', 'CDR'));
test_cdr_validation_paths;
test_detect_pi_center_touch_lock;
test_select_slowest_pi_capture;
test_loop_monitor;
test_build_cdr_ffe_eye;
test_build_cdr_ffe_eye_pair;
test_cdr_ffe_training_reference;
test_cdr_ffe_live_training_reference;
test_cdr_ffe_freeze_integration;
test_detect_pi_dither_lock;  % explicitly opts into the legacy detector
```

Each test initializes the paths it needs; tests no longer require the old root-level v3 file. The path test checks non-repository working directories, runtime/helper resolution, optional scopes and the unchanged output/cache roots. Existing numerical tests retain their original parameter fixtures and assertions.

## Reorganization scope

This is a file/path refactor only. No loop equations, numeric defaults, golden alignment, ADC conversion, FFE coefficient update, reference-mode choice, freeze/lock threshold or result-data semantics are intentionally changed. The result tree retains its task-entry state, including pre-existing modified files and deletions; this refactor does not regenerate, delete, relocate, or restore result artifacts. In particular, the already-deleted `debug_eye_vs_phase.png`, `debug_frontend_scale.png`, `debug_scurve_frozen_states.png`, and `v3_phasecode_convergence_fixed.png` under the v3 result directory are not restored by this task. Historical documents may name old paths as part of past experiment records; use the setup entry above for current invocation.
