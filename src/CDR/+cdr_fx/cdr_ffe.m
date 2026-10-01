classdef cdr_ffe < handle
%CDR_FFE 时序路径专用符号间隔 FFE（定点版）。
%
%   对应浮点参考 src/CDR/cdr_ffe.m。核心定点特性：
%
%   **主抽头恒为 1，不进乘法器。** 主抽头在浮点版被四层硬冻结
%   （cdr_ffe.m:86-88 / :130-133、cdr_ffe_loop.m:146-148、cdr_top.m:472-480），
%   既然它恒等于 1，那一路乘法就是 1*sample，在硬件上是一根直通到加法器的线。
%   因此 6 抽头 FFE 实际只需要 **5 个乘法器**，且主抽头不需要任何系数寄存器。
%   本类把主抽头从乘累加里单独拆出来，正是为了让这个结构在模型上可见。
%
%   系数采用**宽累加器 + 窄输出**双格式：
%     送乘法器 (1,12,10)  LSB≈9.8e-4，相对 FFE 一致性容差 0.02 足够细
%     LMS 累加器 (1,24,22) LSB≈2.4e-7，由实测最小增量 3.125e-6 反推
%   若只用窄格式做累加，单块更新量会小于 LSB 而被丢弃，自适应直接死区停摆。
%   累加器由 cdr_ffe_loop 持有，本类只持有送乘法器的窄系数。
%
%   回归向量的时间方向与浮点版一致：系数 [pre2 pre1 main post1 post2 post3]
%   依次乘窗口样本 [未来2 未来1 当前 过去1 过去2 过去3]。方向错了 LMS 会反向
%   收敛，这是本模块最隐蔽的错误之一。

    properties (SetAccess = private)
        TapCount        double
        PreTapCount     double
        PostTapCount    double
        MainTapIndex    double

        Coefficients    double   % 窄格式，主抽头位恒为 1
        FmtCoeff        struct
        FmtIn           struct
        FmtOut          struct
        OverflowOut     double
    end

    methods
        function obj = cdr_ffe(initialCoefficients, preTapCount)
            %CDR_FFE 构造定点 FFE。
            if nargin < 1 || isempty(initialCoefficients)
                initialCoefficients = [0 0 1 0 0 0];
            end
            if nargin < 2 || isempty(preTapCount)
                preTapCount = 2;
            end
            c = double(initialCoefficients(:)).';
            obj.TapCount = numel(c);
            obj.PreTapCount = double(preTapCount);
            obj.MainTapIndex = obj.PreTapCount + 1;
            obj.PostTapCount = obj.TapCount - obj.MainTapIndex;

            if obj.MainTapIndex < 1 || obj.MainTapIndex > obj.TapCount
                error('cdr_fx:cdr_ffe:InvalidPreTapCount', ...
                    'preTapCount 使主抽头索引越界。');
            end
            if c(obj.MainTapIndex) ~= 1
                error('cdr_fx:cdr_ffe:InvalidMainTap', ...
                    '初始系数的主抽头必须恒等于 1。');
            end

            obj.FmtCoeff = cdr_fx.fxfmt.ffeCoeffMul();
            obj.FmtIn = cdr_fx.fxfmt.adcCode();
            obj.FmtOut = cdr_fx.fxfmt.ffeOutput();

            obj.Coefficients = cdr_fx.fxq.apply(c, obj.FmtCoeff, 'round');
            obj.Coefficients(obj.MainTapIndex) = 1;   % 主抽头不受量化影响
            obj.OverflowOut = 0;
        end

        function [outputBlock, regressors] = processBlockFast(obj, inputWindow)
            %PROCESSBLOCKFAST 对一个完整输入窗口做 FIR，不做校验。
            %
            %   inputWindow = [PostTapCount 个过去样本, 目标块, PreTapCount 个未来样本]
            %   第二个返回值是 BlockSize×TapCount 的回归矩阵，直接喂给
            %   cdr_ffe_loop 做 LMS。两者必须出自同一次索引，否则 LMS 的回归
            %   与误差会错位。
            x = double(inputWindow(:)).';
            blockLength = numel(x) - obj.PostTapCount - obj.PreTapCount;
            if blockLength <= 0
                outputBlock = zeros(1, 0);
                regressors = zeros(0, obj.TapCount);
                return;
            end

            % 回归矩阵：索引递减，使系数向量与 [未来..当前..过去] 对齐。
            firstTapSampleIndex = (obj.TapCount - 1) + (1:blockLength).';
            regressorIndex = firstTapSampleIndex - (0:obj.TapCount - 1);
            regressors = x(regressorIndex);

            % 主抽头那一路恒为 1：直通相加，不走乘法器。
            mainPath = regressors(:, obj.MainTapIndex);

            sideIdx = [1:obj.MainTapIndex - 1, obj.MainTapIndex + 1:obj.TapCount];
            if isempty(sideIdx)
                acc = mainPath;
            else
                % 乘积小数位 = 输入(0) + 系数(10) = 10，求和后统一回缩到输出格式。
                products = regressors(:, sideIdx) .* obj.Coefficients(sideIdx);
                acc = mainPath + sum(products, 2);
            end

            [outputBlock, nOv] = cdr_fx.fxq.apply(acc.', obj.FmtOut, 'floor');
            obj.OverflowOut = obj.OverflowOut + nOv;
        end

        function [outputBlock, regressors] = processBlock(obj, inputWindow)
            %PROCESSBLOCK 带校验的入口。数值与 processBlockFast 完全一致。
            if ~isnumeric(inputWindow) || ~isvector(inputWindow) || ...
                    ~all(isfinite(inputWindow))
                error('cdr_fx:cdr_ffe:InvalidInputWindow', ...
                    'inputWindow 必须是有限数值向量。');
            end
            if numel(inputWindow) <= obj.PostTapCount + obj.PreTapCount
                error('cdr_fx:cdr_ffe:InvalidInputWindow', ...
                    'inputWindow 长度不足以产生任何输出样本。');
            end
            [outputBlock, regressors] = obj.processBlockFast(inputWindow);
        end

        function applyCoefficientDelta(obj, delta)
            %APPLYCOEFFICIENTDELTA 写入系数增量。主抽头不可改写。
            d = double(delta(:)).';
            if numel(d) ~= obj.TapCount
                error('cdr_fx:cdr_ffe:InvalidDelta', ...
                    'delta 长度必须等于抽头数 %d。', obj.TapCount);
            end
            if d(obj.MainTapIndex) ~= 0
                error('cdr_fx:cdr_ffe:MainTapUpdate', ...
                    '主抽头被四层硬冻结，不允许非零增量。');
            end
            obj.setCoefficients(obj.Coefficients + d);
        end

        function setCoefficients(obj, c)
            %SETCOEFFICIENTS 由 cdr_ffe_loop 用宽累加器的截断值刷新窄系数。
            v = double(c(:)).';
            v(obj.MainTapIndex) = 1;
            obj.Coefficients = cdr_fx.fxq.apply(v, obj.FmtCoeff, 'round');
            obj.Coefficients(obj.MainTapIndex) = 1;
        end

        function resetState(obj)
            %RESETSTATE 清空溢出统计。
            obj.OverflowOut = 0;
        end

        function s = getState(obj)
            %GETSTATE 只读快照。
            s = struct( ...
                'TapCount', obj.TapCount, ...
                'PreTapCount', obj.PreTapCount, ...
                'PostTapCount', obj.PostTapCount, ...
                'MainTapIndex', obj.MainTapIndex, ...
                'Coefficients', obj.Coefficients, ...
                'OverflowOut', obj.OverflowOut);
        end
    end
end
