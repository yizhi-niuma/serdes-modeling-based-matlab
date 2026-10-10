classdef loop_monitor < handle
    %LOOP_MONITOR CDR 自适应环路的因果型(逐 block)策略判决器。
    %
    % 本监视器每次只观测一个 block，并返回一次性(one-shot)策略事件。它
    % 只做判决：从不持有环路对象，也从不施加步长、系数或门控。调用方读取
    % 返回的触发标志并施加动作，因此数据通路仍留在 cdr_top。
    %
    % 提供两个相互独立的因果型检测器。
    %
    % 1) 眼质量(SNR) settle 检测器。对逐 block 的判决导向 SNR(dB)做指数加权
    %    平均(EWMA)，越过阈值即一次性触发。内存仅一个标量，天然有界。它是
    %    第一级(capture -> settle)降 mu 门控的唯一判据：它观测"眼睛是否张开"，
    %    这才是决定该不该降 mu 的真正量。逐 block SNR 噪声极大(未锁定、相位
    %    漂移的环路扫过眼心也会给出漂亮的单块读数)，因此做平均是必需的而非
    %    修饰。用 enableSnrSettle 显式启用。
    %
    % 2) 环路频率态锁定门控(EWMA 版)。它作为第二级(settle -> PVT-track)门控，
    %    在任意 ppm(含零)下都有意义：环路频率态恰恰是"环路跟上频偏后会变恒定"
    %    的那个量。本门控用三条指数加权平均(EWMA)替代早期的 2000 深滑窗
    %    mean/std/max：
    %       FreqGateFast (α=AlphaFast) 快速跟随当前频率态
    %       FreqGateSlow (α=AlphaSlow) 慢速基准，近似窗口均值
    %       FreqGateMad  (α=AlphaMad)  |x - slow| 的指数平均，替代窗口 std
    %    四轴判据与早期窗口判据一一对应：
    %       平坦  |fast - slow| <= FreqGateMeanHalfDiffTol
    %       波动  mad           <= FreqGateStdTol
    %       速率  ||slow| - |expected|| <= FreqGateRateTol  (NaN/Inf 旁路)
    %       饱和  |x| < FreqGateSatLevel  (逐样本; railed 样本清 dwell)
    %    四轴同时满足记为一次 instOk；连续 FreqGateDwellBlocks 个 instOk 才闩锁，
    %    把早期"整窗满足"隐含的驻留语义显式化(railed 一次即清零重数)。内存只有
    %    固定几个标量，与运行长度无关。用 enableFreqStateGate 显式启用。在线
    %    updateFreqStateGate 与离线静态判据核 freqStateLockCore 共用同一逐样本
    %    递推与判据，因此把完整频率态 trace 喂进 freqStateLockCore 得到的 one-shot
    %    闩锁块与在线门控逐块一致。
    %
    % 注：原第三个检测器"FFE 写门控(center-touch 码域众数锁定)"已移除，因为
    % 它只在零频偏下有意义(有频偏时 PI code 持续旋转、永不停在单一 code)，
    % 其职责已由上面的频率态门控在任意 ppm 下统一承担。早期的滑窗版频率态
    % 判据(mean/std/max)已于 2026-10-09 整体替换为本 EWMA 版，不再并存。

    properties (SetAccess = private)
        SnrSettleEnabled = false
        SnrSettleThresholdDb = NaN
        SnrSettleAlpha = NaN
        SnrSettleMinBlock = NaN
        SnrEwmaDb = NaN
        SnrSettleDone = false
        SnrSettleBlock = NaN

        % ---- 频率态门控(EWMA 版) ----
        % 配置(由 enableFreqStateGate 设定, 跨 resetState 保留):
        FreqGateEnabled = false
        FreqGateExpectedRate = NaN
        FreqGateMeanHalfDiffTol = NaN
        FreqGateStdTol = NaN
        FreqGateRateTol = Inf
        FreqGateMinBlock = NaN
        FreqGateSatLevel = Inf
        FreqGateDwellBlocks = NaN
        FreqGateAlphaFast = NaN
        FreqGateAlphaSlow = NaN
        FreqGateAlphaMad = NaN
        % 运行态(每次 resetState 清空):
        FreqGateFast = NaN
        FreqGateSlow = NaN
        FreqGateMad = NaN
        FreqGateSeeded = false
        FreqGateDwell = 0
        FreqGateDone = false
        FreqGateBlock = NaN
        FreqGateSkippedCount = 0
    end

    methods
        function obj = loop_monitor()
            %LOOP_MONITOR 构造。两个在线检测器——眼质量(SNR) settle 与频率态
            % 锁定门控——分别用 enableSnrSettle / enableFreqStateGate 启用。
            obj.resetState();
        end

        function resetState(obj)
            %RESETSTATE 清空全部动态状态，同时保留配置。
            % 频率态门控的运行态随每次 reset 清空；配置(alpha / 容差 / dwell)
            % 由 enableFreqStateGate 设定并跨 reset 保留。
            obj.FreqGateFast = NaN;
            obj.FreqGateSlow = NaN;
            obj.FreqGateMad = NaN;
            obj.FreqGateSeeded = false;
            obj.FreqGateDwell = 0;
            obj.FreqGateDone = false;
            obj.FreqGateBlock = NaN;
            obj.FreqGateSkippedCount = 0;
        end

        function enableSnrSettle(obj, thresholdDb, alpha, minBlock)
            %ENABLESNRSETTLE 打开眼质量 settle 检测器。
            %
            %   thresholdDb 是判决导向 SNR 的平均值(dB)，达到或超过它即认为
            %   眼已张开。alpha 是 EWMA 权重，取值 (0, 1]；alpha 越小平滑越重。
            %   minBlock 在平均值尚在预热阶段时抑制触发。
            %
            %   这里用一次独立的配置调用而非增加构造函数参数，是为了让文档
            %   所述的 4 参数构造函数对每个既有调用方都保持有效。
            if nargin ~= 4
                error('loop_monitor:InvalidSnrSettleConfig', ...
                    'Expected thresholdDb, alpha, and minBlock.');
            end
            isValidThreshold = isnumeric(thresholdDb) && ...
                isreal(thresholdDb) && isscalar(thresholdDb) && ...
                isfinite(thresholdDb);
            if ~isValidThreshold
                error('loop_monitor:InvalidSnrSettleThreshold', ...
                    'thresholdDb must be a finite real scalar.');
            end
            isValidAlpha = isnumeric(alpha) && isreal(alpha) && ...
                isscalar(alpha) && isfinite(alpha) && alpha > 0 && alpha <= 1;
            if ~isValidAlpha
                error('loop_monitor:InvalidSnrSettleAlpha', ...
                    'alpha must be a real scalar in (0, 1].');
            end
            obj.validateInteger(minBlock, 1, ...
                'InvalidSnrSettleMinBlock', 'minBlock');

            obj.SnrSettleEnabled = true;
            obj.SnrSettleThresholdDb = double(thresholdDb);
            obj.SnrSettleAlpha = double(alpha);
            obj.SnrSettleMinBlock = double(minBlock);
            obj.SnrEwmaDb = NaN;
            obj.SnrSettleDone = false;
            obj.SnrSettleBlock = NaN;
        end

        function triggered = updateSnrSettle(obj, blockIndex, snrDb)
            %UPDATESNRSETTLE 上报一次性的眼质量 settle 跳变。
            %
            % snrDb 是本块的判决导向 SNR(dB)。不携带可用眼信息的块(没有有效
            % 样本，或误差功率恰为零，即非有限读数)会被跳过而非折入平均，因此
            % 它们既不会污染也不会抬高平均值。
            obj.requireSnrSettleEnabled('updateSnrSettle');
            obj.validateInteger(blockIndex, 1, 'InvalidBlock', 'blockIndex');
            isValidSnr = isnumeric(snrDb) && isreal(snrDb) && isscalar(snrDb);
            if ~isValidSnr
                error('loop_monitor:InvalidSnr', ...
                    'snrDb must be a real scalar.');
            end

            triggered = false;
            if obj.SnrSettleDone
                return;
            end
            if ~isfinite(snrDb)
                return;
            end

            if isnan(obj.SnrEwmaDb)
                % 用首个可用读数播种；否则从零缓升会把触发延迟约 1/alpha 个块。
                obj.SnrEwmaDb = double(snrDb);
            else
                weight = obj.SnrSettleAlpha;
                obj.SnrEwmaDb = (1 - weight) * obj.SnrEwmaDb + ...
                    weight * double(snrDb);
            end

            if blockIndex < obj.SnrSettleMinBlock
                return;
            end
            if obj.SnrEwmaDb >= obj.SnrSettleThresholdDb
                obj.SnrSettleDone = true;
                obj.SnrSettleBlock = blockIndex;
                triggered = true;
            end
        end

        function enableFreqStateGate(obj, expectedRate, meanHalfDiffTol, ...
                stdTol, rateTol, minBlock, satLevel, dwellBlocks, ...
                alphaFast, alphaSlow, alphaMad)
            %ENABLEFREQSTATEGATE 打开 EWMA 版在线频率态锁定门控。
            %
            %   expectedRate / meanHalfDiffTol / stdTol / rateTol / minBlock /
            %   satLevel 的含义与离线判据核 freqStateLockCore 完全一致：
            %   expectedRate 可为 NaN、rateTol 可为 Inf 以仅测平坦与波动；
            %   satLevel 可为 Inf 关闭饱和轴。dwellBlocks 是必须连续满足四轴的
            %   块数(驻留)。三个 α 可选，默认 1/64、1/512、1/256，必须落在 (0, 1]。
            %
            %   这里用一次独立的配置调用而非增加构造函数参数，是为了让文档
            %   所述的 4 参数构造函数对每个既有调用方都保持有效。
            if nargin < 9 || isempty(alphaFast); alphaFast = 1 / 64; end
            if nargin < 10 || isempty(alphaSlow); alphaSlow = 1 / 512; end
            if nargin < 11 || isempty(alphaMad); alphaMad = 1 / 256; end
            loop_monitor.validateFiniteOrNaNScalar(expectedRate, 'expectedRate');
            loop_monitor.validateNonnegativeScalar(meanHalfDiffTol, ...
                'meanHalfDiffTol');
            loop_monitor.validateNonnegativeScalar(stdTol, 'stdTol');
            loop_monitor.validateNonnegativeScalarOrInf(rateTol, 'rateTol');
            obj.validateInteger(minBlock, 1, ...
                'InvalidFreqGateMinBlock', 'minBlock');
            loop_monitor.validateNonnegativeScalarOrInf(satLevel, 'satLevel');
            obj.validateInteger(dwellBlocks, 1, ...
                'InvalidFreqGateDwellBlocks', 'dwellBlocks');
            loop_monitor.validateAlpha(alphaFast, 'alphaFast');
            loop_monitor.validateAlpha(alphaSlow, 'alphaSlow');
            loop_monitor.validateAlpha(alphaMad, 'alphaMad');

            obj.FreqGateEnabled = true;
            obj.FreqGateExpectedRate = double(expectedRate);
            obj.FreqGateMeanHalfDiffTol = double(meanHalfDiffTol);
            obj.FreqGateStdTol = double(stdTol);
            obj.FreqGateRateTol = double(rateTol);
            obj.FreqGateMinBlock = double(minBlock);
            obj.FreqGateSatLevel = double(satLevel);
            obj.FreqGateDwellBlocks = double(dwellBlocks);
            obj.FreqGateAlphaFast = double(alphaFast);
            obj.FreqGateAlphaSlow = double(alphaSlow);
            obj.FreqGateAlphaMad = double(alphaMad);
            obj.FreqGateFast = NaN;
            obj.FreqGateSlow = NaN;
            obj.FreqGateMad = NaN;
            obj.FreqGateSeeded = false;
            obj.FreqGateDwell = 0;
            obj.FreqGateDone = false;
            obj.FreqGateBlock = NaN;
            obj.FreqGateSkippedCount = 0;
        end

        function triggered = updateFreqStateGate(obj, blockIndex, freqState)
            %UPDATEFREQSTATEGATE 上报一次性的频率锁定跳变(EWMA 在线形式)。
            %
            % freqState 是本块环路滤波器积分器的频率态(code/block)，取自本块
            % 环路滤波器更新之后，因此观测序列与记录下来的频率态 trace 逐个
            % 样本对齐。每块 O(1)：推进三条 EWMA、算四轴 instOk、维护 dwell 计数。
            % 非有限样本被跳过且计入 FreqGateSkippedCount，使依赖跳过的运行不会
            % 与干净运行无声地混同。递推与判据核 freqStateLockCore 完全一致，故
            % 在线判决与离线整条回放逐块对齐。
            obj.requireFreqGateEnabled('updateFreqStateGate');
            obj.validateInteger(blockIndex, 1, 'InvalidBlock', 'blockIndex');
            isValidState = isnumeric(freqState) && isreal(freqState) && ...
                isscalar(freqState);
            if ~isValidState
                error('loop_monitor:InvalidFreqState', ...
                    'freqState must be a real scalar.');
            end

            triggered = false;
            if obj.FreqGateDone
                return;
            end
            if ~isfinite(freqState)
                obj.FreqGateSkippedCount = obj.FreqGateSkippedCount + 1;
                return;
            end

            [obj.FreqGateFast, obj.FreqGateSlow, obj.FreqGateMad, ...
                obj.FreqGateSeeded] = loop_monitor.freqStateStep( ...
                double(freqState), obj.FreqGateFast, obj.FreqGateSlow, ...
                obj.FreqGateMad, obj.FreqGateSeeded, obj.FreqGateAlphaFast, ...
                obj.FreqGateAlphaSlow, obj.FreqGateAlphaMad);
            instOk = loop_monitor.freqStateInstOk(double(freqState), ...
                obj.FreqGateFast, obj.FreqGateSlow, obj.FreqGateMad, ...
                obj.FreqGateMeanHalfDiffTol, obj.FreqGateStdTol, ...
                obj.FreqGateRateTol, obj.FreqGateExpectedRate, ...
                obj.FreqGateSatLevel);
            if instOk
                obj.FreqGateDwell = obj.FreqGateDwell + 1;
            else
                obj.FreqGateDwell = 0;
            end
            if blockIndex >= obj.FreqGateMinBlock && ...
                    obj.FreqGateDwell >= obj.FreqGateDwellBlocks
                obj.FreqGateDone = true;
                obj.FreqGateBlock = blockIndex;
                triggered = true;
            end
        end

        function state = getState(obj)
            %GETSTATE 返回配置与有界诊断量的副本。
            state = struct();
            state.SnrSettleEnabled = obj.SnrSettleEnabled;
            state.SnrSettleThresholdDb = obj.SnrSettleThresholdDb;
            state.SnrSettleAlpha = obj.SnrSettleAlpha;
            state.SnrSettleMinBlock = obj.SnrSettleMinBlock;
            state.SnrEwmaDb = obj.SnrEwmaDb;
            state.SnrSettleDone = obj.SnrSettleDone;
            state.SnrSettleBlock = obj.SnrSettleBlock;
            state.FreqGateEnabled = obj.FreqGateEnabled;
            state.FreqGateExpectedRate = obj.FreqGateExpectedRate;
            state.FreqGateMeanHalfDiffTol = obj.FreqGateMeanHalfDiffTol;
            state.FreqGateStdTol = obj.FreqGateStdTol;
            state.FreqGateRateTol = obj.FreqGateRateTol;
            state.FreqGateMinBlock = obj.FreqGateMinBlock;
            state.FreqGateSatLevel = obj.FreqGateSatLevel;
            state.FreqGateDwellBlocks = obj.FreqGateDwellBlocks;
            state.FreqGateAlphaFast = obj.FreqGateAlphaFast;
            state.FreqGateAlphaSlow = obj.FreqGateAlphaSlow;
            state.FreqGateAlphaMad = obj.FreqGateAlphaMad;
            state.FreqGateDwell = obj.FreqGateDwell;
            state.FreqGateDone = obj.FreqGateDone;
            state.FreqGateBlock = obj.FreqGateBlock;
            state.FreqGateSkippedCount = obj.FreqGateSkippedCount;
        end
    end

    methods (Static)
        function [locked, diag] = freqStateLockCore(freqStateSeq, ...
                expectedRate, meanHalfDiffTol, stdTol, rateTol, satLevel, ...
                dwellBlocks, alphaFast, alphaSlow, alphaMad)
            %FREQSTATELOCKCORE 频率态锁定判据(EWMA, 离线整条回放)。
            %
            % 在频偏下，定时环靠保持一个恒定非零的积分器频率态(code/block)来
            % 跟踪。本判据对整条 freqStateSeq 从头跑三条 EWMA，逐样本判四轴
            % instOk(平坦 / 波动 / 速率 / 饱和)并累计 dwell，一旦连续 dwellBlocks
            % 个 instOk 即判锁(one-shot, 锁后不回落)。与在线 updateFreqStateGate
            % 共用同一递推与判据，故把完整轨迹喂进本函数得到的终判与在线门控
            % 逐块对齐。
            %
            %   expectedRate 可为 NaN、rateTol 可为 Inf 以仅测平坦与波动。
            %   速率轴用双重绝对值，使通过/失败与符号约定无关，而诊断量保留
            %   带符号值。satLevel 可为 Inf 关闭饱和轴(钳在积分器饱和限上的频率
            %   态也"完美平坦"，但它是 railed 而非锁定；satLevel 有限时任一
            %   railed 样本都会清零 dwell)。三个 α 可选，默认 1/64、1/512、1/256。
            if nargin < 8 || isempty(alphaFast); alphaFast = 1 / 64; end
            if nargin < 9 || isempty(alphaSlow); alphaSlow = 1 / 512; end
            if nargin < 10 || isempty(alphaMad); alphaMad = 1 / 256; end
            loop_monitor.validateFiniteRealVector(freqStateSeq, ...
                'InvalidFreqSeq', 'freqStateSeq');
            loop_monitor.validateFiniteOrNaNScalar(expectedRate, 'expectedRate');
            loop_monitor.validateNonnegativeScalar(meanHalfDiffTol, ...
                'meanHalfDiffTol');
            loop_monitor.validateNonnegativeScalar(stdTol, 'stdTol');
            loop_monitor.validateNonnegativeScalarOrInf(rateTol, 'rateTol');
            loop_monitor.validateNonnegativeScalarOrInf(satLevel, 'satLevel');
            loop_monitor.validateIntegerArg(dwellBlocks, 1, ...
                'InvalidDwellBlocks', 'dwellBlocks');
            loop_monitor.validateAlpha(alphaFast, 'alphaFast');
            loop_monitor.validateAlpha(alphaSlow, 'alphaSlow');
            loop_monitor.validateAlpha(alphaMad, 'alphaMad');

            seq = reshape(double(freqStateSeq), 1, []);
            fast = NaN;
            slow = NaN;
            mad = NaN;
            seeded = false;
            dwell = 0;
            locked = false;
            latchBlock = NaN;
            lastFlat = false;
            lastQuiet = false;
            lastRate = false;
            for k = 1:numel(seq)
                x = seq(k);
                [fast, slow, mad, seeded] = loop_monitor.freqStateStep( ...
                    x, fast, slow, mad, seeded, alphaFast, alphaSlow, alphaMad);
                [instOk, lastFlat, lastQuiet, lastRate] = ...
                    loop_monitor.freqStateInstOk(x, fast, slow, mad, ...
                    meanHalfDiffTol, stdTol, rateTol, expectedRate, satLevel);
                if instOk
                    dwell = dwell + 1;
                else
                    dwell = 0;
                end
                if ~locked && dwell >= dwellBlocks
                    locked = true;
                    latchBlock = k;
                end
            end
            if nargout > 1
                diag = loop_monitor.freqStateDiag(slow, fast, mad, ...
                    expectedRate, lastFlat, lastQuiet, lastRate);
                diag.LatchBlock = latchBlock;
            end
        end

        function [locked, diag] = detectRotationPeriodLock(unwrappedSeq, ...
                windowBlocks, codesPerUi, minIntervals, covTol, ...
                expectedPeriod, periodTol)
            %DETECTROTATIONPERIODLOCK 恒定 PI 旋转周期 => 跟踪。
            %
            % 在频偏下 PI code 持续旋转；每转满一周(128 码)跨一个 UI 边界
            % (一次 UI slip)。环路跟踪时，相邻两次 UI slip 之间的块数(即旋转
            % 周期)为恒定。该离线判据在尾窗内把 floor(unwrapped / codesPerUi)
            % 的变化检为 UI-slip 事件，当相邻间隔足够多、其变异系数很小
            % (<= covTol)、且均值与 expectedPeriod 匹配(在 periodTol 内)时判锁。
            % expectedPeriod 可为 NaN / periodTol 可为 Inf 以跳过周期匹配。不旋转
            % 的序列(0 ppm)事件太少，返回 locked = false；零频偏情形请改用
            % 众数 center-touch 判据。
            if ~(isnumeric(unwrappedSeq) && isreal(unwrappedSeq) && ...
                    (isempty(unwrappedSeq) || isvector(unwrappedSeq)) && ...
                    all(isfinite(unwrappedSeq(:))))
                error('loop_monitor:InvalidUnwrappedSeq', ...
                    'unwrappedSeq must be a finite real numeric vector.');
            end
            loop_monitor.validateIntegerArg(windowBlocks, 1, ...
                'InvalidWindowBlocks', 'windowBlocks');
            loop_monitor.validateIntegerArg(codesPerUi, 2, ...
                'InvalidCodesPerUi', 'codesPerUi');
            loop_monitor.validateIntegerArg(minIntervals, 1, ...
                'InvalidMinIntervals', 'minIntervals');
            loop_monitor.validateNonnegativeScalar(covTol, 'covTol');
            loop_monitor.validateFiniteOrNaNScalar(expectedPeriod, ...
                'expectedPeriod');
            loop_monitor.validateNonnegativeScalarOrInf(periodTol, 'periodTol');

            seq = reshape(double(unwrappedSeq), 1, []);
            totalLength = numel(seq);
            windowLength = min(totalLength, double(windowBlocks));
            diag = struct('WindowLength', windowLength, 'EventCount', 0, ...
                'IntervalCount', 0, 'PeriodMean', NaN, 'PeriodStd', NaN, ...
                'PeriodCov', NaN, 'ExpectedPeriod', double(expectedPeriod), ...
                'PeriodError', NaN, 'DispersionOk', false, 'PeriodOk', false);
            if windowLength < 2
                locked = false;
                return;
            end

            window = seq(totalLength - windowLength + 1:end);
            slip = floor(window / double(codesPerUi));
            eventIndex = find(diff(slip) ~= 0) + 1;
            diag.EventCount = numel(eventIndex);
            if numel(eventIndex) < 2
                locked = false;
                return;
            end

            intervals = diff(eventIndex);
            diag.IntervalCount = numel(intervals);
            diag.PeriodMean = mean(intervals);
            diag.PeriodStd = std(intervals);
            diag.PeriodCov = diag.PeriodStd / max(abs(diag.PeriodMean), eps);
            diag.PeriodError = diag.PeriodMean - double(expectedPeriod);
            diag.DispersionOk = numel(intervals) >= double(minIntervals) && ...
                diag.PeriodCov <= covTol;
            if isnan(expectedPeriod) || ~isfinite(periodTol)
                diag.PeriodOk = true;
            else
                diag.PeriodOk = abs(diag.PeriodError) <= periodTol;
            end
            locked = totalLength >= double(windowBlocks) && ...
                diag.DispersionOk && diag.PeriodOk;
        end
    end

    methods (Static, Access = private)
        function [fast, slow, mad, seeded] = freqStateStep(x, fast, slow, ...
                mad, seeded, alphaFast, alphaSlow, alphaMad)
            %FREQSTATESTEP 推进一步三条 EWMA。首个有效样本用于播种，避免从 0
            % 缓升引入约 1/alpha 块的纯延迟。由在线门控与离线判据核共用，保证
            % 两者逐块一致。
            if ~seeded
                fast = x;
                slow = x;
                mad = 0;
                seeded = true;
            else
                fast = fast + alphaFast * (x - fast);
                slow = slow + alphaSlow * (x - slow);
                mad = mad + alphaMad * (abs(x - slow) - mad);
            end
        end

        function [instOk, flatOk, quietOk, rateOk] = freqStateInstOk(x, ...
                fast, slow, mad, meanHalfDiffTol, stdTol, rateTol, ...
                expectedRate, satLevel)
            %FREQSTATEINSTOK 单样本四轴判据：平坦 / 波动 / 速率 / 饱和。速率轴用
            % 双重绝对值，使通过/失败与符号约定无关。饱和轴逐样本判定：railed
            % 样本令 instOk 为假，从而把 dwell 清零。
            flatOk = abs(fast - slow) <= meanHalfDiffTol;
            quietOk = mad <= stdTol;
            if isnan(expectedRate) || ~isfinite(rateTol)
                rateOk = true;
            else
                rateOk = abs(abs(slow) - abs(double(expectedRate))) <= rateTol;
            end
            satOk = abs(x) < satLevel;
            instOk = flatOk && quietOk && rateOk && satOk;
        end

        function diag = freqStateDiag(slow, fast, mad, expectedRate, ...
                flatOk, quietOk, rateOk)
            %FREQSTATEDIAG 组装诊断结构。MeanValue=slow、TailStd=mad、
            % MeanHalfDiff=|fast-slow|，字段名沿用早期窗口判据，便于下游
            % (freqDiagList 拼接、summary、eye 回放)无需区分来源。
            diag = struct( ...
                'WindowLength', NaN, ...
                'MeanValue', slow, ...
                'MeanHalfDiff', abs(fast - slow), ...
                'TailStd', mad, ...
                'ExpectedRate', double(expectedRate), ...
                'RateError', slow - double(expectedRate), ...
                'FlatnessOk', logical(flatOk && quietOk), ...
                'RateOk', logical(rateOk), ...
                'SatOk', true);
        end

        function validateAlpha(value, argumentName)
            %VALIDATEALPHA EWMA 权重必须是落在 (0, 1] 的有限实标量。
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                isfinite(value) && value > 0 && value <= 1;
            if ~isValid
                error('loop_monitor:InvalidAlpha', ...
                    '%s must be a finite real scalar in (0, 1].', argumentName);
            end
        end

        function validateIntegerArg(value, minimum, idSuffix, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                isfinite(value) && value >= minimum && value == fix(value);
            if ~isValid
                error(['loop_monitor:' idSuffix], ...
                    '%s must be a finite integer scalar in its valid range.', ...
                    argumentName);
            end
        end

        function validateFiniteRealVector(value, idSuffix, argumentName)
            isValid = isnumeric(value) && isreal(value) && ...
                (isempty(value) || isvector(value)) && all(isfinite(value(:)));
            if ~isValid
                error(['loop_monitor:' idSuffix], ...
                    '%s must be a finite real numeric vector.', argumentName);
            end
        end

        function validateFiniteOrNaNScalar(value, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                (isfinite(value) || isnan(value));
            if ~isValid
                error('loop_monitor:InvalidScalar', ...
                    '%s must be a finite real scalar or NaN.', argumentName);
            end
        end

        function validateNonnegativeScalar(value, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                isfinite(value) && value >= 0;
            if ~isValid
                error('loop_monitor:InvalidTolerance', ...
                    '%s must be a finite nonnegative real scalar.', argumentName);
            end
        end

        function validateNonnegativeScalarOrInf(value, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                ~isnan(value) && value >= 0;
            if ~isValid
                error('loop_monitor:InvalidTolerance', ...
                    '%s must be a nonnegative real scalar or Inf.', argumentName);
            end
        end
    end

    methods (Access = private)
        function requireSnrSettleEnabled(obj, methodName)
            if ~obj.SnrSettleEnabled
                error('loop_monitor:SnrSettleDisabled', ...
                    ['%s requires the eye-quality settle detector; call ', ...
                    'enableSnrSettle first.'], methodName);
            end
        end

        function requireFreqGateEnabled(obj, methodName)
            if ~obj.FreqGateEnabled
                error('loop_monitor:FreqGateDisabled', ...
                    ['%s requires the frequency-state lock gate; call ', ...
                    'enableFreqStateGate first.'], methodName);
            end
        end

        function validateInteger(~, value, minimum, idSuffix, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                isfinite(value) && value >= minimum && value == fix(value);
            if ~isValid
                error(['loop_monitor:' idSuffix], ...
                    '%s must be a finite integer scalar in its valid range.', ...
                    argumentName);
            end
        end
    end
end
