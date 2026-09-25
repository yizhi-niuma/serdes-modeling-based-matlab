function paths = plot_cdr_ffe_eyes(freezeEye, finalEye, config)
%PLOT_CDR_FFE_EYES Render fixed-tap CDR FFE eyes without phase recentering.
%   PATHS = PLOT_CDR_FFE_EYES(FREEZEEYE, FINALEYE, CONFIG) saves independent
%   freeze/final density images and a side-by-side comparison when
%   CONFIG.SaveOutputs is true. Invalid eye structs (Valid=false, Reason=...)
%   are rendered as explicit N/A placeholders rather than assigned data.
%
%   Eye phase is the physical cached-UI phase supplied by the builder. The
%   timing marker is overlaid at mod(code, SamplesPerUi)/SamplesPerUi and one
%   UI later; the density itself is never shifted around the marker.

validatePlotInputs(freezeEye, finalEye, config);
saveOutputs = logical(config.SaveOutputs);
paths = struct('Freeze', '', 'Final', '', 'Comparison', '');
if ~saveOutputs
    return;
end

resultDir = char(config.ResultDir);
if ~exist(resultDir, 'dir')
    [madeDirectory, message] = mkdir(resultDir);
    if ~madeDirectory
        error('plot_cdr_ffe_eyes:CannotCreateResultDir', ...
            'Could not create result directory "%s": %s', resultDir, message);
    end
end
uiCountRequested = double(config.UiCountRequested);
paths.Freeze = fullfile(resultDir, sprintf('cdr_ffe_eye_at_freeze_%dui.fig', uiCountRequested));
paths.Final = fullfile(resultDir, sprintf('cdr_ffe_eye_final_%dui.fig', uiCountRequested));
paths.Comparison = fullfile(resultDir, 'cdr_ffe_eye_freeze_vs_final.fig');

[sharedYLimits, sharedColorLimits] = sharedDensityLimits(freezeEye, finalEye);
metadataLabel = fixedFfeMetadata(freezeEye, finalEye, config);

freezeTitle = composeTitle('FFE eye at freeze', config.SelectedStartPhase, ...
    config.FreezeCenterCode, freezeEye, config.FreezeBlock, metadataLabel);
finalTitle = composeTitle('Final FFE eye', config.SelectedStartPhase, ...
    config.FinalLockCode, finalEye, config.FreezeBlock, metadataLabel);
footerText = 'Offline fixed-tap, ideal-ADC eye; overlapping 2-UI traces are not independent samples.';

figFreeze = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1200 750], ...
    'Name', 'CDR FFE eye at freeze');
axFreeze = axes('Parent', figFreeze, 'Position', [0.10 0.13 0.82 0.77]);
renderEye(axFreeze, freezeEye, config.FreezeCenterCode, sharedYLimits, sharedColorLimits, freezeTitle);
addFooter(figFreeze, footerText);
writeFigure(figFreeze, paths.Freeze);
close(figFreeze);

figFinal = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1200 750], ...
    'Name', 'Final CDR FFE eye');
axFinal = axes('Parent', figFinal, 'Position', [0.10 0.13 0.82 0.77]);
renderEye(axFinal, finalEye, config.FinalLockCode, sharedYLimits, sharedColorLimits, finalTitle);
addFooter(figFinal, footerText);
writeFigure(figFinal, paths.Final);
close(figFinal);

figComparison = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1200 1000], ...
    'Name', 'Freeze versus final CDR FFE eyes');
axComparisonFreeze = axes('Parent', figComparison, 'Position', [0.09 0.56 0.83 0.35]);
renderEye(axComparisonFreeze, freezeEye, config.FreezeCenterCode, sharedYLimits, sharedColorLimits, freezeTitle);
axComparisonFinal = axes('Parent', figComparison, 'Position', [0.09 0.12 0.83 0.35]);
renderEye(axComparisonFinal, finalEye, config.FinalLockCode, sharedYLimits, sharedColorLimits, finalTitle);
annotation(figComparison, 'textbox', [0.08 0.945 0.84 0.035], ...
    'String', 'CDR FFE eye: freeze versus final', 'EdgeColor', 'none', ...
    'HorizontalAlignment', 'center', 'FontSize', 13, 'FontWeight', 'bold');
addFooter(figComparison, footerText);
writeFigure(figComparison, paths.Comparison);
close(figComparison);
end

function renderEye(ax, eye, markerCode, sharedYLimits, sharedColorLimits, titleText)
set(ax, 'FontSize', 11);
if ~eye.Valid
    axis(ax, 'off');
    reason = eyeReason(eye);
    text(ax, 0.5, 0.56, 'N/A', 'Units', 'normalized', ...
        'HorizontalAlignment', 'center', 'FontSize', 24, 'FontWeight', 'bold');
    text(ax, 0.5, 0.46, reason, 'Units', 'normalized', ...
        'HorizontalAlignment', 'center', 'FontSize', 11, 'Interpreter', 'none');
    title(ax, titleText, 'FontSize', 12, 'Interpreter', 'none');
    return;
end

phaseUi = double(eye.PhaseUi(:).');
codeCenters = double(eye.CodeBinCenters(:));
densityImage = log10(1 + double(eye.Density));
imagesc(ax, phaseUi, codeCenters, densityImage);
set(ax, 'YDir', 'normal', 'FontSize', 11, 'Color', 'w');
colormap(ax, parula(256));
clim(ax, sharedColorLimits);
xlim(ax, [0 2]);
ylim(ax, sharedYLimits);
grid(ax, 'on');
box(ax, 'on');
xlabel(ax, 'Cached waveform phase (UI)');
ylabel(ax, 'FFE output code');
title(ax, titleText, 'FontSize', 12, 'Interpreter', 'none');
colorbar(ax);
hold(ax, 'on');
if isFiniteScalar(markerCode)
    markerPhase = mod(double(markerCode), double(eye.SamplesPerUi)) / double(eye.SamplesPerUi);
    markerColor = [0.86 0.16 0.12];
    plot(ax, [markerPhase markerPhase], sharedYLimits, '--', ...
        'Color', markerColor, 'LineWidth', 1.5);
    plot(ax, [markerPhase + 1 markerPhase + 1], sharedYLimits, '--', ...
        'Color', markerColor, 'LineWidth', 1.5);
    markerLabel = sprintf('marker %.4g UI (+1 UI)', markerPhase);
    text(ax, markerPhase, sharedYLimits(2), ['  ' markerLabel], ...
        'Color', markerColor, 'FontSize', 10, 'VerticalAlignment', 'top', ...
        'Interpreter', 'none');
end
hold(ax, 'off');
end

function [yLimits, colorLimits] = sharedDensityLimits(freezeEye, finalEye)
validEyes = {};
if freezeEye.Valid
    validEyes{end + 1} = freezeEye;
end
if finalEye.Valid
    validEyes{end + 1} = finalEye;
end
if isempty(validEyes)
    yLimits = [-1 1];
    colorLimits = [0 1];
    return;
end
minimumEdge = inf;
maximumEdge = -inf;
maximumLogDensity = 0;
for eyeIndex = 1:numel(validEyes)
    currentEye = validEyes{eyeIndex};
    currentEdges = double(currentEye.CodeBinEdges(:));
    minimumEdge = min(minimumEdge, min(currentEdges));
    maximumEdge = max(maximumEdge, max(currentEdges));
    maximumLogDensity = max(maximumLogDensity, max(log10(1 + double(currentEye.Density(:)))));
end
if minimumEdge == maximumEdge
    minimumEdge = minimumEdge - 0.25;
    maximumEdge = maximumEdge + 0.25;
end
yLimits = [minimumEdge maximumEdge];
colorLimits = [0 max(1, maximumLogDensity)];
end

function titleText = composeTitle(prefix, selectedStartPhase, markerCode, eye, freezeBlock, metadataLabel)
selectedText = scalarText(selectedStartPhase);
markerText = scalarText(markerCode);
freezeBlockText = scalarText(freezeBlock);
if eye.Valid && isfield(eye, 'UiCountUsed')
    uiText = sprintf('%g UI used', double(eye.UiCountUsed));
else
    uiText = 'UI used N/A';
end
if isFiniteScalar(markerCode)
    markerClause = ['marker code ' markerText];
else
    markerClause = 'marker N/A';
end
titleText = sprintf('%s | selected initial phase %s | %s | %s | freeze block %s | %s', ...
    prefix, selectedText, markerClause, uiText, freezeBlockText, metadataLabel);
end

function label = fixedFfeMetadata(freezeEye, finalEye, config)
label = '';
optionalFields = {'FixedFfeLabel', 'FfeLabel', 'Label'};
for fieldIndex = 1:numel(optionalFields)
    currentField = optionalFields{fieldIndex};
    if isfield(config, currentField) && isTextScalar(config.(currentField))
        label = char(config.(currentField));
        break;
    end
end
if isempty(label)
    if freezeEye.Valid && isfield(freezeEye, 'Coefficients')
        label = ['fixed FFE ' mat2str(double(freezeEye.Coefficients), 4)];
    elseif finalEye.Valid && isfield(finalEye, 'Coefficients')
        label = ['fixed FFE ' mat2str(double(finalEye.Coefficients), 4)];
    else
        label = 'fixed FFE metadata N/A';
    end
end
end

function addFooter(fig, footerText)
annotation(fig, 'textbox', [0.04 0.015 0.92 0.04], 'String', footerText, ...
    'EdgeColor', 'none', 'HorizontalAlignment', 'center', 'FontSize', 10, ...
    'Color', [0.30 0.30 0.30], 'Interpreter', 'none');
end

function writeFigure(fig, filePath)
set(fig, 'Visible', 'on');
try
    savefig(fig, filePath);
catch
    pause(0.5);
    savefig(fig, filePath);
end
end

function reason = eyeReason(eye)
reason = 'Eye data unavailable.';
if isfield(eye, 'Reason') && isTextScalar(eye.Reason) && ~isempty(char(eye.Reason))
    reason = char(eye.Reason);
end
end

function textValue = scalarText(value)
if isFiniteScalar(value)
    textValue = sprintf('%.6g', double(value));
else
    textValue = 'N/A';
end
end

function validatePlotInputs(freezeEye, finalEye, config)
validateEye(freezeEye, 'freezeEye');
validateEye(finalEye, 'finalEye');
if ~isstruct(config) || ~isscalar(config)
    error('plot_cdr_ffe_eyes:InvalidConfig', 'config must be a scalar struct.');
end
requiredFields = {'ResultDir', 'SelectedStartPhase', 'FreezeBlock', ...
    'FreezeCenterCode', 'FinalLockCode', 'UiCountRequested', 'SaveOutputs'};
for fieldIndex = 1:numel(requiredFields)
    if ~isfield(config, requiredFields{fieldIndex})
        error('plot_cdr_ffe_eyes:MissingConfigField', ...
            'config.%s is required.', requiredFields{fieldIndex});
    end
end
if ~isTextScalar(config.ResultDir)
    error('plot_cdr_ffe_eyes:InvalidResultDir', 'config.ResultDir must be a character vector or string scalar.');
end
if ~(islogical(config.SaveOutputs) && isscalar(config.SaveOutputs)) && ...
        ~(isnumeric(config.SaveOutputs) && isreal(config.SaveOutputs) && isscalar(config.SaveOutputs) && ...
        isfinite(config.SaveOutputs) && any(double(config.SaveOutputs) == [0 1]))
    error('plot_cdr_ffe_eyes:InvalidSaveOutputs', 'config.SaveOutputs must be a logical scalar or numeric 0/1.');
end
if ~isIntegerScalarAtLeast(config.UiCountRequested, 2)
    error('plot_cdr_ffe_eyes:InvalidUiCountRequested', ...
        'config.UiCountRequested must be an integer scalar greater than or equal to 2.');
end
validateFiniteOrNanScalar(config.SelectedStartPhase, 'SelectedStartPhase');
validateFiniteOrNanScalar(config.FreezeBlock, 'FreezeBlock');
validateFiniteOrNanScalar(config.FreezeCenterCode, 'FreezeCenterCode');
validateFiniteOrNanScalar(config.FinalLockCode, 'FinalLockCode');
end

function validateEye(eye, name)
if ~isstruct(eye) || ~isscalar(eye) || ~isfield(eye, 'Valid') || ...
        ~(islogical(eye.Valid) || isnumeric(eye.Valid)) || ~isscalar(eye.Valid) || ...
        ~isfinite(double(eye.Valid)) || ~any(double(eye.Valid) == [0 1])
    error('plot_cdr_ffe_eyes:InvalidEye', '%s must be a scalar struct with scalar logical Valid.', name);
end
if ~logical(eye.Valid)
    if isfield(eye, 'Reason') && ~isTextScalar(eye.Reason)
        error('plot_cdr_ffe_eyes:InvalidEyeReason', '%s.Reason must be text when present.', name);
    end
    return;
end
requiredFields = {'Density', 'PhaseUi', 'CodeBinCenters', 'CodeBinEdges', 'SamplesPerUi', 'UiCountUsed'};
for fieldIndex = 1:numel(requiredFields)
    if ~isfield(eye, requiredFields{fieldIndex})
        error('plot_cdr_ffe_eyes:InvalidEye', '%s.%s is required for a valid eye.', name, requiredFields{fieldIndex});
    end
end
if ~isnumeric(eye.Density) || ~isreal(eye.Density) || isempty(eye.Density) || ...
        any(~isfinite(eye.Density(:))) || any(eye.Density(:) < 0)
    error('plot_cdr_ffe_eyes:InvalidDensity', '%s.Density must be a nonnegative finite real numeric matrix.', name);
end
if ~isnumeric(eye.PhaseUi) || ~isvector(eye.PhaseUi) || any(~isfinite(eye.PhaseUi(:))) || ...
        numel(eye.PhaseUi) ~= size(eye.Density, 2)
    error('plot_cdr_ffe_eyes:InvalidPhaseUi', '%s.PhaseUi must match the Density columns.', name);
end
if ~isnumeric(eye.CodeBinCenters) || ~isvector(eye.CodeBinCenters) || any(~isfinite(eye.CodeBinCenters(:))) || ...
        numel(eye.CodeBinCenters) ~= size(eye.Density, 1)
    error('plot_cdr_ffe_eyes:InvalidCodeBins', '%s.CodeBinCenters must match the Density rows.', name);
end
if ~isnumeric(eye.CodeBinEdges) || ~isvector(eye.CodeBinEdges) || ...
        numel(eye.CodeBinEdges) ~= numel(eye.CodeBinCenters) + 1 || any(~isfinite(eye.CodeBinEdges(:)))
    error('plot_cdr_ffe_eyes:InvalidCodeBins', '%s.CodeBinEdges must bracket CodeBinCenters.', name);
end
if ~isIntegerScalarAtLeast(eye.SamplesPerUi, 1) || numel(eye.PhaseUi) ~= 2 * double(eye.SamplesPerUi)
    error('plot_cdr_ffe_eyes:InvalidSamplesPerUi', '%s.SamplesPerUi is inconsistent with PhaseUi.', name);
end
end

function validateFiniteOrNanScalar(value, name)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~(isfinite(value) || isnan(value))
    error('plot_cdr_ffe_eyes:InvalidConfigScalar', 'config.%s must be a finite real scalar or NaN.', name);
end
end

function tf = isFiniteScalar(value)
tf = isnumeric(value) && isreal(value) && isscalar(value) && isfinite(value);
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
