function result = cdr_dlev_cdrffe_sslms_v0(varargin)
%CDR_DLEV_CDRFFE_SSLMS 在 dlev 双环基础上再叠加 CDR FFE 系数自适应的三环闭环验证。
%   本脚本以 cdr_dlev_sslms 为蓝本(MMPD 相位环 + dlev 符号-符号 LMS 电平环),
%   增量插入第三条环路:CDR FFE 的块速率 LMS 系数自适应。三条环路从第 0 块起
%   并发运行,共用同一份单判决器结果,验证目标是三环同时收敛且全相位锁定。
%
%   1) 共享单判决器:cdr 顶层用 dlev 当前维护的门限/电平对 FFE 输出做一次判决,
%      得到带符号判决 d 与判决误差 e = x - d,再把同一份 (d, e) 同时喂给三条环路:
%      MMPD 算 Mueller-Muller 定时误差,dlev 算符号-符号 LMS 电平更新,CDR FFE
%      算块速率 LMS 系数更新。三环使用完全一致的判决,保证物理自洽。
%
%   2) CDR FFE 环路(新增):由 cdr_ffe_loop 块速率 LMS 引擎驱动。该引擎的梯度为
%      errorVector * regressor / BlockSize,主抽头由 AdaptEnableMask 固定为 1 作为
%      增益锚点(防止系数塌缩到全零平凡解)。BlockSize 固定 64,只有 64 个样本全有效
%      的块才更新,保证梯度分母口径正确。
%
%   3) 目标脉冲 LMS(替代“最小化 ISI”,消解 FFE 与 MMPD 抢游标的矛盾):若让 FFE
%      无约束最小化 |x-d|^2,LMS 最优解会把 pre1/post1 一起拉到 0,而这恰是 MMPD 的
%      零增益死点(S 曲线斜率 ∝ 残余 pre1/post1),两环互相摧毁。这里不再以“判决 d”
%      为 LMS 的期望信号,而是以“判决流 ⊛ 目标脉冲 g_target”得到的参考流 r 为期望:
%        r_n = d_n + c*(d_{n-1} + d_{n+1})
%      即目标输出脉冲主光标=1、首前/首后光标=c≠0、其余为 0。LMS 最优点随之被搬到
%      这个带非零对称游标的脉冲上,MMPD 的鉴相增益被“保活”,且脉冲对称(h1=h-1=c)
%      使 MMPD 的 h1=h-1 锁定点落在 FFE 可行域内。误差 errorBlock = r - x,对
%      |x-r|^2 做最速下降,与引擎“梯度乘正步长”的方向约定配套。无需任何冻结/投影/
%      硬约束,可从冷启动 [0 0 1 0 0 0] 自然长出对称游标。约束/目标逻辑只存在于脚本
%      层,cdr_ffe / cdr_ffe_loop 类文件保持不变。
%
%   4) FFE 初值两方案:
%      方案 B(默认,FfeInitMode='planB'):冷启动 [0 0 1 0 0 0](仅主抽头=1),让目标
%      脉冲 LMS 自然把首前/首后光标长到 c,是最贴近真实上电的启动方式。
%      方案 A(FfeInitMode='planA'):以离线最优解 cdrFfeCoefficients 为基准,在自由
%      抽头上人为叠加偏差 FfeBiasScale 作为收敛压力测试。两方案均不再做任何投影。
%
%   5) 三档协同的 mu 换挡:相位环锁定且 dlev 收敛后,dlev 与 FFE 同时从捕获档大 mu
%      降到稳态档小 mu,压低稳态抖动;只降一次,不设强制兜底,避免在相位尚未收敛时
%      把电平/系数冻结在错值上。
%
%   验证判据在蓝本“全相位锁定 + dlev 一致收敛”之外,新增 FFE 判据:各起始相位收敛
%   到一致的系数、稳态窗口内自由抽头 std 低于阈值、pre1/post1 收敛到目标游标 c;
%   输出图在蓝本 4 图之外新增 FFE 系数收敛图与收敛后 FFE 输出 code 直方图(约 2048 样本)。

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
cdrValidationDir = fileparts(testDir);
validationDir = fileparts(cdrValidationDir);
repoRoot = fileparts(validationDir);
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

% CTLE 缓存与蓝本共用,仍在 test_cdr 下,按相对路径解析。
cachePath = fullfile(cdrValidationDir, 'test_cdr', 'result', ...
    'channel_ctle_cosim', 'channel_ctle.mat');
assert(isfile(cachePath), ...
    'Run test_channel_ctle_cosim first to generate channel_ctle.mat.');
cacheFile = matfile(cachePath);
samplePerSymbol = double(cacheFile.samplePerSymbol);
numCachedSymbols = double(cacheFile.numSymbols);
assert(samplePerSymbol == 128, ...
    'The cached CTLE waveform must use 128 samples/UI.');
assert(logical(cacheFile.isCompletePrbs20Period), ...
    'The cached CTLE waveform is not a complete PRBS20 period.');

analysisStartUi = 512;
% 分析段长度决定处理块总数 numBlocks = floor((analysisNumUi-64-192-256)/64)。
% 方向A(v0)：回到训练模式引入前的验证窗口 24576 UI，复现 GATE 版
% staged/决策导向的全相位锁定。此为 64 整数倍,且 512+24576 远在缓存范围内。
analysisNumUi = 24576;
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
    'channel_ctle_cosim', 'tx_prbs20.mat');
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

% --- CDR FFE 目标脉冲(替代约束流形)---------------------------------
% 目标脉冲 LMS 的期望输出脉冲:主光标=1、首前/首后光标=targetCursor(≠0)、其余=0。
% LMS 以“判决流 ⊛ g_target”为期望信号,把最优点搬到这个带非零对称游标的脉冲上,
% 既给 MMPD 保活鉴相增益(斜率 ∝ 残余 pre1/post1),又让 h1=h-1=targetCursor 的
% 锁定点落在 FFE 可行域内。仍保留 regressor 行索引,供收敛后核算归一化光标使用。
ffeRegressorMatrix = cdrFfeDesign.Regressor;
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

gainScale = (3 / dlevOuterNominal) ^ 2;
loopKp = options.Kp * gainScale;
loopKi = options.Ki * gainScale;
loopMaxDeltaCode = options.MaxDeltaCode;
loopFrequencyLimit = 4;
pdPolarity = options.Polarity;
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
ffeTargetCursor = options.FfeTargetCursor;
% 目标脉冲首前/首后光标的非对称偏置 skew:对称脉冲 [c 1 c] 会让 h1=h-1 在近峰相位与
% 整 UI 之外的混叠相位同时成立(MMPD 存在多个零点),导致各起始相位锁到不同别名(实测
% 慢 mu 下 20 个相位一致收敛却锁在 code 111 而非 22)。取 pre1=c-skew、post1=c+skew
% 使 h1-h-1=2*skew 唯一确定单一锁定相位,打破别名简并。
ffeTargetSkew = options.FfeTargetSkew;
% 训练模式块数 N:前 N 个处理块用发送端 golden 符号做数据辅助自适应(MMPD 与 FFE
% 参考流均以 TX 真值符号代替判决),让相位/FFE 在闭眼期也拿到正确梯度,从冷启动
% [0 0 1 0 0 0] 撑开眼图;第 N 块后一次性切回决策导向并降档 mu。N=0 关闭训练模式,
% 退化为纯决策导向(原行为)。训练模式需配 planB 冷启动使用。
ffeTrainingBlocks = options.FfeTrainingBlocks;
% 训练模式总开关:N>0 时启用数据辅助冷启动。训练模式要求 planB 冷启动,并从第 1 块起
% 就让 FFE 自适应(由 golden 符号驱动),不再走 staged/concurrent 的锁定释放逻辑。
% 方向A(v0)：强制关闭训练模式，回到纯决策导向的 staged 释放逻辑(GATE 版)。
trainingMode = false;
assert(~trainingMode || strcmpi(ffeInitMode, 'planb'), ...
    'Training mode (FfeTrainingBlocks>0) requires FfeInitMode=''planB''.');
% 目标脉冲(长度 = 2*PreTap+1,居中主抽头),用于与判决流卷积构造参考流 r。
ffeTargetPulse = zeros(1, 2 * cdrFfePreTapCount + 1);
ffeTargetPulseMain = cdrFfePreTapCount + 1;
ffeTargetPulse(ffeTargetPulseMain) = 1;
ffeTargetPulse(ffeTargetPulseMain - 1) = ffeTargetCursor - ffeTargetSkew;
ffeTargetPulse(ffeTargetPulseMain + 1) = ffeTargetCursor + ffeTargetSkew;

% --- FFE 初值构造 -----------------------------------------------------
% 方案 A:离线最优 + 自由抽头人为偏差(收敛压力测试);方案 B:冷启动 [0 0 1 0 0 0]。
% 目标脉冲 LMS 无需投影,系数直接从启动点出发,由 LMS 自然长出对称游标。
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
        error('cdr_dlev_cdrffe_sslms:InvalidFfeInitMode', ...
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

settleBlocks = 30;
lockStdTolerance = 1.5;
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
    % 跨块判决历史:上一处理块末尾 PreTap 个判决,供目标脉冲参考流在块首补历史,
    % 冷启动首块无历史时以 0 补齐。
    prevDecisionTail = zeros(1, cdrFfePreTapCount);
    % FFE 目标脉冲参考专用的跨块判决历史,与 prevDecisionTail 分开维护:训练期
    % ffeDecision 用固定锚缩放,块边界补历史也需同口径,避免混入 live dlev 缩放的判决。
    prevFfeDecisionTail = zeros(1, cdrFfePreTapCount);

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
            % 训练模式:取本采样块对应的 golden 发送符号。块首 UI 的全局符号索引为
            % analysisStartUi+firstUi(0 基),对应 txPam4Symbols(analysisStartUi+firstUi+1)
            % 起的 64 个符号;codeWrapped 只是子 UI 采样相位,不改变整数符号索引。
            if trainingMode
                goldenFirst = analysisStartUi + firstUi + 1;
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

            % 经典 Mueller-Muller 定时误差,用共享 (d, e) 计算。
            timingError = decision(1:end - 1) .* sliceError(2:end) - ...
                decision(2:end) .* sliceError(1:end - 1);
            symmetricTransition = decision(2:end) == -decision(1:end - 1);
            if any(symmetricTransition)
                meanTimingError = mean(timingError(symmetricTransition));
            else
                meanTimingError = 0;
            end

            phaseError = pdPolarity * meanTimingError;
            deltaCode = loopFilter.update(phaseError);
            phaseInterpolator.update(deltaCode);

            % 分阶段释放 + 三档 mu 换挡。阶段一:FFE 冻结在 [0 0 1 0 0 0],让相位环
            % (借信道自身残余 pre/post 光标提供 MMPD 鉴相增益)与 dlev 先行捕获——此时
            % 眼图尚未张开、判决不可靠,若让 FFE 自适应会拿错误判决喂 LMS 导致系数发散。
            % 阶段二:待相位锁定且 dlev 收敛(眼图张开、判决可靠)才放开 FFE 目标脉冲
            % LMS,缓慢把脉冲重塑到 h1=h-1=targetCursor 的对称形。阶段三:FFE 也稳定后,
            % dlev 与 FFE 一起降到稳态档小 mu 压抖动。各里程碑只触发一次。
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

            % CDR FFE 块速率 目标脉冲 LMS 更新:仅在 FFE 放开后且满 64 有效样本的块更新,
            % blockRegressor 为 64x6、ffeOutput 与 decision 均为整块。误差取
            % errorBlock = r - x,其中参考流 r = 判决流 ⊛ g_target(主光标=1、首前/首后
            % 光标=targetCursor),对 |x-r|^2 做最速下降,与引擎“梯度乘正步长”的方向约定
            % 配套。块首用上一块末尾判决补历史、块尾用 0 补未来,把 LMS 最优点搬到带非零
            % 对称游标的目标脉冲上,既保活 MMPD 增益又让其锁定点落在可行域内。主抽头由
            % AdaptEnableMask 固定为增益锚点,增量里主抽头分量末了强制归零。
            if ffeReleased && numel(ffeOutput) == adcBlockUi
                referenceBlock = buildTargetReference(ffeDecision, ...
                    prevFfeDecisionTail, ffeTargetPulse, ffeTargetPulseMain);
                errorBlock = referenceBlock - ffeOutput;
                rawDelta = ffeLoop.update(blockRegressor, errorBlock);
                rawDelta(cdrFfeMainTapIndex) = 0;
                ffeModel.applyCoefficientDelta(rawDelta);

                % 直方图相位:累积稳态阶段的整块 FFE 输出 code,后续取尾段约 2048 个。
                if startIndex == histogramPhaseIndex
                    histogramOutputHistory = [histogramOutputHistory, ffeOutput]; %#ok<AGROW>
                end
            end

            % 维护跨块判决历史:记录本块末尾 PreTap 个判决,供下一块参考流补历史。
            if numel(decision) >= cdrFfePreTapCount
                prevDecisionTail = decision(end - cdrFfePreTapCount + 1:end);
            end
            % FFE 参考专用尾:训练期取固定锚缩放的 ffeDecision,训练后等同 decision。
            if numel(ffeDecision) >= cdrFfePreTapCount
                prevFfeDecisionTail = ffeDecision(end - cdrFfePreTapCount + 1:end);
            end

            phaseCodeTrace(startIndex, blockIndex) = codeWrapped;
            uiSlipTrace(startIndex, blockIndex) = uiSlip;
            timingErrorTrace(startIndex, blockIndex) = meanTimingError;
            deltaCodeTrace(startIndex, blockIndex) = deltaCode;
            edgeCountTrace(startIndex, blockIndex) = sum(symmetricTransition);
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
        'final MM error=%.4g, dLev=[%.2f %.2f] (std=[%.3f %.3f]), ' ...
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
    all(abs(lockedPhaseCode - commonLockPhase) <= 2);

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
% pre1/post1 目标游标核验:用平均终值系数在离线 regressor 上重算归一化光标,应逼近
% 目标脉冲设定的 targetCursor(容差放宽到 0.02,兼顾块尾补零近似与信道拖尾残差)。
ffeMeanOutputCursor = reshape(ffeRegressorMatrix * ffeCoeffMean(:), 1, []);
ffeMeanNormalizedCursor = ffeMeanOutputCursor / ffeMeanOutputCursor(ffeMainRow);
ffePre1Final = ffeMeanNormalizedCursor(ffePre1Row);
ffePost1Final = ffeMeanNormalizedCursor(ffePost1Row);
ffeConstraintHeld = abs(ffePre1Final - (ffeTargetCursor - ffeTargetSkew)) <= 0.02 && ...
    abs(ffePost1Final - (ffeTargetCursor + ffeTargetSkew)) <= 0.02;

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

resultDir = fullfile(testDir, 'result', 'cdr_dlev_cdrffe_sslms_v0');
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
resultMatPath = fullfile(resultDir, 'cdr_dlev_cdrffe_sslms_v0_result.mat');

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

    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 650]);
    plot(blockAxis, timingErrorTrace.', 'LineWidth', 1.0);
    hold on;
    yline(0, 'k:');
    hold off;
    grid on;
    xlim([blockAxis(1) blockAxis(end)]);
    xlabel('CDR Block Index (64 UI per block)');
    ylabel('Mean Classic MM Timing Error per Block (code domain)');
    title('Triple-loop CDR Loop Error Transient per Start Phase');
    exportgraphics(fig, timingErrorFigurePath, 'Resolution', 150);
    close(fig);

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
        ylabel(sprintf('tap %d (offset %d)', tapIndex, ...
            cdrFfeTapOffset(tapIndex)));
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

    % 收敛后 FFE 输出 code 直方图:约 2048 个稳态样本,应呈四个 PAM4 code 聚类。
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 620]);
    histogram(histogramSamples, 'BinMethod', 'integers', ...
        'FaceColor', [0.2 0.4 0.8], 'EdgeColor', 'none');
    hold on;
    xline(levelCenter(1), 'r--', 'LineWidth', 1.0);
    xline(levelCenter(2), 'r--', 'LineWidth', 1.0);
    xline(levelCenter(3), 'r--', 'LineWidth', 1.0);
    xline(levelCenter(4), 'r--', 'LineWidth', 1.0);
    hold off;
    grid on;
    xlabel('Converged CDR FFE Output (code domain)');
    ylabel('Sample Count');
    title(sprintf(['Converged CDR FFE Output Histogram ' ...
        '(start phase %d -> locked sampling phase code %d, %d samples)'], ...
        startPhaseList(histogramPhaseIndex), ...
        lockedPhaseCode(histogramPhaseIndex), numel(histogramSamples)));
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
    yline(ffeTargetCursor, 'k--', sprintf('pre1/post1 target %.3f', ...
        ffeTargetCursor), 'LineWidth', 1.0);
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
        '3 pre + 1 main + 8 post, %s'], ffeInitMode));
    exportgraphics(fig, totalPathResponseFigurePath, 'Resolution', 150);
    close(fig);
end

result = struct();
result.CachePath = cachePath;
result.AnalysisStartUi = analysisStartUi;
result.AnalysisNumUi = analysisNumUi;
result.SamplePerSymbol = samplePerSymbol;
result.ReferencePhase = referencePhase;
result.AdcResolutionBits = adcResolutionBits;
result.AdcFullRange = [-adcFullRange adcFullRange];
result.CdrFfeCoefficients = cdrFfeCoefficients;
result.CdrFfeDesign = cdrFfeDesign;
result.CdrFfeTapOffset = cdrFfeTapOffset;
result.CdrFfeMainTapIndex = cdrFfeMainTapIndex;
result.FfeTargetCursor = ffeTargetCursor;
result.FfeTargetPulse = ffeTargetPulse;
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
result.GainScale = gainScale;
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
if ffeConsistent
    fprintf(['CDR FFE converged consistently: max coeff spread %.4g, ' ...
        'pre1=%.4f, post1=%.4f (target %.3f).\n'], max(ffeCoeffSpread), ...
        ffePre1Final, ffePost1Final, ffeTargetCursor);
else
    fprintf(['CDR FFE did NOT converge consistently: max coeff spread ' ...
        '%.4g. Retune ffe mu.\n'], max(ffeCoeffSpread));
end
if ffeConstraintHeld
    fprintf(['pre1/post1 converged to target pulse cursor %.3f under ' ...
        'target-pulse LMS.\n'], ffeTargetCursor);
else
    fprintf(['pre1/post1 did NOT reach target cursor %.3f: pre1=%.4f, ' ...
        'post1=%.4f. Retune FfeTargetCursor/ffe mu.\n'], ...
        ffeTargetCursor, ffePre1Final, ffePost1Final);
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
%   Kp/Ki 以蓝本幅度域数值表示(内部按 gainScale 折算到 code 域);StepSize 为
%   dlev 的 mu;FfeStepSize 为 CDR FFE 的 mu。Polarity/DlevPolarity 分别为 MMPD
%   与 dlev 的极性方向因子,相互独立。名值对(或单个 struct)允许调用方覆盖以重整定。

defaults = struct();
defaults.Kp = 1.8;
defaults.Ki = 0.05;
defaults.MaxDeltaCode = 12;
defaults.Polarity = 1;
defaults.StepSize = 0.3;
defaults.StepSizeSettle = 0.1;
defaults.LockWindow = 8;
defaults.LockDeltaTol = 1;
defaults.DlevSettleWindow = 16;
defaults.DlevSettleTol = 0.5;
defaults.DlevPolarity = 1;
defaults.DlevOuterInit = 48;
defaults.DlevInnerInit = 16;
% CDR FFE 环路默认参数。系数量级约 O(0.1~1),而 regressor 与误差均为 code 域
% (量级约 ±数十),故引擎梯度量级很大,捕获档 mu 需取很小值方能稳定;稳态档更小以
% 压抖动。AdaptEnableMask 固定主抽头(索引 3)为 1 作增益锚点。FfeInitMode 选择
% 方案 A(离线最优起步,默认)或方案 B(冷启动),FfeBiasScale 为方案 A 的自由抽头
% 偏差幅度(默认 0,即从离线最优系数直接起步)。方案 A 起步时眼图已张开,相位/电平
% 环可在开眼条件下捕获,再由目标脉冲 LMS 以极小 mu 精修 FFE,从而保持全相位锁定。
% FfeTargetCursor 为目标脉冲首前/首后光标 c,LMS 收敛后 pre1/post1 逼近该值。
defaults.FfeStepSize = 1e-6;
defaults.FfeStepSizeSettle = 2e-7;
defaults.FfeAdaptEnableMask = logical([1 1 0 1 1 1]);
defaults.FfeInitMode = 'planA';
defaults.FfeBiasScale = 0;
defaults.FfeTargetCursor = 0.05;
defaults.FfeTargetSkew = 0;
defaults.FfeSettleDelay = 250;
defaults.FfeReleaseMode = 'staged';
% 训练模式块数 N:默认 0 关闭(保持原决策导向行为)。设为正数(如 200)启用数据辅助
% 冷启动,需配 FfeInitMode='planB'。
defaults.FfeTrainingBlocks = 0;
defaults.SaveOutputs = true;

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

function reference = buildTargetReference(decisionBlock, pastTail, ...
    targetPulse, mainIndex)
%BUILDTARGETREFERENCE 由判决流与目标脉冲卷积构造目标脉冲 LMS 的参考流 r。
%   r_n = sum_j g(j) * d_{n-(j-mainIndex)},其中 g 为居中目标脉冲(主光标=1、首前/
%   首后光标=c),mainIndex 为主光标在 g 中的位置。块首缺的过去判决用上一处理块末尾的
%   pastTail 补齐(冷启动首块为 0);块尾缺的未来判决用 0 补齐(1~2 个样本的边界近似,
%   块速率 LMS 平均后可忽略)。返回与 decisionBlock 等长的参考流。
decisionBlock = reshape(double(decisionBlock), 1, []);
pastTail = reshape(double(pastTail), 1, []);
targetPulse = reshape(double(targetPulse), 1, []);
blockLength = numel(decisionBlock);
preCount = mainIndex - 1;
postCount = numel(targetPulse) - mainIndex;
paddedDecision = [pastTail, decisionBlock, zeros(1, postCount)];
reference = zeros(1, blockLength);
for outputIndex = 1:blockLength
    accum = 0;
    for tapIndex = 1:numel(targetPulse)
        % r_n = sum_k g(k)*d_{n-k},k = tapIndex-mainIndex;paddedDecision 前置
        % preCount 个过去判决,故 d_{n-k} 落在 paddedDecision 的下述位置。
        paddedIndex = outputIndex + preCount + mainIndex - tapIndex;
        accum = accum + targetPulse(tapIndex) * paddedDecision(paddedIndex);
    end
    reference(outputIndex) = accum;
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
