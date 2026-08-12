%{
% 文件功能说明：
% 本脚本用于对比两种 CTLE 输出波形前导延时估计方法对眼图绘制结果的影响。
% 方法一沿用阈值法，从 CTLE 输出中寻找第一段稳定超过阈值的有效样本，作为有效波形起点。
% 方法二使用 TX 经过 DAC 后的过采样波形作为参考，与 CTLE 输出波形做归一化互相关，寻找参考波形在 CTLE 输出中的最佳匹配起点。
% 两种方法分别去除前导延时后，直接从 delay index 后一个样本开始按 UI 周期叠加绘制眼图，并额外生成一张上下两排对比图。
% 其中互相关方法属于 TX 参考波形与 CTLE 输出波形之间的互相关；由于比较的是两路不同波形，不是单一路波形自身的自相关。
%}
function compare_delay_eye_methods()
%COMPARE_DELAY_EYE_METHODS Compare threshold-based and cross-correlation-based CTLE eye diagrams.

% 获取当前脚本所在目录，保证输入 CSV 和输出 result 文件夹都相对于本脚本目录定位。
scriptDir = fileparts(mfilename('fullpath'));
% TX 经过 DAC 后的过采样输出波形，用作互相关参考波形。
txCsvPath = fullfile(scriptDir, 'waveform_TX.csv');
% CTLE 输出波形，是阈值法和互相关法共同需要处理的接收端波形。
ctleCsvPath = fullfile(scriptDir, 'waveform_CTLE.csv');
% 所有 PNG 结果统一保存到脚本同目录下的 result 文件夹。
resultDir = fullfile(scriptDir, 'result');

% 链路和绘图参数：112 Gbps PAM4，每个 symbol 承载 2 bit，因此 symbol rate 为 56 GBaud。
oversample = 128;
dataRate = 112e9;
bitsPerSymbol = 2;
symbolRate = dataRate / bitsPerSymbol;
ui = 1 / symbolRate;
% 眼图横轴覆盖 2 UI，绘图时直接从 delay index 后一个样本开始叠加，显示 [0, 2] UI。
spanSymbols = 2;
% 为避免波形过长导致绘图过慢，最多抽取 2000 段眼图轨迹参与显示。
maxSegmentsToPlot = 2000;
% 阈值法使用全局峰值的 3% 作为有效信号判据，用于跳过前导近零延时段。
leadingZeroThresholdRatio = 30e-3;
% 要求连续若干个样本超过阈值，避免单个噪声点被误判为有效起点。
leadingSignalRunLength = 8;
% 互相关参考窗口长度，单位是 UI；这里使用 TX 波形前 500 UI 作为参考模板。
xcorrReferenceSymbolCount = 500;


% 检查 TX 参考波形文件是否存在，若缺失则直接报错，避免后续 readmatrix 报错不明确。
if ~exist(txCsvPath, 'file')
    error('TX CSV file was not found: %s', txCsvPath);
end

% 检查 CTLE 输出波形文件是否存在。
if ~exist(ctleCsvPath, 'file')
    error('CTLE CSV file was not found: %s', ctleCsvPath);
end

% 若 result 目录不存在，则创建该目录用于保存眼图 PNG。
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

% 读取 TX DAC 波形和 CTLE 波形。readWaveformCsv 会过滤无效行并按时间升序排序。
[txTime, txVoltage] = readWaveformCsv(txCsvPath);
[ctleTime, ctleVoltage] = readWaveformCsv(ctleCsvPath);

% 使用 CTLE 时间列估计实际采样间隔，并与 112 Gbps PAM4、128 倍过采样的理论采样间隔比较。
sampleInterval = median(diff(ctleTime));
expectedSampleInterval = ui / oversample;
sampleIntervalError = abs(sampleInterval - expectedSampleInterval) / expectedSampleInterval;

% 先识别 TX DAC 输出中的前导近零段，后续 TX 眼图和互相关参考均使用有效起点后的波形。
txDelayIndex = findThresholdDelayIndex(txVoltage, leadingZeroThresholdRatio, leadingSignalRunLength);
txEffectiveVoltage = txVoltage((txDelayIndex + 1):end);

% 如果采样间隔偏差超过 2%，给出告警；脚本仍继续运行，便于用户查看实际输出。
if sampleIntervalError > 0.02
    warning('Measured CTLE sample interval differs from 112Gbps PAM4 and oversample=128 by %.2f%%.', sampleIntervalError * 100);
end

% 方法一：阈值法寻找 CTLE 有效波形起点。
thresholdDelayIndex = findThresholdDelayIndex(ctleVoltage, leadingZeroThresholdRatio, leadingSignalRunLength);
% 从阈值法找到的起点开始截取 CTLE 波形，相当于去除前导延时。
thresholdVoltage = ctleVoltage((thresholdDelayIndex + 1):end);
% 同步构造去除延时后的时间轴，当前脚本主要用于诊断输出，眼图叠加本身只依赖样本序号。
thresholdTime = ctleTime((thresholdDelayIndex + 1):end) - ctleTime(thresholdDelayIndex + 1);

% 方法二：互相关法参考长度选择。不能超过 TX 或 CTLE 的实际样本数，也不能超过配置的 200 UI。
xcorrReferenceSampleCount = min([numel(txEffectiveVoltage), numel(ctleVoltage), xcorrReferenceSymbolCount * oversample]);
% 将参考长度向下取整为完整 UI 数，确保参考模板边界与码元边界一致。
xcorrReferenceSampleCount = floor(xcorrReferenceSampleCount / oversample) * oversample;

% 至少需要 1 UI 的参考数据才有意义，否则无法进行互相关延时搜索。
if xcorrReferenceSampleCount < oversample
    error('Not enough TX/CTLE samples to perform cross-correlation delay search.');
end

% 执行 TX 参考波形与 CTLE 波形之间的滑动归一化互相关，返回最佳匹配起点和峰值分数。
[xcorrDelayIndex, xcorrPeakScore] = findXcorrDelayIndex(txEffectiveVoltage, ctleVoltage, xcorrReferenceSampleCount);
% 从互相关找到的最佳匹配起点开始截取 CTLE 波形。
xcorrVoltage = ctleVoltage((xcorrDelayIndex + 1):end);
% 构造互相关延时去除后的时间轴，便于调试和后续扩展。
xcorrTime = ctleTime((xcorrDelayIndex + 1):end) - ctleTime(xcorrDelayIndex + 1);

% 两种延时去除结果使用完全相同的眼图构造逻辑，均不再搜索眼图张开最大相位，避免绘图算法差异影响对比结论。
txResult = buildEyeDiagram(txEffectiveVoltage, oversample, spanSymbols, maxSegmentsToPlot);
thresholdResult = buildEyeDiagram(thresholdVoltage, oversample, spanSymbols, maxSegmentsToPlot);
xcorrResult = buildEyeDiagram(xcorrVoltage, oversample, spanSymbols, maxSegmentsToPlot);

% 三张输出图片：阈值法单独眼图、互相关法单独眼图、两种方法上下两排对比图。
txPng = fullfile(resultDir, 'tx_dac_eye_diagram.png');
thresholdPng = fullfile(resultDir, 'ctle_eye_threshold_delay.png');
xcorrPng = fullfile(resultDir, 'ctle_eye_xcorr_delay.png');
comparePng = fullfile(resultDir, 'ctle_eye_delay_compare.png');

% 批处理运行 MATLAB 时关闭图窗显示，提升稳定性；onCleanup 确保函数退出时恢复原设置。
defaultFigureVisible = get(0, 'DefaultFigureVisible');
figureVisibilityCleanup = onCleanup(@() set(0, 'DefaultFigureVisible', defaultFigureVisible));
set(0, 'DefaultFigureVisible', 'off');

% 绘制并保存阈值法延时去除后的单独眼图。
% 绘制并保存 TX DAC 输出波形眼图，用于和 CTLE 输出眼图进行相位与形状对比。
txFigure = figure('Color', 'w', 'Name', 'TX DAC Output Eye Diagram');
txAxes = axes('Parent', txFigure);
plotEyeDiagram(txAxes, txResult, sprintf('TX DAC Output Eye Diagram, start = effective index + 1, delay = %d samples', txDelayIndex));
exportgraphics(txFigure, txPng, 'Resolution', 300);
close(txFigure);

thresholdFigure = figure('Color', 'w', 'Name', 'CTLE Eye Diagram - Threshold Delay');
thresholdAxes = axes('Parent', thresholdFigure);
plotEyeDiagram(thresholdAxes, thresholdResult, sprintf('Threshold Delay Eye Diagram, start = delay index + 1, delay = %d samples', thresholdDelayIndex));
exportgraphics(thresholdFigure, thresholdPng, 'Resolution', 300);
close(thresholdFigure);

% 绘制并保存互相关法延时去除后的单独眼图。
xcorrFigure = figure('Color', 'w', 'Name', 'CTLE Eye Diagram - Cross-Correlation Delay');
xcorrAxes = axes('Parent', xcorrFigure);
plotEyeDiagram(xcorrAxes, xcorrResult, sprintf('Cross-Correlation Delay Eye Diagram, start = delay index + 1, delay = %d samples', xcorrDelayIndex));
exportgraphics(xcorrFigure, xcorrPng, 'Resolution', 300);
close(xcorrFigure);

% 绘制两种延时估计方法的对比图。这里按用户要求改为上下两排，即 2 行 1 列布局。
compareFigure = figure('Color', 'w', 'Name', 'CTLE Eye Diagram Delay Method Compare');
compareLayout = tiledlayout(compareFigure, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
% 第一排显示阈值法眼图。
thresholdCompareAxes = nexttile(compareLayout, 1);
plotEyeDiagram(thresholdCompareAxes, thresholdResult, sprintf('Threshold, start = delay index + 1, delay = %d samples', thresholdDelayIndex));
% 第二排显示互相关法眼图。
xcorrCompareAxes = nexttile(compareLayout, 2);
plotEyeDiagram(xcorrCompareAxes, xcorrResult, sprintf('Xcorr, start = delay index + 1, delay = %d samples', xcorrDelayIndex));
title(compareLayout, 'CTLE Eye Diagram Delay Method Compare');
exportgraphics(compareFigure, comparePng, 'Resolution', 300);
close(compareFigure);

% 在命令行输出输入文件、链路参数、两种延时估计结果和输出图片路径，便于审查与复现实验。
fprintf('TX CSV file: %s\n', txCsvPath);
fprintf('CTLE CSV file: %s\n', ctleCsvPath);
fprintf('Original TX samples: %d\n', numel(txVoltage));
fprintf('Original CTLE samples: %d\n', numel(ctleVoltage));
fprintf('Data rate: %.12g bps\n', dataRate);
fprintf('Bits per symbol: %d\n', bitsPerSymbol);
fprintf('Symbol rate: %.12g Baud\n', symbolRate);
fprintf('UI: %.12g s\n', ui);
fprintf('Oversample: %d\n', oversample);
fprintf('Measured CTLE sample interval: %.12g s\n', sampleInterval);
fprintf('Expected sample interval: %.12g s\n', expectedSampleInterval);
fprintf('Sample interval error: %.6g%%\n', sampleIntervalError * 100);
fprintf('TX DAC effective start index: %d\n', txDelayIndex);
fprintf('TX DAC effective start index mod oversample: %d\n', mod(txDelayIndex, oversample));
fprintf('TX DAC effective start removed samples: %d\n', txDelayIndex);
fprintf('TX DAC effective start time: %.12g s\n', txDelayIndex * sampleInterval);
fprintf('TX DAC samples after effective start: %d\n', numel(txEffectiveVoltage));
fprintf('Threshold delay index: %d\n', thresholdDelayIndex);
fprintf('Threshold delay index mod oversample: %d\n', mod(thresholdDelayIndex, oversample));
fprintf('Threshold eye start removed samples mod oversample: %d\n', mod(thresholdDelayIndex, oversample));
fprintf('Threshold eye start removed samples: %d\n', thresholdDelayIndex);
fprintf('Threshold removed delay time: %.12g s\n', thresholdDelayIndex * sampleInterval);
fprintf('Threshold channel delay index: %d\n', thresholdDelayIndex - txDelayIndex);
fprintf('Threshold channel delay: %.12g ns\n', (thresholdDelayIndex - txDelayIndex) * sampleInterval * 1e9);
fprintf('Threshold samples after delay removal: %d\n', numel(thresholdVoltage));
fprintf('Threshold eye center offset: %d samples\n', thresholdResult.centerOffset);
fprintf('Threshold eye segment start offset: %d samples\n', thresholdResult.segmentStartOffset);
fprintf('Xcorr reference sample count: %d samples\n', xcorrReferenceSampleCount);
fprintf('Xcorr reference symbol count: %d UI\n', xcorrReferenceSampleCount / oversample);
fprintf('Xcorr delay index: %d\n', xcorrDelayIndex);
fprintf('Xcorr delay index mod oversample: %d\n', mod(xcorrDelayIndex, oversample));
fprintf('Xcorr eye start removed samples mod oversample: %d\n', mod(xcorrDelayIndex, oversample));
fprintf('Xcorr eye start removed samples: %d\n', xcorrDelayIndex);
fprintf('Xcorr removed delay time: %.12g s\n', xcorrDelayIndex * sampleInterval);
fprintf('Xcorr channel delay index: %d\n', xcorrDelayIndex);
fprintf('Xcorr channel delay: %.12g ns\n', xcorrDelayIndex * sampleInterval * 1e9);
fprintf('Xcorr samples after delay removal: %d\n', numel(xcorrVoltage));
fprintf('Xcorr peak normalized score: %.12g\n', xcorrPeakScore);
fprintf('Xcorr eye center offset: %d samples\n', xcorrResult.centerOffset);
fprintf('Xcorr eye segment start offset: %d samples\n', xcorrResult.segmentStartOffset);
fprintf('TX DAC eye diagram saved: %s\n', txPng);
fprintf('Threshold eye diagram saved: %s\n', thresholdPng);
fprintf('Xcorr eye diagram saved: %s\n', xcorrPng);
fprintf('Compare eye diagram saved: %s\n', comparePng);
end

function [time, voltage] = readWaveformCsv(csvPath)
%READWAVEFORMCSV 读取两列波形 CSV，并返回按时间升序排列的时间和电压向量。
% CSV 第 1 列应为时间，第 2 列应为幅度/电压；其他列即使存在也不会参与当前计算。

% readmatrix 直接读取数值矩阵；后续删除包含 NaN 或 Inf 的无效行。
waveformData = readmatrix(csvPath);
waveformData = waveformData(all(isfinite(waveformData), 2), :);

% 当前脚本至少需要时间列和幅度列，否则无法估计采样间隔或绘制眼图。
if size(waveformData, 2) < 2
    error('CSV file must contain at least two columns: time and amplitude. File: %s', csvPath);
end

% 拆分时间和电压，并按时间排序，避免输入 CSV 行顺序异常影响后续连续采样假设。
time = waveformData(:, 1);
voltage = waveformData(:, 2);
[time, sortIndex] = sort(time);
voltage = voltage(sortIndex);
end

function delayIndex = findThresholdDelayIndex(voltage, leadingZeroThresholdRatio, leadingSignalRunLength)
%FINDTHRESHOLDDELAYINDEX 使用幅度阈值寻找波形有效起点。
% 返回的 delayIndex 是 MATLAB 1-based 索引，表示第一段稳定超过阈值的样本位置。

% 以全局峰值的固定比例作为有效信号阈值，并设置极小下限避免阈值为 0。
signalPeak = max(abs(voltage));
leadingZeroThreshold = max(signalPeak * leadingZeroThresholdRatio, 1e-15);
% 标记幅度超过阈值的样本。
isSignalSample = abs(voltage) > leadingZeroThreshold;
% 统计局部连续有效样本数量，用于排除单点噪声或毛刺造成的误触发。
runCount = conv(double(isSignalSample), ones(leadingSignalRunLength, 1), 'same');
% 找到第一处满足“当前样本超过阈值且附近连续有效样本足够多”的位置。
delayIndex = find(isSignalSample & runCount >= leadingSignalRunLength, 1, 'first');

% 如果连续判据过严导致未找到，则退化为第一个超过阈值的样本。
if isempty(delayIndex)
    delayIndex = find(isSignalSample, 1, 'first');
end

% 如果仍找不到有效信号，说明 CTLE 波形可能全零或输入数据异常。
if isempty(delayIndex)
    error('No non-zero waveform samples were found after applying the leading-zero threshold.');
end
end

function [delayIndex, peakScore] = findXcorrDelayIndex(txVoltage, rxVoltage, referenceSampleCount)
%FINDXCORRDELAYINDEX 使用 TX 参考波形与 CTLE 输出波形的归一化互相关寻找延时。
% delayIndex 表示 txVoltage(1) 在 rxVoltage 中最佳对齐的位置，即参考波形起点对应的 CTLE 样本索引。
% peakScore 是归一化互相关峰值，用于衡量最佳匹配窗口与 TX 参考模板的相似程度。

% 取 TX 波形开头 referenceSampleCount 个样本作为互相关模板。
txReference = txVoltage(1:referenceSampleCount);
% 对参考模板去直流，避免 DC 偏置主导相关结果。
txReference = txReference(:) - mean(txReference);
txReferenceNorm = norm(txReference);

% 如果去均值后参考波形能量为 0，则无法进行归一化互相关。
if txReferenceNorm <= 0
    error('TX reference waveform has zero norm after mean removal.');
end

% 将 CTLE 输出转换为列向量，便于卷积计算滑动相关。
rx = rxVoltage(:);
% rawCorrelation(k) 对应 TX 模板与 rx(k:k+referenceSampleCount-1) 的内积。
rawCorrelation = conv(rx, flipud(txReference), 'valid');
% 计算每个滑动窗口内的样本和，用于窗口去均值能量计算。
rxWindowSum = conv(rx, ones(referenceSampleCount, 1), 'valid');
% 计算每个滑动窗口内的平方和。
rxWindowEnergy = conv(rx .^ 2, ones(referenceSampleCount, 1), 'valid');
% 根据 E[(x-mean)^2] = E[x^2] - N * mean(x)^2 计算去直流后的窗口能量。
rxCenteredEnergy = rxWindowEnergy - (rxWindowSum .^ 2) / referenceSampleCount;
% 数值误差可能导致极小负数，取 max 保证后续 sqrt 合法。
rxCenteredEnergy = max(rxCenteredEnergy, 0);
% 归一化分母为 RX 窗口范数乘以 TX 参考范数。
scoreDenominator = sqrt(rxCenteredEnergy) * txReferenceNorm;
normalizedScore = zeros(size(rawCorrelation));
% 仅对分母大于 0 的窗口计算归一化得分。
validScoreIndex = scoreDenominator > 0;
normalizedScore(validScoreIndex) = rawCorrelation(validScoreIndex) ./ scoreDenominator(validScoreIndex);

% 归一化得分最大的窗口起点即为互相关法估计的 CTLE 延时起点。
[peakScore, delayIndex] = max(normalizedScore);
end

function eyeResult = buildEyeDiagram(voltage, oversample, spanSymbols, maxSegmentsToPlot)
%BUILDEYEDIAGRAM 根据去除延时后的波形构造眼图绘图所需的数据。
% 该函数不再搜索眼图张开位置最大的相位，而是直接从输入波形的第一个样本开始，按 1 UI 步长叠加 2 UI 片段。

samplesPerSymbol = oversample;
% 眼图每段长度为 2 UI。
segmentLength = spanSymbols * samplesPerSymbol;
% 不再进行 centerOffset/eye-opening 搜索，直接从去延时后的第一个样本作为眼图片段起点。
segmentStartOffset = 0;
centerOffset = 0;
maxPowerOffset = 0;
% 计算可叠加的完整 2 UI 片段数量。
segmentCount = floor((numel(voltage) - segmentStartOffset - segmentLength) / samplesPerSymbol) + 1;

% 如果去除延时后剩余样本不足以构成一个完整眼图片段，则报错。
if segmentCount < 1
    error('Not enough waveform samples to draw an eye diagram after removing leading delay samples.');
end

% 如果片段过多，则按固定步长抽取，避免 PNG 过大或绘图过慢。
if segmentCount > maxSegmentsToPlot
    segmentStep = floor(segmentCount / maxSegmentsToPlot);
else
    segmentStep = 1;
end

% 保存眼图绘制所需的全部结果。电压先去均值，使眼图垂直方向以平均值附近为中心。
eyeResult.voltage = voltage(:) - mean(voltage);
% 横轴单位为 UI，范围为 [0, 2)，与从 delayIndex+1 后数据直接叠加的 2 UI 片段长度对应。
eyeResult.eyeTime = (0:(segmentLength - 1)).' / samplesPerSymbol;
eyeResult.samplesPerSymbol = samplesPerSymbol;
eyeResult.segmentLength = segmentLength;
eyeResult.segmentStartOffset = segmentStartOffset;
eyeResult.segmentCount = segmentCount;
eyeResult.segmentStep = segmentStep;
eyeResult.maxPowerOffset = maxPowerOffset;
eyeResult.centerOffset = centerOffset;
end

function plotEyeDiagram(axesHandle, eyeResult, plotTitle)
%PLOTEYEDIAGRAM 将 buildEyeDiagram 得到的 2 UI 波形片段叠加绘制为眼图。
% axesHandle 指定绘图坐标轴，便于同一绘图逻辑复用于单图和 tiledlayout 对比图。

hold(axesHandle, 'on');

% 按 segmentStep 抽取片段，每个片段长度为 2 UI，并叠加到同一坐标轴中。
for segmentIndex = 1:eyeResult.segmentStep:eyeResult.segmentCount
    startIndex = (segmentIndex - 1) * eyeResult.samplesPerSymbol + eyeResult.segmentStartOffset + 1;
    stopIndex = startIndex + eyeResult.segmentLength - 1;
    plot(axesHandle, eyeResult.eyeTime, eyeResult.voltage(startIndex:stopIndex), 'b-', 'LineWidth', 0.35);
end

% 设置坐标轴、标题和显示范围，当前直接从 delayIndex+1 后的数据开始显示 2 UI。
grid(axesHandle, 'on');
xlabel(axesHandle, 'Time (UI, start after delay index + 1)');
ylabel(axesHandle, 'Amplitude');
title(axesHandle, plotTitle);
xlim(axesHandle, [0 2]);
end
