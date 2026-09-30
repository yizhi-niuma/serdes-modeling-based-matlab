function probe_adc_equiv(adcDir, outPath, ctlePath)
%PROBE_ADC_EQUIV Quantize a fixed Vin battery through the ti_adc_top on ADCDIR.
%   Builds the runner's ideal TI ADC configuration (M=64, VL=-4, VH=4, N=7,
%   SarPerTah=8, Oversample=128, InputMargin=0), feeds an identical battery of
%   input voltages, records the fast-path codes as a function of Vin, and saves
%   them to OUTPATH. Run once per ADC source directory (baseline vs v1) and diff
%   the two MAT-files to prove code-for-code equivalence.
%
%   The Vin battery covers (1) a fine ramp beyond the input range to exercise
%   every code boundary and both clip rails, (2) the exact code-threshold ladder
%   VL+code*lsb and tight neighbours to stress boundary rounding, and (3) a large
%   chunk of the real cached CTLE waveform.

adcDir = char(adcDir);
outPath = char(outPath);
if nargin < 3 || isempty(ctlePath)
    ctlePath = fullfile('validation', 'CDR', 'test_cdr', 'result', ...
        'channel_ctle_cosim_prbs22', 'channel_ctle.mat');
end
addpath(adcDir, '-begin');

M = 64; VL = -4; VH = 4; N = 7; SarPerTah = 8; Oversample = 128;
adc = ti_adc_top(M, VL, VH, N, SarPerTah, Oversample);
adc.setInputMargin(0);
lsb = (VH - VL) / 2^N;
blockLen = (M - 1) * Oversample + 1;          % 8065 samples per local block
sampPos = 1 + (0:M - 1) * Oversample;          % the 64 sampled positions

% Physical-lane -> sample-position map, taken from the ADC itself so the
% de-permutation is identical for baseline and v1 (ideal clock, phase index 1).
actualIndex = adc.generateSampleIndex(1);
posIndex = round((actualIndex - 1) / Oversample) + 1;   % 1..M per physical lane
assert(isequal(sort(posIndex), 1:M), 'Unexpected lane/position permutation.');

% ---- Vin battery -------------------------------------------------------------
ramp = linspace(-4.5, 4.5, 900001);
th = VL + (0:2^N) * lsb;                        % 0..128 code thresholds
nb = [th, th - 1e-12, th + 1e-12, th - eps(4), th + eps(4), ...
      th - 1e-9, th + 1e-9, th - 1e-6, th + 1e-6];
mf = matfile(ctlePath);
nCtle = min(256000, size(mf, 'ctleOutput', 2));
ctle = double(mf.ctleOutput(1, 1:nCtle));
vin = [ramp, nb, ctle];
vin = reshape(vin, 1, []);

L = numel(vin);
nGroups = ceil(L / M);
vinPad = [vin, zeros(1, nGroups * M - L)];
codes = zeros(1, nGroups * M);
w = zeros(1, blockLen);
for g = 1:nGroups
    seg = vinPad((g - 1) * M + (1:M));          % seg(k) -> sample position k
    w(sampPos) = seg;
    dfast = adc.convertOneBlockFast(w, 1);       % code per physical lane
    codesByPosition = zeros(1, M);
    codesByPosition(posIndex) = dfast;           % undo lane permutation
    codes((g - 1) * M + (1:M)) = codesByPosition;
end
codes = codes(1:L);

meta = struct('adcDir', adcDir, 'M', M, 'VL', VL, 'VH', VH, 'N', N, ...
    'SarPerTah', SarPerTah, 'Oversample', Oversample, 'lsb', lsb, ...
    'nRamp', numel(ramp), 'nThresh', numel(nb), 'nCtle', nCtle, ...
    'posIndex', posIndex);
save(outPath, 'vin', 'codes', 'meta', '-v7');
fprintf('probe_adc_equiv: %d Vin samples quantized, codes in [%d, %d], adcDir=%s\n', ...
    L, min(codes), max(codes), adcDir);
end
