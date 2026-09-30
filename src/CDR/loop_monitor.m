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
    %    这才是决定该不该降 mu 的真正量。(此前由 dLev settle 检测器——在固定
    %    窗口上做两点位移测试——担任此角色；它本质是隐含的漂移率门限，会在
    %    dLev 缓慢爬升、眼仍闭合时误报 settle，故已于 2026-09-26 移除，改用
    %    本门控。)逐 block SNR 噪声极大(未锁定、相位漂移的环路扫过眼心也会
    %    给出漂亮的单块读数)，因此做平均是必需的而非修饰。用 enableSnrSettle
    %    显式启用。
    %
    % 2) 环路频率态锁定门控。它是下面 detectFrequencyStateLock 判据的一次性
    %    在线(ONLINE)形式。它用一个环形缓冲保存最近 windowBlocks 个环路频率
    %    态样本，缓冲满后把有序窗口交给同一个静态判据，并转发启用时给定的
    %    同一个 satLevel。因此在线判决与在同一尾窗、同一 satLevel 下评估的
    %    离线判决在构造上完全一致：没有第二份会走样的判据代码，railed 积分器
    %    的拒绝逻辑住在这唯一一份判据里，而不在调用方的预过滤里。内存只有
    %    一个窗口，与运行长度无关；每块 O(windowBlocks) 的代价也只持续到门控
    %    闩锁为止。它作为第二级(settle -> PVT-track)门控，在任意 ppm(含零)下
    %    都有意义：环路频率态恰恰是"环路跟上频偏后会变恒定"的那个量。用
    %    enableFreqStateGate 显式启用。
    %
    % 注：原第三个检测器"FFE 写门控(center-touch 码域众数锁定)"已移除，因为
    % 它只在零频偏下有意义(有频偏时 PI code 持续旋转、永不停在单一 code)，
    % 其职责已由上面的频率态门控在任意 ppm 下统一承担。

    properties (SetAccess = private)
        SnrSettleEnabled = false
        SnrSettleThresholdDb = NaN
        SnrSettleAlpha = NaN
        SnrSettleMinBlock = NaN
        SnrEwmaDb = NaN
        SnrSettleDone = false
        SnrSettleBlock = NaN
        FreqGateEnabled = false
        FreqGateWindow = NaN
        FreqGateExpectedRate = NaN
        FreqGateMeanHalfDiffTol = NaN
        FreqGateStdTol = NaN
        FreqGateRateTol = NaN
        FreqGateSatLevel = Inf
        FreqGateMinBlock = NaN
        FreqGateDone = false
        FreqGateBlock = NaN
        FreqGateSampleCount = 0
        FreqGateSkippedCount = 0
    end

    properties (Access = private)
        FreqRingValue = zeros(1, 0)
    end

    methods
        function obj = loop_monitor()
            %LOOP_MONITOR 构造。两个在线检测器——眼质量(SNR) settle 与频率态
            % 锁定门控——分别用 enableSnrSettle / enableFreqStateGate 启用。
            obj.resetState();
        end

        function resetState(obj)
            %RESETSTATE 清空全部动态状态，同时保留配置。
            obj.FreqGateDone = false;
            obj.FreqGateBlock = NaN;
            obj.FreqGateSampleCount = 0;
            obj.FreqGateSkippedCount = 0;
            if obj.FreqGateEnabled
                obj.FreqRingValue = nan(1, obj.FreqGateWindow);
            else
                obj.FreqRingValue = zeros(1, 0);
            end
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

        function enableFreqStateGate(obj, windowBlocks, expectedRate, ...
                meanHalfDiffTol, stdTol, rateTol, minBlock, satLevel)
            %ENABLEFREQSTATEGATE 打开在线的频率态锁定门控。
            %
            %   windowBlocks、expectedRate、meanHalfDiffTol、stdTol、rateTol
            %   与 satLevel 的含义与静态 detectFrequencyStateLock 上所述完全
            %   相同，因为在线门控原样转发给那个函数。expectedRate 可为 NaN、
            %   rateTol 可为 Inf，以仅测平坦性。
            %
            %   satLevel 可选，默认 Inf(禁用)。取有限值时会拒绝峰值幅度已钳在
            %   积分器饱和限上的窗口，因此调用方无需在喂入前预过滤饱和样本：
            %   在线判决在构造上与用同一 satLevel 评估的离线检测器完全一致。
            %
            %   minBlock 在环路仍处于捕获暂态时抑制触发，与 SNR settle 检测器
            %   自己的 minBlock 用意相同。此外，在观测到 windowBlocks 个样本
            %   之前门控也不会触发，因为过短的窗口会被判据本身拒绝。
            %
            %   这里用一次独立的配置调用而非增加构造函数参数，是为了让文档
            %   所述的 4 参数构造函数对每个既有调用方都保持有效。
            if nargin < 7 || nargin > 8
                error('loop_monitor:InvalidFreqGateConfig', ...
                    ['Expected windowBlocks, expectedRate, ', ...
                    'meanHalfDiffTol, stdTol, rateTol, minBlock, ', ...
                    'and optional satLevel.']);
            end
            if nargin < 8
                satLevel = Inf;
            end
            obj.validateInteger(windowBlocks, 2, ...
                'InvalidFreqGateWindow', 'windowBlocks');
            loop_monitor.validateFiniteOrNaNScalar(expectedRate, ...
                'expectedRate');
            loop_monitor.validateNonnegativeScalar(meanHalfDiffTol, ...
                'meanHalfDiffTol');
            loop_monitor.validateNonnegativeScalar(stdTol, 'stdTol');
            loop_monitor.validateNonnegativeScalarOrInf(rateTol, 'rateTol');
            obj.validateInteger(minBlock, 1, ...
                'InvalidFreqGateMinBlock', 'minBlock');
            loop_monitor.validateNonnegativeScalarOrInf(satLevel, 'satLevel');

            obj.FreqGateEnabled = true;
            obj.FreqGateWindow = double(windowBlocks);
            obj.FreqGateExpectedRate = double(expectedRate);
            obj.FreqGateMeanHalfDiffTol = double(meanHalfDiffTol);
            obj.FreqGateStdTol = double(stdTol);
            obj.FreqGateRateTol = double(rateTol);
            obj.FreqGateMinBlock = double(minBlock);
            obj.FreqGateSatLevel = double(satLevel);
            obj.FreqGateDone = false;
            obj.FreqGateBlock = NaN;
            obj.FreqGateSampleCount = 0;
            obj.FreqGateSkippedCount = 0;
            obj.FreqRingValue = nan(1, double(windowBlocks));
        end

        function [triggered, diag] = updateFreqStateGate(obj, blockIndex, ...
                freqState)
            %UPDATEFREQSTATEGATE 上报一次性的频率锁定跳变。
            %
            % freqState 是本块环路滤波器积分器的频率态(code/block)，取自本块
            % 环路滤波器更新之后，因此观测序列与记录下来的频率态 trace 逐个
            % 样本对齐。
            %
            % 非有限样本被跳过而非存储，因为判据会直接拒绝含非有限值的窗口；
            % 这样的样本会让离线检测器报错而非返回 false。跳过次数计入
            % FreqGateSkippedCount，使依赖跳过的运行不会与干净运行无声地混同。
            obj.requireFreqGateEnabled('updateFreqStateGate');
            obj.validateInteger(blockIndex, 1, 'InvalidBlock', 'blockIndex');
            isValidState = isnumeric(freqState) && isreal(freqState) && ...
                isscalar(freqState);
            if ~isValidState
                error('loop_monitor:InvalidFreqState', ...
                    'freqState must be a real scalar.');
            end

            triggered = false;
            % 诊断结构只在调用方真的要第二个输出时才构造。在线路径
            % (cdr_top) 每块只取 triggered 一个输出，而这个 8 字段 struct()
            % 过去在每一块都构造后立即丢弃——包括门控闩锁之后剩下的上万块，
            % 那时函数在下一行就返回了。它是本函数自身时间的主要来源。
            reportDiag = nargout > 1;
            if reportDiag
                diag = struct('WindowLength', 0, 'MeanValue', NaN, ...
                    'MeanHalfDiff', NaN, 'TailStd', NaN, ...
                    'ExpectedRate', obj.FreqGateExpectedRate, ...
                    'RateError', NaN, 'FlatnessOk', false, ...
                    'RateOk', false, 'SatOk', false);
            end
            if obj.FreqGateDone
                return;
            end
            if ~isfinite(freqState)
                obj.FreqGateSkippedCount = obj.FreqGateSkippedCount + 1;
                return;
            end

            window = obj.FreqGateWindow;
            obj.FreqGateSampleCount = obj.FreqGateSampleCount + 1;
            slot = mod(obj.FreqGateSampleCount - 1, window) + 1;
            obj.FreqRingValue(slot) = double(freqState);

            if obj.FreqGateSampleCount < window
                return;
            end
            if blockIndex < obj.FreqGateMinBlock
                return;
            end

            % 环形缓冲的从旧到新视图，即离线判据会从完整 trace 中取的同一个
            % 尾窗。窗口在构造上是有限的，且门控配置已在 enableFreqStateGate
            % 校验过，因此这里直接调用无校验的核，仅在调用方需要时才组装 diag。
            ordered = [obj.FreqRingValue(slot + 1:end), ...
                obj.FreqRingValue(1:slot)];
            if reportDiag
                [locked, diag] = loop_monitor.freqStateLockCore( ...
                    ordered, window, obj.FreqGateExpectedRate, ...
                    obj.FreqGateMeanHalfDiffTol, obj.FreqGateStdTol, ...
                    obj.FreqGateRateTol, obj.FreqGateSatLevel, true);
            else
                locked = loop_monitor.freqStateLockCore( ...
                    ordered, window, obj.FreqGateExpectedRate, ...
                    obj.FreqGateMeanHalfDiffTol, obj.FreqGateStdTol, ...
                    obj.FreqGateRateTol, obj.FreqGateSatLevel, false);
            end
            if locked
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
            state.FreqGateWindow = obj.FreqGateWindow;
            state.FreqGateExpectedRate = obj.FreqGateExpectedRate;
            state.FreqGateMeanHalfDiffTol = obj.FreqGateMeanHalfDiffTol;
            state.FreqGateStdTol = obj.FreqGateStdTol;
            state.FreqGateRateTol = obj.FreqGateRateTol;
            state.FreqGateSatLevel = obj.FreqGateSatLevel;
            state.FreqGateMinBlock = obj.FreqGateMinBlock;
            state.FreqGateDone = obj.FreqGateDone;
            state.FreqGateBlock = obj.FreqGateBlock;
            state.FreqGateSampleCount = obj.FreqGateSampleCount;
            state.FreqGateSkippedCount = obj.FreqGateSkippedCount;
        end
    end

    methods (Static)
        function [locked, diag] = detectFrequencyStateLock(freqStateSeq, ...
                windowBlocks, expectedRate, meanHalfDiffTol, stdTol, ...
                rateTol, satLevel)
            %DETECTFREQUENCYSTATELOCK 平坦均值环路频率锁定判据。
            %
            % 在频偏下，定时环靠保持一个恒定非零的积分器频率态
            % (code/block)来跟踪。该离线判据在尾窗内、当环路频率态为恒定
            % 时判锁：其前半与后半均值一致(<= meanHalfDiffTol)、std 很小
            % (<= stdTol)、且其幅值与期望漂移率匹配(|mean| 在 |expectedRate| 的
            % rateTol 内)。幅值匹配使通过/失败与符号约定无关，而返回的诊断量
            % 保留带符号的值。
            %
            % expectedRate 可为 NaN 以跳过速率匹配(纯平坦性)，rateTol 可为 Inf
            % 达到同样效果。
            %
            % satLevel 可选(默认 Inf = 禁用)。钳在积分器饱和限上的频率态也是
            % "完美平坦"(half-diff 0、std 0)，会通过纯平坦性分支，但它是 railed
            % 而非锁定。satLevel 有限时，一旦窗口峰值 max(|x|) >= satLevel 即拒绝
            % 该窗口，因此窗内任何一个 railed 样本都会阻止锁定。调用方因此无需
            % 再预过滤饱和样本：在线门控把自己的 satLevel 转发到这里，使在线
            % 判决在同一窗口、同一 satLevel 下与本离线判决在构造上完全一致。
            %
            % 数值工作住在私有的 freqStateLockCore 里，本方法先校验输入再调用
            % 它。核仅在调用方需要时才组装诊断 struct，所以单输出调用既不付
            % struct 构建的开销，也(通过直接调核的在线门控)不付输入校验的
            % 开销。两种路径的判决结果完全一致。
            if nargin < 7
                satLevel = Inf;
            end
            loop_monitor.validateFiniteRealVector(freqStateSeq, ...
                'InvalidFreqSeq', 'freqStateSeq');
            loop_monitor.validateIntegerArg(windowBlocks, 1, ...
                'InvalidWindowBlocks', 'windowBlocks');
            loop_monitor.validateFiniteOrNaNScalar(expectedRate, 'expectedRate');
            loop_monitor.validateNonnegativeScalar(meanHalfDiffTol, ...
                'meanHalfDiffTol');
            loop_monitor.validateNonnegativeScalar(stdTol, 'stdTol');
            loop_monitor.validateNonnegativeScalarOrInf(rateTol, 'rateTol');
            loop_monitor.validateNonnegativeScalarOrInf(satLevel, 'satLevel');
            if nargout > 1
                [locked, diag] = loop_monitor.freqStateLockCore(freqStateSeq, ...
                    windowBlocks, expectedRate, meanHalfDiffTol, stdTol, ...
                    rateTol, satLevel, true);
            else
                locked = loop_monitor.freqStateLockCore(freqStateSeq, ...
                    windowBlocks, expectedRate, meanHalfDiffTol, stdTol, ...
                    rateTol, satLevel, false);
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
        function [locked, diag] = freqStateLockCore(freqStateSeq, ...
                windowBlocks, expectedRate, meanHalfDiffTol, stdTol, ...
                rateTol, satLevel, wantDiag)
            %FREQSTATELOCKCORE 平坦均值环路频率锁定判据的无校验数值核。
            % 由公开的 detectFrequencyStateLock(先校验)与在线的
            % updateFreqStateGate(其窗口在构造上有限、配置已在
            % enableFreqStateGate 校验)共用，故二者得到完全一致的判决。
            % 热的在线路径既不付输入校验，也(在 wantDiag 为 false 时)不付
            % 8 字段诊断 struct 的构建。
            seq = reshape(double(freqStateSeq), 1, []);
            totalLength = numel(seq);
            windowLength = min(totalLength, double(windowBlocks));
            if windowLength < 2
                locked = false;
                if wantDiag
                    diag = struct('WindowLength', windowLength, ...
                        'MeanValue', NaN, 'MeanHalfDiff', NaN, ...
                        'TailStd', NaN, 'ExpectedRate', double(expectedRate), ...
                        'RateError', NaN, 'FlatnessOk', false, ...
                        'RateOk', false, 'SatOk', false);
                end
                return;
            end

            window = seq(totalLength - windowLength + 1:end);
            half = floor(windowLength / 2);
            meanFirst = mean(window(1:half));
            meanSecond = mean(window(half + 1:end));
            meanValue = mean(window);
            meanHalfDiff = abs(meanFirst - meanSecond);
            tailStd = std(window);
            flatnessOk = meanHalfDiff <= meanHalfDiffTol && tailStd <= stdTol;
            if isnan(expectedRate) || ~isfinite(rateTol)
                rateOk = true;
            else
                rateOk = abs(abs(meanValue) - abs(double(expectedRate))) <= ...
                    rateTol;
            end
            satOk = max(abs(window)) < double(satLevel);
            locked = totalLength >= double(windowBlocks) && ...
                flatnessOk && rateOk && satOk;
            if wantDiag
                diag = struct('WindowLength', windowLength, ...
                    'MeanValue', meanValue, 'MeanHalfDiff', meanHalfDiff, ...
                    'TailStd', tailStd, 'ExpectedRate', double(expectedRate), ...
                    'RateError', meanValue - double(expectedRate), ...
                    'FlatnessOk', flatnessOk, 'RateOk', rateOk, 'SatOk', satOk);
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
