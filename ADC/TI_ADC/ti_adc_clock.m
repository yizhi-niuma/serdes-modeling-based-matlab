classdef ti_adc_clock < handle
    %TI_ADC_CLOCK TI ADC 采样时钟索引生成器。
    %
    %   cdrPhaseIndex 表示输入波形中的采样点索引。
    %   SamplesPerSymbol 表示相邻两个 ADC 采样槽之间的波形采样点数，
    %   用于把 ADC 采样槽域转换到输入波形的 sample index 域。
    %
    %   物理 lane 映射关系建模为：一个 TAH phase 后面连接 SarPerTah 个 SAR ADC。
    %   例如 M = 64 且 SarPerTah = 8 时，lane 1~8 属于 TAH1，
    %   lane 9~16 属于 TAH2，...，lane 57~64 属于 TAH8。
    %
    %   上升沿 skew 和 jitter 以 UI/采样槽为单位配置，随后通过
    %   SamplesPerSymbol 转换为输入波形 sample index 偏移。
    properties (SetAccess = private)
        M
        SarPerTah
        NumTah
        SamplesPerSymbol
        SkewMode = 'common'
        CommonRisingEdgeSkewUI = 0
        RisingEdgeSkewUI
        RisingEdgeJitterSigmaUI
        PhaseIndex
        TimeOrderIndex
    end

    methods
        function obj = ti_adc_clock(M, SarPerTah, SamplesPerSymbol)
            %TI_ADC_CLOCK 构造 TI ADC clock 行为模型。
            %   M 为物理 ADC lane 总数；SarPerTah 为每个 TAH phase 后连接的 SAR lane 数；
            %   SamplesPerSymbol 为输入波形每 UI 的采样点数，用于将 UI 域 skew / jitter 转换为 sample index。
            if nargin < 3
                SamplesPerSymbol = 128;
            end
            if nargin < 2
                SarPerTah = 8;
            end
            if nargin < 1
                M = 64;
            end
            obj.initializeParameters(M, SarPerTah, SamplesPerSymbol);
            obj.resetToIdeal();
        end

        function [actualIndex, actualRisingEdgeIndex] = generateSampleIndex(obj, cdrPhaseIndex)
            %GENERATESAMPLEINDEX 根据 CDR phase 生成每个物理 lane 的实际采样 index。
            %   cdrPhaseIndex 是 local waveform 坐标系下的 nominal CDR 采样相位。
            %   actualIndex 为长度 M 的整数采样位置；可选输出 actualRisingEdgeIndex 用于观察每个 TAH phase 的上升沿位置。
            if nargin < 2
                cdrPhaseIndex = 1;
            end
            obj.validateFiniteScalar(cdrPhaseIndex, 'cdrPhaseIndex');
            % PhaseIndex 和 TimeOrderIndex 是构造时缓存的 lane 映射，避免每个 block 重复计算。
            phaseIndex = obj.PhaseIndex;
            timeOrderIndex = obj.TimeOrderIndex;
            % 将 UI/采样槽域的 skew 和 jitter 转换为输入波形 sample index 偏移。
            % skew 是每个 TAH phase 的确定性偏移，jitter 则在每个 block、每个 TAH phase 重新生成。
            risingEdgeSkewIndex = obj.getRisingEdgeSkewUI() * obj.SamplesPerSymbol;
            if any(obj.RisingEdgeJitterSigmaUI ~= 0)
                risingEdgeJitterIndex = obj.RisingEdgeJitterSigmaUI .* randn(1, obj.NumTah) * obj.SamplesPerSymbol;
            else
                risingEdgeJitterIndex = zeros(1, obj.NumTah);
            end
            if nargout > 1
                % actualRisingEdgeIndex 主要用于观察每个 TAH 上升沿在加入 skew 和 jitter 后的位置。
                nominalRisingEdgeIndex = cdrPhaseIndex + (0:obj.NumTah - 1) * obj.SamplesPerSymbol;
                actualRisingEdgeIndex = nominalRisingEdgeIndex + risingEdgeSkewIndex + risingEdgeJitterIndex;
            end
            % nominalIndex 是每个物理 lane 的理想输入波形 sample index。
            % actualIndex 进一步叠加驱动该 lane 的 TAH phase 对应的 skew 和 jitter。
            nominalIndex = cdrPhaseIndex + (timeOrderIndex - 1) * obj.SamplesPerSymbol;
            actualIndex = nominalIndex + risingEdgeSkewIndex(phaseIndex) + risingEdgeJitterIndex(phaseIndex);
            actualIndex = round(actualIndex);
        end

        function [dataIndex, edgeIndex, dataRisingEdgeIndex, edgeRisingEdgeIndex] = generateDataAndEdgeSampleIndex(obj, cdrPhaseIndex)
            if nargin < 2
                cdrPhaseIndex = 1;
            end
            obj.validateFiniteScalar(cdrPhaseIndex, 'cdrPhaseIndex');

            phaseIndex = obj.PhaseIndex;
            timeOrderIndex = obj.TimeOrderIndex;

            risingEdgeSkewIndex = obj.getRisingEdgeSkewUI() * obj.SamplesPerSymbol;
            if any(obj.RisingEdgeJitterSigmaUI ~= 0)
                risingEdgeJitterIndex = obj.RisingEdgeJitterSigmaUI .* randn(1, obj.NumTah) * obj.SamplesPerSymbol;
            else
                risingEdgeJitterIndex = zeros(1, obj.NumTah);
            end

            nominalDataIndex = cdrPhaseIndex + (timeOrderIndex - 1) * obj.SamplesPerSymbol;
            nominalEdgeIndex = nominalDataIndex - 0.5 * obj.SamplesPerSymbol;

            clockErrorIndex = risingEdgeSkewIndex(phaseIndex) + risingEdgeJitterIndex(phaseIndex);
            dataIndex = round(nominalDataIndex + clockErrorIndex);
            edgeIndex = round(nominalEdgeIndex + clockErrorIndex);

            if nargout > 2
                nominalDataRisingEdgeIndex = cdrPhaseIndex + (0:obj.NumTah - 1) * obj.SamplesPerSymbol;
                nominalEdgeRisingEdgeIndex = nominalDataRisingEdgeIndex - 0.5 * obj.SamplesPerSymbol;
                risingEdgeErrorIndex = risingEdgeSkewIndex + risingEdgeJitterIndex;
                dataRisingEdgeIndex = nominalDataRisingEdgeIndex + risingEdgeErrorIndex;
                edgeRisingEdgeIndex = nominalEdgeRisingEdgeIndex + risingEdgeErrorIndex;
            end
        end

        function resetToIdeal(obj)
            %RESETTOIDEAL 恢复理想 clock 配置。
            %   清除 common/custom fixed skew 和 random jitter，使所有 TAH phase 回到无偏移状态。
            obj.SkewMode = 'common';
            obj.CommonRisingEdgeSkewUI = 0;
            obj.RisingEdgeSkewUI = zeros(1, obj.NumTah);
            obj.RisingEdgeJitterSigmaUI = zeros(1, obj.NumTah);
        end

        function resetState(~)
            %RESETSTATE 保留 clock 状态重置接口。
            %   当前 clock core 不保存跨 block 的动态状态，因此该函数为空实现。
        end

        function setSkewMode(obj, skewMode)
            %SETSKEWMODE 设置 fixed skew 的解释模式。
            %   'common' 表示所有 TAH phase 共用 CommonRisingEdgeSkewUI；'custom' 表示使用逐 phase 的 RisingEdgeSkewUI。
            obj.validateSkewMode(skewMode);
            obj.SkewMode = char(skewMode);
        end

        function setCommonRisingEdgeSkewUI(obj, skewUI)
            %SETCOMMONRISINGEDGESKEWUI 配置所有 TAH phase 共用的固定上升沿 skew。
            %   skewUI 单位为 UI；后续 generateSampleIndex 中会乘以 SamplesPerSymbol 转换为 sample index。
            obj.validateFiniteScalar(skewUI, 'skewUI');
            obj.CommonRisingEdgeSkewUI = skewUI;
            obj.SkewMode = 'common';
        end

        function setRisingEdgeSkewUI(obj, skewUI)
            %SETRISINGEDGESKEWUI 配置 TAH phase 级别的固定上升沿 skew。
            %   输入可以是标量或长度为 NumTah 的向量；标量表示所有 phase 共用同一个 skew。
            values = obj.expandPhaseVector(skewUI, 'RisingEdgeSkewUI');
            if isscalar(skewUI)
                obj.CommonRisingEdgeSkewUI = values(1);
                obj.SkewMode = 'common';
            else
                obj.RisingEdgeSkewUI = values;
                obj.SkewMode = 'custom';
            end
        end

        function setRisingEdgeJitterSigmaUI(obj, jitterSigmaUI)
            %SETRISINGEDGEJITTERSIGMAUI 配置 TAH phase 级别的随机 jitter sigma。
            %   输入单位为 UI，可以是标量或长度为 NumTah 的向量；每个 block 会重新生成随机 jitter。
            values = obj.expandPhaseVector(jitterSigmaUI, 'RisingEdgeJitterSigmaUI');
            if any(values < 0)
                error('RisingEdgeJitterSigmaUI must be nonnegative.');
            end
            obj.RisingEdgeJitterSigmaUI = values;
        end

    end

    methods (Access = private)
        function initializeParameters(obj, M, SarPerTah, SamplesPerSymbol)
            %INITIALIZEPARAMETERS 校验并保存 clock 基本结构参数。
            %   M 必须能被 SarPerTah 整除，从而得到整数个 TAH phase；随后缓存 lane 映射关系。
            obj.validatePositiveIntegerScalar(M, 'M');
            obj.validatePositiveIntegerScalar(SarPerTah, 'SarPerTah');
            obj.validatePositiveIntegerScalar(SamplesPerSymbol, 'SamplesPerSymbol');
            if mod(M, SarPerTah) ~= 0
                error('M must be an integer multiple of SarPerTah.');
            end
            obj.M = M;
            obj.SarPerTah = SarPerTah;
            obj.NumTah = M / SarPerTah;
            obj.SamplesPerSymbol = SamplesPerSymbol;
            obj.initializeLaneMapping();
        end

        function initializeLaneMapping(obj)
            %INITIALIZELANEMAPPING 缓存物理 lane 到 TAH phase 和采样槽的映射。
            %   该映射只由 M 和 SarPerTah 决定，运行过程中不随 block 改变。
            laneIndex = 1:obj.M;
            obj.PhaseIndex = floor((laneIndex - 1) / obj.SarPerTah) + 1;
            sarIndexInPhase = mod(laneIndex - 1, obj.SarPerTah) + 1;
            obj.TimeOrderIndex = (sarIndexInPhase - 1) * obj.NumTah + obj.PhaseIndex;
        end

        function skewUI = getRisingEdgeSkewUI(obj)
            %GETRISINGEDGESKEWUI 根据当前 skew 模式返回每个 TAH phase 的固定 skew。
            %   common 模式会将单个 CommonRisingEdgeSkewUI 展开为 NumTah 长度向量；custom 模式直接返回逐 phase 配置。
            switch obj.SkewMode
                case 'common'
                    skewUI = repmat(obj.CommonRisingEdgeSkewUI, 1, obj.NumTah);
                case 'custom'
                    skewUI = obj.RisingEdgeSkewUI;
                otherwise
                    error('Unsupported skew mode.');
            end
        end

        function values = expandPhaseVector(obj, value, name)
            %EXPANDPHASEVECTOR 将标量或 phase 向量规整为 1×NumTah 行向量。
            %   标量输入表示所有 TAH phase 共用同一个值；向量输入必须刚好包含 NumTah 个元素。
            if ~isnumeric(value) || isempty(value) || any(~isfinite(value(:)))
                error('%s must be a finite numeric scalar or vector.', name);
            end
            if isscalar(value)
                values = repmat(value, 1, obj.NumTah);
            else
                values = reshape(value, 1, []);
                if numel(values) ~= obj.NumTah
                    error('%s must be scalar or have NumTah elements.', name);
                end
            end
        end

        function validateSkewMode(~, skewMode)
            %VALIDATESKEWMODE 检查 skewMode 是否为支持的字符串模式。
            %   当前仅支持 'common' 和 'custom' 两种 fixed skew 配置方式。
            if ~(ischar(skewMode) || (isstring(skewMode) && isscalar(skewMode)))
                error('skewMode must be a character vector or scalar string.');
            end
            validModes = {'common', 'custom'};
            if ~any(strcmp(char(skewMode), validModes))
                error('Unsupported skew mode.');
            end
        end

        function validateFiniteScalar(~, value, name)
            %VALIDATEFINITESCALAR 检查输入是否为有限数值标量。
            %   name 用于生成更明确的报错信息，便于定位具体参数。
            if ~(isnumeric(value) && isscalar(value) && isfinite(value))
                error('%s must be a finite numeric scalar.', name);
            end
        end

        function validatePositiveIntegerScalar(obj, value, name)
            %VALIDATEPOSITIVEINTEGERSCALAR 检查输入是否为正整数标量。
            %   该 helper 复用 validateFiniteScalar，并额外检查取值大于 0 且等于自身 round 结果。
            obj.validateFiniteScalar(value, name);
            if value < 1 || value ~= round(value)
                error('%s must be a positive integer scalar.', name);
            end
        end

    end
end
