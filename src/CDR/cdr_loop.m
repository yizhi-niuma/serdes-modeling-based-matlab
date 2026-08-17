classdef cdr_loop < handle
    % cdr_loop  CDR 比例-积分环路滤波器行为模型。
    %
    % 本模型接收 voter 输出的数值 phaseError，并输出提供给 cdr_pi 的
    % 整数 PI code 增量。模型不感知 voter 模式，也不负责 PI code wrap。
    % 内部比例、积分和余量状态使用浮点数，避免小于一个 PI code 的控制量丢失。

    properties (SetAccess = private)
        % Kp  比例支路增益，单位为 code / phaseError。
        Kp

        % Ki  积分支路增益，单位为 code / block / phaseError。
        Ki

        % FrequencyMin  积分状态下限，单位为 code / block。
        FrequencyMin = -Inf

        % FrequencyMax  积分状态上限，单位为 code / block。
        FrequencyMax = Inf

        % MaxDeltaCode  每次更新允许输出的最大 PI code 步长。
        % 默认 1，对应硬件相邻 PI code 逐步旋转。
        MaxDeltaCode = 1

        % FrequencyState  当前积分状态，单位为 code / block。
        FrequencyState = 0

        % CodeResidue  尚未形成完整整数 PI code 的累计余量。
        CodeResidue = 0

        % PendingCode  已形成整数、但受 MaxDeltaCode 限制尚未执行的 code。
        PendingCode = 0

        % LastControl  最近一次量化前的 PI 控制量，单位为 code / block。
        LastControl = 0

        % LastRawDeltaCode  最近一次限幅前的整数 PI code 增量。
        LastRawDeltaCode = 0

        % LastDeltaCode  最近一次输出的整数 PI code 增量。
        LastDeltaCode = 0
    end

    methods
        function obj = cdr_loop(Kp, Ki, frequencyMin, frequencyMax, maxDeltaCode)
            % cdr_loop  构造 CDR 环路滤波器。
            %
            % Kp 和 Ki 必须显式配置，避免模型包含未经验证的默认环路增益。
            % frequencyMin / frequencyMax 默认不限制积分状态。

            if nargin < 2
                error('cdr_loop:MissingGain', ...
                    'Kp and Ki must be provided explicitly.');
            end
            if nargin < 3
                frequencyMin = -Inf;
            end
            if nargin < 4
                frequencyMax = Inf;
            end
            if nargin < 5
                maxDeltaCode = 1;
            end

            obj.setGains(Kp, Ki);
            obj.setFrequencyLimits(frequencyMin, frequencyMax);
            obj.setMaxDeltaCode(maxDeltaCode);
        end

        function deltaCode = update(obj, phaseError)
            % update  检查输入并执行一次 block-rate 环路更新。

            obj.validatePhaseError(phaseError);
            deltaCode = obj.updateFast(phaseError);
        end

        function deltaCode = updateFast(obj, phaseError)
            % updateFast  对调用方已保证合法的 phaseError 执行快速更新。
            %
            % 本方法刻意省略输入检查，适合端到端 BER 仿真的 block 热路径。

            phaseError = double(phaseError);
            frequencyState = min(max(obj.FrequencyState + obj.Ki * phaseError, obj.FrequencyMin), obj.FrequencyMax);
            control = obj.Kp * phaseError + frequencyState;
            residueAccum = obj.CodeResidue + control;
            rawDeltaCode = fix(residueAccum);
            pendingAccum = obj.PendingCode + rawDeltaCode;
            deltaCode = min(max(pendingAccum, -obj.MaxDeltaCode), ...
                obj.MaxDeltaCode);

            obj.FrequencyState = frequencyState;
            % CodeResidue 始终只保留不足一个 code 的小数部分；受 slew
            % limit 限制而未执行的完整整数 code 由 PendingCode 单独保存。
            obj.CodeResidue = residueAccum - rawDeltaCode;
            obj.PendingCode = pendingAccum - deltaCode;
            obj.LastControl = control;
            obj.LastRawDeltaCode = rawDeltaCode;
            obj.LastDeltaCode = deltaCode;
        end

        function setGains(obj, Kp, Ki)
            % setGains  配置比例和积分支路增益。

            obj.validateNonnegativeFiniteScalar(Kp, 'Kp');
            obj.validateNonnegativeFiniteScalar(Ki, 'Ki');

            obj.Kp = double(Kp);
            obj.Ki = double(Ki);
        end

        function setFrequencyLimits(obj, frequencyMin, frequencyMax)
            % setFrequencyLimits  配置积分状态限幅并收敛当前状态。

            obj.validateRealScalarOrInf(frequencyMin, 'frequencyMin');
            obj.validateRealScalarOrInf(frequencyMax, 'frequencyMax');
            if frequencyMin == Inf || frequencyMax == -Inf || ...
                    frequencyMin > frequencyMax
                error('cdr_loop:InvalidFrequencyLimits', ...
                    'frequencyMin must be no greater than frequencyMax.');
            end

            obj.FrequencyMin = double(frequencyMin);
            obj.FrequencyMax = double(frequencyMax);
            obj.FrequencyState = min(max(obj.FrequencyState, ...
                obj.FrequencyMin), obj.FrequencyMax);
        end

        function setMaxDeltaCode(obj, maxDeltaCode)
            % setMaxDeltaCode  配置每个 block 最大 PI code 输出步长。
            isPositiveInteger = isnumeric(maxDeltaCode) && isreal(maxDeltaCode) && ...
                isscalar(maxDeltaCode) && isfinite(maxDeltaCode) && ...
                maxDeltaCode >= 1 && maxDeltaCode == round(maxDeltaCode);
            isUnlimited = isnumeric(maxDeltaCode) && isreal(maxDeltaCode) && ...
                isscalar(maxDeltaCode) && maxDeltaCode == Inf;
            if ~(isPositiveInteger || isUnlimited)
                error('cdr_loop:InvalidMaxDeltaCode', ...
                    'maxDeltaCode must be a positive integer or Inf.');
            end
            obj.MaxDeltaCode = double(maxDeltaCode);
        end

        function resetState(obj)
            % resetState  清零动态状态，不改变增益和积分限幅配置。

            obj.FrequencyState = min(max(0, obj.FrequencyMin), obj.FrequencyMax);
            obj.CodeResidue = 0;
            obj.PendingCode = 0;
            obj.LastControl = 0;
            obj.LastRawDeltaCode = 0;
            obj.LastDeltaCode = 0;
        end

        function state = getState(obj)
            % getState  返回当前配置和动态状态的调试快照。

            state = struct();
            state.Kp = obj.Kp;
            state.Ki = obj.Ki;
            state.FrequencyMin = obj.FrequencyMin;
            state.FrequencyMax = obj.FrequencyMax;
            state.MaxDeltaCode = obj.MaxDeltaCode;
            state.FrequencyState = obj.FrequencyState;
            state.CodeResidue = obj.CodeResidue;
            state.PendingCode = obj.PendingCode;
            state.LastControl = obj.LastControl;
            state.LastRawDeltaCode = obj.LastRawDeltaCode;
            state.LastDeltaCode = obj.LastDeltaCode;
        end
    end

    methods (Access = private)
        function validatePhaseError(~, phaseError)
            % validatePhaseError  检查 voter 输出是否为有限实数标量。

            if ~isnumeric(phaseError) || ~isreal(phaseError) || ...
                    ~isscalar(phaseError) || ~isfinite(phaseError)
                error('cdr_loop:InvalidPhaseError', ...
                    'phaseError must be a finite real numeric scalar.');
            end
        end

        function validateNonnegativeFiniteScalar(~, value, name)
            % validateNonnegativeFiniteScalar  检查非负有限实数标量。

            if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ...
                    ~isfinite(value) || value < 0
                error('cdr_loop:InvalidGain', ...
                    '%s must be a nonnegative finite real scalar.', name);
            end
        end

        function validateRealScalarOrInf(~, value, name)
            % validateRealScalarOrInf  检查有限实数或无穷实数标量。

            if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ...
                    isnan(value)
                error('cdr_loop:InvalidFrequencyLimits', ...
                    '%s must be a real numeric scalar.', name);
            end
        end
    end
end
