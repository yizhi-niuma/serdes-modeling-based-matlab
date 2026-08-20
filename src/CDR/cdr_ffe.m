classdef cdr_ffe < handle
    % cdr_ffe  Dedicated symbol-spaced CDR feed-forward equalizer.
    %
    % Coefficients are ordered from precursor to postcursor. The causal
    % implementation delays the equalized output by PreTapCount UI so that
    % precursor taps do not require future samples at the block interface.

    properties (SetAccess = private)
        Coefficients
        InitialCoefficients
        TapCount
        PreTapCount
        MainTapIndex
        PostTapCount
        InputHistory
        ProcessedSampleCount = 0
    end

    methods
        function obj = cdr_ffe(initialCoefficients, preTapCount)
            % cdr_ffe  Construct a floating-point CDR FFE.
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

        function [outputBlock, regressor, validOutput] = processBlock(obj, inputBlock)
            % processBlock  Validate and filter one CDR sample block.
            obj.validateInputBlock(inputBlock);
            [outputBlock, regressor, validOutput] = obj.processBlockFast(inputBlock);
        end

        function [outputBlock, regressor, validOutput] = processBlockFast(obj, inputBlock)
            % processBlockFast  Filter one caller-validated CDR sample block.
            blockLength = numel(inputBlock);
            processedBeforeBlock = obj.ProcessedSampleCount;
            [outputBlock, regressor, obj.InputHistory] = obj.filterOneStream(inputBlock, obj.InputHistory);

            globalSampleIndex = processedBeforeBlock + (1:blockLength);
            validOutput = globalSampleIndex > obj.PreTapCount;
            validOutput = reshape(validOutput, size(inputBlock));
            obj.ProcessedSampleCount = processedBeforeBlock + blockLength;
        end

        function applyCoefficientDelta(obj, deltaCoefficients)
            % applyCoefficientDelta  Apply one block-rate LMS coefficient update.
            isValid = isnumeric(deltaCoefficients);
            isValid = isValid && isreal(deltaCoefficients);
            isValid = isValid && isvector(deltaCoefficients);
            isValid = isValid && numel(deltaCoefficients) == obj.TapCount;
            isValid = isValid && all(isfinite(deltaCoefficients(:)));
            if ~isValid
                error('cdr_ffe:InvalidCoefficientDelta', 'deltaCoefficients must be a finite real vector with TapCount elements.');
            end

            deltaCoefficients = reshape(double(deltaCoefficients), 1, []);
            if deltaCoefficients(obj.MainTapIndex) ~= 0
                error('cdr_ffe:MainTapUpdate', 'The fixed main tap coefficient cannot be updated.');
            end
            obj.Coefficients = obj.Coefficients + deltaCoefficients;
        end

        function resetState(obj)
            % resetState  Restore initial coefficients and clear stream history.
            historyLength = numel(obj.InitialCoefficients) - 1;
            obj.Coefficients = obj.InitialCoefficients;
            obj.InputHistory = zeros(1, historyLength);
            obj.ProcessedSampleCount = 0;
        end

        function state = getState(obj)
            % getState  Return the current FFE configuration and dynamic state.
            state = struct();
            state.Coefficients = obj.Coefficients;
            state.InitialCoefficients = obj.InitialCoefficients;
            state.TapCount = obj.TapCount;
            state.PreTapCount = obj.PreTapCount;
            state.MainTapIndex = obj.MainTapIndex;
            state.PostTapCount = obj.PostTapCount;
            state.InputHistory = obj.InputHistory;
            state.ProcessedSampleCount = obj.ProcessedSampleCount;
        end
    end

    methods (Access = private)
        function [outputBlock, regressor, nextHistory] = filterOneStream(obj, inputBlock, history)
            % filterOneStream  Apply the causal form of the precursor-aligned FIR.
            inputVector = reshape(double(inputBlock), 1, []);
            extendedInput = [history, inputVector];
            blockLength = numel(inputVector);
            currentIndex = (obj.TapCount - 1) + (1:blockLength).';
            tapOffset = 0:obj.TapCount - 1;
            regressor = extendedInput(currentIndex - tapOffset);
            outputVector = regressor * obj.Coefficients.';
            outputBlock = reshape(outputVector, size(inputBlock));

            historyLength = obj.TapCount - 1;
            if historyLength == 0
                nextHistory = zeros(1, 0);
            else
                nextHistory = extendedInput(end - historyLength + 1:end);
            end
        end

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

        function validateInputBlock(~, inputBlock)
            isValid = isnumeric(inputBlock);
            isValid = isValid && isreal(inputBlock);
            isValid = isValid && isvector(inputBlock);
            isValid = isValid && ~isempty(inputBlock);
            isValid = isValid && all(isfinite(inputBlock(:)));
            if ~isValid
                error('cdr_ffe:InvalidInputBlock', 'inputBlock must be a nonempty finite real numeric vector.');
            end
        end
    end
end
