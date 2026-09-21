function probe_bimodal_detail()
testDir = fileparts(fileparts(mfilename('fullpath')));
addpath(testDir);
setup_cdr_dlev_cdrffe_paths('legacy');
warning('cdr_validation:HistoricalProbe', ...
    ['Historical anchor probe: DlevInit no longer sets FFE training reference. ' ...
    'Review explicit FfeTraining*Ref before interpreting results.']);
%PROBE_BIMODAL_DETAIL Re-run anchor 35/12 and print per-start-phase detail to
%   test the two-competing-equilibria hypothesis for the [32,35] degraded band.

[~, r] = evalc(['cdr_dlev_cdrffe_sslms_v3(' ...
    '''DlevOuterInit'',35,''DlevInnerInit'',12,''SaveOutputs'',false)']);
fprintf('anchor 35/12: locked %d/32, common %d, spread %d\n', ...
    sum(r.LockedFlag), r.CommonLockPhase, r.PhaseSpread);
fprintf('idx startPhase locked lockedCode\n');
startPhaseList = 0:4:124;
for k = 1:32
    fprintf('%3d %6d %8d %8d\n', k, startPhaseList(k), r.LockedFlag(k), ...
        r.LockedPhaseCode(k));
end
lockedCodes = r.LockedPhaseCode(r.LockedFlag);
fprintf('locked-code histogram (locked only): ');
u = unique(lockedCodes);
for v = u(:).'
    fprintf('%d:%d ', v, sum(lockedCodes == v));
end
fprintf('\nunlocked final codes: ');
fprintf('%d ', r.LockedPhaseCode(~r.LockedFlag));
fprintf('\n');
end
