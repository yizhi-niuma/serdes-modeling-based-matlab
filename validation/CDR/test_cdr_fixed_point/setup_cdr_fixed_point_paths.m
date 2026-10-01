function paths = setup_cdr_fixed_point_paths()
%SETUP_CDR_FIXED_POINT_PATHS 为定点化套件装配所需路径并返回关键目录。
%
%   本套件自身不跑仿真：它消费 ppm 套件已经产出的 result MAT，用真实动态范围
%   反推定点字长。因此这里既要把被测模型 (src/CDR) 上路径，也要把 ppm 套件的
%   result 目录解析出来。

thisDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(fileparts(fileparts(thisDir)));

paths = struct();
paths.RepoRoot = repoRoot;
paths.SuiteDir = thisDir;
paths.ResultDir = fullfile(thisDir, 'result');

% 浮点参考模型。定点实现将来与它逐块对拍，所以必须同时在路径上。
paths.SrcCdrDir = fullfile(repoRoot, 'src', 'CDR');

% ppm 套件的 result 目录：范围普查的数据来源。
paths.PpmSuiteDir = fullfile(repoRoot, 'validation', 'CDR', 'test_cdr_three_loop_wi_ppm');
paths.PpmResultDir = fullfile(paths.PpmSuiteDir, 'result');

addIfPresent(paths.SrcCdrDir);
addIfPresent(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addIfPresent(thisDir);

if ~exist(paths.ResultDir, 'dir')
    mkdir(paths.ResultDir);
end
end

function addIfPresent(folder)
if exist(folder, 'dir')
    addpath(folder);
end
end
