function result = test_cdr_top_convergence_nrz
% test_cdr_top_convergence_nrz  Track an ideal NRZ edge with the digital CDR.

thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(validationDir));
addpath(fullfile(repoRoot, 'src', 'CDR'));

resultDir = fullfile(repoRoot, 'results', 'CDR');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

samplesPerUI = 128;
blockSize = 64;
numBlocks = 64;
edgeOffsetSamples = 24;
numSymbols = blockSize * numBlocks;

% Alternating NRZ symbols provide one ideal transition per UI so the
% convergence trace is independent of random transition density.
symbolNumber = 0:numSymbols;
txBits = mod(symbolNumber, 2);
txLevels = 2 * txBits - 1;

% Build a 128x oversampled ideal-edge waveform. Symbol n starts at
% (n - 1) UI plus the configured edge offset.
numWaveformSamples = (numSymbols + 1) * samplesPerUI;
waveformSample = 0:numWaveformSamples - 1;
waveformSymbol = floor( ...
    (waveformSample - edgeOffsetSamples) / samplesPerUI) + 1;
waveformSymbol = min(max(waveformSymbol, 0), numSymbols);
waveform = txLevels(waveformSymbol + 1);

pd = cdr_pd('nrz', 1);
voter = cdr_voter('constant', blockSize, 8);
loopFilter = cdr_loop(0.25, 0);
piModel = cdr_pi(8, samplesPerUI);
piModel.resetNonideal();
top = cdr_top(pd, voter, loopFilter, piModel, txBits(1));

sampleIndexForBlock = zeros(1, numBlocks);
nextLocalIndexFloat = zeros(1, numBlocks);
phaseError = zeros(1, numBlocks);
deltaCode = zeros(1, numBlocks);
piCode = zeros(1, numBlocks);
validCount = zeros(1, numBlocks);

for blockIndex = 1:numBlocks
    symbolIndex = (blockIndex - 1) * blockSize + (1:blockSize);

    % This validation uses nearest-grid sampling of the ideal 128x
    % waveform. The project-wide round/interpolation choice remains open.
    localIndexFloat = top.CurrentLocalIndexFloat;
    localIndexInteger = round(localIndexFloat);
    edgeIndex = (symbolIndex - 1) * samplesPerUI + ...
        localIndexInteger + 1;
    dataIndex = (symbolIndex - 1) * samplesPerUI + ...
        samplesPerUI / 2 + localIndexInteger + 1;

    dataCurrBlock = waveform(dataIndex) > 0;
    edgeBitBlock = waveform(edgeIndex) > 0;
    output = top.processBlock(dataCurrBlock, edgeBitBlock);

    sampleIndexForBlock(blockIndex) = output.SampleIndexForBlock;
    nextLocalIndexFloat(blockIndex) = output.NextLocalIndexFloat;
    phaseError(blockIndex) = double(output.PhaseError);
    deltaCode(blockIndex) = output.DeltaCode;
    piCode(blockIndex) = output.PiCodeWrapped;
    validCount(blockIndex) = sum(output.Valid);
end

steadyStateBlock = numBlocks - 15:numBlocks;
phaseErrorSamples = sampleIndexForBlock - edgeOffsetSamples;
assert(all(validCount == blockSize), ...
    'Every UI should contain a valid transition in this ideal test.');
assert(any(phaseError > 0) && any(phaseError < 0), ...
    'The CDR should cross the target edge and reverse its phase decision.');
assert(max(abs(phaseErrorSamples(steadyStateBlock))) <= 1, ...
    'The steady-state phase should remain within one waveform sample.');

blockAxis = 1:numBlocks;
waveformTimeUI = waveformSample / samplesPerUI;
figurePath = fullfile(resultDir, 'cdr_top_phase_convergence_nrz.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1100 850]);
t = tiledlayout(fig, 4, 1, ...
    'TileSpacing', 'compact', 'Padding', 'compact');
title(t, ['cdr\_top NRZ ideal-edge phase convergence: ' ...
    '64 blocks x 64 UI = 4096 UI']);

nexttile;
waveformHandle = stairs(waveformTimeUI, waveform, ...
    'b-', 'LineWidth', 1.2);
hold on;
for boundaryIndex = 0:4
    if boundaryIndex == 0
        nominalHandle = xline(boundaryIndex, ':', ...
            'Color', [0.45 0.45 0.45], 'LineWidth', 1.0);
        trueEdgeHandle = xline( ...
            boundaryIndex + edgeOffsetSamples / samplesPerUI, ...
            'r--', 'LineWidth', 1.0);
    else
        xline(boundaryIndex, ':', ...
            'Color', [0.45 0.45 0.45], 'LineWidth', 1.0, ...
            'HandleVisibility', 'off');
        xline(boundaryIndex + edgeOffsetSamples / samplesPerUI, ...
            'r--', 'LineWidth', 1.0, 'HandleVisibility', 'off');
    end
end
text(edgeOffsetSamples / samplesPerUI + 0.05, -0.75, ...
    sprintf('%d samples = %.4f UI', edgeOffsetSamples, ...
    edgeOffsetSamples / samplesPerUI), ...
    'Color', [0.75 0 0], 'FontWeight', 'bold');
grid on;
xlim([0 4]);
ylim([-1.4 1.4]);
xlabel('Time from first nominal UI boundary (UI)');
ylabel('NRZ level');
title('Input zoom: first 4 of 4096 UI; alternating NRZ has one edge/UI');
legend([waveformHandle nominalHandle trueEdgeHandle], ...
    {'ideal waveform', 'nominal UI boundary', ...
    'true edge = nominal boundary + 24/128 UI'}, ...
    'Location', 'best');

nexttile;
plot(blockAxis, sampleIndexForBlock, 'b-o', ...
    'LineWidth', 1.2, 'MarkerSize', 3);
hold on;
yline(edgeOffsetSamples, 'r--', 'LineWidth', 1.2);
grid on;
ylabel('phase (sample)');
title('PI sampling phase converges to the true edge phase');
legend('PI phase entering block', 'true edge phase', 'Location', 'best');

nexttile;
stairs(blockAxis, phaseErrorSamples, 'LineWidth', 1.2);
hold on;
yline(0, 'k--');
grid on;
ylabel('error (sample)');
title('Sampling-phase error');

nexttile;
yyaxis left;
stairs(blockAxis, phaseError, 'LineWidth', 1.2);
ylabel('voter output');
yyaxis right;
stairs(blockAxis, deltaCode, '--', 'LineWidth', 1.2);
ylabel('\Delta PI code');
grid on;
xlabel('64-UI block index');
title('CDR control decisions');
legend('phaseError', 'deltaCode', 'Location', 'best');

exportgraphics(fig, figurePath, 'Resolution', 200);
close(fig);

result = struct();
result.SamplesPerUI = samplesPerUI;
result.BlockSize = blockSize;
result.NumBlocks = numBlocks;
result.EdgeOffsetSamples = edgeOffsetSamples;
result.SampleIndexForBlock = sampleIndexForBlock;
result.NextLocalIndexFloat = nextLocalIndexFloat;
result.PhaseErrorSamples = phaseErrorSamples;
result.PhaseError = phaseError;
result.DeltaCode = deltaCode;
result.PiCode = piCode;
result.ValidCount = validCount;
result.FigurePath = figurePath;

fprintf('test_cdr_top_convergence_nrz passed.\n');
fprintf('Steady-state phase range: %.3f to %.3f samples.\n', ...
    min(sampleIndexForBlock(steadyStateBlock)), ...
    max(sampleIndexForBlock(steadyStateBlock)));
fprintf('Saved PNG: %s\n', figurePath);
end
