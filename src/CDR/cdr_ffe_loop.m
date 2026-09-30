classdef cdr_ffe_loop < handle
    % cdr_ffe_loop  CDR 专用 FFE 的块级 LMS 自适应引擎。
    %
    % 调用方负责提供数据样本的判决误差, 以及 cdr_ffe 返回的回归矩阵。
    % 边界样本不参与自适应。

    properties (SetAccess = private)
        StepSize
        TapCount = 6
        MainTapIndex = 3
        BlockSize = 64
        AdaptEnableMask = logical([1 1 0 1 1 1])
        LastGradient
        LastDelta
        UpdateCount = 0
    end

    methods
        function obj = cdr_ffe_loop(stepSize, tapCount, mainTapIndex, blockSize, adaptEnableMask)
            % cdr_ffe_loop  构造一个浮点块级 LMS 引擎。
            if nargin < 1
                error('cdr_ffe_loop:MissingStepSize', 'stepSize must be provided explicitly.');
            end
            if nargin < 2
                tapCount = 6;
            end
            if nargin < 3
                mainTapIndex = 3;
            end
            if nargin < 4
                blockSize = 64;
            end
            if nargin < 5
                adaptEnableMask = true(1, tapCount);
                adaptEnableMask(mainTapIndex) = false;
            end

            obj.validateConfiguration(stepSize, tapCount, mainTapIndex, blockSize, adaptEnableMask);
            obj.StepSize = double(stepSize);
            obj.TapCount = double(tapCount);
            obj.MainTapIndex = double(mainTapIndex);
            obj.BlockSize = double(blockSize);
            obj.AdaptEnableMask = logical(reshape(adaptEnableMask, 1, []));
            obj.resetState();
        end

        function deltaCoefficients = update(obj, dataRegressor, errorBlock)
            % update  校验输入并计算一次块级 LMS 更新。
            obj.validateUpdateInput(dataRegressor, errorBlock);
            dataRegressor = double(dataRegressor);
            errorVector = reshape(double(errorBlock), 1, []);
            [deltaCoefficients, gradient] = obj.updateFast(dataRegressor, errorVector);

            obj.LastGradient = gradient;
            obj.LastDelta = deltaCoefficients;
            obj.UpdateCount = obj.UpdateCount + 1;
        end

        function [deltaCoefficients, gradient] = updateFast(obj, dataRegressor, errorVector)
            % updateFast  对调用方已保证合法的 double 数组计算一次更新。
            % dataRegressor 为 BlockSize×TapCount, errorVector 为 1×BlockSize
            % 行向量。本路径不更新任何诊断量。
            gradient = errorVector * dataRegressor / obj.BlockSize;
            deltaCoefficients = obj.StepSize * gradient;
            deltaCoefficients(~obj.AdaptEnableMask) = 0;
        end

        function deltaCoefficients = updateSsLms(obj, dataRegressor, errorBlock)
            % updateSsLms  符号-符号 LMS: 校验输入并计算一次块级 SS-LMS 更新。
            %
            % 把标准 LMS 梯度 e * X / N 换成符号-符号形式
            % sign(e) * sign(X) / N。梯度幅度与信号幅度无关且上界恒为 1,
            % 因此 StepSize 必须相应放大
            % (通常比标准 LMS 的 mu 大 100~300 倍)。
            obj.validateUpdateInput(dataRegressor, errorBlock);
            dataRegressor = double(dataRegressor);
            errorVector = reshape(double(errorBlock), 1, []);
            [deltaCoefficients, gradient] = obj.updateSsLmsFast(dataRegressor, errorVector);

            obj.LastGradient = gradient;
            obj.LastDelta = deltaCoefficients;
            obj.UpdateCount = obj.UpdateCount + 1;
        end

        function [deltaCoefficients, gradient] = updateSsLmsFast(obj, dataRegressor, errorVector)
            % updateSsLmsFast  对调用方已保证合法的 double 数组做符号-符号 LMS。
            % gradient = sign(errorVector) * sign(dataRegressor) / BlockSize。
            % 本路径不更新任何诊断量。
            gradient = sign(errorVector) * sign(dataRegressor) / obj.BlockSize;
            deltaCoefficients = obj.StepSize * gradient;
            deltaCoefficients(~obj.AdaptEnableMask) = 0;
        end

        function setStepSize(obj, stepSize)
            % setStepSize  修改 LMS 步长, 不复位任何状态。
            obj.validateStepSize(stepSize);
            obj.StepSize = double(stepSize);
        end

        function resetState(obj)
            % resetState  清空自适应诊断量与更新计数。
            obj.LastGradient = zeros(1, obj.TapCount);
            obj.LastDelta = zeros(1, obj.TapCount);
            obj.UpdateCount = 0;
        end

        function state = getState(obj)
            % getState  返回 LMS 配置与最近一次更新的结果。
            state = struct();
            state.StepSize = obj.StepSize;
            state.TapCount = obj.TapCount;
            state.MainTapIndex = obj.MainTapIndex;
            state.BlockSize = obj.BlockSize;
            state.AdaptEnableMask = obj.AdaptEnableMask;
            state.LastGradient = obj.LastGradient;
            state.LastDelta = obj.LastDelta;
            state.UpdateCount = obj.UpdateCount;
        end
    end

    methods (Access = private)
        function validateConfiguration(obj, stepSize, tapCount, mainTapIndex, blockSize, adaptEnableMask)
            obj.validateStepSize(stepSize);
            obj.validatePositiveInteger(tapCount, 'tapCount');
            obj.validatePositiveInteger(mainTapIndex, 'mainTapIndex');
            obj.validatePositiveInteger(blockSize, 'blockSize');
            if mainTapIndex > tapCount
                error('cdr_ffe_loop:InvalidMainTapIndex', 'mainTapIndex must not exceed tapCount.');
            end
            maskValid = islogical(adaptEnableMask) || isnumeric(adaptEnableMask);
            maskValid = maskValid && isvector(adaptEnableMask);
            maskValid = maskValid && numel(adaptEnableMask) == tapCount;
            maskValid = maskValid && all(ismember(adaptEnableMask(:), [0 1]));
            if ~maskValid
                error('cdr_ffe_loop:InvalidAdaptEnableMask', 'adaptEnableMask must contain one logical value per tap.');
            end
            % 主抽头是固定的增益锚点，必须在 adaptEnableMask 里被禁用。
            % 这条守卫曾被注释掉，理由写的是"v3 采用增益归一化锚定总增益，
            % 允许所有抽头自适应"。那条路径从未接线：它依赖的
            % cdr_ffe.scaleCoefficients 没有任何调用方(现已删除)，cdr_top
            % 始终显式把主抽头增量置零，而 v3 自己的 runner 连同全部其他
            % runner 的默认 mask 都是 [1 1 0 1 1 1]。守卫缺席的实际后果是
            % 这个旋钮会撒谎：调用方传 mask(mainTapIndex)=1 会被接受，然后
            % 被上层静默抵消。恢复它让四层(本类 / cdr_ffe / cdr_top / 测试)
            % 对同一条不变量取得一致。
            if logical(adaptEnableMask(mainTapIndex))
                error('cdr_ffe_loop:MainTapAdaptEnabled', 'The fixed main tap must be disabled in adaptEnableMask.');
            end
        end

        function validateUpdateInput(obj, dataRegressor, errorBlock)
            regressorValid = isnumeric(dataRegressor);
            regressorValid = regressorValid && isreal(dataRegressor);
            regressorValid = regressorValid && isequal(size(dataRegressor), [obj.BlockSize, obj.TapCount]);
            regressorValid = regressorValid && all(isfinite(dataRegressor(:)));
            if ~regressorValid
                error('cdr_ffe_loop:InvalidRegressor', 'dataRegressor must be a finite BlockSize-by-TapCount matrix.');
            end
            errorValid = isnumeric(errorBlock);
            errorValid = errorValid && isreal(errorBlock);
            errorValid = errorValid && isvector(errorBlock);
            errorValid = errorValid && numel(errorBlock) == obj.BlockSize;
            errorValid = errorValid && all(isfinite(errorBlock(:)));
            if ~errorValid
                error('cdr_ffe_loop:InvalidErrorBlock', 'errorBlock must be a finite real vector with BlockSize elements.');
            end
        end

        function validateStepSize(~, stepSize)
            isValid = isnumeric(stepSize);
            isValid = isValid && isreal(stepSize);
            isValid = isValid && isscalar(stepSize);
            isValid = isValid && isfinite(stepSize);
            isValid = isValid && stepSize >= 0;
            if ~isValid
                error('cdr_ffe_loop:InvalidStepSize', 'stepSize must be a nonnegative finite real scalar.');
            end
        end

        function validatePositiveInteger(~, value, name)
            isValid = isnumeric(value);
            isValid = isValid && isreal(value);
            isValid = isValid && isscalar(value);
            isValid = isValid && isfinite(value);
            isValid = isValid && value >= 1;
            isValid = isValid && value == round(value);
            if ~isValid
                error('cdr_ffe_loop:InvalidConfiguration', '%s must be a positive integer scalar.', name);
            end
        end
    end
end
