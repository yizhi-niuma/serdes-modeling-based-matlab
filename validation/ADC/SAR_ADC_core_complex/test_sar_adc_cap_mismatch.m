function test_sar_adc_cap_mismatch()
    close all;
    rng(1);

    validationDir = fileparts(mfilename('fullpath'));
    repoRoot = fileparts(fileparts(fileparts(validationDir)));
    sourceDir = fullfile(repoRoot, 'src', 'ADC', 'SAR_ADC_core_complex');
    resultDir = fullfile(repoRoot, 'results', 'ADC', 'SAR_ADC_core_complex');
    if ~exist(resultDir, 'dir')
        mkdir(resultDir);
    end
    addpath(sourceDir);

    VL = -1;
    VH = 1;
    nBits = 7;
    Fs = 1e6;
    Nsample = 4096;
    finBin = 37;
    inputAmplitude = 0.9;
    sigmaCuMismatch = 0.03;
    rampRepeat = 64;

    sampleIndex = 0:Nsample-1;
    sineInput = inputAmplitude * sin(2 * pi * finBin * sampleIndex / Nsample);

    idealAdc = sar_adc_core(VL, VH, nBits, false);
    idealAdc = idealAdc.setIdealMode();
    idealAdc = idealAdc.reset();

    mismatchAdc = sar_adc_core(VL, VH, nBits, false);
    mismatchAdc = mismatchAdc.setNonideal('sigmaCu', sigmaCuMismatch);
    mismatchAdc = mismatchAdc.reset();

    idealSineCode = runAdcCodes(idealAdc, sineInput);
    mismatchSineCode = runAdcCodes(mismatchAdc, sineInput);

    [idealTHD, idealSFDR, idealSNR, idealSNDR, idealENOB] = sar_adc_metrics.Dynamic_test(idealSineCode, Fs, Nsample, false);
    [mismatchTHD, mismatchSFDR, mismatchSNR, mismatchSNDR, mismatchENOB] = sar_adc_metrics.Dynamic_test(mismatchSineCode, Fs, Nsample, false);

    rampInput = linspace(VL + 0.5 / 2^nBits * (VH - VL), VH - 0.5 / 2^nBits * (VH - VL), 2^nBits * rampRepeat);

    idealAdc = sar_adc_core(VL, VH, nBits, false);
    idealAdc = idealAdc.setIdealMode();
    idealAdc = idealAdc.reset();

    mismatchAdc = sar_adc_core(VL, VH, nBits, false);
    mismatchAdc = mismatchAdc.setNonideal('sigmaCu', sigmaCuMismatch);
    mismatchAdc = mismatchAdc.reset();

    idealRampCode = runAdcCodes(idealAdc, rampInput);
    mismatchRampCode = runAdcCodes(mismatchAdc, rampInput);

    [idealDNLmax, idealDNLmin, idealINLmax, idealINLmin] = sar_adc_metrics.ramp_INLDNL(idealRampCode, nBits, false);
    [mismatchDNLmax, mismatchDNLmin, mismatchINLmax, mismatchINLmin] = sar_adc_metrics.ramp_INLDNL(mismatchRampCode, nBits, false);

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

    fig = figure('Visible', 'on', 'Color', 'w', 'Name', 'SAR ADC capacitor mismatch comparison');

    subplot(2, 2, 1);
    plotNormalizedSpectrum(idealSineCode, Fs, 'Ideal ADC spectrum');

    subplot(2, 2, 2);
    plotNormalizedSpectrum(mismatchSineCode, Fs, 'Cap mismatch ADC spectrum');

    subplot(2, 2, 3);
    plotDnlInl(idealRampCode, nBits, 'Ideal ADC DNL/INL');

    subplot(2, 2, 4);
    plotDnlInl(mismatchRampCode, nBits, 'Cap mismatch ADC DNL/INL');

    outputPng = fullfile(resultDir, 'test_sar_adc_cap_mismatch.png');
    outputMat = fullfile(resultDir, 'test_sar_adc_cap_mismatch_result.mat');
    exportgraphics(fig, outputPng, 'Resolution', 150);
    save(outputMat, 'idealSineCode', 'mismatchSineCode', 'idealRampCode', 'mismatchRampCode', ...
        'idealTHD', 'idealSFDR', 'idealSNR', 'idealSNDR', 'idealENOB', ...
        'mismatchTHD', 'mismatchSFDR', 'mismatchSNR', 'mismatchSNDR', 'mismatchENOB', ...
        'idealDNLmax', 'idealDNLmin', 'idealINLmax', 'idealINLmin', ...
        'mismatchDNLmax', 'mismatchDNLmin', 'mismatchINLmax', 'mismatchINLmin', ...
        'sigmaCuMismatch');

    fprintf('\n');
    fprintf('Saved plot: %s\n', outputPng);
    fprintf('Saved result: %s\n', outputMat);
end

function codeOutput_dec = runAdcCodes(adc, inputVdiff)
    nBits = adc.N;
    numSamples = length(inputVdiff);
    codeOutput_dec = zeros(1, numSamples);

    for sampleIndex = 1:numSamples
        vip = 0.5 * inputVdiff(sampleIndex);
        vin = -0.5 * inputVdiff(sampleIndex);
        conversionDone = false;

        for bitIndex = 1:nBits
            [adc, ~, dout_dec, ~, conversionDone] = adc.convertByClock(vip, vin, 1);
            if conversionDone
                codeOutput_dec(sampleIndex) = dout_dec;
            end
            [adc, ~, ~, ~, ~] = adc.convertByClock(vip, vin, 0);
        end

        if ~conversionDone
            error('Conversion did not finish at sample %d.', sampleIndex);
        end
    end
end

function plotNormalizedSpectrum(codeOutput_dec, Fs, plotTitle)
    codeOutput_dec = codeOutput_dec(:) - mean(codeOutput_dec);
    numSamples = length(codeOutput_dec);
    nHalf = floor(numSamples / 2);
    spectrum = abs(fft(codeOutput_dec, numSamples));
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
    edges = -0.5:(2^nBits - 0.5);
    histogramData = histcounts(codeOutput_dec, edges);
    meanCount = length(codeOutput_dec) / 2^nBits;
    dnl = histogramData / meanCount - 1;
    inl = cumsum(dnl);
    codeAxis = 0:length(dnl)-1;

    yyaxis left;
    plot(codeAxis, dnl, 'k', 'LineWidth', 1.2);
    ylabel('DNL (LSB)');
    yyaxis right;
    plot(codeAxis, inl, '--', 'LineWidth', 1.2);
    ylabel('INL (LSB)');
    grid on;
    xlabel('Code');
    title(plotTitle);
end
