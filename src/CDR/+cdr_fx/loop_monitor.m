classdef loop_monitor < handle
%LOOP_MONITOR 因果策略判决器（定点版，仅在线检测器算硅）。
%
%   范围界定（用户 2026-10-01 决策）：
%     算硅   —— SNR settle 检测器、频率态门控。两者都必须可综合。
%     不算硅 —— 静态离线判据 detectFrequencyStateLock / detectRotationPeriodLock。
%               它们只在仿真结束后对轨迹做事后判定，属测试台，保持浮点。
%
%   与浮点参考的两处结构性改写：
%
%   1. **dB 判据换域。** 10*log10(Pd/Pe) >= T 等价于 Pd >= 10^(T/10) * Pe。
%      一次乘法，无对数，判决完全等价，而且 Inf/NaN 分支同时消失。
%
%   2. **频率态门控从「2048 深滑窗求 mean/std」改为多级指数平均。**
%      用户要求用类似眼图质量检测器的低成本指数平均替代取 mean，允许多用几个
%      寄存器。本类用三个：
%
%        ewmaFast (α=1/64)   快速跟随
%        ewmaSlow (α=1/512)  慢速基准
%        ewmaMad  (α=1/256)  |x - ewmaSlow| 的指数平均，替代标准差
%
%      判据映射（与原窗口判据语义一一对应）：
%        原「尾窗分半均值差小」-> |ewmaFast - ewmaSlow| <= MeanHalfDiffTol
%        原「尾窗 std 小」      -> ewmaMad <= StdTol
%        原「与期望速率匹配」   -> |ewmaSlow - ExpectedRate| <= RateTol
%
%      成本对比：3 个寄存器 + 3 次「移位-减-加」，对比原来的 2048 深缓冲 +
%      宽加法树 + 54 位平方和累加器。面积与功耗低一个数量级以上，且不再需要
%      把窗口长度凑成 2 的幂（原方案 2000->2048 会改变判据数值）。
%
%      MAD 与 std 的关系：对高斯分布 MAD ≈ 0.7979*std，所以 StdTol 沿用原值
%      时判据略严。这是刻意的保守选择，宁可晚触发也不要早触发 —— 早触发正是
%      2026-09-26 那次 -100 ppm 全相位失败的根因。

    properties (SetAccess = private)
        % ---- SNR settle 检测器 ----
        SnrEnabled          logical
        SnrThresholdRatio   double   % 已从 dB 换算成功率比
        SnrAlpha            double
        SnrMinBlock         double
        SnrEwma             double
        SnrSeeded           logical
        SnrSettleDone       logical
        SnrSettleBlock      double

        % ---- 频率态门控 ----
        FreqEnabled         logical
        FreqAlphaFast       double
        FreqAlphaSlow       double
        FreqAlphaMad        double
        FreqMeanHalfDiffTol double
        FreqStdTol          double
        FreqRateTol         double
        FreqExpectedRate    double
        FreqMinBlock        double
        FreqEwmaFast        double
        FreqEwmaSlow        double
        FreqEwmaMad         double
        FreqSeeded          logical
        FreqGateLatched     logical
        FreqGateBlock       double

        FmtSnr              struct
        FmtFreq             struct
    end

    methods
        function obj = loop_monitor()
            %LOOP_MONITOR 零参构造，与浮点参考保持一致。
            obj.FmtSnr = cdr_fx.fxfmt.snrEwma();
            obj.FmtFreq = cdr_fx.fxfmt.freqEwma();
            obj.resetState();
        end

        % ================= SNR settle 检测器（算硅） =================

        function enableSnrSettle(obj, thresholdDb, alpha, minBlock)
            %ENABLESNRSETTLE 配置第一级门控。
            %   thresholdDb 在这里一次性换算成功率比，运行期不再有对数。
            obj.SnrEnabled = true;
            obj.SnrThresholdRatio = 10 ^ (double(thresholdDb) / 10);
            obj.SnrAlpha = obj.toPowerOfTwoAlpha(alpha, 'SnrSettleAlpha');
            obj.SnrMinBlock = double(minBlock);
        end

        function triggered = updateSnrSettle(obj, blockIndex, decisionPower, errorPower)
            %UPDATESNRSETTLE 用功率比而非 dB 推进 EWMA，返回是否已触发。
            %
            %   注意入参是两路功率而不是一个 dB 值：换域的全部意义就在于让
            %   对数留在测试台、不进硅。调用方给出 mean(d^2) 与 mean(e^2)。
            triggered = obj.SnrSettleDone;
            if ~obj.SnrEnabled || triggered
                return;
            end
            if ~isfinite(decisionPower) || ~isfinite(errorPower) || errorPower <= 0
                % 非有限读数跳过，不污染 EWMA。
                return;
            end

            ratio = decisionPower / errorPower;
            if ~obj.SnrSeeded
                obj.SnrEwma = ratio;          % 用首个可用值播种
                obj.SnrSeeded = true;
            else
                obj.SnrEwma = obj.SnrEwma + obj.SnrAlpha * (ratio - obj.SnrEwma);
            end
            obj.SnrEwma = cdr_fx.fxq.apply(obj.SnrEwma, obj.FmtSnr, 'floor');

            if blockIndex >= obj.SnrMinBlock && obj.SnrEwma >= obj.SnrThresholdRatio
                obj.SnrSettleDone = true;     % 一旦为真即锁存，不回落
                obj.SnrSettleBlock = blockIndex;
                triggered = true;
            end
        end

        % ================= 频率态门控（算硅，EWMA 版） =================

        function enableFreqStateGate(obj, expectedRate, meanHalfDiffTol, ...
                stdTol, rateTol, minBlock, alphaFast, alphaSlow, alphaMad)
            %ENABLEFREQSTATEGATE 配置第二级门控。
            %   三个 α 必须是 2 的负幂，这样 EWMA 就是「移位-减-加」。
            if nargin < 7 || isempty(alphaFast); alphaFast = 1/64; end
            if nargin < 8 || isempty(alphaSlow); alphaSlow = 1/512; end
            if nargin < 9 || isempty(alphaMad);  alphaMad  = 1/256; end

            obj.FreqEnabled = true;
            obj.FreqExpectedRate = double(expectedRate);
            obj.FreqMeanHalfDiffTol = double(meanHalfDiffTol);
            obj.FreqStdTol = double(stdTol);
            obj.FreqRateTol = double(rateTol);
            obj.FreqMinBlock = double(minBlock);
            obj.FreqAlphaFast = obj.toPowerOfTwoAlpha(alphaFast, 'FreqAlphaFast');
            obj.FreqAlphaSlow = obj.toPowerOfTwoAlpha(alphaSlow, 'FreqAlphaSlow');
            obj.FreqAlphaMad = obj.toPowerOfTwoAlpha(alphaMad, 'FreqAlphaMad');
        end

        function [triggered, diag] = updateFreqStateGate(obj, blockIndex, freqState)
            %UPDATEFREQSTATEGATE 推进三条 EWMA 并判定频率态是否已平坦。
            triggered = obj.FreqGateLatched;
            diag = struct('Fast', obj.FreqEwmaFast, 'Slow', obj.FreqEwmaSlow, ...
                'Mad', obj.FreqEwmaMad, 'Flat', false, 'Quiet', false, 'RateOk', false);
            if ~obj.FreqEnabled || triggered || ~isfinite(freqState)
                return;
            end

            fx = cdr_fx.fxq;
            if ~obj.FreqSeeded
                obj.FreqEwmaFast = freqState;
                obj.FreqEwmaSlow = freqState;
                obj.FreqEwmaMad = 0;
                obj.FreqSeeded = true;
            else
                obj.FreqEwmaFast = obj.FreqEwmaFast + ...
                    obj.FreqAlphaFast * (freqState - obj.FreqEwmaFast);
                obj.FreqEwmaSlow = obj.FreqEwmaSlow + ...
                    obj.FreqAlphaSlow * (freqState - obj.FreqEwmaSlow);
                dev = abs(freqState - obj.FreqEwmaSlow);
                obj.FreqEwmaMad = obj.FreqEwmaMad + ...
                    obj.FreqAlphaMad * (dev - obj.FreqEwmaMad);
            end
            obj.FreqEwmaFast = fx.apply(obj.FreqEwmaFast, obj.FmtFreq, 'floor');
            obj.FreqEwmaSlow = fx.apply(obj.FreqEwmaSlow, obj.FmtFreq, 'floor');
            obj.FreqEwmaMad = fx.apply(obj.FreqEwmaMad, obj.FmtFreq, 'floor');

            % 三条判据，语义与原窗口判据一一对应，见类头。
            isFlat = abs(obj.FreqEwmaFast - obj.FreqEwmaSlow) <= obj.FreqMeanHalfDiffTol;
            isQuiet = obj.FreqEwmaMad <= obj.FreqStdTol;
            if isfinite(obj.FreqExpectedRate) && isfinite(obj.FreqRateTol)
                rateOk = abs(obj.FreqEwmaSlow - obj.FreqExpectedRate) <= obj.FreqRateTol;
            else
                rateOk = true;
            end

            diag.Fast = obj.FreqEwmaFast;
            diag.Slow = obj.FreqEwmaSlow;
            diag.Mad = obj.FreqEwmaMad;
            diag.Flat = isFlat;
            diag.Quiet = isQuiet;
            diag.RateOk = rateOk;

            if blockIndex >= obj.FreqMinBlock && isFlat && isQuiet && rateOk
                obj.FreqGateLatched = true;
                obj.FreqGateBlock = blockIndex;
                triggered = true;
            end
        end

        function tf = gateLatched(obj)
            %GATELATCHED 第二级门控是否已闩锁。
            tf = obj.FreqGateLatched;
        end

        function resetState(obj)
            %RESETSTATE 清空全部在线状态。
            obj.SnrEnabled = false;
            obj.SnrThresholdRatio = Inf;
            obj.SnrAlpha = 1 / 128;
            obj.SnrMinBlock = 0;
            obj.SnrEwma = 0;
            obj.SnrSeeded = false;
            obj.SnrSettleDone = false;
            obj.SnrSettleBlock = NaN;

            obj.FreqEnabled = false;
            obj.FreqAlphaFast = 1 / 64;
            obj.FreqAlphaSlow = 1 / 512;
            obj.FreqAlphaMad = 1 / 256;
            obj.FreqMeanHalfDiffTol = Inf;
            obj.FreqStdTol = Inf;
            obj.FreqRateTol = Inf;
            obj.FreqExpectedRate = NaN;
            obj.FreqMinBlock = 0;
            obj.FreqEwmaFast = 0;
            obj.FreqEwmaSlow = 0;
            obj.FreqEwmaMad = 0;
            obj.FreqSeeded = false;
            obj.FreqGateLatched = false;
            obj.FreqGateBlock = NaN;
        end

        function s = getState(obj)
            %GETSTATE 只读快照。
            s = struct( ...
                'SnrEnabled', obj.SnrEnabled, ...
                'SnrThresholdRatio', obj.SnrThresholdRatio, ...
                'SnrEwma', obj.SnrEwma, ...
                'SnrSettleDone', obj.SnrSettleDone, ...
                'SnrSettleBlock', obj.SnrSettleBlock, ...
                'FreqEnabled', obj.FreqEnabled, ...
                'FreqEwmaFast', obj.FreqEwmaFast, ...
                'FreqEwmaSlow', obj.FreqEwmaSlow, ...
                'FreqEwmaMad', obj.FreqEwmaMad, ...
                'FreqGateLatched', obj.FreqGateLatched, ...
                'FreqGateBlock', obj.FreqGateBlock);
        end
    end

    methods (Access = private)
        function a = toPowerOfTwoAlpha(~, alpha, name)
            %TOPOWEROFTWOALPHA 校验 α 是 2 的负幂，否则 EWMA 无法用移位实现。
            a = double(alpha);
            if ~isfinite(a) || a <= 0 || a > 1
                error('cdr_fx:loop_monitor:InvalidAlpha', ...
                    '%s 必须落在 (0, 1]。', name);
            end
            k = log2(1 / a);
            if abs(k - round(k)) > 1e-12
                error('cdr_fx:loop_monitor:AlphaNotPowerOfTwo', ...
                    '%s 必须是 2 的负幂，否则 EWMA 不能用移位实现。', name);
            end
        end
    end
end
