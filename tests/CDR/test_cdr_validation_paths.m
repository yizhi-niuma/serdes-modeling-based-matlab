function test_cdr_validation_paths
%TEST_CDR_VALIDATION_PATHS Validate scoped setup after suite relocation.

originalPath = path;
originalPwd = pwd;
cleanup = onCleanup(@() restoreEnvironment(originalPath, originalPwd)); %#ok<NASGU>
thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
suiteRoot = fullfile(repoRoot, 'validation', 'CDR', 'test_cdr_dlev_cdrffe');

restoredefaultpath;
addpath(suiteRoot, '-begin');
cd(fullfile(repoRoot, 'src'));
pwdBefore = pwd;
p = setup_cdr_dlev_cdrffe_paths();

expected = struct( ...
    'Root', suiteRoot, ...
    'RepoRoot', repoRoot, ...
    'CdrValidationDir', fullfile(repoRoot, 'validation', 'CDR'), ...
    'V3Dir', fullfile(suiteRoot, 'src', 'cdr_dlev_cdrffe_sslms_v3'), ...
    'HelpersDir', fullfile(suiteRoot, 'helpers'), ...
    'DebugDir', fullfile(suiteRoot, 'debug'), ...
    'LegacyDir', fullfile(suiteRoot, 'legacy'), ...
    'ArchiveDir', fullfile(suiteRoot, 'archive'), ...
    'ResultDir', fullfile(suiteRoot, 'result'), ...
    'AdcSourceDir', fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'), ...
    'CdrSourceDir', fullfile(repoRoot, 'src', 'CDR'));
fields = fieldnames(expected);
assert(isempty(setxor(fieldnames(p), fields)), 'Unexpected setup path fields.');
for k = 1:numel(fields)
    name = fields{k};
    assertSamePath(p.(name), expected.(name));
    assert(isfolder(p.(name)), 'Expected directory is missing: %s', p.(name));
    assert(~samePath(p.(name), pwd), '%s unexpectedly depends on the CWD.', name);
end
assert(strcmp(pwd, pwdBefore), 'Runtime setup changed the current directory.');

assertWhich('cdr_dlev_cdrffe_sslms_v3', fullfile(p.V3Dir, 'cdr_dlev_cdrffe_sslms_v3.m'));
helperNames = {'build_cdr_ffe_eye', 'build_cdr_ffe_eye_pair', ...
    'detect_pi_center_touch_lock', 'ffe_freeze_monitor', ...
    'plot_cdr_ffe_eyes', 'select_slowest_pi_capture'};
for k = 1:numel(helperNames)
    assertWhich(helperNames{k}, fullfile(p.HelpersDir, [helperNames{k} '.m']));
    assert(~isfile(fullfile(p.Root, [helperNames{k} '.m'])), ...
        'Relocated helper remains at suite root: %s', helperNames{k});
end
assertWhich('sar_adc_core', fullfile(p.AdcSourceDir, 'sar_adc_core.m'));
assert(~isfile(fullfile(p.Root, 'cdr_dlev_cdrffe_sslms_v3.m')), ...
    'The v3 entry point remains at the suite root.');

% Runtime scope intentionally excludes historical fixtures and generated output.
assertPathExcludes({p.DebugDir, p.LegacyDir, p.ArchiveDir, p.ResultDir});
clear detect_pi_dither_lock
assert(isempty(which('detect_pi_dither_lock')), ...
    'Legacy dither detector resolved in runtime scope.');
runtimePath = path;
p2 = setup_cdr_dlev_cdrffe_paths();
assert(strcmp(path, runtimePath), 'Repeated runtime setup changed the path.');
assert(isequal(p, p2));
assert(strcmp(pwd, pwdBefore), 'Repeated runtime setup changed the current directory.');

restoredefaultpath;
addpath(suiteRoot, '-begin');
debugPwd = pwd;
pDebug = setup_cdr_dlev_cdrffe_paths('debug');
debugNames = {'debug_eye_vs_phase', 'debug_frontend_scale', ...
    'debug_measured_anchor', 'debug_v3_scurve'};
for k = 1:numel(debugNames)
    assertWhich(debugNames{k}, fullfile(pDebug.DebugDir, [debugNames{k} '.m']));
end
assertPathExcludes({pDebug.LegacyDir, pDebug.ArchiveDir, pDebug.ResultDir});
assert(strcmp(pwd, debugPwd), 'Debug setup changed the current directory.');

restoredefaultpath;
addpath(suiteRoot, '-begin');
legacyPwd = pwd;
pLegacy = setup_cdr_dlev_cdrffe_paths('legacy');
legacyNames = {'cdr_dlev_cdrffe_sslms', 'cdr_dlev_cdrffe_sslms_v1', ...
    'cdr_dlev_cdrffe_sslms_v2', 'detect_pi_dither_lock', ...
    'probe_anchor_pothole', 'probe_bimodal_detail', 'verify_anchor_recipe'};
for k = 1:numel(legacyNames)
    assertWhich(legacyNames{k}, fullfile(pLegacy.LegacyDir, [legacyNames{k} '.m']));
end
assertPathExcludes({pLegacy.DebugDir, pLegacy.ArchiveDir, pLegacy.ResultDir});
assert(strcmp(pwd, legacyPwd), 'Legacy setup changed the current directory.');

restoredefaultpath;
addpath(suiteRoot, '-begin');
pAll = setup_cdr_dlev_cdrffe_paths('all');
assertWhich(debugNames{1}, fullfile(pAll.DebugDir, [debugNames{1} '.m']));
assertWhich(legacyNames{1}, fullfile(pAll.LegacyDir, [legacyNames{1} '.m']));
assertPathExcludes({pAll.ArchiveDir, pAll.ResultDir});
assertThrows(@() setup_cdr_dlev_cdrffe_paths('unknown'), ...
    'setup_cdr_dlev_cdrffe_paths:InvalidScope');
assertThrows(@() setup_cdr_dlev_cdrffe_paths(42), ...
    'setup_cdr_dlev_cdrffe_paths:InvalidScope');

runSmokeIfCacheExists(repoRoot, suiteRoot);
fprintf('test_cdr_validation_paths passed.\n');
end

function runSmokeIfCacheExists(repoRoot, suiteRoot)
cacheDir = fullfile(repoRoot, 'validation', 'CDR', 'test_cdr', 'result', ...
    'channel_ctle_cosim_prbs22');
cachePath = fullfile(cacheDir, 'channel_ctle.mat');
txPath = fullfile(cacheDir, 'tx_prbs22.mat');
if ~(isfile(cachePath) && isfile(txPath))
    fprintf('test_cdr_validation_paths: smoke skipped (default cache absent).\n');
    return;
end
restoredefaultpath;
v3Dir = fullfile(suiteRoot, 'src', 'cdr_dlev_cdrffe_sslms_v3');
addpath(v3Dir, '-begin');
cd(fullfile(repoRoot, 'src'));
pwdBefore = pwd;
opts = struct('AnalysisNumUi', 64 * 64 + 512, ...
    'StartPhaseList', 20, 'DlevOuterInit', 48, 'DlevInnerInit', 16, ...
    'SaveOutputs', false, 'EyeDiagramEnable', false, ...
    'FfeFreezeEnable', false);
[~, result] = evalc('cdr_dlev_cdrffe_sslms_v3(opts)');
assert(result.NumBlocks == 64, 'Smoke run did not execute exactly 64 blocks.');
assertSamePath(result.CachePath, cachePath);
expectedResultDir = fullfile(suiteRoot, 'result', 'cdr_dlev_cdrffe_sslms_v3');
assertSamePath(fileparts(result.ResultMatPath), expectedResultDir);
assert(strcmp(pwd, pwdBefore), 'The v3 entry point changed the current directory.');

diagnosticDir = fullfile(repoRoot, 'results', 'CDR', ...
    'dlev_init_phase_diagnostic');
addpath(diagnosticDir, '-begin');
opts = struct('CosimDir', 'channel_ctle_cosim_prbs22', ...
    'TxFile', 'tx_prbs22.mat', 'AnalysisNumUi', 64 * 64 + 512, ...
    'StartPhaseList', 20, 'FfeFreezeEnable', false, ...
    'SaveOutputs', false, 'EyeDiagramEnable', false);
[~, diagnosticResult] = evalc('cdr_anchor_control(opts)');
assert(diagnosticResult.NumBlocks == 64, ...
    'Diagnostic smoke run did not execute exactly 64 blocks.');
assertSamePath(diagnosticResult.CachePath, cachePath);
expectedDiagnosticResultPath = fullfile(diagnosticDir, 'result', ...
    'cdr_dlev_cdrffe_sslms_v3', 'cdr_dlev_cdrffe_sslms_v3_result.mat');
assertSamePath(diagnosticResult.ResultMatPath, expectedDiagnosticResultPath);
assert(strcmp(pwd, pwdBefore), ...
    'The diagnostic entry point changed the current directory.');
end

function assertWhich(name, expected)
actual = which(name);
assert(~isempty(actual), '%s did not resolve.', name);
assertSamePath(actual, expected);
end

function assertPathExcludes(directories)
entries = strsplit(path, pathsep);
for k = 1:numel(directories)
    present = any(cellfun(@(entry) samePath(entry, directories{k}), entries));
    assert(~present, 'Unexpected directory on path: %s', directories{k});
end
end

function assertSamePath(actual, expected)
assert(samePath(actual, expected), 'Path mismatch. Expected "%s", got "%s".', ...
    expected, actual);
end

function tf = samePath(left, right)
left = char(java.io.File(left).getCanonicalPath());
right = char(java.io.File(right).getCanonicalPath());
if ispc
    tf = strcmpi(left, right);
else
    tf = strcmp(left, right);
end
end

function assertThrows(action, expectedId)
didThrow = false;
try
    action();
catch caught
    didThrow = true;
    assert(strcmp(caught.identifier, expectedId), ...
        'Expected error %s, received %s.', expectedId, caught.identifier);
end
assert(didThrow, 'Expected error %s was not thrown.', expectedId);
end

function restoreEnvironment(originalPath, originalPwd)
path(originalPath);
cd(originalPwd);
end
