function result = test_cdr_top_convergence_pam4
% test_cdr_top_convergence_pam4  跟踪理想的 PAM4 对称边沿。

thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(validationDir));
addpath(fullfile(repoRoot, 'src', 'CDR'));

resultDir = fullfile(repoRoot, 'results', 'CDR');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

config = struct();
config.SamplesPerUI = 128;
config.BlockSize = 64;
config.NumBlocks = 64;
config.EdgeOffsetSamples = 24;

% 测试 cdr_pd 支持的两类对称 PAM4 跳变族。
outer = runPam4Case([0 3], config);
inner = runPam4Case([1 2], config);

steadyStateBlock = config.NumBlocks - 15:config.NumBlocks;
assertPam4Convergence(outer, steadyStateBlock, config, 'outer 0<->3');
assertPam4Convergence(inner, steadyStateBlock, config, 'inner 1<->2');

blockAxis = 1:config.NumBlocks;
edgeOffsetUI = config.EdgeOffsetSamples / config.SamplesPerUI;
figurePath = fullfile(resultDir, ...
    'cdr_top_phase_convergence_pam4.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1100 950]);
t = tiledlayout(fig, 4, 1, ...
    'TileSpacing', 'compact', 'Padding', 'compact');
title(t, ['cdr\_top PAM4 ideal-edge convergence: outer and inner ' ...
    'cases, 4096 UI each']);

nexttile;
outerWaveformHandle = stairs(outer.WaveformTimeUI, ...
    outer.WaveformPlot, 'b-', 'LineWidth', 1.2);
hold on;
innerWaveformHandle = stairs(inner.WaveformTimeUI, ...
    inner.WaveformPlot, 'm--', 'LineWidth', 1.2);
for boundaryIndex = 0:4
    if boundaryIndex == 0
        nominalHandle = xline(boundaryIndex, ':', ...
            'Color', [0.45 0.45 0.45], 'LineWidth', 1.0);
        trueEdgeHandle = xline(boundaryIndex + edgeOffsetUI, ...
            'r--', 'LineWidth', 1.0);
    else
        xline(boundaryIndex, ':', ...
            'Color', [0.45 0.45 0.45], 'LineWidth', 1.0, ...
            'HandleVisibility', 'off');
        xline(boundaryIndex + edgeOffsetUI, ...
            'r--', 'LineWidth', 1.0, 'HandleVisibility', 'off');
    end
end
text(edgeOffsetUI + 0.05, -2.4, ...
    sprintf('%d samples = %.4f UI', ...
    config.EdgeOffsetSamples, edgeOffsetUI), ...
    'Color', [0.75 0 0], 'FontWeight', 'bold');
grid on;
xlim([0 4]);
ylim([-3.5 3.5]);
yticks([-3 -1 1 3]);
xlabel('Time from first nominal UI boundary (UI)');
ylabel('PAM4 level');
title(['Input zoom: first 4 of 4096 UI; each case has ' ...
    'one selected symmetric edge/UI']);
legend([outerWaveformHandle innerWaveformHandle ...
    nominalHandle trueEdgeHandle], ...
    {'outer 0<->3', 'inner 1<->2', 'nominal UI boundary', ...
    'true edge = nominal boundary + 24/128 UI'}, ...
    'Location', 'eastoutside');

nexttile;
plot(blockAxis, outer.SampleIndexForBlock, ...
    'b-o', 'LineWidth', 1.2, 'MarkerSize', 3);
hold on;
plot(blockAxis, inner.SampleIndexForBlock, ...
    'm--s', 'LineWidth', 1.2, 'MarkerSize', 3);
yline(config.EdgeOffsetSamples, 'r--', 'LineWidth', 1.2);
grid on;
ylabel('phase (sample)');
title('Outer and inner PAM4 phase convergence');
legend('outer 0<->3', 'inner 1<->2', 'true edge phase', ...
    'Location', 'best');

nexttile;
stairs(blockAxis, outer.PhaseErrorSamples, ...
    'b-', 'LineWidth', 1.2);
hold on;
stairs(blockAxis, inner.PhaseErrorSamples, ...
    'm--', 'LineWidth', 1.2);
yline(0, 'k--');
grid on;
ylabel('error (sample)');
title('Sampling-phase error');
legend('outer 0<->3', 'inner 1<->2', 'Location', 'best');

nexttile;
yyaxis left;
stairs(blockAxis, outer.PhaseError, ...
    'b-', 'LineWidth', 1.2);
hold on;
stairs(blockAxis, inner.PhaseError, ...
    'm--', 'LineWidth', 1.2);
ylabel('voter output');
yyaxis right;
stairs(blockAxis, outer.DeltaCode, ...
    'Color', [0.85 0.33 0.1], 'LineStyle', '-', 'LineWidth', 1.2);
stairs(blockAxis, inner.DeltaCode, ...
    'Color', [0.47 0.67 0.19], 'LineStyle', '--', 'LineWidth', 1.2);
ylabel('\Delta PI code');
grid on;
xlabel('64-UI block index');
title('PAM4 CDR control decisions');
legend('outer phaseError', 'inner phaseError', ...
    'outer deltaCode', 'inner deltaCode', 'Location', 'best');

exportgraphics(fig, figurePath, 'Resolution', 200);
close(fig);

result = struct();
result.SamplesPerUI = config.SamplesPerUI;
result.BlockSize = config.BlockSize;
result.NumBlocksPerCase = config.NumBlocks;
result.EdgeOffsetSamples = config.EdgeOffsetSamples;
result.Outer = outer;
result.Inner = inner;
result.FigurePath = figurePath;

fprintf('test_cdr_top_convergence_pam4 passed.\n');
fprintf('Outer steady-state phase range: %.3f to %.3f samples.\n', ...
    min(outer.SampleIndexForBlock(steadyStateBlock)), ...
    max(outer.SampleIndexForBlock(steadyStateBlock)));
fprintf('Inner steady-state phase range: %.3f to %.3f samples.\n', ...
    min(inner.SampleIndexForBlock(steadyStateBlock)), ...
    max(inner.SampleIndexForBlock(steadyStateBlock)));
fprintf('Saved PNG: %s\n', figurePath);
end

function caseResult = runPam4Case(symbolPair, config)
% runPam4Case  运行一种选定的对称 PAM4 跳变族。

numSymbols = config.BlockSize * config.NumBlocks;
pairIndex = mod(0:numSymbols, 2) + 1;
txSymbols = symbolPair(pairIndex);
pam4Levels = [-3 -1 1 3];
txLevels = pam4Levels(txSymbols + 1);

numWaveformSamples = (numSymbols + 1) * config.SamplesPerUI;
waveformSample = 0:numWaveformSamples - 1;
waveformSymbol = floor( ...
    (waveformSample - config.EdgeOffsetSamples) / ...
    config.SamplesPerUI) + 1;
waveformSymbol = min(max(waveformSymbol, 0), numSymbols);
waveform = txLevels(waveformSymbol + 1);

pd = cdr_pd('pam4', 1);
voter = cdr_voter('constant', config.BlockSize, 8);
loopFilter = cdr_loop(0.25, 0);
piModel = cdr_pi(8, config.SamplesPerUI);
piModel.resetNonideal();
top = cdr_top(pd, voter, loopFilter, piModel, txSymbols(1));

sampleIndexForBlock = zeros(1, config.NumBlocks);
nextLocalIndexFloat = zeros(1, config.NumBlocks);
phaseError = zeros(1, config.NumBlocks);
deltaCode = zeros(1, config.NumBlocks);
piCode = zeros(1, config.NumBlocks);
validCount = zeros(1, config.NumBlocks);

for blockIndex = 1:config.NumBlocks
    symbolIndex = (blockIndex - 1) * config.BlockSize + ...
        (1:config.BlockSize);
    localIndexInteger = round(top.CurrentLocalIndexFloat);
    edgeIndex = (symbolIndex - 1) * config.SamplesPerUI + ...
        localIndexInteger + 1;
    dataIndex = (symbolIndex - 1) * config.SamplesPerUI + ...
        config.SamplesPerUI / 2 + localIndexInteger + 1;

    dataCurrBlock = slicePam4(waveform(dataIndex));
    edgeBitBlock = waveform(edgeIndex) > 0;
    output = top.processBlock(dataCurrBlock, edgeBitBlock);

    sampleIndexForBlock(blockIndex) = output.SampleIndexForBlock;
    nextLocalIndexFloat(blockIndex) = output.NextLocalIndexFloat;
    phaseError(blockIndex) = double(output.PhaseError);
    deltaCode(blockIndex) = output.DeltaCode;
    piCode(blockIndex) = output.PiCodeWrapped;
    validCount(blockIndex) = sum(output.Valid);
end

plotIndex = waveformSample <= 4 * config.SamplesPerUI;
caseResult = struct();
caseResult.SymbolPair = symbolPair;
caseResult.WaveformTimeUI = ...
    waveformSample(plotIndex) / config.SamplesPerUI;
caseResult.WaveformPlot = waveform(plotIndex);
caseResult.SampleIndexForBlock = sampleIndexForBlock;
caseResult.NextLocalIndexFloat = nextLocalIndexFloat;
caseResult.PhaseErrorSamples = ...
    sampleIndexForBlock - config.EdgeOffsetSamples;
caseResult.PhaseError = phaseError;
caseResult.DeltaCode = deltaCode;
caseResult.PiCode = piCode;
caseResult.ValidCount = validCount;
end

function dataSymbol = slicePam4(sampleValue)
% slicePam4  在 -2、0 和 +2 处应用理想的 PAM4 判决门限。

dataSymbol = double(sampleValue > -2) + ...
    double(sampleValue > 0) + double(sampleValue > 2);
end

function assertPam4Convergence(caseResult, steadyStateBlock, config, name)
% assertPam4Convergence  检查一种 PAM4 跳变族的闭环。

assert(all(caseResult.ValidCount == config.BlockSize), ...
    '%s should provide one valid phase decision per UI.', name);
assert(any(caseResult.PhaseError > 0) && ...
    any(caseResult.PhaseError < 0), ...
    '%s should cross the true edge and reverse phase direction.', name);
assert(max(abs(caseResult.PhaseErrorSamples(steadyStateBlock))) <= 1, ...
    '%s steady-state phase should remain within one sample.', name);
end
