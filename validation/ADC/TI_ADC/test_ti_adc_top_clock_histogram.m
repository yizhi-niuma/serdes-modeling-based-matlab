function test_ti_adc_top_clock_histogram()
%TEST_TI_ADC_TOP_CLOCK_HISTOGRAM 验证 ti_adc_top 在不同 clock 条件下的输出码分布。
%   本测试脚本面向 ADC-based SerDes RX 端到端行为仿真，使用 CTLE 输出波形驱动
%   ti_adc_top，并比较三组 clock 配置下的 signed ADC code histogram：
%   1. ideal clock：8 个 TAH phase 无固定 skew、无随机 jitter。
%   2. fixed skew：8 个 TAH phase 之间存在相邻 4 个 waveform index 的固定偏移。
%   3. jitter：无固定 skew，但 TAH rising edge 带随机 UI jitter。
%
%   ti_adc_top 当前使用 local-block 输入模式，因此每次转换只传入一个 nominal ADC
%   block 以及左右等长 input margin。margin 用于吸收 fixed skew / random jitter
%   引起的整数 sample index 移动，避免采样点越过本地输入波形范围。
%
%   输出图片保存到 result/test_ti_adc_top_clock_histogram.png，三行分别对应三种
%   clock case，便于观察 clock impairment 对 ADC 输出码分布的影响。
close all;

% 使用测试文件所在目录作为基准路径，避免 MATLAB 当前工作目录变化导致相对路径失效。
validationDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(fileparts(fileparts(validationDir)));
sourceDir = fullfile(repoRoot, 'src', 'ADC', 'TI_ADC');
resultDir = fullfile(repoRoot, 'results', 'ADC', 'TI_ADC');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end
addpath(sourceDir);

% 固定随机数种子，使 jitter case 每次运行得到可复现的 histogram 结果。
rng(20260803, 'twister');

% ADC top 参数设置。
% numLanes 表示 time-interleaved ADC 的 lane 总数；sarPerTah 表示每个 TAH phase
% 后连接的 SAR ADC lane 数量。samplesPerSymbol 同时也是输入波形的过采样率，因此
% 一个 waveform index 对应 1 / samplesPerSymbol UI。
numLanes = 64;
sarPerTah = 8;
samplesPerSymbol = 128;
nBits = 7;
inputMargin = 100;

% ti_adc_top 的 local-block 输入长度约定：
%   nominalBlockLength = 64 个 lane 在理想采样时刻覆盖的输入波形长度。
%   localWaveformLength = nominal block + 左右各 inputMargin。
% inputMargin 的单位是 waveform sample index，不是 UI。
nominalBlockLength = (numLanes - 1) * samplesPerSymbol + 1;
% localWaveformLength 依赖 cdrPhaseIndex，因此在 bestPhase 确定后再计算。

% 读取 CTLE 输出波形。若 CSV 只有一列，则该列即为电压；若 CSV 有多列，则默认最后
% 一列为电压列。读取后去掉包含 NaN 的行，避免表头或空行影响后续仿真。
waveformCsv = fullfile(repoRoot, 'data', 'ADC', 'TI_ADC', 'ctle_out.csv');
waveformData = readmatrix(waveformCsv);
waveformData = waveformData(all(~isnan(waveformData), 2), :);
if isempty(waveformData)
    error('CTLE waveform CSV does not contain valid numeric data.');
end
if size(waveformData, 2) == 1
    waveformVoltage = waveformData(:, 1).';
else
    waveformVoltage = waveformData(:, end).';
end

% 根据实际 CTLE 波形幅度配置对称 ADC 输入范围。这里使用 0.9 * max(abs(waveform))，
% 与已有 core 测试脚本保持一致，避免 full-scale 设置不同导致 ideal case code 分布不一致。
adcFullScale = 0.9 * max(abs(waveformVoltage));
if adcFullScale <= 0
    error('CTLE waveform amplitude is zero, cannot configure ADC full range.');
end
VL = -adcFullScale;
VH = adcFullScale;

% 在一个 UI 内扫描 CTLE 波形的候选采样相位，并选取能量最大的相位作为三组 case
% 共用的 nominal CDR phase。该 phase 作为 clock 的 cdrPhaseIndex 输入，而不是用于
% 移动 local waveform 的截取起点；这样更接近实际电路中 CDR 决定采样相位、clock
% 负责生成 lane 采样位置的工作方式。
[bestPhase, bestPower, bestVariancePhase, bestVariance] = findBestSamplePhase(waveformVoltage, samplesPerSymbol);
cdrPhaseIndex = bestPhase;
localWaveformLength = nominalBlockLength + 2 * inputMargin + cdrPhaseIndex - 1;

% 每个 ADC block 包含 numLanes 次采样，相邻 lane 的理想采样间隔为 samplesPerSymbol。
% firstBlockStart 对齐到完整 UI/block 边界，并从第二个 block 附近开始，给前方留出
% 足够波形空间；maxBlocks 根据 CTLE 波形总长度和 local block + margin 需求自动计算。
blockStride = numLanes * samplesPerSymbol;
firstBlockStart = blockStride + 1;
maxBlocks = floor((numel(waveformVoltage) - (firstBlockStart - inputMargin) - localWaveformLength + 1) / blockStride) + 1;
if maxBlocks < 1
    error('CTLE waveform is too short for one local ti_adc_top block with margin.');
end
numBlocks = maxBlocks;

% 生成三组 clock case，并为每组保存输出 signed code 和实际采样 index。
caseConfig = createCaseConfig(samplesPerSymbol);
numCases = numel(caseConfig);
caseCode = cell(1, numCases);
caseTimingIndex = cell(1, numCases);

for caseIndex = 1:numCases
    % 每个 case 使用独立的 ti_adc_top 对象，避免上一组 skew / jitter 配置残留。
    adcTop = ti_adc_top(numLanes, VL, VH, nBits, sarPerTah, samplesPerSymbol);
    adcTop.resetToIdeal();
    adcTop.setInputMargin(inputMargin);
    adcTop.setRisingEdgeSkewUI(caseConfig(caseIndex).skewUI);
    adcTop.setRisingEdgeJitterSigmaUI(caseConfig(caseIndex).jitterSigmaUI);

    % Dout_dec 保存 unsigned ADC code；timingIndex 保存每个 block、每个 lane 实际使用的
    % 整数 waveform sample index，用于检查 skew / jitter 是否按预期改变采样位置。
    Dout_dec = zeros(1, numBlocks * numLanes);
    timingIndex = zeros(numBlocks, numLanes);

    for blockIndex = 1:numBlocks
        % blockStart 是该 block 的完整 UI/block 边界；localStart/localStop 在其左右加入
        % 等长 margin 后切出局部输入波形。bestPhase 不再隐藏到 localStart 中，而是作为
        % cdrPhaseIndex 传入 clock，由 clock 生成每个 lane 的实际采样 index。
        blockStart = firstBlockStart + (blockIndex - 1) * blockStride;
        localStart = blockStart - inputMargin;
        localStop = localStart + localWaveformLength - 1;
        if localStart < 1 || localStop > numel(waveformVoltage)
            error('CTLE waveform does not cover the required local block range.');
        end
        VinWaveform = waveformVoltage(localStart:localStop);

        % 将当前 block 的 64 个 lane 输出写入连续的一维结果数组，便于后续统一统计
        % histogram。fast path 不保存 trace，适合此类大量 block 的分布仿真。
        blockResultIndex = (blockIndex - 1) * numLanes + (1:numLanes);
        Dout_dec(blockResultIndex) = adcTop.convertOneBlockFast(VinWaveform, cdrPhaseIndex);

        % 单独记录采样 index。这里传入 cdrPhaseIndex + inputMargin，是因为 timingIndex
        % 以 local waveform 坐标系表示，nominal CDR phase 位于左侧 margin 之后。
        timingIndex(blockIndex, :) = adcTop.generateSampleIndex(cdrPhaseIndex + inputMargin);
    end

    % 检查输出码范围和 timing index 的基本有效性；随后转换为 signed code 供画图使用。
    validateCaseOutput(Dout_dec, timingIndex, nBits, caseConfig(caseIndex).name);
    caseCode{caseIndex} = convertToSignedCode(Dout_dec, nBits);
    caseTimingIndex{caseIndex} = timingIndex;
end

% 绘制三行 histogram。每行对应一个 clock case，并叠加按显著 cluster 拟合得到的
% Gaussian 曲线和峰值标记，用于直观观察输出码分布形态。
figHistogram = figure('Visible', 'on', 'Color', 'w', 'Name', 'TI ADC top clock histogram comparison');
tiledlayout(numCases, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

signedCodeMin = -(2 ^ (nBits - 1) - 1);
signedCodeMax = 2 ^ (nBits - 1) - 1;
codeEdges = (signedCodeMin - 0.5):(signedCodeMax + 0.5);
codeCenters = signedCodeMin:signedCodeMax;

for caseIndex = 1:numCases
    nexttile;
    codeCounts = histcounts(caseCode{caseIndex}, codeEdges);
    codeProbability = codeCounts / sum(codeCounts);
    plotDistributionWithGaussianFit(codeCenters, codeProbability, [0.25, 0.45, 0.95], 4, 'code');
    grid on;
    xlabel('ADC Output Code (Signed Decimal)');
    ylabel('Normalized probability');
    title(caseConfig(caseIndex).titleText);
    subtitle(caseConfig(caseIndex).subtitleText);
    xlim([signedCodeMin, signedCodeMax]);
end

% 保存图片并确认文件生成成功。
histogramPng = fullfile(resultDir, 'test_ti_adc_top_clock_histogram.png');
exportgraphics(figHistogram, histogramPng, 'Resolution', 150);
drawnow;
if ~exist(histogramPng, 'file')
    error('Histogram PNG was not generated.');
end

% 打印本次仿真的关键参数和每组 case 的简单统计，便于在命令行快速确认结果。
fprintf('TI ADC top histogram test passed.\n');
fprintf('Input waveform: %s\n', waveformCsv);
fprintf('Waveform samples: %d\n', numel(waveformVoltage));
fprintf('ADC full range: [%.6g, %.6g] V\n', VL, VH);
fprintf('Best sample phase: %d, power = %.6g\n', bestPhase, bestPower);
fprintf('CDR phase index: %d\n', cdrPhaseIndex);
fprintf('Best variance phase: %d, variance = %.6g\n', bestVariancePhase, bestVariance);
fprintf('Completed blocks: %d\n', numBlocks);
fprintf('Saved figure: %s\n', histogramPng);
for caseIndex = 1:numCases
    timingDeviation = caseTimingIndex{caseIndex} - caseTimingIndex{1};
    fprintf('%s: code mean = %.3f, code std = %.3f, timing deviation std = %.3f index\n', ...
        caseConfig(caseIndex).name, mean(caseCode{caseIndex}), std(double(caseCode{caseIndex})), std(timingDeviation(:)));
end
end

function [bestPowerPhase, bestPower, bestVariancePhase, bestVariance] = findBestSamplePhase(waveformVoltage, samplesPerSymbol)
%FINDBESTSAMPLEPHASE 从 CTLE 波形中寻找 nominal 采样相位。
%   在 1:samplesPerSymbol 的每个候选 phase 上抽取一组 symbol-spaced sample，分别
%   计算平均功率和方差。主流程使用 bestPowerPhase 作为 CDR nominal phase，同时保留
%   bestVariancePhase 作为 debug 信息输出，方便判断波形眼图开口/幅度变化最大的相位。
phasePower = zeros(1, samplesPerSymbol);
phaseVariance = zeros(1, samplesPerSymbol);
for phaseIndex = 1:samplesPerSymbol
    phaseSamples = waveformVoltage(phaseIndex:samplesPerSymbol:end);
    phasePower(phaseIndex) = mean(phaseSamples .^ 2);
    phaseVariance(phaseIndex) = var(phaseSamples, 1);
end
[bestPower, bestPowerPhase] = max(phasePower);
[bestVariance, bestVariancePhase] = max(phaseVariance);
end

function caseConfig = createCaseConfig(samplesPerSymbol)
%CREATECASECONFIG 创建三组 clock impairment 配置。
%   skewUI 和 jitterSigmaUI 的长度均为 8，对应 8 个 TAH phase。fixedSkewIndex 使用
%   waveform index 表示，再除以 samplesPerSymbol 转换为 UI；减去 mean(0:7) 后使固定
%   skew 以零均值方式分布，避免整体采样相位被平移。
fixedSkewIndex = 4;
fixedSkewUI = ((0:7) - mean(0:7)) * fixedSkewIndex / samplesPerSymbol;
caseConfig = struct( ...
    'name', {}, ...
    'titleText', {}, ...
    'subtitleText', {}, ...
    'skewUI', {}, ...
    'jitterSigmaUI', {});

% Case 1：理想 clock，作为输出码分布和 timing index 的参考基准。
caseConfig(1).name = 'ideal';
caseConfig(1).titleText = 'Ideal clock';
caseConfig(1).subtitleText = 'CTLE waveform, no skew, no jitter';
caseConfig(1).skewUI = zeros(1, 8);
caseConfig(1).jitterSigmaUI = zeros(1, 8);

% Case 2：固定 TAH phase skew。相邻 phase 的 skew 间隔为 4 个 waveform index，
% clock core 内部会将 UI skew 乘以 samplesPerSymbol 后转换回 index 偏移。
caseConfig(2).name = 'fixed_skew';
caseConfig(2).titleText = '4-index TAH fixed skew';
caseConfig(2).subtitleText = 'CTLE waveform, adjacent phase skew spacing = 4 index';
caseConfig(2).skewUI = fixedSkewUI;
caseConfig(2).jitterSigmaUI = zeros(1, 8);

% Case 3：随机 jitter。无 fixed skew，各 TAH phase 使用相同的 jitter sigma。
% 这里不改变原始脚本的数值设置；实际 sigma 由下面的赋值行决定。
caseConfig(3).name = 'ten_percent_ui_jitter';
caseConfig(3).titleText = '10% UI jitter';
caseConfig(3).subtitleText = 'CTLE waveform, no fixed skew, jitter sigma = 0.10 UI';
caseConfig(3).skewUI = zeros(1, 8);
caseConfig(3).jitterSigmaUI = 0.05 * ones(1, 8);
end

function signedCode = convertToSignedCode(Dout_dec, nBits)
%CONVERTTOSIGNEDCODE 将 unsigned ADC code 转换为绘图用 signed code。
%   ti_adc_core 输出范围为 [0, 2^N - 1]。为了让 histogram 以 0 为中心显示，这里减去
%   2^(N-1)，并限制到当前 signed 表示范围，避免端点溢出影响绘图坐标。
signedCodeMin = -(2 ^ (nBits - 1) - 1);
signedCodeMax = 2 ^ (nBits - 1) - 1;
signedCode = min(max(Dout_dec - 2 ^ (nBits - 1), signedCodeMin), signedCodeMax);
end

function validateCaseOutput(Dout_dec, timingIndex, nBits, caseName)
%VALIDATECASEOUTPUT 检查单组 case 的 ADC 输出码和采样 index 是否有效。
%   这里仅做仿真结果的基本健壮性检查，不改变数据本身。Dout_dec 必须位于 unsigned
%   ADC code 范围内；timingIndex 必须为有限整数，因为 clock core 已在内部完成取整。
if isempty(Dout_dec) || any(~isfinite(Dout_dec(:)))
    error('%s output code contains invalid values.', caseName);
end
if any(Dout_dec < 0) || any(Dout_dec > 2 ^ nBits - 1)
    error('%s output code is outside expected ADC range.', caseName);
end
if isempty(timingIndex) || any(~isfinite(timingIndex(:))) || any(timingIndex(:) ~= round(timingIndex(:)))
    error('%s timing index contains invalid values.', caseName);
end
end

function plotDistributionWithGaussianFit(xValue, yValue, barColor, maxClusterCount, labelMode)
%PLOTDISTRIBUTIONWITHGAUSSIANFIT 绘制归一化 histogram 并叠加局部 Gaussian 拟合。
%   histogram 中可能存在多个明显峰值，因此先按非零概率区域寻找 cluster，再对每个
%   cluster 独立估计均值和标准差。该拟合仅用于辅助观察分布形态，不参与 ADC 模型计算。
if isempty(yValue) || sum(yValue) <= 0
    return;
end

xValue = xValue(:).';
yValue = yValue(:).';
bar(xValue, yValue, 1.0, ...
    'FaceColor', barColor, ...
    'EdgeColor', barColor, ...
    'FaceAlpha', 0.80, ...
    'EdgeAlpha', 0.80);
hold on;

[clusterStart, clusterStop] = findDistributionClusters(xValue, yValue, maxClusterCount);
fitPeakX = [];
fitPeakY = [];
fitYMax = max(yValue);

for clusterIndex = 1:numel(clusterStart)
    currentRange = clusterStart(clusterIndex):clusterStop(clusterIndex);
    clusterX = xValue(currentRange);
    clusterY = yValue(currentRange);
    clusterMass = sum(clusterY);
    if clusterMass <= 0
        continue;
    end

    % 用当前 cluster 的概率质量作为权重估计 Gaussian 参数。
    mu = sum(clusterX .* clusterY) / clusterMass;
    sigma = sqrt(sum(((clusterX - mu) .^ 2) .* clusterY) / clusterMass);
    if sigma <= 0
        sigma = max(mean(diff(xValue)), eps(mu));
    end

    % 将离散 histogram 的概率质量近似映射到连续 Gaussian 曲线高度，便于视觉叠加。
    fitX = linspace(min(clusterX), max(clusterX), 120);
    fitY = clusterMass * mean(diff(xValue)) ./ (sigma * sqrt(2 * pi)) .* exp(-0.5 * ((fitX - mu) ./ sigma) .^ 2);
    [currentFitYMax, currentFitPeakIndex] = max(fitY);
    fitPeakX(end + 1) = fitX(currentFitPeakIndex);
    fitPeakY(end + 1) = currentFitYMax;
    fitYMax = max(fitYMax, currentFitYMax);
    plot(fitX, fitY, '-', ...
        'Color', barColor * 0.65, ...
        'LineWidth', 1.4, ...
        'HandleVisibility', 'off');
end

% 如果无法形成有效 Gaussian 拟合，则退回到 histogram cluster 的原始峰值标注。
if isempty(fitPeakX)
    [fitPeakX, fitPeakY] = findDistributionClusterPeaks(xValue, yValue, maxClusterCount);
end
annotateDistributionPeaks(fitPeakX, fitPeakY, fitYMax, labelMode);
end

function [clusterStart, clusterStop] = findDistributionClusters(xValue, yValue, maxClusterCount)
%FINDDISTRIBUTIONCLUSTERS 寻找 histogram 中显著的连续分布区域。
%   clusterThreshold 用最大概率的 2% 作为阈值，过滤掉很小的尾部概率。若 cluster 数量
%   超过上限，则优先合并间距最近的相邻 cluster，避免图上标注过密。
if nargin < 3 || isempty(maxClusterCount)
    maxClusterCount = 8;
end

xValue = xValue(:).';
yValue = yValue(:).';
if isempty(yValue) || max(yValue) <= 0
    clusterStart = [];
    clusterStop = [];
    return;
end

maxY = max(yValue);
clusterThreshold = max(0.02 * maxY, eps(maxY));
clusterMask = yValue > clusterThreshold;
if ~any(clusterMask)
    clusterMask = yValue > 0;
end

clusterStart = find(diff([false, clusterMask]) == 1);
clusterStop = find(diff([clusterMask, false]) == -1);

while numel(clusterStart) > maxClusterCount
    clusterGap = xValue(clusterStart(2:end)) - xValue(clusterStop(1:end-1));
    [~, mergeIndex] = min(clusterGap);
    clusterStop(mergeIndex) = clusterStop(mergeIndex + 1);
    clusterStart(mergeIndex + 1) = [];
    clusterStop(mergeIndex + 1) = [];
end

if numel(clusterStart) > maxClusterCount
    clusterMass = zeros(1, numel(clusterStart));
    for clusterIndex = 1:numel(clusterStart)
        currentRange = clusterStart(clusterIndex):clusterStop(clusterIndex);
        clusterMass(clusterIndex) = sum(yValue(currentRange));
    end
    [~, clusterOrder] = sort(clusterMass, 'descend');
    clusterOrder = sort(clusterOrder(1:maxClusterCount));
    clusterStart = clusterStart(clusterOrder);
    clusterStop = clusterStop(clusterOrder);
end
end

function [peakX, peakY] = findDistributionClusterPeaks(xValue, yValue, maxClusterCount)
%FINDDISTRIBUTIONCLUSTERPEAKS 在每个显著 cluster 中寻找一个 histogram 峰值。
%   该函数主要作为 Gaussian 拟合失败时的 fallback，保证图中仍能标出主要分布峰值。
[clusterStart, clusterStop] = findDistributionClusters(xValue, yValue, maxClusterCount);
if isempty(clusterStart)
    peakX = [];
    peakY = [];
    return;
end

xValue = xValue(:).';
yValue = yValue(:).';
peakX = zeros(1, numel(clusterStart));
peakY = zeros(1, numel(clusterStart));
for clusterIndex = 1:numel(clusterStart)
    currentRange = clusterStart(clusterIndex):clusterStop(clusterIndex);
    [peakY(clusterIndex), localPeakIndex] = max(yValue(currentRange));
    peakX(clusterIndex) = xValue(currentRange(localPeakIndex));
end
end

function annotateDistributionPeaks(peakX, peakY, yScale, labelMode)
%ANNOTATEDISTRIBUTIONPEAKS 在 histogram 上标注主要峰值位置。
%   每个峰值使用竖向虚线和三角 marker 标出，并在上方给出 code 标签。标签高度交替
%   错开，减少相邻峰值文字重叠。
if isempty(peakX)
    return;
end
if yScale <= 0
    yScale = 1;
end

ax = gca;
oldYLim = ylim(ax);
labelBaseY = 1.08 * yScale;
labelStepY = 0.08 * yScale;
labelTopY = labelBaseY + labelStepY;
ylim(ax, [oldYLim(1), max([oldYLim(2), 1.32 * yScale, labelTopY + 0.08 * yScale])]);

for peakIndex = 1:numel(peakX)
    switch labelMode
        case 'code'
            markerColor = [0.85, 0.05, 0.05];
            labelText = sprintf('Code=%d', round(peakX(peakIndex)));
        otherwise
            markerColor = [0.85, 0.10, 0.10];
            labelText = sprintf('%.4g', peakX(peakIndex));
    end

    labelY = labelBaseY + mod(peakIndex - 1, 2) * labelStepY;
    plot([peakX(peakIndex), peakX(peakIndex)], [0, labelY - 0.015 * yScale], '--', ...
        'Color', markerColor * 0.75, ...
        'LineWidth', 0.8, ...
        'HandleVisibility', 'off');
    plot(peakX(peakIndex), peakY(peakIndex), 'v', ...
        'Color', markerColor, ...
        'MarkerFaceColor', markerColor, ...
        'MarkerSize', 5, ...
        'HandleVisibility', 'off');
    text(peakX(peakIndex), labelY, labelText, ...
        'Color', markerColor, ...
        'FontSize', 8, ...
        'FontWeight', 'bold', ...
        'BackgroundColor', 'w', ...
        'Margin', 2, ...
        'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'bottom', ...
        'Rotation', 0, ...
        'Clipping', 'on');
end
end
