function ab_stage2_gate()
%AB_STAGE2_GATE A/B the stage-2 downshift gate: center-touch vs freq-state.
%
%   Nothing is written to any result directory: every run uses
%   SaveOutputs=false, so the committed artifacts are untouched. The point of
%   the comparison is three numbers per arm:
%     - how many start phases lock (the pass/fail verdict), and
%     - on which block the stage-2 gate actually fires (NaN = never), and
%     - the frequency-state mean, i.e. whether tracking got better or worse.

ppmList = [-100, 100];
criteria = {'center-touch', 'freq-state'};
startPhases = [0, 32, 64, 96];

fprintf('\n=== stage-2 gate A/B ===\n');
fprintf('start phases: %s | SaveOutputs=false\n\n', mat2str(startPhases));

for p = 1:numel(ppmList)
    ppm = ppmList(p);
    fprintf('---- %+g ppm ----\n', ppm);
    fprintf('%-14s %8s %10s %12s %14s %12s\n', 'criterion', 'locked', ...
        'stage2 fired', 'stage2 blocks', 'freqMean(mean)', 'runtime s');
    for c = 1:numel(criteria)
        crit = criteria{c};
        t0 = tic;
        result = cdr_three_loop_ppm( ...
            'FreqOffsetPpm', ppm, ...
            'StartPhaseList', startPhases, ...
            'FfeGateCriterion', crit, ...
            'SaveOutputs', false);
        elapsed = toc(t0);

        gateBlocks = result.Stage2GateBlock;
        fired = sum(isfinite(gateBlocks));
        freqMeans = arrayfun(@(d) d.MeanValue, result.FreqLockDiagnostics);

        if fired == 0
            blockText = 'none';
        else
            finiteBlocks = gateBlocks(isfinite(gateBlocks));
            blockText = sprintf('%d..%d', min(finiteBlocks), ...
                max(finiteBlocks));
        end

        fprintf('%-14s %5d/%-2d %10d %12s %14.6f %12.1f\n', crit, ...
            sum(result.LockedFlag), numel(result.LockedFlag), fired, ...
            blockText, mean(freqMeans), elapsed);
    end
    fprintf('\n');
end
end
