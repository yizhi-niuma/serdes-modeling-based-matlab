function plot_lock_vs_ref_compare()
%PLOT_LOCK_VS_REF_COMPARE 对比实际锁定相位与参考相位下的 FFE 输出直方图与 1UI 响应。
%   读取 cdr_dlev_cdrffe_sslms 的结果 .mat 与 CTLE 缓存,用收敛后的平均终值系数
%   FfeCoeffMean 在两个相位上离线重算,输出两张 2x1 对比图:
%     图1(直方图对比):上=实际锁定相位(误锁反向边沿,约 111),下=参考相位 19;
%     图2(总通路 1UI 响应对比):上=实际锁定相位,下=参考相位 19。
%   四个面板全部用同一管线、同一 FfeCoeffMean 离线重算,唯一变量是采样相位,
%   从而干净地隔离“采样相位错位”这一效应。不修改主脚本。

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
cdrValidationDir = fileparts(testDir);
validationDir = fileparts(cdrValidationDir);
repoRoot = fileparts(validationDir);
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

% --- 载入结果与缓存 ---------------------------------------------------
resultDir = fullfile(testDir, 'result', 'cdr_dlev_cdrffe_sslms');
resultMatPath = fullfile(resultDir, 'cdr_dlev_cdrffe_sslms_result.mat');
assert(isfile(resultMatPath), 'Run cdr_dlev_cdrffe_sslms first to generate the result mat.');
loaded = load(resultMatPath, 'result');
result = loaded.result;

cachePath = fullfile(cdrValidationDir, 'test_cdr', 'result', ...
    'channel_ctle_cosim', 'channel_ctle.mat');
assert(isfile(cachePath), 'The CTLE cache channel_ctle.mat is missing.');
cacheFile = matfile(cachePath);

% --- 从结果结构取回复算所需参数 ---------------------------------------
samplePerSymbol = result.SamplePerSymbol;
referencePhase = result.ReferencePhase;
adcResolutionBits = result.AdcResolutionBits;
adcFullRange = result.AdcFullRange(2);
adcZeroCode = 2 ^ (adcResolutionBits - 1);
cdrFfeTapOffset = result.CdrFfeTapOffset;
cdrFfeTapCount = numel(cdrFfeTapOffset);
cdrFfePreTapCount = result.CdrFfeMainTapIndex - 1;
ffeCoeffMean = result.FfeCoeffMean;
displayEvalOffset = result.DisplayEvalOffset;
ffeTargetCursor = result.FfeTargetCursor;
analysisStartUi = result.AnalysisStartUi;
analysisNumUi = result.AnalysisNumUi;

% ADC 结构常量与主脚本一致(未存入结果结构,按主脚本固定值)。
adcLaneCount = 64;
adcSarPerTah = 8;
adcBlockUi = 64;
histogramTargetSamples = 2048;

% --- 两个对比相位 -----------------------------------------------------
% 实际锁定相位:取 start-phase-20 那次实验自身的稳态锁定 code(per-phase),
% 比全相位共同锁相 commonLockPhase 更忠实地反映该次实验真实落点。
lockedPhase = result.LockedPhaseCode(result.HistogramPhaseIndex);
lockedStartPhase = result.StartPhaseList(result.HistogramPhaseIndex);

% --- 预备管线通用量 ---------------------------------------------------
[laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol);
channelCtleImpulse = double(cacheFile.channelCtleImpulse);
channelCtleSymbolPulse = conv(channelCtleImpulse(:), ones(samplePerSymbol, 1));

segmentFirstSample = analysisStartUi * samplePerSymbol + 1;
segmentLastSample = (analysisStartUi + analysisNumUi) * samplePerSymbol;
ctleSegment = double(cacheFile.ctleOutput(1, segmentFirstSample:segmentLastSample));

% --- 逐相位离线重算直方图与 1UI 响应 ----------------------------------
[lockHistogram, lockCenter] = computeHistogramAtPhase(ctleSegment, lockedPhase, ...
    samplePerSymbol, adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, ffeCoeffMean, ...
    cdrFfePreTapCount, adcBlockUi, histogramTargetSamples);
[refHistogram, refCenter] = computeHistogramAtPhase(ctleSegment, referencePhase, ...
    samplePerSymbol, adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, ffeCoeffMean, ...
    cdrFfePreTapCount, adcBlockUi, histogramTargetSamples);

lockCursor = computeUnitUiAtPhase(channelCtleSymbolPulse, samplePerSymbol, ...
    lockedPhase, adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, cdrFfeTapOffset, ...
    displayEvalOffset, ffeCoeffMean);
refCursor = computeUnitUiAtPhase(channelCtleSymbolPulse, samplePerSymbol, ...
    referencePhase, adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, cdrFfeTapOffset, ...
    displayEvalOffset, ffeCoeffMean);

% --- 图1:直方图对比(2x1)------------------------------------------
histogramFigurePath = fullfile(resultDir, 'cdr_ffe_histogram_lock_vs_ref.png');
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 900]);

subplot(2, 1, 1);
drawHistogramPanel(lockHistogram, lockCenter);
title(sprintf(['实际锁定相位直方图: start phase %d -> locked code %d ' ...
    '(%d samples)'], lockedStartPhase, lockedPhase, numel(lockHistogram)));

subplot(2, 1, 2);
drawHistogramPanel(refHistogram, refCenter);
title(sprintf('参考相位直方图: reference phase %d (%d samples)', ...
    referencePhase, numel(refHistogram)));

exportgraphics(fig, histogramFigurePath, 'Resolution', 150);
close(fig);

% --- 图2:总通路 1UI 响应对比(2x1)--------------------------------
responseFigurePath = fullfile(resultDir, 'cdr_total_path_ui_lock_vs_ref.png');
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 900]);

subplot(2, 1, 1);
drawUnitUiPanel(displayEvalOffset, lockCursor, ffeTargetCursor);
title(sprintf(['实际锁定相位 1UI 响应: start phase %d -> locked code %d'], ...
    lockedStartPhase, lockedPhase));

subplot(2, 1, 2);
drawUnitUiPanel(displayEvalOffset, refCursor, ffeTargetCursor);
title(sprintf('参考相位 1UI 响应: reference phase %d', referencePhase));

exportgraphics(fig, responseFigurePath, 'Resolution', 150);
close(fig);

fprintf('locked start phase = %d, locked code = %d\n', lockedStartPhase, lockedPhase);
fprintf('reference phase = %d\n', referencePhase);
fprintf('histogram figure saved: %s\n', histogramFigurePath);
fprintf('unit-UI figure saved: %s\n', responseFigurePath);
end


function [histogramSamples, center] = computeHistogramAtPhase(segment, phase, ...
    samplePerSymbol, adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, ffeCoefficients, ...
    cdrFfePreTapCount, blockUi, targetSamples)
%COMPUTEHISTOGRAMATPHASE 在固定相位跑前端得到 code 输出,取尾段样本并估计四电平中心。
outputValid = processOnePhase(segment, phase, samplePerSymbol, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    ffeCoefficients, cdrFfePreTapCount, blockUi);
if numel(outputValid) >= targetSamples
    histogramSamples = outputValid(end - targetSamples + 1:end);
else
    histogramSamples = outputValid;
end
center = estimatePam4Centers(histogramSamples);
end


function normalizedCursor = computeUnitUiAtPhase(pulse, samplePerSymbol, phase, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, adcZeroCode, ...
    laneToTimeOrder, nominalBlockLength, cdrFfeTapOffset, displayEvalOffset, ...
    ffeCoefficients)
%COMPUTEUNITUIATPHASE 在固定相位重建显示 regressor,并用 FFE 系数算归一化 1UI 响应。
cdrFfeTapCount = numel(cdrFfeTapOffset);
displayChannelOffset = ...
    (displayEvalOffset(1) - cdrFfeTapOffset(end)): ...
    (displayEvalOffset(end) - cdrFfeTapOffset(1));
displayAnalogCursor = samplePulseAtPhase(pulse, samplePerSymbol, phase, ...
    displayChannelOffset);
displayAdcCursorCode = quantizeSamplesWithTiAdc(displayAnalogCursor, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    samplePerSymbol, laneToTimeOrder, nominalBlockLength);
displayAdcCursorCodeCentered = displayAdcCursorCode - adcZeroCode;
displayRegressor = zeros(numel(displayEvalOffset), cdrFfeTapCount);
for displayRow = 1:numel(displayEvalOffset)
    for displayColumn = 1:cdrFfeTapCount
        requiredOffset = displayEvalOffset(displayRow) - ...
            cdrFfeTapOffset(displayColumn);
        channelIndex = find(displayChannelOffset == requiredOffset, 1);
        assert(~isempty(channelIndex), ...
            'The total-path display window requires an unavailable channel cursor.');
        displayRegressor(displayRow, displayColumn) = ...
            displayAdcCursorCodeCentered(channelIndex);
    end
end
displayMainRow = find(displayEvalOffset == 0, 1);
outputCursor = reshape(displayRegressor * ffeCoefficients(:), 1, []);
normalizedCursor = outputCursor / outputCursor(displayMainRow);
end


function drawHistogramPanel(samples, center)
%DRAWHISTOGRAMPANEL 画单个直方图面板并标注四电平中心。
histogram(samples, 'BinMethod', 'integers', ...
    'FaceColor', [0.2 0.4 0.8], 'EdgeColor', 'none');
hold on;
for level = 1:numel(center)
    xline(center(level), 'r--', 'LineWidth', 1.0);
end
hold off;
grid on;
xlabel('Converged CDR FFE Output (code domain)');
ylabel('Sample Count');
end


function drawUnitUiPanel(evalOffset, normalizedCursor, targetCursor)
%DRAWUNITUIPANEL 画单个总通路 1UI 响应面板(stem + 数值标注)。
mainRow = find(evalOffset == 0, 1);
stemHandle = stem(evalOffset, normalizedCursor, 'filled', ...
    'LineWidth', 1.3, 'Color', [0.2 0.4 0.8]);
stemHandle.MarkerSize = 6;
hold on;
stem(0, normalizedCursor(mainRow), 'filled', ...
    'LineWidth', 1.6, 'Color', [0.85 0.2 0.2], 'MarkerSize', 8);
yline(targetCursor, 'k--', sprintf('pre1/post1 target %.3f', targetCursor), ...
    'LineWidth', 1.0);
yline(0, 'k:');
for cursorIdx = 1:numel(evalOffset)
    text(evalOffset(cursorIdx), normalizedCursor(cursorIdx), ...
        sprintf('%.3f', normalizedCursor(cursorIdx)), ...
        'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
        'FontSize', 7);
end
hold off;
grid on;
xlim([evalOffset(1) - 0.5, evalOffset(end) + 0.5]);
xticks(evalOffset);
xlabel('Cursor Offset (UI, 0 = main)');
ylabel('Normalized Total-Path Response (main = 1)');
end


function outputValid = processOnePhase(segment, phase, samplePerSymbol, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, blockUi)
%PROCESSONEPHASE 在一个固定相位上跑 TI ADC 与 CDR FFE,返回 code 域有效输出。
numUi = floor((numel(segment) - phase - 1) / samplePerSymbol) + 1;
numBlocks = floor(numUi / blockUi);
adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
ffeModel = cdr_ffe(cdrFfeCoefficients, cdrFfePreTapCount);
cdrFfePostTapCount = ffeModel.PostTapCount;
codeStream = zeros(1, numBlocks * blockUi);
for blockIndex = 1:numBlocks
    firstUi = (blockIndex - 1) * blockUi;
    blockStart = firstUi * samplePerSymbol + phase + 1;
    blockStop = blockStart + nominalBlockLength - 1;
    blockWaveform = segment(blockStart:blockStop);
    physicalCode = adcModel.convertOneBlockFast(blockWaveform, 1);
    centeredCode = double(physicalCode(laneToTimeOrder)) - adcZeroCode;
    codeStream((blockIndex - 1) * blockUi + (1:blockUi)) = centeredCode;
end
inputWindow = [zeros(1, cdrFfePostTapCount), codeStream, ...
    zeros(1, cdrFfePreTapCount)];
outputBlock = ffeModel.processBlock(inputWindow);
valid = true(1, numel(outputBlock));
valid(1:cdrFfePostTapCount) = false;
valid(end - cdrFfePreTapCount + 1:end) = false;
outputValid = outputBlock(valid);
end


function [laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol)
%ADCLANEORDERING 返回物理 lane 重排索引与本地块长度。
laneNumber = 1:adcLaneCount;
numTah = adcLaneCount / adcSarPerTah;
lanePhaseIndex = floor((laneNumber - 1) / adcSarPerTah) + 1;
laneSarIndex = mod(laneNumber - 1, adcSarPerTah) + 1;
laneTimeOrderIndex = (laneSarIndex - 1) * numTah + lanePhaseIndex;
[~, laneToTimeOrder] = sort(laneTimeOrderIndex);
nominalBlockLength = (adcLaneCount - 1) * samplePerSymbol + 1;
end


function sample = samplePulseAtPhase(pulse, samplePerSymbol, phase, offset)
%SAMPLEPULSEATPHASE 在固定 UI 偏移处采样符号脉冲响应。
[~, pulsePeakIndex] = max(abs(pulse));
mainUi = round((pulsePeakIndex - 1 - phase) / samplePerSymbol);
mainIndex = mainUi * samplePerSymbol + phase + 1;
sampleIndex = mainIndex + offset * samplePerSymbol;
assert(sampleIndex(1) >= 1 && sampleIndex(end) <= numel(pulse), ...
    'Requested symbol-pulse cursor window exceeds available data.');
sample = reshape(pulse(sampleIndex), 1, []);
end


function code = quantizeSamplesWithTiAdc(sample, adcLaneCount, ...
    adcSarPerTah, adcResolutionBits, adcFullRange, samplePerSymbol, ...
    laneToTimeOrder, nominalBlockLength)
%QUANTIZESAMPLEWITHTIADC 量化最多一个 64-UI 块的 cursor 样本。
assert(numel(sample) <= adcLaneCount, ...
    'Cursor sample count exceeds one TI ADC block.');
adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
waveform = zeros(1, nominalBlockLength);
sampleLocation = 1 + (0:adcLaneCount - 1) * samplePerSymbol;
waveform(sampleLocation(1:numel(sample))) = sample;
physicalCode = adcModel.convertOneBlockFast(waveform, 1);
timeOrderedCode = double(physicalCode(laneToTimeOrder));
code = timeOrderedCode(1:numel(sample));
end


function center = estimatePam4Centers(sample)
%ESTIMATEPAM4CENTERS 估计四个有序的输出 code 聚类中心。
center = prctile(sample, [12.5 37.5 62.5 87.5]);
for iteration = 1:50
    [~, cluster] = min(abs(sample(:) - center), [], 2);
    updated = center;
    for level = 1:4
        levelSample = sample(cluster == level);
        if ~isempty(levelSample)
            updated(level) = mean(levelSample);
        end
    end
    if max(abs(updated - center)) < 1e-12
        break;
    end
    center = updated;
end
center = sort(center);
end
