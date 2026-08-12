%{
% 文件功能说明：
% 本文件用于对 CTLE 输出波形进行 1 sample/UI 采样，并调用 SAR ADC core 的 fast 接口完成量化转换。
% 主要流程包括：读取 waveform.csv、剔除前导延迟近零样本、在 128 个候选相位上用 200 个 symbol 计算功率和、
% 选择功率和最大的相位作为采样相位、调用 convertInstantFast 和 convertVectorFast、输出采样 CSV、
% 绘制采样时序图、三行电压概率分布 bar 图以及两行十进制 code 概率分布 bar 图。
% 代码中的变量定义、计算逻辑和函数调用均保持原样；本次修改仅新增中文注释，便于理解和审查。
%}
function sample_ctle_with_adc()
% MATLAB 函数说明行：sample_ctle_with_adc 不需要输入参数，直接处理同目录 waveform.csv。
%SAMPLE_CTLE_WITH_ADC Sample CTLE output at 1 sample/UI and run SAR ADC.

% 构造脚本目录、输入波形路径、SAR ADC core 目录和结果输出目录。
scriptDir = fileparts(mfilename('fullpath'));
csvPath = fullfile(scriptDir, 'waveform.csv');
adcCoreDir = fullfile(fileparts(scriptDir), 'SAR_ADC_core');
resultDir = fullfile(scriptDir, 'result');
% 如果 result 目录不存在，则创建该目录用于保存 CSV 和 PNG 输出。
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

% 检查 SAR ADC core 目录是否存在，避免后续实例化 sar_adc_core 时找不到类定义。
if ~exist(adcCoreDir, 'dir')
    error('SAR ADC core folder was not found: %s', adcCoreDir);
end
% 将 SAR_ADC_core 目录加入 MATLAB 搜索路径开头，确保调用到当前工程中的 ADC core。
addpath(adcCoreDir, '-begin');

% 保存并临时关闭 figure 可见性，便于 MATLAB batch 模式下稳定导出图片并避免窗口阻塞。
defaultFigureVisible = get(0, 'DefaultFigureVisible');
% 使用 onCleanup 保证函数退出时恢复原始 figure 可见性设置。
figureVisibilityCleanup = onCleanup(@() set(0, 'DefaultFigureVisible', defaultFigureVisible));
set(0, 'DefaultFigureVisible', 'off');

% 链路和 ADC 参数设置：112 Gbps PAM4、每 symbol 2 bit、每 UI 128 个采样点。
oversample = 128;
dataRate = 112e9;
bitsPerSymbol = 2;
symbolRate = dataRate / bitsPerSymbol;
ui = 1 / symbolRate;
leadingZeroThresholdRatio = 30e-3;
leadingSignalRunLength = 8;
% ADC 输入满量程设置为 [-0.3, 0.3] V，用于减少量化范围浪费并提高有效位利用率。
adcVL = -0.3;
adcVH = 0.3;
adcBits = 7;
% 分布图参数：采样电压使用固定 bin 数，ADC code/重构电压分布使用 code 维度统计并进行平滑。
distributionBinCount = 120;
distributionSmoothWindow = 5;
distributionPeakCount = 4;

% 读取 CTLE 输出波形，并删除包含 NaN/Inf 的无效行。
waveformData = readmatrix(csvPath);
waveformData = waveformData(all(isfinite(waveformData), 2), :);
% 提取时间和电压列，并按时间升序排序，确保后续采样间隔和相位搜索基于连续时间序列。
time = waveformData(:, 1);
voltage = waveformData(:, 2);
[time, sortIndex] = sort(time);
voltage = voltage(sortIndex);

% 根据时间列估算实际采样间隔，并与 ui/oversample 理论值比较。
sampleInterval = median(diff(time));
expectedSampleInterval = ui / oversample;
sampleIntervalError = abs(sampleInterval - expectedSampleInterval) / expectedSampleInterval;
% 采样间隔偏差超过 2% 时给出 warning，提示用户检查数据率或 oversample 设置。
if sampleIntervalError > 0.02
    warning('Measured sample interval differs from expected value by %.2f%%.', sampleIntervalError * 100);
end

% 前导延迟剔除：识别波形开头由信道延迟或仿真空窗导致的近零样本段。
originalSampleCount = numel(voltage);
% 用全局峰值的一定比例形成阈值，并设置极小下限以避免阈值为 0。
signalPeak = max(abs(voltage));
leadingZeroThreshold = max(signalPeak * leadingZeroThresholdRatio, 1e-15);
% 标记超过阈值的有效信号样本。
isSignalSample = abs(voltage) > leadingZeroThreshold;
% 通过连续样本数量判断稳定信号起点，降低单点噪声触发的概率。
runCount = conv(double(isSignalSample), ones(leadingSignalRunLength, 1), 'same');
% 找到第一处满足连续有效样本条件的位置，作为前导延迟结束点。
firstSignalIndex = find(isSignalSample & runCount >= leadingSignalRunLength, 1, 'first');
if isempty(firstSignalIndex)
    firstSignalIndex = find(isSignalSample, 1, 'first');
end
if isempty(firstSignalIndex)
    error('No non-zero waveform samples were found.');
end

% 记录并计算被删除的前导延迟长度，用于最终日志输出。
leadingDelaySamples = firstSignalIndex - 1;
leadingDelayTime = leadingDelaySamples * sampleInterval;
% 删除前导延迟样本，并让删除后的时间从 0 开始，方便采样时间解释。
if leadingDelaySamples > 0
    time = time(firstSignalIndex:end) - time(firstSignalIndex);
    voltage = voltage(firstSignalIndex:end);
end

% 采样相位搜索：使用删除延迟后的前 200 个 symbol，对 128 个候选相位分别计算功率和。
phaseSearchSymbolCount = 200;
% 若有效数据不足 200 UI，则自动限制搜索 UI 数，避免索引越界。
phaseSearchSymbolCount = min(phaseSearchSymbolCount, floor(numel(voltage) / oversample));
if phaseSearchSymbolCount < 1
    error('Not enough waveform samples to search sampling phase after removing leading delay samples.');
end
phaseSearchSampleCount = phaseSearchSymbolCount * oversample;
% phasePower 保存每个候选相位按 1 sample/UI 抽样后的功率和。
phasePower = zeros(oversample, 1);

% 遍历 128 个候选相位；每个相位每隔 128 点取一个样本，覆盖 phaseSearchSymbolCount 个 symbol。
for phaseIndex = 1:oversample
    % 当前相位对应的候选采样序列。功率和越大，通常越接近 PAM4 码元中心和眼图张开位置。
    phaseSamples = voltage(phaseIndex:oversample:phaseSearchSampleCount);
    phasePower(phaseIndex) = sum(phaseSamples .^ 2);
end

% 选择功率和最大的候选相位作为最终 1 sample/UI 采样相位。MATLAB 下标从 1 开始，因此随后减 1 得到 offset。
[~, centerOffset] = max(phasePower);
centerOffset = centerOffset - 1;
% 按选定相位从波形中每隔 128 个样本采一次，实现每个 UI 只采样一次。
sampleIndices = (centerOffset + 1):oversample:numel(voltage);
sampleTimes = time(sampleIndices);
sampledVoltage = voltage(sampleIndices);
% 构造从 0 开始的 symbol 序号，作为 CSV 和时序图横轴。
symbolIndex = (0:(numel(sampleIndices) - 1)).';

% 统一转换为列向量，保证 table 输出和 ADC API 返回值维度一致。
sampledVoltage = sampledVoltage(:);
sampleTimes = sampleTimes(:);
sampleIndices = sampleIndices(:);

% 切换到 SAR ADC core 目录执行 ADC 转换，并用 onCleanup 确保函数退出后恢复原工作目录。
originalDir = pwd;
cleanupObj = onCleanup(@() cd(originalDir));
cd(adcCoreDir);
% 创建用于 convertInstantFast 的 SAR ADC 实例，并逐点调用 fast 单点转换接口。
adcInstant = sar_adc_core(adcVL, adcVH, adcBits);
adcInstantCode = zeros(size(sampledVoltage));
adcInstantVout = zeros(size(sampledVoltage));
% 对每一个 CTLE 采样电压调用 convertInstantFast，记录十进制 code 和重构输出电压。
for sampleIndex = 1:numel(sampledVoltage)
    [adcInstantCode(sampleIndex), adcInstantVout(sampleIndex)] = adcInstant.convertInstantFast(sampledVoltage(sampleIndex));
end

% 创建独立 ADC 实例调用 convertVectorFast，用于一次性处理整个采样向量。
adcVector = sar_adc_core(adcVL, adcVH, adcBits);
[adcVectorCode, adcVectorVout] = adcVector.convertVectorFast(sampledVoltage);
cd(originalDir);
% 将 vector fast 返回结果统一整理为列向量，便于与 instant fast 结果比较和写表。
adcVectorCode = adcVectorCode(:);
adcVectorVout = adcVectorVout(:);

% 汇总每个 symbol 的采样下标、采样时间、CTLE 电压、两种 fast ADC 方法的 code 和重构电压。
adcResult = table(symbolIndex, sampleIndices, sampleTimes, sampledVoltage, adcInstantCode, adcInstantVout, adcVectorCode, adcVectorVout, ...
    'VariableNames', {'SymbolIndex', 'SampleIndexAfterDelayRemoval', 'SampleTime_s', 'SampledVoltage_V', 'InstantFastCode_dec', 'InstantFastVout_V', 'VectorFastCode_dec', 'VectorFastVout_V'});

% 定义所有输出文件路径：采样 CSV、采样时序图、电压分布图和十进制 code 分布图。
outputCsv = fullfile(resultDir, 'ctle_adc_samples.csv');
outputPng = fullfile(resultDir, 'ctle_adc_samples.png');
outputDistributionPng = fullfile(resultDir, 'ctle_adc_voltage_distribution.png');
outputCodeDistributionPng = fullfile(resultDir, 'ctle_adc_code_distribution.png');

% 保存采样和 ADC 转换结果 CSV，便于后续用 MATLAB、Python 或表格工具进一步分析。
writetable(adcResult, outputCsv);

% 绘制采样时序图：上半部分为码元中心采样电压，下半部分为 convertVectorFast 输出 code。
figureHandle = figure('Color', 'w', 'Name', 'CTLE SAR ADC Samples');
tiledlayout(figureHandle, 2, 1, 'TileSpacing', 'compact');
nexttile;
plot(symbolIndex, sampledVoltage, 'b-', 'LineWidth', 0.8);
grid on;
xlabel('Symbol index');
ylabel('Sampled CTLE voltage (V)');
title('CTLE Output Sampled at Symbol Centers');
nexttile;
stairs(symbolIndex, adcVectorCode, 'r-', 'LineWidth', 0.8);
grid on;
xlabel('Symbol index');
ylabel('ADC output code (decimal)');
title(sprintf('SAR ADC Output by convertVectorFast, N = %d, Range = [%.3g, %.3g] V', adcBits, adcVL, adcVH));
exportgraphics(figureHandle, outputPng, 'Resolution', 300);
close(figureHandle);

% 计算三类电压分布：原始 CTLE 采样电压，以及两种 fast ADC 方法得到的重构电压。
[sampledCenters, sampledProbability] = voltageDistribution(sampledVoltage, distributionBinCount, distributionSmoothWindow);
% ADC 重构电压分布按 code 统计概率，再映射到对应重构电压坐标，确保与 code 分布形态一致。
[instantFastCenters, instantFastProbability] = adcVoltageDistribution(adcInstantCode, adcInstantVout, distributionSmoothWindow);
[vectorFastCenters, vectorFastProbability] = adcVoltageDistribution(adcVectorCode, adcVectorVout, distributionSmoothWindow);
% 提取主要概率峰位置，用于在分布图中画虚线并标注对应电压值。
sampledPeakIndices = findDistributionPeaks(sampledProbability, distributionPeakCount);
instantFastPeakIndices = findDistributionPeaks(instantFastProbability, distributionPeakCount);
vectorFastPeakIndices = findDistributionPeaks(vectorFastProbability, distributionPeakCount);

% 绘制三行电压概率分布 bar 图：CTLE 采样电压、convertInstantFast 重构电压、convertVectorFast 重构电压。
figureDistributionHandle = figure('Color', 'w', 'Name', 'CTLE SAR ADC Voltage Distributions');
tiledlayout(figureDistributionHandle, 3, 1, 'TileSpacing', 'compact');
nexttile;
bar(sampledCenters, sampledProbability, 1.0, 'FaceColor', [0.2, 0.45, 1.0], 'EdgeColor', 'none');
grid on;
xlabel('Sampled CTLE voltage (V)');
ylabel('Normalized probability');
title('Sampled CTLE Voltage Distribution');
annotateVoltagePeaks(sampledCenters, sampledProbability, sampledPeakIndices, 'b');
nexttile;
bar(instantFastCenters, instantFastProbability, 1.0, 'FaceColor', [1.0, 0.25, 0.25], 'EdgeColor', 'none');
grid on;
xlabel('convertInstantFast reconstructed voltage (V)');
ylabel('Normalized probability');
title('ADC Reconstructed Voltage Distribution by convertInstantFast');
annotateVoltagePeaks(instantFastCenters, instantFastProbability, instantFastPeakIndices, 'r');
nexttile;
bar(vectorFastCenters, vectorFastProbability, 1.0, 'FaceColor', [0.2, 0.65, 0.25], 'EdgeColor', 'none');
grid on;
xlabel('convertVectorFast reconstructed voltage (V)');
ylabel('Normalized probability');
title('ADC Reconstructed Voltage Distribution by convertVectorFast');
annotateVoltagePeaks(vectorFastCenters, vectorFastProbability, vectorFastPeakIndices, [0, 0.5, 0]);
exportgraphics(figureDistributionHandle, outputDistributionPng, 'Resolution', 300);
close(figureDistributionHandle);

% 计算两种 fast ADC 方法输出十进制 code 的概率分布。
[instantFastCodes, instantFastCodeProbability] = codeDistribution(adcInstantCode, distributionSmoothWindow);
[vectorFastCodes, vectorFastCodeProbability] = codeDistribution(adcVectorCode, distributionSmoothWindow);
instantFastCodePeakIndices = findDistributionPeaks(instantFastCodeProbability, distributionPeakCount);
vectorFastCodePeakIndices = findDistributionPeaks(vectorFastCodeProbability, distributionPeakCount);

% 绘制两行十进制 code 概率分布 bar 图，并标注主要 code 峰值。
figureCodeDistributionHandle = figure('Color', 'w', 'Name', 'CTLE SAR ADC Code Distributions');
tiledlayout(figureCodeDistributionHandle, 2, 1, 'TileSpacing', 'compact');
nexttile;
bar(instantFastCodes, instantFastCodeProbability, 1.0, 'FaceColor', [1.0, 0.25, 0.25], 'EdgeColor', 'none');
grid on;
xlabel('convertInstantFast ADC output code (decimal)');
ylabel('Normalized probability');
title('ADC Decimal Code Distribution by convertInstantFast');
annotateCodePeaks(instantFastCodes, instantFastCodeProbability, instantFastCodePeakIndices, 'r');
nexttile;
bar(vectorFastCodes, vectorFastCodeProbability, 1.0, 'FaceColor', [0.2, 0.65, 0.25], 'EdgeColor', 'none');
grid on;
xlabel('convertVectorFast ADC output code (decimal)');
ylabel('Normalized probability');
title('ADC Decimal Code Distribution by convertVectorFast');
annotateCodePeaks(vectorFastCodes, vectorFastCodeProbability, vectorFastCodePeakIndices, [0, 0.5, 0]);
exportgraphics(figureCodeDistributionHandle, outputCodeDistributionPng, 'Resolution', 300);
close(figureCodeDistributionHandle);

% 输出关键诊断信息，包括延迟剔除、相位搜索、ADC 配置、两种 fast 方法一致性和文件保存路径。
fprintf('Original samples: %d\n', originalSampleCount);
fprintf('Removed leading delay samples: %d\n', leadingDelaySamples);
fprintf('Power search symbol count: %d UI\n', phaseSearchSymbolCount);
fprintf('Power search sample count: %d samples\n', phaseSearchSampleCount);
fprintf('Power-max sampling phase offset: %d samples\n', centerOffset);
fprintf('Sample index spacing: %d samples\n', oversample);
fprintf('ADC full range: [%.3g, %.3g] V\n', adcVL, adcVH);
fprintf('ADC samples: %d\n', numel(sampledVoltage));
fprintf('SAR ADC core folder: %s\n', adcCoreDir);
fprintf('convertInstantFast samples: %d\n', numel(adcInstantVout));
fprintf('convertVectorFast samples: %d\n', numel(adcVectorVout));
fprintf('Fast method code mismatch count: %d\n', nnz(adcInstantCode ~= adcVectorCode));
fprintf('Fast method max Vout difference: %.12g V\n', max(abs(adcInstantVout - adcVectorVout)));
fprintf('ADC sample CSV saved: %s\n', outputCsv);
fprintf('ADC sample plot saved: %s\n', outputPng);
fprintf('Voltage distribution plot saved: %s\n', outputDistributionPng);
fprintf('Code distribution plot saved: %s\n', outputCodeDistributionPng);
close all force;
end

% 辅助函数：对连续电压样本做直方图统计、Gaussian 平滑，并重新归一化为概率分布。
function [binCenters, normalizedProbability] = voltageDistribution(voltageSamples, binCount, smoothWindow)
% histcounts 返回每个 bin 的概率；binCenters 用于 bar 图横坐标。
[counts, binEdges] = histcounts(voltageSamples, binCount, 'Normalization', 'probability');
binCenters = (binEdges(1:end-1) + binEdges(2:end)) / 2;
normalizedProbability = smoothdata(counts, 'gaussian', smoothWindow);
% 平滑可能轻微改变概率总和，因此再次归一化，保证纵坐标仍表示概率。
probabilitySum = sum(normalizedProbability);
if probabilitySum > 0
    normalizedProbability = normalizedProbability / probabilitySum;
end
end

% 辅助函数：先按 ADC code 统计概率，再将每个 code 映射到该 code 对应的平均重构电压。
function [voltageCenters, normalizedProbability] = adcVoltageDistribution(codeSamples, voltageSamples, smoothWindow)
[codes, normalizedProbability] = codeDistribution(codeSamples, smoothWindow);
voltageCenters = nan(size(codes));

% 逐个 code 查找对应样本，并计算该 code 的平均 Vout 作为电压分布横坐标。
for codeIndex = 1:numel(codes)
    codeMask = codeSamples == codes(codeIndex);
    if any(codeMask)
        voltageCenters(codeIndex) = mean(voltageSamples(codeMask));
    end
end

% 对没有直接出现的 code 位置进行插值或填充，保证横坐标长度与 code 概率向量一致。
validIndex = isfinite(voltageCenters);
if nnz(validIndex) >= 2
    voltageCenters = interp1(codes(validIndex), voltageCenters(validIndex), codes, 'linear', 'extrap');
elseif nnz(validIndex) == 1
    voltageCenters(:) = voltageCenters(validIndex);
end
end

% 辅助函数：统计整数 ADC code 的概率分布，并进行平滑和归一化。
function [codes, normalizedProbability] = codeDistribution(codeSamples, smoothWindow)
% code 横坐标覆盖当前样本中出现的最小到最大十进制 code。
codes = min(codeSamples):max(codeSamples);
counts = histcounts(codeSamples, [codes - 0.5, codes(end) + 0.5], 'Normalization', 'probability');
normalizedProbability = smoothdata(counts(:).', 'gaussian', smoothWindow);
probabilitySum = sum(normalizedProbability);
if probabilitySum > 0
    normalizedProbability = normalizedProbability / probabilitySum;
end
end

% 辅助函数：按连续高概率区域寻找峰值，避免同一个直方图簇被重复标注。
function peakIndices = findDistributionPeaks(probability, peakCount)
if isempty(probability) || max(probability) <= 0
    peakIndices = [];
    return;
end

% 将最大概率的 10% 作为峰区域阈值；每个连续区域只保留概率最高的一个位置。
peakThreshold = max(probability) * 0.10;
isPeakRegion = probability >= peakThreshold;
regionStartIndices = find(diff([false, isPeakRegion]) == 1);
regionEndIndices = find(diff([isPeakRegion, false]) == -1);
peakIndices = zeros(size(regionStartIndices));

% 在每个连续高概率区域内寻找局部最高点，作为该簇的代表峰。
for regionIndex = 1:numel(regionStartIndices)
    regionRange = regionStartIndices(regionIndex):regionEndIndices(regionIndex);
    [~, regionPeakOffset] = max(probability(regionRange));
    peakIndices(regionIndex) = regionRange(regionPeakOffset);
end

if isempty(peakIndices)
    [~, peakIndices] = max(probability);
end

% 若峰区域数量超过 peakCount，则按峰值概率从高到低保留前 peakCount 个，并按横坐标顺序输出。
[~, sortOrder] = sort(probability(peakIndices), 'descend');
peakIndices = peakIndices(sortOrder(1:min(peakCount, numel(sortOrder))));
peakIndices = sort(peakIndices);
end

% 辅助函数：在电压分布图上为每个峰画竖直虚线，并标注对应电压值。
function annotateVoltagePeaks(binCenters, probability, peakIndices, lineColor)
hold on;
yLimit = ylim;
for peakIndex = peakIndices(:).'
    peakVoltage = binCenters(peakIndex);
    peakProbability = probability(peakIndex);
    xline(peakVoltage, '--', sprintf('%.4f V', peakVoltage), ...
        'Color', lineColor, 'LabelOrientation', 'horizontal', 'LabelVerticalAlignment', 'bottom');
    text(peakVoltage, peakProbability, sprintf(' %.4f V', peakVoltage), ...
        'Color', lineColor, 'VerticalAlignment', 'bottom', 'HorizontalAlignment', 'left');
end
ylim(yLimit);
hold off;
end

% 辅助函数：在十进制 code 分布图上为每个峰画竖直虚线，并标注对应 code。
function annotateCodePeaks(codes, probability, peakIndices, lineColor)
hold on;
yLimit = ylim;
for peakIndex = peakIndices(:).'
    peakCode = codes(peakIndex);
    peakProbability = probability(peakIndex);
    xline(peakCode, '--', sprintf('%d', peakCode), ...
        'Color', lineColor, 'LabelOrientation', 'horizontal', 'LabelVerticalAlignment', 'bottom');
    text(peakCode, peakProbability, sprintf(' %d', peakCode), ...
        'Color', lineColor, 'VerticalAlignment', 'bottom', 'HorizontalAlignment', 'left');
end
ylim(yLimit);
hold off;
end
