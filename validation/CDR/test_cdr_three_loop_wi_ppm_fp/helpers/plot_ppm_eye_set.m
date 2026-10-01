function paths = plot_ppm_eye_set(eyes, config)
%PLOT_PPM_EYE_SET Render a set of fixed-tap frequency-offset eyes.
%   PATHS = PLOT_PPM_EYE_SET(EYES, CONFIG) saves one standalone density
%   figure for each eye and a stacked stage-comparison figure when
%   CONFIG.SaveOutputs is true. Invalid eye structs are rendered as explicit
%   N/A placeholders rather than being represented by assigned data.
%
%   All valid rows share code and density limits. The timing marker is the
%   tracked, unwrapped PI code plus drift, wrapped to one UI. A nonzero
%   marker span is shown with independent dotted boundary lines.

validatePlotInputs(eyes, config);
eyeCount = numel(eyes);
paths = struct('Standalone', {cell(1, eyeCount)}, 'Combined', '');
if ~config.SaveOutputs
    return;
end

resultDir = char(config.ResultDir);
ensureResultDirectory(resultDir);
rowSlugs = normalizedRowSlugs(config.RowSlugs);
uiCountRequested = double(config.UiCountRequested);
for eyeIndex = 1:eyeCount
    paths.Standalone{eyeIndex} = fullfile(resultDir, sprintf( ...
        'cdr_ffe_eye_%s_%dui.fig', rowSlugs{eyeIndex}, uiCountRequested));
end
paths.Combined = fullfile(resultDir, 'cdr_ffe_eye_stage_comparison.fig');

[sharedYLimits, sharedColorLimits] = sharedDensityLimits(eyes);
titleTexts = cell(1, eyeCount);
for eyeIndex = 1:eyeCount
    metadataLabel = fixedFfeMetadata(eyes(eyeIndex), config);
    titleTexts{eyeIndex} = composeTitle(eyes(eyeIndex), config, metadataLabel);
end
footerText = ['Offline fixed-tap, ideal-ADC eyes rebuilt from the saved per-block coefficient and drift traces; ', ...
    'overlapping 2-UI traces are not independent samples. Marker is the tracked eye phase ', ...
    '(unwrapped PI code + drift) wrapped to one UI.'];
contextText = sprintf(['ppm %+g | start phase %g | expected freq state %s code/block | ', ...
    'measured %s | %s'], double(config.FreqOffsetPpm), ...
    double(config.SelectedStartPhase), ...
    optionalScalarText(config, 'ExpectedFreqStateCodePerBlock'), ...
    optionalScalarText(config, 'MeasuredFreqStateCodePerBlock'), stage2Text(config));

for eyeIndex = 1:eyeCount
    figureName = sprintf('CDR FFE eye: %s', anchorLabel(eyes(eyeIndex)));
    writeStandalone(eyes(eyeIndex), sharedYLimits, sharedColorLimits, ...
        titleTexts{eyeIndex}, footerText, paths.Standalone{eyeIndex}, figureName);
end
writeComparison(eyes, sharedYLimits, sharedColorLimits, titleTexts, ...
    contextText, footerText, paths.Combined);
end

function ensureResultDirectory(resultDir)
if exist(resultDir, 'dir')
    return;
end
try
    [madeDirectory, message] = mkdir(resultDir);
catch caughtException
    error('plot_ppm_eye_set:CannotCreateResultDir', ...
        'Could not create result directory "%s": %s', resultDir, caughtException.message);
end
if ~madeDirectory
    error('plot_ppm_eye_set:CannotCreateResultDir', ...
        'Could not create result directory "%s": %s', resultDir, message);
end
end

function writeStandalone(eyeData, sharedYLimits, sharedColorLimits, titleText, ...
        footerText, filePath, figureName)
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1200 750], ...
    'Name', figureName);
try
    ax = axes('Parent', fig, 'Position', [0.10 0.135 0.82 0.725]);
    renderEye(ax, eyeData, sharedYLimits, sharedColorLimits, titleText);
    addFooter(fig, footerText, [0.04 0.015 0.92 0.04]);
    writeFigure(fig, filePath);
catch caughtException
    close(fig);
    rethrow(caughtException);
end
close(fig);
end

function writeComparison(eyes, sharedYLimits, sharedColorLimits, titleTexts, ...
        contextText, footerText, filePath)
eyeCount = numel(eyes);
topBand = 0.944;
bottomBand = 0.060;
titleSpace = 0.050;
xlabelSpace = 0.045;
slot = (topBand - bottomBand) / eyeCount;
axHeight = slot - titleSpace - xlabelSpace;
if axHeight <= 0.05
    error('plot_ppm_eye_set:TooManyRows', ...
        'The requested eye count leaves insufficient height for each row.');
end

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [80 40 1500 1500], ...
    'Name', 'CDR FFE eye stage comparison');
try
    for eyeIndex = 1:eyeCount
        axBottom = topBand - eyeIndex * slot + xlabelSpace;
        ax = axes('Parent', fig, 'Position', [0.09 axBottom 0.83 axHeight]);
        renderEye(ax, eyes(eyeIndex), sharedYLimits, sharedColorLimits, ...
            titleTexts{eyeIndex});
    end
    annotation(fig, 'textbox', [0.06 0.968 0.88 0.024], ...
        'String', 'CDR FFE eye: stage comparison', 'EdgeColor', 'none', ...
        'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
        'FontSize', 14, 'FontWeight', 'bold', 'Interpreter', 'none');
    annotation(fig, 'textbox', [0.04 0.944 0.92 0.020], ...
        'String', contextText, 'EdgeColor', 'none', ...
        'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
        'FontSize', 9, 'Interpreter', 'none');
    addFooter(fig, footerText, [0.04 0.015 0.92 0.035]);
    writeFigure(fig, filePath);
catch caughtException
    close(fig);
    rethrow(caughtException);
end
close(fig);
end

function renderEye(ax, eyeData, sharedYLimits, sharedColorLimits, titleText)
set(ax, 'FontSize', 11);
if ~logical(eyeData.Valid)
    axis(ax, 'off');
    text(ax, 0.5, 0.56, 'N/A', 'Units', 'normalized', ...
        'HorizontalAlignment', 'center', 'FontSize', 24, 'FontWeight', 'bold', ...
        'Interpreter', 'none');
    text(ax, 0.5, 0.46, eyeReason(eyeData), 'Units', 'normalized', ...
        'HorizontalAlignment', 'center', 'FontSize', 11, 'Interpreter', 'none');
    title(ax, titleText, 'FontSize', 11, 'Interpreter', 'none');
    return;
end

phaseUi = double(eyeData.PhaseUi(:).');
codeCenters = double(eyeData.CodeBinCenters(:));
density = double(eyeData.Density);
imagesc(ax, phaseUi, codeCenters, log10(1 + density));
set(ax, 'YDir', 'normal', 'FontSize', 11, 'Color', 'w');
colormap(ax, parula(256));
clim(ax, sharedColorLimits);
xlim(ax, [0 2]);
ylim(ax, sharedYLimits);
grid(ax, 'on');
box(ax, 'on');
xlabel(ax, 'Cached waveform phase (UI)', 'Interpreter', 'none');
ylabel(ax, 'FFE output code', 'Interpreter', 'none');
title(ax, titleText, 'FontSize', 11, 'Interpreter', 'none');
colorbar(ax);
hold(ax, 'on');
samplesPerUi = double(eyeData.SamplesPerUi);
markerColor = [0.86 0.16 0.12];
markerPhase = mod(double(eyeData.MarkerCode), samplesPerUi) / samplesPerUi;
plotMarkerPair(ax, markerPhase, sharedYLimits, '--', markerColor, 1.5);
if double(eyeData.MarkerSpanCode) > 0
    markerMinimumPhase = mod(double(eyeData.MarkerMinCode), samplesPerUi) / samplesPerUi;
    markerMaximumPhase = mod(double(eyeData.MarkerMaxCode), samplesPerUi) / samplesPerUi;
    % Independent boundaries keep a span that wraps at one UI unambiguous.
    plotMarkerPair(ax, markerMinimumPhase, sharedYLimits, ':', markerColor, 0.8);
    plotMarkerPair(ax, markerMaximumPhase, sharedYLimits, ':', markerColor, 0.8);
end
markerLabel = sprintf('marker %.4g UI (+1 UI)', markerPhase);
text(ax, markerPhase, sharedYLimits(2), ['  ' markerLabel], ...
    'Color', markerColor, 'FontSize', 10, 'VerticalAlignment', 'top', ...
    'Interpreter', 'none');
hold(ax, 'off');
end

function plotMarkerPair(ax, markerPhase, sharedYLimits, lineStyle, markerColor, lineWidth)
plot(ax, [markerPhase markerPhase], sharedYLimits, lineStyle, ...
    'Color', markerColor, 'LineWidth', lineWidth);
plot(ax, [markerPhase + 1 markerPhase + 1], sharedYLimits, lineStyle, ...
    'Color', markerColor, 'LineWidth', lineWidth);
end

function [yLimits, colorLimits] = sharedDensityLimits(eyes)
validMask = false(1, numel(eyes));
for eyeIndex = 1:numel(eyes)
    validMask(eyeIndex) = logical(eyes(eyeIndex).Valid);
end
if ~any(validMask)
    yLimits = [-1 1];
    colorLimits = [0 1];
    return;
end

minimumEdge = inf;
maximumEdge = -inf;
maximumLogDensity = 0;
validIndices = find(validMask);
for validIndex = 1:numel(validIndices)
    currentEye = eyes(validIndices(validIndex));
    currentEdges = double(currentEye.CodeBinEdges(:));
    minimumEdge = min(minimumEdge, min(currentEdges));
    maximumEdge = max(maximumEdge, max(currentEdges));
    maximumLogDensity = max(maximumLogDensity, ...
        max(log10(1 + double(currentEye.Density(:)))));
end
if minimumEdge == maximumEdge
    minimumEdge = minimumEdge - 0.25;
    maximumEdge = maximumEdge + 0.25;
end
yLimits = [minimumEdge maximumEdge];
colorLimits = [0 max(1, maximumLogDensity)];
end

function titleText = composeTitle(eyeData, config, metadataLabel)
identityText = sprintf('%s | ppm %+g | start phase %g | block %s', ...
    anchorLabel(eyeData), double(config.FreqOffsetPpm), ...
    double(config.SelectedStartPhase), anchorBlockText(eyeData));
if ~logical(eyeData.Valid)
    titleText = {[identityText ' | blocks N/A']; 'eye unavailable'};
    return;
end
markerBlocks = double(eyeData.MarkerBlocks(:));
titleText = {[identityText sprintf(' | blocks %g-%g', ...
    markerBlocks(1), markerBlocks(2))]; ...
    sprintf('marker %.2f code (span %g) | %g UI used | %s', ...
    double(eyeData.MarkerCode), double(eyeData.MarkerSpanCode), ...
    double(eyeData.UiCountUsed), metadataLabel)};
end

function label = fixedFfeMetadata(eyeData, config)
if isfield(config, 'FfeLabel') && ~isempty(config.FfeLabel)
    if isTextScalar(config.FfeLabel)
        label = char(config.FfeLabel);
    else
        label = 'fixed FFE metadata N/A';
    end
elseif logical(eyeData.Valid) && isfield(eyeData, 'Coefficients') && ...
        isnumeric(eyeData.Coefficients) && isreal(eyeData.Coefficients) && ...
        isvector(eyeData.Coefficients) && ~isempty(eyeData.Coefficients) && ...
        all(isfinite(eyeData.Coefficients(:)))
    label = ['fixed FFE ' mat2str(double(eyeData.Coefficients), 3)];
else
    label = 'fixed FFE metadata N/A';
end
end

function label = anchorLabel(eyeData)
label = 'FFE eye';
if isfield(eyeData, 'AnchorLabel') && isTextScalar(eyeData.AnchorLabel) && ...
        ~isempty(char(eyeData.AnchorLabel))
    label = char(eyeData.AnchorLabel);
end
end

function textValue = anchorBlockText(eyeData)
textValue = 'final';
if isfield(eyeData, 'AnchorBlock') && isFiniteScalar(eyeData.AnchorBlock)
    textValue = sprintf('%g', double(eyeData.AnchorBlock));
end
end

function addFooter(fig, footerText, position)
annotation(fig, 'textbox', position, 'String', footerText, ...
    'EdgeColor', 'none', 'HorizontalAlignment', 'center', ...
    'VerticalAlignment', 'middle', 'FontSize', 10, ...
    'Color', [0.30 0.30 0.30], 'Interpreter', 'none');
end

function writeFigure(fig, filePath)
try
    set(fig, 'Visible', 'on');
    savefig(fig, filePath);
catch
    pause(0.5);
    set(fig, 'Visible', 'on');
    savefig(fig, filePath);
end
end

function reason = eyeReason(eyeData)
reason = 'Eye data unavailable.';
if isfield(eyeData, 'Reason') && isTextScalar(eyeData.Reason) && ...
        ~isempty(char(eyeData.Reason))
    reason = char(eyeData.Reason);
end
end

function textValue = optionalScalarText(config, fieldName)
textValue = 'N/A';
if isfield(config, fieldName)
    textValue = scalarText(config.(fieldName));
end
end

function textValue = scalarText(value)
if isFiniteScalar(value)
    textValue = sprintf('%.6g', double(value));
else
    textValue = 'N/A';
end
end

function textValue = stage2Text(config)
textValue = 'stage-2 downshift status N/A';
if isfield(config, 'Stage2Note') && isTextScalar(config.Stage2Note) && ...
        ~isempty(char(config.Stage2Note))
    textValue = char(config.Stage2Note);
end
end

function rowSlugs = normalizedRowSlugs(values)
if iscell(values)
    rowSlugs = values;
else
    rowSlugs = cellstr(values(:).');
end
for slugIndex = 1:numel(rowSlugs)
    rowSlugs{slugIndex} = char(rowSlugs{slugIndex});
end
rowSlugs = reshape(rowSlugs, 1, []);
end

function validatePlotInputs(eyes, config)
if ~isstruct(eyes) || ~isrow(eyes) || numel(eyes) < 2
    error('plot_ppm_eye_set:InvalidEyes', ...
        'eyes must be a 1-by-M struct array with M greater than or equal to 2.');
end
for eyeIndex = 1:numel(eyes)
    validateEye(eyes(eyeIndex), sprintf('eyes(%d)', eyeIndex));
end
if ~isstruct(config) || ~isscalar(config)
    error('plot_ppm_eye_set:InvalidConfig', 'config must be a scalar struct.');
end
requiredFields = {'ResultDir', 'SaveOutputs', 'UiCountRequested', ...
    'FreqOffsetPpm', 'SelectedStartPhase', 'NumBlocks', 'RowSlugs'};
for fieldIndex = 1:numel(requiredFields)
    if ~isfield(config, requiredFields{fieldIndex})
        error('plot_ppm_eye_set:MissingConfigField', ...
            'config.%s is required.', requiredFields{fieldIndex});
    end
end
if ~isTextScalar(config.ResultDir)
    error('plot_ppm_eye_set:InvalidConfigField', ...
        'config.ResultDir must be a character vector or string scalar.');
end
if ~islogical(config.SaveOutputs) || ~isscalar(config.SaveOutputs)
    error('plot_ppm_eye_set:InvalidConfigField', ...
        'config.SaveOutputs must be a logical scalar.');
end
if ~isIntegerScalarAtLeast(config.UiCountRequested, 2)
    error('plot_ppm_eye_set:InvalidConfigField', ...
        'config.UiCountRequested must be an integer scalar at least 2.');
end
if ~isFiniteScalar(config.FreqOffsetPpm)
    error('plot_ppm_eye_set:InvalidConfigField', ...
        'config.FreqOffsetPpm must be a finite real numeric scalar.');
end
if ~isFiniteScalar(config.SelectedStartPhase)
    error('plot_ppm_eye_set:InvalidConfigField', ...
        'config.SelectedStartPhase must be a finite real numeric scalar.');
end
if ~isIntegerScalarAtLeast(config.NumBlocks, 1)
    error('plot_ppm_eye_set:InvalidConfigField', ...
        'config.NumBlocks must be an integer scalar at least 1.');
end
validateRowSlugs(config.RowSlugs, numel(eyes));
end

function validateRowSlugs(values, eyeCount)
validContainer = iscell(values);
if ~validContainer && exist('isstring', 'builtin')
    validContainer = isstring(values);
end
if ~validContainer || numel(values) ~= eyeCount
    error('plot_ppm_eye_set:InvalidConfigField', ...
        'config.RowSlugs must contain one filename-safe text value per eye.');
end
for slugIndex = 1:numel(values)
    if iscell(values)
        slug = values{slugIndex};
    else
        slug = values(slugIndex);
    end
    if ~isTextScalar(slug) || isempty(char(slug)) || ...
            isempty(regexp(char(slug), '^[A-Za-z0-9][A-Za-z0-9_-]*$', 'once'))
        error('plot_ppm_eye_set:InvalidConfigField', ...
            'config.RowSlugs must contain filename-safe short tags.');
    end
end
end

function validateEye(eyeData, name)
if ~isfield(eyeData, 'Valid') || ...
        ~(islogical(eyeData.Valid) || isnumeric(eyeData.Valid)) || ...
        ~isscalar(eyeData.Valid) || ~isreal(eyeData.Valid) || ...
        ~isfinite(double(eyeData.Valid)) || ~any(double(eyeData.Valid) == [0 1])
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s must have a scalar logical Valid field.', name);
end
if ~logical(eyeData.Valid)
    if isfield(eyeData, 'Reason') && ~isTextScalar(eyeData.Reason)
        error('plot_ppm_eye_set:InvalidEye', ...
            '%s.Reason must be text when present.', name);
    end
    return;
end
requiredFields = {'Density', 'PhaseUi', 'CodeBinCenters', 'CodeBinEdges', ...
    'SamplesPerUi', 'UiCountUsed', 'MarkerCode', 'MarkerMinCode', ...
    'MarkerMaxCode', 'MarkerSpanCode', 'MarkerBlocks'};
for fieldIndex = 1:numel(requiredFields)
    if ~isfield(eyeData, requiredFields{fieldIndex})
        error('plot_ppm_eye_set:InvalidEye', ...
            '%s.%s is required for a valid eye.', name, requiredFields{fieldIndex});
    end
end
if ~isnumeric(eyeData.Density) || ~isreal(eyeData.Density) || ...
        ~ismatrix(eyeData.Density) || isempty(eyeData.Density) || ...
        any(~isfinite(eyeData.Density(:))) || any(eyeData.Density(:) < 0)
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s.Density must be a nonnegative finite real numeric matrix.', name);
end
if ~isnumeric(eyeData.PhaseUi) || ~isreal(eyeData.PhaseUi) || ...
        ~isvector(eyeData.PhaseUi) || any(~isfinite(eyeData.PhaseUi(:))) || ...
        numel(eyeData.PhaseUi) ~= size(eyeData.Density, 2)
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s.PhaseUi must match the Density columns.', name);
end
if ~isnumeric(eyeData.CodeBinCenters) || ~isreal(eyeData.CodeBinCenters) || ...
        ~isvector(eyeData.CodeBinCenters) || ...
        any(~isfinite(eyeData.CodeBinCenters(:))) || ...
        numel(eyeData.CodeBinCenters) ~= size(eyeData.Density, 1)
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s.CodeBinCenters must match the Density rows.', name);
end
if ~isnumeric(eyeData.CodeBinEdges) || ~isreal(eyeData.CodeBinEdges) || ...
        ~isvector(eyeData.CodeBinEdges) || ...
        numel(eyeData.CodeBinEdges) ~= numel(eyeData.CodeBinCenters) + 1 || ...
        any(~isfinite(eyeData.CodeBinEdges(:)))
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s.CodeBinEdges must bracket CodeBinCenters.', name);
end
if ~isIntegerScalarAtLeast(eyeData.SamplesPerUi, 1) || ...
        numel(eyeData.PhaseUi) ~= 2 * double(eyeData.SamplesPerUi)
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s.SamplesPerUi is inconsistent with PhaseUi.', name);
end
if ~isIntegerScalarAtLeast(eyeData.UiCountUsed, 2)
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s.UiCountUsed must be an integer scalar at least 2.', name);
end
finiteScalarFields = {'MarkerCode', 'MarkerMinCode', 'MarkerMaxCode', 'MarkerSpanCode'};
for fieldIndex = 1:numel(finiteScalarFields)
    fieldName = finiteScalarFields{fieldIndex};
    if ~isFiniteScalar(eyeData.(fieldName))
        error('plot_ppm_eye_set:InvalidEye', ...
            '%s.%s must be a finite real numeric scalar.', name, fieldName);
    end
end
if double(eyeData.MarkerSpanCode) < 0
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s.MarkerSpanCode must be nonnegative.', name);
end
if ~isnumeric(eyeData.MarkerBlocks) || ~isreal(eyeData.MarkerBlocks) || ...
        ~isvector(eyeData.MarkerBlocks) || numel(eyeData.MarkerBlocks) ~= 2 || ...
        any(~isfinite(eyeData.MarkerBlocks(:))) || ...
        any(double(eyeData.MarkerBlocks(:)) ~= fix(double(eyeData.MarkerBlocks(:)))) || ...
        any(double(eyeData.MarkerBlocks(:)) < 1) || ...
        eyeData.MarkerBlocks(2) < eyeData.MarkerBlocks(1)
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s.MarkerBlocks must be an increasing pair of positive integers.', name);
end
if isfield(eyeData, 'Coefficients') && ~isempty(eyeData.Coefficients) && ...
        (~isnumeric(eyeData.Coefficients) || ~isreal(eyeData.Coefficients) || ...
        ~isvector(eyeData.Coefficients) || any(~isfinite(eyeData.Coefficients(:))))
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s.Coefficients must be a finite real numeric vector when present.', name);
end
if isfield(eyeData, 'AnchorLabel') && ~isTextScalar(eyeData.AnchorLabel)
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s.AnchorLabel must be text when present.', name);
end
if isfield(eyeData, 'AnchorBlock') && ~isFiniteOrNanScalar(eyeData.AnchorBlock)
    error('plot_ppm_eye_set:InvalidEye', ...
        '%s.AnchorBlock must be a finite real scalar or NaN when present.', name);
end
end

function tf = isFiniteScalar(value)
tf = isnumeric(value) && isreal(value) && isscalar(value) && isfinite(value);
end

function tf = isFiniteOrNanScalar(value)
tf = isnumeric(value) && isreal(value) && isscalar(value) && ...
    (isfinite(value) || isnan(value));
end

function tf = isIntegerScalarAtLeast(value, minimumValue)
tf = isnumeric(value) && isreal(value) && isscalar(value) && isfinite(value) && ...
    double(value) == fix(double(value)) && double(value) >= minimumValue;
end

function tf = isTextScalar(value)
tf = ischar(value) && (isrow(value) || isempty(value));
if ~tf && exist('isstring', 'builtin')
    tf = isstring(value) && isscalar(value);
end
end
