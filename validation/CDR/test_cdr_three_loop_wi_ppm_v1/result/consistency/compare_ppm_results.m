function report = compare_ppm_results(pathA, pathB, reportTxt)
%COMPARE_PPM_RESULTS Deep-compare two cdr_three_loop_ppm result MAT-files.
%   REPORT = COMPARE_PPM_RESULTS(PATHA, PATHB) loads the `result` struct saved by
%   the baseline and the v1 (new-ADC) runs and walks every leaf value. Numeric
%   and logical leaves are compared with isequaln; the maximum absolute
%   difference is reported for any that differ. A third optional argument writes
%   the printed report to a text file.
%
%   Because the whole ppm pipeline is deterministic (no RNG) and the updated TI
%   ADC produces bit-identical codes in the runner's ideal configuration, an
%   all-identical report is the expected consistency result.

A = load(pathA);
B = load(pathB);
assert(isfield(A, 'result') && isfield(B, 'result'), ...
    'Both MAT-files must contain a variable named result.');

report = struct('nLeaves', 0, 'nIdentical', 0, 'diffs', {{}});
report = walk('result', A.result, B.result, report);

lines = {};
lines{end+1} = '==== compare_ppm_results ====';
lines{end+1} = sprintf('A (baseline old ADC) = %s', pathA);
lines{end+1} = sprintf('B (v1 new ADC)       = %s', pathB);
lines{end+1} = sprintf('leaves compared = %d, identical = %d, differing = %d', ...
    report.nLeaves, report.nIdentical, numel(report.diffs));
if isempty(report.diffs)
    lines{end+1} = 'RESULT: IDENTICAL -- every leaf matches (isequaln).';
else
    lines{end+1} = 'RESULT: DIFFERENCES FOUND:';
    for i = 1:numel(report.diffs)
        lines{end+1} = sprintf('  DIFF: %s', report.diffs{i}); %#ok<AGROW>
    end
end
text = strjoin(lines, newline);
fprintf('%s\n', text);
if nargin >= 3 && ~isempty(reportTxt)
    fid = fopen(reportTxt, 'w');
    assert(fid > 0, 'Could not open report file for writing.');
    fprintf(fid, '%s\n', text);
    fclose(fid);
end
end

function report = walk(name, a, b, report)
if isstruct(a) && isstruct(b)
    if ~isequal(size(a), size(b))
        report.diffs{end+1} = sprintf('%s: struct size %s vs %s', ...
            name, mat2str(size(a)), mat2str(size(b)));
        return;
    end
    fa = fieldnames(a);
    fb = fieldnames(b);
    if ~isequal(sort(fa), sort(fb))
        report.diffs{end+1} = sprintf('%s: fieldnames differ (%s vs %s)', ...
            name, strjoin(setdiff(fa, fb), ','), strjoin(setdiff(fb, fa), ','));
    end
    common = intersect(fa, fb);
    for e = 1:numel(a)
        for k = 1:numel(common)
            report = walk(sprintf('%s(%d).%s', name, e, common{k}), ...
                a(e).(common{k}), b(e).(common{k}), report);
        end
    end
elseif iscell(a) && iscell(b)
    if ~isequal(size(a), size(b))
        report.diffs{end+1} = sprintf('%s: cell size %s vs %s', ...
            name, mat2str(size(a)), mat2str(size(b)));
        return;
    end
    for k = 1:numel(a)
        report = walk(sprintf('%s{%d}', name, k), a{k}, b{k}, report);
    end
else
    report.nLeaves = report.nLeaves + 1;
    if isequaln(a, b)
        report.nIdentical = report.nIdentical + 1;
    elseif isnumeric(a) && isnumeric(b) && isequal(size(a), size(b))
        dd = double(a) - double(b);
        report.diffs{end+1} = sprintf('%s: numeric differ, maxAbs=%g, nDiff=%d/%d', ...
            name, max(abs(dd(:))), nnz(dd(:) ~= 0 & ~isnan(dd(:))), numel(dd));
    elseif (ischar(a) || isstring(a)) && (ischar(b) || isstring(b))
        report.diffs{end+1} = sprintf('%s: text differ ("%s" vs "%s")', ...
            name, char(string(a)), char(string(b)));
    else
        report.diffs{end+1} = sprintf('%s: differ (class %s/%s size %s/%s)', ...
            name, class(a), class(b), mat2str(size(a)), mat2str(size(b)));
    end
end
end
