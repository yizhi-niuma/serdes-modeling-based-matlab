function summary = ppm_tracking_range(varargin)
%PPM_TRACKING_RANGE Measure the trackable frequency-offset range of the suite.
%
%   SUMMARY = PPM_TRACKING_RANGE() runs a fast verification subset: the two
%   boundary pairs found on 2026-09-26 (+102 pass / +103 fail and -105 pass /
%   -106 fail) at 8 start phases, plus one guard-relaxed point. It prints a
%   table and returns one struct per evaluated point. Nothing is written to a
%   result directory: every run uses SaveOutputs = false.
%
%   SUMMARY = PPM_TRACKING_RANGE('Name', VALUE, ...) accepts:
%     PpmList        Offsets to evaluate. Default is the boundary subset.
%     StartPhaseStep 4 gives the 32-phase all-phase sweep, 16 the 8-phase
%                    probe. Default 16.
%     PiNonideal     'ab_constant' (default, the suite default) or 'ideal'.
%     RelaxSlewGuard When true, the slew-saturation veto is relaxed as far as
%                    the runner validators allow, which separates the
%                    guard-defined boundary from the tracking boundary.
%                    Default false.
%
%   Two distinct boundaries exist and must not be conflated.
%
%   1) Guard-defined boundary. runner:482-490 computes
%      lockedFlag = freqLock && rotationLock && ~slewSaturated, so the
%      slew-saturation guard is a veto inside the lock verdict. With the
%      default SlewSatPendingTol = 0.5 the suite's own pass criterion holds up
%      to +102 / -105 ppm.
%
%   2) Tracking boundary. With the guard relaxed, the frequency-state and
%      rotation-period criteria themselves remain satisfied well beyond that,
%      because a bounded pending backlog still delivers the correct average
%      rate. The backlog, not the lock criterion, is what degrades first.
%
%   The pass criterion used here is all three of: every start phase locked,
%   AllPhaseLock == 1, and no start phase flagged slew-saturated. They are
%   printed separately so a partial failure stays visible.
%
%   Note on subset logic: the 8-phase list 0:16:112 is a strict subset of the
%   32-phase list 0:4:127, and each start phase is an independent
%   deterministic run, so a FAIL at 8 phases implies a FAIL at 32 phases. Only
%   a PASS needs re-checking at 32 phases.

thisFile = mfilename('fullpath');
suiteDir = fileparts(thisFile);
addpath(suiteDir);
setup_cdr_three_loop_wi_ppm_v1_paths('all');
options = parseOptions(varargin{:});

fprintf('\nppm tracking range : PiNonideal=%s  startPhaseStep=%d  relaxGuard=%d\n', ...
    options.PiNonideal, options.StartPhaseStep, options.RelaxSlewGuard);
printHeader();
summary = repmat(emptyEntry(), 1, numel(options.PpmList));
for index = 1:numel(options.PpmList)
    summary(index) = evaluateOnePoint(options.PpmList(index), options);
    printRow(summary(index));
end

hardCeiling = hardSlewCeilingPpm();
fprintf(['\narithmetic slew ceiling = %.2f ppm ', ...
    '(MaxDeltaCode / (PI codes per UI * ADC block UI) = 1/(128*64))\n'], ...
    hardCeiling);
end

% -------------------------------------------------------------------------

function ceilingPpm = hardSlewCeilingPpm()
% The PI applies at most MaxDeltaCode codes once per ADC block. One code is
% 1/128 UI and one block is 64 UI, so the fastest sustainable phase rate is
% 1/(128*64) UI per UI, which a frequency offset of X ppm demands as X*1e-6.
maxDeltaCode = 1;
piCodesPerUi = 128;
adcBlockUi = 64;
ceilingPpm = maxDeltaCode * 1e6 / (piCodesPerUi * adcBlockUi);
end

function entry = evaluateOnePoint(ppm, options)
runArgs = {'FreqOffsetPpm', ppm, ...
    'StartPhaseStep', options.StartPhaseStep, ...
    'PiNonideal', options.PiNonideal, ...
    'SaveOutputs', false};
if options.RelaxSlewGuard
    % Inf is rejected by the runner's 'finite' validator, so use a large
    % finite tolerance; SlewSatDeltaFrac = 1 is the loosest value permitted
    % and fires only if the mean applied step actually reaches MaxDeltaCode.
    runArgs = [runArgs, {'SlewSatPendingTol', 1e9, 'SlewSatDeltaFrac', 1}];
end

startTime = tic;
result = cdr_three_loop_ppm(runArgs{:});
elapsed = toc(startTime);

phaseCount = numel(result.StartPhaseList);
freqStateMean = arrayfun(@(item) item.MeanValue, result.FreqLockDiagnostics);

entry = emptyEntry();
entry.Ppm = ppm;
entry.PiNonideal = options.PiNonideal;
entry.PhaseCount = phaseCount;
entry.FreqLockCount = sum(logical(result.FreqLockFlag));
entry.RotationLockCount = sum(logical(result.RotationLockFlag));
entry.LockedCount = sum(logical(result.LockedFlag));
entry.AllPhaseLock = logical(result.AllPhaseLock);
entry.SlewSaturatedCount = sum(logical(result.SlewSaturatedFlag));
entry.MaxPendingCodeMeanAbs = max(result.SlewPendingMeanAbs);
entry.MaxDeltaCodeMeanAbs = max(result.SlewDeltaMeanAbs);
entry.SlewUtilization = result.SlewUtilization;
entry.MaxFreqStateError = max(abs(freqStateMean - result.ExpectedFreqState));
entry.CommonLockPhase = result.CommonLockPhase;
entry.RelaxSlewGuard = options.RelaxSlewGuard;
entry.Elapsed = elapsed;
entry.Pass = (entry.LockedCount == phaseCount) && entry.AllPhaseLock && ...
    (entry.SlewSaturatedCount == 0);
end

function entry = emptyEntry()
entry = struct('Ppm', NaN, 'PiNonideal', '', 'PhaseCount', NaN, ...
    'FreqLockCount', NaN, 'RotationLockCount', NaN, 'LockedCount', NaN, ...
    'AllPhaseLock', false, 'SlewSaturatedCount', NaN, ...
    'MaxPendingCodeMeanAbs', NaN, 'MaxDeltaCodeMeanAbs', NaN, ...
    'SlewUtilization', NaN, 'MaxFreqStateError', NaN, ...
    'CommonLockPhase', NaN, 'RelaxSlewGuard', false, 'Elapsed', NaN, ...
    'Pass', false);
end

function printHeader()
fprintf('%6s %6s %6s %7s %4s %4s %9s %9s %8s %9s %7s\n', ...
    'ppm', 'freqL', 'rotL', 'locked', 'all', 'sat', 'maxPend', ...
    'maxDelta', 'util', 'freqErr', 'verdict');
end

function printRow(entry)
if entry.Pass
    verdict = 'PASS';
else
    verdict = 'FAIL';
end
fprintf('%+6g %4d/%-2d %4d/%-2d %4d/%-2d %4d %4d %9.4f %9.4f %8.4f %9.2e %7s\n', ...
    entry.Ppm, entry.FreqLockCount, entry.PhaseCount, ...
    entry.RotationLockCount, entry.PhaseCount, entry.LockedCount, ...
    entry.PhaseCount, entry.AllPhaseLock, entry.SlewSaturatedCount, ...
    entry.MaxPendingCodeMeanAbs, entry.MaxDeltaCodeMeanAbs, ...
    entry.SlewUtilization, entry.MaxFreqStateError, verdict);
end

function options = parseOptions(varargin)
if mod(numel(varargin), 2) ~= 0
    error('ppm_tracking_range:InvalidOptionPairs', ...
        'Name/value options must be supplied in pairs.');
end
options = struct();
options.PpmList = [102, 103, -105, -106];
options.StartPhaseStep = 16;
options.PiNonideal = 'ab_constant';
options.RelaxSlewGuard = false;

for index = 1:2:numel(varargin)
    name = varargin{index};
    if ~(ischar(name) || (isstring(name) && isscalar(name)))
        error('ppm_tracking_range:InvalidOptionName', ...
            'Option names must be character vectors or string scalars.');
    end
    name = char(name);
    if ~isfield(options, name)
        error('ppm_tracking_range:UnknownOption', ...
            'Unknown option "%s".', name);
    end
    options.(name) = varargin{index + 1};
end

validateattributes(options.PpmList, {'numeric'}, ...
    {'vector', 'real', 'finite', 'nonempty'});
validateattributes(options.StartPhaseStep, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'positive', 'integer'});
options.PiNonideal = lower(char(options.PiNonideal));
if ~ismember(options.PiNonideal, {'ideal', 'ab_constant'})
    error('ppm_tracking_range:InvalidPiNonideal', ...
        'PiNonideal must be ''ideal'' or ''ab_constant''.');
end
validateattributes(options.RelaxSlewGuard, {'numeric', 'logical'}, ...
    {'scalar', 'real', 'finite'});
options.RelaxSlewGuard = logical(options.RelaxSlewGuard);
options.PpmList = reshape(double(options.PpmList), 1, []);
end
