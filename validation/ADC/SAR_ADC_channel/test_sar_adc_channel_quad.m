function test_sar_adc_channel_quad()
    close all;

    validationDir = fileparts(mfilename('fullpath'));
    repoRoot = fileparts(fileparts(fileparts(validationDir)));
    sourceDir = fullfile(repoRoot, 'src', 'ADC', 'SAR_ADC_channel');
    resultDir = fullfile(repoRoot, 'results', 'ADC', 'SAR_ADC_channel');
    if ~exist(resultDir, 'dir')
        mkdir(resultDir);
    end
    addpath(sourceDir);

    signalFreq = 50;
    nBits = 7;
    numChannels = 4;
    combinedConversionsPerPeriod = 52;
    channelConversionsPerPeriod = combinedConversionsPerPeriod / numChannels;
    numPeriods = 3;

    VL = -1;
    VH = 1;
    inputAmplitude = 0.9;

    combinedConversionFreq = signalFreq * combinedConversionsPerPeriod;
    channelConversionFreq = signalFreq * channelConversionsPerPeriod;
    sarClockFreq = combinedConversionFreq * (nBits + 1);
    samplesPerSarClock = 8;
    clockSampleFreq = sarClockFreq * samplesPerSarClock;
    numConversionsPerChannel = numPeriods * channelConversionsPerPeriod;
    numConversions = numConversionsPerChannel * numChannels;
    numSarEdges = numConversions * (nBits + 1);
    numClockSamples = numSarEdges * samplesPerSarClock;

    adc = cell(1, numChannels);
    for channelIndex = 1:numChannels
        adc{channelIndex} = sar_adc_channel(VL, VH, nBits, false);
        adc{channelIndex} = adc{channelIndex}.setIdealMode();
        adc{channelIndex} = adc{channelIndex}.setTraceMode(true);
        adc{channelIndex} = adc{channelIndex}.reset();
        adc{channelIndex} = adc{channelIndex}.setTraceMode(true);
    end

    tOutput = NaN(1, numConversions);
    vOutput = NaN(1, numConversions);
    tSample = NaN(1, numConversions);
    vSample = NaN(1, numConversions);
    vipSample = NaN(1, numConversions);
    vinSample = NaN(1, numConversions);
    codeOutput_dec = NaN(1, numConversions);
    channelOutput = NaN(1, numConversions);
    channelCount = zeros(1, numChannels);

    tStop = numPeriods / signalFreq;
    tFine = linspace(0, tStop, 5000);
    vdiffFine = inputAmplitude * sin(2 * pi * signalFreq * tFine);

    fig = figure('Visible', 'off', 'Color', 'w', 'Name', 'SAR ADC channel quad time-interleaved test');
    channelColors = lines(numChannels);

    subplot(2, 1, 1);
    inputPlot = plot(tFine, vdiffFine, 'LineWidth', 1.5);
    hold on;
    outputPlot = stairs(tOutput, vOutput, 'LineWidth', 1.2);
    samplePlot = gobjects(1, numChannels);
    for channelIndex = 1:numChannels
        samplePlot(channelIndex) = plot(NaN, NaN, 'o', 'Color', channelColors(channelIndex, :), ...
            'MarkerFaceColor', channelColors(channelIndex, :), 'MarkerSize', 3, 'LineStyle', 'none');
    end
    grid on;
    xlabel('Time (s)');
    ylabel('Voltage (V)');
    title('4-channel time-interleaved SAR ADC channel output');
    legendEntries = [{'Vip - Vin', 'Interleaved SAR ADC output'}, arrayfun(@(x) sprintf('CH%d TAH sample', x), 1:numChannels, 'UniformOutput', false)];
    legend([inputPlot, outputPlot, samplePlot], legendEntries{:}, 'Location', 'best');
    xlim([0, tStop]);
    ylim([VL - 0.1, VH + 0.1]);

    subplot(2, 1, 2);
    channelOrderPlot = stairs(tOutput, channelOutput, 'LineWidth', 1.2);
    grid on;
    xlabel('Time (s)');
    ylabel('Channel index');
    title('Time-interleaved output channel order');
    yticks(1:numChannels);
    xlim([0, tStop]);
    ylim([0.5, numChannels + 0.5]);
    drawnow;

    formatSpec = 'Output %3d/%3d: ch=%d, tSample=%.8f s, Vdiff=%.7f V, code=%3d, Vout=%.7f V \n';
    conversionIndex = 0;
    for sampleIndex = 1:numClockSamples
        tNow = (sampleIndex - 1) / clockSampleFreq;
        vdiff = inputAmplitude * sin(2 * pi * signalFreq * tNow);
        vip = 0.5 * vdiff;
        vin = -0.5 * vdiff;

        edgeIndex = floor((sampleIndex - 1) / samplesPerSarClock);
        conversionSlot = floor(edgeIndex / (nBits + 1));
        activeChannel = mod(conversionSlot, numChannels) + 1;
        clkHigh = mod(sampleIndex - 1, samplesPerSarClock) < samplesPerSarClock / 2;

        for channelIndex = 1:numChannels
            clk = channelIndex == activeChannel && clkHigh;

            [adc{channelIndex}, ~, dout_dec, vout, conversionDone, trace] = adc{channelIndex}.convertByClock(vip, vin, clk);

            if conversionDone
                conversionIndex = conversionIndex + 1;
                channelCount(channelIndex) = channelCount(channelIndex) + 1;
                sampleEdgeIndex = floor((sampleIndex - 1) / samplesPerSarClock) - nBits;

                tSample(conversionIndex) = sampleEdgeIndex / sarClockFreq;
                vSample(conversionIndex) = trace.Vdiff;
                vipSample(conversionIndex) = trace.Vip;
                vinSample(conversionIndex) = trace.Vin;
                tOutput(conversionIndex) = tNow;
                vOutput(conversionIndex) = vout;
                codeOutput_dec(conversionIndex) = dout_dec;
                channelOutput(conversionIndex) = channelIndex;

                fprintf(formatSpec, conversionIndex, numConversions, channelIndex, tSample(conversionIndex), vSample(conversionIndex), dout_dec, vout);
            end
        end
    end

    if conversionIndex ~= numConversions
        error('Expected %d total conversions, got %d.', numConversions, conversionIndex);
    end

    if any(channelCount ~= numConversionsPerChannel)
        error('Per-channel conversion count check failed.');
    end

    if combinedConversionsPerPeriod ~= numChannels * channelConversionsPerPeriod
        error('Combined conversion count per period check failed.');
    end

    if max(abs(vSample - (vipSample - vinSample))) > 10 * eps
        error('Differential sample check failed.');
    end

    if any(abs(vSample) > inputAmplitude + 10 * eps)
        error('TAH sample is outside expected differential input range.');
    end

    [~, sortIndex] = sort(tOutput);
    sortedChannelOutput = channelOutput(sortIndex);
    expectedChannelOutput = mod(0:numConversions-1, numChannels) + 1;
    if any(sortedChannelOutput ~= expectedChannelOutput)
        error('Time-interleaved channel order check failed.');
    end

    sortedSampleTime = tSample(sortIndex);
    expectedSampleSpacing = 1 / combinedConversionFreq;
    if max(abs(diff(sortedSampleTime) - expectedSampleSpacing)) > 10 * eps(max(sortedSampleTime))
        error('Interleaved sample spacing check failed.');
    end

    set(outputPlot, 'XData', tOutput, 'YData', vOutput);
    for plotIndex = 1:numChannels
        channelMask = channelOutput == plotIndex;
        set(samplePlot(plotIndex), 'XData', tSample(channelMask), 'YData', vSample(channelMask));
    end
    set(channelOrderPlot, 'XData', tOutput, 'YData', channelOutput);

    outputPng = fullfile(resultDir, 'test_sar_adc_channel_quad.png');
    outputMat = fullfile(resultDir, 'test_sar_adc_channel_quad_result.mat');
    exportgraphics(fig, outputPng, 'Resolution', 150);
    save(outputMat, 'tOutput', 'vOutput', 'tSample', 'vSample', 'vipSample', 'vinSample', 'codeOutput_dec', 'channelOutput', 'channelCount', 'combinedConversionsPerPeriod', 'channelConversionsPerPeriod');

    fprintf('SAR ADC channel quad test completed.\n');
    fprintf('Signal frequency: %.6g Hz\n', signalFreq);
    fprintf('SAR clock frequency: %.6g Hz\n', sarClockFreq);
    fprintf('Combined conversions per period: %d\n', combinedConversionsPerPeriod);
    fprintf('Per-channel conversions per period: %d\n', channelConversionsPerPeriod);
    fprintf('Per-channel conversion frequency: %.6g Hz\n', channelConversionFreq);
    fprintf('Combined conversion frequency: %.6g Hz\n', combinedConversionFreq);
    fprintf('Completed conversions: %d\n', conversionIndex);
    fprintf('Per-channel conversions: %d %d %d %d\n', channelCount(1), channelCount(2), channelCount(3), channelCount(4));
    fprintf('First output channel/code: %d/%d\n', channelOutput(1), codeOutput_dec(1));
    fprintf('Last output channel/code: %d/%d\n', channelOutput(conversionIndex), codeOutput_dec(conversionIndex));
    fprintf('Saved plot: %s\n', outputPng);
    fprintf('Saved result: %s\n', outputMat);
end
