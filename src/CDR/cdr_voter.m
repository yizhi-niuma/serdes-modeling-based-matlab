classdef cdr_voter < handle
    % cdr_voter  CDR 相位判决块内投票行为模型。
    %
    % 本模型将一个并行 block 的相位判决聚合为一个有符号相位误差输出。
    % 每个输入判决必须为 -1、0 或 +1。linear 模式保留有符号净票数，
    % constant 模式仅保留净票数符号，并使用 ConstantMagnitude 作为幅度。

    properties (SetAccess = private)
        % Mode  投票模式：linear 或 constant。
        Mode = 'linear'

        % BlockSize  单个并行 block 中的相位判决数量。
        BlockSize = 64

        % ConstantMagnitude  constant 模式使用的输出幅度。
        ConstantMagnitude = int16(8)
    end

    properties (SetAccess = private, Hidden)
        % ModeId  热路径使用的数值模式：0=linear，1=constant。
        ModeId = uint8(0)
    end

    methods
        function obj = cdr_voter(mode, blockSize, constantMagnitude)
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

            obj.setMode(mode);
            obj.BlockSize = obj.validatePositiveInt16Scalar(blockSize, 'blockSize');
            obj.ConstantMagnitude = obj.validatePositiveInt16Scalar( ...
                constantMagnitude, 'constantMagnitude');
        end

        function phaseError = vote(obj, phaseDecision)
            % vote  检查并聚合一个并行相位判决 block。
            obj.validatePhaseDecision(phaseDecision);
            phaseError = obj.calculateVote(phaseDecision);
        end

        function phaseError = voteFast(obj, phaseDecision)
            % voteFast  聚合一个已由调用方保证合法的并行相位判决 block。
            %
            % 调用方必须提供只包含 -1、0 和 +1 的合法单 block 向量。
            % 本方法刻意不执行输入检查。
            phaseDecisionCount = sum(int16(phaseDecision), 'native');
            modeId = obj.ModeId;

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
            % setMode  选择 linear 或 constant 投票模式。
            if isstring(mode) && isscalar(mode)
                mode = char(mode);
            end
            if ~ischar(mode) || ~isrow(mode)
                error('cdr_voter:InvalidMode', ...
                    'mode must be ''linear'' or ''constant''.');
            end

            mode = lower(mode);
            switch mode
                case 'linear'
                    modeId = uint8(0);
                case 'constant'
                    modeId = uint8(1);
                otherwise
                    error('cdr_voter:InvalidMode', ...
                        'mode must be ''linear'' or ''constant''.');
            end

            obj.Mode = mode;
            obj.ModeId = modeId;
        end
    end

    methods (Access = private)
        function phaseError = calculateVote(obj, phaseDecision)
            % calculateVote  按当前配置执行投票计算。
            phaseDecisionCount = sum(int16(phaseDecision), 'native');

            if obj.ModeId == 0
                phaseError = phaseDecisionCount;
            elseif phaseDecisionCount > 0
                phaseError = obj.ConstantMagnitude;
            elseif phaseDecisionCount < 0
                phaseError = -obj.ConstantMagnitude;
            else
                phaseError = int16(0);
            end
        end

        function validatePhaseDecision(obj, phaseDecision)
            % validatePhaseDecision  检查一个完整的相位判决向量。
            if ~(isnumeric(phaseDecision) || islogical(phaseDecision)) || ...
                    ~isreal(phaseDecision) || ~isvector(phaseDecision) || ...
                    numel(phaseDecision) ~= obj.BlockSize || ...
                    any(~isfinite(phaseDecision(:))) || ...
                    any(phaseDecision(:) < -1 | phaseDecision(:) > 1) || ...
                    any(phaseDecision(:) ~= round(phaseDecision(:)))
                error('cdr_voter:InvalidPhaseDecision', ...
                    ['phaseDecision must be a real vector with BlockSize ' ...
                    'elements containing only -1, 0, and +1.']);
            end
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
