classdef cdr_pi < handle
%CDR_PI 相位插值器（定点版）。
%
%   对应浮点参考 src/CDR/cdr_pi.m。两个要点：
%
%   1. **码累加本来就是整数运算**，定点化在这里几乎是恒等变换：CodeWrapped 是
%      0..NumCode-1 的无符号整数，UiSlip 是带符号整数。而且浮点版用的就是
%      floor（cdr_pi.m:115 的 floor(rawCode/NumCode)），所以这里可以放心直接
%      按 2 的幂移位 —— 这与 cdr_loop 必须用 fix 形成对照，两种取整语义在同一
%      个仓库里并存，必须逐处核对，不能一把梭。
%
%   2. **相位表与 INL 保持 double，不定点化**。它们表示的是模拟非理想性（PI
%      的物理失配），是物理量而不是运算量。把它定点化等于把"模拟电路有多准"
%      和"数字电路算多细"两件事混为一谈。查表输出的样本偏移在调用方取整到
%      整数样本，那一步才是真正的量化。

    properties (SetAccess = private)
        NumBit              double
        NumCode             double
        SamplesPerSymbol    double

        CodeWrapped         double
        UiSlip              double

        PhaseTableUI        double   % 保持 double：模拟非理想性
        FmtCode             struct
        FmtSlip             struct
        OverflowSlip        double
    end

    methods
        function obj = cdr_pi(numBit, samplesPerSymbol)
            %CDR_PI 构造定点相位插值器。
            if nargin < 1 || isempty(numBit); numBit = 7; end
            if nargin < 2 || isempty(samplesPerSymbol); samplesPerSymbol = 128; end
            if ~isnumeric(numBit) || ~isscalar(numBit) || numBit <= 0 || ...
                    numBit ~= floor(numBit)
                error('cdr_fx:cdr_pi:InvalidNumBit', 'numBit 必须是正整数。');
            end
            obj.NumBit = double(numBit);
            obj.NumCode = 2 ^ obj.NumBit;
            obj.SamplesPerSymbol = double(samplesPerSymbol);
            obj.FmtCode = cdr_fx.fxfmt.piCodeWrapped();
            obj.FmtSlip = cdr_fx.fxfmt.piUiSlip();
            obj.resetNonideal();
            obj.resetState();
        end

        function localIndexFloat = updateFast(obj, deltaCode)
            %UPDATEFAST 累加码增量并处理 UI 回绕。
            %   deltaCode 是整数。floor 与算术右移等价，这里直接用 floor。
            rawCode = obj.CodeWrapped + double(deltaCode);
            uiDelta = floor(rawCode / obj.NumCode);
            obj.CodeWrapped = rawCode - uiDelta * obj.NumCode;

            [obj.UiSlip, nOv] = cdr_fx.fxq.sat(obj.UiSlip + uiDelta, obj.FmtSlip);
            obj.OverflowSlip = obj.OverflowSlip + nOv;

            localIndexFloat = obj.getLocalIndex();
        end

        function localIndexFloat = update(obj, deltaCode)
            %UPDATE 带校验的入口。数值与 updateFast 完全一致。
            if ~isnumeric(deltaCode) || ~isscalar(deltaCode) || ...
                    ~isfinite(deltaCode) || deltaCode ~= floor(deltaCode)
                error('cdr_fx:cdr_pi:InvalidDeltaCode', ...
                    'deltaCode 必须是有限整数标量。');
            end
            localIndexFloat = obj.updateFast(double(deltaCode));
        end

        function idx = getLocalIndex(obj)
            %GETLOCALINDEX 当前码对应的 UI 内样本偏移（单位：波形样本）。
            %   取自相位表而非原始码，这正是让 PI 非理想性可观测的关键。
            idx = obj.PhaseTableUI(obj.CodeWrapped + 1) * obj.SamplesPerSymbol;
        end

        function setCode(obj, codeWrapped, uiSlip)
            %SETCODE 直接设置 PI 状态，用于起始相位扫描。
            obj.CodeWrapped = mod(double(codeWrapped), obj.NumCode);
            if nargin >= 3 && ~isempty(uiSlip)
                obj.UiSlip = double(uiSlip);
            end
        end

        function setPhaseTableUI(obj, phaseTableUI)
            %SETPHASETABLEUI 装载完整相位表（单位 UI），保持 double。
            v = double(phaseTableUI(:)).';
            if numel(v) ~= obj.NumCode
                error('cdr_fx:cdr_pi:InvalidPhaseTable', ...
                    '相位表长度必须等于 NumCode = %d。', obj.NumCode);
            end
            obj.PhaseTableUI = v;
        end

        function resetNonideal(obj)
            %RESETNONIDEAL 回到理想线性相位表。
            obj.PhaseTableUI = (0:obj.NumCode - 1) / obj.NumCode;
        end

        function resetState(obj)
            %RESETSTATE 清零码与滑移。
            obj.CodeWrapped = 0;
            obj.UiSlip = 0;
            obj.OverflowSlip = 0;
        end

        function s = getState(obj)
            %GETSTATE 只读快照。
            s = struct( ...
                'NumBit', obj.NumBit, 'NumCode', obj.NumCode, ...
                'SamplesPerSymbol', obj.SamplesPerSymbol, ...
                'CodeWrapped', obj.CodeWrapped, 'UiSlip', obj.UiSlip, ...
                'CodeAccum', obj.UiSlip * obj.NumCode + obj.CodeWrapped, ...
                'OverflowSlip', obj.OverflowSlip);
        end
    end
end
