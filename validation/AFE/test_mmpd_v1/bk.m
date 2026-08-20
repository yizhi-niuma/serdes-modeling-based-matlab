function result = test_channel_ctle_cosim()
%TEST_CHANNEL_CTLE_COSIM Run Channel, CTLE, TI ADC, and CDR FFE co-simulation.
%   The preserved TX FFE path is disabled below with IF FALSE. The active
%   path samples the CTLE output with a 7-bit TI ADC and filters the centered
%   ADC codes with the same ten coefficients as the disabled TX FFE.

if false
    thisFile = mfilename('fullpath');
    testDir = fileparts(thisFile);
    afeValidationDir = fileparts(testDir);
    validationDir = fileparts(afeValidationDir);
    repoRoot = fileparts(validationDir);
    addpath(fullfile(repoRoot, 'src', 'TX+Channel'));
    addpath(fullfile(repoRoot, 'src', 'AFE'));

    symbolRate = 56e9;
    samplePerSymbol = 128;
    numSymbols = 8192;
    eyeNumUi = 2048;
    numEyeTraces = eyeNumUi / 2;
    eyeStartUi = 512;
    numPhaseEvaluationUi = eyeNumUi;

    % CTLE tuning parameters. Change these three frequencies to review a new
    % frequency response, eye diagram, impulse response, and sampling metric.
    ctleZeroFrequency = 6e9;
    ctleFirstPoleFrequency = 28e9;
    ctleSecondPoleFrequency = 50e9;
    ctleDcGainDb = 0;

    pam4Level = [-3 -1 1 3];
    txFfeTapOffset = -3:6;
    txFfeFitCursorOffset = -3:6;
    pam4Symbols = generatePrbs20Pam4(2 * numSymbols, pam4Level);
    assert(numel(pam4Symbols) == numSymbols, ...
        'PRBS20 generation produced the wrong PAM4 symbol count.');
    assert(isequal(unique(pam4Symbols), pam4Level), ...
        'Generated PRBS20 PAM4 symbols do not contain all four levels.');

    channelModel = tx_channel([], symbolRate, samplePerSymbol);
    ctleModel = ctle(samplePerSymbol);
    ctleModel.SymbolRate = symbolRate;
    ctleModel.ZeroFrequency = ctleZeroFrequency;
    ctleModel.FirstPoleFrequency = ctleFirstPoleFrequency;
    ctleModel.SecondPoleFrequency = ctleSecondPoleFrequency;
    ctleModel.DCGainDb = ctleDcGainDb;

    channelImpulse = channelModel.ImpulseResponse;
    channelCtleImpulse = ctleModel.process(channelImpulse);
    [txFfeCoefficients, txFfeOptimization] = optimizeTxFfe( ...
        channelCtleImpulse, samplePerSymbol, txFfeTapOffset, ...
        txFfeFitCursorOffset);
    txFfeSymbols = filter(txFfeCoefficients, 1, double(pam4Symbols));
    [channelOutput, time] = channelModel.process(txFfeSymbols);
    ctleOutput = ctleModel.process(channelOutput);

    nyquistFrequency = symbolRate / 2;
    nyquistResponse = squeeze(freqresp(ctleModel.transferFunction(), ...
        2 * pi * nyquistFrequency));
    nyquistGainDb = 20 * log10(abs(nyquistResponse));

    txFfeChannelCtleImpulse = applyTxFfeToImpulse( ...
        channelCtleImpulse, txFfeCoefficients, samplePerSymbol);
    [~, channelCtleMainIndex] = max(abs(txFfeChannelCtleImpulse));
    txFfeChannelCtleSymbolPulse = conv(txFfeChannelCtleImpulse, ...
        ones(samplePerSymbol, 1));
    [symbolPulseTimeUi, symbolPulseNormalized, symbolPulseCursor] = ...
        normalizePulse(txFfeChannelCtleSymbolPulse, samplePerSymbol, ...
        txFfeOptimization.SymbolPulseMainIndex, txFfeFitCursorOffset);

    [phasePower, maximumPowerPhase] = measurePhasePower(ctleOutput, ...
        samplePerSymbol, eyeStartUi, numPhaseEvaluationUi);
    mainImpulsePhase = mod(channelCtleMainIndex - 1, samplePerSymbol);
    mainImpulseUi = floor((channelCtleMainIndex - 1) / samplePerSymbol);
    symbolLag = mainImpulseUi + double(maximumPowerPhase < mainImpulsePhase);
    [levelMean, levelSigma, powerPhaseSeparation] = ...
        measureLabelConditionedSeparation(ctleOutput, pam4Symbols, pam4Level, ...
        samplePerSymbol, eyeStartUi, numPhaseEvaluationUi, ...
        maximumPowerPhase, symbolLag);
    [phaseSeparation, bestEyePhase, bestEyeLevelMean, ...
        bestEyeLevelSigma, bestEyeSeparation, bestEyeSymbolLag] = ...
        scanLabelConditionedSeparation(ctleOutput, pam4Symbols, pam4Level, ...
        samplePerSymbol, eyeStartUi, numPhaseEvaluationUi, ...
        channelCtleMainIndex);

    ctleEye = makeEyeMatrix(ctleOutput, samplePerSymbol, ...
        eyeStartUi, numEyeTraces);
    eyeTime = (0:2 * samplePerSymbol - 1) / samplePerSymbol;

    resultDir = fullfile(testDir, 'result', 'channel_ctle_cosim');
    if ~exist(resultDir, 'dir')
        mkdir(resultDir);
    end

    frequencyFigurePath = fullfile(resultDir, ...
        'ctle_and_channel_ctle_frequency_response.png');
    frequencyHz = logspace(8, 11, 1000);
    ctleFrequencyResponse = squeeze(freqresp(ctleModel.transferFunction(), ...
        2 * pi * frequencyHz));
    ctleMagnitudeDb = 20 * log10(abs(ctleFrequencyResponse));
    fftLength = 2^nextpow2(numel(channelImpulse));
    channelFft = fft(channelImpulse, fftLength);
    channelFft = channelFft(1:fftLength / 2 + 1);
    channelFftFrequency = (0:fftLength / 2) * ...
        channelModel.SampleRate / fftLength;
    channelFrequencyResponse = interp1(channelFftFrequency, channelFft, ...
        frequencyHz, 'linear');
    channelCtleFrequencyResponse = channelFrequencyResponse(:) .* ...
        ctleFrequencyResponse(:);
    channelCtleMagnitudeDb = 20 * log10(abs(channelCtleFrequencyResponse));
    channelCtleNyquistResponse = interp1(frequencyHz, ...
        channelCtleFrequencyResponse, nyquistFrequency, 'linear');
    channelCtleNyquistGainDb = 20 * log10(abs(channelCtleNyquistResponse));
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 900]);
    tiled = tiledlayout(fig, 2, 1, ...
        'TileSpacing', 'compact', 'Padding', 'compact');
    nexttile;
    semilogx(frequencyHz / 1e9, ctleMagnitudeDb, ...
        'b-', 'LineWidth', 1.4);
    hold on;
    xline(ctleZeroFrequency / 1e9, 'k--', 'Zero', ...
        'LabelVerticalAlignment', 'bottom');
    xline(ctleFirstPoleFrequency / 1e9, 'm--', 'Pole 1', ...
        'LabelVerticalAlignment', 'bottom');
    xline(ctleSecondPoleFrequency / 1e9, 'c--', 'Pole 2', ...
        'LabelVerticalAlignment', 'bottom');
    plot(nyquistFrequency / 1e9, nyquistGainDb, 'ro', ...
        'MarkerFaceColor', 'r', 'MarkerSize', 7);
    text(nyquistFrequency / 1e9, nyquistGainDb, ...
        sprintf('  Nyquist: %.2f dB', nyquistGainDb), ...
        'VerticalAlignment', 'bottom');
    yline(ctleDcGainDb, 'k:');
    hold off;
    grid on;
    xlim([frequencyHz(1) frequencyHz(end)] / 1e9);
    xlabel('Frequency (GHz)');
    ylabel('Magnitude (dB)');
    title(sprintf(['CTLE Magnitude Response: f_z=%.0f GHz, ' ...
        'f_{p1}=%.0f GHz, f_{p2}=%.0f GHz'], ...
        ctleZeroFrequency / 1e9, ctleFirstPoleFrequency / 1e9, ...
        ctleSecondPoleFrequency / 1e9));
    nexttile;
    semilogx(frequencyHz / 1e9, channelCtleMagnitudeDb, ...
        'r-', 'LineWidth', 1.4);
    hold on;
    plot(nyquistFrequency / 1e9, channelCtleNyquistGainDb, 'bo', ...
        'MarkerFaceColor', 'b', 'MarkerSize', 7);
    text(nyquistFrequency / 1e9, channelCtleNyquistGainDb, ...
        sprintf('  Nyquist: %.2f dB', channelCtleNyquistGainDb), ...
        'VerticalAlignment', 'bottom');
    hold off;
    grid on;
    xlim([frequencyHz(1) frequencyHz(end)] / 1e9);
    xlabel('Frequency (GHz)');
    ylabel('Magnitude (dB)');
    title('S-Parameter Channel + CTLE Magnitude Response');
    title(tiled, 'CTLE and Channel + CTLE Frequency Responses');
    exportgraphics(fig, frequencyFigurePath, 'Resolution', 150);
    close(fig);

    unitUiFigurePath = fullfile(resultDir, ...
        'tx_ffe_channel_ctle_unit_ui_response.png');
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 620]);
    plot(symbolPulseTimeUi, symbolPulseNormalized, ...
        'r-', 'LineWidth', 1.2);
    hold on;
    stem(txFfeFitCursorOffset, symbolPulseCursor, 'ro', ...
        'filled', 'LineWidth', 1.0, 'MarkerSize', 4);
    hold off;
    grid on;
    xlim([-3 6]);
    ylim([-1.1 1.1]);
    xline(0, 'k--');
    yline(0, 'k:');
    xlabel('Cursor Offset (UI)');
    ylabel('Normalized Amplitude');
    title(['TX FFE + Channel + CTLE Total Unit-UI Response: ' ...
        '10 taps (3 pre, 1 main, 6 post)']);
    exportgraphics(fig, unitUiFigurePath, 'Resolution', 150);
    close(fig);

    ctleEyePath = fullfile(resultDir, 'tx_ffe_channel_ctle_eye.png');
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 900 600]);
    plot(eyeTime, ctleEye, 'Color', [0.85 0.15 0.1 0.10]);
    hold on;
    xline(maximumPowerPhase / samplePerSymbol, 'b--', ...
        'LineWidth', 1.4);
    xline(1 + maximumPowerPhase / samplePerSymbol, 'b--', ...
        'LineWidth', 1.4);
    xline(bestEyePhase / samplePerSymbol, 'g--', ...
        'LineWidth', 1.4);
    xline(1 + bestEyePhase / samplePerSymbol, 'g--', ...
        'LineWidth', 1.4);
    hold off;
    grid on;
    xlim([0 2]);
    xlabel('Time (UI)');
    ylabel('Amplitude');
    title(sprintf(['TX FFE + Channel + CTLE Eye: %d UI, ' ...
        'Power/Best Phase=%d/%d'], eyeNumUi, ...
        maximumPowerPhase, bestEyePhase));
    exportgraphics(fig, ctleEyePath, 'Resolution', 150);
    close(fig);

    assert(isequal(size(channelOutput), size(ctleOutput)), ...
        'CTLE output shape differs from the channel output shape.');
    assert(all(isfinite(channelOutput)) && all(isfinite(ctleOutput)), ...
        'Co-simulation produced nonfinite waveform samples.');
    assert(all(isfinite(channelCtleImpulse)), ...
        'Channel and CTLE cascade impulse response contains nonfinite values.');
    assert(all(isfinite(txFfeChannelCtleImpulse)), ...
        'TX FFE, channel, and CTLE cascade impulse response contains nonfinite values.');
    assert(abs(symbolPulseCursor(txFfeFitCursorOffset == 0) - 1) < 1e-12, ...
        'Normalized TX FFE, channel, and CTLE main cursor is not one.');
    assert(max(abs(symbolPulseCursor - ...
        txFfeOptimization.NormalizedCursor)) < 1e-12, ...
        'Plotted symbol-pulse cursors differ from the TX FFE optimization.');
    assert(abs(sum(abs(txFfeCoefficients)) - 1) < 1e-12, ...
        'TX FFE coefficients do not satisfy unit L1 normalization.');
    assert(txFfeCoefficients(txFfeTapOffset == 0) > 0, ...
        'TX FFE main coefficient is not positive.');
    if bestEyeSeparation <= 1.5
        warning('test_channel_ctle_cosim:WeakBestPhaseOpening', ...
            ['The optimized TX FFE does not provide the target weak PAM4 ' ...
            'opening; best label-conditioned separation is %.4f.'], ...
            bestEyeSeparation);
    end

    result = struct();
    result.SymbolRate = symbolRate;
    result.SamplePerSymbol = samplePerSymbol;
    result.NumSymbols = numSymbols;
    result.EyeStartUi = eyeStartUi;
    result.EyeNumUi = eyeNumUi;
    result.Pam4Symbols = pam4Symbols;
    result.TxFfeSymbols = txFfeSymbols;
    result.TxFfeCoefficients = txFfeCoefficients;
    result.TxFfeTapOffset = txFfeTapOffset;
    result.TxFfeOptimization = txFfeOptimization;
    result.Time = time;
    result.ChannelOutput = channelOutput;
    result.CtleOutput = ctleOutput;
    result.ChannelCtleImpulse = channelCtleImpulse;
    result.TxFfeChannelCtleImpulse = txFfeChannelCtleImpulse;
    result.ChannelCtleMainIndex = channelCtleMainIndex;
    result.TxFfeChannelCtleSymbolPulse = txFfeChannelCtleSymbolPulse;
    result.SymbolPulseTimeUi = symbolPulseTimeUi;
    result.SymbolPulseNormalized = symbolPulseNormalized;
    result.SymbolPulseCursor = symbolPulseCursor;
    result.SymbolPulseMainIndex = txFfeOptimization.SymbolPulseMainIndex;
    result.CtleZeroFrequency = ctleZeroFrequency;
    result.CtleFirstPoleFrequency = ctleFirstPoleFrequency;
    result.CtleSecondPoleFrequency = ctleSecondPoleFrequency;
    result.CtleDcGainDb = ctleDcGainDb;
    result.NyquistGainDb = nyquistGainDb;
    result.ChannelCtleNyquistGainDb = channelCtleNyquistGainDb;
    result.PhasePower = phasePower;
    result.MaximumPowerPhase = maximumPowerPhase;
    result.SymbolLag = symbolLag;
    result.LevelMean = levelMean;
    result.LevelSigma = levelSigma;
    result.PowerPhaseSeparation = powerPhaseSeparation;
    result.PhaseSeparation = phaseSeparation;
    result.BestEyePhase = bestEyePhase;
    result.BestEyeSymbolLag = bestEyeSymbolLag;
    result.BestEyeLevelMean = bestEyeLevelMean;
    result.BestEyeLevelSigma = bestEyeLevelSigma;
    result.BestEyeSeparation = bestEyeSeparation;
    result.UnitUiFigurePath = unitUiFigurePath;
    result.CtleEyePath = ctleEyePath;
    result.FrequencyFigurePath = frequencyFigurePath;
    resultMatPath = fullfile(resultDir, 'result.mat');
    result.ResultMatPath = resultMatPath;
    save(resultMatPath, 'result', '-v7.3');

    fprintf(['TX FFE + Channel + CTLE co-simulation passed: PRBS20 PAM4, ' ...
        '%.0f GBd, ' ...
        '%d samples/UI, CTLE Nyquist gain %.2f dB.\n'], ...
        symbolRate / 1e9, samplePerSymbol, nyquistGainDb);
    fprintf('TX FFE taps [pre3 pre2 pre1 main post1:post6]: %s.\n', ...
        mat2str(txFfeCoefficients, 6));
    fprintf('Normalized 1-UI symbol-pulse cursors [-3:6 UI]: %s.\n', ...
        mat2str(symbolPulseCursor, 6));
    fprintf(['Maximum-power phase/separation: %d / %.4f; ' ...
        'best-eye phase/separation: %d / %.4f.\n'], ...
        maximumPowerPhase, powerPhaseSeparation, ...
        bestEyePhase, bestEyeSeparation);
    fprintf('Results saved to %s.\n', resultDir);
end

result = runAdcCdrFfeCosim();
end

function result = runAdcCdrFfeCosim()
%RUNADCCDRFFECOSIM Run the active no-TX-FFE ADC and CDR-FFE signal path.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
afeValidationDir = fileparts(testDir);
validationDir = fileparts(afeValidationDir);
repoRoot = fileparts(validationDir);
addpath(fullfile(repoRoot, 'src', 'TX+Channel'));
addpath(fullfile(repoRoot, 'src', 'AFE'));
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

symbolRate = 56e9;
samplePerSymbol = 128;
numSymbols = 8192;
adcWarmupUi = 512;
adcSamplingPhase = 19;
eyeStartUi = 512;
eyeNumUi = 2048;
numEyeTraces = eyeNumUi / 2;
adcLaneCount = 64;
adcSarPerTah = 8;
adcResolutionBits = 7;
adcFullRange = 4;

cdrFfeTapOffset = -3:6;
cdrFfePreTapCount = 3;
cdrFfeEvalOffset = -3:9;

ctleZeroFrequency = 6e9;
ctleFirstPoleFrequency = 28e9;
ctleSecondPoleFrequency = 50e9;
ctleDcGainDb = 0;

pam4Level = [-3 -1 1 3];
pam4Symbols = generatePrbs20Pam4(2 * numSymbols, pam4Level);
channelModel = tx_channel([], symbolRate, samplePerSymbol);
ctleModel = ctle(samplePerSymbol);
ctleModel.SymbolRate = symbolRate;
ctleModel.ZeroFrequency = ctleZeroFrequency;
ctleModel.FirstPoleFrequency = ctleFirstPoleFrequency;
ctleModel.SecondPoleFrequency = ctleSecondPoleFrequency;
ctleModel.DCGainDb = ctleDcGainDb;

% TX FFE is disabled: channel input is the original PAM4 symbol stream.
[channelOutput, time] = channelModel.process(double(pam4Symbols));
ctleOutput = ctleModel.process(channelOutput);

adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
[laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol);
zeroCode = 2^(adcResolutionBits - 1);

channelCtleImpulse = ctleModel.process(channelModel.ImpulseResponse);
channelCtleSymbolPulse = conv(double(channelCtleImpulse(:)), ...
    ones(samplePerSymbol, 1));
channelAdcCursorOffset = ...
    (cdrFfeEvalOffset(1) - cdrFfeTapOffset(end)): ...
    (cdrFfeEvalOffset(end) - cdrFfeTapOffset(1));
analogCursor = samplePulseAtPhase(channelCtleSymbolPulse, ...
    samplePerSymbol, adcSamplingPhase, channelAdcCursorOffset);
adcCursorCode = quantizeSamplesWithTiAdc(analogCursor, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    samplePerSymbol, laneToTimeOrder, nominalBlockLength);
adcCursorCodeCentered = adcCursorCode - zeroCode;
[cdrFfeCoefficients, cdrFfeDesign] = optimizeCdrFfe( ...
    adcCursorCodeCentered, channelAdcCursorOffset, ...
    cdrFfeTapOffset, cdrFfeEvalOffset);
totalUnitUiResponse = cdrFfeDesign.OutputCursor;
totalUnitUiResponseNormalized = cdrFfeDesign.NormalizedCursor;

numAdcBlocks = floor((numSymbols - adcWarmupUi) / adcLaneCount);
numAdcSamples = numAdcBlocks * adcLaneCount;
adcInputSamples = zeros(1, numAdcSamples);
adcCodes = zeros(1, numAdcSamples);
cdrFfeOutput = zeros(1, numAdcSamples);
cdrFfeValid = false(1, numAdcSamples);
cdrFfeModel = cdr_ffe(cdrFfeCoefficients, cdrFfePreTapCount);

for blockIndex = 1:numAdcBlocks
    firstUi = adcWarmupUi + (blockIndex - 1) * adcLaneCount;
    blockStartSample = firstUi * samplePerSymbol + adcSamplingPhase + 1;
    blockStopSample = blockStartSample + nominalBlockLength - 1;
    assert(blockStopSample <= numel(ctleOutput), ...
        'ADC block sampling window exceeds the CTLE waveform length.');
    blockWaveform = ctleOutput(blockStartSample:blockStopSample);
    blockCode = adcModel.convertOneBlockFast(blockWaveform, 1);
    timeOrderedCode = double(blockCode(laneToTimeOrder));
    centeredCode = timeOrderedCode - zeroCode;
    [blockFfeOutput, ~, blockFfeValid] = ...
        cdrFfeModel.processBlock(centeredCode);

    outputIndex = (blockIndex - 1) * adcLaneCount + (1:adcLaneCount);
    adcInputSamples(outputIndex) = blockWaveform(1:samplePerSymbol:end);
    adcCodes(outputIndex) = timeOrderedCode;
    cdrFfeOutput(outputIndex) = blockFfeOutput;
    cdrFfeValid(outputIndex) = blockFfeValid;
end
cdrFfeOutputValid = cdrFfeOutput(cdrFfeValid);

resultDir = fullfile(testDir, 'result', 'channel_ctle_cosim');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

ctleEye = makeEyeMatrix(ctleOutput, samplePerSymbol, ...
    eyeStartUi, numEyeTraces);
eyeTime = (0:2 * samplePerSymbol - 1) / samplePerSymbol;
ctleEyeFigurePath = fullfile(resultDir, 'ctle_output_eye.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 900 650]);
plot(eyeTime, ctleEye, 'Color', [0.85 0.15 0.1 0.08]);
hold on;
xline(adcSamplingPhase / samplePerSymbol, 'b--', ...
    'LineWidth', 1.4);
xline(1 + adcSamplingPhase / samplePerSymbol, 'b--', ...
    'LineWidth', 1.4);
yline(adcFullRange, 'k--', '+ADC Full Range', ...
    'LineWidth', 1.2);
yline(-adcFullRange, 'k--', '-ADC Full Range', ...
    'LineWidth', 1.2);
hold off;
grid on;
xlim([0 2]);
xlabel('Time (UI)');
ylabel('CTLE Output Voltage (V)');
title(sprintf(['Channel + CTLE Output Eye: %d UI, phase=%d/128, ' ...
    'ADC range=+/-%.1f V'], eyeNumUi, adcSamplingPhase, adcFullRange));
exportgraphics(fig, ctleEyeFigurePath, 'Resolution', 150);
close(fig);

unitUiFigurePath = fullfile(resultDir, ...
    'channel_ctle_adc_cdr_ffe_unit_ui_response.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1000 620]);
stem(cdrFfeEvalOffset, totalUnitUiResponseNormalized, 'ro', ...
    'filled', 'LineWidth', 1.2, 'MarkerSize', 6);
grid on;
xlim([cdrFfeEvalOffset(1) cdrFfeEvalOffset(end)]);
ylim([-0.2 1.1]);
xline(0, 'k--');
yline(0, 'k:');
yline(0.1, 'b:', 'pre1/post1 target');
xlabel('Cursor Offset (UI)');
ylabel('Normalized Equalized Code');
title(['Channel + CTLE + 7-bit ADC + CDR FFE Total Unit-UI ' ...
    'Response']);
exportgraphics(fig, unitUiFigurePath, 'Resolution', 150);
close(fig);

histogramFigurePath = fullfile(resultDir, ...
    'cdr_ffe_code_histogram.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 900 600]);
histogram(cdrFfeOutputValid, 200, 'Normalization', 'probability', ...
    'FaceColor', [0.2 0.4 0.8], 'EdgeColor', 'none');
grid on;
xlabel('CDR FFE Output Code (centered)');
ylabel('Probability');
title(sprintf(['CDR FFE Code Histogram: phase=%d/128, ' ...
    '%d blocks x 64 UI'], adcSamplingPhase, numAdcBlocks));
exportgraphics(fig, histogramFigurePath, 'Resolution', 150);
close(fig);

assert(all(isfinite(ctleOutput)), ...
    'CTLE output contains nonfinite samples.');
assert(all(adcCodes >= 0 & adcCodes <= 2^adcResolutionBits - 1), ...
    'ADC code is outside the 7-bit output range.');
assert(all(isfinite(cdrFfeOutputValid)) && ~isempty(cdrFfeOutputValid), ...
    'CDR FFE produced no valid finite output codes.');
assert(numel(cdrFfeCoefficients) == 10 && ...
    isequal(cdrFfeTapOffset, -3:6), ...
    'CDR FFE is not configured as 3 pre, 1 main, and 6 post taps.');
assert(abs(cdrFfeCoefficients(cdrFfeTapOffset == 0) - 1) < 1e-12, ...
    'CDR FFE main coefficient is not fixed to one.');
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == 0) - 1) < 1e-12, ...
    'Normalized total-path main cursor is not one.');
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == -1) - 0.1) < 1e-6, ...
    'Normalized total-path pre1 cursor does not equal 0.1.');
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == 1) - 0.1) < 1e-6, ...
    'Normalized total-path post1 cursor does not equal 0.1.');

result = struct();
result.SymbolRate = symbolRate;
result.SamplePerSymbol = samplePerSymbol;
result.NumSymbols = numSymbols;
result.Pam4Symbols = pam4Symbols;
result.Time = time;
result.ChannelOutput = channelOutput;
result.CtleOutput = ctleOutput;
result.TxFfeEnabled = false;
result.AdcSamplingPhase = adcSamplingPhase;
result.AdcSamplingMatlabIndex = adcSamplingPhase + 1;
result.AdcLaneCount = adcLaneCount;
result.AdcResolutionBits = adcResolutionBits;
result.AdcFullRange = [-adcFullRange adcFullRange];
result.AdcWarmupUi = adcWarmupUi;
result.EyeStartUi = eyeStartUi;
result.EyeNumUi = eyeNumUi;
result.NumAdcBlocks = numAdcBlocks;
result.AdcInputSamples = adcInputSamples;
result.AdcInputPeak = max(abs(adcInputSamples));
result.AdcInputOverrangeCount = nnz(abs(adcInputSamples) > adcFullRange);
result.AdcCodes = adcCodes;
result.AdcZeroCode = zeroCode;
result.AdcSaturationCount = nnz(adcCodes == 0 | ...
    adcCodes == 2^adcResolutionBits - 1);
result.CdrFfeTapOffset = cdrFfeTapOffset;
result.CdrFfeCoefficients = cdrFfeCoefficients;
result.CdrFfeDesign = cdrFfeDesign;
result.CdrFfeOutput = cdrFfeOutput;
result.CdrFfeValid = cdrFfeValid;
result.CdrFfeOutputValid = cdrFfeOutputValid;
result.UnitUiCursorOffset = cdrFfeEvalOffset;
result.ChannelAdcCursorOffset = channelAdcCursorOffset;
result.AnalogCursor = analogCursor;
result.AdcCursorCode = adcCursorCode;
result.AdcCursorCodeCentered = adcCursorCodeCentered;
result.TotalUnitUiResponse = totalUnitUiResponse;
result.TotalUnitUiResponseNormalized = totalUnitUiResponseNormalized;
result.CtleEye = ctleEye;
result.CtleEyeFigurePath = ctleEyeFigurePath;
result.UnitUiFigurePath = unitUiFigurePath;
result.HistogramFigurePath = histogramFigurePath;
resultMatPath = fullfile(resultDir, 'result.mat');
result.ResultMatPath = resultMatPath;
save(resultMatPath, 'result', '-v7.3');

fprintf(['Channel + CTLE + TI ADC + CDR FFE co-simulation passed: ' ...
    '%d symbols, phase %d/128, %d blocks x 64 UI.\n'], ...
    numSymbols, adcSamplingPhase, numAdcBlocks);
fprintf('ADC: 7 bit, full range +/-%.1f V, zero code %d, saturation count %d.\n', ...
    adcFullRange, zeroCode, result.AdcSaturationCount);
fprintf('ADC input peak %.4f V, overrange sample count %d.\n', ...
    result.AdcInputPeak, result.AdcInputOverrangeCount);
fprintf('CDR FFE taps [-3:6 UI]: %s.\n', ...
    mat2str(cdrFfeCoefficients, 6));
fprintf('Normalized total unit-UI response [-3:9 UI]: %s.\n', ...
    mat2str(totalUnitUiResponseNormalized, 6));
fprintf(['Total response pre1/main/post1: %.6f / %.6f / %.6f; ' ...
    'other cursor RMS %.6f.\n'], ...
    totalUnitUiResponseNormalized(cdrFfeEvalOffset == -1), ...
    totalUnitUiResponseNormalized(cdrFfeEvalOffset == 0), ...
    totalUnitUiResponseNormalized(cdrFfeEvalOffset == 1), ...
    cdrFfeDesign.OtherCursorRms);
fprintf('Results saved to %s.\n', resultDir);
end

function [coefficients, design] = optimizeCdrFfe( ...
    channelCursor, channelOffset, tapOffset, evalOffset)
%OPTIMIZECDRFFE Constrain pre1/post1 to 0.1 and minimize other ISI.

mainTapIndex = find(tapOffset == 0, 1);
freeTapMask = tapOffset ~= 0;
regressor = zeros(numel(evalOffset), numel(tapOffset));
for row = 1:numel(evalOffset)
    for column = 1:numel(tapOffset)
        requiredOffset = evalOffset(row) - tapOffset(column);
        channelIndex = find(channelOffset == requiredOffset, 1);
        assert(~isempty(channelIndex), ...
            'CDR FFE design requires an unavailable channel cursor.');
        regressor(row, column) = channelCursor(channelIndex);
    end
end

freeRegressor = regressor(:, freeTapMask);
fixedMainResponse = regressor(:, mainTapIndex);
pre1Row = find(evalOffset == -1, 1);
mainRow = find(evalOffset == 0, 1);
post1Row = find(evalOffset == 1, 1);
constraintMatrix = [ ...
    freeRegressor(pre1Row, :) - 0.1 * freeRegressor(mainRow, :); ...
    freeRegressor(post1Row, :) - 0.1 * freeRegressor(mainRow, :)];
constraintTarget = -[ ...
    fixedMainResponse(pre1Row) - 0.1 * fixedMainResponse(mainRow); ...
    fixedMainResponse(post1Row) - 0.1 * fixedMainResponse(mainRow)];

otherCursorMask = ~ismember(evalOffset, [-1 0 1]);
objectiveMatrix = freeRegressor(otherCursorMask, :);
objectiveTarget = fixedMainResponse(otherCursorMask);
normalMatrix = objectiveMatrix.' * objectiveMatrix;
regularizationScale = max(trace(normalMatrix) / ...
    size(normalMatrix, 1), eps);
regularization = 1e-8 * regularizationScale;
kktMatrix = [ ...
    normalMatrix + regularization * eye(size(normalMatrix)), ...
    constraintMatrix.'; ...
    constraintMatrix, zeros(size(constraintMatrix, 1))];
kktTarget = [-objectiveMatrix.' * objectiveTarget; constraintTarget];
kktSolution = kktMatrix \ kktTarget;

coefficients = zeros(1, numel(tapOffset));
coefficients(mainTapIndex) = 1;
coefficients(freeTapMask) = kktSolution(1:nnz(freeTapMask));
outputCursor = reshape(regressor * coefficients(:), 1, []);
mainCursor = outputCursor(mainRow);
assert(abs(mainCursor) > eps, ...
    'Optimized CDR FFE total-path main cursor is zero.');
normalizedCursor = outputCursor / mainCursor;

design = struct();
design.TapOffset = tapOffset;
design.EvalOffset = evalOffset;
design.Regressor = regressor;
design.Regularization = regularization;
design.OutputCursor = outputCursor;
design.NormalizedCursor = normalizedCursor;
design.OtherCursorRms = sqrt(mean( ...
    normalizedCursor(otherCursorMask) .^ 2));
design.OtherCursorMax = max(abs(normalizedCursor(otherCursorMask)));
end

function [laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol)
%ADCLANEORDERING Return physical-lane reorder indices and local block size.

laneNumber = 1:adcLaneCount;
numTah = adcLaneCount / adcSarPerTah;
lanePhaseIndex = floor((laneNumber - 1) / adcSarPerTah) + 1;
laneSarIndex = mod(laneNumber - 1, adcSarPerTah) + 1;
laneTimeOrderIndex = (laneSarIndex - 1) * numTah + lanePhaseIndex;
[~, laneToTimeOrder] = sort(laneTimeOrderIndex);
nominalBlockLength = (adcLaneCount - 1) * samplePerSymbol + 1;
end

function sample = samplePulseAtPhase(pulse, samplePerSymbol, phase, offset)
%SAMPLEPULSEATPHASE Sample a symbol-pulse response at fixed UI offsets.

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
%QUANTIZESAMPLEWITHTIADC Quantize up to one 64-UI block of cursor samples.

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

function pam4Symbols = generatePrbs20Pam4(numPrbsBits, pam4Level)
%GENERATEPRBS20PAM4 Generate natural-mapped PAM4 from PRBS20 bits.

prbs = comm.PNSequence('Polynomial', [20 3 0], ...
    'InitialConditions', ones(1, 20), ...
    'SamplesPerFrame', numPrbsBits);
prbsBits = double(prbs()).';
if mod(numel(prbsBits), 2) ~= 0
    prbsBits(end + 1) = prbsBits(1);
end
symbolCode = 2 * prbsBits(1:2:end) + prbsBits(2:2:end);
pam4Symbols = pam4Level(symbolCode + 1);
end

function eyeMatrix = makeEyeMatrix(waveform, samplePerSymbol, startUi, numTraces)
%MAKEEYEMATRIX Divide a settled waveform section into two-UI traces.

startIndex = startUi * samplePerSymbol + 1;
numSamples = 2 * samplePerSymbol * numTraces;
stopIndex = startIndex + numSamples - 1;
eyeMatrix = reshape(waveform(startIndex:stopIndex), ...
    2 * samplePerSymbol, numTraces);
end

function [phasePower, maximumPowerPhase] = measurePhasePower( ...
    waveform, samplePerSymbol, startUi, numUi)
%MEASUREPHASEPOWER Measure symbol-spaced waveform power at every phase.

phasePower = zeros(1, samplePerSymbol);
uiIndex = startUi + (0:numUi - 1);
for phase = 0:samplePerSymbol - 1
    sampleIndex = uiIndex * samplePerSymbol + phase + 1;
    phasePower(phase + 1) = mean(waveform(sampleIndex) .^ 2);
end
[~, maximumPowerIndex] = max(phasePower);
maximumPowerPhase = maximumPowerIndex - 1;
end

function [levelMean, levelSigma, separation] = ...
    measureLabelConditionedSeparation(waveform, symbols, pam4Level, ...
    samplePerSymbol, startUi, numUi, phase, symbolLag)
%MEASURELABELCONDITIONEDSEPARATION Check the opening at one sampling phase.

sampleIndex = (startUi + (0:numUi - 1)) * samplePerSymbol + phase + 1;
sample = waveform(sampleIndex);
alignedSymbol = symbols(startUi + (1:numUi) - symbolLag);
levelMean = zeros(1, 4);
levelSigma = zeros(1, 4);
for levelIndex = 1:4
    levelSample = sample(alignedSymbol == pam4Level(levelIndex));
    levelMean(levelIndex) = mean(levelSample);
    levelSigma(levelIndex) = std(levelSample);
end
separation = min(diff(levelMean) ./ sqrt( ...
    levelSigma(1:3) .^ 2 + levelSigma(2:4) .^ 2));
end

function [coefficients, optimization] = optimizeTxFfe( ...
    channelCtleImpulse, samplePerSymbol, tapOffset, fitCursorOffset)
%OPTIMIZETXFFE Find a ten-tap TX FFE that minimizes sampled residual ISI.

symbolPulse = conv(double(channelCtleImpulse(:)), ...
    ones(samplePerSymbol, 1));
[~, pulsePeakIndex] = max(abs(symbolPulse));
target = double(fitCursorOffset(:) == 0);
mainTapIndex = find(tapOffset == 0, 1);
mainCursorRow = find(fitCursorOffset == 0, 1);
otherCursorMask = fitCursorOffset ~= 0;
bestScore = Inf;
best = struct();

for phase = 0:samplePerSymbol - 1
    phaseIndex = phase + 1;
    candidateMainIndex = phaseIndex + round( ...
        (pulsePeakIndex - phaseIndex) / samplePerSymbol) * samplePerSymbol;
    regressor = zeros(numel(fitCursorOffset), numel(tapOffset));
    for row = 1:numel(fitCursorOffset)
        for column = 1:numel(tapOffset)
            pulseIndex = candidateMainIndex + ...
                (fitCursorOffset(row) - tapOffset(column)) * ...
                samplePerSymbol;
            assert(pulseIndex >= 1 && pulseIndex <= numel(symbolPulse), ...
                'TX FFE optimization pulse window exceeds available data.');
            regressor(row, column) = symbolPulse(pulseIndex);
        end
    end

    normalMatrix = regressor.' * regressor;
    regularizationScale = max(trace(normalMatrix) / numel(tapOffset), eps);
    regularization = 1e-8 * regularizationScale;
    candidate = (normalMatrix + regularization * eye(numel(tapOffset))) \ ...
        (regressor.' * target);
    if candidate(mainTapIndex) < 0
        candidate = -candidate;
    end
    candidate = candidate / sum(abs(candidate));
    cursor = regressor * candidate;
    if abs(cursor(mainCursorRow)) < eps
        continue;
    end
    normalizedCursor = cursor / cursor(mainCursorRow);
    otherCursorRms = sqrt(mean(normalizedCursor(otherCursorMask) .^ 2));
    otherCursorMax = max(abs(normalizedCursor(otherCursorMask)));
    score = otherCursorRms + 0.25 * otherCursorMax;
    if score < bestScore
        bestScore = score;
        best.Phase = phase;
        best.SymbolPulseMainIndex = candidateMainIndex + ...
            (mainTapIndex - 1) * samplePerSymbol;
        best.Coefficients = candidate(:).';
        best.Cursor = normalizedCursor(:).';
        best.OtherCursorRms = otherCursorRms;
        best.OtherCursorMax = otherCursorMax;
        best.Regularization = regularization;
        best.Regressor = regressor;
    end
end

assert(isfield(best, 'Coefficients'), ...
    'TX FFE optimization did not produce a valid solution.');
coefficients = best.Coefficients;
optimization = struct();
optimization.TapOffset = tapOffset;
optimization.FitCursorOffset = fitCursorOffset;
optimization.SelectedPhase = best.Phase;
optimization.SymbolPulseMainIndex = best.SymbolPulseMainIndex;
optimization.NormalizedCursor = best.Cursor;
optimization.OtherCursorRms = best.OtherCursorRms;
optimization.OtherCursorMax = best.OtherCursorMax;
optimization.Regularization = best.Regularization;
optimization.Score = bestScore;
end

function [timeUi, normalizedWindow, cursorValue] = normalizePulse( ...
    pulseResponse, samplePerSymbol, mainIndex, cursorOffsetUi)
%NORMALIZEPULSE Align and normalize a one-UI symbol-pulse response.

windowSampleOffset = cursorOffsetUi(1) * samplePerSymbol: ...
    cursorOffsetUi(end) * samplePerSymbol;
windowIndex = mainIndex + windowSampleOffset;
assert(windowIndex(1) >= 1 && windowIndex(end) <= numel(pulseResponse), ...
    'Symbol-pulse response does not cover the requested cursor window.');
mainValue = pulseResponse(mainIndex);
assert(abs(mainValue) > eps, 'Symbol-pulse main cursor is zero.');
timeUi = windowSampleOffset / samplePerSymbol;
normalizedWindow = pulseResponse(windowIndex) / mainValue;

cursorIndex = mainIndex + cursorOffsetUi * samplePerSymbol;
cursorValue = reshape(pulseResponse(cursorIndex) / mainValue, 1, []);
end

function outputImpulse = applyTxFfeToImpulse( ...
    inputImpulse, coefficients, samplePerSymbol)
%APPLYTXFFETOIMPULSE Apply symbol-spaced TX taps to an oversampled impulse.

expandedCoefficients = zeros( ...
    (numel(coefficients) - 1) * samplePerSymbol + 1, 1);
expandedCoefficients(1:samplePerSymbol:end) = coefficients(:);
outputImpulse = conv(double(inputImpulse(:)), expandedCoefficients);
end

function [phaseSeparation, bestPhase, bestLevelMean, bestLevelSigma, ...
    bestSeparation, bestSymbolLag] = scanLabelConditionedSeparation( ...
    waveform, symbols, pam4Level, samplePerSymbol, startUi, numUi, ...
    mainImpulseIndex)
%SCANLABELCONDITIONEDSEPARATION Find the best labeled PAM4 sampling phase.

phaseSeparation = zeros(1, samplePerSymbol);
mainImpulsePhase = mod(mainImpulseIndex - 1, samplePerSymbol);
mainImpulseUi = floor((mainImpulseIndex - 1) / samplePerSymbol);
levelMeanByPhase = zeros(samplePerSymbol, 4);
levelSigmaByPhase = zeros(samplePerSymbol, 4);
symbolLagByPhase = zeros(1, samplePerSymbol);
for phase = 0:samplePerSymbol - 1
    symbolLag = mainImpulseUi + double(phase < mainImpulsePhase);
    [levelMean, levelSigma, separation] = ...
        measureLabelConditionedSeparation(waveform, symbols, pam4Level, ...
        samplePerSymbol, startUi, numUi, phase, symbolLag);
    phaseSeparation(phase + 1) = separation;
    levelMeanByPhase(phase + 1, :) = levelMean;
    levelSigmaByPhase(phase + 1, :) = levelSigma;
    symbolLagByPhase(phase + 1) = symbolLag;
end
[bestSeparation, bestIndex] = max(phaseSeparation);
bestPhase = bestIndex - 1;
bestLevelMean = levelMeanByPhase(bestIndex, :);
bestLevelSigma = levelSigmaByPhase(bestIndex, :);
bestSymbolLag = symbolLagByPhase(bestIndex);
end
