function result = cdr_dlev_cdrffe_sslms_v3(varargin)
%CDR_DLEV_CDRFFE_SSLMS_V3 CDR+DLEV+CDRFFE+SSLMS 链路验证脚本 (v3: SS-MMPD + FFE SS-LMS 版本)
%   本版本在 v2 基础上将 FFE 自适应算法从标准 MMSE LMS 替换为 Sign-Sign LMS (SS-LMS) (Sign-Sign MMPD, uniform weight-1)。
%   核心改进点：
%   1. 相位检测器在做鉴相前先对数据做 PAM4 判决得到 0-3 符号编码，对误差取符号位，
%      仅保留符号信息，消除幅度依赖。
%   2. 每个有效的 PAM4 跳变沿贡献 ±1 的早/晚投票，权重统一为 1，无跳变幅度加权。
%   3. SS-MMPD 的 S 曲线不直接依赖于残留的 pre1/post1 码间干扰幅度，对 FFE 收敛后
%      ISI 趋近于零的场景更鲁棒。
%   4. 本脚本用于验证当 MMSE FFE 将 ISI 补偿到接近零时，SS-MMPD 是否能够稳定维持
%      锁定，以及相位跟踪性能是否满足要求。
%
%   调用方式：
%       result = CDR_DLEV_CDRFFE_SSLMS_V3();
%
%   输出结果：
%       result: 结构体，包含所有相位的收敛状态、环路参数、误码率等信息。
%
%   配置选项可通过 options 结构体传入，默认参数见 parseLoopOptions 函数。
%
%   See also: CDR_DLEV_CDRFFE_SSLMS_V2, cdr_pd, loop_filter, phase_interpolator
%
%
%
%
%
%
%
%   4) FFE 初值两方案:
%      方案 B(默认,FfeInitMode='planB'):冷启动 [0 0 1 0 0 0](仅主抽头=1),让 MMSE
%      自然把 ISI 收敛到最优(首前/首后光标趋于 ~0),是最贴近真实上电的启动方式(v3 用 SS-LMS)。
%      方案 A(FfeInitMode='planA'):以离线最优解 cdrFfeCoefficients 为基准,在自由
%      抽头上人为叠加偏差 FfeBiasScale 作为收敛压力测试。两方案均不再做任何投影。
%
%   5) 三档协同的 mu 换挡:相位环锁定且 dlev 收敛后,dlev 与 FFE 同时从捕获档大 mu
%      降到稳态档小 mu,压低稳态抖动;只降一次,不设强制兜底,避免在相位尚未收敛时
%      把电平/系数冻结在错值上。
%
%   验证判据在蓝本“全相位锁定 + dlev 一致收敛”之外,新增 FFE 判据:各起始相位收敛
%   到一致的系数、稳态窗口内自由抽头 std 低于阈值、pre1/post1 收敛到 ~0(MMSE ISI 归零);
%   输出图在蓝本 4 图之外新增 FFE 系数收敛图与收敛后 FFE 输出 code 直方图(约 2048 样本)。

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
cdrValidationDir = fileparts(testDir);
validationDir = fileparts(cdrValidationDir);
repoRoot = fileparts(validationDir);
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

options = parseLoopOptions(varargin{:});
% CTLE 缓存:默认 PRBS20 完整周期(CosimDir='channel_ctle_cosim'),可切到独立缓存(如 PRBS22)。
cachePath = fullfile(cdrValidationDir, 'test_cdr', 'result', ...
    options.CosimDir, 'channel_ctle.mat');
assert(isfile(cachePath), ...
    'Run test_channel_ctle_cosim first to generate channel_ctle.mat.');
cacheFile = matfile(cachePath);
samplePerSymbol = double(cacheFile.samplePerSymbol);
numCachedSymbols = double(cacheFile.numSymbols);
assert(samplePerSymbol == 128, ...
    'The cached CTLE waveform must use 128 samples/UI.');
assert(logical(getCachePeriodFlag(cacheFile)), ...
    'The cached CTLE waveform is not a complete PRBS20 period.');

analysisStartUi = 512;
% 分析段长度决定处理块总数 numBlocks = floor((analysisNumUi-64-192-256)/64)。
% 取 512512 UI 得到正好 8000 个块:配 FfeTrainingBlocks=500,训练后仍有 7500 个块
% 用于判决引导自收敛长观察。512512 为 64 整数倍,且 512+512512=513024 在缓存 524288
% 符号范围内。
analysisNumUi = options.AnalysisNumUi;  % 默认 512512 (8000 blocks); PRBS22 可加大
adcBlockUi = 64;
assert(mod(analysisNumUi, adcBlockUi) == 0, ...
    'The fixed analysis segment must contain complete 64-UI blocks.');
assert(analysisStartUi + analysisNumUi <= numCachedSymbols, ...
    'The fixed analysis segment exceeds the CTLE cache.');

segmentFirstSample = analysisStartUi * samplePerSymbol + 1;
segmentLastSample = (analysisStartUi + analysisNumUi) * samplePerSymbol;
ctleSegment = double(cacheFile.ctleOutput( ...
    1, segmentFirstSample:segmentLastSample));
assert(numel(ctleSegment) == analysisNumUi * samplePerSymbol, ...
    'The loaded CTLE analysis segment has the wrong length.');

% --- 发送端 golden PAM4 符号(训练模式数据辅助用)---------------------
% 训练模式用已知发送符号做数据辅助自适应:冷启动闭眼时判决不可靠,改用 TX 真值符号
% 定位正确电平,喂给 MMPD/dlev/FFE 三环,保证从闭眼收敛。tx_prbs20.mat 与 CTLE 缓存
% 同源同长(完整 PRBS20 周期),pam4Symbols(k) 对应全局 UI k-1(即 ctleOutput 第
% (k-1)*samplePerSymbol+1 个样本起的那个 UI),电平为 {-3,-1,+1,+3}。
txCachePath = fullfile(cdrValidationDir, 'test_cdr', 'result', ...
    options.CosimDir, options.TxFile);
assert(isfile(txCachePath), ...
    'Run test_channel_ctle_cosim first to generate tx_prbs20.mat.');
txCacheFile = matfile(txCachePath);
txPam4Symbols = reshape(double(txCacheFile.pam4Symbols), 1, []);
assert(numel(txPam4Symbols) == numCachedSymbols, ...
    'The TX golden symbol count must equal the cached symbol count.');
assert(isequal(unique(txPam4Symbols), [-3 -1 1 3]), ...
    'The TX golden symbols must be normalized PAM4 levels {-3,-1,+1,+3}.');

adcLaneCount = 64;
adcSarPerTah = 8;
adcResolutionBits = 7;
adcFullRange = 4;
adcZeroCode = 2^(adcResolutionBits - 1);
referencePhase = 19;
cdrFfeTapOffset = -2:3;
cdrFfePreTapCount = 2;
cdrFfePostTapCount = numel(cdrFfeTapOffset) - cdrFfePreTapCount - 1;
cdrFfeTapCount = numel(cdrFfeTapOffset);
cdrFfeMainTapIndex = cdrFfePreTapCount + 1;
cdrFfeEvalOffset = -3:6;
[laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol);

channelCtleImpulse = double(cacheFile.channelCtleImpulse);
channelCtleSymbolPulse = conv(channelCtleImpulse(:), ...
    ones(samplePerSymbol, 1));
% 信道+CTLE 主光标整数 UI 延迟:符号脉冲峰值相对参考相位所落的整 UI 数。接收端在
% 全局 UI u 采到的样本携带的是发送符号 UI (u - channelMainCursorUi) 的主光标,故训练
% 模式取 golden 必须减去该延迟,否则 golden 标签与接收样本错位(实测约 105 UI),三环
% 拿到去相关的随机梯度而无法收敛。延迟口径与 samplePulseAtPhase 内部一致。
[~, channelPulsePeakIndex] = max(abs(channelCtleSymbolPulse));
channelMainCursorUi = round( ...
    (channelPulsePeakIndex - 1 - referencePhase) / samplePerSymbol);
channelAdcCursorOffset = ...
    (cdrFfeEvalOffset(1) - cdrFfeTapOffset(end)): ...
    (cdrFfeEvalOffset(end) - cdrFfeTapOffset(1));
analogCursor = samplePulseAtPhase(channelCtleSymbolPulse, ...
    samplePerSymbol, referencePhase, channelAdcCursorOffset);
adcCursorCode = quantizeSamplesWithTiAdc(analogCursor, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    samplePerSymbol, laneToTimeOrder, nominalBlockLength);
adcCursorCodeCentered = adcCursorCode - adcZeroCode;
[cdrFfeCoefficients, cdrFfeDesign] = optimizeCdrFfe( ...
    adcCursorCodeCentered, channelAdcCursorOffset, ...
    cdrFfeTapOffset, cdrFfeEvalOffset);
totalUnitUiResponseNormalized = cdrFfeDesign.NormalizedCursor;
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == -1) - 0.05) < 1e-6);
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == 0) - 1) < 1e-12);
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == 1) - 0.05) < 1e-6);

% --- 总通路单位 UI 响应显示窗口(3 pre + 1 main + 8 post)-----------------
% 为直观展示 channel->CTLE->ADC->CDR FFE 总通路的单位 UI(单符号脉冲)响应,单独
% 构造一个比设计窗口更宽的评估窗口 displayEvalOffset = -3:8(3 个 pre cursor、
% 1 个 main cursor、8 个 post cursor)。设计仅把 -3:6 内的非 pre1/post1 cursor 纳入
% KKT 优化,后 cursor 7、8 未被约束,此处如实反映总通路的残余拖尾。显示 regressor
% 只依赖信道数据,先在此构造;收敛后再乘以 FFE 平均终值系数得到归一化单位 UI 响应。
% 显示窗口比设计窗口宽,需要更大偏移的信道 cursor,故重新采样并量化一段更宽的脉冲;
% 量化按 lane 独立进行,重叠偏移处的 code 与设计口径完全一致。
displayEvalOffset = -3:8;
displayChannelOffset = ...
    (displayEvalOffset(1) - cdrFfeTapOffset(end)): ...
    (displayEvalOffset(end) - cdrFfeTapOffset(1));
displayAnalogCursor = samplePulseAtPhase(channelCtleSymbolPulse, ...
    samplePerSymbol, referencePhase, displayChannelOffset);
displayAdcCursorCode = quantizeSamplesWithTiAdc(displayAnalogCursor, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    samplePerSymbol, laneToTimeOrder, nominalBlockLength);
displayAdcCursorCodeCentered = displayAdcCursorCode - adcZeroCode;
displayRegressor = zeros(numel(displayEvalOffset), cdrFfeTapCount);
for displayRow = 1:numel(displayEvalOffset)
    for displayColumn = 1:cdrFfeTapCount
        requiredOffset = displayEvalOffset(displayRow) - ...
            cdrFfeTapOffset(displayColumn);
        channelIndex = find(displayChannelOffset == requiredOffset, 1);
        assert(~isempty(channelIndex), ...
            'The total-path display window requires an unavailable channel cursor.');
        displayRegressor(displayRow, displayColumn) = ...
            displayAdcCursorCodeCentered(channelIndex);
    end
end
displayMainRow = find(displayEvalOffset == 0, 1);

% --- CDR FFE regressor 行索引(用于收敛后核算归一化光标)---------------
% v3:SS-LMS 直接以判决 d 为期望信号(等效目标脉冲 [0 1 0]),不再构造带对称游标的目标
% 脉冲。SS-LMS 最优解同样把 pre1/post1 压到 ~0(与 MMSE 稳态一致,仅收敛路径不同),
% 故这里仅保留 regressor 行索引,供收敛后核算 pre1/post1 归一化光标之用。
% 核算用的 ffeRegressorMatrix 不在此处固定为 referencePhase 版,而是等环路跑完后在真实
% 锁定相位 evalPhase 上用 buildPathRegressor 重建(见"事后核算/绘图的采样相位对齐")。
ffePre1Row = find(cdrFfeEvalOffset == -1, 1);
ffeMainRow = find(cdrFfeEvalOffset == 0, 1);
ffePost1Row = find(cdrFfeEvalOffset == 1, 1);

% --- dlev 参考真值离线标定(仅用于验证,不作为初值)-------------------
% 在参考相位跑一遍前端,得到 FFE 输出的 code 域样本,用 KMeans 式聚类估计四个电平
% 的 code 聚类中心,折叠成内/外环“正确值”,作为收敛后的对照真值。
referenceOutput = processOnePhase(ctleSegment, referencePhase, ...
    samplePerSymbol, adcLaneCount, adcSarPerTah, adcResolutionBits, ...
    adcFullRange, adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, adcBlockUi);
levelCenter = estimatePam4Centers(referenceOutput);
dlevInnerReference = (abs(levelCenter(2)) + abs(levelCenter(3))) / 2;
dlevOuterReference = (abs(levelCenter(1)) + abs(levelCenter(4))) / 2;

% --- CDR 闭环配置 -----------------------------------------------------
piNumBit = 7;
piCodeCount = 2^piNumBit;
assert(piCodeCount == samplePerSymbol, ...
    'The PI code count must equal the samples per UI.');

options = parseLoopOptions(varargin{:});

% dlev 初值:硬件可实现的标称值,由 ADC 满量程与 AGC 目标决定,不依赖离线扫描。
dlevOuterNominal = options.DlevOuterInit;
dlevInnerInit = options.DlevInnerInit;
dlevOuterInit = dlevOuterNominal;

loopKp = options.Kp;
loopKi = options.Ki;
loopMaxDeltaCode = options.MaxDeltaCode;
loopFrequencyLimit = 4;
pdPolarity = options.Polarity;
pdOffset = options.PdOffset;
dlevStepSize = options.StepSize;
dlevStepSizeSettle = options.StepSizeSettle;
lockWindow = options.LockWindow;
lockDeltaTol = options.LockDeltaTol;
dlevSettleWindow = options.DlevSettleWindow;
dlevSettleTol = options.DlevSettleTol;
dlevPolarity = options.DlevPolarity;
saveOutputs = options.SaveOutputs;

% CDR FFE 环路配置。
ffeStepSize = options.FfeStepSize;
ffeStepSizeSettle = options.FfeStepSizeSettle;
ffeAdaptEnableMask = options.FfeAdaptEnableMask;
ffeInitMode = options.FfeInitMode;
ffeBiasScale = options.FfeBiasScale;
% FFE 放开后至少再自适应 ffeSettleDelay 个块才允许降档,给目标脉冲 LMS 留足重塑时间。
ffeSettleDelay = options.FfeSettleDelay;
% FFE 释放时机。'staged':阶段一冻结 FFE,先让相位/dlev 捕获,锁定后再放开(要求起步
% 眼图已张开,配 planA 使用)。'concurrent':三环从第 1 块起并发自适应,FFE 目标脉冲
% LMS 在捕获期就把眼图撑开,支持 planB 冷启动 [0 0 1 0 0 0] 的真正三环并发收敛。
ffeReleaseMode = options.FfeReleaseMode;
% 目标脉冲首前/首后光标幅度 c:LMS 收敛后 pre1/post1 应逼近该值,也是 MMPD 的保活
% 游标。取值需在“保住 MMPD 增益”与“不过度引入 ISI”之间折中,默认 0.05。
% 目标脉冲首前/首后光标的非对称偏置 skew:对称脉冲 [c 1 c] 会让 h1=h-1 在近峰相位与
% 整 UI 之外的混叠相位同时成立(MMPD 存在多个零点),导致各起始相位锁到不同别名(实测
% 慢 mu 下 20 个相位一致收敛却锁在 code 111 而非 22)。取 pre1=c-skew、post1=c+skew
% 使 h1-h-1=2*skew 唯一确定单一锁定相位,打破别名简并。
% 训练模式块数 N:前 N 个处理块用发送端 golden 符号做数据辅助自适应(MMPD 与 FFE
% 参考流均以 TX 真值符号代替判决),让相位/FFE 在闭眼期也拿到正确梯度,从冷启动
% [0 0 1 0 0 0] 撑开眼图;第 N 块后一次性切回决策导向并降档 mu。N=0 关闭训练模式,
% 退化为纯决策导向(原行为)。训练模式需配 planB 冷启动使用。
ffeTrainingBlocks = options.FfeTrainingBlocks;
% 训练模式总开关:N>0 时启用数据辅助冷启动。训练模式要求 planB 冷启动,并从第 1 块起
% 就让 FFE 自适应(由 golden 符号驱动),不再走 staged/concurrent 的锁定释放逻辑。
trainingMode = ffeTrainingBlocks > 0;
assert(~trainingMode || strcmpi(ffeInitMode, 'planb'), ...
    'Training mode (FfeTrainingBlocks>0) requires FfeInitMode=''planB''.');
% v3:SS-LMS 直接以判决为期望信号(等效目标脉冲 [0 1 0]),无需构造目标脉冲卷积核。

% --- FFE 初值构造 -----------------------------------------------------
% 方案 A:离线最优 + 自由抽头人为偏差(收敛压力测试);方案 B:冷启动 [0 0 1 0 0 0]。
% SS-LMS 无需投影,系数直接从启动点出发,由 SS-LMS 自然收敛到 ISI 最优解。
switch lower(ffeInitMode)
    case 'plana'
        ffeBiasVector = zeros(1, cdrFfeTapCount);
        freeTapMaskInit = true(1, cdrFfeTapCount);
        freeTapMaskInit(cdrFfeMainTapIndex) = false;
        ffeBiasVector(freeTapMaskInit) = ffeBiasScale;
        ffeInitCoefficients = cdrFfeCoefficients + ffeBiasVector;
    case 'planb'
        ffeInitCoefficients = zeros(1, cdrFfeTapCount);
        ffeInitCoefficients(cdrFfeMainTapIndex) = 1;
    otherwise
        error('cdr_dlev_cdrffe_sslms_v3:InvalidFfeInitMode', ...
            'FfeInitMode must be ''planA'' or ''planB''.');
end

% 块调度。两侧留整数 UI 保护带,保证 PI 捕获期 UI-slip 不采到缓存之外。
baseUi = 256;
uiGuard = 192;
maxFirstUi = analysisNumUi - adcBlockUi - uiGuard;
numBlocks = floor((maxFirstUi - baseUi) / adcBlockUi);
assert(numBlocks > 60, 'The analysis segment is too short for the loop run.');

startPhaseList = 0:4:samplePerSymbol - 1;
numStartPhase = numel(startPhaseList);

phaseCodeTrace = zeros(numStartPhase, numBlocks);
uiSlipTrace = zeros(numStartPhase, numBlocks);
timingErrorTrace = zeros(numStartPhase, numBlocks);
deltaCodeTrace = zeros(numStartPhase, numBlocks);
unwrappedPhaseTrace = zeros(numStartPhase, numBlocks);
edgeCountTrace = zeros(numStartPhase, numBlocks);
dlevInnerTrace = zeros(numStartPhase, numBlocks);
dlevOuterTrace = zeros(numStartPhase, numBlocks);
dlevThresholdTrace = zeros(numStartPhase, numBlocks);
ffeCoeffTrace = zeros(numStartPhase, numBlocks, cdrFfeTapCount);
lockedPhaseCode = zeros(1, numStartPhase);
lockedFlag = false(1, numStartPhase);
ffeReleasePhaseCodeTrace = -ones(1, numStartPhase);

% 直方图取样相位:选离参考相位最近的起始相位,收敛后的输出分布与相位无关,任取一
% 个锁定相位即可,这里固定用该相位的稳态尾段累积约 2048 个 FFE 输出 code。
[~, histogramPhaseIndex] = min(abs(startPhaseList - referencePhase));
histogramTargetSamples = 2048;
histogramOutputHistory = [];
% 训练期刚结束后的输出分布:从 blockIndex > ffeTrainingBlocks 起累积首个 2048 UI 的
% FFE 输出 code,与稳态尾段直方图并排对比,观察释放训练后分布是否已经四簇分离。
postTrainOutputHistory = [];

settleBlocks = 30;
lockStdTolerance = 2.0;
dlevSettleStdTolerance = 1.0;
% FFE 判据:稳态窗口内各自由抽头系数的 std 需低于此阈值,判断 FFE 是否收敛稳定。
ffeSettleStdTolerance = 0.01;

for startIndex = 1:numStartPhase
    startPhase = startPhaseList(startIndex);

    phaseInterpolator = cdr_pi(piNumBit, samplePerSymbol);
    phaseInterpolator.resetNonideal();
    phaseInterpolator.setCode(startPhase);
    loopFilter = cdr_loop(loopKp, loopKi, ...
        -loopFrequencyLimit, loopFrequencyLimit, loopMaxDeltaCode);
    loopFilter.resetState();
    dlevLoop = dlev_loop(dlevStepSize, adcBlockUi, ...
        dlevInnerInit, dlevOuterInit, dlevPolarity);
    % 每相位新建一份 FFE 引擎与无状态 FFE,系数从投影后的启动点开始。
    ffeLoop = cdr_ffe_loop(ffeStepSize, cdrFfeTapCount, ...
        cdrFfeMainTapIndex, adcBlockUi, ffeAdaptEnableMask);

    % 两档 mu 换挡状态。lockCounter 累计连续满足 |deltaCode|<=lockDeltaTol 的块数,
    % 达到 lockWindow 且 dlev 收敛即判定锁定,dlev 与 FFE 同时降档,只降一次。
    lockCounter = 0;
    settleDone = false;
    % 分阶段释放状态:ffeReleased=false 时冻结 FFE,先让相位与 dlev 捕获;相位锁定且
    % dlev 收敛后置 true 放开 FFE 目标脉冲 LMS,并记录释放块号 ffeReleaseBlock。
    % 并发模式下 FFE 从第 1 块起即放开,与相位/dlev 三环同时自适应(冷启动开眼)。
    concurrentRelease = strcmpi(ffeReleaseMode, 'concurrent');
    % 训练模式下三环从第 1 块起并发自适应(FFE 由 golden 符号驱动),等效于立即释放。
    ffeReleased = concurrentRelease || trainingMode;
    ffeReleaseBlock = 0;
    ffeReleasePhaseCode = -1;

    adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
        adcResolutionBits, adcSarPerTah, samplePerSymbol);
    adcModel.setInputMargin(0);
    ffeModel = cdr_ffe(ffeInitCoefficients, cdrFfePreTapCount);

    % cdr_ffe 无跨块缓存,采样与处理错开一个块。pendingCentered 暂存待处理块整块
    % code,pendingPast 暂存其 PostTap 个过去样本,pendingHasPast 标记冷启动首块。
    havePending = false;
    pendingHasPast = false;
    pendingCentered = zeros(1, adcBlockUi);
    pendingPast = zeros(1, cdrFfePostTapCount);
    pendingCodeWrapped = 0;
    pendingUiSlip = 0;
    pendingBlockIndex = 0;
    % 训练模式:待处理块对应的 golden 发送符号(整块 64 个),与 pendingCentered 同步
    % 传递,保证与该块 ffeOutput 严格 1:1 对齐。
    pendingGolden = zeros(1, adcBlockUi);

    for sampleBlockIndex = 1:numBlocks + 1
        if sampleBlockIndex <= numBlocks
            sampleCodeWrapped = phaseInterpolator.CodeWrapped;
            sampleUiSlip = phaseInterpolator.UiSlip;
            firstUi = baseUi + (sampleBlockIndex - 1) * adcBlockUi + sampleUiSlip;
            blockStart = firstUi * samplePerSymbol + sampleCodeWrapped + 1;
            blockStop = blockStart + nominalBlockLength - 1;
            assert(blockStart >= 1 && blockStop <= numel(ctleSegment), ...
                'PI slip drove the sampling window off the cached segment.');
            blockWaveform = ctleSegment(blockStart:blockStop);

            physicalCode = adcModel.convertOneBlockFast(blockWaveform, 1);
            centeredCode = double(physicalCode(laneToTimeOrder)) - adcZeroCode;
            haveFuture = true;
            futureSamples = centeredCode(1:cdrFfePreTapCount);
            % 训练模式:取本采样块对应的 golden 发送符号。接收端在全局 UI u 采到的样本
            % 携带的是发送符号 UI (u - channelMainCursorUi) 的主光标,故块首采样 UI
            % analysisStartUi+firstUi(0 基)对应的发送符号是
            % txPam4Symbols(analysisStartUi+firstUi - channelMainCursorUi + 1);codeWrapped
            % 只是子 UI 采样相位,不改变整数符号索引。必须扣除信道主光标延迟,否则
            % golden 标签与接收样本错位,三环拿到去相关梯度无法收敛。
            if trainingMode
                goldenFirst = analysisStartUi + firstUi - channelMainCursorUi + 1;
                assert(goldenFirst >= 1 && ...
                    goldenFirst + adcBlockUi - 1 <= numel(txPam4Symbols), ...
                    'Golden symbol window ran off the TX symbol cache.');
                sampleGolden = txPam4Symbols(goldenFirst:goldenFirst + adcBlockUi - 1);
            else
                sampleGolden = zeros(1, adcBlockUi);
            end
        else
            sampleCodeWrapped = 0;
            sampleUiSlip = 0;
            haveFuture = false;
            futureSamples = zeros(1, cdrFfePreTapCount);
        end

        if havePending
            % 顶层拼接完整输入窗口,送入无状态 cdr_ffe 计算目标块输出与 regressor。
            inputWindow = [pendingPast, pendingCentered, futureSamples];
            [blockOutput, blockRegressor] = ffeModel.processBlock(inputWindow);

            % 边界有效性:冷启动首块缺过去样本(头 PostTap 无效);末块缺未来样本
            % (尾 PreTap 无效);中间块 64 个全有效。
            blockValid = true(1, adcBlockUi);
            if ~pendingHasPast
                blockValid(1:cdrFfePostTapCount) = false;
            end
            if ~haveFuture
                blockValid(end - cdrFfePreTapCount + 1:end) = false;
            end
            ffeOutput = blockOutput(blockValid);

            codeWrapped = pendingCodeWrapped;
            uiSlip = pendingUiSlip;
            blockIndex = pendingBlockIndex;

            % 单判决器:用 dlev 当前门限/电平在 code 域判决,产出共享的 (d, e)。
            [decision, sliceError] = sliceCodePam4(ffeOutput, ...
                dlevLoop.DLevInner, dlevLoop.DLevOuter, dlevLoop.Threshold);

            % 训练模式数据辅助:前 ffeTrainingBlocks 个处理块,用 golden 发送符号替代
            % 判决,把正确电平喂给共享 (d, e)。闭眼期真实判决不可靠,而 golden 符号是
            % 发送真值,MMPD/dlev/FFE 三环由此拿到正确梯度,从冷启动 [0 0 1 0 0 0] 撑开
            % 眼图。golden 需按当前 dlev 电平映射到 code 域({±3,±1}→{±DLevOuter,
            % ±DLevInner}),误差 e = ffeOutput - goldenDecision 与决策导向同口径。
            trainingActive = trainingMode && blockIndex <= ffeTrainingBlocks;
            if trainingActive
                goldenValid = pendingGolden(blockValid);
                goldenIsOuter = abs(goldenValid) >= 2;
                goldenMagnitude = dlevLoop.DLevInner + ...
                    (dlevLoop.DLevOuter - dlevLoop.DLevInner) .* goldenIsOuter;
                decision = sign(goldenValid) .* goldenMagnitude;
                sliceError = ffeOutput - decision;
            end

            % FFE 目标脉冲参考专用判决流。训练期(闭眼、dlev 未稳)FFE 参考若跟随 live
            % dlev,会与 dlev 构成“一起缩到 0”的正反馈(|x-r|^2 的平凡零解吸引子)。故训练
            % 期把 golden 按固定锚电平 dlevOuterInit/dlevInnerInit(48/16,设计标称值、上电
            % 前已知,非离线真值)缩放,给 FFE 一个不随自身缩放的稳定标尺,拆掉缩零耦合;
            % dlev 仍独立估 mean|x|。训练结束/非训练时 ffeDecision 等同 decision,FFE 参考
            % 回到 live dlev 正常跟踪——此时眼已张开、非零工作点已是稳定不动点,零解不再吸引。
            if trainingActive
                ffeMagnitude = dlevInnerInit + ...
                    (dlevOuterInit - dlevInnerInit) .* goldenIsOuter;
                ffeDecision = sign(goldenValid) .* ffeMagnitude;
            else
                ffeDecision = decision;
            end

            % --- SS-MMPD 相位检测(纯 code 域,复用共享判决)-------------------
            % ADC 之后即进入 DSP,处理的全是 code,无需回到幅度域。SS-MMPD 只需两个量:
            % 数据符号(0-3)与误差符号位(0/1),二者都能直接从共享 (decision, sliceError)
            % 派生。sliceError 的符号在 code 域与幅度域一致(仅线性缩放),故 errorBit 不变;
            % code 域判决 {-DLevOuter,-DLevInner,+DLevInner,+DLevOuter} 直接映射到 {0,1,2,3}。
            % 训练期 decision/sliceError 已被 golden 覆盖,故此处无需再对训练分支单独处理。
            ssIsPositive = decision >= 0;
            ssIsOuter = abs(decision) >= dlevLoop.Threshold;
            ssDataSymbol = double(ssIsPositive) * 2 + double(ssIsPositive == ssIsOuter);
            ssErrorBit = double(sliceError >= 0);

            dataPrev = ssDataSymbol(1:end - 1);
            dataCurr = ssDataSymbol(2:end);
            errorPrev = ssErrorBit(1:end - 1);
            errorCurr = ssErrorBit(2:end);

            ssDecision = ssMmpdUniform(pdPolarity, ...
                dataPrev, errorPrev, dataCurr, errorCurr);
            validTransition = ssMmpdValid(dataPrev, errorPrev, ...
                dataCurr, errorCurr);
            biasActive = (codeWrapped >= 45) && (codeWrapped <= 116);
            meanPhaseError = mean(double(ssDecision)) + pdOffset * biasActive;

            deltaCode = loopFilter.update(meanPhaseError);
            phaseInterpolator.update(deltaCode);

            % 分阶段释放 + 三档 mu 换挡。阶段一:FFE 冻结在 [0 0 1 0 0 0],让相位环
            % (借信道自身残余 pre/post 光标提供 SS-MMPD 鉴相增益)与 dlev 先行捕获——此时
            % 眼图尚未张开、判决不可靠,若让 FFE 自适应会拿错误判决喂 LMS 导致系数发散。
            % 阶段二:待相位锁定且 dlev 收敛(眼图张开、判决可靠)才放开 FFE 的判决
            % 导向 MMSE 自适应,缓慢把 ISI 收敛到最优(pre1/post1→~0)。阶段三:FFE 也
            % 稳定后,dlev 与 FFE 一起降到稳态档小 mu 压抖动。各里程碑只触发一次。
            if abs(deltaCode) <= lockDeltaTol
                lockCounter = lockCounter + 1;
            else
                lockCounter = 0;
            end
            dlevSettled = blockIndex > dlevSettleWindow && ...
                abs(dlevLoop.DLevOuter - ...
                dlevOuterTrace(startIndex, blockIndex - dlevSettleWindow)) ...
                <= dlevSettleTol;
            if ~ffeReleased
                % 阶段一→二:相位锁定且 dlev 收敛,放开 FFE 自适应并重置锁定计数,
                % 记录释放块号以便阶段三判定 FFE 已运行足够久。
                if lockCounter >= lockWindow && dlevSettled
                    ffeReleased = true;
                    ffeReleaseBlock = blockIndex;
                    ffeReleasePhaseCode = codeWrapped;
                    lockCounter = 0;
                end
            elseif ~settleDone
                if trainingMode
                    % 训练模式:训练结束(跑满 ffeTrainingBlocks 个块)即从数据辅助切回
                    % 决策导向,并把 dlev/FFE 一次性降到稳态档小 mu,压稳态抖动。只降一次。
                    if blockIndex >= ffeTrainingBlocks
                        dlevLoop.setStepSize(dlevStepSizeSettle);
                        ffeLoop.setStepSize(ffeStepSizeSettle);
                        settleDone = true;
                    end
                else
                    % 阶段二→三:FFE 放开后相位重新锁定,且 FFE 已自适应至少 ffeSettleDelay
                    % 个块,dlev 与 FFE 同时降到稳态档,只降一次。
                    ffeRunLongEnough = blockIndex - ffeReleaseBlock >= ffeSettleDelay;
                    if lockCounter >= lockWindow && dlevSettled && ffeRunLongEnough
                        dlevLoop.setStepSize(dlevStepSizeSettle);
                        ffeLoop.setStepSize(ffeStepSizeSettle);
                        settleDone = true;
                    end
                end
            end

            % dlev 符号-符号 LMS 更新:只在满 64 个有效样本的块更新。
            % dlev 更新专用判决:符号取接收样本本身(判决导向),令 dlev_loop 内部
            % sign(d).*e 化简为 |x|-|DLev|,估计目标为 mean(|x|)——眼张开后即可正常
            % 回升,不再被 sign(golden)·x 中符号判错样本的负贡献拖着继续下跌。训练期
            % 内外环归属仍按 golden(goldenMagnitude)指定,闭眼期不依赖阈值路由,避免
            % 把 ±1/±3 认错;非训练期回退到共享 decision,此时眼已张开、阈值路由可靠。
            if trainingActive
                dlevDecision = sign(ffeOutput) .* goldenMagnitude;
                dlevSliceError = ffeOutput - dlevDecision;
            else
                dlevDecision = decision;
                dlevSliceError = sliceError;
            end

            if numel(ffeOutput) == adcBlockUi
                dlevLoop.dlevSsLms(dlevDecision, dlevSliceError);
            end

            % CDR FFE 块速率 SS-LMS 更新:仅在 FFE 放开后且满 64 有效样本的块更新,
            % blockRegressor 为 64x6、ffeOutput 与 ffeDecision 均为整块。
            % v3:Sign-Sign LMS(SS-LMS)。梯度 = sign(e) * sign(X) / N,丢弃误差与
            % regressor 的幅度信息,仅用符号方向驱动系数收敛。与标准 MMSE LMS 相比:
            %   - 梯度幅度恒定(±1/N),不受信号/误差幅度影响,稳定性更好;
            %   - 收敛精度略低(稳态 misadjustment 更大),但硬件友好(只需比较器);
            %   - mu 需比标准 LMS 大 ~100-300 倍以补偿梯度量级压缩。
            % 训练期 ffeDecision 仍用固定锚缩放,避免与 dlev 构成缩零正反馈。主抽头由
            % AdaptEnableMask 固定为增益锚点,增量里主抽头分量末了强制归零。
            if ffeReleased && numel(ffeOutput) == adcBlockUi
                errorBlock = ffeDecision - ffeOutput;
                rawDelta = ffeLoop.updateSsLms(blockRegressor, errorBlock);
                rawDelta(cdrFfeMainTapIndex) = 0;
                ffeModel.applyCoefficientDelta(rawDelta);

                % 直方图相位:累积稳态阶段的整块 FFE 输出 code,后续取尾段约 2048 个。
                if startIndex == histogramPhaseIndex
                    histogramOutputHistory = [histogramOutputHistory, ffeOutput]; %#ok<AGROW>
                    % 训练期刚结束后:blockIndex > ffeTrainingBlocks 起累积首个 2048 个
                    % FFE 输出 code(约 2048 UI),用于第一排直方图。
                    if trainingMode && blockIndex > ffeTrainingBlocks && ...
                            numel(postTrainOutputHistory) < histogramTargetSamples
                        postTrainOutputHistory = ...
                            [postTrainOutputHistory, ffeOutput]; %#ok<AGROW>
                    end
                end
            end

            phaseCodeTrace(startIndex, blockIndex) = codeWrapped;
            uiSlipTrace(startIndex, blockIndex) = uiSlip;
            timingErrorTrace(startIndex, blockIndex) = meanPhaseError;
            deltaCodeTrace(startIndex, blockIndex) = deltaCode;
            edgeCountTrace(startIndex, blockIndex) = sum(validTransition);
            unwrappedPhaseTrace(startIndex, blockIndex) = ...
                uiSlip * samplePerSymbol + codeWrapped;
            dlevInnerTrace(startIndex, blockIndex) = dlevLoop.DLevInner;
            dlevOuterTrace(startIndex, blockIndex) = dlevLoop.DLevOuter;
            dlevThresholdTrace(startIndex, blockIndex) = dlevLoop.Threshold;
            ffeCoeffTrace(startIndex, blockIndex, :) = ...
                reshape(ffeModel.Coefficients, 1, 1, cdrFfeTapCount);
        end

        if sampleBlockIndex <= numBlocks
            if havePending
                pendingPast = pendingCentered(end - cdrFfePostTapCount + 1:end);
                pendingHasPast = true;
            else
                pendingPast = zeros(1, cdrFfePostTapCount);
                pendingHasPast = false;
            end
            pendingCentered = centeredCode;
            pendingGolden = sampleGolden;
            pendingCodeWrapped = sampleCodeWrapped;
            pendingUiSlip = sampleUiSlip;
            pendingBlockIndex = sampleBlockIndex;
            havePending = true;
        end
    end

    settleWindow = phaseCodeTrace(startIndex, end - settleBlocks + 1:end);
    lockedPhaseCode(startIndex) = round(mean(settleWindow));
    ffeReleasePhaseCodeTrace(startIndex) = ffeReleasePhaseCode;
    dlevInnerSettleStd = std(dlevInnerTrace(startIndex, ...
        end - settleBlocks + 1:end));
    dlevOuterSettleStd = std(dlevOuterTrace(startIndex, ...
        end - settleBlocks + 1:end));
    % FFE 稳态判据:各自由抽头系数在稳态窗口内的 std 取最大值,低于阈值判收敛。
    ffeSettleStdPerTap = std(ffeCoeffTrace(startIndex, ...
        end - settleBlocks + 1:end, :), 0, 2);
    ffeSettleStdPerTap = reshape(ffeSettleStdPerTap, 1, cdrFfeTapCount);
    ffeSettleStdMax = max(ffeSettleStdPerTap);
    lockedFlag(startIndex) = std(settleWindow) <= lockStdTolerance && ...
        dlevInnerSettleStd <= dlevSettleStdTolerance && ...
        dlevOuterSettleStd <= dlevSettleStdTolerance && ...
        ffeSettleStdMax <= ffeSettleStdTolerance;

    fprintf(['Start phase %3d/%d: locked=%d, steady phase code=%d, ' ...
        'final SS-MM error=%.4g, dLev=[%.2f %.2f] (std=[%.3f %.3f]), ' ...
        'ffe std max=%.4g.\n'], ...
        startPhase, samplePerSymbol, lockedFlag(startIndex), ...
        lockedPhaseCode(startIndex), timingErrorTrace(startIndex, end), ...
        dlevInnerTrace(startIndex, end), dlevOuterTrace(startIndex, end), ...
        dlevInnerSettleStd, dlevOuterSettleStd, ffeSettleStdMax);
end

commonLockPhase = round(median(lockedPhaseCode(lockedFlag)));
phaseSpread = max(lockedPhaseCode(lockedFlag)) - ...
    min(lockedPhaseCode(lockedFlag));
allPhaseLock = all(lockedFlag) && ...
    all(abs(lockedPhaseCode - commonLockPhase) <= 3);

% dlev 一致性。
dlevInnerFinal = dlevInnerTrace(:, end).';
dlevOuterFinal = dlevOuterTrace(:, end).';
dlevInnerSpread = max(dlevInnerFinal) - min(dlevInnerFinal);
dlevOuterSpread = max(dlevOuterFinal) - min(dlevOuterFinal);
dlevConsistent = dlevInnerSpread <= 2 * dlevSettleStdTolerance && ...
    dlevOuterSpread <= 2 * dlevSettleStdTolerance;

dlevInnerTruthError = mean(dlevInnerFinal) - dlevInnerReference;
dlevOuterTruthError = mean(dlevOuterFinal) - dlevOuterReference;

% --- FFE 一致性与目标游标核验 -----------------------------------------
% 各起始相位收敛到的系数应彼此接近;取终值系数矩阵(numStartPhase x tapCount)。
ffeFinalCoefficients = reshape(ffeCoeffTrace(:, end, :), ...
    numStartPhase, cdrFfeTapCount);
ffeCoeffSpread = max(ffeFinalCoefficients, [], 1) - ...
    min(ffeFinalCoefficients, [], 1);
ffeCoeffMean = mean(ffeFinalCoefficients, 1);
ffeConsistent = max(ffeCoeffSpread) <= 2 * ffeSettleStdTolerance;

% --- 事后核算/绘图的采样相位对齐(v1 关键修正)-------------------------
% referencePhase 只是 S 曲线与离线 KKT 设计的锚点,SS-MMPD 实际锁定相位由环路自己决定,
% 二者并不相等。FFE 系数是在锁定相位上用 live 判决做 MMSE 收敛的,若仍拿
% referencePhase 的 regressor 去乘这套系数,等于把脉冲投影到错误相位,会人为放大
% pre1/post1 残余。故此处在环路真实锁定相位上重新采样并量化,重建"核算用"与"绘图用"
% 两个 regressor。在线自适应逻辑完全不受影响(它本来就在锁定相位上跑)。
if any(lockedFlag)
    evalPhase = commonLockPhase;
else
    evalPhase = referencePhase;   % 未锁定时回退到设计参考相位
end
ffeRegressorMatrix = buildPathRegressor(channelCtleSymbolPulse, ...
    samplePerSymbol, evalPhase, cdrFfeEvalOffset, cdrFfeTapOffset, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    laneToTimeOrder, nominalBlockLength, adcZeroCode);
displayRegressor = buildPathRegressor(channelCtleSymbolPulse, ...
    samplePerSymbol, evalPhase, displayEvalOffset, cdrFfeTapOffset, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    laneToTimeOrder, nominalBlockLength, adcZeroCode);

% v3:SS-LMS ISI 归零核验。用平均终值系数在"锁定相位"regressor 上重算归一化光标,
% SS-LMS 最优解同样把 pre1/post1 压到 ~0(容差 0.02,兼顾块尾补零近似与信道拖尾残差)。
ffeMeanOutputCursor = reshape(ffeRegressorMatrix * ffeCoeffMean(:), 1, []);
ffeMeanNormalizedCursor = ffeMeanOutputCursor / ffeMeanOutputCursor(ffeMainRow);
ffePre1Final = ffeMeanNormalizedCursor(ffePre1Row);
ffePost1Final = ffeMeanNormalizedCursor(ffePost1Row);
ffeConstraintHeld = abs(ffePre1Final) <= 0.02 && abs(ffePost1Final) <= 0.02;

% --- 总通路单位 UI 响应(显示窗口 -3:8)-------------------------------
% 用平均终值系数在更宽的 displayRegressor 上重算总通路单位 UI 响应,并对 main
% cursor 归一化。窗口含 3 个 pre、1 个 main、8 个 post 共 12 个 cursor。
displayOutputCursor = reshape(displayRegressor * ffeCoeffMean(:), 1, []);
displayNormalizedCursor = displayOutputCursor / displayOutputCursor(displayMainRow);

% --- 直方图样本:取累积输出的尾段约 2048 个 ----------------------------
if numel(histogramOutputHistory) >= histogramTargetSamples
    histogramSamples = histogramOutputHistory( ...
        end - histogramTargetSamples + 1:end);
else
    histogramSamples = histogramOutputHistory;
end

% 训练期刚结束后的首个 2048 个 FFE 输出 code(约 2048 UI),用于第一排直方图对比。
if numel(postTrainOutputHistory) >= histogramTargetSamples
    postTrainSamples = postTrainOutputHistory(1:histogramTargetSamples);
else
    postTrainSamples = postTrainOutputHistory;
end

resultDir = fullfile(testDir, 'result', 'cdr_dlev_cdrffe_sslms_v3');
if saveOutputs && ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

blockAxis = 1:numBlocks;
convergenceFigurePath = fullfile(resultDir, 'cdr_phase_convergence.png');
timingErrorFigurePath = fullfile(resultDir, 'cdr_block_timing_error.png');
lockSummaryFigurePath = fullfile(resultDir, ...
    'cdr_locked_phase_vs_start_phase.png');
dlevConvergenceFigurePath = fullfile(resultDir, 'dlev_convergence.png');
ffeConvergenceFigurePath = fullfile(resultDir, 'cdr_ffe_convergence.png');
ffeHistogramFigurePath = fullfile(resultDir, 'cdr_ffe_output_histogram.png');
totalPathResponseFigurePath = fullfile(resultDir, ...
    'cdr_total_path_ui_response.png');
resultMatPath = fullfile(resultDir, 'cdr_dlev_cdrffe_sslms_v3_result.mat');

if saveOutputs
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 650]);
    plot(blockAxis, phaseCodeTrace.', 'LineWidth', 1.0);
    hold on;
    yline(commonLockPhase, 'k--', sprintf('common lock code %d', ...
        commonLockPhase), 'LineWidth', 1.2);
    yline(referencePhase, 'm:', 'S-curve reference phase 19', ...
        'LineWidth', 1.1);
    hold off;
    grid on;
    xlim([blockAxis(1) blockAxis(end)]);
    ylim([0 samplePerSymbol - 1]);
    xlabel('CDR Block Index (64 UI per block)');
    ylabel('PI Sampling Phase Code (wrapped, sample index)');
    title(sprintf(['Triple-loop CDR Phase Convergence: %d start phases, ' ...
        'Kp=%.3g, Ki=%.3g'], numStartPhase, loopKp, loopKi));
    exportgraphics(fig, convergenceFigurePath, 'Resolution', 150);
    close(fig);

    % 每块定时误差瞬态图已按需求取消绘制;timingErrorTrace 仍保留在 result 中备查。

    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 620]);
    plot(startPhaseList, lockedPhaseCode, 'bo-', 'LineWidth', 1.3, ...
        'MarkerFaceColor', 'b');
    hold on;
    yline(commonLockPhase, 'k--', sprintf('common lock code %d', ...
        commonLockPhase), 'LineWidth', 1.2);
    hold off;
    grid on;
    xlim([startPhaseList(1) startPhaseList(end)]);
    xlabel('Initial Sampling Phase Code');
    ylabel('Steady-state Locked Phase Code');
    title(sprintf(['Locked Phase vs Start Phase (all-phase lock = %d, ' ...
        'spread = %d code)'], allPhaseLock, phaseSpread));
    exportgraphics(fig, lockSummaryFigurePath, 'Resolution', 150);
    close(fig);

    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 650]);
    plot(blockAxis, dlevOuterTrace.', 'LineWidth', 1.0);
    hold on;
    plot(blockAxis, dlevInnerTrace.', 'LineWidth', 1.0);
    yline(dlevOuterReference, 'r--', ...
        sprintf('outer ref %.2f', dlevOuterReference), 'LineWidth', 1.2);
    yline(dlevInnerReference, 'r:', ...
        sprintf('inner ref %.2f', dlevInnerReference), 'LineWidth', 1.2);
    yline(dlevOuterInit, 'k--', sprintf('outer init %.2f', dlevOuterInit), ...
        'LineWidth', 1.0);
    yline(dlevInnerInit, 'k:', sprintf('inner init %.2f', dlevInnerInit), ...
        'LineWidth', 1.0);
    hold off;
    grid on;
    xlim([blockAxis(1) blockAxis(end)]);
    xlabel('CDR Block Index (64 UI per block)');
    ylabel('Adapted dLev (code domain)');
    title(sprintf(['dLev Convergence: mu=%.4g->%.4g, inner spread=%.3g, ' ...
        'outer spread=%.3g code'], dlevStepSize, dlevStepSizeSettle, ...
        dlevInnerSpread, dlevOuterSpread));
    exportgraphics(fig, dlevConvergenceFigurePath, 'Resolution', 150);
    close(fig);

    % FFE 系数收敛图:自由抽头各占一个子图,叠画全部起始相位的收敛轨迹,并标注
    % 离线最优系数作为参考线,直观展示三环并发下 FFE 系数的收敛与跨相位一致性。
    freeTapIndexList = find(logical(ffeAdaptEnableMask));
    numFreeTap = numel(freeTapIndexList);
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1100 720]);
    tiledLayout = tiledlayout(fig, numFreeTap, 1, ...
        'TileSpacing', 'compact', 'Padding', 'compact');
    for freeIdx = 1:numFreeTap
        tapIndex = freeTapIndexList(freeIdx);
        nexttile(tiledLayout);
        tapTrace = reshape(ffeCoeffTrace(:, :, tapIndex), ...
            numStartPhase, numBlocks);
        plot(blockAxis, tapTrace.', 'LineWidth', 0.8);
        hold on;
        yline(cdrFfeCoefficients(tapIndex), 'k--', ...
            sprintf('offline %.4f', cdrFfeCoefficients(tapIndex)), ...
            'LineWidth', 1.1);
        hold off;
        grid on;
        xlim([blockAxis(1) blockAxis(end)]);
        thisOffset = cdrFfeTapOffset(tapIndex);
        if thisOffset < 0
            tapName = sprintf('pre%d tap', -thisOffset);
        elseif thisOffset > 0
            tapName = sprintf('post%d tap', thisOffset);
        else
            tapName = 'main tap';
        end
        ylabel(sprintf('%s (offset %+d)', tapName, thisOffset));
        if freeIdx == 1
            title(tiledLayout, sprintf(['CDR FFE Coefficient Convergence ' ...
                '(%s, mu=%.3g->%.3g)'], ffeInitMode, ffeStepSize, ...
                ffeStepSizeSettle));
        end
        if freeIdx == numFreeTap
            xlabel('CDR Block Index (64 UI per block)');
        end
    end
    exportgraphics(fig, ffeConvergenceFigurePath, 'Resolution', 150);
    close(fig);

    % CDR FFE 输出 code 直方图:第一排为训练期刚结束后的首个 ~2048 UI,第二排为
    % 收敛后的稳态尾段 ~2048 个样本,两者都应呈四个 PAM4 code 聚类。
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 900]);
    tl = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    % 第一排:训练期结束后 2048 UI。
    ax1 = nexttile(tl);
    if ~isempty(postTrainSamples)
        histogram(ax1, postTrainSamples, 'BinMethod', 'integers', ...
            'FaceColor', [0.85 0.45 0.1], 'EdgeColor', 'none');
        hold(ax1, 'on');
        hRefLine1 = xline(ax1, levelCenter(1), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
        xline(ax1, levelCenter(2), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
        xline(ax1, levelCenter(3), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
        xline(ax1, levelCenter(4), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
        % 收敛后真实 dlev(观测相位)电平中心,红虚线:
        hConvLine1 = xline(ax1, -dlevOuterFinal(histogramPhaseIndex), 'r--', 'LineWidth', 1.0);
        xline(ax1, -dlevInnerFinal(histogramPhaseIndex), 'r--', 'LineWidth', 1.0);
        xline(ax1, dlevInnerFinal(histogramPhaseIndex), 'r--', 'LineWidth', 1.0);
        xline(ax1, dlevOuterFinal(histogramPhaseIndex), 'r--', 'LineWidth', 1.0);
        legend(ax1, [hRefLine1 hConvLine1], ...
            {'offline-optimal reference level', 'online-converged dlev level'}, ...
            'Location', 'best', 'AutoUpdate', 'off', 'FontSize', 8);
        hold(ax1, 'off');
        title(ax1, sprintf(['Post-training CDR FFE Output Histogram ' ...
            '(first %d UI = blocks %d-%d, after %d training blocks, phase code %d)'], ...
            numel(postTrainSamples), ffeTrainingBlocks + 1, ...
            ffeTrainingBlocks + round(numel(postTrainSamples) / adcBlockUi), ...
            ffeTrainingBlocks, ...
            lockedPhaseCode(histogramPhaseIndex)));
    else
        text(ax1, 0.5, 0.5, ...
            'no post-training samples (training mode disabled)', ...
            'Units', 'normalized', 'HorizontalAlignment', 'center');
        title(ax1, 'Post-training CDR FFE Output Histogram (N/A)');
    end
    grid(ax1, 'on');
    xlabel(ax1, 'CDR FFE Output (code domain)');
    ylabel(ax1, 'Sample Count');

    % 第二排:收敛后稳态尾段。
    ax2 = nexttile(tl);
    histogram(ax2, histogramSamples, 'BinMethod', 'integers', ...
        'FaceColor', [0.2 0.4 0.8], 'EdgeColor', 'none');
    hold(ax2, 'on');
    hRefLine2 = xline(ax2, levelCenter(1), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
    xline(ax2, levelCenter(2), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
    xline(ax2, levelCenter(3), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
    xline(ax2, levelCenter(4), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
    % 收敛后真实 dlev(观测相位)电平中心,红虚线:
    hConvLine2 = xline(ax2, -dlevOuterFinal(histogramPhaseIndex), 'r--', 'LineWidth', 1.0);
    xline(ax2, -dlevInnerFinal(histogramPhaseIndex), 'r--', 'LineWidth', 1.0);
    xline(ax2, dlevInnerFinal(histogramPhaseIndex), 'r--', 'LineWidth', 1.0);
    xline(ax2, dlevOuterFinal(histogramPhaseIndex), 'r--', 'LineWidth', 1.0);
    legend(ax2, [hRefLine2 hConvLine2], ...
        {'offline-optimal reference level', 'online-converged dlev level'}, ...
        'Location', 'best', 'AutoUpdate', 'off', 'FontSize', 8);
    hold(ax2, 'off');
    grid(ax2, 'on');
    xlabel(ax2, 'Converged CDR FFE Output (code domain)');
    ylabel(ax2, 'Sample Count');
    title(ax2, sprintf(['Converged CDR FFE Output Histogram ' ...
        '(start phase %d -> locked sampling phase code %d, %d samples = last blocks %d-%d)'], ...
        startPhaseList(histogramPhaseIndex), ...
        lockedPhaseCode(histogramPhaseIndex), numel(histogramSamples), ...
        numBlocks - round(numel(histogramSamples) / adcBlockUi) + 1, numBlocks));
    exportgraphics(fig, ffeHistogramFigurePath, 'Resolution', 150);
    close(fig);

    % channel->CTLE->ADC->CDR FFE 总通路单位 UI 响应:显示窗口 -3:8,共 3 个 pre、
    % 1 个 main、8 个 post cursor。用平均终值系数重算,归一化到 main。标注 pre1/post1
    % 约束目标 0.05,直观展示总通路残余拖尾与约束保持情况。
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 620]);
    stemHandle = stem(displayEvalOffset, displayNormalizedCursor, 'filled', ...
        'LineWidth', 1.3, 'Color', [0.2 0.4 0.8]);
    stemHandle.MarkerSize = 6;
    hold on;
    stem(0, displayNormalizedCursor(displayMainRow), 'filled', ...
        'LineWidth', 1.6, 'Color', [0.85 0.2 0.2], 'MarkerSize', 8);
    yline(0, 'k--', 'pre1/post1 target 0 (SS-LMS ISI-null)', 'LineWidth', 1.0);
    yline(0, 'k:');
    for cursorIdx = 1:numel(displayEvalOffset)
        text(displayEvalOffset(cursorIdx), ...
            displayNormalizedCursor(cursorIdx), ...
            sprintf('%.3f', displayNormalizedCursor(cursorIdx)), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
            'FontSize', 7);
    end
    hold off;
    grid on;
    xlim([displayEvalOffset(1) - 0.5, displayEvalOffset(end) + 0.5]);
    xticks(displayEvalOffset);
    xlabel('Cursor Offset (UI, 0 = main)');
    ylabel('Normalized Total-Path Response (main = 1)');
    title(sprintf(['Total-Path Unit-UI Response (channel->CTLE->ADC->CDR FFE): ' ...
        '3 pre + 1 main + 8 post, %s | evaluated @ lock phase %d (S-curve ref %d)'], ffeInitMode, evalPhase, referencePhase));
    exportgraphics(fig, totalPathResponseFigurePath, 'Resolution', 150);
    close(fig);
end

result = struct();
result.CachePath = cachePath;
result.AnalysisStartUi = analysisStartUi;
result.AnalysisNumUi = analysisNumUi;
result.SamplePerSymbol = samplePerSymbol;
result.ReferencePhase = referencePhase;
% v1:事后 pre1/post1 核算与总通路响应绘图实际使用的采样相位(= 环路锁定相位,
% 未锁定时回退为 referencePhase)。绘图标题同步显示该值,避免硬编码相位造成误读。
result.EvalPhase = evalPhase;
result.AdcResolutionBits = adcResolutionBits;
result.AdcFullRange = [-adcFullRange adcFullRange];
result.CdrFfeCoefficients = cdrFfeCoefficients;
result.CdrFfeDesign = cdrFfeDesign;
result.CdrFfeTapOffset = cdrFfeTapOffset;
result.CdrFfeMainTapIndex = cdrFfeMainTapIndex;
result.FfeCostMode = 'sslms_ssmmpd';  % v3:SS-MMPD + 判决导向 SS-LMS
result.FfeInitMode = ffeInitMode;
result.FfeBiasScale = ffeBiasScale;
result.FfeInitCoefficients = ffeInitCoefficients;
result.FfeStepSize = ffeStepSize;
result.FfeStepSizeSettle = ffeStepSizeSettle;
result.FfeAdaptEnableMask = ffeAdaptEnableMask;
result.LevelCenter = levelCenter;
result.DlevInnerReference = dlevInnerReference;
result.DlevOuterReference = dlevOuterReference;
result.DlevInnerInit = dlevInnerInit;
result.DlevOuterInit = dlevOuterInit;
result.DlevOuterNominal = dlevOuterNominal;
result.PdType = 'ss-mmpd';
result.PdOffset = pdOffset;
result.LoopKp = loopKp;
result.LoopKi = loopKi;
result.LoopMaxDeltaCode = loopMaxDeltaCode;
result.LoopFrequencyLimit = loopFrequencyLimit;
result.PdPolarity = pdPolarity;
result.DlevStepSize = dlevStepSize;
result.DlevStepSizeSettle = dlevStepSizeSettle;
result.LockWindow = lockWindow;
result.LockDeltaTol = lockDeltaTol;
result.DlevSettleWindow = dlevSettleWindow;
result.DlevSettleTol = dlevSettleTol;
result.DlevPolarity = dlevPolarity;
result.PiNumBit = piNumBit;
result.BaseUi = baseUi;
result.NumBlocks = numBlocks;
result.StartPhaseList = startPhaseList;
result.PhaseCodeTrace = phaseCodeTrace;
result.UiSlipTrace = uiSlipTrace;
result.UnwrappedPhaseTrace = unwrappedPhaseTrace;
result.TimingErrorTrace = timingErrorTrace;
result.DeltaCodeTrace = deltaCodeTrace;
result.EdgeCountTrace = edgeCountTrace;
result.DlevInnerTrace = dlevInnerTrace;
result.DlevOuterTrace = dlevOuterTrace;
result.DlevThresholdTrace = dlevThresholdTrace;
result.FfeCoeffTrace = ffeCoeffTrace;
result.SettleBlocks = settleBlocks;
result.LockStdTolerance = lockStdTolerance;
result.DlevSettleStdTolerance = dlevSettleStdTolerance;
result.FfeSettleStdTolerance = ffeSettleStdTolerance;
result.LockedPhaseCode = lockedPhaseCode;
result.LockedFlag = lockedFlag;
result.FfeReleasePhaseCode = ffeReleasePhaseCodeTrace;
result.CommonLockPhase = commonLockPhase;
result.PhaseSpread = phaseSpread;
result.AllPhaseLock = allPhaseLock;
result.DlevInnerFinal = dlevInnerFinal;
result.DlevOuterFinal = dlevOuterFinal;
result.DlevInnerSpread = dlevInnerSpread;
result.DlevOuterSpread = dlevOuterSpread;
result.DlevInnerTruthError = dlevInnerTruthError;
result.DlevOuterTruthError = dlevOuterTruthError;
result.DlevConsistent = dlevConsistent;
result.FfeFinalCoefficients = ffeFinalCoefficients;
result.FfeCoeffMean = ffeCoeffMean;
result.FfeCoeffSpread = ffeCoeffSpread;
result.FfeConsistent = ffeConsistent;
result.FfeMeanNormalizedCursor = ffeMeanNormalizedCursor;
result.DisplayEvalOffset = displayEvalOffset;
result.DisplayNormalizedCursor = displayNormalizedCursor;
result.FfePre1Final = ffePre1Final;
result.FfePost1Final = ffePost1Final;
result.FfeConstraintHeld = ffeConstraintHeld;
result.HistogramPhaseIndex = histogramPhaseIndex;
result.HistogramSamples = histogramSamples;
result.PostTrainSamples = postTrainSamples;
result.ConvergenceFigurePath = convergenceFigurePath;
result.TimingErrorFigurePath = timingErrorFigurePath;
result.LockSummaryFigurePath = lockSummaryFigurePath;
result.DlevConvergenceFigurePath = dlevConvergenceFigurePath;
result.FfeConvergenceFigurePath = ffeConvergenceFigurePath;
result.FfeHistogramFigurePath = ffeHistogramFigurePath;
result.TotalPathResponseFigurePath = totalPathResponseFigurePath;
result.ResultMatPath = resultMatPath;
if saveOutputs
    save(resultMatPath, 'result', '-v7.3');
end

fprintf('\n');
if allPhaseLock
    fprintf(['CDR triple loop passed: all %d start phases locked to ' ...
        'code %d (spread %d code, ref phase %d).\n'], numStartPhase, ...
        commonLockPhase, phaseSpread, referencePhase);
else
    fprintf(['CDR triple loop did NOT reach full-phase lock: %d/%d ' ...
        'phases stable, spread %d code. Retune gains/mu/polarity.\n'], ...
        sum(lockedFlag), numStartPhase, phaseSpread);
end
if dlevConsistent
    fprintf(['dLev converged consistently: inner=%.2f (spread %.3g), ' ...
        'outer=%.2f (spread %.3g) code.\n'], mean(dlevInnerFinal), ...
        dlevInnerSpread, mean(dlevOuterFinal), dlevOuterSpread);
else
    fprintf(['dLev did NOT converge consistently: inner spread %.3g, ' ...
        'outer spread %.3g code. Retune mu/polarity.\n'], ...
        dlevInnerSpread, dlevOuterSpread);
end
fprintf('pre1/post1 cursors evaluated @ lock phase %d (S-curve ref phase %d).\n', ...
    evalPhase, referencePhase);
if ffeConsistent
    fprintf(['CDR FFE (SS-LMS+SS-MMPD) converged consistently: max coeff spread %.4g, ' ...
        'pre1=%.4f, post1=%.4f (target 0, ISI-null).\n'], max(ffeCoeffSpread), ...
        ffePre1Final, ffePost1Final);
else
    fprintf(['CDR FFE did NOT converge consistently: max coeff spread ' ...
        '%.4g. Retune ffe mu.\n'], max(ffeCoeffSpread));
end
if ffeConstraintHeld
    fprintf(['pre1/post1 nulled to ~0 under decision-directed SS-LMS ' ...
        '(pre1=%.4f, post1=%.4f).\n'], ffePre1Final, ffePost1Final);
else
    fprintf(['pre1/post1 did NOT reach ~0: pre1=%.4f, post1=%.4f. ' ...
        'Under SS-LMS 残余游标偏大,检查 ffe mu / 收敛窗口。\n'], ...
        ffePre1Final, ffePost1Final);
end
fprintf(['dLev vs offline truth: inner ref=%.2f (err %+.2f), ' ...
    'outer ref=%.2f (err %+.2f) code.\n'], dlevInnerReference, ...
    dlevInnerTruthError, dlevOuterReference, dlevOuterTruthError);
fprintf(['Total-path unit-UI response (norm to main): pre=[%s], ' ...
    'post=[%s].\n'], ...
    strtrim(sprintf('%.3f ', displayNormalizedCursor(displayEvalOffset < 0))), ...
    strtrim(sprintf('%.3f ', displayNormalizedCursor(displayEvalOffset > 0))));
fprintf('Results saved to %s.\n', resultDir);
end

function options = parseLoopOptions(varargin)
%PARSELOOPOPTIONS 解析 CDR/dlev/FFE 三环增益与运行开关,给出可调默认值。
%   Kp/Ki 直接作用于 SS-MMPD 归一化输出(无 gainScale 折算)
%   dlev 的 mu;FfeStepSize 为 CDR FFE 的 mu。Polarity/DlevPolarity 分别为 SS-MMPD
%   与 dlev 的极性方向因子,相互独立。名值对(或单个 struct)允许调用方覆盖以重整定。

defaults = struct();
defaults.Kp = 8.0;
defaults.Ki = 0.03;
defaults.PdOffset = -0.05;
defaults.MaxDeltaCode = 12;
defaults.Polarity = 1;
defaults.StepSize = 0.3;
defaults.StepSizeSettle = 0.1;
defaults.LockWindow = 8;
defaults.LockDeltaTol = 1;
defaults.DlevSettleWindow = 16;
defaults.DlevSettleTol = 0.5;
defaults.DlevPolarity = 1;
defaults.DlevOuterInit = 36;
defaults.DlevInnerInit = 12;
% CDR FFE 环路默认参数(v3: Sign-Sign LMS)。SS-LMS 梯度 = sign(e)*sign(X)/N,幅度
% 恒为 O(1) 而非 O(error*regressor)~O(300),故 mu 需比标准 LMS 大 ~200-300 倍方能
% 获得相近的系数更新速度。AdaptEnableMask 固定主抽头(索引 3)为 1 作增益锚点。
% FfeInitMode 选择方案 B(冷启动),FfeBiasScale 默认 0。
% 默认 planB 冷启动训练模式:planB 从 [0 0 1 0 0 0] 冷启动,配训练序列由 golden
% 符号驱动三环。SS-LMS 梯度量级小,捕获档 mu=0.02、稳态档 mu=0.001。实测
% FfeStepSize=0.02 + FfeTrainingBlocks=500 + FfeStepSizeSettle=0.001 可全相位锁定,
% 稳态系数扩展 <0.01。
defaults.FfeStepSize = 0.02;
defaults.FfeStepSizeSettle = 1e-4;
defaults.FfeAdaptEnableMask = logical([1 1 0 1 1 1]);
defaults.FfeInitMode = 'planB';
defaults.FfeBiasScale = 0;
defaults.FfeTargetCursor = 0.05;
defaults.FfeTargetSkew = 0;
defaults.FfeSettleDelay = 250;
defaults.FfeReleaseMode = 'staged';
% 训练模式块数 N:默认 500 开启数据辅助冷启动(需配 FfeInitMode='planB')。~200 块已够张眼,配
% numBlocks=8000,训练结束后仍有 7500 个块做判决引导自收敛长观察。设为 0 可关闭训练、
% 退回纯决策导向(此时应同时把 FfeInitMode 改回 'planA')。
defaults.FfeTrainingBlocks = 500;
defaults.SaveOutputs = true;
% CTLE 缓存选择:默认 PRBS20 完整周期。切 PRBS22 长周期时传
% 'CosimDir','channel_ctle_cosim_prbs22','TxFile','tx_prbs22.mat' 并加大 'AnalysisNumUi'。
defaults.CosimDir = 'channel_ctle_cosim';
defaults.TxFile = 'tx_prbs20.mat';
defaults.AnalysisNumUi = 512512;

options = defaults;
if isempty(varargin)
    return;
end
if numel(varargin) == 1 && isstruct(varargin{1})
    provided = varargin{1};
    fieldList = fieldnames(provided);
    for index = 1:numel(fieldList)
        options.(fieldList{index}) = provided.(fieldList{index});
    end
    return;
end
assert(mod(numel(varargin), 2) == 0, ...
    'Loop options must be name/value pairs.');
for index = 1:2:numel(varargin)
    options.(varargin{index}) = varargin{index + 1};
end
end

function flag = getCachePeriodFlag(cacheFile)
%GETCACHEPERIODFLAG 兼容两种缓存:新缓存有通用字段 isCompletePrbsPeriod;
%   旧 PRBS20 缓存只有 isCompletePrbs20Period。二者皆表示整周期波形。
names = who(cacheFile);
if ismember('isCompletePrbsPeriod', names)
    flag = cacheFile.isCompletePrbsPeriod;
else
    flag = cacheFile.isCompletePrbs20Period;
end
end

function [decision, sliceError] = sliceCodePam4(sample, ...
    dLevInner, dLevOuter, threshold)
%SLICECODEPAM4 用 dlev 维护的 code 域门限/电平做一次 PAM4 判决(单判决器)。
%   电平为 {-dLevOuter, -dLevInner, +dLevInner, +dLevOuter},门限为
%   {-threshold, 0, +threshold}。|x| >= threshold 判外电平,否则内电平;符号由 x
%   的正负决定(x == 0 归正)。返回带符号判决 d 与判决误差 e = x - d。
sample = reshape(sample, 1, []);
isNegative = sample < 0;
isOuter = abs(sample) >= threshold;
magnitude = dLevInner + (dLevOuter - dLevInner) .* isOuter;
decision = magnitude;
decision(isNegative) = -magnitude(isNegative);
sliceError = sample - decision;
end

function outputValid = processOnePhase(segment, phase, samplePerSymbol, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, blockUi)
%PROCESSONEPHASE 在一个固定相位上跑 TI ADC 与 CDR FFE,返回 code 域有效输出。
%   cdr_ffe 无跨块缓存,故先把各块量化得到的 code 沿时间拼成一条连续码流,再在
%   首尾补齐 PostTap/PreTap 个零构成完整输入窗口一次性送入 FFE;窗口首 PostTap 个
%   与尾 PreTap 个输出因边界补零无效,予以剔除。

numUi = floor((numel(segment) - phase - 1) / samplePerSymbol) + 1;
numBlocks = floor(numUi / blockUi);
adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
ffeModel = cdr_ffe(cdrFfeCoefficients, cdrFfePreTapCount);
cdrFfePostTapCount = ffeModel.PostTapCount;
codeStream = zeros(1, numBlocks * blockUi);
for blockIndex = 1:numBlocks
    firstUi = (blockIndex - 1) * blockUi;
    blockStart = firstUi * samplePerSymbol + phase + 1;
    blockStop = blockStart + nominalBlockLength - 1;
    blockWaveform = segment(blockStart:blockStop);
    physicalCode = adcModel.convertOneBlockFast(blockWaveform, 1);
    centeredCode = double(physicalCode(laneToTimeOrder)) - adcZeroCode;
    codeStream((blockIndex - 1) * blockUi + (1:blockUi)) = centeredCode;
end
inputWindow = [zeros(1, cdrFfePostTapCount), codeStream, ...
    zeros(1, cdrFfePreTapCount)];
outputBlock = ffeModel.processBlock(inputWindow);
valid = true(1, numel(outputBlock));
valid(1:cdrFfePostTapCount) = false;
valid(end - cdrFfePreTapCount + 1:end) = false;
outputValid = outputBlock(valid);
end

function [laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol)
%ADCLANEORDERING 返回物理 lane 重排索引与本地块长度。

laneNumber = 1:adcLaneCount;
numTah = adcLaneCount / adcSarPerTah;
lanePhaseIndex = floor((laneNumber - 1) / adcSarPerTah) + 1;
laneSarIndex = mod(laneNumber - 1, adcSarPerTah) + 1;
laneTimeOrderIndex = (laneSarIndex - 1) * numTah + lanePhaseIndex;
[~, laneToTimeOrder] = sort(laneTimeOrderIndex);
nominalBlockLength = (adcLaneCount - 1) * samplePerSymbol + 1;
end

function sample = samplePulseAtPhase(pulse, samplePerSymbol, phase, offset)
%SAMPLEPULSEATPHASE 在固定 UI 偏移处采样符号脉冲响应。

[~, pulsePeakIndex] = max(abs(pulse));
mainUi = round((pulsePeakIndex - 1 - phase) / samplePerSymbol);
mainIndex = mainUi * samplePerSymbol + phase + 1;
sampleIndex = mainIndex + offset * samplePerSymbol;
assert(sampleIndex(1) >= 1 && sampleIndex(end) <= numel(pulse), ...
    'Requested symbol-pulse cursor window exceeds available data.');
sample = reshape(pulse(sampleIndex), 1, []);
end

function regressor = buildPathRegressor(symbolPulse, samplePerSymbol, ...
    phase, evalOffset, tapOffset, adcLaneCount, adcSarPerTah, ...
    adcResolutionBits, adcFullRange, laneToTimeOrder, nominalBlockLength, ...
    adcZeroCode)
%BUILDPATHREGRESSOR 在指定采样相位 phase 上重建总通路 regressor(供事后核算/绘图)。
%   在相位 phase 采样 channel+CTLE 符号脉冲、经同口径 TI ADC 量化去零码后,按
%   (evalOffset(row) - tapOffset(col)) 组装 numel(evalOffset) x numel(tapOffset) 的
%   regressor。与设计期 optimizeCdrFfe / 显示窗口的构造完全同口径,唯一区别是采样相位
%   可任意指定,从而在 MMPD 真实锁定相位上评估 FFE 输出的归一化光标。
channelOffset = (evalOffset(1) - tapOffset(end)):(evalOffset(end) - tapOffset(1));
analog = samplePulseAtPhase(symbolPulse, samplePerSymbol, phase, channelOffset);
codeQuantized = quantizeSamplesWithTiAdc(analog, adcLaneCount, adcSarPerTah, ...
    adcResolutionBits, adcFullRange, samplePerSymbol, laneToTimeOrder, ...
    nominalBlockLength);
codeCentered = codeQuantized - adcZeroCode;
regressor = zeros(numel(evalOffset), numel(tapOffset));
for row = 1:numel(evalOffset)
    for col = 1:numel(tapOffset)
        requiredOffset = evalOffset(row) - tapOffset(col);
        channelIndex = find(channelOffset == requiredOffset, 1);
        assert(~isempty(channelIndex), ...
            'buildPathRegressor: required channel cursor unavailable.');
        regressor(row, col) = codeCentered(channelIndex);
    end
end
end

function code = quantizeSamplesWithTiAdc(sample, adcLaneCount, ...
    adcSarPerTah, adcResolutionBits, adcFullRange, samplePerSymbol, ...
    laneToTimeOrder, nominalBlockLength)
%QUANTIZESAMPLEWITHTIADC 量化最多一个 64-UI 块的 cursor 样本。

assert(numel(sample) <= adcLaneCount, ...
    'Cursor sample count exceeds one TI ADC block.');
adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
waveform = zeros(1, nominalBlockLength);
sampleLocation = 1 + (0:adcLaneCount - 1) * samplePerSymbol;
waveform(sampleLocation(1:numel(sample))) = sample;
physicalCode = adcModel.convertOneBlockFast(waveform, 1);
timeOrderedCode = double(physicalCode(laneToTimeOrder));
code = timeOrderedCode(1:numel(sample));
end

function [coefficients, design] = optimizeCdrFfe( ...
    channelCursor, channelOffset, tapOffset, evalOffset)
%OPTIMIZECDRFFE 约束 pre1/post1 为 0.05 并最小化其余 ISI。

mainTapIndex = find(tapOffset == 0, 1);
freeTapMask = tapOffset ~= 0;
regressor = zeros(numel(evalOffset), numel(tapOffset));
for row = 1:numel(evalOffset)
    for column = 1:numel(tapOffset)
        requiredOffset = evalOffset(row) - tapOffset(column);
        channelIndex = find(channelOffset == requiredOffset, 1);
        assert(~isempty(channelIndex), ...
            'CDR FFE design requires an unavailable channel cursor.');
        regressor(row, column) = channelCursor(channelIndex);
    end
end

freeRegressor = regressor(:, freeTapMask);
fixedMainResponse = regressor(:, mainTapIndex);
pre1Row = find(evalOffset == -1, 1);
mainRow = find(evalOffset == 0, 1);
post1Row = find(evalOffset == 1, 1);
constraintMatrix = [ ...
    freeRegressor(pre1Row, :) - 0.05 * freeRegressor(mainRow, :); ...
    freeRegressor(post1Row, :) - 0.05 * freeRegressor(mainRow, :)];
constraintTarget = -[ ...
    fixedMainResponse(pre1Row) - 0.05 * fixedMainResponse(mainRow); ...
    fixedMainResponse(post1Row) - 0.05 * fixedMainResponse(mainRow)];
otherCursorMask = ~ismember(evalOffset, [-1 0 1]);
objectiveMatrix = freeRegressor(otherCursorMask, :);
objectiveTarget = fixedMainResponse(otherCursorMask);
normalMatrix = objectiveMatrix.' * objectiveMatrix;
regularizationScale = max(trace(normalMatrix) / ...
    size(normalMatrix, 1), eps);
regularization = 1e-8 * regularizationScale;
kktMatrix = [ ...
    normalMatrix + regularization * eye(size(normalMatrix)), ...
    constraintMatrix.'; ...
    constraintMatrix, zeros(size(constraintMatrix, 1))];
kktTarget = [-objectiveMatrix.' * objectiveTarget; constraintTarget];
kktSolution = kktMatrix \ kktTarget;

coefficients = zeros(1, numel(tapOffset));
coefficients(mainTapIndex) = 1;
coefficients(freeTapMask) = kktSolution(1:nnz(freeTapMask));
outputCursor = reshape(regressor * coefficients(:), 1, []);
mainCursor = outputCursor(mainRow);
normalizedCursor = outputCursor / mainCursor;
design = struct();
design.TapOffset = tapOffset;
design.EvalOffset = evalOffset;
design.Regularization = regularization;
design.Regressor = regressor;
design.OutputCursor = outputCursor;
design.NormalizedCursor = normalizedCursor;
design.OtherCursorRms = sqrt(mean( ...
    normalizedCursor(otherCursorMask) .^ 2));
design.OtherCursorMax = max(abs(normalizedCursor(otherCursorMask)));
end

function center = estimatePam4Centers(sample)
%ESTIMATEPAM4CENTERS 估计四个有序的输出 code 聚类中心。

center = prctile(sample, [12.5 37.5 62.5 87.5]);
for iteration = 1:50
    [~, cluster] = min(abs(sample(:) - center), [], 2);
    updated = center;
    for level = 1:4
        levelSample = sample(cluster == level);
        if ~isempty(levelSample)
            updated(level) = mean(levelSample);
        end
    end
    if max(abs(updated - center)) < 1e-12
        break;
    end
    center = updated;
end
center = sort(center);
end


function decision = ssMmpdUniform(polarity, dataPrev, errorPrev, ...
    dataCurr, errorCurr)
%SSMMPDUNIFORM SS-MMPD decision with uniform weight 1 (cdr_pd MMPD kernel).
%   Mirrors cdr_pd.mmpdFast exactly, except every valid transition carries
%   uniform weight 1 (the four symmetric 0<->3 and 1<->2 transitions are no
%   longer boosted to weight 2). This is the "weight = 1" SS-MMPD.

sameError = errorPrev == errorCurr;
errorHigh = errorPrev ~= 0;
dataTransition = dataPrev ~= dataCurr;
risingTransition = dataCurr > dataPrev;
valid = sameError & dataTransition;
early = valid & ((~risingTransition & errorHigh) | ...
    (risingTransition & ~errorHigh));

polarity = int8(polarity);
decision = zeros(size(valid), 'int8');
decision(valid) = -polarity;
decision(early) = polarity;
end

function valid = ssMmpdValid(dataPrev, errorPrev, dataCurr, errorCurr)
%SSMMPDVALID Valid-transition mask used by the uniform SS-MMPD kernel.

sameError = errorPrev == errorCurr;
dataTransition = dataPrev ~= dataCurr;
valid = sameError & dataTransition;
end
