function paths = setup_cdr_three_loop_wi_ppm_paths(scope)
%SETUP_CDR_THREE_LOOP_WI_PPM_PATHS Configure paths for the ppm CDR suite.
%   PATHS = SETUP_CDR_THREE_LOOP_WI_PPM_PATHS() configures runtime paths for
%   the three-loop CDR-with-frequency-offset validation suite.
%   PATHS = SETUP_CDR_THREE_LOOP_WI_PPM_PATHS(SCOPE) additionally accepts the
%   'all' scope, which is currently identical to the runtime scope.
%
%   The suite reuses the sibling test_cdr_dlev_cdrffe helpers (modal lock and
%   slowest-capture selection) rather than duplicating them; only the ppm
%   runner and its result tree live under this directory.

if nargin < 1
    scope = 'runtime';
end
if isstring(scope)
    if ~isscalar(scope)
        error('setup_cdr_three_loop_wi_ppm_paths:InvalidScope', ...
            'scope must be ''runtime'' or ''all''.');
    end
    scope = char(scope);
end
if ~(ischar(scope) && isrow(scope))
    error('setup_cdr_three_loop_wi_ppm_paths:InvalidScope', ...
        'scope must be ''runtime'' or ''all''.');
end
scope = lower(strtrim(scope));
validScopes = {'runtime', 'all'};
if ~any(strcmp(scope, validScopes))
    error('setup_cdr_three_loop_wi_ppm_paths:InvalidScope', ...
        'scope must be ''runtime'' or ''all''.');
end

thisFile = mfilename('fullpath');
rootDir = fileparts(thisFile);
cdrValidationDir = fileparts(rootDir);
repoRoot = fileparts(fileparts(cdrValidationDir));

paths = struct();
paths.Root = rootDir;
paths.CdrValidationDir = cdrValidationDir;
paths.RepoRoot = repoRoot;
paths.RunnerDir = fullfile(rootDir, 'src', 'cdr_three_loop_ppm');
paths.SiblingSuiteDir = fullfile(cdrValidationDir, 'test_cdr_dlev_cdrffe');
paths.SiblingHelpersDir = fullfile(paths.SiblingSuiteDir, 'helpers');
paths.ResultDir = fullfile(rootDir, 'result');
paths.AdcSourceDir = fullfile(repoRoot, 'src', 'ADC', 'TI_ADC');
paths.CdrSourceDir = fullfile(repoRoot, 'src', 'CDR');

runtimeDirs = {paths.Root, paths.RunnerDir, paths.SiblingHelpersDir, ...
    paths.AdcSourceDir, paths.CdrSourceDir};
for index = 1:numel(runtimeDirs)
    requireDirectory(runtimeDirs{index});
end

% Add explicit runtime paths with TI-ADC/CDR source precedence, mirroring the
% sibling suite convention. The setup never changes pwd or calls savepath.
addpath(paths.Root, '-begin');
addpath(paths.RunnerDir, '-begin');
addpath(paths.SiblingHelpersDir, '-begin');
addpath(paths.CdrSourceDir, '-begin');
addpath(paths.AdcSourceDir, '-begin');
end

function requireDirectory(directoryPath)
if ~exist(directoryPath, 'dir')
    error('setup_cdr_three_loop_wi_ppm_paths:MissingDir', ...
        'Required directory does not exist: "%s".', directoryPath);
end
end
