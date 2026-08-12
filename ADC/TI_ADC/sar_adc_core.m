classdef sar_adc_core < handle
    %SAR_ADC_CORE 单端逐次逼近型模数转换器核心行为模型，支持瞬时完成一次完整转换。
    %
    %   行为说明：
    %   - 输入 Vin 已经由前级采样级完成采样。
    %   - 每次 convertInstant 调用锁存一个采样输入，并在函数内部完成全部 N bit SAR 判决。
    %   - 模型保留逐 bit 试探、比较和更新的 SAR 行为逻辑，同时使用真实 CDAC bit 权重。
    %   - 核心不再包含外部时钟输入，也不维护时钟驱动的逐位状态机。
    %   - Dout、Dout_dec、Vout 在一次 convertInstant 返回时已经完成更新。
    %
    %   API 使用说明：
    %   - convertInstant / convertVector 是默认带检查版本，保留输入校验、一次性诊断警告
    %     和可选逐位跟踪，推荐用于调试、单元测试和模型前期调通。
    %   - convertInstantFast 是 code-only 高吞吐单点版本，只输出 Dout_dec。
    %   - convertVectorFast 是高吞吐向量版本，保留 Dout_dec、Vout 和可选 Dout 输出。
    %     快速版本跳过诊断警告和跟踪记录，默认参数已由设置函数校验。

    properties (SetAccess = private)
        % 可配置参数通过 setter 方法修改，避免外部绕过校验直接写入非法值。
        Cu = 1
        sigmaCu = 0
        Gain = 1

        % 比较器参数
        % 正 Comp_offset 会加到采样输入端，使输出码字增大。
        % Comp_offset、Comp_noise 和 BitOffset 均为输入等效电压项。
        % Comp_noise 当前建模为每一次 bit 判决独立抽样的输入等效随机噪声。
        Comp_offset = 0
        Comp_noise = 0
        BitOffset

        % ADC 基本参数
        VL
        VH
        N
        lsb
        BitWeights

        % 电容阵列派生参数
        C_tot
        C_act
        C_dummy

        % 转换内部状态
        VinHold
        WorkingBits

        % 最近一次转换 trace
        trace_en = false
        CurrentTrace
        LastTrace
        InputOverdriveWarned = false
        VdacOutOfRangeWarned = false
    end

    methods
        function obj = sar_adc_core(VL, VH, N)
            if nargin < 3
                N = 7;
            end
            if nargin < 2
                VH = 0.3;
            end
            if nargin < 1
                VL = -0.3;
            end

            obj.initializeParameters(VL, VH, N);
            obj.applyIdealParameters();
            obj.initializeState();
        end

        function [Dout_dec, Vout, Dout, varargout] = convertInstant(obj, Vin)
            %CONVERTINSTANT 对一个已采样单端输入瞬时完成 SAR 转换。
            %   Vin 由前级采样器根据索引采样得到；核心本身不处理时钟、时钟数据恢复抖动或插值。
            %   Dout_dec 和 Vout 为默认输出；可选第 3 个输出 Dout 为位向量；可选第 4 个输出返回跟踪信息。
            if nargout > 4
                error('convertInstant supports at most 4 outputs: Dout_dec, Vout, Dout, trace.');
            end
            obj.validateInputSample(Vin);

            obj.startConversion(Vin);
            for bitIndex = 1:obj.N
                obj.resolveOneBit(bitIndex);
            end
            [Dout_dec, Vout, Dout] = obj.completeConversion();

            if nargout > 3
                if obj.trace_en
                    varargout{1} = obj.LastTrace;
                else
                    varargout{1} = [];
                end
            end
        end

        function [Dout_dec, Vout, Dout] = convertVector(obj, Vin)
            %CONVERTVECTOR 转换已采样输入序列，并保持输入形状。
            %   convertVector 有意作为诊断版本，会逐采样点调用 convertInstant。
            %   对长波形或多通道串行链路仿真，应使用 convertVectorFast。
            inputSize = size(Vin);
            Vin = Vin(:).';
            numSamples = numel(Vin);
            Dout_dec_vector = zeros(1, numSamples);
            Vout_vector = zeros(1, numSamples);

            if nargout > 2
                Dout_vector = zeros(numSamples, obj.N);
                for sampleIndex = 1:numSamples
                    [Dout_dec_vector(sampleIndex), Vout_vector(sampleIndex), doutBits] = obj.convertInstant(Vin(sampleIndex));
                    Dout_vector(sampleIndex, :) = doutBits;
                end
            else
                for sampleIndex = 1:numSamples
                    [Dout_dec_vector(sampleIndex), Vout_vector(sampleIndex)] = obj.convertInstant(Vin(sampleIndex));
                end
            end

            Dout_dec = reshape(Dout_dec_vector, inputSize);
            Vout = reshape(Vout_vector, inputSize);
            if nargout > 2
                Dout = reshape(Dout_vector, [inputSize, obj.N]);
            end
        end

        function Dout_dec = convertInstantFast(obj, Vin)
            %CONVERTINSTANTFAST 面向大规模仿真的单点快速 SAR code-only 转换。
            %   该路径只返回十进制码字，跳过输入校验、Vout、Dout 和 trace 记录。
            %   本函数只服务主仿真路径；如需 Vout、Dout 或 trace，请使用 convertInstant。
            VL_local = obj.VL;
            VH_local = obj.VH;
            N_local = obj.N;
            Gain_local = obj.Gain;
            C_act_local = obj.C_act;
            BitWeights_local = obj.BitWeights;
            Comp_offset_local = obj.Comp_offset;
            Comp_noise_local = obj.Comp_noise;
            BitOffset_local = obj.BitOffset;
            Vcm_local = (VH_local + VL_local) / 2;
            fullScale_local = VH_local - VL_local;
            dacScale_local = fullScale_local / obj.C_tot;
            invGain_local = 1 / Gain_local;

            capSum_local = 0;
            Dout_dec = 0;

            if Comp_noise_local == 0
                for bitIndex = 1:N_local
                    trialCapSum_local = capSum_local + C_act_local(bitIndex);
                    VdacIdeal = VL_local + trialCapSum_local * dacScale_local;
                    VdacTrial = Vcm_local + (VdacIdeal - Vcm_local) * invGain_local;
                    vinCompare = Vin + Comp_offset_local + BitOffset_local(bitIndex);
                    if VdacTrial - vinCompare < 0
                        capSum_local = trialCapSum_local;
                        Dout_dec = Dout_dec + BitWeights_local(bitIndex);
                    end
                end
            else
                for bitIndex = 1:N_local
                    trialCapSum_local = capSum_local + C_act_local(bitIndex);
                    VdacIdeal = VL_local + trialCapSum_local * dacScale_local;
                    VdacTrial = Vcm_local + (VdacIdeal - Vcm_local) * invGain_local;
                    noiseSample = Comp_noise_local * randn(1, 1);
                    vinCompare = Vin + Comp_offset_local + BitOffset_local(bitIndex) + noiseSample;
                    if VdacTrial - vinCompare < 0
                        capSum_local = trialCapSum_local;
                        Dout_dec = Dout_dec + BitWeights_local(bitIndex);
                    end
                end
            end
        end

        function [Dout_dec, Vout, Dout] = convertVectorFast(obj, Vin)
            %CONVERTVECTORFAST 面向大规模仿真的快速向量 SAR 转换，并保持输入形状。
            %   该路径跳过输入校验、一次性警告和跟踪记录，用于参数已配置后的高吞吐仿真。
            %   Dout_dec 和 Vout 保持 size(Vin)；可选 Dout 的尺寸为 [size(Vin), N]。
            %   为获得最高吞吐，若不需要逐位结果，调用时只接收 Dout_dec 和 Vout。
            %   本函数的核心判决逻辑应与 convertInstantFast 保持一致。
            inputSize = size(Vin);
            Vin = reshape(Vin, 1, []);
            numSamples = numel(Vin);

            VL_local = obj.VL;
            VH_local = obj.VH;
            N_local = obj.N;
            Gain_local = obj.Gain;
            C_act_local = obj.C_act;
            BitWeights_local = obj.BitWeights;
            Comp_offset_local = obj.Comp_offset;
            Comp_noise_local = obj.Comp_noise;
            BitOffset_local = obj.BitOffset;
            Vcm_local = (VH_local + VL_local) / 2;
            fullScale_local = VH_local - VL_local;
            dacScale_local = fullScale_local / obj.C_tot;
            invGain_local = 1 / Gain_local;
            outScale_local = fullScale_local / (2^N_local);
            needDout_local = nargout > 2;

            Dout_dec_vector = zeros(1, numSamples);
            Vout_vector = zeros(1, numSamples);
            if needDout_local
                Dout_vector = zeros(numSamples, N_local);
            end

            if Comp_noise_local == 0
                for sampleIndex = 1:numSamples
                    capSum_local = 0;
                    doutDec_local = 0;
                    if needDout_local
                        doutBits = zeros(1, N_local);
                    end
                    for bitIndex = 1:N_local
                        trialCapSum_local = capSum_local + C_act_local(bitIndex);
                        VdacIdeal = VL_local + trialCapSum_local * dacScale_local;
                        VdacTrial = Vcm_local + (VdacIdeal - Vcm_local) * invGain_local;
                        vinCompare = Vin(sampleIndex) + Comp_offset_local + BitOffset_local(bitIndex);
                        if VdacTrial - vinCompare < 0
                            capSum_local = trialCapSum_local;
                            doutDec_local = doutDec_local + BitWeights_local(bitIndex);
                            if needDout_local
                                doutBits(bitIndex) = 1;
                            end
                        end
                    end
                    Dout_dec_vector(sampleIndex) = doutDec_local;
                    Vout_vector(sampleIndex) = VL_local + doutDec_local * outScale_local;
                    if needDout_local
                        Dout_vector(sampleIndex, :) = doutBits;
                    end
                end
            else
                for sampleIndex = 1:numSamples
                    capSum_local = 0;
                    doutDec_local = 0;
                    if needDout_local
                        doutBits = zeros(1, N_local);
                    end
                    for bitIndex = 1:N_local
                        trialCapSum_local = capSum_local + C_act_local(bitIndex);
                        VdacIdeal = VL_local + trialCapSum_local * dacScale_local;
                        VdacTrial = Vcm_local + (VdacIdeal - Vcm_local) * invGain_local;
                        noiseSample = Comp_noise_local * randn(1, 1);
                        vinCompare = Vin(sampleIndex) + Comp_offset_local + BitOffset_local(bitIndex) + noiseSample;
                        if VdacTrial - vinCompare < 0
                            capSum_local = trialCapSum_local;
                            doutDec_local = doutDec_local + BitWeights_local(bitIndex);
                            if needDout_local
                                doutBits(bitIndex) = 1;
                            end
                        end
                    end
                    Dout_dec_vector(sampleIndex) = doutDec_local;
                    Vout_vector(sampleIndex) = VL_local + doutDec_local * outScale_local;
                    if needDout_local
                        Dout_vector(sampleIndex, :) = doutBits;
                    end
                end
            end

            Dout_dec = reshape(Dout_dec_vector, inputSize);
            Vout = reshape(Vout_vector, inputSize);
            if needDout_local
                Dout = reshape(Dout_vector, [inputSize, N_local]);
            end
        end

        function resetToIdeal(obj)
            %RESETTOIDEAL 恢复全部非理想参数，并清除转换状态。
            %   该方法会清除电容失配、Gain、比较器失调/噪声、BitOffset、
            %   一次性警告状态、转换状态和跟踪缓存。若只需要清除转换状态，
            %   请改用 resetState。
            obj.applyIdealParameters();
            obj.initializeState();
        end

        function setCapMismatch(obj, sigmaCuValue)
            %SETCAPMISMATCH 配置单位电容失配系数，并重新生成 CDAC 阵列。
            obj.validateNonnegativeFiniteScalar(sigmaCuValue, 'sigmaCu');
            obj.sigmaCu = sigmaCuValue;
            obj.updateCapArray();
            obj.VdacOutOfRangeWarned = false;
            obj.invalidateTrace();
        end

        function setCapArray(obj, C_act, C_dummy)
            %SETCAPARRAY 注入固定 CDAC 电容阵列，用于确定性的失配测试。
            if ~isnumeric(C_act) || ~isvector(C_act) || numel(C_act) ~= obj.N || any(~isfinite(C_act(:))) || any(C_act(:) <= 0)
                error('C_act must be a positive finite numeric vector with N elements.');
            end
            obj.validatePositiveFiniteScalar(C_dummy, 'C_dummy');
            obj.C_act = reshape(C_act, 1, obj.N);
            obj.C_dummy = C_dummy;
            obj.C_tot = sum(obj.C_act) + obj.C_dummy;
            if obj.C_tot <= 0 || ~isfinite(obj.C_tot)
                error('Total capacitor value must be positive and finite.');
            end
            obj.VdacOutOfRangeWarned = false;
            obj.invalidateTrace();
        end

        function setGain(obj, gainValue)
            %SETGAIN 配置最终 code transfer gain；Gain 通过 bitsToVdac 影响 SAR 判决和输出码字。
            obj.validatePositiveFiniteScalar(gainValue, 'Gain');
            if gainValue < 0.1 || gainValue > 10
                warning('sar_adc_core:ExtremeGain', ...
                    'Gain %.6g is far from 1 and may cause severe code saturation or compressed transfer behavior.', gainValue);
            end
            obj.Gain = gainValue;
            obj.VdacOutOfRangeWarned = false;
            obj.invalidateTrace();
        end

        function setComparator(obj, compOffsetValue, compNoiseValue)
            %SETCOMPARATOR 配置比较器输入等效 offset 和每 bit 独立噪声。
            if nargin < 3
                compNoiseValue = obj.Comp_noise;
            end
            obj.validateFiniteScalar(compOffsetValue, 'Comp_offset');
            obj.validateNonnegativeFiniteScalar(compNoiseValue, 'Comp_noise');
            obj.Comp_offset = compOffsetValue;
            obj.Comp_noise = compNoiseValue;
            obj.invalidateTrace();
        end

        function setBitOffsetSigmaLSB(obj, bitOffsetSigmaLSB)
            %SETBITOFFSETSIGMALSB 按 LSB 为单位的 sigma 生成每一位固定输入等效 offset。
            %   bitOffsetSigmaLSB 的单位为 LSB，内部生成的 BitOffset 单位为 V。
            obj.validateNonnegativeFiniteScalar(bitOffsetSigmaLSB, 'BitOffsetSigmaLSB');
            obj.BitOffset = randn(1, obj.N) * bitOffsetSigmaLSB * obj.lsb;
            obj.invalidateTrace();
        end

        function resetState(obj)
            %RESETSTATE 清除转换状态和跟踪缓存，不改变非理想参数。
            obj.initializeState();
        end

        function resetWarningState(obj)
            %RESETWARNINGSTATE 重新使能当前 ADC 对象的一次性诊断警告。
            obj.InputOverdriveWarned = false;
            obj.VdacOutOfRangeWarned = false;
        end

        function setTraceMode(obj, trace_en)
            %SETTRACEMODE 使能或关闭逐位跟踪记录。
            if nargin < 2
                trace_en = true;
            end
            if ~(islogical(trace_en) && isscalar(trace_en)) && ...
                    ~(isnumeric(trace_en) && isscalar(trace_en) && isfinite(trace_en) && (trace_en == 0 || trace_en == 1))
                error('trace_en must be a logical scalar or numeric scalar 0/1.');
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
        % SAR 转换辅助函数
        function startConversion(obj, Vin)
            obj.VinHold = Vin;
            obj.WorkingBits = zeros(1, obj.N);
            if obj.trace_en
                obj.CurrentTrace = obj.initTrace();
                obj.CurrentTrace.Vin = Vin;
            end
        end

        function resolveOneBit(obj, i)
            trialBits = obj.WorkingBits;
            trialBits(i) = 1;
            VdacTrial = obj.bitsToVdac(trialBits);
            obj.warnIfVdacOutOfRange(VdacTrial);
            noiseSample = obj.Comp_noise * randn(1, 1);

            inputOffset = obj.Comp_offset + obj.BitOffset(i);
            vinCompare = obj.VinHold + inputOffset + noiseSample;
            Vresidual = VdacTrial - vinCompare;
            if Vresidual < 0
                obj.WorkingBits(i) = 1;
            else
                % Vresidual == 0 时固定清零当前 bit，使阈值边界归属确定。
                obj.WorkingBits(i) = 0;
            end

            if obj.trace_en
                VdacAfterDecision = obj.bitsToVdac(obj.WorkingBits);
                obj.updateBitTrace(i, VdacTrial, noiseSample, Vresidual, VdacAfterDecision);
            end
        end

        function [Dout_dec, Vout, Dout] = completeConversion(obj)
            Dout = obj.WorkingBits;
            Dout_dec = Dout * obj.BitWeights';
            Vout = obj.bitsToVout(Dout);
            if obj.trace_en
                obj.LastTrace = obj.CurrentTrace;
            end
        end

        function Vdac = bitsToVdac(obj, bits)
            %BITSTOVDAC 使用电容权重计算 SAR 内部 trial DAC 电压。
            %   Gain 表示最终 code transfer gain；它通过反向缩放内部 CDAC trial 电压影响输出码字。
            %   Gain > 1 时等效 Vdac 摆幅变小，同一输入更倾向于得到更大码字。
            %   Gain < 1 时等效 Vdac 摆幅变大，同一输入更倾向于得到更小码字。
            %   缩放围绕输入共模 Vcm 展开，避免 0 到 1 V 等输入范围在 Gain 不为 1 时发生共模漂移。
            %   极端 Gain 或电容 mismatch 可能使内部 trial Vdac 超出 [VL, VH]，带检查转换路径会报告该诊断。
            VdacIdeal = obj.VL + sum(bits .* obj.C_act) / obj.C_tot * (obj.VH - obj.VL);
            Vcm = (obj.VH + obj.VL) / 2;
            Vdac = Vcm + (VdacIdeal - Vcm) / obj.Gain;
        end

        function Vout = bitsToVout(obj, bits)
            %BITSTOVOUT 使用输出码字按理想 LSB 恢复 ADC 输出电压。
            %   Gain 已经通过 bitsToVdac 影响 SAR 判决和输出码字，这里不再重复施加 Gain。
            code = bits * obj.BitWeights';
            Vout = obj.VL + code / (2^obj.N) * (obj.VH - obj.VL);
        end
    end

    methods (Access = private)
        % 参数和状态初始化辅助函数
        function initializeParameters(obj, VL, VH, N)
            obj.validateFiniteScalar(VL, 'VL');
            obj.validateFiniteScalar(VH, 'VH');
            if VH <= VL
                error('VH must be greater than VL.');
            end
            if ~isnumeric(N) || ~isscalar(N) || ~isfinite(N) || N ~= fix(N) || N <= 0
                error('N must be a positive integer scalar.');
            end
            if N > 24
                error('N must be <= 24 to avoid excessive memory usage and floating-point resolution limits.');
            end

            obj.Cu = 1;
            obj.sigmaCu = 0;
            obj.Gain = 1;
            obj.Comp_offset = 0;
            obj.Comp_noise = 0;
            obj.trace_en = false;

            obj.VL = VL;
            obj.VH = VH;
            obj.N = N;
            % lsb 用作输入等效 offset/noise 的标定尺度；内部 DAC 电压使用真实电容权重。
            obj.lsb = (VH - VL) / (2^N);
            obj.BitWeights = 2.^((obj.N-1):-1:0);
            obj.BitOffset = zeros(1, N);
        end

        function applyIdealParameters(obj)
            obj.sigmaCu = 0;
            obj.Gain = 1;
            obj.Comp_noise = 0;
            obj.Comp_offset = 0;
            obj.BitOffset = zeros(1, obj.N);
            obj.InputOverdriveWarned = false;
            obj.VdacOutOfRangeWarned = false;
            obj.updateCapArray();
        end

        function initializeState(obj)
            obj.VinHold = 0;
            obj.WorkingBits = zeros(1, obj.N);
            if obj.trace_en
                obj.CurrentTrace = obj.initTrace();
                obj.LastTrace = obj.initTrace();
            else
                obj.CurrentTrace = [];
                obj.LastTrace = [];
            end
        end

        function updateCapArray(obj)
            obj.validatePositiveFiniteScalar(obj.Cu, 'Cu');
            obj.validateNonnegativeFiniteScalar(obj.sigmaCu, 'sigmaCu');

            obj.C_act = obj.BitWeights .* obj.Cu + obj.sigmaCu .* obj.Cu .* sqrt(obj.BitWeights) .* randn(1, obj.N);
            % 额外的 dummy unit capacitor 也参与 mismatch，使总电容更接近真实 binary-weighted CDAC。
            obj.C_dummy = obj.Cu + obj.sigmaCu .* obj.Cu .* randn(1, 1);
            obj.C_tot = sum(obj.C_act) + obj.C_dummy;

            if any(obj.C_act <= 0) || ~all(isfinite(obj.C_act)) || obj.C_dummy <= 0 || ~isfinite(obj.C_dummy)
                error('Generated capacitor array contains non-positive or non-finite values. Reduce sigmaCu or check Cu.');
            end
            if obj.C_tot <= 0 || ~isfinite(obj.C_tot)
                error('Total capacitor value must be positive and finite.');
            end
        end
    end

    methods (Access = private)
        % Trace 辅助函数
        function updateBitTrace(obj, i, VdacTrial, noiseSample, Vresidual, VdacAfterDecision)
            obj.CurrentTrace.VdacTrial(i) = VdacTrial;
            obj.CurrentTrace.NoiseSample(i) = noiseSample;
            obj.CurrentTrace.Vresidual(i) = Vresidual;
            obj.CurrentTrace.bit(i) = obj.WorkingBits(i);
            obj.CurrentTrace.VdacAfterDecision(i) = VdacAfterDecision;
        end

        function invalidateTrace(obj)
            if obj.trace_en
                obj.CurrentTrace = obj.initTrace();
                obj.LastTrace = obj.initTrace();
            else
                obj.CurrentTrace = [];
                obj.LastTrace = [];
            end
        end

        function trace = initTrace(obj)
            trace = struct();
            trace.Vin = NaN;
            trace.bit = zeros(1, obj.N);
            trace.NoiseSample = NaN(1, obj.N);
            trace.VdacTrial = NaN(1, obj.N);
            trace.VdacAfterDecision = NaN(1, obj.N);
            trace.Vresidual = NaN(1, obj.N);
        end
    end

    methods (Access = private)
        % 校验辅助函数
        function validateInputSample(obj, Vin)
            obj.validateFiniteScalar(Vin, 'Vin');
            if (Vin < obj.VL || Vin > obj.VH) && ~obj.InputOverdriveWarned
                warning('sar_adc_core:InputOverdrive', ...
                    'Vin %.6g V is outside ADC input range [%.6g, %.6g] V. The conversion will continue with saturated SAR behavior. Further input-overdrive warnings are suppressed for this ADC object.', ...
                    Vin, obj.VL, obj.VH);
                obj.InputOverdriveWarned = true;
            end
        end

        function warnIfVdacOutOfRange(obj, Vdac)
            if (Vdac < obj.VL || Vdac > obj.VH) && ~obj.VdacOutOfRangeWarned
                warning('sar_adc_core:VdacOutOfRange', ...
                    'Internal Vdac %.6g V is outside reference range [%.6g, %.6g] V, usually caused by extreme Gain or capacitor mismatch. Further Vdac warnings are suppressed for this ADC object.', ...
                    Vdac, obj.VL, obj.VH);
                obj.VdacOutOfRangeWarned = true;
            end
        end

        function validateFiniteScalar(~, value, name)
            if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value)
                error('%s must be a finite numeric scalar.', name);
            end
        end

        function validatePositiveFiniteScalar(obj, value, name)
            obj.validateFiniteScalar(value, name);
            if value <= 0
                error('%s must be positive.', name);
            end
        end

        function validateNonnegativeFiniteScalar(obj, value, name)
            obj.validateFiniteScalar(value, name);
            if value < 0
                error('%s must be nonnegative.', name);
            end
        end
    end

end
