classdef sar_adc_core
    %SAR_ADC_CORE Differential-input SAR ADC core model with zero-order-hold output.
    %
    %   obj = SAR_ADC_CORE(VL, VH, N, nonideal_en) creates an N-bit
    %   differential-input SAR ADC core model. The model assumes Vip/Vin have
    %   already been held by the previous TAH stage. Each rising edge of clk
    %   advances one SAR bit decision. After N rising edges, the digital output
    %   code and reconstructed output voltage are updated and then held until
    %   the next completed conversion.
    %
    %   Inputs:
    %       VL          Lower reference voltage.
    %       VH          Upper reference voltage.
    %       N           ADC resolution in bits.
    %       nonideal_en Enable default capacitor, comparator, and bit-offset
    %                   nonidealities when true.
    %
    %   Outputs:
    %       obj         Initialized SAR ADC core object.
    %
    %   Notes:
    %       - The model uses a binary-weighted capacitive DAC with optional
    %         unit-capacitor mismatch and parasitic capacitance.
    %       - Comparator offset, noise, and per-bit offsets are modeled as
    %         input-referred voltage terms.
    %       - Dout, Dout_dec, and Vout are zero-order-held outputs updated only
    %         after a full conversion is completed.

    properties
        % 电容阵列
        Cu = 1e-15              % 单位电容值，用于构造二进制权重电容阵列
        sigmaCu                 % 单位电容随机失配系数
        Cp_p                    % 正端 DAC 阵列寄生电容
        C_tot_p                 % 正端 DAC 等效总电容
        C_act_p                 % 各 bit 实际有效电容值
        BitWeights              % 数字码对应的二进制 bit 权重

        % 比较器参数
        % Positive Comp_offset is added to sampled input, increasing output code.
        % Comp_offset, Comp_noise, and BitOffset are input-referred voltage terms.
        Comp_offset             % 比较器输入等效失调电压
        Comp_noise              % 比较器输入等效随机噪声标准差

        VL                      % ADC 低参考电压
        VH                      % ADC 高参考电压

        N                       % ADC 分辨率位数
        lsb                     % 理想 LSB 电压，用于输入等效 offset 标定
        BitOffset               % 每个 bit 决策对应的输入等效 offset

        % 时钟 / 转换状态
        PrevClk                 % 上一次调用时的时钟高低状态
        Busy                    % 当前是否处于一次 SAR 转换过程中
        BitIndex                % 当前已完成或正在处理的 bit 索引
        VipHold                 % 当前转换锁存的正端输入电压
        VinHold                 % 当前转换锁存的负端输入电压
        VdiffHold               % 当前转换锁存的差分输入电压
        WorkingBits             % 当前转换过程中的逐位试探结果

        % 零阶保持输出
        DoutHold                % 最近一次完整转换的二进制输出码
        Dout_decHold            % 最近一次完整转换的十进制输出码
        VoutHold                % 最近一次完整转换对应的 DAC 重构电压

        % 最近一次转换 trace
        trace_en                % bit-by-bit trace 记录使能标志
        CurrentTrace            % 当前转换过程的逐 bit trace 数据
        LastTrace               % 最近一次完整转换的 trace 数据
    end

    methods
        function obj = sar_adc_core(VL, VH, N, nonideal_en)
            %SAR_ADC_CORE Construct and initialize a SAR ADC core object.
            %   obj = SAR_ADC_CORE() uses default references [-0.3, 0.3], 7-bit
            %   resolution, and ideal-mode parameters.
            %
            %   obj = SAR_ADC_CORE(VL, VH, N, nonideal_en) initializes the ADC
            %   core with user-defined reference range, resolution, and optional
            %   default nonideal parameter set.

            % 设置非理想模型使能的默认值。
            if nargin < 4
                nonideal_en = false;
            end

            % 设置 ADC 分辨率默认值。
            if nargin < 3
                N = 7;
            end

            % 设置高参考电压默认值。
            if nargin < 2
                VH = 0.3;
            end

            % 设置低参考电压默认值。
            if nargin < 1
                VL = -0.3;
            end

            obj = obj.initializeParameters(VL, VH, N); % 初始化参考电压、分辨率和理想基础参数

            % 根据使能标志选择默认非理想参数或理想参数。
            if nonideal_en
                obj = obj.applyNonidealParameters(0.005, 1e-15, 0.0015, 1, 0);
            else
                obj = obj.applyIdealParameters();
            end

            obj = obj.initializeState(); % 初始化转换状态和输出保持寄存器
        end

        function [obj, Dout, Dout_dec, Vout, conversionDone, varargout] = convertByClock(obj, Vip, Vin, clk)
            %CONVERTBYCLOCK Advance SAR conversion according to the input clock.
            %   [obj, Dout, Dout_dec, Vout, conversionDone] = CONVERTBYCLOCK(obj, Vip, Vin, clk)
            %   detects the rising edge of clk and advances one SAR bit decision
            %   per edge. Vip/Vin are assumed to be held by the previous TAH
            %   stage. Output values are zero-order-held between completed
            %   conversions.
            %
            %   [obj, Dout, Dout_dec, Vout, conversionDone, trace] also returns
            %   the latest completed conversion trace when trace mode is enabled;
            %   otherwise trace is returned as [].
            %
            %   Inputs:
            %       Vip             Held positive input voltage.
            %       Vin             Held negative input voltage.
            %       clk             Clock level; values greater than 0.5 are high.
            %
            %   Outputs:
            %       Dout            Held binary output code vector.
            %       Dout_dec        Held decimal output code.
            %       Vout            Held reconstructed output voltage.
            %       conversionDone  True only on the call that completes N bits.
            %       trace           Optional latest completed conversion trace.

            clkHigh = clk > 0.5;                    % 将输入时钟电平转换为逻辑高低状态
            prevHigh = obj.PrevClk;                 % 保存上一拍时钟状态用于边沿检测
            risingEdge = clkHigh && ~prevHigh;      % 检测当前调用是否出现上升沿
            conversionDone = false;                 % 默认当前调用未完成完整转换

            % 仅在时钟上升沿推进 SAR 状态机。
            if risingEdge

                % 空闲状态下，第一个上升沿锁存输入并启动新一次转换。
                if ~obj.Busy
                    obj = obj.startConversion(Vip, Vin);
                end

                obj = obj.resolveOneBit(); % 对当前 bit 执行一次试探和比较决策

                % 当已完成 N 个 bit 决策后，更新保持输出并结束本次转换。
                if obj.BitIndex >= obj.N
                    obj = obj.completeConversion();
                    conversionDone = true;
                end
            end

            obj.PrevClk = clkHigh;      % 更新时钟历史状态供下一次边沿检测使用
            Dout = obj.DoutHold;        % 输出最近一次完整转换的保持二进制码
            Dout_dec = obj.Dout_decHold;% 输出最近一次完整转换的保持十进制码
            Vout = obj.VoutHold;        % 输出最近一次完整转换的保持重构电压

            % 按调用方请求返回 trace；未使能 trace 时返回空数组。
            if nargout > 5
                if obj.trace_en
                    varargout{1} = obj.LastTrace;
                else
                    varargout{1} = [];
                end
            end
        end

        function obj = setIdealMode(obj)
            %SETIDEALMODE Disable noise, mismatch, parasitic capacitance, and offsets.
            %   obj = SETIDEALMODE(obj) resets the ADC core to deterministic ideal
            %   parameter values. This mode is suitable for repeatable unit tests.

            obj = obj.applyIdealParameters(); % 应用理想参数并刷新电容阵列
        end

        function obj = setNonideal(obj, varargin)
            %SETNONIDEAL Configure selected nonideal terms with name-value pairs.
            %   obj = SETNONIDEAL(obj, name, value, ...) first resets the model to
            %   ideal mode, then applies the specified nonideal options.
            %
            %   Supported names:
            %       'sigmaCu' or 'sigma_cu'             Unit-capacitor mismatch.
            %       'cp', 'cp_p', or 'cpp'              Parasitic capacitance.
            %       'compNoise' or 'comp_noise'         Comparator noise sigma.
            %       'bitOffsetSigma' or 'bit_offset_sigma' Per-bit offset sigma in LSB.
            %       'compOffset' or 'comp_offset'       Comparator offset.

            obj = obj.setIdealMode(); % 先回到理想模式，避免历史非理想参数残留
            updateCap = false;        % 标记是否需要根据电容相关参数刷新阵列

            % 校验非理想参数必须以 name-value pair 形式输入。
            if mod(numel(varargin), 2) ~= 0
                error('setNonideal expects name-value pairs.');
            end

            % 逐对解析并应用非理想参数配置。
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

            % 仅当电容失配或寄生电容发生变化时重新计算电容阵列。
            if updateCap
                obj = obj.updateCapArray();
            end
        end

        function obj = reset(obj)
            %RESET Clear clock state, conversion state, and held outputs.
            %   obj = RESET(obj) reinitializes the SAR state machine and output
            %   hold registers without changing reference voltages or nonideal
            %   parameter settings.

            obj = obj.initializeState(); % 重置状态机、保持输入、保持输出和 trace 缓存
        end

        function obj = setTraceMode(obj, trace_en)
            %SETTRACEMODE Enable or disable bit-by-bit trace recording.
            %   obj = SETTRACEMODE(obj) enables trace recording by default.
            %   obj = SETTRACEMODE(obj, trace_en) uses the logical value of
            %   trace_en to enable or disable trace storage.

            % 未显式指定时，默认开启 trace 记录。
            if nargin < 2
                trace_en = true;
            end

            obj.trace_en = logical(trace_en); % 归一化为逻辑类型，便于状态判断

            % 根据 trace 模式初始化或清空 trace 缓存。
            if obj.trace_en
                obj.CurrentTrace = obj.initTrace();
                obj.LastTrace = obj.initTrace();
            else
                obj.CurrentTrace = [];
                obj.LastTrace = [];
            end
        end

        function trace = getLastTrace(obj)
            %GETLASTTRACE Return the latest completed conversion trace.
            %   trace = GETLASTTRACE(obj) returns LastTrace. When trace mode is
            %   disabled, LastTrace is empty.

            trace = obj.LastTrace; % 返回最近一次完整转换的逐 bit trace 数据
        end
    end

    methods (Access = private)
        % SAR conversion helpers
        function obj = startConversion(obj, Vip, Vin)
            %STARTCONVERSION Latch the held input and initialize one SAR conversion.
            %   obj = STARTCONVERSION(obj, Vip, Vin) starts a new conversion by
            %   storing the held differential input and clearing the working bit
            %   register.

            obj.Busy = true;                  % 标记 SAR 状态机进入转换状态
            obj.BitIndex = 0;                 % 从 MSB 决策前的初始 bit 索引开始
            obj.VipHold = Vip;                % 锁存当前正端输入电压
            obj.VinHold = Vin;                % 锁存当前负端输入电压
            obj.VdiffHold = Vip - Vin;        % 计算并锁存差分输入电压
            obj.WorkingBits = zeros(1, obj.N);% 清空本次转换的工作码寄存器

            % trace 模式下记录本次转换的输入采样信息。
            if obj.trace_en
                obj.CurrentTrace = obj.initTrace();
                obj.CurrentTrace.Vip = Vip;
                obj.CurrentTrace.Vin = Vin;
                obj.CurrentTrace.Vdiff = obj.VdiffHold;
            end
        end

        function obj = resolveOneBit(obj)
            %RESOLVEONEBIT Resolve one SAR bit using trial DAC voltage comparison.
            %   obj = RESOLVEONEBIT(obj) advances BitIndex, sets the current trial
            %   bit to 1, evaluates the residual polarity including comparator
            %   nonidealities, and stores the final decision for that bit.

            obj.BitIndex = obj.BitIndex + 1; % 进入下一个 bit 的决策
            i = obj.BitIndex;                % 缓存当前 bit 索引用于数组访问

            trialBits = obj.WorkingBits;     % 复制当前工作码用于本轮试探
            trialBits(i) = 1;                % 将当前 bit 置 1 形成试探码
            VdacTrial = obj.bitsToVdac(trialBits); % 计算试探码对应的 DAC 电压
            noiseSample = obj.Comp_noise * randn(1, 1); % 生成本次比较器噪声采样值

            % gain_cp only scales residual amplitude; it does not change bit decision polarity.
            gain_cp = sum(obj.C_act_p) / obj.C_tot_p;

            inputOffset = obj.Comp_offset + obj.BitOffset(i); % 合成本 bit 的输入等效 offset
            vipCompare = obj.VdiffHold + inputOffset + noiseSample; % 形成含 offset/noise 的比较输入
            vresidual = (VdacTrial - vipCompare) * gain_cp; % 计算经电容增益缩放后的残差电压

            % 根据残差极性确定当前 bit 的最终决策。
            if vresidual < 0
                obj.WorkingBits(i) = 1;
            else
                obj.WorkingBits(i) = 0;
            end

            VdacAfterDecision = obj.bitsToVdac(obj.WorkingBits); % 计算当前决策后的 DAC 电压

            % trace 模式下记录本 bit 的试探、电噪声、残差和最终 DAC 电压。
            if obj.trace_en
                obj = obj.updateBitTrace(i, VdacTrial, noiseSample, vresidual, VdacAfterDecision);
            end
        end

        function obj = completeConversion(obj)
            %COMPLETECONVERSION Commit the working code to held outputs.
            %   obj = COMPLETECONVERSION(obj) updates DoutHold, Dout_decHold, and
            %   VoutHold after all N bit decisions are complete, then returns the
            %   SAR state machine to idle.

            obj.DoutHold = obj.WorkingBits;                    % 锁存完整转换得到的二进制输出码
            obj.Dout_decHold = obj.DoutHold * obj.BitWeights'; % 将二进制输出码换算为十进制码
            obj.VoutHold = obj.bitsToVdac(obj.DoutHold);       % 计算并保持输出重构电压

            % trace 模式下保存本次完整转换记录，供外部读取。
            if obj.trace_en
                obj.LastTrace = obj.CurrentTrace;
            end

            obj.Busy = false; % 转换完成后返回空闲状态
            obj.BitIndex = 0; % 清零 bit 索引，为下一次转换做准备
        end

        function Vdac = bitsToVdac(obj, bits)
            %BITSTOVDAC Calculate DAC voltage using actual capacitor weights.
            %   Vdac = BITSTOVDAC(obj, bits) maps a binary bit vector to the
            %   corresponding mathematical DAC voltage. This function is not a
            %   complete charge-redistribution transient model.
            %
            %   Under an ideal capacitor array, the result is equivalent to
            %   code * lsb plus VL. Cp_p only reduces DAC gain through the total
            %   capacitance denominator.

            Vdac = obj.VL + sum(bits .* obj.C_act_p) / obj.C_tot_p * (obj.VH - obj.VL); % 按实际电容权重计算 DAC 电压
        end
    end

    methods (Access = private)
        % Parameter and state initialization helpers
        function obj = initializeParameters(obj, VL, VH, N)
            %INITIALIZEPARAMETERS Initialize reference, resolution, and base parameters.
            %   obj = INITIALIZEPARAMETERS(obj, VL, VH, N) stores reference
            %   voltages and resolution, then initializes all nonideal terms to
            %   deterministic defaults before applying mode-specific settings.

            obj.sigmaCu = 0;        % 默认无单位电容失配
            obj.Cp_p = 0;           % 默认无寄生电容
            obj.Comp_offset = 0.00; % 默认无比较器失调
            obj.Comp_noise = 0;     % 默认无比较器随机噪声
            obj.trace_en = false;   % 默认关闭转换 trace 记录

            obj.VL = VL;            % 保存低参考电压
            obj.VH = VH;            % 保存高参考电压
            obj.N = N;              % 保存 ADC 分辨率
            % lsb is used as an input-referred offset scale; DAC output uses actual capacitor weights.
            obj.lsb = (VH - VL) / (2^N);
            obj.BitWeights = 2.^((obj.N-1):-1:0); % 生成 MSB 到 LSB 的二进制权重
            obj.BitOffset = zeros(1, N);           % 初始化每个 bit 的输入等效 offset
        end

        function obj = applyIdealParameters(obj)
            %APPLYIDEALPARAMETERS Apply deterministic ideal ADC parameters.
            %   obj = APPLYIDEALPARAMETERS(obj) clears capacitor mismatch,
            %   parasitic capacitance, comparator noise, comparator offset, and
            %   per-bit offsets, then rebuilds the capacitor array.

            obj.sigmaCu = 0;                    % 清除单位电容失配
            obj.Cp_p = 0;                       % 清除寄生电容
            obj.Comp_noise = 0;                 % 清除比较器噪声
            obj.Comp_offset = 0;                % 清除比较器失调
            obj.BitOffset = zeros(1, obj.N);    % 清除逐 bit 输入等效 offset
            obj = obj.updateCapArray();         % 按理想参数重建电容阵列
        end

        function obj = applyNonidealParameters(obj, sigmaCuValue, CpValue, compNoiseValue, bitOffsetSigmaValue, compOffsetValue)
            %APPLYNONIDEALPARAMETERS Apply default or user-specified nonideal parameters.
            %   obj = APPLYNONIDEALPARAMETERS(obj, sigmaCuValue, CpValue,
            %   compNoiseValue, bitOffsetSigmaValue, compOffsetValue) configures
            %   capacitor mismatch, parasitic capacitance, comparator noise,
            %   random per-bit offset, and comparator offset.

            % 未指定逐 bit offset 标准差时，默认使用 1 LSB。
            if nargin < 5 || isempty(bitOffsetSigmaValue)
                bitOffsetSigmaValue = 1;
            end

            % 未指定比较器失调时，默认无固定失调。
            if nargin < 6 || isempty(compOffsetValue)
                compOffsetValue = 0;
            end

            obj.sigmaCu = sigmaCuValue;                                      % 设置单位电容失配系数
            obj.Cp_p = CpValue;                                              % 设置寄生电容
            obj.Comp_noise = compNoiseValue;                                 % 设置比较器噪声标准差
            obj.Comp_offset = compOffsetValue;                               % 设置比较器输入等效失调
            obj.BitOffset = randn(1, obj.N) * bitOffsetSigmaValue * obj.lsb; % 生成逐 bit 随机 offset
            obj = obj.updateCapArray();                                      % 按非理想参数重建电容阵列
        end

        function obj = initializeState(obj)
            %INITIALIZESTATE Initialize clock, conversion, output, and trace state.
            %   obj = INITIALIZESTATE(obj) resets runtime state without changing
            %   the ADC reference range, resolution, or nonideal parameter values.

            obj.PrevClk = false;                 % 初始化时钟历史状态为低电平
            obj.Busy = false;                    % 初始化为空闲状态
            obj.BitIndex = 0;                    % 初始化 bit 决策索引
            obj.VipHold = 0;                     % 清零正端锁存输入
            obj.VinHold = 0;                     % 清零负端锁存输入
            obj.VdiffHold = 0;                   % 清零差分锁存输入
            obj.WorkingBits = zeros(1, obj.N);   % 清空工作码寄存器
            obj.DoutHold = zeros(1, obj.N);      % 清空输出二进制保持码
            obj.Dout_decHold = 0;                % 清空十进制保持码
            obj.VoutHold = obj.VL;               % 初始化输出保持电压为低参考电压

            % 根据 trace 模式初始化或清空 trace 数据结构。
            if obj.trace_en
                obj.CurrentTrace = obj.initTrace();
                obj.LastTrace = obj.initTrace();
            else
                obj.CurrentTrace = [];
                obj.LastTrace = [];
            end
        end

        function obj = updateCapArray(obj)
            %UPDATECAPARRAY Recalculate actual binary-weighted capacitor array.
            %   obj = UPDATECAPARRAY(obj) builds the effective per-bit capacitor
            %   values using binary weights, optional mismatch, and parasitic
            %   capacitance, then updates the total capacitance denominator.

            obj.C_act_p = obj.BitWeights .* obj.Cu + obj.sigmaCu .* obj.Cu .* sqrt(obj.BitWeights) .* randn(1, obj.N); % 计算含失配的实际 bit 电容
            obj.C_tot_p = sum(obj.C_act_p) + obj.Cu + obj.Cp_p; % 计算含 dummy 单位电容和寄生电容的总电容
        end

    end

    methods (Access = private)
        % Trace helpers
        function obj = updateBitTrace(obj, i, VdacTrial, noiseSample, vresidual, VdacAfterDecision)
            %UPDATEBITTRACE Store trace information for one SAR bit decision.
            %   obj = UPDATEBITTRACE(obj, i, VdacTrial, noiseSample, vresidual,
            %   VdacAfterDecision) records the trial DAC value, comparator noise,
            %   residual, final bit value, and post-decision DAC voltage.

            obj.CurrentTrace.VdacTrial(i) = VdacTrial;                       % 记录当前 bit 试探 DAC 电压
            obj.CurrentTrace.NoiseSample(i) = noiseSample;                   % 记录当前 bit 比较器噪声采样
            obj.CurrentTrace.Vresidual(i) = vresidual;                       % 记录当前 bit 决策残差
            obj.CurrentTrace.bit(i) = obj.WorkingBits(i);                    % 记录当前 bit 最终决策值
            obj.CurrentTrace.VdacAfterDecision(i) = VdacAfterDecision;       % 记录决策后的 DAC 电压
        end

        function trace = initTrace(obj)
            %INITTRACE Create an empty trace structure for one conversion.
            %   trace = INITTRACE(obj) returns a struct with scalar input fields
            %   and N-length per-bit arrays initialized to NaN or zero.

            trace = struct();                                % 创建 trace 结构体
            trace.Vip = NaN;                                 % 初始化正端输入记录
            trace.Vin = NaN;                                 % 初始化负端输入记录
            trace.Vdiff = NaN;                               % 初始化差分输入记录
            trace.bit = zeros(1, obj.N);                     % 初始化 bit 决策记录
            trace.NoiseSample = NaN(1, obj.N);               % 初始化比较器噪声记录
            trace.VdacTrial = NaN(1, obj.N);                 % 初始化试探 DAC 电压记录
            trace.VdacAfterDecision = NaN(1, obj.N);         % 初始化决策后 DAC 电压记录
            trace.Vresidual = NaN(1, obj.N);                 % 初始化残差电压记录
        end
    end

end
