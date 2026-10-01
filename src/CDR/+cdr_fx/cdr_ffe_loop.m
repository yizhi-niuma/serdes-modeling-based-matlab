classdef cdr_ffe_loop < handle
%CDR_FFE_LOOP FFE 系数自适应引擎（定点版）。
%
%   对应浮点参考 src/CDR/cdr_ffe_loop.m。本类持有**宽累加器**，是整个定点化
%   里字长最吃紧的地方：
%
%   实测逐块最小系数增量 3.125e-6，反推需要 22 位小数（LSB≈2.4e-7）。这比凭
%   经验估的 20 位多 2 位 —— 若按 20 位（LSB≈9.5e-7）做，相当一部分单块更新量
%   会小于 LSB 而被取整丢弃，累加器进入**死区停摆**：环路看上去收敛了，实际
%   是冻住的，而且波形上几乎看不出来。这就是范围普查必须先做的理由。
%
%   结构上是「宽累加器 + 窄输出」：本类维护 (1,24,22) 的累加器，每块更新后把
%   截断到 (1,12,10) 的值推给 cdr_ffe 去做乘累加。
%
%   主抽头始终被掩码排除，且累加器里主抽头位恒为 1、永不更新。

    properties (SetAccess = private)
        StepSize            double
        TapCount            double
        MainTapIndex        double
        BlockSize           double
        AdaptEnableMask     logical

        CoeffAccum          double   % 宽累加器 (1,24,22)
        FmtAccum            struct
        FmtStep             struct
        ShiftBits           double
        OverflowAccum       double
        UpdateCount         double
        LastDelta           double
    end

    methods
        function obj = cdr_ffe_loop(stepSize, tapCount, mainTapIndex, blockSize, adaptEnableMask)
            %CDR_FFE_LOOP 构造定点 LMS 引擎。
            if nargin < 2 || isempty(tapCount); tapCount = 6; end
            if nargin < 3 || isempty(mainTapIndex); mainTapIndex = 3; end
            if nargin < 4 || isempty(blockSize); blockSize = 64; end
            if nargin < 5 || isempty(adaptEnableMask)
                adaptEnableMask = true(1, tapCount);
                adaptEnableMask(mainTapIndex) = false;
            end

            if log2(blockSize) ~= floor(log2(blockSize))
                error('cdr_fx:cdr_ffe_loop:InvalidBlockSize', ...
                    'blockSize 必须是 2 的幂，否则块平均无法用移位实现。');
            end
            mask = logical(adaptEnableMask(:)).';
            if numel(mask) ~= tapCount
                error('cdr_fx:cdr_ffe_loop:InvalidMask', ...
                    'adaptEnableMask 长度必须等于抽头数。');
            end
            if mask(mainTapIndex)
                error('cdr_fx:cdr_ffe_loop:MainTapAdaptEnabled', ...
                    '主抽头被四层硬冻结，掩码不得使能它。');
            end

            obj.FmtAccum = cdr_fx.fxfmt.ffeCoeffAccum();
            obj.FmtStep = cdr_fx.fxfmt.ffeStep();

            obj.TapCount = double(tapCount);
            obj.MainTapIndex = double(mainTapIndex);
            obj.BlockSize = double(blockSize);
            obj.ShiftBits = log2(obj.BlockSize);
            obj.AdaptEnableMask = mask;
            obj.setStepSize(stepSize);

            obj.CoeffAccum = zeros(1, obj.TapCount);
            obj.CoeffAccum(obj.MainTapIndex) = 1;
            obj.OverflowAccum = 0;
            obj.UpdateCount = 0;
            obj.LastDelta = zeros(1, obj.TapCount);
        end

        function delta = updateSsLmsFast(obj, dataRegressor, errorVector)
            %UPDATESSLMSFAST 符号-符号 LMS 块更新，返回本块施加的系数增量。
            %
            %   gradient = sign(e) * sign(X) / BlockSize
            %   梯度幅度与信号幅度无关且上界为 1，所以步长要比标准 LMS 大得多。
            %   SS-LMS 只用符号，这让它对定点字长远比全精度 LMS 宽容 —— 本设计
            %   的字长压力全在累加器一侧，不在梯度一侧。
            fx = cdr_fx.fxq;
            if isempty(errorVector)
                delta = zeros(1, obj.TapCount);
                return;
            end

            sgnE = fx.sign3(double(errorVector(:)).');
            sgnX = fx.sign3(double(dataRegressor));
            % 除以 BlockSize：2 的幂，等价于算术右移。
            gradient = fx.quant((sgnE * sgnX) / obj.BlockSize, ...
                obj.FmtAccum.FracBits, 'floor');

            % 符号约定必须与浮点参考一致：cdr_ffe_loop.updateSsLmsFast 用的是
            % +StepSize * gradient，配合 cdr_top 传入的 error = decision -
            % ffeOutput。若照搬教科书里 e = x - d 对应的 -StepSize，LMS 会反向
            % 收敛 —— 实测表现为 pre1 抽头符号翻转（+0.497 而非 -0.226）、
            % 眼睛打不开（末段 SNR 9.65 dB 对 23.57 dB）、第一级门控永不触发。
            rawDelta = fx.quant(obj.StepSize * gradient, ...
                obj.FmtAccum.FracBits, 'floor');
            rawDelta(~obj.AdaptEnableMask) = 0;
            rawDelta(obj.MainTapIndex) = 0;   % 纵深防御，掩码已保证

            [newAccum, nOv] = fx.apply(obj.CoeffAccum + rawDelta, obj.FmtAccum, 'floor');
            newAccum(obj.MainTapIndex) = 1;
            delta = newAccum - obj.CoeffAccum;

            obj.CoeffAccum = newAccum;
            obj.OverflowAccum = obj.OverflowAccum + nOv;
            obj.UpdateCount = obj.UpdateCount + 1;
            obj.LastDelta = delta;
        end

        function delta = updateSsLms(obj, dataRegressor, errorVector)
            %UPDATESSLMS 带校验的入口。数值与 updateSsLmsFast 完全一致。
            if ~isnumeric(dataRegressor) || ~ismatrix(dataRegressor) || ...
                    ~all(isfinite(dataRegressor(:)))
                error('cdr_fx:cdr_ffe_loop:InvalidRegressor', ...
                    'dataRegressor 必须是有限数值矩阵。');
            end
            if size(dataRegressor, 2) ~= obj.TapCount
                error('cdr_fx:cdr_ffe_loop:InvalidRegressor', ...
                    'dataRegressor 列数必须等于抽头数 %d。', obj.TapCount);
            end
            if numel(errorVector) ~= size(dataRegressor, 1)
                error('cdr_fx:cdr_ffe_loop:SizeMismatch', ...
                    'errorVector 长度必须等于回归矩阵行数。');
            end
            delta = obj.updateSsLmsFast(dataRegressor, errorVector);
        end

        function c = coefficients(obj)
            %COEFFICIENTS 宽累加器的当前值。调用方负责截断后送 cdr_ffe。
            c = obj.CoeffAccum;
        end

        function setStepSize(obj, stepSize)
            %SETSTEPSIZE 修改步长，不复位累加器。
            if ~isnumeric(stepSize) || ~isscalar(stepSize) || ...
                    ~isfinite(stepSize) || stepSize < 0
                error('cdr_fx:cdr_ffe_loop:InvalidStepSize', ...
                    'stepSize 必须是非负有限标量。');
            end
            obj.StepSize = cdr_fx.fxq.apply(stepSize, obj.FmtStep, 'round');
        end

        function setCoefficients(obj, c)
            %SETCOEFFICIENTS 直接装载累加器初值（用于冷启动配置）。
            v = double(c(:)).';
            v(obj.MainTapIndex) = 1;
            obj.CoeffAccum = cdr_fx.fxq.apply(v, obj.FmtAccum, 'round');
            obj.CoeffAccum(obj.MainTapIndex) = 1;
        end

        function resetState(obj)
            %RESETSTATE 清空诊断量与更新计数，保留系数。
            obj.OverflowAccum = 0;
            obj.UpdateCount = 0;
            obj.LastDelta = zeros(1, obj.TapCount);
        end

        function s = getState(obj)
            %GETSTATE 只读快照。
            s = struct( ...
                'StepSize', obj.StepSize, ...
                'TapCount', obj.TapCount, ...
                'MainTapIndex', obj.MainTapIndex, ...
                'BlockSize', obj.BlockSize, ...
                'AdaptEnableMask', obj.AdaptEnableMask, ...
                'CoeffAccum', obj.CoeffAccum, ...
                'LastDelta', obj.LastDelta, ...
                'UpdateCount', obj.UpdateCount, ...
                'OverflowAccum', obj.OverflowAccum);
        end
    end
end
