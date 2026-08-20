classdef cdr_ffe_lms < handle
    % cdr_ffe_lms  Block-rate LMS adaptation for the dedicated CDR FFE.
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
        function obj = cdr_ffe_lms(stepSize, tapCount, mainTapIndex, blockSize, adaptEnableMask)
            % cdr_ffe_lms  Construct a floating-point block LMS engine.
            if nargin < 1
                error('cdr_ffe_lms:MissingStepSize', 'stepSize must be provided explicitly.');
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
            deltaCoefficients = obj.updateFast(dataRegressor, errorBlock);
        end

        function deltaCoefficients = updateFast(obj, dataRegressor, errorBlock)
            % updateFast  Compute one caller-validated block LMS update.
            errorVector = reshape(double(errorBlock), 1, []);
            gradient = errorVector * double(dataRegressor) / obj.BlockSize;
            deltaCoefficients = obj.StepSize * gradient;
            deltaCoefficients(~obj.AdaptEnableMask) = 0;

            obj.LastGradient = gradient;
            obj.LastDelta = deltaCoefficients;
            obj.UpdateCount = obj.UpdateCount + 1;
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
                error('cdr_ffe_lms:InvalidMainTapIndex', 'mainTapIndex must not exceed tapCount.');
            end
            maskValid = islogical(adaptEnableMask) || isnumeric(adaptEnableMask);
            maskValid = maskValid && isvector(adaptEnableMask);
            maskValid = maskValid && numel(adaptEnableMask) == tapCount;
            maskValid = maskValid && all(ismember(adaptEnableMask(:), [0 1]));
            if ~maskValid
                error('cdr_ffe_lms:InvalidAdaptEnableMask', 'adaptEnableMask must contain one logical value per tap.');
            end
            if logical(adaptEnableMask(mainTapIndex))
                error('cdr_ffe_lms:MainTapAdaptEnabled', 'The fixed main tap must be disabled in adaptEnableMask.');
            end
        end

        function validateUpdateInput(obj, dataRegressor, errorBlock)
            regressorValid = isnumeric(dataRegressor);
            regressorValid = regressorValid && isreal(dataRegressor);
            regressorValid = regressorValid && isequal(size(dataRegressor), [obj.BlockSize, obj.TapCount]);
            regressorValid = regressorValid && all(isfinite(dataRegressor(:)));
            if ~regressorValid
                error('cdr_ffe_lms:InvalidRegressor', 'dataRegressor must be a finite BlockSize-by-TapCount matrix.');
            end
            errorValid = isnumeric(errorBlock);
            errorValid = errorValid && isreal(errorBlock);
            errorValid = errorValid && isvector(errorBlock);
            errorValid = errorValid && numel(errorBlock) == obj.BlockSize;
            errorValid = errorValid && all(isfinite(errorBlock(:)));
            if ~errorValid
                error('cdr_ffe_lms:InvalidErrorBlock', 'errorBlock must be a finite real vector with BlockSize elements.');
            end
        end

        function validateStepSize(~, stepSize)
            isValid = isnumeric(stepSize);
            isValid = isValid && isreal(stepSize);
            isValid = isValid && isscalar(stepSize);
            isValid = isValid && isfinite(stepSize);
            isValid = isValid && stepSize >= 0;
            if ~isValid
                error('cdr_ffe_lms:InvalidStepSize', 'stepSize must be a nonnegative finite real scalar.');
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
                error('cdr_ffe_lms:InvalidConfiguration', '%s must be a positive integer scalar.', name);
            end
        end
    end
end
