function test_sar_adc_core()
    close all;

    validationDir = fileparts(mfilename('fullpath'));
    repoRoot = fileparts(fileparts(fileparts(validationDir)));
    sourceDir = fullfile(repoRoot, 'src', 'ADC', 'SAR_ADC_core_complex');
    resultDir = fullfile(repoRoot, 'results', 'ADC', 'SAR_ADC_core_complex');
    if ~exist(resultDir, 'dir')
        mkdir(resultDir);
    end
    addpath(sourceDir);

    signalFreq = 50;
    nBits = 7;
    conversionsPerPeriod = 50;
    numPeriods = 3;

    VL = -1;
    VH = 1;
    inputAmplitude = 0.9;

    conversionFreq = signalFreq * conversionsPerPeriod;
    sarClockFreq = conversionFreq * nBits;
    samplesPerSarClock = 8;
    clockSampleFreq = sarClockFreq * samplesPerSarClock;
    numConversions = numPeriods * conversionsPerPeriod;
    numSarEdges = numConversions * nBits;
    numClockSamples = numSarEdges * samplesPerSarClock;

    adc = sar_adc_core(VL, VH, nBits, false);
    adc = adc.setIdealMode();
    adc = adc.setTraceMode(true);
    adc = adc.reset();
    adc = adc.setTraceMode(true);

    tOutput = NaN(1, numConversions);
    vOutput = NaN(1, numConversions);
    tHold = NaN(1, numConversions);
    vHold = NaN(1, numConversions);
    vipHold = NaN(1, numConversions);
    vinHold = NaN(1, numConversions);
    codeOutput_dec = NaN(1, numConversions);

    tStop = numPeriods / signalFreq;
    tFine = linspace(0, tStop, 5000);
    vdiffFine = inputAmplitude * sin(2 * pi * signalFreq * tFine);
    vipFine = 0.5 * vdiffFine;
    vinFine = -0.5 * vdiffFine;

    fig = figure('Visible', 'on', 'Color', 'w', 'Name', 'SAR ADC core 50 Hz sine test');
    plot(tFine, vdiffFine, 'LineWidth', 1.5);
    hold on;
    plot(tFine, vipFine, '--', 'LineWidth', 0.8);
    plot(tFine, vinFine, '--', 'LineWidth', 0.8);
    outputPlot = stairs(tOutput, vOutput, 'LineWidth', 1.2);
    holdPlot = plot(tHold, vHold, 'o', 'MarkerSize', 3);
    grid on;
    xlabel('Time (s)');
    ylabel('Voltage (V)');
    title('50 Hz held differential input and 7-bit SAR ADC core output');
    legend('Vip - Vin', 'Vip', 'Vin', 'SAR ADC core output', 'Held differential input', 'Location', 'best');
    xlim([0, tStop]);
    ylim([VL - 0.1, VH + 0.1]);
    drawnow;

    formatSpec = 'Conversion %3d/%3d: tHold=%.8f s, Vip=%.7f V, Vin=%.7f V, Vdiff=%.7f V, code=%3d, Vout=%.7f V \n';
    conversionIndex = 0;
    heldVip = 0;
    heldVin = 0;
    for sampleIndex = 1:numClockSamples
        tNow = (sampleIndex - 1) / clockSampleFreq;
        edgeIndex = floor((sampleIndex - 1) / samplesPerSarClock) + 1;
        phaseIndex = mod(edgeIndex - 1, nBits) + 1;
        clk = mod(sampleIndex - 1, samplesPerSarClock) < samplesPerSarClock / 2;

        if phaseIndex == 1 && clk && mod(sampleIndex - 1, samplesPerSarClock) == 0
            vdiff = inputAmplitude * sin(2 * pi * signalFreq * tNow);
            heldVip = 0.5 * vdiff;
            heldVin = -0.5 * vdiff;
        end

        [adc, ~, dout_dec, vout, conversionDone, trace] = adc.convertByClock(heldVip, heldVin, clk);

        if conversionDone
            conversionIndex = conversionIndex + 1;
            holdEdgeIndex = edgeIndex - nBits + 1;

            tHold(conversionIndex) = (holdEdgeIndex - 1) / sarClockFreq;
            vHold(conversionIndex) = trace.Vdiff;
            vipHold(conversionIndex) = trace.Vip;
            vinHold(conversionIndex) = trace.Vin;
            tOutput(conversionIndex) = tNow;
            vOutput(conversionIndex) = vout;
            codeOutput_dec(conversionIndex) = dout_dec;

            set(outputPlot, 'XData', tOutput, 'YData', vOutput);
            set(holdPlot, 'XData', tHold, 'YData', vHold);
            drawnow limitrate;

            fprintf(formatSpec, conversionIndex, numConversions, tHold(conversionIndex), vipHold(conversionIndex), vinHold(conversionIndex), vHold(conversionIndex), dout_dec, vout);
        end
    end

    if conversionIndex ~= numConversions
        error('Expected %d conversions, got %d.', numConversions, conversionIndex);
    end

    if max(abs(vHold - (vipHold - vinHold))) > 10 * eps
        error('Differential held input check failed.');
    end

    if any(abs(vHold) > inputAmplitude + 10 * eps)
        error('Held differential input is outside expected range.');
    end

    outputPng = fullfile(resultDir, 'test_sar_adc_core.png');
    outputMat = fullfile(resultDir, 'test_sar_adc_core_result.mat');
    exportgraphics(fig, outputPng, 'Resolution', 150);
    save(outputMat, 'tOutput', 'vOutput', 'tHold', 'vHold', 'vipHold', 'vinHold', 'codeOutput_dec');

    fprintf('SAR ADC core test completed.\n');
    fprintf('Signal frequency: %.6g Hz\n', signalFreq);
    fprintf('SAR clock frequency: %.6g Hz\n', sarClockFreq);
    fprintf('Conversion frequency: %.6g Hz\n', conversionFreq);
    fprintf('Completed conversions: %d\n', conversionIndex);
    fprintf('First output code: %d\n', codeOutput_dec(1));
    fprintf('Last output code: %d\n', codeOutput_dec(conversionIndex));
    fprintf('Saved plot: %s\n', outputPng);
    fprintf('Saved result: %s\n', outputMat);
end
