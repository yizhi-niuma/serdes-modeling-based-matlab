classdef cdr_pd < handle
    % cdr_pd  CDR 环路中的 Phase Detector（PD）行为模型。

    properties (SetAccess = private)
        % PdType  当前 PD 主类型。
        PdType = 'bbpd'

        % Threshold  slicer 判决阈值。
        Threshold = 0

        % Polarity  PD 输出极性。
        Polarity = 1

        % LastOutput  最近一次 detect 的完整输出快照。
        LastOutput
    end

    methods
        function obj = cdr_pd(threshold, polarity)
            % cdr_pd  构造 Alexander BBPD 行为模型。

            if nargin < 1
                threshold = 0;
            end
            if nargin < 2
                polarity = 1;
            end

            obj.setThreshold(threshold);
            obj.setPolarity(polarity);
            obj.resetState();
        end

        function [pdError, valid, output] = detect(obj, dataSamplePrev, edgeSampleCurr, dataSampleCurr)
            % detect  根据 D[n-1] / E[n] / D[n] 生成 Alexander BBPD 判决。

            obj.validateSameSize(dataSamplePrev, edgeSampleCurr, dataSampleCurr);

            % 将三路模拟采样值判决为 0 / 1。
            dPrev = obj.sliceSample(dataSamplePrev);
            eCurr = obj.sliceSample(edgeSampleCurr);
            dCurr = obj.sliceSample(dataSampleCurr);

            % 只有前后 data decision 不同时，当前 UI 才包含数据跳变。
            transition = dPrev ~= dCurr;

            % rawDecision 是未乘 Polarity 前的 BBPD 原始判决。

            % edge decision 等于旧 data decision 时，按当前约定记为 +1。
            early = eCurr == dPrev;

            % rawDecision 是未乘 Polarity 前的 BBPD 原始判决。
            rawDecision = zeros(size(dCurr));
            rawDecision(transition) = -1;
            rawDecision(transition & early) = 1;


            % valid 只表示当前 UI 是否存在数据跳变。
            valid = transition;

            % 通过 Polarity 完成环路方向映射。
            pdError = obj.Polarity * rawDecision;

            % 无效位置强制清零，避免后级 voter / loop filter 误用。
            pdError(~valid) = 0;

            % 保存 debug 信息，便于上层 CDR 环路调试和波形追踪。
            output = struct();
            output.PdType = obj.PdType;
            output.Threshold = obj.Threshold;
            output.Polarity = obj.Polarity;
            output.DataDecisionPrev = dPrev;
            output.EdgeDecisionCurr = eCurr;
            output.DataDecisionCurr = dCurr;
            output.Transition = transition;
            output.RawDecision = rawDecision;
            output.Valid = valid;
            output.PdError = pdError;

            obj.LastOutput = output;
        end

        function setThreshold(obj, threshold)
            % setThreshold  设置 slicer 判决阈值。

            obj.validateFiniteScalar(threshold, 'threshold');
            obj.Threshold = threshold;
        end

        function setPolarity(obj, polarity)
            % setPolarity  设置 PD 输出极性。

            obj.validatePolarity(polarity);
            obj.Polarity = polarity;
        end

        function resetState(obj)
            % resetState  清空最近一次输出快照。

            obj.LastOutput = struct();
        end

        function state = getState(obj)
            % getState  返回 PD 当前配置和最近一次输出快照。

            state = struct();
            state.PdType = obj.PdType;
            state.Threshold = obj.Threshold;
            state.Polarity = obj.Polarity;
            state.LastOutput = obj.LastOutput;
        end
    end

    methods (Access = private)
        function decision = sliceSample(obj, sampleValue)
            % sliceSample  将模拟 sample value 判决为 0 / 1。

            decision = sampleValue > obj.Threshold;
        end

        function validateSameSize(obj, dataSamplePrev, edgeSampleCurr, dataSampleCurr)
            % validateSameSize  检查三路输入是否为同尺寸有限数值数组。

            obj.validateFiniteNumericArray(dataSamplePrev, 'dataSamplePrev');
            obj.validateFiniteNumericArray(edgeSampleCurr, 'edgeSampleCurr');
            obj.validateFiniteNumericArray(dataSampleCurr, 'dataSampleCurr');

            if ~isequal(size(dataSamplePrev), size(edgeSampleCurr)) || ~isequal(size(dataSamplePrev), size(dataSampleCurr))
                error('dataSamplePrev, edgeSampleCurr, and dataSampleCurr must have the same size.');
            end
        end

        function validateFiniteNumericArray(~, value, name)
            % validateFiniteNumericArray  检查输入是否为有限数值数组。

            if ~isnumeric(value) || isempty(value) || any(~isfinite(value(:)))
                error('%s must be a finite numeric array.', name);
            end
        end

        function validateFiniteScalar(~, value, name)
            % validateFiniteScalar  检查输入是否为有限数值标量。

            if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value)
                error('%s must be a finite numeric scalar.', name);
            end
        end

        function validatePolarity(~, polarity)
            % validatePolarity  检查 polarity 是否为 +1 或 -1。

            if ~isnumeric(polarity) || ~isscalar(polarity) || ~(polarity == 1 || polarity == -1)
                error('polarity must be +1 or -1.');
            end
        end
    end
end
