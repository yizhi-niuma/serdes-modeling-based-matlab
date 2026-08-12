classdef ti_adc_top < handle
    %TI_ADC_TOP 集成 CDR 采样索引、ADC clock 和 TI ADC core 的顶层模型。
    %
    %   模型分工：
    %   - ti_adc_top 负责 local waveform block 接口和 CDR phase 入口。
    %   - ti_adc_clock 将 CDR phase、TAH 固定 skew 和随机 jitter 转换为整数 sample index。
    %   - ti_adc_core 将一个已经采样好的 M-lane 电压 block 转换为 ADC 输出码。
    %
    %   local block 输入约定：
    %   - VinWaveform 不是完整输入波形，而是一个 nominal ADC block 加左右等长 margin。
    %   - 期望长度为 (M - 1) * Oversample + 1 + 2 * InputMargin。
    %   - cdrPhaseIndex 先按 local nominal block 内的相位解释，再整体平移 InputMargin。
    %   - InputMargin 必须覆盖固定 skew 和随机 jitter 可能造成的 sample index 移动。
    %
    %   fast path 约定：
    %   - convertOneBlockFast 面向长序列端到端仿真，跳过公开入口的校验和 trace 组装。
    %   - 采样路径直接生成 actualIndex 并索引 VinWaveform，不再调用 full path 的 sampleInput 校验。
    properties (SetAccess = private)
        M                 % 时间交织 ADC lane 总数。
        VL                % ADC 量化输入下限电压。
        VH                % ADC 量化输入上限电压。
        N                 % ADC 输出位宽。
        lsb               % 由 VL、VH 和 N 推导得到的理想 LSB 电压步进。
        SarPerTah         % 每个 TAH phase 后连接的 SAR ADC lane 数量。
        NumTah            % TAH phase 数量，等于 M / SarPerTah。
        Oversample        % 相邻 ADC 采样时刻之间的输入波形 sample index 间隔。
        ClockCore         % ti_adc_clock 对象，用于生成采样索引和 TAH edge timing。
        AdcCore           % ti_adc_core 对象，用于将采样电压转换为 ADC 输出码。
        trace_en = false  % full conversion path 的 trace 使能标志。
        LastTrace         % 最近一次 convertOneBlock 保存的 trace 结构体。
        InputMargin = 0   % local waveform 左右等长 margin，单位为输入波形 sample index。
    end

    methods
        function obj = ti_adc_top(M, VL, VH, N, SarPerTah, Oversample)
            %TI_ADC_TOP 构造 TI ADC 顶层模型并初始化 clock/core 子模块。
            %   默认模型为 64-lane、7-bit、输入范围 [-1, 1] 的 TI ADC。
            %   SarPerTah 默认值为 8，表示 lane 1:8 共享 TAH phase 1，
            %   lane 9:16 共享 TAH phase 2，以此类推。
            %   构造完成后，clock 和 ADC core 均处于 ideal 参数状态。
            if nargin < 6
                Oversample = 1;
            end
            if nargin < 5
                SarPerTah = 8;
            end
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
                M = 64;
            end
            obj.initializeParameters(M, VL, VH, N, SarPerTah, Oversample);
            obj.applyIdealParameters();
            obj.initializeState();
        end

        function [Dout_dec, Vout, laneIndex, Dout, varargout] = convertOneBlock(obj, VinWaveform, cdrPhaseIndex)
            %CONVERTONEBLOCK 对一个 local waveform block 执行完整顶层转换。
            %   VinWaveform 必须是一个 nominal ADC block 加左右等长 InputMargin。
            %   本方法根据 cdrPhaseIndex 生成整数 sample index，采样得到 M 个 lane 电压，
            %   然后调用 ti_adc_core.convertOneBlock 得到 ADC 输出。
            %   当 trace_en 为 true 时，可选第 5 个输出返回顶层 trace。
            if nargout > 5
                error('convertOneBlock supports at most 5 outputs: Dout_dec, Vout, laneIndex, Dout, trace.');
            end
            if nargin < 3
                cdrPhaseIndex = 1;
            end
            obj.validateWaveform(VinWaveform, 'VinWaveform');
            obj.validateFiniteScalar(cdrPhaseIndex, 'cdrPhaseIndex');
            VinBlock = obj.generateSampleIndexAndSample(VinWaveform, cdrPhaseIndex);
            if obj.trace_en
                [Dout_dec, Vout, laneIndex, Dout, coreTrace] = obj.AdcCore.convertOneBlock(VinBlock);
            else
                [Dout_dec, Vout, laneIndex, Dout] = obj.AdcCore.convertOneBlock(VinBlock);
                coreTrace = [];
            end
            if obj.trace_en
                trace = obj.initTrace();
                trace.CdrPhaseIndex = cdrPhaseIndex;
                trace.VinBlock = VinBlock;
                trace.CoreTrace = coreTrace;
                trace.Dout_dec = Dout_dec;
                trace.Vout = Vout;
                trace.LaneIndex = laneIndex;
                trace.Dout = Dout;
                obj.LastTrace = trace;
            else
                obj.LastTrace = [];
            end
            if nargout > 4
                varargout{1} = obj.LastTrace;
            end
        end

        function Dout_dec = convertOneBlockFast(obj, VinWaveform, cdrPhaseIndex)
            %CONVERTONEBLOCKFAST 面向长序列仿真的 code-only 转换路径。
            %   该路径跳过公开入口校验、local block 长度检查、sampleInput 校验和 trace 组装。
            %   调用者需要保证 VinWaveform 是合法 local block，且 jitter/skew 后的 actualIndex 不越界。
            %   Dout_dec 为所有 lane 的十进制 ADC 输出码向量。
            if nargin < 3
                cdrPhaseIndex = 1;
            end
            VinBlock = obj.generateSampleIndexAndSampleFast(VinWaveform, cdrPhaseIndex);
            Dout_dec = obj.AdcCore.convertOneBlockFast(VinBlock);
        end

        function [actualIndex, actualRisingEdgeIndex] = generateSampleIndex(obj, cdrPhaseIndex)
            %GENERATESAMPLEINDEX 生成 lane 采样索引和 TAH 上升沿 timing。
            %   actualIndex 为 1-by-M 向量，用于对 VinWaveform 中每一个 ADC lane 取样。
            %   actualRisingEdgeIndex 为 1-by-NumTah 向量，仅用于观察 TAH edge timing。
            %   该公开 wrapper 不会自动叠加 InputMargin。
            if nargin < 2
                cdrPhaseIndex = 1;
            end
            obj.validateFiniteScalar(cdrPhaseIndex, 'cdrPhaseIndex');
            if nargout > 1
                [actualIndex, actualRisingEdgeIndex] = obj.ClockCore.generateSampleIndex(cdrPhaseIndex);
            else
                actualIndex = obj.ClockCore.generateSampleIndex(cdrPhaseIndex);
            end
        end

        function VinBlock = sampleInput(obj, VinWaveform, actualIndex)
            %SAMPLEINPUT 使用整数 sample index 从 local waveform 中采样 M 个 lane 电压。
            %   VinWaveform 会被整理为行向量，actualIndex 也会被整理为行向量。
            %   本模型有意不使用 fractional-index sampling 或输入信号插值。
            %   如果任一 index 超出 local waveform 范围，需要增大左右等长 InputMargin。
            obj.validateWaveform(VinWaveform, 'VinWaveform');
            if ~isnumeric(actualIndex) || isempty(actualIndex) || any(~isfinite(actualIndex(:)))
                error('actualIndex must be a non-empty finite numeric array.');
            end
            waveformVector = reshape(VinWaveform, 1, []);
            sampleIndex = reshape(actualIndex, 1, []);
            if any(sampleIndex ~= round(sampleIndex))
                error('actualIndex must contain integer sample indices.');
            end
            if any(sampleIndex < 1) || any(sampleIndex > numel(waveformVector))
                error('actualIndex exceeds VinWaveform range. Increase the equal input margin on both sides of the local block.');
            end
            VinBlock = waveformVector(sampleIndex);
        end

        function resetToIdeal(obj)
            %RESETTOIDEAL 重新创建 ideal clock/core 对象并清空顶层状态。
            %   已配置的 skew、jitter、lane gain/offset、电容 mismatch 和 noise 设置都会被丢弃。
            %   当需要用相同顶层维度重新开启 ideal baseline 仿真时调用该方法。
            obj.applyIdealParameters();
            obj.initializeState();
        end

        function resetState(obj)
            %RESETSTATE 清除运行时状态，但保留已经配置的非理想参数。
            %   顶层 trace 会被清空；如果子模块提供 resetState，也会同步清除其运行状态。
            %   固定 skew、jitter sigma 和 ADC mismatch 等参数保持不变。
            obj.initializeState();
            if ~isempty(obj.AdcCore) && ismethod(obj.AdcCore, 'resetState')
                obj.AdcCore.resetState();
            end
            if ~isempty(obj.ClockCore) && ismethod(obj.ClockCore, 'resetState')
                obj.ClockCore.resetState();
            end
        end

        function setTraceMode(obj, trace_en)
            %SETTRACEMODE 使能或关闭 full conversion path 的 trace 记录。
            %   trace_en 可以是 logical scalar，也可以是 numeric 0/1 scalar。
            %   使能后，convertOneBlock 会记录 VinBlock、coreTrace 和 ADC 输出。
            %   fast path 保持 code-only，不组装 trace 数据。
            if nargin < 2
                trace_en = true;
            end
            if ~(islogical(trace_en) && isscalar(trace_en)) && ~(isnumeric(trace_en) && isscalar(trace_en) && isfinite(trace_en) && (trace_en == 0 || trace_en == 1))
                error('trace_en must be a logical scalar.');
            end
            obj.trace_en = logical(trace_en);
            if ~isempty(obj.AdcCore) && ismethod(obj.AdcCore, 'setTraceMode')
                obj.AdcCore.setTraceMode(obj.trace_en);
            end
            obj.invalidateTrace();
        end

        function trace = getLastTrace(obj)
            %GETLASTTRACE 返回最近一次 full conversion 保存的 trace。
            %   如果 trace 关闭，或最近一次转换使用 fast path，则返回空。
            trace = obj.LastTrace;
        end

        function setInputMargin(obj, inputMargin)
            %SETINPUTMARGIN 设置 local VinWaveform block 的左右等长 margin。
            %   inputMargin 单位是输入波形 sample index，不是 UI。
            %   它必须覆盖固定 skew 和随机 jitter 造成的 actualIndex 最大预期移动。
            %   修改该值也会改变每个 local VinWaveform block 的期望长度。
            obj.validateNonnegativeIntegerScalar(inputMargin, 'inputMargin');
            obj.InputMargin = inputMargin;
            obj.invalidateTrace();
        end

        function inputMargin = getInputMargin(obj)
            %GETINPUTMARGIN 返回当前单侧 local waveform margin。
            inputMargin = obj.InputMargin;
        end

        function setRisingEdgeSkewMode(obj, skewMode)
            %SETRISINGEDGESKEWMODE 设置 TAH 上升沿 skew 配置模式。
            %   可接受的 mode 取值及其含义由 ti_adc_clock.setSkewMode 定义。
            obj.ClockCore.setSkewMode(skewMode);
            obj.invalidateTrace();
        end

        function setCommonRisingEdgeSkewUI(obj, skewUI)
            %SETCOMMONRISINGEDGESKEWUI 设置所有 TAH phase 共用的上升沿 skew。
            %   skewUI 单位是 UI，会在 clock core 内转换为输入波形 sample index 偏移。
            obj.ClockCore.setCommonRisingEdgeSkewUI(skewUI);
            obj.invalidateTrace();
        end

        function setRisingEdgeSkewUI(obj, skewUI)
            %SETRISINGEDGESKEWUI 设置每个 TAH phase 的固定上升沿 skew。
            %   skewUI 通常为 1-by-NumTah 向量，用于建模不同 TAH clock phase 之间的固定偏移。
            obj.ClockCore.setRisingEdgeSkewUI(skewUI);
            obj.invalidateTrace();
        end

        function setRisingEdgeJitterSigmaUI(obj, jitterSigmaUI)
            %SETRISINGEDGEJITTERSIGMAUI 设置每个 TAH phase 的随机 jitter RMS。
            %   jitterSigmaUI 单位是 UI。clock core 在每次生成 block 时重新抽取随机 jitter。
            %   最终 sample index 在 ti_adc_clock 内取整，因此 jitter 只会移动整数 index。
            obj.ClockCore.setRisingEdgeJitterSigmaUI(jitterSigmaUI);
            obj.invalidateTrace();
        end

        function setTahFixedSkewUI(obj, fixedSkewUI)
            %SETTAHFIXEDSKEWUI TAH 固定 skew 配置的兼容 wrapper。
            %   该方法等价于 setRisingEdgeSkewUI。
            obj.setRisingEdgeSkewUI(fixedSkewUI);
        end

        function setTahJitterSigmaUI(obj, jitterSigmaUI)
            %SETTAHJITTERSIGMAUI TAH 随机 jitter 配置的兼容 wrapper。
            %   该方法等价于 setRisingEdgeJitterSigmaUI。
            obj.setRisingEdgeJitterSigmaUI(jitterSigmaUI);
        end

        function setLaneEquivalentGain(obj, laneGainValue)
            %SETLANEEQUIVALENTGAIN 设置 ADC lane 的等效 gain mismatch。
            %   参数直接传递给 ti_adc_core，用于 lane-level 非理想转换。
            obj.AdcCore.setLaneEquivalentGain(laneGainValue);
            obj.invalidateTrace();
        end

        function setLaneEquivalentOffset(obj, laneOffsetValue)
            %SETLANEEQUIVALENTOFFSET 设置 ADC lane 的等效 offset mismatch。
            %   参数直接传递给 ti_adc_core，用于建模 lane 间 offset 差异。
            obj.AdcCore.setLaneEquivalentOffset(laneOffsetValue);
            obj.invalidateTrace();
        end

        function setLaneCapMismatch(obj, sigmaCuValue)
            %SETLANECAPMISMATCH 设置 ADC lane 的电容 mismatch 强度。
            %   参数含义继承自 ti_adc_core.setLaneCapMismatch。
            obj.AdcCore.setLaneCapMismatch(sigmaCuValue);
            obj.invalidateTrace();
        end

        function setLaneComparatorNoise(obj, compNoiseValue)
            %SETLANECOMPARATORNOISE 设置 ADC lane 的 comparator noise。
            %   参数含义继承自 ti_adc_core.setLaneComparatorNoise。
            obj.AdcCore.setLaneComparatorNoise(compNoiseValue);
            obj.invalidateTrace();
        end

        function setLaneBitOffsetSigmaLSB(obj, bitOffsetSigmaLSB)
            %SETLANEBITOFFSETSIGMALSB 设置 ADC lane 的 bit-offset sigma。
            %   单位是 LSB，详细 bit-level offset 模型由 ti_adc_core 管理。
            obj.AdcCore.setLaneBitOffsetSigmaLSB(bitOffsetSigmaLSB);
            obj.invalidateTrace();
        end

    end

    methods (Access = private)
        function initializeParameters(obj, M, VL, VH, N, SarPerTah, Oversample)
            %INITIALIZEPARAMETERS 校验并保存顶层静态配置。
            %   该 helper 只处理维度、ADC 范围、位宽、TAH/SAR 结构和 index 间隔。
            %   子对象在 applyIdealParameters 中创建，便于 resetToIdeal 复用同一流程。
            obj.validatePositiveIntegerScalar(M, 'M');
            obj.validatePositiveIntegerScalar(N, 'N');
            obj.validatePositiveIntegerScalar(SarPerTah, 'SarPerTah');
            obj.validatePositiveIntegerScalar(Oversample, 'Oversample');
            obj.validateFiniteScalar(VL, 'VL');
            obj.validateFiniteScalar(VH, 'VH');
            if VH <= VL
                error('VH must be greater than VL.');
            end
            if mod(M, SarPerTah) ~= 0
                error('M must be an integer multiple of SarPerTah.');
            end
            obj.M = M;
            obj.VL = VL;
            obj.VH = VH;
            obj.N = N;
            obj.lsb = (VH - VL) / (2^N - 1);
            obj.SarPerTah = SarPerTah;
            obj.NumTah = M / SarPerTah;
            obj.Oversample = Oversample;
        end

        function applyIdealParameters(obj)
            %APPLYIDEALPARAMETERS 创建 ideal clock core 和 ADC core 对象。
            %   重新创建 ti_adc_clock 会清除已有 skew 和 jitter 设置。
            %   重新创建 ti_adc_core 会清除已有 lane mismatch 和 noise 设置。
            obj.ClockCore = ti_adc_clock(obj.M, obj.SarPerTah, obj.Oversample);
            obj.AdcCore = ti_adc_core(obj.M, obj.VL, obj.VH, obj.N);
        end

        function initializeState(obj)
            %INITIALIZESTATE 清空顶层运行时缓存。
            obj.LastTrace = [];
        end

        function VinBlock = generateSampleIndexAndSample(obj, VinWaveform, cdrPhaseIndex)
            %GENERATESAMPLEINDEXANDSAMPLE 将 local CDR phase 转换为采样后的 lane 电压。
            %   cdrPhaseIndex 先通过 getLocalCdrPhaseIndex 平移 InputMargin。
            %   clock core 随后生成整数 actualIndex，sampleInput 再抽取 VinBlock。
            %   full path 和 fast path 都使用该 helper，以保证采样行为一致。
            localCdrPhaseIndex = obj.getLocalCdrPhaseIndex(VinWaveform, cdrPhaseIndex);
            actualIndex = obj.ClockCore.generateSampleIndex(localCdrPhaseIndex);
            VinBlock = obj.sampleInput(VinWaveform, actualIndex);
        end

        function VinBlock = generateSampleIndexAndSampleFast(obj, VinWaveform, cdrPhaseIndex)
            %GENERATESAMPLEINDEXANDSAMPLEFAST 快速路径中直接生成采样索引并读取 local waveform。
            %   该 helper 有意跳过 local block 长度检查和 sampleInput 的完整校验。
            %   调用者需要保证 VinWaveform 覆盖所有可能的 actualIndex。
            localCdrPhaseIndex = cdrPhaseIndex + obj.InputMargin;
            actualIndex = obj.ClockCore.generateSampleIndex(localCdrPhaseIndex);
            VinBlock = VinWaveform(actualIndex);
        end

        function localCdrPhaseIndex = getLocalCdrPhaseIndex(obj, VinWaveform, cdrPhaseIndex)
            %GETLOCALCDRPHASEINDEX 检查 local waveform 长度并应用 InputMargin 平移。
            %   nominalBlockLength 覆盖 lane 1 到 lane M 的理想采样跨度。
            %   expectedWaveformLength 在 nominal block 左右各增加一个 InputMargin。
            %   该 helper 只检查 local block 结构，最终 actualIndex 越界检查稍后由 sampleInput 完成。
            waveformLength = numel(VinWaveform);
            nominalBlockLength = (obj.M - 1) * obj.Oversample + 1;
            expectedWaveformLength = nominalBlockLength + 2 * obj.InputMargin;
            if waveformLength ~= expectedWaveformLength
                error('VinWaveform length must be one nominal ADC block plus 2 * InputMargin samples.');
            end
            localCdrPhaseIndex = cdrPhaseIndex + obj.InputMargin;
        end

        function trace = initTrace(obj)
            %INITTRACE 创建基础顶层 trace 结构体。
            %   该结构体保存解释本次转换所需的顶层参数。
            %   更详细的 ADC-core 内部信息单独保存在 CoreTrace 中。
            trace = struct();
            trace.M = obj.M;
            trace.SarPerTah = obj.SarPerTah;
            trace.NumTah = obj.NumTah;
            trace.Oversample = obj.Oversample;
            trace.InputMargin = obj.InputMargin;
        end

        function invalidateTrace(obj)
            %INVALIDATETRACE 清空 LastTrace，避免参数变化后留下过期 trace。
            obj.LastTrace = [];
        end

        function validateWaveform(~, value, name)
            %VALIDATEWAVEFORM 检查 waveform 是否为非空有限数值数组。
            if ~isnumeric(value) || isempty(value) || any(~isfinite(value(:)))
                error('%s must be a non-empty finite numeric waveform.', name);
            end
        end

        function validateFiniteScalar(~, value, name)
            %VALIDATEFINITESCALAR 检查输入是否为有限数值标量。
            if ~(isnumeric(value) && isscalar(value) && isfinite(value))
                error('%s must be a finite numeric scalar.', name);
            end
        end

        function validatePositiveIntegerScalar(obj, value, name)
            %VALIDATEPOSITIVEINTEGERSCALAR 检查输入是否为正整数标量。
            obj.validateFiniteScalar(value, name);
            if value < 1 || value ~= round(value)
                error('%s must be a positive integer scalar.', name);
            end
        end

        function validateNonnegativeIntegerScalar(obj, value, name)
            %VALIDATENONNEGATIVEINTEGERSCALAR 检查输入是否为非负整数标量。
            obj.validateFiniteScalar(value, name);
            if value < 0 || value ~= round(value)
                error('%s must be a nonnegative integer scalar.', name);
            end
        end

    end
end
