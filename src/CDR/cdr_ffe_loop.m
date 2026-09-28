classdef cdr_ffe_loop < handle
    % cdr_ffe_loop  Block-rate LMS adaptation for the dedicated CDR FFE.
    %
    % The caller supplies data-sample decision error and the regressor
    % returned by cdr_ffe. Edge samples do not participate in adaptation.

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
            % cdr_ffe_loop  Construct a floating-point block LMS engine.
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
            % update  Validate inputs and compute one block LMS update.
            obj.validateUpdateInput(dataRegressor, errorBlock);
            dataRegressor = double(dataRegressor);
            errorVector = reshape(double(errorBlock), 1, []);
            [deltaCoefficients, gradient] = obj.updateFast(dataRegressor, errorVector);

            obj.LastGradient = gradient;
            obj.LastDelta = deltaCoefficients;
            obj.UpdateCount = obj.UpdateCount + 1;
        end

        function [deltaCoefficients, gradient] = updateFast(obj, dataRegressor, errorVector)
            % updateFast  Compute an update from caller-validated double arrays.
            % dataRegressor is BlockSize-by-TapCount and errorVector is a
            % 1-by-BlockSize row vector. This path does not update diagnostics.
            gradient = errorVector * dataRegressor / obj.BlockSize;
            deltaCoefficients = obj.StepSize * gradient;
            deltaCoefficients(~obj.AdaptEnableMask) = 0;
        end

        function deltaCoefficients = updateSsLms(obj, dataRegressor, errorBlock)
            % updateSsLms  Sign-sign LMS: validate inputs, compute one block SS-LMS update.
            %
            % Replaces the standard LMS gradient  e * X / N  with the sign-sign
            % variant  sign(e) * sign(X) / N.  Gradient magnitude is bounded by 1
            % regardless of signal amplitude, so the StepSize must be scaled up
            % accordingly (typically 100-300x larger than standard LMS mu).
            obj.validateUpdateInput(dataRegressor, errorBlock);
            dataRegressor = double(dataRegressor);
            errorVector = reshape(double(errorBlock), 1, []);
            [deltaCoefficients, gradient] = obj.updateSsLmsFast(dataRegressor, errorVector);

            obj.LastGradient = gradient;
            obj.LastDelta = deltaCoefficients;
            obj.UpdateCount = obj.UpdateCount + 1;
        end

        function [deltaCoefficients, gradient] = updateSsLmsFast(obj, dataRegressor, errorVector)
            % updateSsLmsFast  Sign-sign LMS from caller-validated double arrays.
            % gradient = sign(errorVector) * sign(dataRegressor) / BlockSize.
            % This path does not update diagnostics.
            gradient = sign(errorVector) * sign(dataRegressor) / obj.BlockSize;
            deltaCoefficients = obj.StepSize * gradient;
            deltaCoefficients(~obj.AdaptEnableMask) = 0;
        end

        function setStepSize(obj, stepSize)
            % setStepSize  Change the LMS step size without resetting state.
            obj.validateStepSize(stepSize);
            obj.StepSize = double(stepSize);
        end

        function resetState(obj)
            % resetState  Clear adaptation diagnostics and update count.
            obj.LastGradient = zeros(1, obj.TapCount);
            obj.LastDelta = zeros(1, obj.TapCount);
            obj.UpdateCount = 0;
        end

        function state = getState(obj)
            % getState  Return the LMS configuration and latest update.
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
