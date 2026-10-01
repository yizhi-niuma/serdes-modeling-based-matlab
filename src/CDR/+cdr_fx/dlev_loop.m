classdef dlev_loop < handle
%DLEV_LOOP PAM4 判决电平自适应（定点版）。
%
%   对应浮点参考 src/CDR/dlev_loop.m。本类是整个定点化里最容易写错的一个，
%   原因是 docs/CDR_FIXED_POINT.md §5.1 那条陷阱：
%
%   **宽累加器与送 slicer 的窄值必须严格区分，而归属判断只能用窄值。**
%
%   浮点版用精确相等判内外环归属：
%       isInner = abs(d) == obj.DLevInner;
%   定点下 DLevInner 存在 (1,23,16) 的宽累加器里，而 slicer 判决用的是截断到
%   (1,9,2) 的窄值。如果比较时一边用累加器、一边用截断值，这个 == 永远不成立
%   —— 内外环归属全错，innerErr/outerErr 恒零，dLev 环静默死掉，而且波形上
%   完全看不出来。
%
%   本类的解法：对外暴露 DLevInnerSlice / DLevOuterSlice / ThresholdSlice 三个
%   窄值供 slicer 使用，内部比较也一律用这三个窄值；宽累加器只在更新时参与。
%
%   另一处与浮点一致的设计：梯度除以 BlockSize 而不是本环实际命中样本数。
%   PAM4 下内外环各占约一半，所以两环有效增益约为名义步长的一半，且随码型
%   波动。这是对应 RTL 定长累加器的刻意选择，不是缺陷。BlockSize 是 2 的幂，
%   所以这个除法就是算术右移。

    properties (SetAccess = private)
        BlockSize       double
        Polarity        double
        StepSize        double

        DLevInner       double   % 宽累加器 (1,23,16)
        DLevOuter       double
        Threshold       double

        DLevInnerSlice  double   % 送 slicer 的窄值 (1,9,2)
        DLevOuterSlice  double
        ThresholdSlice  double

        FmtAccum        struct
        FmtSlice        struct
        FmtStep         struct
        ShiftBits       double   % log2(BlockSize)
        OverflowAccum   double
    end

    methods
        function obj = dlev_loop(stepSize, blockSize, levelsInner, levelsOuter, polarity)
            %DLEV_LOOP 构造定点 dLev 环。
            if nargin < 2 || isempty(blockSize); blockSize = 64; end
            if nargin < 3 || isempty(levelsInner); levelsInner = 1; end
            if nargin < 4 || isempty(levelsOuter); levelsOuter = 3; end
            if nargin < 5 || isempty(polarity); polarity = 1; end

            if log2(blockSize) ~= floor(log2(blockSize))
                error('cdr_fx:dlev_loop:InvalidBlockSize', ...
                    'blockSize 必须是 2 的幂，否则块平均无法用移位实现。');
            end
            if ~ismember(polarity, [-1 1])
                error('cdr_fx:dlev_loop:InvalidPolarity', 'polarity 必须是 ±1。');
            end

            obj.FmtAccum = cdr_fx.fxfmt.dlevAccum();
            obj.FmtSlice = cdr_fx.fxfmt.dlevSlice();
            obj.FmtStep = cdr_fx.fxfmt.dlevStep();

            obj.BlockSize = double(blockSize);
            obj.ShiftBits = log2(obj.BlockSize);
            obj.Polarity = double(polarity);
            obj.setStepSize(stepSize);

            obj.DLevInner = cdr_fx.fxq.apply(levelsInner, obj.FmtAccum, 'round');
            obj.DLevOuter = cdr_fx.fxq.apply(levelsOuter, obj.FmtAccum, 'round');
            obj.OverflowAccum = 0;
            obj.refreshDerived();
        end

        function dlevSsLmsFast(obj, d, e)
            %DLEVSSLMSFAST 符号-符号 LMS 块更新。
            %
            %   折叠误差 sign(d).*e 恒等于 |x| - |d|。归属判断用**窄值**比较，
            %   见类头说明。sign(0)=0 的三值语义必须保留：环外样本被置零后，
            %   sign(0)=0 正是"环外不贡献"的实现机制。
            d = double(d(:));
            e = double(e(:));
            if isempty(d)
                return;
            end

            absD = abs(d);
            isInner = (absD == obj.DLevInnerSlice);
            isOuter = (absD == obj.DLevOuterSlice);

            foldedErr = cdr_fx.fxq.sign3(d) .* e;
            innerTerm = cdr_fx.fxq.sign3(foldedErr .* isInner);
            outerTerm = cdr_fx.fxq.sign3(foldedErr .* isOuter);

            obj.applyUpdate(sum(innerTerm), sum(outerTerm));
        end

        function dlevLmsFast(obj, d, e)
            %DLEVLMSFAST 全精度折叠误差块更新（非默认路径，保留以便对照）。
            d = double(d(:));
            e = double(e(:));
            if isempty(d)
                return;
            end
            absD = abs(d);
            foldedErr = cdr_fx.fxq.sign3(d) .* e;
            obj.applyUpdate( ...
                sum(foldedErr .* (absD == obj.DLevInnerSlice)), ...
                sum(foldedErr .* (absD == obj.DLevOuterSlice)));
        end

        function setStepSize(obj, stepSize)
            %SETSTEPSIZE 修改步长，不复位任何状态。
            if ~isnumeric(stepSize) || ~isscalar(stepSize) || ...
                    ~isfinite(stepSize) || stepSize < 0
                error('cdr_fx:dlev_loop:InvalidStepSize', ...
                    'stepSize 必须是非负有限标量。');
            end
            obj.StepSize = cdr_fx.fxq.apply(stepSize, obj.FmtStep, 'round');
        end

        function resetState(obj)
            %RESETSTATE 清空溢出统计。电平本身由构造值决定，不在此重置。
            obj.OverflowAccum = 0;
        end

        function s = getState(obj)
            %GETSTATE 只读快照，宽窄两套值都给出。
            s = struct( ...
                'BlockSize', obj.BlockSize, 'Polarity', obj.Polarity, ...
                'StepSize', obj.StepSize, ...
                'DLevInner', obj.DLevInner, 'DLevOuter', obj.DLevOuter, ...
                'Threshold', obj.Threshold, ...
                'DLevInnerSlice', obj.DLevInnerSlice, ...
                'DLevOuterSlice', obj.DLevOuterSlice, ...
                'ThresholdSlice', obj.ThresholdSlice, ...
                'OverflowAccum', obj.OverflowAccum);
        end
    end

    methods (Access = private)
        function applyUpdate(obj, sumInner, sumOuter)
            %APPLYUPDATE 块平均后写入宽累加器，再刷新窄值。
            fx = cdr_fx.fxq;
            % 除以 BlockSize：2 的幂，等价于算术右移。
            gradInner = fx.quant(sumInner / obj.BlockSize, obj.FmtAccum.FracBits, 'floor');
            gradOuter = fx.quant(sumOuter / obj.BlockSize, obj.FmtAccum.FracBits, 'floor');

            stepInner = fx.quant(obj.StepSize * obj.Polarity * gradInner, ...
                obj.FmtAccum.FracBits, 'floor');
            stepOuter = fx.quant(obj.StepSize * obj.Polarity * gradOuter, ...
                obj.FmtAccum.FracBits, 'floor');

            [obj.DLevInner, n1] = fx.apply(obj.DLevInner + stepInner, obj.FmtAccum, 'floor');
            [obj.DLevOuter, n2] = fx.apply(obj.DLevOuter + stepOuter, obj.FmtAccum, 'floor');
            obj.OverflowAccum = obj.OverflowAccum + n1 + n2;

            obj.refreshDerived();
        end

        function refreshDerived(obj)
            %REFRESHDERIVED 重算门限与三个窄值。
            %   门限是内外电平的算术中点，除以 2 即右移 1 位，精确无损。
            fx = cdr_fx.fxq;
            obj.Threshold = fx.quant((obj.DLevInner + obj.DLevOuter) / 2, ...
                obj.FmtAccum.FracBits, 'floor');
            obj.DLevInnerSlice = fx.apply(obj.DLevInner, obj.FmtSlice, 'round');
            obj.DLevOuterSlice = fx.apply(obj.DLevOuter, obj.FmtSlice, 'round');
            obj.ThresholdSlice = fx.apply(obj.Threshold, obj.FmtSlice, 'round');
        end
    end
end
