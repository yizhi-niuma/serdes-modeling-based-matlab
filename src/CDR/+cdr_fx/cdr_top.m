classdef cdr_top < handle
%CDR_TOP 块级码域 CDR 内核（定点版组合根）。
%
%   与浮点参考 src/CDR/cdr_top.m 的块级流水、字段契约、两级 mu 门控调度顺序
%   完全一致，只把 8 个子块换成 +cdr_fx 里的定点实现，并在 slicer 与 SNR FOM
%   处施加量化。公开面保持同形状，便于与浮点版逐块对拍。
%
%   三处与浮点版的刻意差异（均在 docs/CDR_FIXED_POINT.md 有据）：
%
%   1. voter 不再做除法，输出整数求和；配置层把 Kp/Ki 预先除以 BlockSize。
%      本类在 buildLoopFilter 里完成这次换算，调用方仍传原始增益。
%   2. slicer 用 dLev 的**窄值**（DLevInnerSlice 等），保证 dlev_loop 内部的
%      精确相等归属判断成立。见 §5.1。
%   3. SNR 门控改喂两路功率而非 dB，对数留在测试台不进硅。见 §6。

    properties (SetAccess = private)
        Config              struct
        Pd
        Voter
        LoopFilter
        PhaseInterpolator
        Ffe
        FfeLoop
        Dlev
        Monitor

        Detector            char
        TransitionFilter    double

        PendingCentered     double
        PendingPast         double
        PendingHasPast      logical
        PendingCodeWrapped  double
        PendingUiSlip       double
        PendingBlockIndex   double
        HavePending         logical
        SampleBlockCount    double
        BlockIndex          double

        PreviousDataSymbol  double
        PreviousErrorBit    double
        CurrentLocalIndexFloat double
        GatedCoefficients   double

        FmtFfeOut           struct
        FmtSlice            struct
        FmtSliceErr         struct
    end

    methods
        function obj = cdr_top(cfg)
            %CDR_TOP 由一个完整配置结构体构造。字段名与浮点版 defaultConfig 一致。
            if nargin < 1 || isempty(cfg)
                cfg = cdr_fx.cdr_top.defaultConfig();
            end
            obj.Config = cfg;
            obj.Detector = cfg.Detector;
            obj.TransitionFilter = double(cfg.TransitionFilter);

            obj.FmtFfeOut = cdr_fx.fxfmt.ffeOutput();
            obj.FmtSlice = cdr_fx.fxfmt.dlevSlice();
            obj.FmtSliceErr = cdr_fx.fxfmt.sliceError();

            % PD 复用浮点实现：它的输入输出本来就是 dataSymbol(0..3)/errorBit(0/1)
            % 与 -1/0/+1 判决，全是数字量，没有任何可量化的连续值。
            obj.Pd = cdr_pd('pam4', cfg.PdPolarity);

            obj.Voter = cdr_fx.cdr_voter(cfg.BlockSize);
            obj.LoopFilter = obj.buildLoopFilter(cfg);
            obj.PhaseInterpolator = cdr_fx.cdr_pi(cfg.PiNumBit, cfg.SamplesPerSymbol);
            if isfield(cfg, 'PiPhaseTableUI') && ~isempty(cfg.PiPhaseTableUI)
                obj.PhaseInterpolator.setPhaseTableUI(cfg.PiPhaseTableUI);
            end
            obj.PhaseInterpolator.setCode(cfg.PiInitialCode, 0);

            obj.Ffe = cdr_fx.cdr_ffe(cfg.FfeInitCoefficients, cfg.FfePreTapCount);
            obj.FfeLoop = cdr_fx.cdr_ffe_loop(cfg.FfeStepSize, ...
                obj.Ffe.TapCount, obj.Ffe.MainTapIndex, cfg.BlockSize, ...
                cfg.FfeAdaptEnableMask);
            obj.FfeLoop.setCoefficients(obj.Ffe.Coefficients);

            obj.Dlev = cdr_fx.dlev_loop(cfg.DlevStepSize, cfg.BlockSize, ...
                cfg.DlevInnerInit, cfg.DlevOuterInit, cfg.DlevPolarity);

            obj.Monitor = cdr_fx.loop_monitor();
            obj.Monitor.enableSnrSettle(cfg.SnrSettleThresholdDb, ...
                cfg.SnrSettleAlpha, cfg.SnrSettleMinBlock);
            if cfg.FfeGateEnable
                obj.Monitor.enableFreqStateGate(cfg.FfeGateFreqExpectedRate, ...
                    cfg.FfeGateFreqMeanHalfDiffTol, cfg.FfeGateFreqStdTol, ...
                    cfg.FfeGateFreqRateTol, cfg.FfeGateFreqMinBlock, ...
                    cfg.FfeGateAlphaFast, cfg.FfeGateAlphaSlow, cfg.FfeGateAlphaMad);
            end

            obj.resetState();
        end

        function output = processConfiguredBlock(obj, centeredCode)
            %PROCESSCONFIGUREDBLOCK 喂入一块 ADC 码，返回上一块的处理结果。
            %   一块 pending 流水：输出对应的是上一块，相位生效延迟 2 块。
            cfg = obj.Config;
            centeredCode = double(centeredCode);

            % 必须先快照本块实际采用的 PI 状态，再处理 pending 并更新 PI。
            newCode = obj.PhaseInterpolator.CodeWrapped;
            newSlip = obj.PhaseInterpolator.UiSlip;
            futureSamples = centeredCode(1:obj.Ffe.PreTapCount);

            if obj.HavePending
                output = obj.processPending(true, futureSamples);
            else
                output = obj.emptyConfiguredOutput();
            end

            if obj.HavePending
                if obj.Ffe.PostTapCount == 0
                    obj.PendingPast = zeros(1, 0);
                else
                    obj.PendingPast = obj.PendingCentered( ...
                        end - obj.Ffe.PostTapCount + 1:end);
                end
                obj.PendingHasPast = true;
            else
                obj.PendingPast = zeros(1, obj.Ffe.PostTapCount);
                obj.PendingHasPast = false;
            end
            obj.PendingCentered = centeredCode;
            obj.PendingCodeWrapped = newCode;
            obj.PendingUiSlip = newSlip;
            obj.SampleBlockCount = obj.SampleBlockCount + 1;
            obj.PendingBlockIndex = obj.SampleBlockCount;
            obj.HavePending = true;
        end

        function output = flush(obj)
            %FLUSH 处理最后一块 pending，未来样本以零填充。
            if ~obj.HavePending
                output = obj.emptyConfiguredOutput();
                return;
            end
            output = obj.processPending(false, zeros(1, obj.Ffe.PreTapCount));
            obj.HavePending = false;
        end

        function [codeWrapped, uiSlip] = getSamplingPhase(obj)
            %GETSAMPLINGPHASE 调用方据此去采样波形。
            codeWrapped = obj.PhaseInterpolator.CodeWrapped;
            uiSlip = obj.PhaseInterpolator.UiSlip;
        end

        function idx = getLocalIndex(obj)
            %GETLOCALINDEX 当前 PI 码对应的 UI 内样本偏移。
            idx = obj.PhaseInterpolator.getLocalIndex();
        end

        function tf = gateLatched(obj)
            %GATELATCHED 第二级门控是否已闩锁。
            tf = obj.Monitor.gateLatched();
        end

        function resetState(obj)
            %RESETSTATE 协调复位全部子块与流水状态。
            obj.PendingCentered = zeros(1, 0);
            obj.PendingPast = zeros(1, obj.Ffe.PostTapCount);
            obj.PendingHasPast = false;
            obj.PendingCodeWrapped = 0;
            obj.PendingUiSlip = 0;
            obj.PendingBlockIndex = 0;
            obj.HavePending = false;
            obj.SampleBlockCount = 0;
            obj.BlockIndex = 0;
            obj.PreviousDataSymbol = [];
            obj.PreviousErrorBit = [];
            obj.CurrentLocalIndexFloat = obj.PhaseInterpolator.getLocalIndex();
            obj.GatedCoefficients = obj.Ffe.Coefficients;
        end

        function s = overflowReport(obj)
            %OVERFLOWREPORT 逐节点溢出/饱和计数。
            %   定点模型的验收不能只有 pass/fail：必须能回答"哪个节点在什么
            %   工况下溢出了多少次"。这是一等公民输出。
            lf = obj.LoopFilter.getState();
            s = struct( ...
                'Voter', obj.Voter.getState().OverflowCount, ...
                'LoopFreqState', lf.OverflowFreq, ...
                'LoopControl', lf.OverflowControl, ...
                'LoopCodeResidue', lf.OverflowResidue, ...
                'LoopPendingCode', lf.OverflowPending, ...
                'PiUiSlip', obj.PhaseInterpolator.getState().OverflowSlip, ...
                'FfeOutput', obj.Ffe.getState().OverflowOut, ...
                'FfeCoeffAccum', obj.FfeLoop.getState().OverflowAccum, ...
                'DlevAccum', obj.Dlev.getState().OverflowAccum);
        end
    end

    methods (Access = private)
        function lf = buildLoopFilter(~, cfg)
            %BUILDLOOPFILTER 把 voter 的 1/BlockSize 折进增益后构造环路滤波器。
            %   定点 voter 不做除法，所以这次换算必须在这里一次性完成；
            %   调用方传入的仍是与浮点版同义的原始 Kp/Ki。
            kp = cfg.Kp / cfg.BlockSize;
            ki = cfg.Ki / cfg.BlockSize;
            lf = cdr_fx.cdr_loop(kp, ki, -cfg.FrequencyLimit, ...
                cfg.FrequencyLimit, cfg.MaxDeltaCode);
        end

        function output = processPending(obj, haveFuture, futureSamples)
            %PROCESSPENDING 处理上一块：FFE -> 掩码 -> slicer -> PD -> voter ->
            %   环路 -> PI -> 第一级门控 -> dLev -> 第二级门控 -> FFE LMS。
            %   顺序与浮点版逐行对应，不得重排：两级门控都是一次性闩锁，
            %   stage-1 必须在 stage-2 尚未闩锁时才生效，否则会把已降到 PVT 档
            %   的步长抬回 settle 档。
            cfg = obj.Config;
            inputWindow = [obj.PendingPast, obj.PendingCentered, futureSamples];
            [blockOutput, blockRegressor] = obj.Ffe.processBlockFast(inputWindow);

            blockValid = true(1, cfg.BlockSize);
            if ~obj.PendingHasPast && obj.Ffe.PostTapCount > 0
                blockValid(1:obj.Ffe.PostTapCount) = false;
            end
            if ~haveFuture && obj.Ffe.PreTapCount > 0
                blockValid(end - obj.Ffe.PreTapCount + 1:end) = false;
            end
            ffeOutput = blockOutput(blockValid);

            codeWrapped = obj.PendingCodeWrapped;
            uiSlip = obj.PendingUiSlip;
            blockIndex = obj.PendingBlockIndex;

            % slicer 必须用 dLev 的**窄值**，这样 dlev_loop 内部的精确相等
            % 归属判断才成立。用宽累加器会让 == 永不命中，dLev 环静默死掉。
            [decision, sliceError, dataSymbol, errorBit] = obj.slicePam4( ...
                ffeOutput, obj.Dlev.DLevInnerSlice, ...
                obj.Dlev.DLevOuterSlice, obj.Dlev.ThresholdSlice);

            if isempty(obj.PreviousDataSymbol)
                obj.PreviousDataSymbol = dataSymbol(1);
                obj.PreviousErrorBit = errorBit(1);
            end
            dataPrev = [obj.PreviousDataSymbol, dataSymbol(1:end - 1)];
            errorPrev = [obj.PreviousErrorBit, errorBit(1:end - 1)];
            [phaseDecision, validTransition] = obj.Pd.mmpdFast( ...
                dataPrev, errorPrev, dataSymbol, errorBit, obj.TransitionFilter);
            obj.PreviousDataSymbol = dataSymbol(end);
            obj.PreviousErrorBit = errorBit(end);

            phaseError = obj.Voter.voteFast(phaseDecision);
            deltaCode = obj.LoopFilter.updateFast(phaseError);
            obj.PhaseInterpolator.update(deltaCode);

            % 第一级降档：门控喂的是两路功率而非 dB，对数不进硅。
            [decisionPower, errorPower] = obj.blockPowers(decision, sliceError);
            eyeOpenedEvent = obj.Monitor.updateSnrSettle( ...
                blockIndex, decisionPower, errorPower);
            if eyeOpenedEvent && ~obj.gateLatched()
                obj.Dlev.setStepSize(cfg.DlevStepSizeSettle);
                obj.FfeLoop.setStepSize(cfg.FfeStepSizeSettle);
            end

            if numel(ffeOutput) == cfg.BlockSize
                obj.Dlev.dlevSsLmsFast(decision, sliceError);
            end

            loopLockedEvent = false;
            if cfg.FfeGateEnable
                freqState = obj.LoopFilter.FrequencyState;
                loopLockedEvent = obj.Monitor.updateFreqStateGate(blockIndex, freqState);
                if loopLockedEvent
                    obj.GatedCoefficients = obj.Ffe.Coefficients;
                    if strcmp(cfg.FfeGateMode, 'pvt-track')
                        obj.FfeLoop.setStepSize(cfg.FfeStepSizePvtTrack);
                        obj.Dlev.setStepSize(cfg.DlevStepSizePvtTrack);
                    end
                end
            end

            rawDelta = nan(1, obj.Ffe.TapCount);
            appliedDelta = zeros(1, obj.Ffe.TapCount);
            proposedCoefficients = nan(1, obj.Ffe.TapCount);
            adaptationCalculated = false;
            writeApplied = false;
            if numel(ffeOutput) == cfg.BlockSize
                errorBlock = decision - ffeOutput;
                rawDelta = obj.FfeLoop.updateSsLmsFast(blockRegressor, errorBlock);
                rawDelta(obj.Ffe.MainTapIndex) = 0;
                % 宽累加器是真相源，窄系数由它截断得到后送乘法器。
                obj.Ffe.setCoefficients(obj.FfeLoop.coefficients());
                proposedCoefficients = obj.Ffe.Coefficients;
                appliedDelta = rawDelta;
                adaptationCalculated = true;
                writeApplied = true;
            end

            obj.BlockIndex = blockIndex;
            obj.CurrentLocalIndexFloat = obj.PhaseInterpolator.getLocalIndex();
            lf = obj.LoopFilter;
            dl = obj.Dlev;

            v = struct();
            v.HasOutput = true;
            v.BlockIndex = blockIndex;
            v.ValidMask = blockValid;
            v.SampleCodeWrapped = codeWrapped;
            v.SampleUiSlip = uiSlip;
            v.UnwrappedCode = uiSlip * cfg.SamplesPerSymbol + codeWrapped;
            v.FfeOutput = ffeOutput;
            v.Decision = decision;
            v.SliceError = sliceError;
            v.DataSymbol = dataSymbol;
            v.ErrorBit = errorBit;
            v.PhaseDecision = phaseDecision;
            v.ValidTransition = validTransition;
            v.PhaseError = phaseError;
            v.DeltaCode = deltaCode;
            v.LoopFrequencyState = lf.FrequencyState;
            v.LoopCodeResidue = lf.CodeResidue;
            v.LoopPendingCode = lf.PendingCode;
            v.NextCodeWrapped = obj.PhaseInterpolator.CodeWrapped;
            v.NextUiSlip = obj.PhaseInterpolator.UiSlip;
            v.DlevInner = dl.DLevInner;
            v.DlevOuter = dl.DLevOuter;
            v.DlevThreshold = dl.Threshold;
            v.DlevStepSize = dl.StepSize;
            v.FfeCoefficients = obj.Ffe.Coefficients;
            v.FfeRawDelta = rawDelta;
            v.FfeAppliedDelta = appliedDelta;
            v.FfeProposedCoefficients = proposedCoefficients;
            v.FfeAdaptationCalculated = adaptationCalculated;
            v.FfeWriteApplied = writeApplied;
            v.FfeStepSize = obj.FfeLoop.StepSize;
            v.LoopLockedEvent = loopLockedEvent;
            v.GateEngaged = obj.gateLatched();
            v.SnrSettleDone = obj.Monitor.SnrSettleDone;
            v.SnrSettleBlock = obj.Monitor.SnrSettleBlock;
            v.DecisionPower = decisionPower;
            v.ErrorPower = errorPower;
            output = v;
        end

        function output = emptyConfiguredOutput(obj)
            %EMPTYCONFIGUREDOUTPUT 流水线未填满时的空块输出，字段与正常块同形状。
            n = obj.Ffe.TapCount;
            output = struct( ...
                'HasOutput', false, 'BlockIndex', 0, ...
                'ValidMask', false(1, obj.Config.BlockSize), ...
                'SampleCodeWrapped', 0, 'SampleUiSlip', 0, 'UnwrappedCode', 0, ...
                'FfeOutput', zeros(1, 0), 'Decision', zeros(1, 0), ...
                'SliceError', zeros(1, 0), 'DataSymbol', zeros(1, 0), ...
                'ErrorBit', zeros(1, 0), 'PhaseDecision', zeros(1, 0), ...
                'ValidTransition', false(1, 0), 'PhaseError', 0, 'DeltaCode', 0, ...
                'LoopFrequencyState', 0, 'LoopCodeResidue', 0, 'LoopPendingCode', 0, ...
                'NextCodeWrapped', obj.PhaseInterpolator.CodeWrapped, ...
                'NextUiSlip', obj.PhaseInterpolator.UiSlip, ...
                'DlevInner', obj.Dlev.DLevInner, 'DlevOuter', obj.Dlev.DLevOuter, ...
                'DlevThreshold', obj.Dlev.Threshold, 'DlevStepSize', obj.Dlev.StepSize, ...
                'FfeCoefficients', obj.Ffe.Coefficients, ...
                'FfeRawDelta', nan(1, n), 'FfeAppliedDelta', zeros(1, n), ...
                'FfeProposedCoefficients', nan(1, n), ...
                'FfeAdaptationCalculated', false, 'FfeWriteApplied', false, ...
                'FfeStepSize', obj.FfeLoop.StepSize, ...
                'LoopLockedEvent', false, 'GateEngaged', obj.gateLatched(), ...
                'SnrSettleDone', obj.Monitor.SnrSettleDone, ...
                'SnrSettleBlock', obj.Monitor.SnrSettleBlock, ...
                'DecisionPower', NaN, 'ErrorPower', NaN);
        end

        function [decision, sliceError, dataSymbol, errorBit] = ...
                slicePam4(obj, sample, dLevInner, dLevOuter, threshold)
            %SLICEPAM4 静态 PAM4 判决器（定点）。
            %   一个判决器同时供 MMPD、dLev 环、FFE 误差与 SNR FOM 使用。
            %   dataSymbol 是自然序：0=-3, 1=-1, 2=+1, 3=+3。
            isOuter = abs(sample) >= threshold;
            isPositive = sample >= 0;
            magnitude = dLevInner + (dLevOuter - dLevInner) .* isOuter;
            decision = magnitude;
            decision(~isPositive) = -magnitude(~isPositive);
            % decision 由两个已在 (1,9,2) 栅格上的值组合而来，天然合规，
            % 这里仅做饱和兜底。
            decision = cdr_fx.fxq.sat(decision, obj.FmtSlice);
            sliceError = cdr_fx.fxq.apply(sample - decision, obj.FmtSliceErr, 'floor');
            dataSymbol = double(isPositive) * 2 + double(isPositive == isOuter);
            errorBit = double(sliceError >= 0);
        end

        function [decisionPower, errorPower] = blockPowers(~, decision, sliceError)
            %BLOCKPOWERS 两路功率，供换域后的 SNR 门控使用。
            %   原浮点版在这里算 10*log10(Pd/Pe)；对数不可综合，所以把比值
            %   留给门控内部做一次乘法比较，这里只输出两个功率。
            if isempty(decision)
                decisionPower = NaN;
                errorPower = NaN;
                return;
            end
            decisionPower = mean(double(decision) .^ 2);
            errorPower = mean(double(sliceError) .^ 2);
        end
    end

    methods (Static)
        function cfg = defaultConfig()
            %DEFAULTCONFIG 与浮点版同名字段的定点默认配置。
            cfg = cdr_top.defaultConfig();
            % 频率态门控改用 EWMA，窗口类参数被三个 alpha 取代。
            cfg = rmfield(cfg, intersect(fieldnames(cfg), ...
                {'FfeGateFreqWindowBlocks', 'FfeGateFreqSatFrac'}));
            cfg.FfeGateAlphaFast = 1 / 64;
            cfg.FfeGateAlphaSlow = 1 / 512;
            cfg.FfeGateAlphaMad = 1 / 256;
            cfg.FfeGateFreqMinBlock = 2048;
            cfg.PiPhaseTableUI = [];
        end
    end
end

