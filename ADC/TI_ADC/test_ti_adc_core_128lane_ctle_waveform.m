function test_ti_adc_core_128lane_ctle_waveform()
%TEST_TI_ADC_CORE_128LANE_CTLE_WAVEFORM 用 CTLE 输出波形验证 64-lane TI ADC 行为。
%   本测试脚本完成以下流程：
%   1. 从 ctle_out.csv 读取 CTLE 输出波形，并取最后一列作为输入电压。
%   2. 按 64 倍过采样关系扫描采样相位，选择平均功率最大的相位。
%   3. 以 block-by-block 方式每次采样 64 个码元，并送入 64 路 TI ADC。
%   4. 根据 ADC 输出 code 分别生成 lower-edge 和 bin-center 两种重建电压。
%   5. 绘制并保存 code 分布、电压分布和相位扫描结果。
%
%   注意：脚本运行时会直接显示 figure，同时仍会把 PNG 保存到 result 目录。
close all;

% 获取当前测试脚本所在目录，保证后续 addpath、数据读取和结果保存路径都相对于本脚本。
% 路径统一从本脚本所在目录出发，避免依赖 MATLAB 当前 cd 状态。
baseDir = fileparts(mfilename('fullpath'));
resultDir = fullfile(baseDir, 'result');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end
addpath(baseDir);

% 读取 CTLE 输出波形。
% ctle_out.csv 中如果包含多列数据，默认最后一列为 CTLE 输出电压。
waveformCsv = fullfile(baseDir, 'ctle_out.csv');
% readmatrix 会将非数值表头读成 NaN，后面会删除含 NaN 的行。
waveformData = readmatrix(waveformCsv);
waveformData = waveformData(all(~isnan(waveformData), 2), :);
if isempty(waveformData)
    error('CTLE waveform CSV does not contain valid numeric data.');
end
if size(waveformData, 2) == 1
    waveformVoltage = waveformData(:, 1).';
else
    waveformTime = waveformData(:, 1).';
    waveformVoltage = waveformData(:, end).';
end

% 设置 64 路 TI ADC 和 ADC 分辨率。
% full range 按所有波形采样点最大绝对值的 90%% 设置为对称输入范围。
numLanes = 64;
% oversample 表示每个 UI 的原始波形采样点数，此处与 64-lane 数保持一致。
oversample = 128;
nBits = 7;
adcFullScale = 0.9 * max(abs(waveformVoltage));
if adcFullScale <= 0
    error('CTLE waveform amplitude is zero, cannot configure ADC full range.');
end
VL = -adcFullScale;
VH = adcFullScale;

% 通过相位扫描选择采样点。
% 对每个候选相位，按 64 点间隔抽样，并计算采样点电压方差和平均功率。
% 这里以平均功率最大为主选择准则，同时记录方差用于观察两者是否一致。
numWaveformSamples = numel(waveformVoltage);
if numWaveformSamples < oversample
    error('CTLE waveform length must be no less than oversample.');
end
phasePower = zeros(1, oversample);
phaseVariance = zeros(1, oversample);
phaseSampleCount = zeros(1, oversample);

% 扫描每个候选相位，在所有 UI 上抽取同相位样本并计算功率/方差。
for phaseIndex = 1:oversample
    phaseSamples = waveformVoltage(phaseIndex:oversample:end);
    phaseSampleCount(phaseIndex) = numel(phaseSamples);
    phasePower(phaseIndex) = mean(phaseSamples .^ 2);
    phaseVariance(phaseIndex) = var(phaseSamples, 1);
end

[bestPower, bestPhase] = max(phasePower);
[bestVariance, bestVariancePhase] = max(phaseVariance);

% 每 64 个抽样后的码元组成一个 TI ADC block，并一次分配给 64 个 SAR ADC lane。
% 当前 phaseOffset 为 0，用 block-by-block 采样结构预留后续 CDR 相位更新入口。
% 从 bestPhase 开始，每 oversample 点取一次可得到的总码元数。
% 只保留完整 64-lane block，尾部不足一个 block 的样本不参与转换。
numSampledSymbols = floor((numWaveformSamples - bestPhase) / oversample) + 1;
numBlocks = floor(numSampledSymbols / numLanes);
numSamplesUsed = numBlocks * numLanes;
if numBlocks < 1
    error('Not enough sampled symbols to form one 64-lane TI ADC block.');
end
sampledVoltage = zeros(1, numSamplesUsed);
sampledIndex = zeros(1, numSamplesUsed);

% 建立 64 路 TI ADC，并使用 fast code-only 路径完成转换。
adc = ti_adc_core(numLanes, VL, VH, nBits);
adc.resetToIdeal();
adc.setLaneEquivalentGain(ones(1, numLanes));
adc.setLaneEquivalentOffset(zeros(1, numLanes));
adc.setLaneSkew(zeros(1, numLanes));
adc.setLaneCapMismatch(zeros(1, numLanes));
adc.setLaneComparatorNoise(zeros(1, numLanes));

Dout_dec = zeros(1, numSamplesUsed);
currentPhase = bestPhase;
phaseOffset = 0;
for blockIndex = 1:numBlocks
    % blockResultIndex 对应输出数组中的连续 64 个位置。
    % blockSampleIndex 是本 block 在 CTLE 原始过采样波形中实际访问的样本索引。
    blockResultIndex = (blockIndex - 1) * numLanes + (1:numLanes);
    blockSampleIndex = currentPhase + (0:numLanes-1) * oversample;
    VinBlock = waveformVoltage(blockSampleIndex);
    % fast 路径只返回十进制 code，适合长波形分布统计。
    doutDecBlock = adc.convertOneBlockFast(VinBlock);

    sampledIndex(blockResultIndex) = blockSampleIndex;
    sampledVoltage(blockResultIndex) = VinBlock;
    Dout_dec(blockResultIndex) = doutDecBlock;

    % 这里预留给 DSP/CDR/自适应逻辑更新。
    % dsp_state = "ing";
    % dsp.update(doutDecBlock);
    % dsp_state = "finish";
    % 跳到下一个 64-lane block 的起始采样相位；未来 CDR 可通过 phaseOffset 提前或滞后采样。
    currentPhase = currentPhase + numLanes * oversample + phaseOffset;
end

% 利用 Dout_dec 重建 ADC 输出电压。
% Vrec 使用 lower-edge 映射，VrecCenter 使用 bin-center 映射，用于对照量化误差和分布偏移。
lsb = (VH - VL) / (2 ^ nBits);
Vrec = VL + Dout_dec * lsb;
VrecCenter = VL + (Dout_dec + 0.5) * lsb;

% 基础一致性检查。
if any(Dout_dec < 0) || any(Dout_dec > 2^nBits - 1)
    error('Output code is outside expected range.');
end
% 绘制 ADC 十进制输出码型分布，并叠加每个视觉簇的高斯拟合曲线。
% code 总范围有 2^14 个离散值，而本测试只有数千个样本；
% 如果按每个 code 一个 bin 绘图，会出现大量针状空 bin，视觉上像分布异常。
% 因此只在绘图阶段合并为 128 个 code bin，ADC 输出 Dout_dec 本身不做任何重采样或修改。
signedCodeMin = -(2 ^ (nBits - 1) - 1);
signedCodeMax = 2 ^ (nBits - 1) - 1;
Dout_signed = min(max(Dout_dec - 2 ^ (nBits - 1), signedCodeMin), signedCodeMax);
codeEdges = (signedCodeMin - 0.5):(signedCodeMax + 0.5);
codeCenters = signedCodeMin:signedCodeMax;
codeCounts = histcounts(Dout_signed, codeEdges);
codeProbability = codeCounts / sum(codeCounts);

figCode = figure('Visible', 'on', 'Color', 'w', 'Name', '64-lane TI ADC signed code distribution');
plotDistributionWithGaussianFit(codeCenters, codeProbability, [0.25, 0.45, 0.95], 4, 'code');
grid on;
xlabel('ADC Output Code (Signed Decimal)');
ylabel('Normalized probability');
title('64-lane TI ADC Signed Code Distribution');
xlim([signedCodeMin, signedCodeMax]);

codePng = fullfile(resultDir, 'test_ti_adc_core_64lane_ctle_code_distribution.png');
exportgraphics(figCode, codePng, 'Resolution', 150);

% 绘制采样点电压和 ADC 重建电压的电压分布，并分两排叠加每簇高斯拟合曲线。
numVoltageBins = 128;
voltageMin = min([sampledVoltage, Vrec, VrecCenter]);
voltageMax = max([sampledVoltage, Vrec, VrecCenter]);
if voltageMin == voltageMax
    voltageMin = voltageMin - lsb;
    voltageMax = voltageMax + lsb;
end
voltageEdges = linspace(voltageMin, voltageMax, numVoltageBins + 1);
voltageCenters = (voltageEdges(1:end-1) + voltageEdges(2:end)) / 2;
sampledVoltageCounts = histcounts(sampledVoltage, voltageEdges);
reconstructedVoltageCounts = histcounts(Vrec, voltageEdges);
centerReconstructedVoltageCounts = histcounts(VrecCenter, voltageEdges);
sampledVoltageProbability = sampledVoltageCounts / sum(sampledVoltageCounts);
reconstructedVoltageProbability = reconstructedVoltageCounts / sum(reconstructedVoltageCounts);
centerReconstructedVoltageProbability = centerReconstructedVoltageCounts / sum(centerReconstructedVoltageCounts);

figVoltage = figure('Visible', 'on', 'Color', 'w', 'Name', 'Sampled and reconstructed voltage distribution');
subplot(3, 1, 1);
plotDistributionWithGaussianFit(voltageCenters, sampledVoltageProbability, [0.00, 0.35, 0.95], 4, 'sampledVoltage');
grid on;
xlabel('Sampled CTLE voltage (V)');
ylabel('Normalized probability');
title('Sampled CTLE Voltage Distribution');
xlim([voltageMin, voltageMax]);

subplot(3, 1, 2);
plotDistributionWithGaussianFit(voltageCenters, reconstructedVoltageProbability, [0.95, 0.20, 0.20], 4, 'reconstructedVoltage');
grid on;
xlabel('ADC lower-edge reconstructed voltage (V)');
ylabel('Normalized probability');
title('ADC Lower-edge Reconstructed Voltage Distribution');
xlim([voltageMin, voltageMax]);

subplot(3, 1, 3);
plotDistributionWithGaussianFit(voltageCenters, centerReconstructedVoltageProbability, [0.20, 0.65, 0.20], 4, 'centerReconstructedVoltage');
grid on;
xlabel('ADC bin-center reconstructed voltage (V)');
ylabel('Normalized probability');
title('ADC Bin-center Reconstructed Voltage Distribution');
xlim([voltageMin, voltageMax]);

voltagePng = fullfile(resultDir, 'test_ti_adc_core_64lane_ctle_voltage_distribution.png');
exportgraphics(figVoltage, voltagePng, 'Resolution', 150);

% 绘制相位扫描指标，便于确认最佳采样点位置。
figPhase = figure('Visible', 'on', 'Color', 'w', 'Name', 'CTLE waveform phase scan');
subplot(2, 1, 1);
plot(1:oversample, phasePower, 'LineWidth', 1.2);
hold on;
plot(bestPhase, bestPower, 'o', 'MarkerSize', 6, 'LineWidth', 1.2);
grid on;
xlabel('Phase Index');
ylabel('Mean Power');
title('Phase Scan by Sampled Voltage Power');
xlim([1, oversample]);

subplot(2, 1, 2);
plot(1:oversample, phaseVariance, 'LineWidth', 1.2);
hold on;
plot(bestVariancePhase, bestVariance, 'o', 'MarkerSize', 6, 'LineWidth', 1.2);
grid on;
xlabel('Phase Index');
ylabel('Variance');
title('Phase Scan by Sampled Voltage Variance');
xlim([1, oversample]);

phasePng = fullfile(resultDir, 'test_ti_adc_core_64lane_ctle_phase_scan.png');
exportgraphics(figPhase, phasePng, 'Resolution', 150);

% 刷新图形事件队列，保证交互式运行时 figure 会立即显示出来；
% batch/headless 运行时该语句不会改变 PNG 保存行为。
drawnow;

% 打印测试摘要。
fprintf('TI ADC lanes: %d\n', numLanes);
fprintf('ADC bits: %d\n', nBits);
fprintf('ADC full range: [%.6g, %.6g] V\n', VL, VH);
fprintf('First sampled waveform index: %d\n', sampledIndex(1));
fprintf('Completed blocks: %d\n', numBlocks);
fprintf('Completed conversions: %d\n', numSamplesUsed);
end

% 以直方图概率为权重估计每个视觉簇的均值/方差，叠加高斯拟合曲线仅作为视觉参考。
function plotDistributionWithGaussianFit(xValue, yValue, barColor, maxClusterCount, labelMode)
%PLOTDISTRIBUTIONWITHGAUSSIANFIT 绘制分布 bar 图，并为每个视觉簇叠加高斯拟合曲线。
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

    mu = sum(clusterX .* clusterY) / clusterMass;
    sigma = sqrt(sum(((clusterX - mu) .^ 2) .* clusterY) / clusterMass);
    if sigma <= 0
        sigma = max(mean(diff(xValue)), eps(mu));
    end

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

if isempty(fitPeakX)
    [fitPeakX, fitPeakY] = findDistributionClusterPeaks(xValue, yValue, maxClusterCount);
end
annotateDistributionPeaks(fitPeakX, fitPeakY, fitYMax, labelMode);
end

function [clusterStart, clusterStop] = findDistributionClusters(xValue, yValue, maxClusterCount)
%FINDDISTRIBUTIONCLUSTERS 查找显著分布簇，并按需要合并被局部低谷切开的近邻区域。
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
%FINDDISTRIBUTIONCLUSTERPEAKS 查找显著分布簇的峰值横坐标。
%   先用低阈值找出有效分布区域；如果同一视觉簇被局部低谷切开，
%   则优先合并横向间隔最近的相邻区域，直到满足期望簇数。
%   每个簇最终只取概率最高的 bin 作为峰值。
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
%ANNOTATEDISTRIBUTIONPEAKS 在分布图中标注每簇峰值对应横坐标。
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
        case 'sampledVoltage'
            markerColor = [0.00, 0.20, 0.85];
            labelText = sprintf('%.4g V', peakX(peakIndex));
        otherwise
            markerColor = [0.85, 0.10, 0.10];
            labelText = sprintf('%.4g V', peakX(peakIndex));
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
