function test_detect_pi_center_touch_lock
%TEST_DETECT_PI_CENTER_TOUCH_LOCK Regression checks for modal-center locking.
thisFile = mfilename('fullpath');
repoRoot = fileparts(fileparts(fileparts(thisFile)));
suiteRoot = fullfile(repoRoot, 'validation', 'CDR', 'test_cdr_dlev_cdrffe');
addpath(suiteRoot);
setup_cdr_dlev_cdrffe_paths();
checkEventKinds(); checkThreshold(); checkBandReset(); checkWindowIsolation();
checkInsufficientWindow(); checkModeTie(); checkWrapAndShift(); checkInvalid();
checkRandomOracle();
fprintf('test_detect_pi_center_touch_lock passed 9 / 9 checks.\n');
end

function checkEventKinds
[locked, center, d] = detect_pi_center_touch_lock([9 8 9 8 9], 5, 2, 1, 128);
assert(locked && center == 9 && d.FinalCount == 2 && d.TouchEvents == 2);
assert(d.DirectCrossEvents == 0 && isequal(find(d.EventMask), [3 5]));
[locked, center, d] = detect_pi_center_touch_lock([10 10 9 11 10], 5, 2, 2, 128);
assert(locked && center == 10 && d.FinalCount == 2);
assert(d.TouchEvents == 1 && d.DirectCrossEvents == 1);
[locked, ~, d] = detect_pi_center_touch_lock([7 7 6 6 7 7 6], 7, 2, 1, 128);
assert(~locked && d.FinalCount == 1); % dwell/departure add no events
[locked, center, d] = detect_pi_center_touch_lock(ones(1, 20) * 4, 20, 1, 3, 128);
assert(~locked && center == 4 && d.FinalCount == 0 && d.TotalEvents == 0);
end

function checkThreshold
s50 = touchSequence(9, 50);
[locked, center, d] = detect_pi_center_touch_lock(s50, numel(s50), 51, 3, 128);
assert(~locked && center == 9 && d.FinalCount == 50 && isnan(d.OnsetBlock));
s51 = touchSequence(9, 51);
[locked, center, d] = detect_pi_center_touch_lock(s51, numel(s51), 51, 3, 128);
assert(locked && center == 9 && d.FinalCount == 51 && d.OnsetBlock == numel(s51));
end

function checkBandReset
[locked, center, d] = detect_pi_center_touch_lock([20 17 20 23 20], 5, 2, 3, 128);
assert(locked && center == 20 && d.FinalCount == 2 && d.OutOfBandCount == 0);
s = [20 19 20 19 20 24 20 19 20];
[locked, center, d] = detect_pi_center_touch_lock(s, numel(s), 2, 3, 128);
assert(~locked && center == 20 && d.FinalCount == 1 && d.TotalEvents == 3);
assert(d.OutOfBandCount == 1 && d.LastResetBlock == 6 && isnan(d.OnsetBlock));
assert(~d.EventMask(7) && d.EventMask(9));
end

function checkWindowIsolation
prefix = touchSequence(30, 60);
s = [prefix repmat(40, 1, 8)];
[locked, center, d] = detect_pi_center_touch_lock(s, 8, 1, 3, 128);
assert(~locked && center == 40 && d.WindowStartBlock == numel(prefix) + 1);
assert(d.WindowLength == 8 && d.FinalCount == 0 && d.TotalEvents == 0);
end

function checkInsufficientWindow
[locked, center, d] = detect_pi_center_touch_lock([4 5 4], 10, 1, 3, 128);
assert(~locked && center == 4 && d.WindowStartBlock == 1 && d.WindowLength == 3);
assert(d.FinalCount == 1 && isnan(d.OnsetBlock));
[locked, center, d] = detect_pi_center_touch_lock([], 10, 1, 3, 128);
assert(~locked && isnan(center) && isnan(d.WindowStartBlock));
assert(isnan(d.CenterUnwrapped) && isnan(d.CenterOccurrences) && isnan(d.ModeTieCount));
assert(isempty(d.EventMask) && isempty(d.CountTrace));
end

function checkModeTie
[locked, center, d] = detect_pi_center_touch_lock([5 6], 2, 1, 3, 128);
assert(~locked && center == 5 && d.CenterUnwrapped == 5);
assert(d.CenterOccurrences == 1 && d.ModeTieCount == 2 && d.FinalCount == 0);
end

function checkWrapAndShift
for shift = [-256 -128 0 128 256]
    s = touchSequence(-128 + shift, 3);
    [locked, center, d] = detect_pi_center_touch_lock(s, numel(s), 3, 3, 128);
    assert(locked && center == 0 && d.CenterUnwrapped == -128 + shift);
end
[locked, center, d] = detect_pi_center_touch_lock([0 128 0 128 0], 5, 1, 3, 128);
assert(~locked && center == 0 && d.FinalCount == 0 && d.OutOfBandCount == 2);
end

function checkInvalid
cases = {@() detect_pi_center_touch_lock([1 2;3 4], 2, 1, 3, 128), ...
    @() detect_pi_center_touch_lock([1 NaN], 2, 1, 3, 128), ...
    @() detect_pi_center_touch_lock([1 1.5], 2, 1, 3, 128), ...
    @() detect_pi_center_touch_lock([1 1i], 2, 1, 3, 128), ...
    @() detect_pi_center_touch_lock([1 2], 0, 1, 3, 128), ...
    @() detect_pi_center_touch_lock([1 2], 2, 0, 3, 128), ...
    @() detect_pi_center_touch_lock([1 2], 2, 1, -1, 128), ...
    @() detect_pi_center_touch_lock([1 2], 2, 1, 1.5, 128), ...
    @() detect_pi_center_touch_lock([1 2], 2, 1, 3, 1)};
ids = {'InvalidSequence','InvalidSequence','InvalidSequence','InvalidSequence', ...
    'InvalidWindowBlocks','InvalidMinEvents','InvalidBandHalfWidth', ...
    'InvalidBandHalfWidth','InvalidCodesPerUi'};
for k = 1:numel(cases)
    assertThrows(cases{k}, ['detect_pi_center_touch_lock:' ids{k}]);
end
end

function checkRandomOracle
oldRng = rng; cleanup = onCleanup(@() rng(oldRng)); %#ok<NASGU>
rng(48127, 'twister');
for trial = 1:100
    n = randi([35 100]); w = randi([45 60]); h = randi([0 4]); minimum = randi([1 12]);
    seq = cumsum([randi([-10 10]), randi([-5 5], 1, n - 1)]);
    [locked, centerCode, d] = detect_pi_center_touch_lock(seq, w, minimum, h, 16);
    tail = seq(max(1, n-w+1):n); center = mode(tail); in = abs(tail-center) <= h;
    event = false(size(tail)); touch = event; cross = event;
    valid = in(1:end-1) & in(2:end);
    touch(2:end) = valid & tail(1:end-1) ~= center & tail(2:end) == center;
    cross(2:end) = valid & (tail(1:end-1)-center).*(tail(2:end)-center) < 0;
    event = touch | cross; lastOutside = find(~in, 1, 'last');
    if isempty(lastOutside), lastOutside = 0; end
    finalCount = sum(event(lastOutside+1:end)); expectedLocked = n >= w && finalCount >= minimum;
    assert(locked == expectedLocked && centerCode == mod(center, 16));
    assert(d.CenterUnwrapped == center && isequal(d.EventMask, event));
    assert(d.FinalCount == finalCount && d.TotalEvents == sum(event));
    assert(d.TouchEvents == sum(touch) && d.DirectCrossEvents == sum(cross));
    assert(d.OutOfBandCount == sum(~in));
    if expectedLocked
        qualifying = find(cumsum(event(lastOutside+1:end)) >= minimum, 1) + lastOutside;
        assert(d.OnsetBlock == d.WindowStartBlock + qualifying - 1);
    else
        assert(isnan(d.OnsetBlock));
    end
end
end

function s = touchSequence(center, count)
s = [center repmat([center + 1 center], 1, count)];
end

function assertThrows(action, identifier)
try, action(); catch err, assert(strcmp(err.identifier, identifier)); return; end
error('Expected error %s was not thrown.', identifier);
end
