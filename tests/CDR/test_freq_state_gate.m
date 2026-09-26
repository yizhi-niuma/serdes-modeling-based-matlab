function test_freq_state_gate()
%TEST_FREQ_STATE_GATE Online frequency-state lock gate in loop_monitor.
%
%   The gate is an online form of the static detectFrequencyStateLock. The
%   decisive property is therefore not "does it ever fire" but "does it fire
%   on exactly the block at which the offline criterion, evaluated on the
%   trace prefix, first turns true". Every case below is built around that
%   equivalence rather than around hand-picked expected block numbers.

fprintf('test_freq_state_gate\n');
rng(20260926, 'twister');

testEquivalenceOnRampThenFlat();
testEquivalenceOnNoisyFlat();
testNeverFiresWhileRamping();
testWindowBoundaryAndOneShot();
testMinBlockSuppression();
testRateMatchRejectsWrongRate();
testNonFiniteSamplesAreSkipped();
testResetStateClearsGate();
testConfigValidation();

fprintf('  ALL PASS\n');
end

% -------------------------------------------------------------------------

function mon = makeMonitor()
% Constructor arity is unchanged by the gate; use the documented 4-argument
% form and configure the gate separately.
mon = loop_monitor(500, 100, 3, 1);
end

function blk = offlineFirstLockBlock(seq, window, expectedRate, ...
        meanHalfDiffTol, stdTol, rateTol, minBlock)
%OFFLINEFIRSTLOCKBLOCK First block at which the offline criterion holds.
blk = NaN;
for k = window:numel(seq)
    if k < minBlock
        continue;
    end
    locked = loop_monitor.detectFrequencyStateLock(seq(1:k), window, ...
        expectedRate, meanHalfDiffTol, stdTol, rateTol);
    if locked
        blk = k;
        return;
    end
end
end

function blk = onlineFireBlock(seq, window, expectedRate, ...
        meanHalfDiffTol, stdTol, rateTol, minBlock)
%ONLINEFIREBLOCK Block at which the online gate latches, or NaN.
mon = makeMonitor();
mon.enableFreqStateGate(window, expectedRate, meanHalfDiffTol, stdTol, ...
    rateTol, minBlock);
blk = NaN;
fireCount = 0;
for k = 1:numel(seq)
    triggered = mon.updateFreqStateGate(k, seq(k));
    if triggered
        fireCount = fireCount + 1;
        blk = k;
    end
end
assert(fireCount <= 1, 'gate reported more than one transition');
if fireCount == 1
    state = mon.getState();
    assert(state.FreqGateDone, 'FreqGateDone not latched after a trigger');
    assert(state.FreqGateBlock == blk, 'FreqGateBlock disagrees with return');
end
end

function checkEquivalence(label, seq, window, expectedRate, ...
        meanHalfDiffTol, stdTol, rateTol, minBlock)
offlineBlk = offlineFirstLockBlock(seq, window, expectedRate, ...
    meanHalfDiffTol, stdTol, rateTol, minBlock);
onlineBlk = onlineFireBlock(seq, window, expectedRate, ...
    meanHalfDiffTol, stdTol, rateTol, minBlock);
assert(isequaln(offlineBlk, onlineBlk), ...
    '%s: online block %s differs from offline block %s', label, ...
    mat2str(onlineBlk), mat2str(offlineBlk));
fprintf('  %-34s offline=%-8s online=%-8s OK\n', label, ...
    mat2str(offlineBlk), mat2str(onlineBlk));
end

% -------------------------------------------------------------------------

function testEquivalenceOnRampThenFlat()
% A capture transient that settles onto a constant frequency state, i.e. the
% ppm tracking case the gate exists for.
window = 50;
rate = -0.82;
seq = [linspace(0, rate, 120), rate * ones(1, 400)];
seq = seq + 1e-4 * randn(1, numel(seq));
checkEquivalence('ramp-then-flat', seq, window, rate, 0.01, 0.02, 0.05, 1);
end

function testEquivalenceOnNoisyFlat()
% Several noise levels, some of which never satisfy the tolerance. Both
% paths must agree including on the never-locks outcome.
window = 40;
rate = 0.5;
for noise = [1e-4, 5e-3, 2e-2, 1e-1]
    seq = rate + noise * randn(1, 300);
    label = sprintf('noisy-flat noise=%.0e', noise);
    checkEquivalence(label, seq, window, rate, 0.01, 0.02, 0.05, 1);
end
end

function testNeverFiresWhileRamping()
% A PI code that keeps ramping is exactly the situation in which the old
% code-domain center-touch gate could never fire. Here the frequency state
% itself is still ramping, so the frequency gate must not fire either.
window = 50;
seq = linspace(0, 5, 400);
blk = onlineFireBlock(seq, window, NaN, 1e-6, 1e-6, Inf, 1);
assert(isnan(blk), 'gate fired on a ramping frequency state at block %g', blk);
fprintf('  %-34s no trigger OK\n', 'ramping-never-fires');
end

function testWindowBoundaryAndOneShot()
% The gate cannot fire before the window is full, and fires at most once.
window = 30;
seq = 0.25 * ones(1, 200);
blk = onlineFireBlock(seq, window, 0.25, 1e-9, 1e-9, 1e-9, 1);
assert(blk == window, ...
    'perfectly flat sequence should fire at the window boundary %d, got %g', ...
    window, blk);
fprintf('  %-34s block=%d OK\n', 'window-boundary', blk);
end

function testMinBlockSuppression()
% minBlock defers the trigger without changing the criterion: a flat
% sequence fires exactly at minBlock once that is past the window.
window = 20;
minBlock = 75;
seq = -0.3 * ones(1, 200);
blk = onlineFireBlock(seq, window, -0.3, 1e-9, 1e-9, 1e-9, minBlock);
assert(blk == minBlock, 'expected suppression until %d, got %g', ...
    minBlock, blk);
checkEquivalence('min-block', seq, window, -0.3, 1e-9, 1e-9, 1e-9, minBlock);
end

function testRateMatchRejectsWrongRate()
% Flat but at the wrong magnitude: flatness passes, the rate match fails.
window = 30;
seq = 0.9 * ones(1, 200);
blk = onlineFireBlock(seq, window, 0.2, 1e-9, 1e-9, 0.05, 1);
assert(isnan(blk), 'gate ignored the rate mismatch and fired at %g', blk);

% The same sequence with the rate test disabled must fire on flatness.
blk = onlineFireBlock(seq, window, NaN, 1e-9, 1e-9, Inf, 1);
assert(blk == window, 'flatness-only gate failed to fire, got %g', blk);
fprintf('  %-34s reject+accept OK\n', 'rate-match');
end

function testNonFiniteSamplesAreSkipped()
% A non-finite sample must not enter the window, must be counted, and must
% not make the criterion error out mid-run.
window = 10;
mon = makeMonitor();
mon.enableFreqStateGate(window, 0.4, 1e-9, 1e-9, 1e-9, 1);
blk = NaN;
for k = 1:60
    value = 0.4;
    if k == 5 || k == 6
        value = NaN;
    elseif k == 7
        value = Inf;
    end
    if mon.updateFreqStateGate(k, value)
        blk = k;
        break;
    end
end
state = mon.getState();
assert(state.FreqGateSkippedCount == 3, ...
    'expected 3 skipped samples, got %g', state.FreqGateSkippedCount);
% Three samples were skipped, so the window fills three blocks later than
% the clean case: the gate observes samples, not block indices.
assert(blk == window + 3, ...
    'expected the trigger at block %d, got %g', window + 3, blk);
fprintf('  %-34s skipped=%d block=%d OK\n', 'non-finite-skip', ...
    state.FreqGateSkippedCount, blk);
end

function testResetStateClearsGate()
% resetState clears dynamic gate state while preserving its configuration.
window = 15;
mon = makeMonitor();
mon.enableFreqStateGate(window, 0.1, 1e-9, 1e-9, 1e-9, 1);
for k = 1:40
    mon.updateFreqStateGate(k, 0.1);
end
before = mon.getState();
assert(before.FreqGateDone, 'gate did not latch before reset');

mon.resetState();
after = mon.getState();
assert(after.FreqGateEnabled, 'reset disabled the gate');
assert(~after.FreqGateDone, 'reset left the gate latched');
assert(isnan(after.FreqGateBlock), 'reset left a stale block');
assert(after.FreqGateSampleCount == 0, 'reset left a stale sample count');
assert(after.FreqGateSkippedCount == 0, 'reset left a stale skip count');
assert(after.FreqGateWindow == window, 'reset lost the window config');

% It must be usable again and reach the same verdict as a fresh monitor.
blk = NaN;
for k = 1:40
    if mon.updateFreqStateGate(k, 0.1)
        blk = k;
        break;
    end
end
assert(blk == window, 'gate did not re-arm correctly, got %g', blk);
fprintf('  %-34s re-armed at %d OK\n', 'reset-state', blk);
end

function testConfigValidation()
% Bad configuration and misuse must raise rather than silently mis-gate.
mon = makeMonitor();
assertThrows(@() mon.updateFreqStateGate(1, 0.5), ...
    'loop_monitor:FreqGateDisabled', 'update before enable');
assertThrows(@() mon.enableFreqStateGate(10, 0.1, 1e-9, 1e-9), ...
    'loop_monitor:InvalidFreqGateConfig', 'wrong arity');
assertThrows(@() mon.enableFreqStateGate(1, 0.1, 1e-9, 1e-9, 1e-9, 1), ...
    'loop_monitor:InvalidFreqGateWindow', 'window below 2');
assertThrows(@() mon.enableFreqStateGate(10, 0.1, -1, 1e-9, 1e-9, 1), ...
    'loop_monitor:InvalidTolerance', 'negative meanHalfDiffTol');
assertThrows(@() mon.enableFreqStateGate(10, 0.1, 1e-9, 1e-9, 1e-9, 0), ...
    'loop_monitor:InvalidFreqGateMinBlock', 'minBlock below 1');

mon.enableFreqStateGate(10, 0.1, 1e-9, 1e-9, 1e-9, 1);
assertThrows(@() mon.updateFreqStateGate(0, 0.5), ...
    'loop_monitor:InvalidBlock', 'block below 1');
assertThrows(@() mon.updateFreqStateGate(1, [1 2]), ...
    'loop_monitor:InvalidFreqState', 'non-scalar state');
fprintf('  %-34s OK\n', 'config-validation');
end

function assertThrows(fn, expectedId, label)
threw = false;
try
    fn();
catch err
    threw = true;
    assert(strcmp(err.identifier, expectedId), ...
        '%s: expected %s, got %s', label, expectedId, err.identifier);
end
assert(threw, '%s: expected an error, none raised', label);
end
