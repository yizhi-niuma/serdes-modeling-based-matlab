function test_ti_adc_core_4lane_sine()
close all;

% 获取当前测试脚本所在目录，保证后续 addpath、结果保存路径都相对于本脚本。
baseDir = fileparts(mfilename('fullpath'));
resultDir = fullfile(baseDir, 'result');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end
addpath(baseDir);

% 设置 4 路 TI ADC、输入正弦波和 ADC 分辨率。
% 这里用 50 Hz 正弦波，每周期 128 个采样点，连续仿真 2 个周期。
numLanes = 4;
signalFreq = 50;
nBits = 7;
samplesPerPeriod = 128;
numPeriods = 2;

% 设置单端 ADC 输入范围和正弦输入幅度。
% inputAmplitude 小于满量程端点，避免功能测试中触发输入过驱饱和。
VL = -1;
VH = 1;
inputAmplitude = 0.9;

% 根据每周期采样点数计算总采样率和总采样点数。
% 第一版 TI ADC 模型接收已经采样好的离散 Vin，不在模型内执行 timing skew 插值。
sampleFreq = signalFreq * samplesPerPeriod;
numSamples = samplesPerPeriod * numPeriods;
sampleIndex = 0:numSamples-1;
tSample = sampleIndex / sampleFreq;
vinSample = inputAmplitude * sin(2 * pi * signalFreq * tSample);

% 创建 4 路 TI ADC，并配置为理想 lane mismatch。
% trace 模式用于记录每个 block 的 laneIndex 和每一路 SAR trace。
adc = ti_adc_core(numLanes, VL, VH, nBits);
adc.resetToIdeal();
adc.setTraceMode(true);
adc.setLaneEquivalentGain(ones(1, numLanes));
adc.setLaneEquivalentOffset(zeros(1, numLanes));
adc.setLaneSkew(zeros(1, numLanes));
adc.setLaneCapMismatch(zeros(1, numLanes));
adc.setLaneComparatorNoise(zeros(1, numLanes));

% 按 M 个码元为一个 block 推进 TI ADC。
% 每个 block 内 M 路 SAR ADC 各调用一次 convertInstant，便于后续接入 DSP/CDR 状态更新。
if mod(numSamples, numLanes) ~= 0
    error('numSamples must be an integer multiple of numLanes for block-based TI ADC test.');
end
numBlocks = numSamples / numLanes;
Dout_dec = zeros(1, numSamples);
Vout = zeros(1, numSamples);
laneIndex = zeros(1, numSamples);
Dout = zeros(numSamples, nBits);
trace = [];

for blockIndex = 1:numBlocks
    blockSampleIndex = (blockIndex - 1) * numLanes + (1:numLanes);
    VinBlock = vinSample(blockSampleIndex);
    [doutDecBlock, voutBlock, laneIndexBlock, doutBlock, trace] = adc.convertOneBlock(VinBlock);

    Dout_dec(blockSampleIndex) = doutDecBlock;
    Vout(blockSampleIndex) = voutBlock;
    laneIndex(blockSampleIndex) = laneIndexBlock;
    Dout(blockSampleIndex, :) = reshape(doutBlock, [], nBits);

    % 这里预留后续 DSP/CDR/自适应均衡更新入口。
    % dsp_state = "ing";
    % dsp.update(doutDecBlock, voutBlock);
    % dsp_state = "finish";
end

% 基础一致性检查。
expectedLaneIndex = mod(sampleIndex, numLanes) + 1;
if any(laneIndex ~= expectedLaneIndex)
    error('Lane index sequence is not round-robin.');
end
if any(abs(vinSample) > inputAmplitude + 10 * eps)
    error('Sampled input is outside expected range.');
end
if any(Dout_dec < 0) || any(Dout_dec > 2^nBits - 1)
    error('Output code is outside expected range.');
end
if isempty(trace) || any(trace.LaneIndex ~= 1:numLanes)
    error('TI ADC trace is not recorded as expected.');
end

% 建立输入/输出波形图。
% 输入用连续曲线和采样点显示，ADC 输出用 stairs 显示量化后的阶梯波形。
fig = figure('Visible', 'on', 'Color', 'w', 'Name', '4-lane TI ADC 50 Hz sine test');
subplot(2, 1, 1);
plot(sampleIndex, vinSample, 'LineWidth', 1.5);
hold on;
stairs(sampleIndex, Vout, 'LineWidth', 1.2);
plot(sampleIndex, vinSample, 'o', 'MarkerSize', 3);
grid on;
xlabel('Sample Index');
ylabel('Voltage (V)');
title('50 Hz input and 4-lane TI ADC output');
legend('Single-ended input', 'TI ADC output', 'Sampled input', 'Location', 'best');
xlim([0, numSamples - 1]);
ylim([VL - 0.1, VH + 0.1]);

% 显示每个采样点分配到的 lane，便于确认 4 路交织顺序。
subplot(2, 1, 2);
stem(sampleIndex, laneIndex, 'filled', 'MarkerSize', 3);
grid on;
xlabel('Sample Index');
ylabel('Lane Index');
title('Round-robin lane assignment');
xlim([0, min(numSamples - 1, 63)]);
ylim([0.5, numLanes + 0.5]);

% 保存测试图像，便于后续对比输入正弦和 ADC 输出阶梯波形。
outputPng = fullfile(resultDir, 'test_ti_adc_core_4lane_sine.png');
exportgraphics(fig, outputPng, 'Resolution', 150);

% 打印测试摘要。
fprintf('4-lane TI ADC sine test completed.\n');
fprintf('Signal frequency: %.6g Hz\n', signalFreq);
fprintf('Sample frequency: %.6g Hz\n', sampleFreq);
fprintf('Samples per period: %d\n', samplesPerPeriod);
fprintf('Completed periods: %d\n', numPeriods);
fprintf('Completed blocks: %d\n', numBlocks);
fprintf('Completed conversions: %d\n', numSamples);
fprintf('ADC full range: [%.6g, %.6g] V\n', VL, VH);
fprintf('Input amplitude: %.6g V\n', inputAmplitude);
fprintf('First output code: %d\n', Dout_dec(1));
fprintf('Last output code: %d\n', Dout_dec(numSamples));
fprintf('Saved plot: %s\n', outputPng);
end
