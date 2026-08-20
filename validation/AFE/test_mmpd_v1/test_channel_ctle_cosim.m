function result = test_channel_ctle_cosim()
%TEST_CHANNEL_CTLE_COSIM Cache one complete PRBS20 Channel+CTLE waveform.
%   The TX FFE implementation is retained under IF FALSE and is disabled by
%   default. The complete CTLE output is streamed to a v7.3 MAT file so later
%   ADC, CDR FFE, and MMPD phase scans do not rerun Channel or CTLE.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
afeValidationDir = fileparts(testDir);
validationDir = fileparts(afeValidationDir);
repoRoot = fileparts(validationDir);
addpath(fullfile(repoRoot, 'src', 'TX+Channel'));
addpath(fullfile(repoRoot, 'src', 'AFE'));

symbolRate = 56e9;
samplePerSymbol = 128;
prbs20BitCount = 2^20 - 1;
streamChunkSymbols = 8192;

ctleZeroFrequency = 6e9;
ctleFirstPoleFrequency = 28e9;
ctleSecondPoleFrequency = 50e9;
ctleDcGainDb = 0;

pam4Level = [-3 -1 1 3];
pam4Symbols = generatePrbs20Pam4(prbs20BitCount, pam4Level);
numSymbols = numel(pam4Symbols);
numSamples = numSymbols * samplePerSymbol;
assert(numSymbols == 2^19, ...
    'A complete PRBS20 period must produce 524288 PAM4 symbols.');

channelModel = tx_channel([], symbolRate, samplePerSymbol);
ctleModel = ctle(samplePerSymbol);
ctleModel.SymbolRate = symbolRate;
ctleModel.ZeroFrequency = ctleZeroFrequency;
ctleModel.FirstPoleFrequency = ctleFirstPoleFrequency;
ctleModel.SecondPoleFrequency = ctleSecondPoleFrequency;
ctleModel.DCGainDb = ctleDcGainDb;

channelImpulse = channelModel.ImpulseResponse;
channelCtleImpulse = ctleModel.process(channelImpulse);
txFfeEnabled = false;
if false
    % Preserved TX FFE path: 3 precursor, main, and 6 postcursor taps.
    txFfeTapOffset = -3:6;
    txFfeFitCursorOffset = -3:6;
    [txFfeCoefficients, txFfeOptimization] = optimizeTxFfe( ...
        channelCtleImpulse, samplePerSymbol, txFfeTapOffset, ...
        txFfeFitCursorOffset);
    txFfeEnabled = true;
else
    txFfeTapOffset = 0;
    txFfeCoefficients = 1;
    txFfeOptimization = struct();
end

resultDir = fullfile(testDir, 'result', 'channel_ctle_cosim');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end
cachePath = fullfile(resultDir, 'channel_ctle.mat');
writeChannelCtleCache(cachePath, pam4Symbols, channelModel, ctleModel, ...
    txFfeCoefficients, txFfeTapOffset, txFfeEnabled, ...
    streamChunkSymbols, channelCtleImpulse, prbs20BitCount);

cacheFile = matfile(cachePath);
cacheSize = size(cacheFile, 'ctleOutput');
cacheInfo = whos(cacheFile, 'ctleOutput');
assert(isequal(cacheSize, [1 numSamples]), ...
    'Cached CTLE waveform has the wrong dimensions.');
assert(strcmp(cacheInfo.class, 'single'), ...
    'Cached CTLE waveform must use single precision.');
assert(double(cacheFile.numSymbols) == numSymbols, ...
    'Cached symbol count is incorrect.');
assert(double(cacheFile.prbs20BitCount) == prbs20BitCount, ...
    'Cached PRBS20 bit count is incorrect.');

result = struct();
result.CachePath = cachePath;
result.Prbs20BitCount = prbs20BitCount;
result.NumSymbols = numSymbols;
result.NumSamples = numSamples;
result.SymbolRate = symbolRate;
result.SamplePerSymbol = samplePerSymbol;
result.SampleInterval = channelModel.SampleInterval;
result.StreamChunkSymbols = streamChunkSymbols;
result.TxFfeEnabled = txFfeEnabled;
result.TxFfeTapOffset = txFfeTapOffset;
result.TxFfeCoefficients = txFfeCoefficients;
result.TxFfeOptimization = txFfeOptimization;
result.CtleZeroFrequency = ctleZeroFrequency;
result.CtleFirstPoleFrequency = ctleFirstPoleFrequency;
result.CtleSecondPoleFrequency = ctleSecondPoleFrequency;
result.CtleDcGainDb = ctleDcGainDb;

fprintf(['Channel+CTLE cache passed: complete PRBS20, %d PAM4 symbols, ' ...
    '%d samples, TX FFE enabled=%d.\n'], ...
    numSymbols, numSamples, txFfeEnabled);
fprintf('Cache saved to %s.\n', cachePath);
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

function writeChannelCtleCache(cachePath, symbols, channelModel, ...
    ctleModel, txFfeCoefficients, txFfeTapOffset, txFfeEnabled, ...
    chunkSymbols, channelCtleImpulse, prbs20BitCount)
%WRITECHANNELCTLECACHE Stream the full waveform directly into a MAT cache.

if isfile(cachePath)
    delete(cachePath);
end

samplePerSymbol = channelModel.SamplesPerSymbol;
sampleInterval = channelModel.SampleInterval;
channelImpulse = double(channelModel.ImpulseResponse(:));
channelHistoryLength = numel(channelImpulse) - 1;
channelHistory = zeros(channelHistoryLength, 1);
ctleSystem = ss(ctleModel.transferFunction());
ctleState = [];
previousCtleInput = [];
txFfeState = zeros(numel(txFfeCoefficients) - 1, 1);
numSymbols = numel(symbols);
numSamples = numSymbols * samplePerSymbol;

cacheFile = matfile(cachePath, 'Writable', true);
cacheFile.ctleOutput(1, numSamples) = single(0);
cacheFile.cacheVersion = uint32(2);
cacheFile.prbs20BitCount = uint32(prbs20BitCount);
cacheFile.isCompletePrbs20Period = true;
cacheFile.pam4Symbols = int8(symbols);
cacheFile.pam4Levels = int8([-3 -1 1 3]);
cacheFile.symbolRate = channelModel.SymbolRate;
cacheFile.samplePerSymbol = uint32(samplePerSymbol);
cacheFile.sampleInterval = sampleInterval;
cacheFile.numSymbols = uint32(numSymbols);
cacheFile.numSamples = uint64(numSamples);
cacheFile.channelFile = channelModel.ChannelFile;
cacheFile.channelCtleImpulse = channelCtleImpulse;
cacheFile.ctleZeroFrequency = ctleModel.ZeroFrequency;
cacheFile.ctleFirstPoleFrequency = ctleModel.FirstPoleFrequency;
cacheFile.ctleSecondPoleFrequency = ctleModel.SecondPoleFrequency;
cacheFile.ctleDcGainDb = ctleModel.DCGainDb;
cacheFile.txFfeEnabled = logical(txFfeEnabled);
cacheFile.txFfeTapOffset = int8(txFfeTapOffset);
cacheFile.txFfeCoefficients = txFfeCoefficients;

numChunks = ceil(numSymbols / chunkSymbols);
for chunkIndex = 1:numChunks
    firstSymbol = (chunkIndex - 1) * chunkSymbols + 1;
    lastSymbol = min(chunkIndex * chunkSymbols, numSymbols);
    symbolChunk = double(symbols(firstSymbol:lastSymbol)).';
    [txFfeChunk, txFfeState] = filter(txFfeCoefficients, 1, ...
        symbolChunk, txFfeState);
    txWaveformChunk = repelem(txFfeChunk, samplePerSymbol);

    extendedInput = [channelHistory; txWaveformChunk];
    extendedOutput = fftfilt(channelImpulse, extendedInput);
    channelChunk = extendedOutput(channelHistoryLength + 1:end);
    channelHistory = extendedInput(end - channelHistoryLength + 1:end);

    if chunkIndex == 1
        ctleInput = channelChunk;
        ctleTime = (0:numel(ctleInput) - 1).' * sampleInterval;
        [ctleChunk, ~, stateTrace] = lsim( ...
            ctleSystem, ctleInput, ctleTime);
    else
        ctleInput = [previousCtleInput; channelChunk];
        ctleTime = (0:numel(ctleInput) - 1).' * sampleInterval;
        [ctleExtended, ~, stateTrace] = lsim( ...
            ctleSystem, ctleInput, ctleTime, ctleState);
        ctleChunk = ctleExtended(2:end);
    end
    ctleState = stateTrace(end, :);
    previousCtleInput = channelChunk(end);

    firstSample = (firstSymbol - 1) * samplePerSymbol + 1;
    lastSample = lastSymbol * samplePerSymbol;
    cacheFile.ctleOutput(1, firstSample:lastSample) = ...
        reshape(single(ctleChunk), 1, []);
    fprintf('Channel+CTLE cache progress: %d / %d chunks.\n', ...
        chunkIndex, numChunks);
end
end

function [coefficients, optimization] = optimizeTxFfe( ...
    channelCtleImpulse, samplePerSymbol, tapOffset, fitCursorOffset)
%OPTIMIZETXFFE Retained ten-tap TX FFE optimizer for optional use.

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
    normalizedCursor = cursor / cursor(mainCursorRow);
    score = sqrt(mean(normalizedCursor(otherCursorMask) .^ 2)) + ...
        0.25 * max(abs(normalizedCursor(otherCursorMask)));
    if score < bestScore
        bestScore = score;
        best.Phase = phase;
        best.Coefficients = candidate(:).';
        best.NormalizedCursor = normalizedCursor(:).';
        best.Regularization = regularization;
    end
end

coefficients = best.Coefficients;
optimization = best;
optimization.TapOffset = tapOffset;
optimization.FitCursorOffset = fitCursorOffset;
optimization.Score = bestScore;
end
