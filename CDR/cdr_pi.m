classdef cdr_pi < handle
    % cdr_pi  CDR 环路中的 Phase Interpolator（PI）行为模型。
    %
    % 本类用于 SerDes 端到端建模、CDR 架构/算法探索以及后续 BER 仿真。
    % 建模重点放在“PI code -> 相位 -> 采样点索引”的关系上，并以 PhaseTable
    % 作为运行时主要非理想建模入口。INL 可按需由 PhaseTable 和理想相位表计算得到。
    %
    % 设计约定：
    %   1. PI 的输入 deltaCode 来自 loop filter，期望为整数 code 增量。
    %   2. CodeWrapped 表示硬件风格的 PI wrapped code，范围为 [0, NumCode - 1]。
    %   3. UiSlip 记录跨越完整 UI 的累计次数，用于保留长期相位/频偏信息。
    %   4. ADC / sampler 主路径通常只需要 LocalIndexFloat，即当前 UI 内的本地采样偏移。
    %   5. PhaseTableUI 是运行时查表所用的 canonical phase table；每次更新只做简单整数
    %      wrap 和一次 LUT 查表，避免在 BER 热路径中重复计算非线性模型。
    %
    % update 与 updateFast 的区别：
    %   - update：保留输入检查，并刷新完整 debug/output state，适合调试、trace 和普通仿真。
    %   - updateFast：面向 BER 主循环，不做输入检查，不刷新完整 state，只返回本次 local index。
    %     因此调用 updateFast 后，CodeWrapped / UiSlip 会更新，但 getState 中的相位/索引派生量
    %     可能仍为上一次 refreshOutputState 的结果，这是为了性能刻意保留的行为。

    properties (SetAccess = private)
        % NumBit  PI 控制码位宽；例如 8-bit PI 对应 256 个 code。
        NumBit

        % NumCode  PI code 总数，等于 2^NumBit；构造后保持不变。
        NumCode

        % SamplesPerSymbol  每个 UI / symbol 对应的 waveform 采样点数。
        SamplesPerSymbol

        % EnableNonideal  是否启用非理想相位表；false 时使用理想线性相位表。
        EnableNonideal = true

        % NonidealMode  当前非理想模式标识：ideal / ab_constant / custom_inl / custom_phase_table。
        NonidealMode = 'ab_constant'

        % PhaseTableUI  实际运行时相位表，单位为 UI，范围 wrap 到 [0, 1)。
        % update / updateFast 均通过 CodeWrapped + 1 查询该表。
        PhaseTableUI

        % IndexTableFloat  PhaseTableUI 对应的采样点偏移 LUT。
        % 该表是 PhaseTableUI 的派生缓存，用于避免 updateFast 热路径重复乘 SamplesPerSymbol。
        IndexTableFloat

        % CodeWrapped  当前 UI 内的 wrapped PI code，范围为 [0, NumCode - 1]。
        CodeWrapped = 0

        % UiSlip  累计 UI slip 数；当 code 正向或反向跨越 UI 边界时递增或递减。
        UiSlip = 0

        % PhaseWrappedUI  当前 UI 内相位，单位 UI；由 PhaseTableUI(CodeWrapped + 1) 得到。
        PhaseWrappedUI = 0

        % PhaseAccumUI  累计相位，单位 UI；等于 UiSlip + PhaseWrappedUI。
        PhaseAccumUI = 0

        % IndexWrappedFloat  当前 UI 内采样点偏移，单位为 sample index，可为小数。
        IndexWrappedFloat = 0

        % IndexAccumFloat  累计采样点偏移，单位为 sample index，可用于观察长期 phase tracking。
        IndexAccumFloat = 0

        % LocalIndexFloat  提供给 ADC / sampler 的本地采样点偏移；当前等同于 IndexWrappedFloat。
        LocalIndexFloat = 0
    end

    methods
        function obj = cdr_pi(NumBit, SamplesPerSymbol)
            % cdr_pi  构造 PI 模型并初始化理想/非理想相位表。
            %
            % 输入：
            %   NumBit           PI code 位宽，默认 8。
            %   SamplesPerSymbol 每个 UI 的采样点数，默认 128。
            %
            % 默认启用 a+b=constant 非理想模型。该模型只在配置/构造阶段计算相位表，
            % 后续 update 只查表，降低主仿真循环开销。

            if nargin < 1
                NumBit = 8;
            end
            if nargin < 2
                SamplesPerSymbol = 128;
            end

            obj.validatePositiveIntegerScalar(NumBit, 'NumBit');
            obj.validatePositiveFiniteScalar(SamplesPerSymbol, 'SamplesPerSymbol');

            obj.NumBit = NumBit;
            obj.NumCode = 2 ^ NumBit;
            obj.SamplesPerSymbol = SamplesPerSymbol;

            % 默认用 a+b=constant 模型生成实际相位表。
            % 理想相位表和 INL 不作为长期属性保存，需要时按需计算。
            obj.PhaseTableUI = obj.buildAbConstantPhaseTableUI();
            obj.refreshIndexTable();

            % 初始化派生输出状态，保证构造后 getState / getIndex 等接口立即可用。
            obj.refreshOutputState();
        end

        function update(obj, deltaCode)
            % update  带完整检查和 state 刷新的 PI 更新接口。
            %
            % deltaCode 为 loop filter 输出的整数 code 增量。该函数适合调试、单步仿真、
            % 需要 getState / getPhaseUI / getIndex 立即反映最新派生状态的场景。

            obj.validateIntegerScalar(deltaCode, 'deltaCode');

            % NumCode 构造后为定值，缓存到局部变量可减少热路径属性访问开销。
            NumCode_local = obj.NumCode;

            % rawCode 允许超出 [0, NumCode-1]，通过 floor/mod 拆成 UI slip 和 wrapped code。
            rawCode = obj.CodeWrapped + deltaCode;
            uiDelta = floor(rawCode / NumCode_local);
            obj.CodeWrapped = mod(rawCode, NumCode_local);
            obj.UiSlip = obj.UiSlip + uiDelta;

            % 刷新完整派生状态，便于 debug/trace，但会带来额外运行时开销。
            obj.refreshOutputState();
        end

        function localIndexFloat = updateFast(obj, deltaCode)
            % updateFast  面向 BER 仿真热路径的快速 PI 更新接口。
            %
            % 使用前提：
            %   deltaCode 已由上游 loop filter 保证为有限整数标量。
            %
            % 性能取舍：
            %   1. 不调用 validateIntegerScalar，避免每拍输入检查开销。
            %   2. 不调用 refreshOutputState，避免刷新完整 debug state。
            %   3. 只更新 CodeWrapped / UiSlip，并直接返回 ADC 需要的 localIndexFloat。
            %
            % 注意：调用该函数后，getState 中的 PhaseWrappedUI / PhaseAccumUI / Index* / LocalIndexFloat
            % 可能不是最新值；如需完整状态，请使用 update 或手动通过调试路径刷新。

            NumCode_local = obj.NumCode;

            rawCode = obj.CodeWrapped + deltaCode;
            uiDelta = floor(rawCode / NumCode_local);
            obj.CodeWrapped = mod(rawCode, NumCode_local);
            obj.UiSlip = obj.UiSlip + uiDelta;

            % 主路径只需要当前 UI 内采样偏移，因此直接查预先换算好的 IndexTableFloat。
            localIndexFloat = obj.IndexTableFloat(obj.CodeWrapped + 1);
        end

        function setCode(obj, code)
            % setCode  直接设置累计 code，并同步拆分为 UiSlip + CodeWrapped。
            %
            % code 可以超出一个 UI 的范围；函数会自动计算对应的完整 UI slip 和 wrapped code。

            obj.validateIntegerScalar(code, 'code');

            obj.UiSlip = floor(code / obj.NumCode);
            obj.CodeWrapped = mod(code, obj.NumCode);

            obj.refreshOutputState();
        end

        function resetState(obj)
            % resetState  清零 PI 动态状态，不改变非理想配置和相位表。

            obj.CodeWrapped = 0;
            obj.UiSlip = 0;

            obj.refreshOutputState();
        end

        function resetNonideal(obj)
            % resetNonideal  关闭 PI 非理想效应，恢复理想线性相位表。

            obj.EnableNonideal = false;
            obj.NonidealMode = 'ideal';
            obj.PhaseTableUI = obj.buildIdealPhaseTableUI();
            obj.refreshIndexTable();

            obj.refreshOutputState();
        end

        function setDefaultNonideal(obj)
            % setDefaultNonideal  恢复默认 a+b=constant 非理想相位表。
            %
            % 该默认模型用于近似 PI 权重线性插值时产生的相位非线性。

            obj.EnableNonideal = true;
            obj.NonidealMode = 'ab_constant';
            obj.PhaseTableUI = obj.buildAbConstantPhaseTableUI();
            obj.refreshIndexTable();

            obj.refreshOutputState();
        end 

        function setInlTableUI(obj, inlTableUI)
            % setInlTableUI  使用用户自定义 INL 表配置 PI 非理想。
            %
            % inlTableUI 的长度必须等于 NumCode，单位为 UI。实际相位表通过
            % 按需生成的理想相位表 + inlTableUI 得到，并 wrap 到 [0, 1)。

            obj.validateTableUI(inlTableUI, 'inlTableUI');

            obj.EnableNonideal = true;
            obj.NonidealMode = 'custom_inl';
            idealPhaseTableUI = obj.buildIdealPhaseTableUI();
            obj.PhaseTableUI = mod(idealPhaseTableUI + reshape(inlTableUI, 1, obj.NumCode), 1);
            obj.refreshIndexTable();

            obj.refreshOutputState();
        end

        function setPhaseTableUI(obj, phaseTableUI)
            % setPhaseTableUI  直接使用用户自定义 PhaseTable 配置 PI 非理想。
            %
            % phaseTableUI 是 code 到 phase 的完整 LUT，单位为 UI。该接口适合已有测量结果、
            % 电路级仿真结果或其它自定义 PI 模型时使用。

            obj.validateTableUI(phaseTableUI, 'phaseTableUI');

            obj.EnableNonideal = true;
            obj.NonidealMode = 'custom_phase_table';
            obj.PhaseTableUI = mod(reshape(phaseTableUI, 1, obj.NumCode), 1);
            obj.refreshIndexTable();

            obj.refreshOutputState();
        end

        function [phaseWrappedUI, phaseAccumUI] = getPhaseUI(obj)
            % getPhaseUI  返回当前 UI 内相位和累计相位，单位均为 UI。

            phaseWrappedUI = obj.PhaseWrappedUI;
            phaseAccumUI = obj.PhaseAccumUI;
        end

        function [indexWrappedFloat, indexAccumFloat] = getIndex(obj)
            % getIndex  返回当前 UI 内采样点偏移和累计采样点偏移。
            %
            % 输出为 float index，调用方可根据后续采样策略决定 round / floor / interpolation。

            indexWrappedFloat = obj.IndexWrappedFloat;
            indexAccumFloat = obj.IndexAccumFloat;
        end

        function localIndexFloat = getLocalIndex(obj)
            % getLocalIndex  返回提供给 ADC / sampler 的本地采样点偏移。

            localIndexFloat = obj.LocalIndexFloat;
        end

        function inlTableUI = getInlTableUI(obj)
            % getInlTableUI  按需计算并返回当前 PI 相位表对应的 INL。
            %
            % INL 不作为长期属性保存，避免与 PhaseTableUI 形成冗余状态。
            % 调用该函数时，使用当前 PhaseTableUI 减去按需生成的理想相位表得到。

            idealPhaseTableUI = obj.buildIdealPhaseTableUI();
            inlTableUI = obj.wrapPhaseErrorUI(obj.PhaseTableUI - idealPhaseTableUI);
        end

        function state = getState(obj)
            % getState  返回 PI 当前配置、动态状态和相位表的调试快照。
            %
            % state 主要用于 debug、trace、可视化和测试，不建议在 BER 主循环中每拍调用。
            % 若主循环只需要采样点偏移，优先使用 updateFast 的返回值。

            state = struct();
            state.NumBit = obj.NumBit;
            state.NumCode = obj.NumCode;
            state.SamplesPerSymbol = obj.SamplesPerSymbol;
            state.EnableNonideal = obj.EnableNonideal;
            state.NonidealMode = obj.NonidealMode;
            state.CodeWrapped = obj.CodeWrapped;
            state.UiSlip = obj.UiSlip;
            state.CodeAccum = obj.UiSlip * obj.NumCode + obj.CodeWrapped;
            state.PhaseWrappedUI = obj.PhaseWrappedUI;
            state.PhaseAccumUI = obj.PhaseAccumUI;
            state.IndexWrappedFloat = obj.IndexWrappedFloat;
            state.IndexAccumFloat = obj.IndexAccumFloat;
            state.LocalIndexFloat = obj.LocalIndexFloat;
            state.IdealPhaseTableUI = obj.buildIdealPhaseTableUI();
            state.InlTableUI = obj.getInlTableUI();
            state.PhaseTableUI = obj.PhaseTableUI;
            state.IndexTableFloat = obj.IndexTableFloat;
        end
    end

    methods (Access = private)
        function refreshIndexTable(obj)
            % refreshIndexTable  根据 PhaseTableUI 刷新采样点偏移 LUT。
            %
            % PhaseTableUI 是唯一真实相位表；IndexTableFloat 只是派生缓存，
            % 用于让 updateFast 在 BER 热路径中少做一次乘法。

            obj.IndexTableFloat = obj.PhaseTableUI * obj.SamplesPerSymbol;
        end

        function refreshOutputState(obj)
            % refreshOutputState  根据 CodeWrapped / UiSlip 刷新所有派生输出状态。
            %
            % 该函数集中维护 phase/index 的一致性，便于 update、setCode、resetState 和
            % 非理想配置接口复用。updateFast 为性能考虑故意不调用该函数。

            obj.PhaseWrappedUI = obj.PhaseTableUI(obj.CodeWrapped + 1);
            obj.PhaseAccumUI = obj.UiSlip + obj.PhaseWrappedUI;
            obj.IndexWrappedFloat = obj.IndexTableFloat(obj.CodeWrapped + 1);
            obj.IndexAccumFloat = obj.UiSlip * obj.SamplesPerSymbol + obj.IndexWrappedFloat;
            obj.LocalIndexFloat = obj.IndexWrappedFloat;
        end

        function idealPhaseTableUI = buildIdealPhaseTableUI(obj)
            % buildIdealPhaseTableUI  按需生成理想 PI 相位表。
            %
            % code 0 对应 0 UI，code NumCode-1 对应接近 1 UI。

            idealPhaseTableUI = (0:obj.NumCode - 1) / obj.NumCode;
        end

        function phaseTableUI = buildAbConstantPhaseTableUI(obj)
            % buildAbConstantPhaseTableUI  构造默认 a+b=constant PI 非理想相位表。
            %
            % 模型含义：
            %   在每个象限内，两个相邻相位分量权重满足 a + b = 1，且 a = 1-localAlpha，
            %   b = localAlpha。输出相位用 atan2(b, a) 映射到该象限内的归一化相位。
            %   这种模型可近似权重线性变化但矢量相位非线性变化所造成的 PI INL。
            %
            % 性能说明：
            %   atan2 只在构造或重新配置非理想时计算一次，运行时 update 只做 LUT 查表。

            alpha = (0:obj.NumCode - 1) / obj.NumCode;
            phaseTableUI = zeros(1, obj.NumCode);

            quadrantCode = obj.NumCode / 4;
            for k = 1:obj.NumCode
                % x 将 0~1 UI 展开到四个象限；quadrantIndex 表示当前象限编号。
                x = alpha(k) * 4;
                quadrantIndex = floor(x);
                localAlpha = x - quadrantIndex;

                % 理论上 alpha 最大为 (NumCode-1)/NumCode，通常不会到 4；这里保留保护逻辑。
                if quadrantIndex >= 4
                    quadrantIndex = 3;
                    localAlpha = 1;
                end

                % a+b=constant 权重插值，并用 atan2 得到象限内实际相位。
                a = 1 - localAlpha;
                b = localAlpha;
                localPhase = atan2(b, a) / (pi / 2);
                phaseTableUI(k) = (quadrantIndex + localPhase) / 4;
            end

            % 强制关键象限边界精确落在 0/0.25/0.5/0.75 UI，避免浮点误差影响基本点。
            phaseTableUI(1) = 0;
            if quadrantCode == round(quadrantCode)
                quarterIndex = quadrantCode + 1;
                halfIndex = 2 * quadrantCode + 1;
                threeQuarterIndex = 3 * quadrantCode + 1;

                if quarterIndex <= obj.NumCode
                    phaseTableUI(quarterIndex) = 0.25;
                end
                if halfIndex <= obj.NumCode
                    phaseTableUI(halfIndex) = 0.5;
                end
                if threeQuarterIndex <= obj.NumCode
                    phaseTableUI(threeQuarterIndex) = 0.75;
                end
            end

            phaseTableUI = mod(phaseTableUI, 1);
        end

        function phaseErrorUI = wrapPhaseErrorUI(~, phaseErrorUI)
            % wrapPhaseErrorUI  将相位误差 wrap 到 [-0.5, 0.5) UI。
            %
            % 这样可避免 0/1 UI 边界附近的误差显示成接近 +/-1 UI 的大跳变。

            phaseErrorUI = mod(phaseErrorUI + 0.5, 1) - 0.5;
        end

        function validateTableUI(obj, tableUI, name)
            % validateTableUI  检查用户输入相位/INL 表长度和数值有效性。

            if ~isnumeric(tableUI) || numel(tableUI) ~= obj.NumCode || any(~isfinite(tableUI(:)))
                error('%s must be a finite numeric table with NumCode elements.', name);
            end
        end

        function validateIntegerScalar(~, value, name)
            % validateIntegerScalar  检查输入是否为有限整数标量。

            if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value) || value ~= round(value)
                error('%s must be a finite integer scalar.', name);
            end
        end

        function validatePositiveIntegerScalar(~, value, name)
            % validatePositiveIntegerScalar  检查输入是否为正整数标量。

            if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value) || value <= 0 || value ~= round(value)
                error('%s must be a positive integer scalar.', name);
            end
        end

        function validatePositiveFiniteScalar(~, value, name)
            % validatePositiveFiniteScalar  检查输入是否为正的有限数值标量。

            if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value) || value <= 0
                error('%s must be a positive finite scalar.', name);
            end
        end
    end
end
