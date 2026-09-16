function result = cdr_dlev_sslms(varargin)
%CDR_DLEV_SSLMS 固定 dlev 判决电平,自适应 phase 环(SS-MMPD)与 CDR FFE(SS-LMS)的双自适应闭环。
%   本脚本原为“FFE 系数固定 + 相位环与 dlev 自适应”的双环验证;现改为:
%     - dlev 判决电平固定:外环(高电平)DLevOuter=36、内环(低电平)DLevInner=12,
%       门限 Threshold=(12+36)/2=24,全程不做自适应。这两个 code 域电平与离线聚类
%       真值(外≈36.6、内≈12.2)吻合,故固定后单判决器判决可靠。
%     - 相位环自适应:相位检测器改用 SS-MMPD(Sign-Sign Mueller-Muller,uniform
%       weight 1)。SS-MMPD 只需数据符号(0-3)与误差符号位(0/1),其 S 曲线不直接
%       依赖残留 pre1/post1 的 ISI 幅度,故 FFE 把 ISI 收敛到接近零时相位环仍稳定。
%     - FFE 系数自适应:CDR FFE 系数用符号-符号 LMS(SS-LMS,cdr_ffe_loop.updateSsLms)
%       在线调整,并且是**冷启动**:初值 [0 0 1 0 0 0](仅主抽头=1,不做任何均衡)。
%       梯度 = sign(e)*sign(X)/BlockSize,幅度恒为 O(1/N),硬件友好(只需比较器),但
%       mu 需比标准 MMSE LMS 大 ~100-300 倍。误差 errorBlock = decision - ffeOutput
%       (= -sliceError),主抽头由 AdaptEnableMask 固定为 1 作增益锚点,增量中主抽头
%       分量强制归零。
%
%   冷启动两阶段:前 FfeTrainingBlocks(默认 500)个处理块为**训练模式**,用发送端
%   golden PAM4 符号替代判决喂给 SS-MMPD 与 FFE SS-LMS——冷启动时眼图闭合、真实判决
%   不可靠,golden 是发送真值,可提供正确梯度把眼图撑开。golden 取值须扣除信道+CTLE
%   主光标整数 UI 延迟 channelMainCursorUi(实测 105 UI),否则标签与接收样本错位、
%   环路拿到去相关梯度无法收敛。dlev 固定为 12/36,故 golden {±3,±1} 直接映射到
%   {±36,±12} code。训练跑满后自动切回判决导向(**盲收敛**),同时把 FFE mu 从捕获档
%   降到稳态档。默认分析段 512512 UI(约 8000 块)= 500 块训练 + 约 7500 块盲收敛。
%
%   共享单判决器:cdr 顶层用固定 dlev 门限/电平对 FFE 输出做一次判决,得到带符号
%   判决 d 与判决误差 e = x - d,再把同一份 (d, e) 同时喂给 SS-MMPD 与 FFE SS-LMS,
%   保证两条自适应环路使用完全一致的判决。
%
%   FFE 边界按硬件做法:ADC 一次只采 64 路,由顶层维护长度 PostTap+64+PreTap 的
%   延时线拼接输入窗口后送入无状态 cdr_ffe,跨块携带边界样本。每个起始相位只创建一次
%   ADC/FFE 对象:该相位第一块冷启动缺 PostTap=3 个过去样本(丢头 3,61 有效),末块缺
%   PreTap=2 个未来样本(丢尾 2,62 有效),中间块 64 全有效。FFE SS-LMS 仅在满 64 个
%   有效样本的块更新,保证梯度分母口径正确。
%
%   分阶段释放:FFE 先冻结在离线最优系数,让 SS-MMPD 相位环借该固定 FFE 已张开的眼
%   先行捕获锁定;相位锁定后再放开 FFE 的判决导向 SS-LMS,把 ISI 缓慢收敛到最优;FFE
%   自适应足够久且相位重新锁定后,把 FFE 的 mu 从捕获档降到稳态档压低系数抖动。里程碑
%   只触发一次。
%
%   验证目标:各起始相位的相位环收敛到一致的采样相位码(稳态窗口 std 低于阈值、相位
%   间分布小);FFE 系数在各相位间收敛一致(系数扩展低于阈值);并绘制相位与 FFE 系数
%   收敛轨迹。dlev 为固定值,仅作对照记录,不参与收敛判据。

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
cdrValidationDir = fileparts(testDir);
validationDir = fileparts(cdrValidationDir);
repoRoot = fileparts(validationDir);
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

options = parseLoopOptions(varargin{:});

% CTLE 缓存位于同级目录 test_cdr 下,按相对路径解析。
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
% 分析段长度决定处理块总数 numBlocks;默认 512512 UI(约 8000 个块):配前 500 块
% golden 训练,训练后仍有约 7500 个块做盲(判决导向)自收敛长观察。512512 为 64 整数
% 倍,且 512+512512=513024 落在 PRBS20 缓存 524288 符号内。
analysisNumUi = options.AnalysisNumUi;
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

% --- 发送端 golden PAM4 符号(冷启动训练模式数据辅助用)------------------
% FFE 从 [0 0 1 0 0 0] 冷启动时眼图闭合、判决不可靠,故前 FfeTrainingBlocks 个处理块
% 用已知发送符号(golden)替代判决,把正确电平喂给 SS-MMPD 与 FFE SS-LMS 撑开眼图;
% 训练结束后切回判决导向(盲收敛)。tx_prbs20.mat 与 CTLE 缓存同源同长,pam4Symbols(k)
% 对应全局 UI k-1,电平为 {-3,-1,+1,+3}。
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
% 信道+CTLE 主光标整数 UI 延迟:接收端全局 UI u 采到的样本携带的是发送符号 UI
% (u - channelMainCursorUi) 的主光标,故训练模式取 golden 须减去该延迟(实测约 105 UI),
% 否则 golden 标签与接收样本错位、环路拿到去相关梯度无法收敛。口径与 samplePulseAtPhase 一致。
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

% --- dlev 离线参考真值(仅作对照,不参与环路)---------------------------
% 在参考相位跑一遍前端,对 FFE 输出的 code 域样本做四电平聚类,折叠成内/外环
% “真值”。真实芯片无法离线扫描,这里只用来对照固定 dlev(12/36)与真值的偏差。
referenceOutput = processOnePhase(ctleSegment, referencePhase, ...
    samplePerSymbol, adcLaneCount, adcSarPerTah, adcResolutionBits, ...
    adcFullRange, adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, adcBlockUi);
levelCenter = estimatePam4Centers(referenceOutput);
dlevInnerReference = (abs(levelCenter(2)) + abs(levelCenter(3))) / 2;
dlevOuterReference = (abs(levelCenter(1)) + abs(levelCenter(4))) / 2;

% --- 环路配置 ---------------------------------------------------------
% cdr_pi 用 NumBit = 7,使 128 个 PI code 与每 UI 的 128 个样本一一对应,
% 1 个 PI code 恰好等于 1 个样本的采样相位移动。
piNumBit = 7;
piCodeCount = 2^piNumBit;
assert(piCodeCount == samplePerSymbol, ...
    'The PI code count must equal the samples per UI.');

% 固定 dlev 判决电平(code 域):外环(高电平)、内环(低电平)与正侧门限。
dlevInner = options.DlevInner;
dlevOuter = options.DlevOuter;
dlevThreshold = (dlevInner + dlevOuter) / 2;

% SS-MMPD 相位环增益。SS-MMPD 每块输出为归一化 mean(±1/0),量纲与 code 幅度无关,
% 故直接用 Kp/Ki 作用,不再做 code 域 gainScale 折算。PdOffset 为一个相位相关的小
% 偏置(仅在 codeWrapped∈[45,116] 生效),用于打破 SS-MMPD 在整 UI 之外混叠相位的
% 多零点简并,帮助各起始相位锁到同一相位。
loopKp = options.Kp;
loopKi = options.Ki;
loopMaxDeltaCode = options.MaxDeltaCode;
loopFrequencyLimit = 4;
pdPolarity = options.Polarity;
pdOffset = options.PdOffset;

% FFE SS-LMS 两档 mu 与自适应使能掩码。捕获档大 mu 在 golden 训练期快速把冷启动
% [0 0 1 0 0 0] 的系数拉起撑开眼图,训练结束后降到稳态档小 mu 做盲收敛并压抖动。
ffeStepSize = options.FfeStepSize;
ffeStepSizeSettle = options.FfeStepSizeSettle;
ffeAdaptEnableMask = options.FfeAdaptEnableMask;
ffeSettleDelay = options.FfeSettleDelay;

% 冷启动 + 数据辅助训练:FFE 初值为 [0 0 1 0 0 0](仅主抽头=1,不做任何均衡)。前
% ffeTrainingBlocks 个处理块为训练模式(golden 替代判决),之后切盲收敛(判决导向)。
ffeTrainingBlocks = options.FfeTrainingBlocks;
trainingMode = ffeTrainingBlocks > 0;
ffeInitCoefficients = zeros(1, cdrFfeTapCount);
ffeInitCoefficients(cdrFfeMainTapIndex) = 1;

lockWindow = options.LockWindow;
lockDeltaTol = options.LockDeltaTol;
saveOutputs = options.SaveOutputs;

% 块调度。分析段两侧各留整数 UI 保护带,保证 PI 在捕获期 UI-slip 不会采到缓存之外。
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
ffeCoeffTrace = zeros(numStartPhase, numBlocks, cdrFfeTapCount);
ffeSettleBlockTrace = zeros(1, numStartPhase);
lockedPhaseCode = zeros(1, numStartPhase);
lockedFlag = false(1, numStartPhase);

settleBlocks = 30;
% 在静态零 ppm 缓存波形上,bang-bang SS-MMPD 环稳态无法完全静止:会在真正过零点
% 附近 +/-1~+/-2 code 极限环抖动。锁定判据因此接受稳态窗口 std 最大 1.5 code 的
% 固有抖动底,以及各相位间最大 2 code 的分布,而非要求相位完全冻结。
lockStdTolerance = 1.5;
% FFE 一致性判据:各起始相位收敛到的每个自适应抽头系数扩展需低于此阈值。冷启动 +
% 500 块 golden 训练 + 约 7500 块盲收敛下,各相位锁到同一相位(spread 0),FFE 系数
% 扩展实测约 0.0023;取 0.01 兼顾 SS-LMS 固有稳态失调(misadjustment)留裕量。
ffeConsistencyTolerance = 0.01;

for startIndex = 1:numStartPhase
    startPhase = startPhaseList(startIndex);

    phaseInterpolator = cdr_pi(piNumBit, samplePerSymbol);
    phaseInterpolator.resetNonideal();
    phaseInterpolator.setCode(startPhase);
    loopFilter = cdr_loop(loopKp, loopKi, ...
        -loopFrequencyLimit, loopFrequencyLimit, loopMaxDeltaCode);
    loopFilter.resetState();

    % FFE 从 [0 0 1 0 0 0] 冷启动;训练期由 golden 数据辅助 SS-LMS 撑开眼图,训练后判决导向。
    ffeModel = cdr_ffe(ffeInitCoefficients, cdrFfePreTapCount);
    ffeLoop = cdr_ffe_loop(ffeStepSize, cdrFfeTapCount, ...
        cdrFfeMainTapIndex, adcBlockUi, ffeAdaptEnableMask);

    % 两档 mu 换挡状态。冷启动训练模式下 FFE 从第 1 块起就由 golden 数据辅助自适应
    % (ffeReleased=true),训练结束(blockIndex>=ffeTrainingBlocks)时一次性把 FFE mu 从捕获
    % 档降到稳态档并切盲收敛;只降一次。非训练模式(FfeTrainingBlocks=0)退化为纯判决导向
    % 冷启动,相位连续 lockWindow 块锁定后再降档(眼图可能闭合、通常锁不住,仅作对照)。
    lockCounter = 0;
    ffeReleased = true;
    settleBlock = 0;
    settleDone = false;

    % 每个起始相位只建一次 ADC/FFE 对象;FFE 无内部缓存,跨块边界样本由顶层延时线携带。
    adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
        adcResolutionBits, adcSarPerTah, samplePerSymbol);
    adcModel.setInputMargin(0);

    % cdr_ffe 无跨块缓存:要算第 k 块的均衡输出,顶层须提供 [PostTap 过去,第 k 块 64
    % 样本, PreTap 未来] 的完整窗口,而 PreTap 个未来样本要到第 k+1 块采样后才拿得到,
    % 故采样与处理天然错开一个块。pendingCentered 暂存待处理块整块 code、pendingPast
    % 暂存其 PostTap 个过去样本、pendingHasPast 标记冷启动首块,并对齐相位上下文;循环
    % 多跑一次(numBlocks+1)以在无未来样本(尾 PreTap 无效)时处理最后缓存的第 numBlocks 块。
    havePending = false;
    pendingHasPast = false;
    pendingCentered = zeros(1, adcBlockUi);
    pendingPast = zeros(1, cdrFfePostTapCount);
    pendingGolden = zeros(1, adcBlockUi);
    pendingCodeWrapped = 0;
    pendingUiSlip = 0;
    pendingBlockIndex = 0;

    for sampleBlockIndex = 1:numBlocks + 1
        if sampleBlockIndex <= numBlocks
            % 采样第 sampleBlockIndex 块:用当前 PI 相位取样并量化为 code。
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
            % 训练模式:取本采样块对应的 golden 发送符号。块首采样 UI 为
            % analysisStartUi+firstUi(0 基),其主光标来自发送符号
            % txPam4Symbols(analysisStartUi+firstUi-channelMainCursorUi+1);codeWrapped 只是
            % 子 UI 采样相位,不改变整数符号索引。必须扣除主光标延迟,否则 golden 与接收样本错位。
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
            % 数据流结束:无下一块提供未来样本,末块尾部 PreTap 个输出无效。
            sampleCodeWrapped = 0;
            sampleUiSlip = 0;
            haveFuture = false;
            futureSamples = zeros(1, cdrFfePreTapCount);
        end

        if havePending
            % 顶层拼接完整输入窗口 [PostTap 过去, 64 目标块, PreTap 未来],送入无状态
            % cdr_ffe 计算该目标块的 64 个均衡输出与 64x6 regressor。
            inputWindow = [pendingPast, pendingCentered, futureSamples];
            [blockOutput, blockRegressor] = ffeModel.processBlock(inputWindow);

            % 边界有效性:冷启动首块缺过去样本(头 PostTap 无效);数据流末块缺未来样本
            % (尾 PreTap 无效);中间块 64 全有效。
            blockValid = true(1, adcBlockUi);
            if ~pendingHasPast
                blockValid(1:cdrFfePostTapCount) = false;
            end
            if ~haveFuture
                blockValid(end - cdrFfePreTapCount + 1:end) = false;
            end
            ffeOutput = blockOutput(blockValid);

            % 时延对齐:把本次均衡输出对齐回它被采样时的相位上下文。
            codeWrapped = pendingCodeWrapped;
            uiSlip = pendingUiSlip;
            blockIndex = pendingBlockIndex;

            % 共享单判决器:用固定 dlev 门限/电平在 code 域判决,产出带符号判决 d 与判决
            % 误差 e = x - d,供 SS-MMPD 与 FFE SS-LMS 共用。
            [decision, sliceError] = sliceCodePam4(ffeOutput, ...
                dlevInner, dlevOuter, dlevThreshold);

            % 训练模式数据辅助:前 ffeTrainingBlocks 个处理块,用 golden 发送符号替代
            % 判决。FFE 冷启动 [0 0 1 0 0 0] 时眼图闭合、真实判决不可靠,而 golden 是发送
            % 真值,SS-MMPD 与 FFE SS-LMS 由此拿到正确梯度把眼图撑开。dlev 固定为 12/36,
            % 故 golden {±3,±1} 直接按该固定电平映射到 code:{±dlevOuter, ±dlevInner};
            % 误差 e = ffeOutput - decision 与判决导向同口径。训练结束后本分支关闭,
            % decision/sliceError 回到真实判决器输出,即进入盲收敛。
            trainingActive = trainingMode && blockIndex <= ffeTrainingBlocks;
            if trainingActive
                goldenValid = pendingGolden(blockValid);
                goldenIsOuter = abs(goldenValid) >= 2;
                goldenMagnitude = dlevInner + ...
                    (dlevOuter - dlevInner) .* goldenIsOuter;
                decision = sign(goldenValid) .* goldenMagnitude;
                sliceError = ffeOutput - decision;
            end

            % --- SS-MMPD 相位检测(纯 code 域,uniform weight 1)-----------------
            % SS-MMPD 只需数据符号(0-3)与误差符号位(0/1),两者都从共享 (d, e) 派生:
            % 固定 dlev 电平 {-Outer,-Inner,+Inner,+Outer} 直接映射到 {0,1,2,3};误差符号
            % 位取 sliceError>=0。
            ssIsPositive = decision >= 0;
            ssIsOuter = abs(decision) >= dlevThreshold;
            ssDataSymbol = double(ssIsPositive) * 2 + ...
                double(ssIsPositive == ssIsOuter);
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

            % 两档 mu 换挡。训练模式:训练跑满 ffeTrainingBlocks 个块即一次性把 FFE mu 从
            % 捕获档降到稳态档,同时(由 trainingActive 自动)切回判决导向盲收敛,只降一次。
            % 非训练模式:退化为纯判决导向冷启动,相位连续 lockWindow 块锁定后再降档。
            if abs(deltaCode) <= lockDeltaTol
                lockCounter = lockCounter + 1;
            else
                lockCounter = 0;
            end
            if ~settleDone
                if trainingMode
                    if blockIndex >= ffeTrainingBlocks
                        ffeLoop.setStepSize(ffeStepSizeSettle);
                        settleBlock = blockIndex;
                        settleDone = true;
                    end
                else
                    if lockCounter >= lockWindow
                        ffeLoop.setStepSize(ffeStepSizeSettle);
                        settleBlock = blockIndex;
                        settleDone = true;
                    end
                end
            end

            % CDR FFE 块速率 SS-LMS 更新:满 64 有效样本的块才更新(梯度分母口径正确)。
            % 梯度 = sign(e)*sign(X)/N;误差 errorBlock = decision - ffeOutput(= -sliceError,
            % 即“期望 - 输出”)。训练期 decision 已被 golden 覆盖,故同一行代码即完成
            % “数据辅助 -> 盲收敛”的切换。主抽头由掩码固定,增量里强制归零作增益锚点。
            if ffeReleased && numel(ffeOutput) == adcBlockUi
                errorBlock = decision - ffeOutput;
                rawDelta = ffeLoop.updateSsLms(blockRegressor, errorBlock);
                rawDelta(cdrFfeMainTapIndex) = 0;
                ffeModel.applyCoefficientDelta(rawDelta);
            end

            phaseCodeTrace(startIndex, blockIndex) = codeWrapped;
            uiSlipTrace(startIndex, blockIndex) = uiSlip;
            timingErrorTrace(startIndex, blockIndex) = meanPhaseError;
            deltaCodeTrace(startIndex, blockIndex) = deltaCode;
            edgeCountTrace(startIndex, blockIndex) = sum(validTransition);
            unwrappedPhaseTrace(startIndex, blockIndex) = ...
                uiSlip * samplePerSymbol + codeWrapped;
            ffeCoeffTrace(startIndex, blockIndex, :) = ...
                reshape(ffeModel.Coefficients, 1, 1, cdrFfeTapCount);
        end

        % 登记本次采样的整块 code、其 PostTap 个过去样本与相位上下文,供下一次迭代拼接。
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

    ffeSettleBlockTrace(startIndex) = settleBlock;
    settleWindow = phaseCodeTrace(startIndex, end - settleBlocks + 1:end);
    lockedPhaseCode(startIndex) = round(mean(settleWindow));
    lockedFlag(startIndex) = std(settleWindow) <= lockStdTolerance;

    finalCoeff = squeeze(ffeCoeffTrace(startIndex, end, :)).';
    fprintf(['Start phase %3d/%d: locked=%d, steady phase code=%d, ' ...
        'final MM error=%.4g, blind@blk %d, pre1=%.4f post1=%.4f.\n'], ...
        startPhase, samplePerSymbol, lockedFlag(startIndex), ...
        lockedPhaseCode(startIndex), timingErrorTrace(startIndex, end), ...
        settleBlock, finalCoeff(cdrFfeMainTapIndex - 1), ...
        finalCoeff(cdrFfeMainTapIndex + 1));
end

commonLockPhase = round(median(lockedPhaseCode(lockedFlag)));
phaseSpread = max(lockedPhaseCode(lockedFlag)) - ...
    min(lockedPhaseCode(lockedFlag));
allPhaseLock = all(lockedFlag) && ...
    all(abs(lockedPhaseCode - commonLockPhase) <= 2);

% FFE 一致性:各起始相位收敛到的每个抽头系数应彼此接近。
ffeFinalCoeff = squeeze(ffeCoeffTrace(:, end, :));
if numStartPhase == 1
    ffeFinalCoeff = reshape(ffeFinalCoeff, 1, cdrFfeTapCount);
end
ffeCoeffSpread = max(ffeFinalCoeff, [], 1) - min(ffeFinalCoeff, [], 1);
ffeMaxCoeffSpread = max(ffeCoeffSpread(ffeAdaptEnableMask));
ffeConsistent = ffeMaxCoeffSpread <= ffeConsistencyTolerance;

% 收敛后 FFE 归一化 pre1/post1(相对主抽头),衡量在线 SS-LMS 的 ISI 补偿。
ffePre1Final = mean(ffeFinalCoeff(:, cdrFfeMainTapIndex - 1));
ffePost1Final = mean(ffeFinalCoeff(:, cdrFfeMainTapIndex + 1));

resultDir = fullfile(testDir, 'result', 'cdr_dlev_sslms');
if saveOutputs && ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

blockAxis = 1:numBlocks;
convergenceFigurePath = fullfile(resultDir, 'cdr_phase_convergence.png');
timingErrorFigurePath = fullfile(resultDir, 'cdr_block_timing_error.png');
lockSummaryFigurePath = fullfile(resultDir, ...
    'cdr_locked_phase_vs_start_phase.png');
ffeConvergenceFigurePath = fullfile(resultDir, 'ffe_coeff_convergence.png');
resultMatPath = fullfile(resultDir, 'cdr_dlev_sslms_result.mat');

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
    title(sprintf(['SS-MMPD Phase Convergence (fixed dlev, adaptive FFE): ' ...
        '%d start phases, Kp=%.3g, Ki=%.3g'], numStartPhase, loopKp, loopKi));
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
    ylabel('Mean SS-MMPD Phase Error per Block');
    title('SS-MMPD Loop Error Transient per Start Phase');
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
    hold on;
    tapLabels = cell(1, cdrFfeTapCount);
    for tapIndex = 1:cdrFfeTapCount
        plot(blockAxis, squeeze(ffeCoeffTrace(:, :, tapIndex)).', ...
            'LineWidth', 0.8);
        tapLabels{tapIndex} = sprintf('tap %+d UI', cdrFfeTapOffset(tapIndex));
    end
    hold off;
    grid on;
    xlim([blockAxis(1) blockAxis(end)]);
    xlabel('CDR Block Index (64 UI per block)');
    ylabel('CDR FFE Coefficient (SS-LMS)');
    title(sprintf(['CDR FFE SS-LMS Convergence: mu=%.4g->%.4g, ' ...
        'max coeff spread=%.4g'], ffeStepSize, ffeStepSizeSettle, ...
        ffeMaxCoeffSpread));
    exportgraphics(fig, ffeConvergenceFigurePath, 'Resolution', 150);
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
result.CdrFfeInitCoefficients = ffeInitCoefficients;
result.CdrFfeOfflineReference = cdrFfeCoefficients;
result.ChannelMainCursorUi = channelMainCursorUi;
result.FfeTrainingBlocks = ffeTrainingBlocks;
result.TrainingMode = trainingMode;
result.CdrFfeDesign = cdrFfeDesign;
result.CdrFfeTapOffset = cdrFfeTapOffset;
result.CdrFfeMainTapIndex = cdrFfeMainTapIndex;
result.LevelCenter = levelCenter;
result.DlevInner = dlevInner;
result.DlevOuter = dlevOuter;
result.DlevThreshold = dlevThreshold;
result.DlevInnerReference = dlevInnerReference;
result.DlevOuterReference = dlevOuterReference;
result.LoopKp = loopKp;
result.LoopKi = loopKi;
result.LoopMaxDeltaCode = loopMaxDeltaCode;
result.LoopFrequencyLimit = loopFrequencyLimit;
result.PdPolarity = pdPolarity;
result.PdOffset = pdOffset;
result.PdType = 'ss-mmpd';
result.FfeStepSize = ffeStepSize;
result.FfeStepSizeSettle = ffeStepSizeSettle;
result.FfeAdaptEnableMask = ffeAdaptEnableMask;
result.FfeSettleDelay = ffeSettleDelay;
result.FfeCostMode = 'coldstart-golden-train-then-blind-sslms';
result.LockWindow = lockWindow;
result.LockDeltaTol = lockDeltaTol;
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
result.FfeCoeffTrace = ffeCoeffTrace;
result.FfeSettleBlockTrace = ffeSettleBlockTrace;
result.SettleBlocks = settleBlocks;
result.LockStdTolerance = lockStdTolerance;
result.FfeConsistencyTolerance = ffeConsistencyTolerance;
result.LockedPhaseCode = lockedPhaseCode;
result.LockedFlag = lockedFlag;
result.CommonLockPhase = commonLockPhase;
result.PhaseSpread = phaseSpread;
result.AllPhaseLock = allPhaseLock;
result.FfeFinalCoeff = ffeFinalCoeff;
result.FfeCoeffSpread = ffeCoeffSpread;
result.FfeMaxCoeffSpread = ffeMaxCoeffSpread;
result.FfeConsistent = ffeConsistent;
result.FfePre1Final = ffePre1Final;
result.FfePost1Final = ffePost1Final;
result.ConvergenceFigurePath = convergenceFigurePath;
result.TimingErrorFigurePath = timingErrorFigurePath;
result.LockSummaryFigurePath = lockSummaryFigurePath;
result.FfeConvergenceFigurePath = ffeConvergenceFigurePath;
result.ResultMatPath = resultMatPath;
if saveOutputs
    save(resultMatPath, 'result', '-v7.3');
end

fprintf('\n');
if allPhaseLock
    fprintf(['CDR SS-MMPD phase loop passed: all %d start phases locked to ' ...
        'code %d (spread %d code, ref phase %d).\n'], numStartPhase, ...
        commonLockPhase, phaseSpread, referencePhase);
else
    fprintf(['CDR SS-MMPD phase loop did NOT reach full-phase lock: %d/%d ' ...
        'phases stable, spread %d code. Retune Kp/Ki/PdOffset/polarity.\n'], ...
        sum(lockedFlag), numStartPhase, phaseSpread);
end
if ffeConsistent
    fprintf(['CDR FFE (SS-LMS) converged consistently: max coeff spread ' ...
        '%.4g, mean pre1=%.4f post1=%.4f.\n'], ffeMaxCoeffSpread, ...
        ffePre1Final, ffePost1Final);
else
    fprintf(['CDR FFE (SS-LMS) did NOT converge consistently: max coeff ' ...
        'spread %.4g. Retune FfeStepSize/FfeStepSizeSettle/FfeSettleDelay.\n'], ...
        ffeMaxCoeffSpread);
end
fprintf(['Fixed dlev: inner(low)=%.2f, outer(high)=%.2f (offline truth ' ...
    'inner=%.2f, outer=%.2f).\n'], dlevInner, dlevOuter, ...
    dlevInnerReference, dlevOuterReference);
fprintf('Results saved to %s.\n', resultDir);
end

function options = parseLoopOptions(varargin)
%PARSELOOPOPTIONS 解析 SS-MMPD 相位环增益、FFE SS-LMS mu、固定 dlev 与运行开关。
%   Kp/Ki 直接作用于 SS-MMPD 归一化输出(无 gainScale 折算);PdOffset 为相位相关
%   小偏置;FfeStepSize/FfeStepSizeSettle 为 FFE SS-LMS 两档 mu;DlevInner/DlevOuter
%   为固定判决电平(低/高);Polarity 为 SS-MMPD 极性方向因子。名值对(或单个 struct)
%   允许调用方覆盖以便重整定。

defaults = struct();
% SS-MMPD 相位环默认增益,直接作用于归一化 mean(±1/0) 输出。沿用 v3 SS-MMPD 整定。
defaults.Kp = 8.0;
defaults.Ki = 0.06;
defaults.PdOffset = -0.05;
defaults.MaxDeltaCode = 12;
defaults.Polarity = 1;
defaults.LockWindow = 8;
defaults.LockDeltaTol = 1;
% 固定 dlev 判决电平(code 域):低电平(内环)= 12,高电平(外环)= 36。与离线聚类
% 真值(内≈12.2、外≈36.6)吻合,固定后单判决器判决可靠。
defaults.DlevInner = 12;
defaults.DlevOuter = 36;
% CDR FFE 环路默认参数(Sign-Sign LMS)。SS-LMS 梯度 = sign(e)*sign(X)/N,幅度恒为
% O(1/N),故 mu 需比标准 MMSE LMS 大 ~100-300 倍。AdaptEnableMask 固定主抽头(索引 3)
% 为增益锚点。FFE 从 [0 0 1 0 0 0] 冷启动:前 FfeTrainingBlocks 块用 golden 数据辅助,
% 捕获档 mu=0.02 迅速把系数拉起撑开眼图;训练结束切盲收敛并降到稳态档 mu=0.001。
% 该组合沿用同目录 planB(v3)已验证的 SS-LMS 冷启动整定。
defaults.FfeStepSize = 0.02;
defaults.FfeStepSizeSettle = 0.001;
defaults.FfeAdaptEnableMask = logical([1 1 0 1 1 1]);
defaults.FfeSettleDelay = 500;
% 训练块数:前 N 个处理块用 TX golden 符号做数据辅助自适应,之后切判决导向盲收敛。
% 设为 0 可关闭训练,退回纯判决导向冷启动(闭眼期判决不可靠,通常锁不住,仅作对照)。
defaults.FfeTrainingBlocks = 500;
% 分析段 UI 数,决定处理块总数。512512 UI -> 约 8000 块:500 块训练 + 约 7500 块盲收敛。
defaults.AnalysisNumUi = 512512;
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

function [decision, sliceError] = sliceCodePam4(sample, ...
    dLevInner, dLevOuter, threshold)
%SLICECODEPAM4 用固定 dlev 门限/电平做一次 PAM4 判决(单判决器)。
%   电平为 {-dLevOuter, -dLevInner, +dLevInner, +dLevOuter},门限为
%   {-threshold, 0, +threshold}。|x| >= threshold 判外电平,否则内电平;符号
%   由 x 的正负决定(x == 0 归正)。返回带符号判决 d 与判决误差 e = x - d。
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
%   首尾补齐 PostTap/PreTap 个零构成完整输入窗口一次性送入 FFE;窗口首 PostTap
%   个与尾 PreTap 个输出因边界补零无效,予以剔除(离线聚类真值对少量边界样本不敏感)。

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
%OPTIMIZECDRFFE 约束 pre1/post1 为 0.05 并最小化其余 ISI(FFE 暖启动系数)。

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
