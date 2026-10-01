classdef cdr_loop < handle
%CDR_LOOP 数字 PI 环路滤波器（定点版）。
%
%   对应浮点参考 src/CDR/cdr_loop.m。两处必须注意的定点特性：
%
%   1. **取整语义**。浮点版用的是 fix()（向零取整），不是 floor。算术右移是
%      floor，对负数结果不同（-1.7 -> fix 得 -1，floor 得 -2）。直接写移位会在
%      零点附近引入方向不对称的偏置，而本项目已存在负 ppm 方向的捕获不对称
%      （冷启动盲区，负向上限 -30 ppm vs 正向 +110 ppm），一旦混进 floor/fix
%      错误几乎必然被误诊成物理现象。因此这里显式调 fxq.fixToZero。
%
%   2. **增益已折入 1/BlockSize**。上游定点 voter 不再做除法，输出整数求和，
%      所以构造时传入的 Kp/Ki 应当是浮点值除以 BlockSize 后的结果
%      （8.0 -> 0.125, 0.03 -> 4.6875e-4）。本类不自己做这个换算，由调用方
%      在配置层完成，避免同一个换算散落两处。
%
%   三个状态量的分工与浮点版相同：
%     FrequencyState  code/block，积分器，即频差估计
%     CodeResidue     |·|<1，小数残量，防止不足 1 code 的控制量被丢弃
%     PendingCode     整数，被 slew 限幅拒绝执行的积压，是饱和的灵敏先兆

    properties (SetAccess = private)
        Kp              double
        Ki              double
        FrequencyMin    double
        FrequencyMax    double
        MaxDeltaCode    double

        FrequencyState  double
        CodeResidue     double
        PendingCode     double
        LastControl     double

        FmtKp           struct
        FmtKi           struct
        FmtFreq         struct
        FmtControl      struct
        FmtResidue      struct
        FmtPending      struct
        FmtDelta        struct

        OverflowFreq    double
        OverflowControl double
        OverflowResidue double
        OverflowPending double
    end

    methods
        function obj = cdr_loop(kp, ki, frequencyMin, frequencyMax, maxDeltaCode)
            %CDR_LOOP 构造定点 PI 环路滤波器。
            %   kp/ki 必须是**已折入 1/BlockSize** 的值，见类头说明。
            obj.FmtKp = cdr_fx.fxfmt.loopGainKp();
            obj.FmtKi = cdr_fx.fxfmt.loopGainKi();
            obj.FmtFreq = cdr_fx.fxfmt.freqState();
            obj.FmtControl = cdr_fx.fxfmt.loopControl();
            obj.FmtResidue = cdr_fx.fxfmt.codeResidue();
            obj.FmtPending = cdr_fx.fxfmt.pendingCode();
            obj.FmtDelta = cdr_fx.fxfmt.deltaCode();

            % 增益是配置常量，在装载时一次性量化到其格式栅格上。取 round 是因为
            % 这一步代表"综合时把常量写进寄存器"，不是运行期的数据通路取整。
            obj.Kp = cdr_fx.fxq.apply(kp, obj.FmtKp, 'round');
            obj.Ki = cdr_fx.fxq.apply(ki, obj.FmtKi, 'round');

            obj.setFrequencyLimits(frequencyMin, frequencyMax);
            obj.setMaxDeltaCode(maxDeltaCode);
            obj.resetState();
        end

        function deltaCode = updateFast(obj, phaseError)
            %UPDATEFAST 一次块级更新。phaseError 是 voter 的整数求和。
            fx = cdr_fx.fxq;

            % 积分支路。Ki*pe 的乘积小数位是 FmtKi.FracBits（pe 是整数），
            % 回缩到频率态格式后再累加，然后按 FrequencyMin/Max 饱和。
            % 这里用 'round' 而不是 'floor'：floor 每次累加都引入 -0.5 LSB 的
            % 系统偏置，而积分器会把它一路累积，直到 PD 产生一个反向偏置来平衡，
            % 最终表现为采样相位偏移。实测 0 ppm 下 floor 留下 -0.0035 的残余
            % 频率态(约 115 个 LSB)。RTL 里 round 就是"加半个 LSB 再截断"，
            % 只多一个常数加法器，代价可忽略。
            kiTerm = fx.quant(obj.Ki * phaseError, obj.FmtFreq.FracBits, 'round');
            freqRaw = obj.FrequencyState + kiTerm;
            freqRaw = min(max(freqRaw, obj.FrequencyMin), obj.FrequencyMax);
            [obj.FrequencyState, nOv] = fx.apply(freqRaw, obj.FmtFreq, 'floor');
            obj.OverflowFreq = obj.OverflowFreq + nOv;

            % 比例支路 + 合成控制量。
            kpTerm = fx.quant(obj.Kp * phaseError, obj.FmtControl.FracBits, 'floor');
            controlRaw = kpTerm + obj.FrequencyState;
            [control, nOv] = fx.apply(controlRaw, obj.FmtControl, 'floor');
            obj.OverflowControl = obj.OverflowControl + nOv;
            obj.LastControl = control;

            % 残量累加后取整出整数码。**这里必须是向零取整**，见类头第 1 条。
            residueAccum = obj.CodeResidue + control;
            rawDeltaCode = fx.fixToZero(residueAccum, 0);

            % 剩下不足 1 code 的部分留给下一块。
            [obj.CodeResidue, nOv] = fx.apply( ...
                residueAccum - rawDeltaCode, obj.FmtResidue, 'floor');
            obj.OverflowResidue = obj.OverflowResidue + nOv;

            % slew 限幅：超出的整数码进入积压，不丢弃。
            pendingAccum = obj.PendingCode + rawDeltaCode;
            deltaCode = min(max(pendingAccum, -obj.MaxDeltaCode), obj.MaxDeltaCode);
            deltaCode = fx.sat(deltaCode, obj.FmtDelta);

            % 积压必须钳位：浮点版它无界增长，RTL 不可能。钳位值 ±1024 远大于
            % slew 饱和守卫的阈值 0.5（均值），因此钳位不会影响饱和判决，
            % 但能防止 +120~+130 ppm 边界下寄存器回绕。
            [obj.PendingCode, nOv] = fx.apply( ...
                pendingAccum - deltaCode, obj.FmtPending, 'fix');
            obj.OverflowPending = obj.OverflowPending + nOv;
        end

        function deltaCode = update(obj, phaseError)
            %UPDATE 带校验的入口。数值与 updateFast 完全一致。
            if ~isnumeric(phaseError) || ~isscalar(phaseError) || ~isfinite(phaseError)
                error('cdr_fx:cdr_loop:InvalidPhaseError', ...
                    'phaseError 必须是有限数值标量。');
            end
            deltaCode = obj.updateFast(double(phaseError));
        end

        function setFrequencyLimits(obj, frequencyMin, frequencyMax)
            %SETFREQUENCYLIMITS 设置积分器饱和区间，并立即把当前状态夹回区间。
            if ~isnumeric(frequencyMin) || ~isscalar(frequencyMin) || ...
                    ~isnumeric(frequencyMax) || ~isscalar(frequencyMax) || ...
                    frequencyMin > frequencyMax
                error('cdr_fx:cdr_loop:InvalidFrequencyLimits', ...
                    'frequencyMin 必须不大于 frequencyMax。');
            end
            obj.FrequencyMin = cdr_fx.fxq.quant(frequencyMin, obj.FmtFreq.FracBits, 'ceil');
            obj.FrequencyMax = cdr_fx.fxq.quant(frequencyMax, obj.FmtFreq.FracBits, 'floor');
            if ~isempty(obj.FrequencyState)
                obj.FrequencyState = min(max(obj.FrequencyState, ...
                    obj.FrequencyMin), obj.FrequencyMax);
            end
        end

        function setMaxDeltaCode(obj, maxDeltaCode)
            %SETMAXDELTACODE 设置每块 PI 码增量上限。必须是正整数或 Inf。
            if isempty(maxDeltaCode)
                maxDeltaCode = Inf;
            end
            if ~isnumeric(maxDeltaCode) || ~isscalar(maxDeltaCode) || ...
                    maxDeltaCode <= 0 || ...
                    (isfinite(maxDeltaCode) && maxDeltaCode ~= floor(maxDeltaCode))
                error('cdr_fx:cdr_loop:InvalidMaxDeltaCode', ...
                    'maxDeltaCode 必须是正整数或 Inf。');
            end
            obj.MaxDeltaCode = double(maxDeltaCode);
        end

        function setGains(obj, kp, ki)
            %SETGAINS 运行期改增益。传入值同样应已折入 1/BlockSize。
            obj.Kp = cdr_fx.fxq.apply(kp, obj.FmtKp, 'round');
            obj.Ki = cdr_fx.fxq.apply(ki, obj.FmtKi, 'round');
        end

        function resetState(obj)
            %RESETSTATE 清零动态状态与溢出统计，保留增益与限幅配置。
            obj.FrequencyState = 0;
            obj.CodeResidue = 0;
            obj.PendingCode = 0;
            obj.LastControl = 0;
            obj.OverflowFreq = 0;
            obj.OverflowControl = 0;
            obj.OverflowResidue = 0;
            obj.OverflowPending = 0;
        end

        function s = getState(obj)
            %GETSTATE 只读快照，含逐节点溢出计数。
            s = struct( ...
                'Kp', obj.Kp, 'Ki', obj.Ki, ...
                'FrequencyMin', obj.FrequencyMin, 'FrequencyMax', obj.FrequencyMax, ...
                'MaxDeltaCode', obj.MaxDeltaCode, ...
                'FrequencyState', obj.FrequencyState, ...
                'CodeResidue', obj.CodeResidue, ...
                'PendingCode', obj.PendingCode, ...
                'LastControl', obj.LastControl, ...
                'OverflowFreq', obj.OverflowFreq, ...
                'OverflowControl', obj.OverflowControl, ...
                'OverflowResidue', obj.OverflowResidue, ...
                'OverflowPending', obj.OverflowPending);
        end
    end
end
