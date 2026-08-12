classdef sar_adc_core
    %SAR_ADC_CORE differential-input SAR ADC core model with zero-order-hold output.
    %
    %   Behavior:
    %   - Input Vip/Vin is already held by the previous TAH stage.
    %   - A rising edge of clk advances the SAR by one bit decision.
    %   - When idle, the first rising edge latches the held differential input and resolves the MSB.
    %   - A full conversion takes N rising edges.
    %   - Dout/Dout_dec/Vout update only after the Nth bit is resolved.
    %   - Between completed conversions the output is held unchanged.

    properties
        % 电容阵列
        Cu
        sigmaCu
        Cp_p
        C_tot_p
        C_act_p
        BitWeights

        % 比较器参数
        % Positive Comp_offset is added to sampled input, increasing output code.
        % Comp_offset, Comp_noise, and BitOffset are input-referred voltage terms.
        Comp_offset
        Comp_noise

        VL
        VH

        N
        lsb
        BitOffset

        % 时钟 / 转换状态
        PrevClk
        Busy
        BitIndex
        Vip
        Vin
        Vdiff
        WorkingBits

        % 零阶保持输出
        DoutHold
        Dout_decHold
        VoutHold

        % 最近一次转换 trace
        trace_en
        CurrentTrace
        LastTrace
    end

    methods
        function obj = sar_adc_core(VL, VH, N, nonideal_en)
            if nargin < 4
                nonideal_en = false;
            end
            if nargin < 3
                N = 7;
            end
            if nargin < 2
                VH = 0.3;
            end
            if nargin < 1
                VL = -0.3;
            end

            obj = obj.initializeParameters(VL, VH, N);
            if nonideal_en
                obj = obj.applyNonidealParameters(0.005, 1e-15, 0.0015, 1, 0);
            else
                obj = obj.applyIdealParameters();
            end
            obj = obj.initializeState();
        end

        function [obj, Dout, Dout_dec, Vout, conversionDone, varargout] = convertByClock(obj, Vip, Vin, clk)
            %CONVERTBYCLOCK 根据已保持的 Vip/Vin/clk 推进 SAR ADC core，并返回零阶保持输出。
            %   Vip/Vin 由前级 TAH 保持；core 本身不再执行 track/sample。
            %   clk 使用方波电平输入；每个 rising edge 推进一个 SAR bit。
            %   第 6 个可选输出返回最近一次完整转换 trace；trace_en=false 时返回 []。
            clkHigh = clk > 0.5;
            prevHigh = obj.PrevClk;
            risingEdge = clkHigh && ~prevHigh;
            conversionDone = false;

            if risingEdge
                if ~obj.Busy
                    obj = obj.startConversion(Vip, Vin);
                end

                obj = obj.resolveOneBit();

                if obj.BitIndex >= obj.N
                    obj = obj.completeConversion();
                    conversionDone = true;
                end
            end

            obj.PrevClk = clkHigh;
            Dout = obj.DoutHold;
            Dout_dec = obj.Dout_decHold;
            Vout = obj.VoutHold;
            if nargout > 5
                if obj.trace_en
                    varargout{1} = obj.LastTrace;
                else
                    varargout{1} = [];
                end
            end
        end

        function obj = setIdealMode(obj)
            %SETIDEALMODE 关闭随机噪声、失配、寄生和建立误差，用于可重复单元测试。
            obj = obj.applyIdealParameters();
        end

        function obj = setNonideal(obj, varargin)
            %SETNONIDEAL Reset to ideal mode, then configure selected nonideal terms with name-value pairs.
            obj = obj.setIdealMode();
            updateCap = false;

            if mod(numel(varargin), 2) ~= 0
                error('setNonideal expects name-value pairs.');
            end

            for k = 1:2:numel(varargin)
                name = lower(char(varargin{k}));
                value = varargin{k + 1};
                switch name
                    case {'sigmacu', 'sigma_cu'}
                        obj.sigmaCu = value;
                        updateCap = true;
                    case {'cp', 'cp_p', 'cpp'}
                        obj.Cp_p = value;
                        updateCap = true;
                    case {'compnoise', 'comp_noise'}
                        obj.Comp_noise = value;
                    case {'bitoffsetsigma', 'bit_offset_sigma'}
                        obj.BitOffset = randn(1, obj.N) * value * obj.lsb;
                    case {'compoffset', 'comp_offset'}
                        obj.Comp_offset = value;
                    otherwise
                        error('Unknown nonideal option: %s', varargin{k});
                end
            end

            if updateCap
                obj = obj.updateCapArray();
            end
        end

        function obj = setCapUnit(obj, Cu)
            %SETCAPUNIT Set unit capacitance and update the capacitor array.
            obj.Cu = Cu;
            obj = obj.updateCapArray();
        end

        function obj = reset(obj)
            %RESET 清空时钟状态、转换状态和保持输出。
            obj = obj.initializeState();
        end

        function obj = setTraceMode(obj, trace_en)
            %SETTRACEMODE Enable or disable bit-by-bit trace recording.
            if nargin < 2
                trace_en = true;
            end
            obj.trace_en = logical(trace_en);
            if obj.trace_en
                obj.CurrentTrace = obj.initTrace();
                obj.LastTrace = obj.initTrace();
            else
                obj.CurrentTrace = [];
                obj.LastTrace = [];
            end
        end

        function trace = getLastTrace(obj)
            %GETLASTTRACE 返回最近一次完整转换 trace；trace_en=false 时 LastTrace 为空。
            trace = obj.LastTrace;
        end
    end

    methods (Access = private)
        % SAR conversion helpers
        function obj = startConversion(obj, Vip, Vin)
            obj.Busy = true;
            obj.BitIndex = 0;
            obj.Vip = Vip;
            obj.Vin = Vin;
            obj.Vdiff = Vip - Vin;
            obj.WorkingBits = zeros(1, obj.N);
            if obj.trace_en
                obj.CurrentTrace = obj.initTrace();
                obj.CurrentTrace.Vip = Vip;
                obj.CurrentTrace.Vin = Vin;
                obj.CurrentTrace.Vdiff = obj.Vdiff;
            end
        end

        function obj = resolveOneBit(obj)
            obj.BitIndex = obj.BitIndex + 1;
            i = obj.BitIndex;

            trialBits = obj.WorkingBits;
            trialBits(i) = 1;
            VdacTrial = obj.bitsToVdac(trialBits);
            noiseSample = obj.Comp_noise * randn(1, 1);

            % gain_cp only scales residual amplitude; it does not change bit decision polarity.
            gain_cp = sum(obj.C_act_p) / obj.C_tot_p;

            inputOffset = obj.Comp_offset + obj.BitOffset(i);
            vipCompare = obj.Vdiff + inputOffset + noiseSample;
            vresidual = (VdacTrial - vipCompare) * gain_cp;
            if vresidual < 0
                obj.WorkingBits(i) = 1;
            else
                obj.WorkingBits(i) = 0;
            end

            VdacAfterDecision = obj.bitsToVdac(obj.WorkingBits);
            if obj.trace_en
                obj = obj.updateBitTrace(i, VdacTrial, noiseSample, vresidual, VdacAfterDecision);
            end
        end

        function obj = completeConversion(obj)
            obj.DoutHold = obj.WorkingBits;
            obj.Dout_decHold = obj.DoutHold * obj.BitWeights';
            obj.VoutHold = obj.bitsToVdac(obj.DoutHold);
            if obj.trace_en
                obj.LastTrace = obj.CurrentTrace;
            end
            obj.Busy = false;
            obj.BitIndex = 0;
        end

        function Vdac = bitsToVdac(obj, bits)
            %BITSTOVDAC 使用实际电容权重计算数学 DAC 电压；不是完整电荷重分配模型。
            %   理想电容阵列下等价于 code * lsb；Cp_p 只通过分母降低 DAC 增益。
            Vdac = obj.VL + sum(bits .* obj.C_act_p) / obj.C_tot_p * (obj.VH - obj.VL);
        end
    end

    methods (Access = private)
        % Parameter and state initialization helpers
        function obj = initializeParameters(obj, VL, VH, N)
            obj.Cu = 1e-15;
            obj.sigmaCu = 0;
            obj.Cp_p = 0;
            obj.Comp_offset = 0.00;
            obj.Comp_noise = 0;
            obj.trace_en = false;

            obj.VL = VL;
            obj.VH = VH;
            obj.N = N;
            % lsb is used as an input-referred offset scale; DAC output uses actual capacitor weights.
            obj.lsb = (VH - VL) / (2^N);
            obj.BitWeights = 2.^((obj.N-1):-1:0);
            obj.BitOffset = zeros(1, N);
        end

        function obj = applyIdealParameters(obj)
            obj.sigmaCu = 0;
            obj.Cp_p = 0;
            obj.Comp_noise = 0;
            obj.Comp_offset = 0;
            obj.BitOffset = zeros(1, obj.N);
            obj = obj.updateCapArray();
        end

        function obj = applyNonidealParameters(obj, sigmaCuValue, CpValue, compNoiseValue, bitOffsetSigmaValue, compOffsetValue)
            if nargin < 5 || isempty(bitOffsetSigmaValue)
                bitOffsetSigmaValue = 1;
            end
            if nargin < 6 || isempty(compOffsetValue)
                compOffsetValue = 0;
            end

            obj.sigmaCu = sigmaCuValue;
            obj.Cp_p = CpValue;
            obj.Comp_noise = compNoiseValue;
            obj.Comp_offset = compOffsetValue;
            obj.BitOffset = randn(1, obj.N) * bitOffsetSigmaValue * obj.lsb;
            obj = obj.updateCapArray();
        end

        function obj = initializeState(obj)
            obj.PrevClk = false;
            obj.Busy = false;
            obj.BitIndex = 0;
            obj.Vip = 0;
            obj.Vin = 0;
            obj.Vdiff = 0;
            obj.WorkingBits = zeros(1, obj.N);
            obj.DoutHold = zeros(1, obj.N);
            obj.Dout_decHold = 0;
            obj.VoutHold = obj.VL;
            if obj.trace_en
                obj.CurrentTrace = obj.initTrace();
                obj.LastTrace = obj.initTrace();
            else
                obj.CurrentTrace = [];
                obj.LastTrace = [];
            end
        end

        function obj = updateCapArray(obj)
            obj.C_act_p = obj.BitWeights .* obj.Cu + obj.sigmaCu .* obj.Cu .* sqrt(obj.BitWeights) .* randn(1, obj.N);
            obj.C_tot_p = sum(obj.C_act_p) + obj.Cu + obj.Cp_p;
        end

    end

    methods (Access = private)
        % Trace helpers
        function obj = updateBitTrace(obj, i, VdacTrial, noiseSample, vresidual, VdacAfterDecision)
            obj.CurrentTrace.VdacTrial(i) = VdacTrial;
            obj.CurrentTrace.NoiseSample(i) = noiseSample;
            obj.CurrentTrace.Vresidual(i) = vresidual;
            obj.CurrentTrace.bit(i) = obj.WorkingBits(i);
            obj.CurrentTrace.VdacAfterDecision(i) = VdacAfterDecision;
        end

        function trace = initTrace(obj)
            trace = struct();
            trace.Vip = NaN;
            trace.Vin = NaN;
            trace.Vdiff = NaN;
            trace.bit = zeros(1, obj.N);
            trace.NoiseSample = NaN(1, obj.N);
            trace.VdacTrial = NaN(1, obj.N);
            trace.VdacAfterDecision = NaN(1, obj.N);
            trace.Vresidual = NaN(1, obj.N);
        end
    end

end
