function test_sar_adc_channel_single()
    close all;

    baseDir = fileparts(mfilename('fullpath'));
    resultDir = fullfile(baseDir, 'result');
    if ~exist(resultDir, 'dir')
        mkdir(resultDir);
    end
    addpath(baseDir);

    signalFreq = 50;
    nBits = 7;
    conversionsPerPeriod = 50;
    numPeriods = 3;

    VL = -1;
    VH = 1;
    inputAmplitude = 0.9;

    conversionFreq = signalFreq * conversionsPerPeriod;
    sarClockFreq = conversionFreq * (nBits + 1);
    samplesPerSarClock = 8;
    clockSampleFreq = sarClockFreq * samplesPerSarClock;
    numConversions = numPeriods * conversionsPerPeriod;
    numSarEdges = numConversions * (nBits + 1);
    numClockSamples = numSarEdges * samplesPerSarClock;

    adc = sar_adc_channel(VL, VH, nBits, false);
    adc = adc.setIdealMode();
    adc = adc.setTraceMode(true);
    adc = adc.reset();
    adc = adc.setTraceMode(true);

    tOutput = NaN(1, numConversions);
    vOutput = NaN(1, numConversions);
    tSample = NaN(1, numConversions);
    vSample = NaN(1, numConversions);
    vipSample = NaN(1, numConversions);
    vinSample = NaN(1, numConversions);
    codeOutput_dec = NaN(1, numConversions);

    tStop = numPeriods / signalFreq;
    tFine = linspace(0, tStop, 5000);
    vdiffFine = inputAmplitude * sin(2 * pi * signalFreq * tFine);
    vipFine = 0.5 * vdiffFine;
    vinFine = -0.5 * vdiffFine;

    fig = figure('Visible', 'on', 'Color', 'w', 'Name', 'SAR ADC channel single 50 Hz sine test');
    plot(tFine, vdiffFine, 'LineWidth', 1.5);
    hold on;
    plot(tFine, vipFine, '--', 'LineWidth', 0.8);
    plot(tFine, vinFine, '--', 'LineWidth', 0.8);
    outputPlot = stairs(tOutput, vOutput, 'LineWidth', 1.2);
    samplePlot = plot(tSample, vSample, 'o', 'MarkerSize', 3);
    grid on;
    xlabel('Time (s)');
    ylabel('Voltage (V)');
    title('50 Hz differential input and single SAR ADC channel output');
    legend('Vip - Vin', 'Vip', 'Vin', 'SAR ADC channel output', 'TAH sampled differential input', 'Location', 'best');
    xlim([0, tStop]);
    ylim([VL - 0.1, VH + 0.1]);
    drawnow;

    formatSpec = 'Conversion %3d/%3d: tSample=%.8f s, Vip=%.7f V, Vin=%.7f V, Vdiff=%.7f V, code=%3d, Vout=%.7f V \n';
    conversionIndex = 0;
    for sampleIndex = 1:numClockSamples
        tNow = (sampleIndex - 1) / clockSampleFreq;
        clk = mod(sampleIndex - 1, samplesPerSarClock) < samplesPerSarClock / 2;
        vdiff = inputAmplitude * sin(2 * pi * signalFreq * tNow);
        vip = 0.5 * vdiff;
        vin = -0.5 * vdiff;

        [adc, ~, dout_dec, vout, conversionDone, trace] = adc.convertByClock(vip, vin, clk);

        if conversionDone
            conversionIndex = conversionIndex + 1;
            sampleEdgeIndex = floor((sampleIndex - 1) / samplesPerSarClock) - nBits + 1;

            tSample(conversionIndex) = sampleEdgeIndex / sarClockFreq;
            vSample(conversionIndex) = trace.Vdiff;
            vipSample(conversionIndex) = trace.Vip;
            vinSample(conversionIndex) = trace.Vin;
            tOutput(conversionIndex) = tNow;
            vOutput(conversionIndex) = vout;
            codeOutput_dec(conversionIndex) = dout_dec;

            set(outputPlot, 'XData', tOutput, 'YData', vOutput);
            set(samplePlot, 'XData', tSample, 'YData', vSample);
            drawnow limitrate;

            fprintf(formatSpec, conversionIndex, numConversions, tSample(conversionIndex), vipSample(conversionIndex), vinSample(conversionIndex), vSample(conversionIndex), dout_dec, vout);
        end
    end

    if conversionIndex ~= numConversions
        error('Expected %d conversions, got %d.', numConversions, conversionIndex);
    end

    if max(abs(vSample - (vipSample - vinSample))) > 10 * eps
        error('Differential sample check failed.');
    end

    if any(abs(vSample) > inputAmplitude + 10 * eps)
        error('TAH sample is outside expected differential input range.');
    end

    outputPng = fullfile(resultDir, 'test_sar_adc_channel_singel.png');
    outputMat = fullfile(resultDir, 'test_sar_adc_channel_singel_result.mat');
    exportgraphics(fig, outputPng, 'Resolution', 150);
    save(outputMat, 'tOutput', 'vOutput', 'tSample', 'vSample', 'vipSample', 'vinSample', 'codeOutput_dec');

    fprintf('SAR ADC channel single test completed.\n');
    fprintf('Signal frequency: %.6g Hz\n', signalFreq);
    fprintf('SAR clock frequency: %.6g Hz\n', sarClockFreq);
    fprintf('Conversion frequency: %.6g Hz\n', conversionFreq);
    fprintf('Completed conversions: %d\n', conversionIndex);
    fprintf('First output code: %d\n', codeOutput_dec(1));
    fprintf('Last output code: %d\n', codeOutput_dec(conversionIndex));
    fprintf('Saved plot: %s\n', outputPng);
    fprintf('Saved result: %s\n', outputMat);
end
