classdef cdr_pd < handle
    % cdr_pd  CDR 环路中的数字 Phase Detector（PD）行为模型。

    properties (SetAccess = private)
        % Mode  调制模式：nrz 或 pam4。
        Mode = 'pam4'

        % Polarity  PD 输出极性。
        Polarity = 1

        % LastOutput  最近一次 PD 判决的完整输出快照。
        LastOutput
    end

    properties (SetAccess = private, Hidden)
        % ModeId  热路径使用的数值模式：0=NRZ，1=PAM4。
        ModeId = uint8(1)
    end

    methods
        function obj = cdr_pd(mode, polarity)
            % cdr_pd  构造数字 BBPD/MMPD 行为模型。

            if nargin < 1
                mode = 'pam4';
            end
            if nargin < 2
                polarity = 1;
            end

            obj.setMode(mode);
            obj.setPolarity(polarity);
            obj.resetState();
        end

        function [phaseDecision, valid, output] = bbpd(obj, dataPrev, edgeBit, dataCurr)
            % bbpd  根据数字 D[n-1] / E[n] / D[n] 生成 BBPD 判决。
            %
            % NRZ 模式使用 0/1 data 和 edge 判决，所有 data 跳变均有效。
            % PAM4 模式使用 0~3 symbol code，并只使用 00<->11 和
            % 01<->10 对称跳变。edgeBit 在两种模式下均为 0/1。

            obj.validateSameSize(dataPrev, edgeBit, dataCurr);
            obj.validateDigitalArray(edgeBit, 0, 1, 'edgeBit');
            maxSymbol = 1 + 2 * double(obj.ModeId);
            obj.validateDigitalArray(dataPrev, 0, maxSymbol, 'dataPrev');
            obj.validateDigitalArray(dataCurr, 0, maxSymbol, 'dataCurr');

            [phaseDecision, valid] = obj.bbpdFast(dataPrev, edgeBit, dataCurr);

            output = struct();
            output.PdType = 'bbpd';
            output.Mode = obj.Mode;
            output.Polarity = obj.Polarity;
            output.DataSymbolPrev = dataPrev;
            output.EdgeBit = edgeBit;
            output.DataSymbolCurr = dataCurr;
            output.Valid = valid;
            output.PhaseDecision = phaseDecision;

            obj.LastOutput = output;
        end

        function [phaseDecision, valid] = bbpdFast(obj, dataPrev, edgeBit, dataCurr)
            % bbpdFast  面向块向量化 BER 仿真的无检查 BBPD 热路径。
            %
            % 调用方必须保证三路输入尺寸一致、码值合法且不含 NaN/Inf。
            % 本方法不生成调试结构，也不更新 LastOutput。

            modeId = obj.ModeId;
            polarity = int8(obj.Polarity);

            switch modeId
                case 0
                    valid = dataPrev ~= dataCurr;
                    early = valid & (edgeBit == dataPrev);

                case 1
                    outerTransition = (dataPrev == 0 & dataCurr == 3) | ...
                        (dataPrev == 3 & dataCurr == 0);
                    innerTransition = (dataPrev == 1 & dataCurr == 2) | ...
                        (dataPrev == 2 & dataCurr == 1);
                    valid = outerTransition | innerTransition;
                    early = valid & ((edgeBit ~= 0) == (dataPrev >= 2));

                otherwise
                    error('cdr_pd:InvalidModeId', 'Unsupported numeric PD mode: %d.', modeId);
            end

            phaseDecision = zeros(size(valid), 'int8');
            phaseDecision(valid) = -polarity;
            phaseDecision(early) = polarity;
        end

        function [phaseDecision, valid, output] = mmpd(~, dataPrev, errorPrev, dataCurr, errorCurr) %#ok<INUSD>
            % mmpd  MMPD 数字接口框架，算法尚未实现。

            phaseDecision = []; %#ok<NASGU>
            valid = []; %#ok<NASGU>
            output = struct(); %#ok<NASGU>
            error('cdr_pd:MMPDNotImplemented', ...
                'MMPD is not implemented yet. Use bbpd for the current model.');
        end

        function setMode(obj, mode)
            % setMode  设置调制模式：nrz 或 pam4。

            if isstring(mode) && isscalar(mode)
                mode = char(mode);
            end
            if ~ischar(mode) || ~isrow(mode)
                error('cdr_pd:InvalidMode', 'mode must be ''nrz'' or ''pam4''.');
            end

            mode = lower(mode);
            if ~ismember(mode, {'nrz', 'pam4'})
                error('cdr_pd:InvalidMode', 'mode must be ''nrz'' or ''pam4''.');
            end

            obj.Mode = mode;
            if strcmp(mode, 'nrz')
                obj.ModeId = uint8(0);
            else
                obj.ModeId = uint8(1);
            end
            obj.resetState();
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
            state.Mode = obj.Mode;
            state.Polarity = obj.Polarity;
            state.LastOutput = obj.LastOutput;
        end
    end

    methods (Access = private)
        function validateSameSize(~, dataPrev, edgeBit, dataCurr)
            % validateSameSize  检查三路数字输入尺寸一致。

            if ~isequal(size(dataPrev), size(edgeBit)) || ~isequal(size(dataPrev), size(dataCurr))
                error('cdr_pd:SizeMismatch', ...
                    'dataPrev, edgeBit, and dataCurr must have the same size.');
            end
        end

        function validateDigitalArray(~, value, minValue, maxValue, name)
            % validateDigitalArray  检查有限、整数且位于指定范围的数字数组。

            if ~(isnumeric(value) || islogical(value)) || isempty(value) || ...
                    any(~isfinite(value(:))) || any(value(:) ~= round(value(:))) || ...
                    any(value(:) < minValue) || any(value(:) > maxValue)
                error('cdr_pd:InvalidDigitalInput', ...
                    '%s must contain integer values from %d to %d.', name, minValue, maxValue);
            end
        end

        function validatePolarity(~, polarity)
            % validatePolarity  检查 polarity 是否为 +1 或 -1。

            if ~isnumeric(polarity) || ~isscalar(polarity) || ~(polarity == 1 || polarity == -1)
                error('cdr_pd:InvalidPolarity', 'polarity must be +1 or -1.');
            end
        end
    end
end
