classdef cdr_ffe < handle
    % cdr_ffe  由顶层提供完整输入窗口的 CDR 前馈均衡器。
    %
    % inputWindow 的排列固定为:
    %   [PostTapCount 个过去样本,目标块,PreTapCount 个未来样本]
    %
    % 本类只计算目标块的 FFE 输出,不缓存过去样本、待处理块或未来样本。
    % 跨块缓存、窗口拼接以及数据流首尾的有效性标记由调用方负责。

    properties (SetAccess = private)
        Coefficients
        InitialCoefficients
        TapCount
        PreTapCount
        MainTapIndex
        PostTapCount
    end

    methods
        function obj = cdr_ffe(initialCoefficients, preTapCount)
            % cdr_ffe  构造一个无跨块缓存的浮点 CDR FFE。
            if nargin < 1
                initialCoefficients = [0 0 1 0 0 0];
            end
            if nargin < 2
                preTapCount = 2;
            end

            obj.validateConfiguration(initialCoefficients, preTapCount);
            obj.InitialCoefficients = reshape(double(initialCoefficients), 1, []);
            obj.TapCount = numel(obj.InitialCoefficients);
            obj.PreTapCount = double(preTapCount);
            obj.MainTapIndex = obj.PreTapCount + 1;
            obj.PostTapCount = obj.TapCount - obj.MainTapIndex;
            obj.resetState();
        end

        function [outputBlock, regressor] = processBlock(obj, inputWindow)
            % processBlock  校验并处理一个由顶层拼接完成的输入窗口。
            obj.validateInputWindow(inputWindow);
            inputWindow = double(inputWindow);
            [outputBlock, regressor] = obj.processBlockFast(inputWindow);
        end

        function [outputBlock, regressor] = processBlockFast(obj, inputWindow)
            % processBlockFast  处理一个已由调用方校验的 double 行向量输入窗口。
            blockLength = numel(inputWindow) - obj.PostTapCount - obj.PreTapCount;
            firstTapSampleIndex = (obj.TapCount - 1) + (1:blockLength).';
            tapOffset = 0:obj.TapCount - 1;
            regressorIndex = firstTapSampleIndex - tapOffset;
            regressor = inputWindow(regressorIndex);
            outputBlock = (regressor * obj.Coefficients.').';
        end

        function applyCoefficientDelta(obj, deltaCoefficients)
            % applyCoefficientDelta  施加一次块速率 LMS 系数更新。
            isValid = isnumeric(deltaCoefficients);
            isValid = isValid && isreal(deltaCoefficients);
            isValid = isValid && isvector(deltaCoefficients);
            isValid = isValid && numel(deltaCoefficients) == obj.TapCount;
            isValid = isValid && all(isfinite(deltaCoefficients(:)));
            if ~isValid
                error('cdr_ffe:InvalidCoefficientDelta', 'deltaCoefficients must be a finite real vector with TapCount elements.');
            end

            deltaCoefficients = reshape(double(deltaCoefficients), 1, []);
            obj.Coefficients = obj.Coefficients + deltaCoefficients;
        end

        function resetState(obj)
            % resetState  恢复初始系数。
            obj.Coefficients = obj.InitialCoefficients;
        end

        function state = getState(obj)
            % getState  返回当前 FFE 配置。
            state = struct();
            state.Coefficients = obj.Coefficients;
            state.InitialCoefficients = obj.InitialCoefficients;
            state.TapCount = obj.TapCount;
            state.PreTapCount = obj.PreTapCount;
            state.MainTapIndex = obj.MainTapIndex;
            state.PostTapCount = obj.PostTapCount;
        end
        
        function scaleCoefficients(obj, factor)
            % scaleCoefficients  按比例缩放所有FFE系数，用于增益归一化
            % factor: 缩放因子，所有系数乘以该值
            isValid = isnumeric(factor) && isscalar(factor) && isreal(factor) && isfinite(factor);
            if ~isValid
                error('cdr_ffe:InvalidScaleFactor', 'Scale factor must be a finite real scalar.');
            end
            obj.Coefficients = obj.Coefficients * factor;
        end
    end

    methods (Access = private)
        function validateConfiguration(~, initialCoefficients, preTapCount)
            coefficientsValid = isnumeric(initialCoefficients);
            coefficientsValid = coefficientsValid && isreal(initialCoefficients);
            coefficientsValid = coefficientsValid && isvector(initialCoefficients);
            coefficientsValid = coefficientsValid && ~isempty(initialCoefficients);
            coefficientsValid = coefficientsValid && all(isfinite(initialCoefficients(:)));
            if ~coefficientsValid
                error('cdr_ffe:InvalidCoefficients', 'initialCoefficients must be a nonempty finite real vector.');
            end
            tapCount = numel(initialCoefficients);
            preTapCountValid = isnumeric(preTapCount);
            preTapCountValid = preTapCountValid && isreal(preTapCount);
            preTapCountValid = preTapCountValid && isscalar(preTapCount);
            preTapCountValid = preTapCountValid && isfinite(preTapCount);
            preTapCountValid = preTapCountValid && preTapCount >= 0;
            preTapCountValid = preTapCountValid && preTapCount < tapCount;
            preTapCountValid = preTapCountValid && preTapCount == round(preTapCount);
            if ~preTapCountValid
                error('cdr_ffe:InvalidPreTapCount', 'preTapCount must be an integer from 0 to TapCount - 1.');
            end
            mainTapIndex = preTapCount + 1;
            if initialCoefficients(mainTapIndex) ~= 1
                error('cdr_ffe:InvalidMainTap', 'The fixed main tap coefficient must equal 1.');
            end
        end

        function validateInputWindow(obj, inputWindow)
            isValid = isnumeric(inputWindow);
            isValid = isValid && isreal(inputWindow);
            isValid = isValid && isrow(inputWindow);
            isValid = isValid && ~isempty(inputWindow);
            isValid = isValid && all(isfinite(inputWindow));
            if ~isValid
                error('cdr_ffe:InvalidInputWindow', 'inputWindow must be a nonempty finite real numeric row vector.');
            end
            if numel(inputWindow) < obj.TapCount
                error('cdr_ffe:InputWindowTooShort', 'inputWindow must contain PostTapCount past samples, at least one target sample, and PreTapCount future samples.');
            end
        end
    end
end
