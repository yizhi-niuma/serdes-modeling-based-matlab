function result = fx_range_census(varargin)
%FX_RANGE_CENSUS 定点化第 0 步：从已有 ppm result MAT 统计各节点动态范围。
%
%   RESULT = FX_RANGE_CENSUS() 读取 ±100/0 ppm 三组 result MAT，对定点化会涉及
%   的每一个节点统计 min / max / 绝对值峰值 / RMS / p99.9，并额外统计自适应量
%   的"逐块最小有效增量"，据此反推建议字长 (signed, WordLength, FractionLength)。
%
%   为什么要先做这一步：字长不能猜。整数位由动态范围决定，而小数位由**最小有效
%   增量**决定 —— 对 FFE 系数与 dLev 这类自适应量，若 LSB 粗于单块更新量，累加器
%   会直接进入死区停摆，环路看起来"收敛"实则冻结。这两个约束必须分别用数据定。
%
%   本函数不跑任何仿真，只读现有 MAT。
%
%   选项：
%     'ResultDir'  输出目录，默认 result/fx_range_census
%     'SaveOutputs' 是否写出报告，默认 true

options = parseOptions(varargin{:});
paths = setup_cdr_fixed_point_paths();

cases = { ...
    'p100', fullfile(paths.PpmResultDir, 'cdr_three_loop_ppm_p100', 'cdr_three_loop_ppm_result.mat'); ...
    'p0',   fullfile(paths.PpmResultDir, 'cdr_three_loop_ppm_p0',   'cdr_three_loop_ppm_result.mat'); ...
    'm100', fullfile(paths.PpmResultDir, 'cdr_three_loop_ppm_m100', 'cdr_three_loop_ppm_result.mat')};

fprintf('=== 定点化范围普查 ===\n');
records = {};
for c = 1:size(cases, 1)
    tag = cases{c, 1};
    matPath = cases{c, 2};
    if ~isfile(matPath)
        warning('fx_range_census:MissingResult', '缺少 %s，跳过。', matPath);
        continue;
    end
    s = loadResultStruct(matPath);
    fprintf('载入 %s: %d 相位 x %d block\n', tag, ...
        size(s.PhaseCodeTrace, 1), size(s.PhaseCodeTrace, 2));
    records = [records; censusOneCase(tag, s)]; %#ok<AGROW>
end

if isempty(records)
    error('fx_range_census:NoData', '没有任何可用的 result MAT。');
end

result = struct();
result.Records = records;
result.GeneratedOn = datetime('now');
result.Cases = cases(:, 1).';

summary = aggregateAcrossCases(records);
result.Summary = summary;

printSummary(summary);

if options.SaveOutputs
    outDir = options.ResultDir;
    if isempty(outDir)
        outDir = fullfile(paths.ResultDir, 'fx_range_census');
    end
    if ~exist(outDir, 'dir')
        mkdir(outDir);
    end
    writeReport(fullfile(outDir, 'fx_range_census.txt'), summary, result.Cases);
    writeCsv(fullfile(outDir, 'fx_range_census.csv'), summary);
    result.ResultDir = outDir;
    fprintf('\n报告已写入 %s\n', outDir);
end
end

% ---------------------------------------------------------------------------

function s = loadResultStruct(matPath)
raw = load(matPath);
names = fieldnames(raw);
if numel(names) == 1 && isstruct(raw.(names{1}))
    s = raw.(names{1});
else
    s = raw;
end
end

function records = censusOneCase(tag, s)
%CENSUSONECASE 对一组 result 的全部关注节点做统计。
%
% 'kind' 决定小数位怎么定：
%   'range'    只看动态范围，小数位由调用方按物理分辨率给（如整数码）
%   'adaptive' 还要看逐块增量，LSB 必须远小于最小有效增量，否则死区
nodes = { ...
    'AdcCodeEnvelope',     'range',    dlevEnvelope(s); ...
    'PhaseError_Voter',    'range',    s.TimingErrorTrace; ...
    'LoopControl',         'range',    s.LoopControlTrace; ...
    'FrequencyState',      'adaptive', s.LoopFrequencyStateTrace; ...
    'CodeResidue',         'range',    s.LoopCodeResidueTrace; ...
    'PendingCode',         'range',    s.LoopPendingCodeTrace; ...
    'DeltaCode',           'range',    s.DeltaCodeTrace; ...
    'PhaseCodeWrapped',    'range',    s.PhaseCodeTrace; ...
    'UiSlip',              'range',    s.UiSlipTrace; ...
    'UnwrappedPhase',      'range',    s.UnwrappedPhaseTrace; ...
    'DlevInner',           'adaptive', s.DlevInnerTrace; ...
    'DlevOuter',           'adaptive', s.DlevOuterTrace; ...
    'DlevThreshold',       'adaptive', s.DlevThresholdTrace; ...
    'EdgeCountPerBlock',   'range',    s.EdgeCountTrace; ...
    'DriftSample',         'range',    s.DriftSampleTrace; ...
    'SnrDb',               'range',    s.SnrDbTrace};

records = cell(0, 1);
for k = 1:size(nodes, 1)
    records{end + 1, 1} = makeRecord(tag, nodes{k, 1}, nodes{k, 2}, nodes{k, 3}); %#ok<AGROW>
end

% FFE 系数逐抽头统计。主抽头被四层硬冻结为恒等于 1，与其余抽头的量纲完全
% 不同（它根本不需要乘法器，是一根直通线），所以必须分开统计，不能混在一起
% 取包络，否则非主抽头的字长会被主抽头的 1.0 拉大 2 bit。
coeff = s.FfeCoeffTrace;
tapCount = size(coeff, 3);
mainTapIndex = findMainTapIndex(s, tapCount);
for t = 1:tapCount
    if t == mainTapIndex
        name = sprintf('FfeTap%d_MAIN_frozen', t);
        kind = 'range';
    else
        name = sprintf('FfeTap%d', t);
        kind = 'adaptive';
    end
    records{end + 1, 1} = makeRecord(tag, name, kind, coeff(:, :, t)); %#ok<AGROW>
end
end

function idx = findMainTapIndex(s, tapCount)
%FINDMAINTAPINDEX 主抽头 = 初值恒为 1 的那一个。
idx = NaN;
if isfield(s, 'FfeInitCoefficients')
    hit = find(s.FfeInitCoefficients == 1, 1, 'first');
    if ~isempty(hit)
        idx = hit;
    end
end
if isnan(idx)
    idx = min(3, tapCount);
end
end

function env = dlevEnvelope(s)
%DLEVENVELOPE 用 dLev 外电平包络代表 ADC 码域幅度，给信号路径字长定上界。
env = [s.DlevOuterTrace(:); -s.DlevOuterTrace(:)];
end

function r = makeRecord(tag, name, kind, data)
x = double(data(:));
x = x(isfinite(x));

r = struct();
r.Case = tag;
r.Node = name;
r.Kind = kind;
r.Count = numel(x);

if isempty(x)
    [r.Min, r.Max, r.AbsMax, r.Rms, r.P999, r.MinStep, r.IntBits, r.FracBits] = deal(NaN);
    return;
end

r.Min = min(x);
r.Max = max(x);
r.AbsMax = max(abs(x));
r.Rms = sqrt(mean(x .^ 2));
r.P999 = prctile(abs(x), 99.9);

% 整数位（不含符号位）。+1 位余量留给捕获期的瞬态过冲。
r.IntBits = max(0, ceil(log2(max(r.AbsMax, eps)))) + 1;

% 小数位。对自适应量，看逐块增量的最小有效值：LSB 必须显著小于它，
% 否则累加器进入死区。这里取非零增量的 1% 分位，避开数值噪声，
% 再留 3 bit 余量（约 8 倍）保证不停摆。
if strcmp(kind, 'adaptive')
    d = abs(diff(double(data), 1, 2));
    d = d(isfinite(d) & d > 0);
    if isempty(d)
        r.MinStep = NaN;
        r.FracBits = NaN;
    else
        r.MinStep = prctile(d, 1);
        r.FracBits = max(0, ceil(-log2(r.MinStep))) + 3;
    end
else
    r.MinStep = NaN;
    r.FracBits = NaN;
end
end

function summary = aggregateAcrossCases(records)
%AGGREGATEACROSSCASES 跨 ±100/0 ppm 取最坏情况，字长必须同时覆盖三者。
all = [records{:}];
nodes = unique({all.Node}, 'stable');
summary = struct('Node', {}, 'Kind', {}, 'Min', {}, 'Max', {}, 'AbsMax', {}, ...
    'Rms', {}, 'P999', {}, 'MinStep', {}, 'IntBits', {}, 'FracBits', {}, ...
    'WordLength', {}, 'Lsb', {}, 'Range', {});

for k = 1:numel(nodes)
    sel = all(strcmp({all.Node}, nodes{k}));
    e = struct();
    e.Node = nodes{k};
    e.Kind = sel(1).Kind;
    e.Min = min([sel.Min]);
    e.Max = max([sel.Max]);
    e.AbsMax = max([sel.AbsMax]);
    e.Rms = max([sel.Rms]);
    e.P999 = max([sel.P999]);
    e.MinStep = min([sel.MinStep]);
    e.IntBits = max([sel.IntBits]);
    fb = [sel.FracBits];
    fb = fb(isfinite(fb));
    if isempty(fb)
        e.FracBits = NaN;
    else
        e.FracBits = max(fb);
    end
    if isfinite(e.FracBits)
        e.WordLength = 1 + e.IntBits + e.FracBits;
        e.Lsb = 2 ^ (-e.FracBits);
    else
        e.WordLength = NaN;
        e.Lsb = NaN;
    end
    e.Range = 2 ^ e.IntBits;
    summary(end + 1) = e; %#ok<AGROW>
end
end

function printSummary(summary)
fprintf('\n%-26s %-9s %12s %12s %12s %10s %6s %6s %6s\n', ...
    '节点', '类型', 'min', 'max', '最小增量', 'LSB', '整数', '小数', '总位');
fprintf('%s\n', repmat('-', 1, 112));
for k = 1:numel(summary)
    e = summary(k);
    if isfinite(e.WordLength)
        fprintf('%-26s %-9s %12.5g %12.5g %12.3g %10.3g %6d %6d %6d\n', ...
            e.Node, e.Kind, e.Min, e.Max, e.MinStep, e.Lsb, ...
            e.IntBits, e.FracBits, e.WordLength);
    else
        fprintf('%-26s %-9s %12.5g %12.5g %12s %10s %6d %6s %6s\n', ...
            e.Node, e.Kind, e.Min, e.Max, '-', '-', e.IntBits, '(待定)', '-');
    end
end
fprintf('%s\n', repmat('-', 1, 112));
fprintf('说明：整数位不含符号位，已含 1 bit 瞬态余量；小数位仅对自适应量由最小增量反推（含 3 bit 余量）。\n');
fprintf('      标注"(待定)"的是纯范围类节点，其小数位应由物理分辨率决定（如整数码则为 0）。\n');
end

function writeReport(filePath, summary, caseTags)
fid = fopen(filePath, 'w', 'n', 'UTF-8');
if fid < 0
    error('fx_range_census:CannotWrite', '无法写入 %s', filePath);
end
closer = onCleanup(@() fclose(fid));

fprintf(fid, '定点化范围普查报告\n');
fprintf(fid, '生成时间: %s\n', datestr(now, 'yyyy-mm-dd HH:MM:SS')); %#ok<DATST,TNOW1>
fprintf(fid, '数据来源: ppm 套件 result MAT, 工况 %s\n', strjoin(caseTags, ' / '));
fprintf(fid, '口径: 跨工况取最坏值; 整数位不含符号位且已含 1 bit 瞬态余量;\n');
fprintf(fid, '      自适应量的小数位由逐块增量的 1%% 分位反推并留 3 bit 余量。\n\n');

fprintf(fid, '%-26s %-9s %14s %14s %14s %12s %6s %6s %6s\n', ...
    'Node', 'Kind', 'Min', 'Max', 'MinStep', 'LSB', 'Int', 'Frac', 'WL');
fprintf(fid, '%s\n', repmat('-', 1, 116));
for k = 1:numel(summary)
    e = summary(k);
    if isfinite(e.WordLength)
        fprintf(fid, '%-26s %-9s %14.6g %14.6g %14.4g %12.4g %6d %6d %6d\n', ...
            e.Node, e.Kind, e.Min, e.Max, e.MinStep, e.Lsb, ...
            e.IntBits, e.FracBits, e.WordLength);
    else
        fprintf(fid, '%-26s %-9s %14.6g %14.6g %14s %12s %6d %6s %6s\n', ...
            e.Node, e.Kind, e.Min, e.Max, '-', '-', e.IntBits, 'TBD', '-');
    end
end
fprintf(fid, '%s\n', repmat('-', 1, 116));
end

function writeCsv(filePath, summary)
fid = fopen(filePath, 'w', 'n', 'UTF-8');
if fid < 0
    error('fx_range_census:CannotWrite', '无法写入 %s', filePath);
end
closer = onCleanup(@() fclose(fid));
fprintf(fid, 'Node,Kind,Min,Max,AbsMax,Rms,P999,MinStep,IntBits,FracBits,WordLength,Lsb\n');
for k = 1:numel(summary)
    e = summary(k);
    fprintf(fid, '%s,%s,%.10g,%.10g,%.10g,%.10g,%.10g,%.10g,%d,%g,%g,%.10g\n', ...
        e.Node, e.Kind, e.Min, e.Max, e.AbsMax, e.Rms, e.P999, e.MinStep, ...
        e.IntBits, e.FracBits, e.WordLength, e.Lsb);
end
end

function options = parseOptions(varargin)
defaults.ResultDir = '';
defaults.SaveOutputs = true;
options = defaults;
if mod(numel(varargin), 2) ~= 0
    error('fx_range_census:InvalidOptions', '选项必须成对出现。');
end
for k = 1:2:numel(varargin)
    name = varargin{k};
    if ~isfield(defaults, name)
        error('fx_range_census:UnknownOption', '未知选项 %s。', name);
    end
    options.(name) = varargin{k + 1};
end
end
