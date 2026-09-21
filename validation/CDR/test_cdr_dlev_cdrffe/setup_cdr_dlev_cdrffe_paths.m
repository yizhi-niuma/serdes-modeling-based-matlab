function paths = setup_cdr_dlev_cdrffe_paths(scope)
%SETUP_CDR_DLEV_CDRFFE_PATHS Configure paths for the CDR/DLEV/CDR-FFE suite.
%   PATHS = SETUP_CDR_DLEV_CDRFFE_PATHS() configures runtime paths.
%   PATHS = SETUP_CDR_DLEV_CDRFFE_PATHS(SCOPE) additionally configures the
%   requested 'debug', 'legacy', or 'all' path scope.

if nargin < 1
    scope = 'runtime';
end
if isstring(scope)
    if ~isscalar(scope)
        error('setup_cdr_dlev_cdrffe_paths:InvalidScope', ...
            'scope must be ''runtime'', ''debug'', ''legacy'', or ''all''.');
    end
    scope = char(scope);
end
if ~(ischar(scope) && isrow(scope))
    error('setup_cdr_dlev_cdrffe_paths:InvalidScope', ...
        'scope must be ''runtime'', ''debug'', ''legacy'', or ''all''.');
end
scope = lower(strtrim(scope));
validScopes = {'runtime', 'debug', 'legacy', 'all'};
if ~any(strcmp(scope, validScopes))
    error('setup_cdr_dlev_cdrffe_paths:InvalidScope', ...
        'scope must be ''runtime'', ''debug'', ''legacy'', or ''all''.');
end

thisFile = mfilename('fullpath');
rootDir = fileparts(thisFile);
cdrValidationDir = fileparts(rootDir);
repoRoot = fileparts(fileparts(cdrValidationDir));

paths = struct();
paths.Root = rootDir;
paths.CdrValidationDir = cdrValidationDir;
paths.RepoRoot = repoRoot;
paths.V3Dir = fullfile(rootDir, 'src', 'cdr_dlev_cdrffe_sslms_v3');
paths.HelpersDir = fullfile(rootDir, 'helpers');
paths.DebugDir = fullfile(rootDir, 'debug');
paths.LegacyDir = fullfile(rootDir, 'legacy');
paths.ArchiveDir = fullfile(rootDir, 'archive');
paths.ResultDir = fullfile(rootDir, 'result');
paths.AdcSourceDir = fullfile(repoRoot, 'src', 'ADC', 'TI_ADC');
paths.CdrSourceDir = fullfile(repoRoot, 'src', 'CDR');

runtimeDirs = {paths.Root, paths.HelpersDir, paths.V3Dir, ...
    paths.AdcSourceDir, paths.CdrSourceDir};
for index = 1:numel(runtimeDirs)
    requireDirectory(runtimeDirs{index});
end
if any(strcmp(scope, {'debug', 'all'}))
    requireDirectory(paths.DebugDir);
end
if any(strcmp(scope, {'legacy', 'all'}))
    requireDirectory(paths.LegacyDir);
end

% Add optional scopes first so runtime dependencies retain precedence.
if any(strcmp(scope, {'debug', 'all'}))
    addpath(paths.DebugDir, '-begin');
end
if any(strcmp(scope, {'legacy', 'all'}))
    addpath(paths.LegacyDir, '-begin');
end
addpath(paths.Root, '-begin');
addpath(paths.HelpersDir, '-begin');
addpath(paths.V3Dir, '-begin');
addpath(paths.CdrSourceDir, '-begin');
addpath(paths.AdcSourceDir, '-begin');
end

function requireDirectory(directoryPath)
if ~exist(directoryPath, 'dir')
    error('setup_cdr_dlev_cdrffe_paths:MissingDir', ...
        'Required directory does not exist: "%s".', directoryPath);
end
end
