function verify_anchor_recipe()
testDir = fileparts(fileparts(mfilename('fullpath')));
addpath(testDir);
setup_cdr_dlev_cdrffe_paths('legacy');
warning('cdr_validation:HistoricalProbe', ...
    ['Historical anchor probe: DlevInit no longer sets FFE training reference. ' ...
    'Review explicit FfeTraining*Ref before interpreting results.']);
%VERIFY_ANCHOR_RECIPE Validate the margined measured-anchor recipe endpoints.
%   Recipe: outerAnchor = 1.8 * mean(|x|) over the first 200 blocks of raw ADC
%   codes at the (arbitrary) start phase; innerAnchor = outerAnchor/3.
%   Measured mean|x| spans 20.53..22.93 over all 128 phases, so the recipe
%   yields outer 36.9..41.2. Verify BOTH endpoints lock, i.e. the recipe clears
%   the [32,35] degraded band for every possible measurement phase.

points = [37 12; 41 14];
for k = 1:size(points, 1)
    o = points(k, 1); i = points(k, 2);
    [~, r] = evalc(sprintf(['cdr_dlev_cdrffe_sslms_v3(' ...
        '''DlevOuterInit'',%d,''DlevInnerInit'',%d,''SaveOutputs'',false)'], o, i));
    fprintf(['anchor %2d/%2d : locked %2d/32  ALL %d  phase %3d  spread %2d  ' ...
        'dlev %5.2f/%5.2f  err %+5.2f/%+5.2f  pre1 %+7.4f post1 %+7.4f  dC %d fC %d\n'], ...
        o, i, sum(r.LockedFlag), r.AllPhaseLock, r.CommonLockPhase, ...
        r.PhaseSpread, mean(r.DlevInnerFinal), mean(r.DlevOuterFinal), ...
        r.DlevInnerTruthError, r.DlevOuterTruthError, ...
        r.FfePre1Final, r.FfePost1Final, r.DlevConsistent, r.FfeConsistent);
end
end
