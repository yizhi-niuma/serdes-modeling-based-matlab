function result = cdr_dlev_sslms(varargin)
%CDR_DLEV_SSLMS 在 MMPD CDR 单环基础上叠加 dlev 判决电平符号-符号 LMS 自适应的双环闭环。
%   本脚本以 cdr_dlev_lms 为蓝本(结构一致),唯一区别是 dlev 环路用符号-符号
%   LMS(SS-LMS)替代全精度 LMS:更新项取 sign(sign(d).*e),每样本只贡献 ±1,
%   对应 RTL 的 bang-bang 累加,硬件实现最省(无乘法器、无宽位累加)。
%   MMPD CDR 环路组成从第 0 块起并发运行的双环:
%
%   1) 方案 B(纯 code 域):去掉蓝本里一次性标定的 codeToSymbol 幅度映射,
%      全程在 CDR FFE 输出的 code 域工作。判决电平不再折算成 ±1/±3 幅度,
%      而是由 dlev 环路直接在 code 域维护(内环 |±1|、外环 |±3| 的 code 值)。
%      真实芯片进入 DSP 后不存在电平概念,这与硬件一致。
%
%   2) 单判决器:cdr 顶层用 dlev 当前维护的门限/电平对 FFE 输出做一次判决,
%      得到带符号判决 d 与判决误差 e = x - d,再把同一份 (d, e) 同时喂给
%      MMPD(算 Mueller-Muller 定时误差)与 dlev(算符号-符号 LMS 更新),保证
%      两条环路使用完全一致的判决。
%
%   3) FFE 边界按硬件做法:ADC 一次只采 64 路,由顶层维护长度 PostTap+64+PreTap
%      的延时线拼接输入窗口后送入无状态 FFE,跨块携带边界样本。每个起始相位只
%      创建一次 ADC/FFE 对象,于是该相位第一块冷启动缺 PostTap=3 个过去样本(丢头
%      3,61 有效),末块缺 PreTap=2 个未来样本(丢尾 2,62 有效),中间块 64 全有效。
%
%   4) dlev 初值由参考相位处 FFE 输出的 code 聚类中心离线折叠得到;mu、Kp、Ki
%      均做成名值可调参数,便于按仿真结果微调;dlev 极性与 CDR 的 pdPolarity
%      相互独立,需各自正确以保证收敛。SS-LMS 每样本梯度只有 ±1,幅度远小于
%      全精度 LMS 的 |x|-|d|,故捕获档 mu 需相应调大才能在相同 block 数内收敛。
%
%   主闭环用无跨块缓存的 cdr_ffe:由顶层维护延时线拼接
%   [PostTap 过去, 64 目标块, PreTap 未来] 窗口后送入,FFE 只算该目标块输出;因
%   PreTap 未来样本要到下一块采样后才有,采样与处理错开一个块并做时延对齐,循环
%   多跑一次以处理末块(尾 PreTap 无效)。processOnePhase 的离线标定同样调用
%   cdr_ffe,只是把整段码流一次拼成完整窗口送入。
%
%   验证目标在蓝本"全相位锁定到 ~22、spread<=2"之外,新增 dlev 判据:各起始
%   相位收敛到一致的 code 电平、稳态窗口内 DLevInner/DLevOuter 的 std 低于阈值,
%   并绘制 dlev 收敛轨迹。

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
cdrValidationDir = fileparts(testDir);
validationDir = fileparts(cdrValidationDir);
repoRoot = fileparts(validationDir);
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

% 新脚本位于 test_cdr_dlev,CTLE 缓存仍在同级目录 test_cdr 下,按相对路径解析。
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
analysisNumUi = 8192 * 8;
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

adcLaneCount = 64;
adcSarPerTah = 8;
adcResolutionBits = 7;
adcFullRange = 4;
adcZeroCode = 2^(adcResolutionBits - 1);
referencePhase = 19;
cdrFfeTapOffset = -2:3;
cdrFfePreTapCount = 2;
cdrFfePostTapCount = numel(cdrFfeTapOffset) - cdrFfePreTapCount - 1;
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

% --- dlev 参考真值离线标定(仅用于验证,不作为初值)-------------------
% 在参考相位跑一遍前端,得到 FFE 输出的 code 域样本,用 KMeans 式聚类估计
% 四个电平的 code 聚类中心,折叠成内/外环“正确值”。真实芯片无法做这种离线
% 扫描,所以这里得到的 dlevInnerReference/dlevOuterReference 只作为收敛后
% 的对照真值(ground truth),既不参与环路初始化,也不参与增益折算。
referenceOutput = processOnePhase(ctleSegment, referencePhase, ...
    samplePerSymbol, adcLaneCount, adcSarPerTah, adcResolutionBits, ...
    adcFullRange, adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, adcBlockUi);
levelCenter = estimatePam4Centers(referenceOutput);
dlevInnerReference = (abs(levelCenter(2)) + abs(levelCenter(3))) / 2;
dlevOuterReference = (abs(levelCenter(1)) + abs(levelCenter(4))) / 2;

% --- CDR 闭环配置 -----------------------------------------------------
% cdr_pi 用 NumBit = 7,使 128 个 PI code 与每 UI 的 128 个样本一一对应,
% 1 个 PI code 恰好等于 1 个样本的采样相位移动,与蓝本一致。
piNumBit = 7;
piCodeCount = 2^piNumBit;
assert(piCodeCount == samplePerSymbol, ...
    'The PI code count must equal the samples per UI.');

% 环路增益。蓝本的 Kp/Ki 是在幅度域(判决 ±3)整定的;方案 B 在 code 域,
% 判决幅度约放大 dlevOuterNominal/3 倍,MMPD 定时误差按其平方放大。这里的
% dlevOuterNominal 是芯片上电即可知的“设计标称”(由 ADC 满量程与 AGC 目标
% 决定),不依赖任何离线扫描;把蓝本增益乘以 (3/dlevOuterNominal)^2 折算到
% code 域作为默认起点,既复用已验证的环路动态,又保持 Kp/Ki 旋钮的直观量纲。
% mu 给一个起步值,与 Kp/Ki 一样做成名值可调,后续按仿真结果微调。
options = parseLoopOptions(varargin{:});

% dlev 初值:采用硬件可实现的标称值,而非离线真值。真实芯片上电时只知道
% ADC 满量程与 AGC 的外眼目标(PAM4 名义 ±1/±3,内外幅度比 1:3),据此给出
% 外环标称 dlevOuterNominal 与内环 dlevOuterNominal/3,再由 dlev 环路在线
% 收敛到真实电平。DlevInnerInit/DlevOuterInit 允许调用方覆盖标称起点。
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

% 块调度。分析段两侧各留整数 UI 的保护带,保证 PI 在捕获期 UI-slip 不会采到
% 缓存波形之外。
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
lockedPhaseCode = zeros(1, numStartPhase);
lockedFlag = false(1, numStartPhase);

settleBlocks = 30;
% 在静态零 ppm 缓存波形上,bang-bang MMPD 环稳态无法完全静止:会在真正过零点
% 附近 +/-1~+/-2 code 极限环抖动。锁定判据因此接受稳态窗口 std 最大 1.5 code
% 的固有抖动底,以及各相位间最大 2 code 的分布,而非要求相位完全冻结。
lockStdTolerance = 1.5;
% dlev 判据:稳态窗口内两环 code 电平的 std 需低于此阈值(code 单位),用于
% 判断 dlev 是否收敛稳定。
dlevSettleStdTolerance = 1.0;

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

    % 两档 mu 换挡状态。lockCounter 累计连续满足 |deltaCode|<=lockDeltaTol 的
    % 块数,达到 lockWindow 即判定相位环锁定;settleDone 保证只降档一次。
    lockCounter = 0;
    settleDone = false;

    % 每个起始相位只建一次 ADC/FFE 对象;FFE 无内部缓存,跨块边界样本由顶层
    % 延时线携带。故本相位第一块冷启动缺 PostTap=3 个过去样本(丢头 3,61 有效),
    % 末块缺 PreTap=2 个未来样本(丢尾 2,62 有效),中间块 64 个全有效。
    adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
        adcResolutionBits, adcSarPerTah, samplePerSymbol);
    adcModel.setInputMargin(0);
    ffeModel = cdr_ffe(cdrFfeCoefficients, cdrFfePreTapCount);

    % cdr_ffe 无跨块缓存:要算第 k 块的均衡输出,顶层须提供 [PostTap 过去,
    % 第 k 块 64 样本, PreTap 未来] 的完整窗口,而 PreTap 个未来样本要到第 k+1
    % 块采样后才拿得到,故采样与处理天然错开一个块。这里用 pendingCentered 暂存
    % 待处理块的整块 code、pendingPast 暂存其 PostTap 个过去样本(上一块尾部)、
    % pendingHasPast 标记是否为冷启动首块,并把相位上下文
    % (codeWrapped/uiSlip/blockIndex)一并对齐;循环多跑一次(numBlocks+1)以在无
    % 未来样本(尾 PreTap 无效)的情况下处理最后缓存的第 numBlocks 块。
    havePending = false;
    pendingHasPast = false;
    pendingCentered = zeros(1, adcBlockUi);
    pendingPast = zeros(1, cdrFfePostTapCount);
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

            % 顶层只做采样与量化,不再让 FFE 内部缓存。取本块开头 PreTap 个 code
            % 作为下一次迭代处理待处理块时所需的未来样本。
            physicalCode = adcModel.convertOneBlockFast(blockWaveform, 1);
            centeredCode = double(physicalCode(laneToTimeOrder)) - adcZeroCode;
            haveFuture = true;
            futureSamples = centeredCode(1:cdrFfePreTapCount);
        else
            % 数据流结束:无下一块提供未来样本,末块尾部 PreTap 个输出无效。
            sampleCodeWrapped = 0;
            sampleUiSlip = 0;
            haveFuture = false;
            futureSamples = zeros(1, cdrFfePreTapCount);
        end

        % 首块采样时尚无待处理块,只登记上下文后进入下一次迭代;之后每次迭代
        % 处理上一块——它此刻才凑齐 PreTap 个未来样本(来自本块开头),故与采样
        % 天然错开一个块,忠实反映并行 FFE 需跨块边界样本的流水结构。
        if havePending
            % 顶层拼接完整输入窗口 [PostTap 过去, 64 目标块, PreTap 未来],送入
            % 无状态 cdr_ffe 只计算该目标块的 64 个均衡输出。
            inputWindow = [pendingPast, pendingCentered, futureSamples];
            [blockOutput, ~] = ffeModel.processBlock(inputWindow);

            % 边界有效性:冷启动首块缺过去样本(头 PostTap 个输出无效);数据流末
            % 块缺未来样本(尾 PreTap 个输出无效);中间块 64 个全有效。
            blockValid = true(1, adcBlockUi);
            if ~pendingHasPast
                blockValid(1:cdrFfePostTapCount) = false;
            end
            if ~haveFuture
                blockValid(end - cdrFfePreTapCount + 1:end) = false;
            end
            ffeOutput = blockOutput(blockValid);

            % 时延对齐:把本次均衡输出对齐回它被采样时的相位上下文,使判决/MMPD/
            % dlev 更新与轨迹记录都落在正确的块上。
            codeWrapped = pendingCodeWrapped;
            uiSlip = pendingUiSlip;
            blockIndex = pendingBlockIndex;

            % 单判决器:用 dlev 当前维护的门限/电平在 code 域判决,产出带符号判决
            % d 与判决误差 e = x - d,供 MMPD 与 dlev 共用。判决先于更新,保证用
            % 的是本块进入时的电平估计(因果顺序)。
            [decision, sliceError] = sliceCodePam4(ffeOutput, ...
                dlevLoop.DLevInner, dlevLoop.DLevOuter, dlevLoop.Threshold);

            % 经典 Mueller-Muller 定时误差,直接用共享的 (d, e) 在 code 域计算。
            timingError = decision(1:end - 1) .* sliceError(2:end) - ...
                decision(2:end) .* sliceError(1:end - 1);
            % 边沿过滤:仅在对称 PAM4 跳变(d[n] == -d[n-1])上累加 MM 更新,
            % 与蓝本一致,抑制 ISI 较重的内电平跳变。
            symmetricTransition = decision(2:end) == -decision(1:end - 1);
            if any(symmetricTransition)
                meanTimingError = mean(timingError(symmetricTransition));
            else
                meanTimingError = 0;
            end

            phaseError = pdPolarity * meanTimingError;
            deltaCode = loopFilter.update(phaseError);
            phaseInterpolator.update(deltaCode);

            % 运行时相位环锁定检测与 mu 换挡。deltaCode 是环路滤波器的直接输出,
            % 相位拉到位后自然趋零;连续 lockWindow 块 |deltaCode|<=lockDeltaTol 即
            % 判定相位环真锁定。dlev 必须先启动且全程保持捕获档大 mu(最大环路带宽)
            % 跟着移动的采样相位一路追真值,只有 CDR 真收敛后才把 dlev 降到稳态档小
            % mu 压抖动,只降一次。不设强制降档兜底:过早冻结会把 dlev 锁死在尚未
            % 收敛相位对应的错电平上,导致门限错误与假锁。
            if ~settleDone
                if abs(deltaCode) <= lockDeltaTol
                    lockCounter = lockCounter + 1;
                else
                    lockCounter = 0;
                end
                % dlev 稳定判据:SS-LMS 每样本梯度仅 ±1,从硬件标称初值下行到真值比
                % 全精度 LMS 慢得多,相位环往往先于 dlev 收敛而锁定。若仅凭相位锁定就
                % 降档,会把仍在下行途中的 dlev 冻结在偏高的错电平上,造成门限偏移与
                % 远端相位假锁。故降档需同时满足:相位环锁定,且 dlev 外环在最近
                % dlevSettleWindow 块内的漂移不超过 dlevSettleTol,即 dlev 也已收敛,
                % 严格对应“CDR 收敛后再降 dlev 环路带宽”的启动次序。
                dlevSettled = blockIndex > dlevSettleWindow && ...
                    abs(dlevLoop.DLevOuter - ...
                    dlevOuterTrace(startIndex, blockIndex - dlevSettleWindow)) ...
                    <= dlevSettleTol;
                if lockCounter >= lockWindow && dlevSettled
                    dlevLoop.setStepSize(dlevStepSizeSettle);
                    settleDone = true;
                end
            end

            % dlev 符号-符号 LMS 更新:BlockSize 固定为 64,只有满 64 个有效样本的块
            % 才更新(即跳过每相位第一块的 61 样本冷启动块与末尾 62 样本尾块),保证梯度
            % 分母口径正确。SS-LMS 更新项取 sign(sign(d).*e),每样本仅 ±1 贡献,对应
            % RTL bang-bang。
            if numel(ffeOutput) == adcBlockUi
                dlevLoop.dlevSsLms(decision, sliceError);
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
        end

        % 登记本次采样的整块 code、其 PostTap 个过去样本(取自上一待处理块的尾
        % 部)与相位上下文,供下一次迭代拼接窗口并做时延对齐使用。
        if sampleBlockIndex <= numBlocks
            if havePending
                pendingPast = pendingCentered(end - cdrFfePostTapCount + 1:end);
                pendingHasPast = true;
            else
                pendingPast = zeros(1, cdrFfePostTapCount);
                pendingHasPast = false;
            end
            pendingCentered = centeredCode;
            pendingCodeWrapped = sampleCodeWrapped;
            pendingUiSlip = sampleUiSlip;
            pendingBlockIndex = sampleBlockIndex;
            havePending = true;
        end
    end

    settleWindow = phaseCodeTrace(startIndex, end - settleBlocks + 1:end);
    lockedPhaseCode(startIndex) = round(mean(settleWindow));
    dlevInnerSettleStd = std(dlevInnerTrace(startIndex, ...
        end - settleBlocks + 1:end));
    dlevOuterSettleStd = std(dlevOuterTrace(startIndex, ...
        end - settleBlocks + 1:end));
    lockedFlag(startIndex) = std(settleWindow) <= lockStdTolerance && ...
        dlevInnerSettleStd <= dlevSettleStdTolerance && ...
        dlevOuterSettleStd <= dlevSettleStdTolerance;

    fprintf(['Start phase %3d/%d: locked=%d, steady phase code=%d, ' ...
        'final MM error=%.4g, dLev=[%.2f %.2f] (std=[%.3f %.3f]).\n'], ...
        startPhase, samplePerSymbol, lockedFlag(startIndex), ...
        lockedPhaseCode(startIndex), timingErrorTrace(startIndex, end), ...
        dlevInnerTrace(startIndex, end), dlevOuterTrace(startIndex, end), ...
        dlevInnerSettleStd, dlevOuterSettleStd);
end

commonLockPhase = round(median(lockedPhaseCode(lockedFlag)));
phaseSpread = max(lockedPhaseCode(lockedFlag)) - ...
    min(lockedPhaseCode(lockedFlag));
allPhaseLock = all(lockedFlag) && ...
    all(abs(lockedPhaseCode - commonLockPhase) <= 2);

% dlev 一致性:各起始相位收敛到的两环 code 电平应彼此接近。
dlevInnerFinal = dlevInnerTrace(:, end).';
dlevOuterFinal = dlevOuterTrace(:, end).';
dlevInnerSpread = max(dlevInnerFinal) - min(dlevInnerFinal);
dlevOuterSpread = max(dlevOuterFinal) - min(dlevOuterFinal);
dlevConsistent = dlevInnerSpread <= 2 * dlevSettleStdTolerance && ...
    dlevOuterSpread <= 2 * dlevSettleStdTolerance;

% 收敛终值与离线参考真值的偏差,衡量在线自适应逼近真实电平的程度。
dlevInnerTruthError = mean(dlevInnerFinal) - dlevInnerReference;
dlevOuterTruthError = mean(dlevOuterFinal) - dlevOuterReference;

resultDir = fullfile(testDir, 'result', 'cdr_dlev_sslms');
if saveOutputs && ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

blockAxis = 1:numBlocks;
convergenceFigurePath = fullfile(resultDir, 'cdr_phase_convergence.png');
timingErrorFigurePath = fullfile(resultDir, 'cdr_block_timing_error.png');
lockSummaryFigurePath = fullfile(resultDir, ...
    'cdr_locked_phase_vs_start_phase.png');
dlevConvergenceFigurePath = fullfile(resultDir, 'dlev_convergence.png');
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
    title(sprintf(['Dual-loop CDR Phase Convergence: %d start phases, ' ...
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
    title('Dual-loop CDR Loop Error Transient per Start Phase');
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
result.SettleBlocks = settleBlocks;
result.LockStdTolerance = lockStdTolerance;
result.DlevSettleStdTolerance = dlevSettleStdTolerance;
result.LockedPhaseCode = lockedPhaseCode;
result.LockedFlag = lockedFlag;
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
result.ConvergenceFigurePath = convergenceFigurePath;
result.TimingErrorFigurePath = timingErrorFigurePath;
result.LockSummaryFigurePath = lockSummaryFigurePath;
result.DlevConvergenceFigurePath = dlevConvergenceFigurePath;
result.ResultMatPath = resultMatPath;
if saveOutputs
    save(resultMatPath, 'result', '-v7.3');
end

fprintf('\n');
if allPhaseLock
    fprintf(['CDR dual loop passed: all %d start phases locked to ' ...
        'code %d (spread %d code, ref phase %d).\n'], numStartPhase, ...
        commonLockPhase, phaseSpread, referencePhase);
else
    fprintf(['CDR dual loop did NOT reach full-phase lock: %d/%d ' ...
        'phases stable, spread %d code. Retune Kp/Ki/mu/polarity.\n'], ...
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
fprintf(['dLev vs offline truth: inner ref=%.2f (err %+.2f), ' ...
    'outer ref=%.2f (err %+.2f) code.\n'], dlevInnerReference, ...
    dlevInnerTruthError, dlevOuterReference, dlevOuterTruthError);
fprintf('Results saved to %s.\n', resultDir);
end

function options = parseLoopOptions(varargin)
%PARSELOOPOPTIONS 解析 CDR/dlev 环路增益与运行开关,给出可调默认值。
%   Kp/Ki 以蓝本幅度域数值表示(内部按 gainScale 折算到 code 域);StepSize
%   为 dlev 的 mu;Polarity/DlevPolarity 分别为 MMPD 与 dlev 的极性方向因子,
%   相互独立。DlevOuterInit/DlevInnerInit 为 dlev 的硬件标称初值(上电即可知,
%   不依赖离线扫描)。名值对(或单个 struct)允许调用方覆盖以便重整定。

defaults = struct();
defaults.Kp = 1.8;
defaults.Ki = 0.05;
defaults.MaxDeltaCode = 12;
defaults.Polarity = 1;
defaults.StepSize = 0.3;
defaults.StepSizeSettle = 0.1;
% mu 两档换挡参数。SS-LMS 每样本梯度仅 ±1(全精度 LMS 为 |x|-|d|,可达数 code),
% 故捕获档 mu 需比全精度版明显调大才能在相同 block 数内让 dlev 收敛;捕获档用
% 大 mu(StepSize)让 dlev 先启动并以最大环路带宽全程跟随移动的采样相位逼近
% 真值;检测到相位环真锁定后才切到稳态档小 mu(StepSizeSettle)压低稳态抖动。
% 锁定判据:连续 LockWindow 块 |deltaCode| <= LockDeltaTol 视为相位环锁定。
% 不设强制降档兜底,避免在相位尚未收敛时把 dlev 冻结在错电平上。稳态档 mu 不宜
% 过小:SS-LMS 用大 mu 捕获时稳态抖动本就很小(std≈0.05 code),若降到 0.03 会
% 抽掉恢复力,把各相位残余偏置冻结在略偏的平台上,反而使 dlev 一致性变差;取
% 0.1 兼顾抖动抑制与残余偏置回拉,实测全相位锁点、dlev 与离线真值偏差 <0.1 code。
defaults.LockWindow = 8;
defaults.LockDeltaTol = 1;
% dlev 收敛判据(SS-LMS 专用)。相位环锁定后还须确认 dlev 外环在最近
% DlevSettleWindow 块内的漂移不超过 DlevSettleTol(code)才允许降档,避免在
% dlev 仍从硬件标称初值下行途中就把它冻结在错电平上。SS-LMS 捕获档 ±mu 步进
% 下,dlev 从 48 收敛到 ~36.5 约需十几块,取窗口 16 块、容差 0.5 code 兼顾
% “确已收敛”与“不过度延迟降档”。
defaults.DlevSettleWindow = 16;
defaults.DlevSettleTol = 0.5;
defaults.DlevPolarity = 1;
% dlev 硬件标称初值:由 ADC 满量程与量化精度换算。adcFullRange=±4、7bit
% 共 128 code,故 1 个 analog 单位 = 128/8 = 16 code。按 PAM4 名义幅度
% ±3/±1 直接映射得外环 3*16=48、内环 1*16=16 code。这是芯片上电即可算的
% 设计标称,不依赖离线扫描。注意实际 FFE 输出外摆未跑满 ±3(离线真值外环
% 仅≈36.6),故此标称偏高,正好用作 dlev 从偏置状态向下收敛的压力测试起点。
defaults.DlevOuterInit = 48;
defaults.DlevInnerInit = 16;
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

function [decision, sliceError] = sliceCodePam4(sample, ...
    dLevInner, dLevOuter, threshold)
%SLICECODEPAM4 用 dlev 维护的 code 域门限/电平做一次 PAM4 判决(单判决器)。
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
