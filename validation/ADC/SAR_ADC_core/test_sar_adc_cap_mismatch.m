function test_sar_adc_cap_mismatch()
    close all;

    % 固定随机种子，保证每次运行生成相同的电容 mismatch 样本，便于结果复现和对比。
    rng(1);

    % 获取当前测试脚本目录，并创建 result 子目录保存测试图像。
    validationDir = fileparts(mfilename('fullpath'));
    repoRoot = fileparts(fileparts(fileparts(validationDir)));
    sourceDir = fullfile(repoRoot, 'src', 'ADC', 'SAR_ADC_core');
    resultDir = fullfile(repoRoot, 'results', 'ADC', 'SAR_ADC_core');
    if ~exist(resultDir, 'dir')
        mkdir(resultDir);
    end
    addpath(sourceDir);

    % ADC 基本配置。
    % 本测试使用 7 bit、输入范围 [-1, 1] V 的单端 SAR ADC。
    VL = -1;
    VH = 1;
    nBits = 7;
    % 动态正弦测试配置。
    % finBin 表示输入正弦在 FFT 频谱中的相干采样 bin，避免频谱泄漏影响动态指标统计。
    Fs = 1e6;
    Nsample = 4096;
    finBin = 37;
    inputAmplitude = 0.9;
    % 电容失配和 ramp 静态测试配置。
    % sigmaCuMismatch 是单位电容标准差比例；rampRepeat 决定每个理想 code 平均覆盖的 ramp 点数。
    % rampMarginLsb 让 ramp 在满量程两端额外多扫若干 LSB，用于模拟真实静态测试中的端点余量。
    sigmaCuMismatch = 0.03;
    rampRepeat = 64;
    rampMarginLsb = 2;

    % 按相干采样条件生成动态测试正弦输入。
    % 输入频率等效为 finBin * Fs / Nsample，且 finBin 与 Nsample 互质时采样点能均匀覆盖正弦相位。
    sampleIndex = 0:Nsample-1;
    sineInput = inputAmplitude * sin(2 * pi * finBin * sampleIndex / Nsample);

    % 创建理想 ADC 作为基准模型。
    % resetToIdeal 清除所有非理想因素；resetState 清空上一次转换留下的状态。
    idealAdc = sar_adc_core(VL, VH, nBits);
    idealAdc.resetToIdeal();
    idealAdc.resetState();

    % 创建带电容 mismatch 的 ADC，用同一组输入与理想 ADC 对比。
    % setCapMismatch 会扰动 CDAC bit 权重，从而引入静态非线性。
    mismatchAdc = sar_adc_core(VL, VH, nBits);
    mismatchAdc.setCapMismatch(sigmaCuMismatch);
    mismatchAdc.resetState();

    % 分别对理想 ADC 和 mismatch ADC 运行同一段正弦输入，得到输出码字序列。
    % 后续动态指标只比较 ADC 非理想性带来的差异，输入条件保持一致。
    idealSineCode = runAdcCodes(idealAdc, sineInput);
    mismatchSineCode = runAdcCodes(mismatchAdc, sineInput);

    % 调用动态性能统计函数，提取 THD、SFDR、SNR、SNDR 和 ENOB。
    % 最后一个 false 表示不在指标函数内部绘图，本脚本统一负责结果可视化。
    [idealTHD, idealSFDR, idealSNR, idealSNDR, idealENOB] = sar_adc_metrics.Dynamic_test(idealSineCode, Fs, Nsample, false);
    [mismatchTHD, mismatchSFDR, mismatchSNR, mismatchSNDR, mismatchENOB] = sar_adc_metrics.Dynamic_test(mismatchSineCode, Fs, Nsample, false);

    % 构造 ramp code-density 静态测试输入。
    % ramp 在理想满量程两端各多扫 rampMarginLsb 个 LSB，避免端点 code 统计不足。
    lsb = (VH - VL) / 2^nBits;
    numRampPoints = (2^nBits + 2 * rampMarginLsb) * rampRepeat;
    rampInput = linspace(VL - rampMarginLsb * lsb, VH + rampMarginLsb * lsb, numRampPoints);

    % 静态 ramp 测试重新创建理想 ADC，避免动态测试后的对象状态影响静态统计。
    idealAdc = sar_adc_core(VL, VH, nBits);
    idealAdc.resetToIdeal();
    idealAdc.resetState();

    % 静态 ramp 测试也重新创建 mismatch ADC，保持与动态测试相同的失配强度设置。
    mismatchAdc = sar_adc_core(VL, VH, nBits);
    mismatchAdc.setCapMismatch(sigmaCuMismatch);
    mismatchAdc.resetState();

    % 对 ramp 输入逐点转换，得到 code-density 统计所需的码字序列。
    idealRampCode = runAdcCodes(idealAdc, rampInput);
    mismatchRampCode = runAdcCodes(mismatchAdc, rampInput);

    % 计算 ramp code-density 得到的 DNL/INL 极值。
    % 理想结果用于检查测试方法本身，mismatch 结果用于观察电容失配导致的非线性。
    [idealDNLmax, idealDNLmin, idealINLmax, idealINLmin] = sar_adc_metrics.ramp_INLDNL(idealRampCode, nBits, false);
    [mismatchDNLmax, mismatchDNLmin, mismatchINLmax, mismatchINLmin] = sar_adc_metrics.ramp_INLDNL(mismatchRampCode, nBits, false);

    % 在命令行打印动态和静态指标，方便不打开图像时快速判断 mismatch 影响。
    fprintf('Capacitor mismatch mainly changes DAC bit weights, so it causes static nonlinearity first.\n');
    fprintf('The static nonlinearity appears as DNL/INL error and then creates harmonic distortion, lower SFDR, lower SNDR and lower ENOB.\n');
    fprintf('\n');
    fprintf('Unit capacitor mismatch sigmaCu = %.2f %%\n', sigmaCuMismatch * 100);
    fprintf('\n');
    fprintf('Dynamic sine test, fin bin = %d, Nsample = %d\n', finBin, Nsample);
    fprintf('Mode        THD(dB)    SFDR(dB)    SNR(dB)    SNDR(dB)    ENOB(bit)\n');
    fprintf('Ideal     %9.2f   %9.2f  %8.2f   %9.2f    %9.2f\n', idealTHD, idealSFDR, idealSNR, idealSNDR, idealENOB);
    fprintf('Mismatch  %9.2f   %9.2f  %8.2f   %9.2f    %9.2f\n', mismatchTHD, mismatchSFDR, mismatchSNR, mismatchSNDR, mismatchENOB);
    fprintf('\n');
    fprintf('Ramp static test\n');
    fprintf('Mode        DNLmax     DNLmin     INLmax     INLmin\n');
    fprintf('Ideal     %8.3f   %8.3f   %8.3f   %8.3f\n', idealDNLmax, idealDNLmin, idealINLmax, idealINLmin);
    fprintf('Mismatch  %8.3f   %8.3f   %8.3f   %8.3f\n', mismatchDNLmax, mismatchDNLmin, mismatchINLmax, mismatchINLmin);

    % 绘制四宫格对比图：上排比较理想/失配动态频谱，下排比较理想/失配 DNL 和 INL。
    fig = figure('Visible', 'on', 'Color', 'w', 'Name', 'SAR ADC capacitor mismatch comparison');

    subplot(2, 2, 1);
    plotNormalizedSpectrum(idealSineCode, Fs, 'Ideal ADC spectrum');

    subplot(2, 2, 2);
    plotNormalizedSpectrum(mismatchSineCode, Fs, 'Cap mismatch ADC spectrum');

    subplot(2, 2, 3);
    plotDnlInl(idealRampCode, nBits, 'Ideal ADC DNL/INL');

    subplot(2, 2, 4);
    plotDnlInl(mismatchRampCode, nBits, 'Cap mismatch ADC DNL/INL');

    % 保存对比图到 result 目录，文件名与测试脚本保持一致。
    outputPng = fullfile(resultDir, 'test_sar_adc_cap_mismatch.png');
    exportgraphics(fig, outputPng, 'Resolution', 150);

    fprintf('\n');
    fprintf('Saved plot: %s\n', outputPng);
end

function codeOutput_dec = runAdcCodes(adc, inputVin)
    % 将一组输入电压逐点送入 ADC，并收集十进制输出码字。
    % helper 只负责调用转换接口，不修改输入波形或 ADC 配置。
    numSamples = numel(inputVin);
    codeOutput_dec = zeros(1, numSamples);

    for sampleIndex = 1:numSamples
        % convertInstant 表示每个输入样本都瞬时完成一次完整 SAR 转换。
        [dout_dec, ~] = adc.convertInstant(inputVin(sampleIndex));
        codeOutput_dec(sampleIndex) = dout_dec;
    end
end

function plotNormalizedSpectrum(codeOutput_dec, Fs, plotTitle)
    % 绘制归一化单边频谱。
    % 先去除直流分量，再用最大谱线归一化到 0 dBc，便于比较杂散和噪声底。
    codeOutput_dec = codeOutput_dec(:) - mean(codeOutput_dec);
    numSamples = numel(codeOutput_dec);
    nHalf = floor(numSamples / 2);
    spectrum = abs(fft(codeOutput_dec, numSamples));
    % 加 eps 避免零幅度点取 log10 时产生 -Inf。
    spectrumDb = 20 * log10(spectrum(1:nHalf) / max(spectrum(1:nHalf)) + eps);
    freqAxis = (0:nHalf-1) * Fs / numSamples;

    plot(freqAxis, spectrumDb, 'k', 'LineWidth', 1.2);
    grid on;
    xlabel('Frequency (Hz)');
    ylabel('Amplitude (dBc)');
    title(plotTitle);
    ylim([-120 5]);
end

function plotDnlInl(codeOutput_dec, nBits, plotTitle)
    % 根据 ramp 输出码字重新计算并绘制 DNL/INL。
    % 这里与指标函数独立计算一次，目的是得到完整曲线用于可视化。
    edges = -0.5:(2^nBits - 0.5);
    histogramData = histcounts(codeOutput_dec, edges);
    codeAxisAll = 0:numel(histogramData)-1;
    % 去掉最低和最高端点 code，避免 ramp 超出满量程造成的饱和计数影响平均 bin 宽估计。
    validCodeIndex = 2:numel(histogramData)-1;
    meanCount = mean(histogramData(validCodeIndex));
    dnl = histogramData(validCodeIndex) / meanCount - 1;
    inl = cumsum(dnl);
    % 去除端点连线，相当于 endpoint-fit INL，便于观察中间 code 的相对非线性。
    inl = inl - linspace(inl(1), inl(end), numel(inl));
    codeAxis = codeAxisAll(validCodeIndex);

    yyaxis left;
    plot(codeAxis, dnl, 'k', 'LineWidth', 1.2);
    ylabel('DNL (LSB)');
    yyaxis right;
    plot(codeAxis, inl, '--', 'LineWidth', 1.2);
    ylabel('INL (LSB)');
    grid on;
    xlabel('Code');
    title(plotTitle);
    xlim([1 2^nBits - 2]);
end
