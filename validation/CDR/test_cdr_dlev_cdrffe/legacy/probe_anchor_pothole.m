function probe_anchor_pothole()
testDir = fileparts(fileparts(mfilename('fullpath')));
addpath(testDir);
setup_cdr_dlev_cdrffe_paths('legacy');
warning('cdr_validation:HistoricalProbe', ...
    ['Historical anchor probe: DlevInit no longer sets FFE training reference. ' ...
    'Review explicit FfeTraining*Ref before interpreting results.']);
%PROBE_ANCHOR_POTHOLE Probe the width of the 33/11 convergence dip inside the
%   anchor basin, since measured-anchor recipes can land near it.
%   33/11 is re-run a third time to test whether the dip is deterministic.

points = [32 11; 33 11; 34 11; 35 12];
for k = 1:size(points, 1)
    o = points(k, 1); i = points(k, 2);
    [~, r] = evalc(sprintf(['cdr_dlev_cdrffe_sslms_v3(' ...
        '''DlevOuterInit'',%d,''DlevInnerInit'',%d,''SaveOutputs'',false)'], o, i));
    fprintf('anchor %2d/%2d : locked %2d/32  ALL %d  phase %3d  spread %2d  dlev %5.2f/%5.2f  pre1 %+7.4f post1 %+7.4f\n', ...
        o, i, sum(r.LockedFlag), r.AllPhaseLock, r.CommonLockPhase, ...
        r.PhaseSpread, mean(r.DlevInnerFinal), mean(r.DlevOuterFinal), ...
        r.FfePre1Final, r.FfePost1Final);
end
end
