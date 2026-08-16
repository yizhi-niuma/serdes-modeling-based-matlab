function result = test_cdr_top_ctle_waveform(Kp, Ki)
% test_cdr_top_ctle_waveform  在固定 CTLE 输出波形上验证 PAM4 CDR 的捕获与跟踪。
%
% 本脚本把过采样 CTLE 电压作为 CDR 前端输入，在脚本内部完成 PAM4 数据判决和
% 中心门限 edge-bit 判决，再把数字判决送入 cdr_top。当前验证链路为：
%   CTLE 电压 -> 固定门限 slicer -> PAM4 BBPD -> 64-UI constant voter
%   -> 比例积分环路滤波器 -> 8-bit 理想 PI -> 下一 block 的采样相位。
%
% 建模边界：本脚本直接读取并切片 CTLE 电压，不包含专用 CDR FFE、TI ADC 量化、
% 数据通路 DFE、频率检测器或 BER 统计。CSV 也没有发送符号标签，因此本测试只验证
% 相位捕获、统计锁定和稳态漂移，不验证误码率。
%
% 输入 Kp、Ki 是每 64 UI 更新一次的行为级环路增益；省略时使用当前 fixture 经局部
% 扫描选出的默认值。返回值 result 保存离线参考、闭环轨迹和输出图路径，便于调用方
% 复核数值结果。

if nargin < 1
    % 默认比例增益使 constant voter 的 +/-8 输出对应 +/-0.5 PI code 的比例控制量。
    Kp = 0.0625;
end
if nargin < 2
    % 保留较弱积分支路，用于消除长期偏差，同时避免稳态附近积分推动过强。
    Ki = 0.0005;
end

% 所有路径均由当前脚本位置推导，避免依赖 MATLAB 启动目录。
thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(validationDir));
addpath(fullfile(repoRoot, 'src', 'CDR'));

% 验证输出统一写入仓库顶层 results/CDR，不写回输入数据目录。
resultDir = fullfile(repoRoot, 'results', 'CDR');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

waveformCsv = fullfile(repoRoot, 'data', 'ADC', 'TI_ADC', ...
    'ctle_out.csv');
waveformData = readmatrix(waveformCsv);
% 删除包含 NaN/Inf 的行，防止 CSV 表头或尾部空行进入相位扫描和切片计算。
waveformData = waveformData(all(isfinite(waveformData), 2), :);
assert(size(waveformData, 2) >= 2, ...
    'CTLE waveform CSV must contain time and voltage columns.');

time = waveformData(:, 1).';
voltage = waveformData(:, end).';
% 当前 fixture 按 56 GBaud PAM4、128 samples/UI 生成。闭环共处理
% 64 blocks x 64 UI/block = 4096 UI，并从文件中的第 1 个完整 UI 开始。
samplesPerUI = 128;
blockSize = 64;
numBlocks = 64;
startUi = 1;

% 用时间列反查实际采样间隔，确保后续所有 sample-index 与 UI 的换算成立。
sampleInterval = median(diff(time));
expectedSampleInterval = 1 / (56e9 * samplesPerUI);
assert(abs(sampleInterval / expectedSampleInterval - 1) < 1e-3, ...
    'CTLE waveform sample interval is inconsistent with 128 samples/UI.');

% 对一个 UI 内的全部 128 个候选数据相位做离线功率扫描。最大平均平方值相位通常
% 接近数据眼中心，只用于：1) 选择稳定的 PAM4 电平校准样本；2) 给 BBPD 锁点搜索
% 提供物理上合理的局部窗口。它不会初始化 PI，闭环仍然从 code 0 / phase 0 开始。
phasePower = zeros(1, samplesPerUI);
for phaseIndex = 1:samplesPerUI
    phaseSample = voltage(phaseIndex:samplesPerUI:end);
    phasePower(phaseIndex) = mean(phaseSample .^ 2);
end
[~, referenceDataPhaseIndex] = max(phasePower);
% MATLAB 下标从 1 开始，而模型相位采用 0-based sample offset，因此这里减 1。
referenceDataPhase = referenceDataPhaseIndex - 1;
% 经典 2x BBPD 的 edge sample 比 data sample 提前半个 UI；mod 保证结果落在当前 UI。
referenceEdgePhase = mod(referenceDataPhase - samplesPerUI / 2, samplesPerUI);

% 在离线数据眼中心抽取样本，通过确定性四电平聚类估计 PAM4 电平中心；相邻中心
% 的中点构成三个固定 slicer 门限。门限在闭环开始前一次确定，跟踪过程中不自适应。
calibrationSample = voltage(referenceDataPhaseIndex:samplesPerUI:end);
levelCenter = estimatePam4Centers(calibrationSample);
threshold = (levelCenter(1:3) + levelCenter(2:4)) / 2;

% 扫描全部 edge phase，测量当前波形和门限对应的 BBPD S 曲线。由于 CTLE 波形含
% ISI，BBPD 的统计零交叉不一定等于功率法得到的 referenceEdgePhase。
[pdMeanDecision, pdValidCount] = measurePdCharacteristic( ...
    voltage, threshold, samplesPerUI, startUi, blockSize * numBlocks);
phaseCandidate = 0:samplesPerUI - 1;
distanceFromPowerEdge = abs(wrapSampleError( ...
    phaseCandidate - referenceEdgePhase, samplesPerUI));
% 只在功率参考 +/-0.25 UI 内搜索，并要求至少 5% UI 是当前 PAM4 BBPD 支持的
% 对称跳变，避免在有效样本过少的位置误选一个表面上的零均值点。
lockSearchMask = distanceFromPowerEdge <= samplesPerUI / 4 & ...
    pdValidCount >= 0.05 * blockSize * numBlocks;
lockScore = abs(pdMeanDecision);
lockScore(~lockSearchMask) = Inf;
[~, pdLockPhaseIndex] = min(lockScore);
pdLockPhase = pdLockPhaseIndex - 1;

% 组装行为级数字 CDR：
%   1. PAM4 BBPD 只选择 0<->3 和 1<->2 对称跳变，polarity=+1；
%   2. constant voter 每 64 UI 只保留净票数符号，输出固定为 -8、0 或 +8；
%   3. loop filter 每个 block 更新一次，积分状态限制为 [-2,+2] code/block；
%   4. 8-bit PI 每 UI 有 256 code；理想表下 128 samples/UI 对应 0.5 sample/code。
% 默认 Kp/Ki 仅针对此固定 fixture，通过最终误差、稳态范围、有效跳变密度和漂移
% 的局部扫描选定，不代表产品环路带宽指标。
pd = cdr_pd('pam4', 1);
voter = cdr_voter('constant', blockSize, 8);
loopFilter = cdr_loop(Kp, Ki, -2, 2);
piModel = cdr_pi(8, samplesPerUI);
% 关闭默认 a+b=constant PI 非线性，使本测试只观察 CDR 环路与波形本身的影响。
piModel.resetNonideal();

% cdr_top 必须显式获得第一个 block 之前的历史 symbol，才能构造第一个 UI 的
% D[n-1]。这里在初始 data phase = 0.5 UI 处切出该 symbol；这不会预置 PI 相位。
initialDataIndex = (startUi - 1) * samplesPerUI + samplesPerUI / 2 + 1;
initialSymbol = slicePam4(voltage(initialDataIndex), threshold);
top = cdr_top(pd, voter, loopFilter, piModel, initialSymbol);

% 预分配逐 block 轨迹。SampleIndexForBlock 是更新前、当前 block 实际使用的相位；
% NextLocalIndexFloat 是当前判决完成后、供下一个 block 使用的 PI 相位。
sampleIndexForBlock = zeros(1, numBlocks);
nextLocalIndexFloat = zeros(1, numBlocks);
phaseError = zeros(1, numBlocks);
deltaCode = zeros(1, numBlocks);
validCount = zeros(1, numBlocks);
piCode = zeros(1, numBlocks);

for blockIndex = 1:numBlocks
    % 每次循环处理连续 64 UI。uiIndex 表示相对 CSV 起点的 0-based UI 编号。
    uiIndex = startUi + (blockIndex - 1) * blockSize + (0:blockSize - 1);
    % PI 输出允许为浮点 sample offset；当前验证局部采用 nearest-sample rounding。
    % 这是本脚本的采样选择，不代表项目已决定所有 downstream sampler 都必须 round。
    localIndexInteger = round(top.CurrentLocalIndexFloat);
    % edgeIndex 取 UI 边界附近的 CDR edge sample；+1 完成 0-based 模型相位到
    % MATLAB 1-based 数组下标的转换。data sample 固定比 edge sample 晚 0.5 UI。
    edgeIndex = uiIndex * samplesPerUI + localIndexInteger + 1;
    dataIndex = edgeIndex + samplesPerUI / 2;
    assert(dataIndex(end) <= numel(voltage), ...
        'CTLE waveform does not contain enough samples.');

    % data slicer 使用全部三个 PAM4 门限，edge slicer 只使用中心门限。cdr_top 内部
    % 依次执行 BBPD、voter、loop filter 和 PI；本 block 的更新相位从下一 block 生效。
    dataCurrBlock = slicePam4(voltage(dataIndex), threshold);
    edgeBitBlock = voltage(edgeIndex) > threshold(2);
    output = top.processBlock(dataCurrBlock, edgeBitBlock);

    sampleIndexForBlock(blockIndex) = output.SampleIndexForBlock;
    nextLocalIndexFloat(blockIndex) = output.NextLocalIndexFloat;
    % PhaseError 是 constant voter 输出的 -8/0/+8，不是以 UI 或 sample 表示的
    % 连续相位误差。DeltaCode 是加到 PI 上的整数 code 增量，小数控制量由 loop
    % filter 的 CodeResidue 跨 block 保留，因此常呈现 -1/0/+1 的量化序列。
    phaseError(blockIndex) = double(output.PhaseError);
    deltaCode(blockIndex) = output.DeltaCode;
    validCount(blockIndex) = sum(output.Valid);
    piCode(blockIndex) = output.PiCodeWrapped;
end

% 与上面的 voter PhaseError 不同，phaseErrorSample 才是当前采样相位相对离线
% BBPD 统计锁点的 sample-domain 环形误差，并折叠到 [-0.5 UI, +0.5 UI)。
phaseErrorSample = wrapSampleError( ...
    sampleIndexForBlock - pdLockPhase, samplesPerUI);
% 最后 16 个 block 作为稳态观察窗口，用于检查均值误差、相位摆幅和残余漂移。
steadyStateBlock = numBlocks - 15:numBlocks;
steadyStateError = phaseErrorSample(steadyStateBlock);
steadyStatePhase = sampleIndexForBlock(steadyStateBlock);

fprintf(['CTLE CDR diagnostic: power edge = %d, BBPD lock = %d, ' ...
    'final phase = %.3f, ' ...
    'steady mean error = %.3f, range = %.3f to %.3f, valid = %d.\n'], ...
    referenceEdgePhase, pdLockPhase, sampleIndexForBlock(end), ...
    mean(steadyStateError), min(steadyStatePhase), ...
    max(steadyStatePhase), sum(validCount));

% 验收条件分别覆盖：可用 PAM4 跳变数量、跨越锁点后的控制方向反转、稳态平均
% 相位误差、稳态峰峰摆幅，以及是否仍存在单向相位漂移。
assert(sum(validCount) >= 0.1 * blockSize * numBlocks, ...
    'Too few selected PAM4 transitions were available for CDR tracking.');
assert(any(phaseError > 0) && any(phaseError < 0), ...
    'The voter output did not reverse direction around the tracked edge.');
assert(abs(mean(steadyStateError)) <= 3, ...
    'Mean steady-state phase error exceeds three waveform samples.');
assert(max(steadyStatePhase) - min(steadyStatePhase) <= 8, ...
    'Steady-state PI phase range exceeds eight waveform samples.');
assert(abs(mean(diff(steadyStatePhase))) <= 0.25, ...
    'Steady-state PI phase still shows excessive drift.');

figurePath = fullfile(resultDir, 'cdr_top_ctle_convergence.png');
% 六个子图依次展示：CTLE 眼图、离线 BBPD S 曲线、闭环 PI 相位、相对统计锁点
% 的真实 sample 误差、每 block 有效跳变数，以及 voter/loop 的离散控制量。
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1150 1200]);
tiled = tiledlayout(fig, 6, 1, ...
    'TileSpacing', 'compact', 'Padding', 'compact');
title(tiled, ['cdr\_top PAM4 tracking on CTLE waveform: ' ...
    '4096 UI, 128 samples/UI']);

nexttile;
plotCtleEye(voltage, samplesPerUI, referenceEdgePhase, threshold);

nexttile;
phaseAxis = 0:samplesPerUI - 1;
plot(phaseAxis, pdMeanDecision, 'b-', 'LineWidth', 1.2);
hold on;
yline(0, 'k--');
xline(referenceEdgePhase, 'r:', 'LineWidth', 1.2);
xline(pdLockPhase, 'm--', 'LineWidth', 1.2);
grid on;
xlim([0 samplesPerUI - 1]);
xlabel('Edge sampling phase (sample)');
ylabel('mean decision');
title('Offline PAM4 BBPD S-curve');
legend('mean valid decision', 'zero', 'power-derived edge', ...
    'selected BBPD lock phase', 'Location', 'best');

blockAxis = 1:numBlocks;
nexttile;
plot(blockAxis, sampleIndexForBlock, ...
    'b-o', 'LineWidth', 1.2, 'MarkerSize', 3);
hold on;
yline(referenceEdgePhase, 'r:', 'LineWidth', 1.2);
yline(pdLockPhase, 'm--', 'LineWidth', 1.2);
grid on;
ylabel('phase (sample)');
title('PI phase versus offline power and BBPD references');
legend('PI phase entering block', 'power-derived edge', ...
    'BBPD statistical lock phase', ...
    'Location', 'best');

nexttile;
stairs(blockAxis, phaseErrorSample, 'LineWidth', 1.2);
hold on;
yline(0, 'k--');
grid on;
ylabel('error (sample)');
title('Wrapped phase error relative to BBPD statistical lock phase');

nexttile;
bar(blockAxis, validCount, 0.8, ...
    'FaceColor', [0.2 0.6 0.35], 'EdgeColor', 'none');
grid on;
ylim([0 blockSize]);
ylabel('valid/UI');
title('Selected PAM4 BBPD transitions per 64-UI block');

nexttile;
yyaxis left;
stairs(blockAxis, phaseError, 'LineWidth', 1.2);
ylabel('voter output');
yyaxis right;
stairs(blockAxis, deltaCode, '--', 'LineWidth', 1.2);
ylabel('\Delta PI code');
grid on;
xlabel('64-UI block index');
title(sprintf('CDR control: Kp = %.4g, Ki = %.4g', Kp, Ki));
legend('phaseError', 'deltaCode', 'Location', 'best');

exportgraphics(fig, figurePath, 'Resolution', 200);
close(fig);

% 返回完整数值轨迹，使自动化调用无需解析图像或终端文本即可复核测试结果。
result = struct();
result.WaveformCsv = waveformCsv;
result.SamplesPerUI = samplesPerUI;
result.NumUiUsed = blockSize * numBlocks;
result.SampleInterval = sampleInterval;
result.LevelCenter = levelCenter;
result.Threshold = threshold;
result.ReferenceDataPhase = referenceDataPhase;
result.ReferenceEdgePhase = referenceEdgePhase;
result.PdLockPhase = pdLockPhase;
result.PdMeanDecision = pdMeanDecision;
result.PdValidCount = pdValidCount;
result.Kp = Kp;
result.Ki = Ki;
result.SampleIndexForBlock = sampleIndexForBlock;
result.NextLocalIndexFloat = nextLocalIndexFloat;
result.PhaseErrorSample = phaseErrorSample;
result.PhaseError = phaseError;
result.DeltaCode = deltaCode;
result.ValidCount = validCount;
result.PiCode = piCode;
result.FigurePath = figurePath;

fprintf('test_cdr_top_ctle_waveform passed.\n');
fprintf('PAM4 centers: %s V.\n', mat2str(levelCenter, 5));
fprintf('PAM4 thresholds: %s V.\n', mat2str(threshold, 5));
fprintf('Reference data/edge phase: %d / %d samples.\n', ...
    referenceDataPhase, referenceEdgePhase);
fprintf('BBPD statistical lock phase: %d samples.\n', pdLockPhase);
fprintf('Steady-state phase range: %.3f to %.3f samples.\n', ...
    min(steadyStatePhase), max(steadyStatePhase));
fprintf('Mean steady-state phase error: %.3f samples.\n', ...
    mean(steadyStateError));
fprintf('Selected transition count: %d of %d UI.\n', ...
    sum(validCount), blockSize * numBlocks);
fprintf('Saved PNG: %s\n', figurePath);
end

function levelCenter = estimatePam4Centers(sample)
% estimatePam4Centers  用确定性一维四电平聚类估计 PAM4 电平中心。
%
% 先用四个分位点初始化中心，再重复“分配到最近中心、按簇求均值”。不使用随机
% 初值，因此同一输入每次得到相同门限；1e-12 是数值收敛条件，最多迭代 50 次。

levelCenter = prctile(sample, [12.5 37.5 62.5 87.5]);
for iteration = 1:50
    distance = abs(sample(:) - levelCenter);
    [~, clusterIndex] = min(distance, [], 2);
    updatedCenter = levelCenter;
    for levelIndex = 1:4
        levelSample = sample(clusterIndex == levelIndex);
        assert(~isempty(levelSample), ...
            'PAM4 level clustering produced an empty level.');
        updatedCenter(levelIndex) = mean(levelSample);
    end
    updatedCenter = sort(updatedCenter);
    if max(abs(updatedCenter - levelCenter)) < 1e-12
        break;
    end
    levelCenter = updatedCenter;
end
levelCenter = sort(levelCenter);
end

function dataSymbol = slicePam4(sampleValue, threshold)
% slicePam4  应用三个已校准门限，把电压映射为 PAM4 数字码 0、1、2、3。
%
% 样本每超过一个升序门限就累加 1，因此最低/最高电平分别映射为 0/3。该数字码
% 与 cdr_pd 的 PAM4 接口一致，不等同于物理电平值 -3、-1、+1、+3。

dataSymbol = double(sampleValue > threshold(1)) + ...
    double(sampleValue > threshold(2)) + ...
    double(sampleValue > threshold(3));
end

function [meanDecision, validCount] = measurePdCharacteristic( ...
        voltage, threshold, samplesPerUI, startUi, numUi)
% measurePdCharacteristic  离线测量 PAM4 BBPD 平均判决随 edge phase 的变化。
%
% 对每个候选相位，用同一批 UI 构造 data/edge 判决。BBPD 只对支持的对称跳变
% 输出 +/-1，其余 UI 标记为 invalid。meanDecision 只除以有效跳变数，所以表示
% “给定有效跳变时”的平均 early/late 方向；validCount 单独记录统计可信度。

pd = cdr_pd('pam4', 1);
meanDecision = zeros(1, samplesPerUI);
validCount = zeros(1, samplesPerUI);
uiIndex = startUi + (0:numUi - 1);
for phase = 0:samplesPerUI - 1
    % edge 位于当前 UI 边界加候选相位；data 位于其后半个 UI。
    edgeIndex = uiIndex * samplesPerUI + phase + 1;
    dataIndex = edgeIndex + samplesPerUI / 2;
    previousDataIndex = (startUi - 1) * samplesPerUI + ...
        phase + samplesPerUI / 2 + 1;
    dataCurr = slicePam4(voltage(dataIndex), threshold);
    previousSymbol = slicePam4(voltage(previousDataIndex), threshold);
    % 显式拼接扫描区间之前的历史 symbol，保留第一个 UI 的跨边界跳变。
    dataPrev = [previousSymbol dataCurr(1:end - 1)];
    edgeBit = voltage(edgeIndex) > threshold(2);
    [decision, valid] = pd.bbpdFast(dataPrev, edgeBit, dataCurr);
    validCount(phase + 1) = sum(valid);
    meanDecision(phase + 1) = sum(double(decision)) / ...
        max(validCount(phase + 1), 1);
end
end

function errorSample = wrapSampleError(errorSample, samplesPerUI)
% wrapSampleError  将周期性的采样相位误差折叠到 [-0.5 UI, +0.5 UI)。
%
% PI 相位以一个 UI 为周期；例如接近 127 sample 与接近 0 sample 实际相邻，不能
% 直接相减得到约一整个 UI 的假大误差，因此统一取最短环形距离。

errorSample = mod(errorSample + samplesPerUI / 2, samplesPerUI) - ...
    samplesPerUI / 2;
end

function plotCtleEye(voltage, samplesPerUI, referenceEdgePhase, threshold)
% plotCtleEye  绘制以标称 UI 边界为参考的紧凑两 UI CTLE 眼图。
%
% 叠加 160 条两 UI 波形用于观察眼口和 ISI。红色虚线是功率法数据相位平移半 UI
% 得到的 edge 参考，不是强制锁点；黑色点线是离线聚类得到的三个 PAM4 门限。

numTrace = 160;
traceLength = 2 * samplesPerUI;
traceStart = (0:numTrace - 1) * traceLength + 1;
hold on;
for traceIndex = 1:numTrace
    index = traceStart(traceIndex) + (0:traceLength - 1);
    plot((0:traceLength - 1) / samplesPerUI, voltage(index), ...
        'Color', [0.15 0.4 0.85 0.12], 'LineWidth', 0.5);
end
xline(referenceEdgePhase / samplesPerUI, ...
    'r--', 'LineWidth', 1.2);
xline(1 + referenceEdgePhase / samplesPerUI, ...
    'r--', 'LineWidth', 1.2, 'HandleVisibility', 'off');
for thresholdIndex = 1:numel(threshold)
    yline(threshold(thresholdIndex), 'k:', ...
        'HandleVisibility', 'off');
end
grid on;
xlim([0 2]);
xlabel('Time from nominal UI boundary (UI)');
ylabel('CTLE voltage (V)');
title(['CTLE eye: red dashed line is offline reference edge; ' ...
    'black dotted lines are slicer thresholds']);
end
