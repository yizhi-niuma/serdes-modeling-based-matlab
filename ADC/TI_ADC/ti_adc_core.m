classdef ti_adc_core < handle
    %TI_ADC_CORE 多路时间交织型 SAR ADC 顶层行为模型。
    %
    %   行为说明：
    %   - 输入 Vin 已经由前级采样器完成离散采样。
    %   - 顶层每次推进一个 block，M 路 lane 各完成一次转换。
    %   - 每一路 lane 内部复用 sar_adc_core 完成 SAR 转换。
    %   - 第一版仅保存 LaneSkew，不在模型内部根据 timing skew 重新采样或插值。
    %   - 每一路等效 gain 和等效 offset 直接下发到对应的 sar_adc_core。
    %
    %   API 使用说明：
    %   - convertOneBlock 每次输入 M 个已经采样好的码元。
    %   - 每一路 lane 在一个 block 内调用一次 sar_adc_core.convertInstant。

    properties (SetAccess = private)
        % ADC 基本参数
        M
        VL
        VH
        N
        lsb

        % 每一路 SAR ADC core
        LaneAdc

        % TI lane 固定等效非理想参数
        LaneEquivalentGain
        LaneEquivalentOffset
        LaneSkew
        LaneComp_noise
        LaneCapMismatch
        LaneBitOffsetSigmaLSB

        % 最近一次转换 trace
        trace_en = false
        LastTrace
    end

    methods
        function obj = ti_adc_core(M, VL, VH, N)
            if nargin < 4
                N = 7;
            end
            if nargin < 3
                VH = 1;
            end
            if nargin < 2
                VL = -1;
            end
            if nargin < 1
                M = 4;
            end

            obj.initializeParameters(M, VL, VH, N);
            obj.applyIdealParameters();
            obj.initializeState();
        end

        function [Dout_dec, Vout, laneIndex, Dout, varargout] = convertOneBlock(obj, Vin)
            %CONVERTONEBLOCK 推进一个 TI ADC block，M 路 lane 各完成一次转换。
            %   Vin 必须包含 M 个已经采样好的输入码元。
            %   第 3 个输出 laneIndex 表示 block 内每个样本对应的 TI lane 编号。
            %   可选第 4 个输出 Dout 为逐 bit 结果；可选第 5 个输出返回顶层 trace。
            %   每一路 lane 调用一次对应 sar_adc_core.convertInstant，不在 TI 顶层重复 SAR 转换逻辑。
            if nargout > 5
                error('convertOneBlock supports at most 5 outputs: Dout_dec, Vout, laneIndex, Dout, trace.');
            end
            obj.validateInputVector(Vin);
            if numel(Vin) ~= obj.M
                error('Vin must contain exactly M samples for one TI ADC block.');
            end

            inputSize = size(Vin);
            Vin = reshape(Vin, 1, []);

            Dout_dec_vector = zeros(1, obj.M);
            Vout_vector = zeros(1, obj.M);
            laneIndex_vector = 1:obj.M;
            needDout_local = nargout > 3;
            needTraceOutput_local = nargout > 4;

            if needDout_local
                Dout_vector = zeros(obj.M, obj.N);
            end
            if obj.trace_en
                trace = obj.initTrace();
            end

            for currentLane = 1:obj.M
                if needDout_local
                    [Dout_dec_vector(currentLane), Vout_vector(currentLane), doutLane] = ...
                        obj.LaneAdc{currentLane}.convertInstant(Vin(currentLane));
                    Dout_vector(currentLane, :) = reshape(doutLane, 1, obj.N);
                else
                    [Dout_dec_vector(currentLane), Vout_vector(currentLane)] = ...
                        obj.LaneAdc{currentLane}.convertInstant(Vin(currentLane));
                end

                if obj.trace_en
                    trace.LaneTrace{currentLane} = obj.LaneAdc{currentLane}.getLastTrace();
                end
            end

            Dout_dec = reshape(Dout_dec_vector, inputSize);
            Vout = reshape(Vout_vector, inputSize);
            laneIndex = reshape(laneIndex_vector, inputSize);
            if needDout_local
                Dout = reshape(Dout_vector, [inputSize, obj.N]);
            else
                Dout = [];
            end

            if obj.trace_en
                trace.Vin = reshape(Vin, inputSize);
                trace.LaneIndex = laneIndex;
                trace.Dout_dec = Dout_dec;
                trace.Vout = Vout;
                obj.LastTrace = trace;
            else
                obj.LastTrace = [];
            end

            if needTraceOutput_local
                varargout{1} = obj.LastTrace;
            end
        end

        function Dout_dec = convertOneBlockFast(obj, Vin)
            %CONVERTONEBLOCKFAST 面向快速仿真的 TI ADC block code-only 转换。
            %   该路径假设 Vin 为 1×M 行向量，跳过输入校验、trace 记录和 shape 兼容处理。
            %   每一路 lane 调用一次对应 sar_adc_core.convertInstantFast。
            M_local = obj.M;
            LaneAdc_local = obj.LaneAdc;
            Dout_dec = zeros(1, M_local);

            for currentLane = 1:M_local
                Dout_dec(currentLane) = LaneAdc_local{currentLane}.convertInstantFast(Vin(currentLane));
            end
        end

        function resetToIdeal(obj)
            %RESETTOIDEAL 恢复全部 lane 参数和每一路 SAR core 非理想参数。
            obj.applyIdealParameters();
            obj.initializeState();
        end

        function resetState(obj)
            %RESETSTATE 清除转换状态和 trace 缓存，不改变非理想参数。
            for laneIndex = 1:obj.M
                obj.LaneAdc{laneIndex}.resetState();
            end
            obj.initializeState();
        end

        function setLaneEquivalentGain(obj, laneGainValue)
            %SETLANEEQUIVALENTGAIN 配置每一路 TI lane 的总等效 gain。
            %   第一版不在 TI 顶层缩放 Vin，而是直接复用 sar_adc_core.setGain。
            laneGainValue = obj.expandLaneVector(laneGainValue, 'LaneEquivalentGain');
            if any(laneGainValue <= 0)
                error('LaneEquivalentGain must be positive.');
            end
            obj.LaneEquivalentGain = laneGainValue;
            for laneIndex = 1:obj.M
                obj.LaneAdc{laneIndex}.setGain(laneGainValue(laneIndex));
            end
            obj.invalidateTrace();
        end

        function setLaneEquivalentOffset(obj, laneOffsetValue)
            %SETLANEEQUIVALENTOFFSET 配置每一路 TI lane 的总等效输入 offset。
            %   该 offset 包括 frontend offset、采样路径 offset 和 comparator offset 等总等效项。
            %   第一版直接映射到 sar_adc_core 的 comparator offset，单位与 sar_adc_core.Comp_offset 一致。
            obj.LaneEquivalentOffset = obj.expandLaneVector(laneOffsetValue, 'LaneEquivalentOffset');
            obj.applyLaneComparatorParameters();
            obj.invalidateTrace();
        end

        function setLaneSkew(obj, laneSkewValue)
            %SETLANESKEW 配置固定 lane timing skew。
            %   第一版仅保存该参数，不在 convertOneBlock 内执行重新采样或插值。
            obj.LaneSkew = obj.expandLaneVector(laneSkewValue, 'LaneSkew');
            obj.invalidateTrace();
        end

        function setLaneCapMismatch(obj, sigmaCuValue)
            %SETLANECAPMISMATCH 配置每一路 SAR core 的 CDAC 单位电容失配系数。
            sigmaCuValue = obj.expandLaneVector(sigmaCuValue, 'LaneCapMismatch');
            if any(sigmaCuValue < 0)
                error('LaneCapMismatch must be nonnegative.');
            end
            obj.LaneCapMismatch = sigmaCuValue;
            for laneIndex = 1:obj.M
                obj.LaneAdc{laneIndex}.setCapMismatch(sigmaCuValue(laneIndex));
            end
            obj.invalidateTrace();
        end

        function setLaneComparatorNoise(obj, compNoiseValue)
            %SETLANECOMPARATORNOISE 配置每一路 SAR core 的 comparator noise。
            %   comparator offset 由 setLaneEquivalentOffset 配置，并与 noise 一起下发到 sar_adc_core。
            compNoiseValue = obj.expandLaneVector(compNoiseValue, 'LaneComp_noise');
            if any(compNoiseValue < 0)
                error('LaneComp_noise must be nonnegative.');
            end
            obj.LaneComp_noise = compNoiseValue;
            obj.applyLaneComparatorParameters();
            obj.invalidateTrace();
        end

        function setLaneBitOffsetSigmaLSB(obj, bitOffsetSigmaLSB)
            %SETLANEBITOFFSETSIGMALSB 按 LSB 为单位配置每一路 SAR core 的 per-bit offset sigma。
            bitOffsetSigmaLSB = obj.expandLaneVector(bitOffsetSigmaLSB, 'LaneBitOffsetSigmaLSB');
            if any(bitOffsetSigmaLSB < 0)
                error('LaneBitOffsetSigmaLSB must be nonnegative.');
            end
            obj.LaneBitOffsetSigmaLSB = bitOffsetSigmaLSB;
            for laneIndex = 1:obj.M
                obj.LaneAdc{laneIndex}.setBitOffsetSigmaLSB(bitOffsetSigmaLSB(laneIndex));
            end
            obj.invalidateTrace();
        end

        function setTraceMode(obj, trace_en)
            %SETTRACEMODE 使能或关闭 TI 顶层和每一路 SAR core trace。
            if nargin < 2
                trace_en = true;
            end
            if ~(islogical(trace_en) && isscalar(trace_en)) && ...
                    ~(isnumeric(trace_en) && isscalar(trace_en) && isfinite(trace_en) && (trace_en == 0 || trace_en == 1))
                error('trace_en must be a logical scalar or numeric scalar 0/1.');
            end
            obj.trace_en = logical(trace_en);
            for laneIndex = 1:obj.M
                obj.LaneAdc{laneIndex}.setTraceMode(obj.trace_en);
            end
            obj.invalidateTrace();
        end

        function trace = getLastTrace(obj)
            %GETLASTTRACE 返回最近一次 block 转换 trace；trace_en=false 时 LastTrace 为空。
            trace = obj.LastTrace;
        end
    end

    methods (Access = private)
        % 参数和状态初始化辅助函数
        function initializeParameters(obj, M, VL, VH, N)
            obj.validatePositiveIntegerScalar(M, 'M');
            obj.validateFiniteScalar(VL, 'VL');
            obj.validateFiniteScalar(VH, 'VH');
            if VH <= VL
                error('VH must be greater than VL.');
            end
            obj.validatePositiveIntegerScalar(N, 'N');
            if N > 24
                error('N must be <= 24 to avoid excessive memory usage and floating-point resolution limits.');
            end

            obj.M = M;
            obj.VL = VL;
            obj.VH = VH;
            obj.N = N;
            obj.lsb = (VH - VL) / (2^N);

            obj.LaneAdc = cell(1, obj.M);
            for laneIndex = 1:obj.M
                obj.LaneAdc{laneIndex} = sar_adc_core(VL, VH, N);
            end
        end

        function applyIdealParameters(obj)
            obj.LaneEquivalentGain = ones(1, obj.M);
            obj.LaneEquivalentOffset = zeros(1, obj.M);
            obj.LaneSkew = zeros(1, obj.M);
            obj.LaneComp_noise = zeros(1, obj.M);
            obj.LaneCapMismatch = zeros(1, obj.M);
            obj.LaneBitOffsetSigmaLSB = zeros(1, obj.M);
            for laneIndex = 1:obj.M
                obj.LaneAdc{laneIndex}.resetToIdeal();
                obj.LaneAdc{laneIndex}.setTraceMode(obj.trace_en);
            end
        end

        function initializeState(obj)
            if obj.trace_en
                obj.LastTrace = obj.initTrace();
            else
                obj.LastTrace = [];
            end
        end

        function invalidateTrace(obj)
            if obj.trace_en
                obj.LastTrace = obj.initTrace();
            else
                obj.LastTrace = [];
            end
        end

        function trace = initTrace(obj)
            trace = struct();
            trace.Vin = [];
            trace.LaneIndex = [];
            trace.Dout_dec = [];
            trace.Vout = [];
            trace.LaneEquivalentGain = obj.LaneEquivalentGain;
            trace.LaneEquivalentOffset = obj.LaneEquivalentOffset;
            trace.LaneSkew = obj.LaneSkew;
            trace.LaneComp_noise = obj.LaneComp_noise;
            trace.LaneCapMismatch = obj.LaneCapMismatch;
            trace.LaneBitOffsetSigmaLSB = obj.LaneBitOffsetSigmaLSB;
            trace.LaneTrace = cell(1, obj.M);
        end
    end

    methods (Access = private)
        % 转换辅助函数
        function applyLaneComparatorParameters(obj)
            for laneIndex = 1:obj.M
                obj.LaneAdc{laneIndex}.setComparator(obj.LaneEquivalentOffset(laneIndex), obj.LaneComp_noise(laneIndex));
            end
        end
    end

    methods (Access = private)
        % 校验辅助函数
        function validateInputVector(obj, Vin)
            if ~isnumeric(Vin) || isempty(Vin) || any(~isfinite(Vin(:)))
                error('Vin must be a non-empty finite numeric array.');
            end
            if any(Vin(:) < obj.VL) || any(Vin(:) > obj.VH)
                warning('ti_adc_core:InputOverdrive', ...
                    'Some Vin samples are outside ADC input range [%.6g, %.6g] V. The conversion will continue with saturated SAR behavior.', ...
                    obj.VL, obj.VH);
            end
        end

        function value = expandLaneVector(obj, value, name)
            if ~isnumeric(value) || isempty(value) || any(~isfinite(value(:)))
                error('%s must be a finite numeric scalar or vector.', name);
            end
            if isscalar(value)
                value = repmat(value, 1, obj.M);
            elseif isvector(value) && numel(value) == obj.M
                value = reshape(value, 1, obj.M);
            else
                error('%s must be a scalar or a vector with M elements.', name);
            end
        end

        function validateFiniteScalar(~, value, name)
            if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value)
                error('%s must be a finite numeric scalar.', name);
            end
        end

        function validatePositiveIntegerScalar(~, value, name)
            if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value) || value ~= fix(value) || value <= 0
                error('%s must be a positive integer scalar.', name);
            end
        end

    end
end
