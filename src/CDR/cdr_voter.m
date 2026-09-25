classdef cdr_voter < handle
    % cdr_voter  CDR 相位判决块内投票行为模型。
    %
    % 本模型将一个并行 block 的相位判决聚合为一个有符号相位误差输出。
    % 每个输入判决必须为 -1、0 或 +1。linear 模式保留有符号净票数，
    % constant 模式仅保留净票数符号，并使用 ConstantMagnitude 作为幅度；
    % mean 模式返回 double 类型的判决均值。

    properties (SetAccess = private)
        % Mode  投票模式：linear、constant 或 mean。
        Mode = 'linear'

        % BlockSize  单个并行 block 中的相位判决数量。
        BlockSize = 64

        % ConstantMagnitude  constant 模式使用的输出幅度。
        ConstantMagnitude = int16(8)

        % MeanDenominator  mean 模式分母；'auto' 表示使用实际输入长度。
        MeanDenominator = 'auto'
    end

    properties (SetAccess = private, Hidden)
        % ModeId  热路径使用的数值模式：0=linear，1=constant，2=mean。
        ModeId = uint8(0)
    end

    methods
        function obj = cdr_voter(mode, blockSize, constantMagnitude, meanDenominator)
            % cdr_voter  构造块内 voter 行为模型。
            if nargin < 1
                mode = 'linear';
            end
            if nargin < 2
                blockSize = 64;
            end
            if nargin < 3
                constantMagnitude = 8;
            end
            if nargin < 4
                meanDenominator = 'auto';
            end

            obj.setMode(mode);
            obj.BlockSize = obj.validatePositiveInt16Scalar(blockSize, 'blockSize');
            obj.ConstantMagnitude = obj.validatePositiveInt16Scalar( ...
                constantMagnitude, 'constantMagnitude');
            obj.MeanDenominator = obj.validateMeanDenominator(meanDenominator);
        end

        function phaseError = vote(obj, phaseDecision)
            % vote  检查并聚合一个并行相位判决 block。
            obj.validatePhaseDecision(phaseDecision);
            phaseError = obj.voteFast(phaseDecision);
        end

        function phaseError = voteFast(obj, phaseDecision)
            % voteFast  聚合一个已由调用方保证合法的并行相位判决 block。
            %
            % 调用方必须提供只包含 -1、0 和 +1 的合法单 block 向量。
            % 本方法刻意不执行输入检查。
            modeId = obj.ModeId;
            if modeId == 2
                if ischar(obj.MeanDenominator)
                    denominator = numel(phaseDecision);
                else
                    denominator = obj.MeanDenominator;
                end
                phaseError = double(sum(double(phaseDecision))) / denominator;
                return;
            end

            phaseDecisionCount = sum(int16(phaseDecision), 'native');
            if modeId == 0
                phaseError = phaseDecisionCount;
            elseif phaseDecisionCount > 0
                phaseError = obj.ConstantMagnitude;
            elseif phaseDecisionCount < 0
                phaseError = -obj.ConstantMagnitude;
            else
                phaseError = int16(0);
            end
        end

        function setMode(obj, mode)
            % setMode  选择 linear、constant 或 mean 投票模式。
            if isstring(mode) && isscalar(mode)
                mode = char(mode);
            end
            if ~ischar(mode) || ~isrow(mode)
                error('cdr_voter:InvalidMode', ...
                    'mode must be ''linear'', ''constant'', or ''mean''.');
            end

            mode = lower(mode);
            switch mode
                case 'linear'
                    modeId = uint8(0);
                case 'constant'
                    modeId = uint8(1);
                case 'mean'
                    modeId = uint8(2);
                otherwise
                    error('cdr_voter:InvalidMode', ...
                        'mode must be ''linear'', ''constant'', or ''mean''.');
            end

            obj.Mode = mode;
            obj.ModeId = modeId;
        end
    end

    methods (Access = private)
        function validatePhaseDecision(obj, phaseDecision)
            % validatePhaseDecision  检查一个完整或 mean 部分相位判决向量。
            decisionCount = numel(phaseDecision);
            if obj.ModeId == 2
                isLengthValid = decisionCount >= 1 && decisionCount <= obj.BlockSize;
            else
                isLengthValid = decisionCount == obj.BlockSize;
            end
            if ~(isnumeric(phaseDecision) || islogical(phaseDecision)) || ...
                    ~isreal(phaseDecision) || ~isvector(phaseDecision) || ...
                    ~isLengthValid || any(~isfinite(phaseDecision(:))) || ...
                    any(phaseDecision(:) < -1 | phaseDecision(:) > 1) || ...
                    any(phaseDecision(:) ~= round(phaseDecision(:)))
                error('cdr_voter:InvalidPhaseDecision', ...
                    ['phaseDecision must be a real vector with a valid length ' ...
                    'containing only -1, 0, and +1.']);
            end
        end

        function value = validateMeanDenominator(~, value)
            % validateMeanDenominator  检查 mean 模式分母配置。
            if isstring(value) && isscalar(value)
                value = char(value);
            end
            if ischar(value) && isrow(value) && strcmpi(value, 'auto')
                value = 'auto';
                return;
            end
            if ~(isnumeric(value) && isreal(value) && isscalar(value) && ...
                    isfinite(value) && value > 0)
                error('cdr_voter:InvalidConfiguration', ...
                    'meanDenominator must be ''auto'' or a positive finite numeric scalar.');
            end
            value = double(value);
        end

        function value = validatePositiveInt16Scalar(~, value, name)
            % validatePositiveInt16Scalar  检查 int16 正数范围内的整数标量。
            if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ...
                    ~isfinite(value) || value <= 0 || value ~= round(value) || ...
                    value > double(intmax('int16'))
                error('cdr_voter:InvalidConfiguration', ...
                    '%s must be a positive integer no greater than %d.', ...
                    name, intmax('int16'));
            end

            value = int16(value);
        end
    end
end
