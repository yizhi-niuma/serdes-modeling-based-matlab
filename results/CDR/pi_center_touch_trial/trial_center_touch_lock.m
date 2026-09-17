function trial = trial_center_touch_lock(resultMatPath, outputDir)
%TRIAL_CENTER_TOUCH_LOCK Diagnose a saved PRBS22 result without changing it.
% An event is an in-band arrival from a noncenter code to center, or a
% strict crossing that skips center. Center dwell and departure are not events.
% Every out-of-band sample resets the retained count and forgets continuity.
% Synthetic checks are deliberately run before loading the saved result.
a = evaluate([11 12 11], 12, 3, 51); assert(a.counts == 1 && sum(a.eventmask) == 1);
a = evaluate([11 12 13], 12, 3, 51); assert(a.counts == 1 && sum(a.eventmask) == 1);
a = evaluate([11 12 12 13], 12, 3, 51); assert(a.counts == 1 && sum(a.eventmask) == 1);
a = evaluate([11 13], 12, 3, 51); assert(a.counts == 1 && sum(a.eventmask) == 1);
a = evaluate([12 12 12], 12, 3, 51); assert(a.counts == 0 && ~any(a.eventmask));
a = evaluate([11 12 11 12 13], 12, 3, 51); assert(a.counts == 2 && sum(a.eventmask) == 2);
a = evaluate([11 12 16 12 11 12], 12, 3, 51);
assert(a.counts == 1 && sum(a.eventmask) == 2 && sum(a.resetmask) == 1);
a = evaluate([9 12 15 12 9], 12, 3, 51);
assert(a.counts == 2 && sum(a.eventmask) == 2 && ~any(a.resetmask));
a = evaluate([11 12 8 11 12], 12, 3, 51);
assert(a.counts == 1 && sum(a.eventmask) == 2 && sum(a.resetmask) == 1);
a50 = evaluate([11 repmat([12 11], 1, 50)], 12, 3, 51);
a51 = evaluate([11 repmat([12 11], 1, 51)], 12, 3, 51);
assert(a50.counts == 50 && ~a50.locked && isnan(a50.onset));
assert(a51.counts == 51 && a51.locked && a51.onset == 102);
a = evaluate([-117 -116 -117], -116, 3, 51);
assert(a.counts == 1 && sum(a.eventmask) == 1);
fprintf('Synthetic center-touch checks pass.\n');
narginchk(1, 2);
if nargin < 2 || isempty(outputDir), outputDir = fileparts(mfilename('fullpath')); end
if ~isfolder(outputDir), mkdir(outputDir); end
loaded = load(resultMatPath);
assert(isfield(loaded, 'result'), 'MAT file must contain field result.');
R = loaded.result;
assert(isstruct(R) && ~isempty(R), 'result must be a nonempty struct.');
if numel(R) > 1
    assert(all(arrayfun(@(z) isfield(z, 'StartPhaseList'), R)), 'StartPhaseList is required.');
    starts = [R.StartPhaseList];
    assert(numel(starts) == numel(R), 'Struct-array StartPhaseList entries must be scalar.');
    hit = find(starts == 20);
    assert(numel(hit) == 1, 'StartPhaseList must contain 20 exactly once.');
    E = R(hit); phaseIndex = 1;
else
    E = R;
    assert(isfield(E, 'StartPhaseList'), 'StartPhaseList is required.');
    starts = E.StartPhaseList(:);
    hit = find(starts == 20);
    assert(numel(hit) == 1, 'StartPhaseList must contain 20 exactly once.');
    phaseIndex = hit;
end
assert(isfield(E, 'NumBlocks') && isfield(E, 'SamplePerSymbol'), ...
    'NumBlocks and SamplePerSymbol are required.');
numBlocks = E.NumBlocks; samplePeriod = E.SamplePerSymbol;
if ~isscalar(numBlocks), numBlocks = numBlocks(phaseIndex); end
if ~isscalar(samplePeriod), samplePeriod = samplePeriod(phaseIndex); end
assert(numBlocks == 20000, 'NumBlocks must equal 20000.');
assert(samplePeriod == 128, 'SamplePerSymbol must equal 128.');
assert(isfield(E, 'UnwrappedPhaseTrace'), 'UnwrappedPhaseTrace is required.');
U = E.UnwrappedPhaseTrace;
if iscell(U)
    u = U{phaseIndex};
elseif isvector(U)
    assert(numel(starts) == 1 || numel(R) > 1, 'Trace cannot select the requested phase.');
    u = U;
elseif size(U, 2) == numel(starts)
    u = U(:, phaseIndex);
elseif size(U, 1) == numel(starts)
    u = U(phaseIndex, :);
else
    error('UnwrappedPhaseTrace has no StartPhaseList dimension.');
end
u = u(:);
assert(numel(u) >= 2000 && all(isfinite(u)), 'Trace needs at least 2000 finite points.');
q = u(end-1999:end);
[codes, ~, codeIndex] = unique(q);
codeCounts = accumarray(codeIndex, 1);
maxCount = max(codeCounts);
tieCenters = codes(codeCounts == maxCount);
center = tieCenters(1);                         % unique sorts, so ties choose lowest
centerWrapped = mod(center, 128);
wrapped = mod(q, 128);
D = evaluate(q, center, 3, 51);
in = abs(q - center) <= 3;
evt = [false; in(1:end-1) & in(2:end) & ...
    ((q(1:end-1) ~= center & q(2:end) == center) | ...
    ((q(1:end-1)-center).*(q(2:end)-center) < 0))];
lastOutside = find(~in, 1, 'last');
if isempty(lastOutside), lastOutside = 0; end
expectedCount = sum(evt(lastOutside+1:end));
assert(isequal(D.eventmask, evt), 'Independent event-mask oracle failed.');
assert(D.counts == expectedCount, 'Independent retained-count oracle failed.');
blocks = (numBlocks-1999:numBlocks)';
firstQualifyingBlock = NaN;
if ~isnan(D.onset), firstQualifyingBlock = blocks(D.onset); end
trial = struct;
trial.ResultMatPath = resultMatPath;
trial.StartPhase = 20; trial.NumBlocks = numBlocks; trial.SamplePerSymbol = samplePeriod;
trial.CenterUnwrapped = center; trial.CenterWrapped = centerWrapped;
trial.CenterOccurrences = maxCount; trial.CenterFraction = maxCount / numel(q);
trial.TieCenters = tieCenters; trial.CodeHist = [codes codeCounts];
trial.ActualRangeUnwrapped = [min(q) max(q)];
trial.ActualRangeWrapped = [min(wrapped) max(wrapped)];
trial.ResetCount = sum(D.resetmask); trial.TotalEvents = sum(D.eventmask);
trial.FinalCount = D.counts; trial.EventsLast200BlocksSameC = sum(D.eventmask(end-199:end));
trial.Locked = D.locked; trial.FirstQualifyingBlock = firstQualifyingBlock;
trial.EventBlocks = blocks(D.eventmask); trial.ResetBlocks = blocks(D.resetmask);
trial.CountTrace = D.counttrace;
fieldNames = fieldnames(E);
keepNames = {'sourcefile','runopts','runoptions','note36','note12'};
for k = 1:numel(fieldNames)
    if any(strcmpi(fieldNames{k}, keepNames))
        trial.(fieldNames{k}) = E.(fieldNames{k});
        fprintf('%s:\n', fieldNames{k}); disp(E.(fieldNames{k}));
    end
end
fprintf('Code center: unwrapped=%g wrapped=%g occurrence=%d fraction=%.6f\n', ...
    center, centerWrapped, maxCount, maxCount/numel(q));
if numel(tieCenters) > 1, fprintf('TieCenters (lowest selected):\n'); disp(tieCenters(:)'); end
fprintf('CodeHist [unwrapped count]:\n'); disp([codes codeCounts]);
fprintf('Actual range: unwrapped=[%g %g] wrapped=[%g %g]\n', ...
    min(q), max(q), min(wrapped), max(wrapped));
fprintf('Resets=%d total events=%d final count=%d events last 200 blocks=%d\n', ...
    trial.ResetCount, trial.TotalEvents, trial.FinalCount, trial.EventsLast200BlocksSameC);
fprintf('Locked (>=51)=%d first qualifying block in final in-band run=%g\n', ...
    trial.Locked, trial.FirstQualifyingBlock);
trial.PlotPath = fullfile(outputDir, 'trial_center_touch_trial.png');
save(fullfile(outputDir, 'trial_center_touch_result.mat'), 'trial');
branch = q - center + centerWrapped;
fig = figure('Color', 'w', 'Visible', 'off', 'Position', [100 100 1200 750]);
subplot(2,1,1); plot(blocks, branch, 'b-'); hold on;
yline(centerWrapped, 'k-'); yline(centerWrapped-3, 'k--'); yline(centerWrapped+3, 'k--');
plot(blocks(D.eventmask), branch(D.eventmask), '.', 'Color', [0.85 0.33 0.10], 'MarkerSize', 9);
ylabel('Adjusted wrapped code'); grid on; xlim([blocks(1) blocks(end)]);
subplot(2,1,2); stairs(blocks, D.counttrace, 'b-'); hold on; yline(51, 'r--');
ylabel('Final count trace'); xlabel('Absolute block'); grid on; xlim([blocks(1) blocks(end)]);
sgtitle(sprintf('Center touch rule: final count=%d, locked=%d (>=51)', D.counts, D.locked));
print(fig, trial.PlotPath, '-dpng', '-r150'); close(fig);
end
function out = evaluate(seq, center, halfwidth, minCount)
seq = seq(:); n = numel(seq);
eventmask = false(n,1); resetmask = false(n,1); counttrace = zeros(n,1);
count = 0; havePrevious = false; previous = NaN; onset = NaN;
for k = 1:n
    current = seq(k);
    if abs(current-center) > halfwidth
        count = 0; resetmask(k) = true; havePrevious = false; onset = NaN;
    else
        if havePrevious
            eventmask(k) = (previous ~= center && current == center) || ...
                ((previous-center)*(current-center) < 0);
            if eventmask(k)
                count = count + 1;
                if count == minCount, onset = k; end
            end
        end
        previous = current; havePrevious = true;
    end
    counttrace(k) = count;
end
out = struct('counts', count, 'eventmask', eventmask, 'counttrace', counttrace, ...
    'resetmask', resetmask, 'locked', count >= minCount, 'onset', onset);
end
