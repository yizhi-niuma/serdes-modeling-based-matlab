function test_sar_adc_core()
close all;

% 获取当前测试脚本所在目录，保证后续 addpath、结果保存路径都相对于本脚本。
baseDir = fileparts(mfilename('fullpath'));
resultDir = fullfile(baseDir, 'result');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end
addpath(baseDir);

% 设置输入正弦波和 ADC 分辨率。
% 这里用 50 Hz 正弦波，每周期 128 个采样点，连续仿真 2 个周期。
signalFreq = 50;
nBits = 7;
samplesPerPeriod = 128;
numPeriods = 2;

% 设置单端 ADC 输入范围和正弦输入幅度。
% inputAmplitude 小于满量程端点，避免功能测试中触发输入过驱饱和。
VL = -1;
VH = 1;
inputAmplitude = 0.9;

% 根据每周期采样点数计算采样率和总采样点数。
% sampleIndex 是离散采样序号；tSample 仅用于打印每个样本对应的时间。
sampleFreq = signalFreq * samplesPerPeriod;
numSamples = samplesPerPeriod * numPeriods;
sampleIndex = 0:numSamples-1;
tSample = sampleIndex / sampleFreq;

% 直接按采样索引生成离散正弦样本。
% 这样测试不依赖外部时钟驱动，而是模拟前级采样器已经按索引完成采样。
vinSample = inputAmplitude * sin(2 * pi * sampleIndex / samplesPerPeriod);

% 创建 7 bit 单端 SAR ADC core，并复位到理想状态。
% trace 模式用于记录每次转换内部锁存输入和逐 bit 判决信息，方便功能调试。
adc = sar_adc_core(VL, VH, nBits);
adc.resetToIdeal();
adc.setTraceMode(true);
adc.resetState();
adc.setTraceMode(true);

% 本基础功能测试只验证理想 gain=1 的瞬时 SAR 转换行为。
adc.setGain(1);

% 预分配输出数组。
% 初始填 NaN 是为了绘图时只显示已经完成转换的样本点。
vOutput = NaN(1, numSamples);
codeOutput_dec = NaN(1, numSamples);

% 建立输入/输出波形图。
% 输入用连续曲线和采样点显示，ADC 输出用 stairs 显示量化后的阶梯波形。
fig = figure('Visible', 'on', 'Color', 'w', 'Name', 'Instant SAR ADC core 50 Hz sine test');
plot(sampleIndex, vinSample, 'LineWidth', 1.5);
hold on;
outputPlot = stairs(sampleIndex, vOutput, 'LineWidth', 1.2);
samplePlot = plot(sampleIndex, vinSample, 'o', 'MarkerSize', 3);
grid on;
xlabel('Sample Index');
ylabel('Voltage (V)');
title('50 Hz single-ended input and instantaneous 7-bit SAR ADC core output');
legend('Single-ended input', 'SAR ADC core output', 'Sampled input', 'Location', 'best');
xlim([0, numSamples - 1]);
ylim([VL - 0.1, VH + 0.1]);
drawnow;

% 逐样本调用 convertInstant。
% 每次调用代表对一个已经采样完成的单端输入瞬时完成完整 N bit SAR 转换。
formatSpec = 'Sample %3d/%3d: index=%3d, t=%.8f s, Vin=%.7f V, code=%3d, Vout=%.7f V \n';
for k = 1:numSamples
    [dout_dec, vout, ~, trace] = adc.convertInstant(vinSample(k));

    % 保存当前转换的恢复电压和十进制输出码字。
    vOutput(k) = vout;
    codeOutput_dec(k) = dout_dec;

    % 在线更新图像，便于观察随采样 index 推进的量化输出。
    set(outputPlot, 'YData', vOutput);
    set(samplePlot, 'YData', vinSample);
    drawnow limitrate;

    % 打印当前样本的输入、输出码字和恢复电压。
    % trace.Vin 是 ADC 内部锁存输入，用于确认转换使用的采样值。
    fprintf(formatSpec, k, numSamples, sampleIndex(k), tSample(k), trace.Vin, dout_dec, vout);
end

% 检查输入样本是否仍在预期幅度范围内。
% 这是测试脚本自身的输入生成一致性检查，不是 ADC 饱和行为测试。
if any(abs(vinSample) > inputAmplitude + 10 * eps)
    error('Sampled input is outside expected range.');
end

% 检查输出码字是否落在 N bit ADC 的合法范围 [0, 2^N - 1] 内。
if any(codeOutput_dec < 0) || any(codeOutput_dec > 2^nBits - 1)
    error('Output code is outside expected range.');
end

% 保存测试图像，便于后续对比输入正弦和 ADC 输出阶梯波形。
outputPng = fullfile(resultDir, 'test_sar_adc_core.png');
exportgraphics(fig, outputPng, 'Resolution', 150);

% 打印测试摘要。
fprintf('Instant SAR ADC core test completed.\n');
fprintf('Signal frequency: %.6g Hz\n', signalFreq);
fprintf('Sample frequency: %.6g Hz\n', sampleFreq);
fprintf('Samples per period: %d\n', samplesPerPeriod);
fprintf('Completed periods: %d\n', numPeriods);
fprintf('Completed conversions: %d\n', numSamples);
fprintf('First output code: %d\n', codeOutput_dec(1));
fprintf('Last output code: %d\n', codeOutput_dec(numSamples));
fprintf('Saved plot: %s\n', outputPng);
end
