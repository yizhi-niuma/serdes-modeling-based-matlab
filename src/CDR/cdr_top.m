classdef cdr_top < handle
    % cdr_top  数字 CDR 顶层行为模型。
    %
    % 本类由单个 config 结构体构造：在 code 域内拥有并调度 CDR FFE、统一 PAM4
    % slicer、dlev 与 FFE SS-LMS 及 FFE gate monitor，同时组合 PD、voter、
    % loop filter 与 PI 构成相位环。

    properties (SetAccess = private)
        % 四级 CDR 控制链。
        Pd
        Voter
        LoopFilter
        PhaseInterpolator

        % 顶层状态。
        BlockIndex = 0
        CurrentLocalIndexFloat = 0
        LastOutput

        % config 路径拥有的 DSP 子模块与配置。
        Ffe
        Dlev
        FfeLoop
        Monitor
        Config
        Detector = ''
        TransitionFilter = true

        % config 路径的流式 pending 与跨块 carry。
        PreviousDataSymbol = []
        PreviousErrorBit = []
        SampleBlockCount = 0
        PendingCentered
        PendingPast
        PendingHasPast = false
        HavePending = false
        PendingCodeWrapped = 0
        PendingUiSlip = 0
        PendingBlockIndex = 0

        % gate 触发瞬间的系数快照。换挡/门控的判决状态归 loop_monitor 所有。
        GatedCoefficients
    end

    properties (Dependent, SetAccess = private)
        % 只读代理：一次性换挡状态由 loop_monitor 持有，本类不再复制一份。
        SettleDone
    end

    methods
        function obj = cdr_top(config)
            % cdr_top  由单个 config 结构体构造完整 code 域 DSP 核。
            if nargin ~= 1 || ~isstruct(config)
                error('cdr_top:InvalidConfig', ...
                    'cdr_top requires a single configuration struct.');
            end
            obj.constructConfigured(config);
        end

        function output = processBlock(obj, centeredCode)
            % processBlock  处理一个时序 ADC code 块。
            output = obj.processConfiguredBlock(centeredCode);
            obj.LastOutput = output;
        end

        function output = flush(obj)
            % flush  用零 future 处理最后一个 pending 块。
            if ~obj.HavePending
                output = obj.emptyConfiguredOutput();
                obj.LastOutput = output;
                return;
            end

            futureSamples = zeros(1, obj.Ffe.PreTapCount);
            output = obj.processPending(false, futureSamples);
            obj.HavePending = false;
            obj.LastOutput = output;
        end

        function [codeWrapped, uiSlip] = getSamplingPhase(obj)
            % getSamplingPhase  返回下一次外部采样应使用的 PI wrapped/slip 状态。
            codeWrapped = obj.PhaseInterpolator.CodeWrapped;
            uiSlip = obj.PhaseInterpolator.UiSlip;
        end

        function resetState(obj)
            % resetState  协同复位动态状态，不改变任何配置项。
            obj.Pd.resetState();
            obj.LoopFilter.resetState();
            obj.PhaseInterpolator.resetState();
            obj.configurePiNonideal();
            obj.PhaseInterpolator.setCode(obj.Config.PiInitialCode);
            obj.Dlev.resetState();
            obj.Dlev.setStepSize(obj.Config.DlevStepSize);
            obj.Ffe.resetState();
            obj.FfeLoop.resetState();
            obj.FfeLoop.setStepSize(obj.Config.FfeStepSize);
            obj.Monitor.resetState();

            obj.PreviousDataSymbol = [];
            obj.PreviousErrorBit = [];
            obj.BlockIndex = 0;
            obj.SampleBlockCount = 0;
            obj.CurrentLocalIndexFloat = ...
                obj.PhaseInterpolator.getLocalIndex();
            obj.PendingCentered = zeros(1, obj.Config.BlockSize);
            obj.PendingPast = zeros(1, obj.Ffe.PostTapCount);
            obj.PendingHasPast = false;
            obj.HavePending = false;
            obj.PendingCodeWrapped = 0;
            obj.PendingUiSlip = 0;
            obj.PendingBlockIndex = 0;
            obj.GatedCoefficients = nan(1, obj.Ffe.TapCount);
            obj.LastOutput = struct();
        end

        function state = getState(obj)
            % getState  返回完整调试状态。
            state = struct();
            state.Config = obj.Config;
            state.Detector = obj.Detector;
            state.TransitionFilter = obj.TransitionFilter;
            state.BlockIndex = obj.BlockIndex;
            state.SampleBlockCount = obj.SampleBlockCount;
            state.PreviousDataSymbol = obj.PreviousDataSymbol;
            state.PreviousErrorBit = obj.PreviousErrorBit;
            state.HavePending = obj.HavePending;
            state.PendingHasPast = obj.PendingHasPast;
            state.PendingCentered = obj.PendingCentered;
            state.PendingPast = obj.PendingPast;
            state.PendingCodeWrapped = obj.PendingCodeWrapped;
            state.PendingUiSlip = obj.PendingUiSlip;
            state.PendingBlockIndex = obj.PendingBlockIndex;
            state.SettleDone = obj.SettleDone;
            state.GatedCoefficients = obj.GatedCoefficients;
            state.LastOutput = obj.LastOutput;
            state.Pd = obj.Pd.getState();
            state.LoopFilter = obj.LoopFilter.getState();
            state.PhaseInterpolator = obj.PhaseInterpolator.getState();
            state.Dlev = obj.Dlev.getState();
            state.Ffe = obj.Ffe.getState();
            state.FfeLoop = obj.FfeLoop.getState();
            state.Monitor = obj.Monitor.getState();
        end

        function value = get.SettleDone(obj)
            % get.SettleDone  一次性换挡状态的只读代理，真值在 loop_monitor。
            if isempty(obj.Monitor)
                value = false;
                return;
            end
            value = obj.Monitor.SettleDone;
        end
    end

    methods (Static)
        function cfg = defaultConfig()
            % defaultConfig  返回完整且可直接构造的 v3 对齐默认配置。
            cfg = struct();
            cfg.BlockSize = 64;
            cfg.SamplesPerSymbol = 128;
            cfg.Detector = 'mmpd';
            cfg.TransitionFilter = true;
            cfg.PdPolarity = 1;
            cfg.VoterMode = 'mean';
            cfg.VoterDenominator = 'auto';
            cfg.Kp = 8;
            cfg.Ki = 0.03;
            cfg.FrequencyLimit = 4;
            cfg.MaxDeltaCode = 1;
            cfg.PiNumBit = 7;
            cfg.PiNonideal = 'ab_constant';
            cfg.PiInitialCode = 0;
            cfg.DlevInnerInit = 16;
            cfg.DlevOuterInit = 48;
            cfg.DlevPolarity = 1;
            cfg.DlevStepSize = 0.5;
            cfg.DlevStepSizeSettle = 0.1;
            cfg.DlevStepSizePvtTrack = 0.02;
            cfg.DlevSettleWindow = 16;
            cfg.DlevSettleTol = 0.5;
            % Stage-2 (capture -> settle) mu-downshift gate.
            %   'snr'  : averaged decision-directed eye SNR crosses
            %            SnrSettleThresholdDb. Default, because the eye being
            %            open is the actual precondition for slowing the FFE.
            %   'dlev' : legacy outer-dLev displacement test. Kept selectable
            %            for the loop_monitor/cdr_top unit contracts, but it is
            %            an implicit drift-rate threshold of
            %            DlevSettleTol/DlevSettleWindow and a slowly ramping
            %            dLev satisfies it while the eye is still closed.
            cfg.SettleGate = 'snr';
            cfg.SnrSettleThresholdDb = 15;
            cfg.SnrSettleAlpha = 1 / 128;
            cfg.SnrSettleMinBlock = 200;
            cfg.FfeInitCoefficients = [0 0 1 0 0 0];
            cfg.FfePreTapCount = 2;
            cfg.FfeStepSize = 0.004;
            cfg.FfeStepSizeSettle = 2e-4;
            cfg.FfeAdaptEnableMask = logical([1 1 0 1 1 1]);
            cfg.FfeGateEnable = true;
            cfg.FfeGateMode = 'pvt-track';
            cfg.FfeStepSizePvtTrack = 2e-4;
            cfg.FfeGateMinModeOccurrences = 500;
            cfg.FfeGateMinEvents = 100;
            cfg.FfeGateBandHalfWidth = 3;
            cfg.FfeGateStartBlock = 1;
            % 第二级降档的门控判据。'center-touch' 是码域众数检测，只在零频偏
            % 下成立：有 ppm 时 PI code 持续爬升、不会停驻在单一码上，该门控
            % 永远不会触发。'freq-state' 改用环路积分频率态的平坦性判据，它与
            % 离线 loop_monitor.detectFrequencyStateLock 同源，在任意 ppm
            % (含 0) 下都有意义。默认保持 'center-touch' 以维持既有行为。
            cfg.FfeGateCriterion = 'center-touch';
            cfg.FfeGateFreqWindowBlocks = 2000;
            cfg.FfeGateFreqExpectedRate = NaN;
            cfg.FfeGateFreqMeanHalfDiffTol = 1e-3;
            cfg.FfeGateFreqStdTol = 5e-3;
            cfg.FfeGateFreqRateTol = Inf;
            cfg.FfeGateFreqMinBlock = 1;
        end

        function [decision, sliceError, dataSymbol, errorBit] = ...
                slicePam4(sample, dLevInner, dLevOuter, threshold)
            % slicePam4  用当前 dlev 电平和门限完成统一 PAM4 code 域判决。
            sample = reshape(sample, 1, []);
            isNegative = sample < 0;
            isOuter = abs(sample) >= threshold;
            magnitude = dLevInner + (dLevOuter - dLevInner) .* isOuter;
            decision = magnitude;
            decision(isNegative) = -magnitude(isNegative);
            sliceError = sample - decision;

            isPositive = decision >= 0;
            isOuter = abs(decision) >= threshold;
            dataSymbol = double(isPositive) * 2 + ...
                double(isPositive == isOuter);
            errorBit = double(sliceError >= 0);
        end
        function snrDb = blockSnrDb(decision, sliceError)
            % blockSnrDb  判决导向眼质量 FOM：判决电平功率/切片误差功率 (dB)。
            %
            % decision 与 sliceError 已是有效样本(ffeOutput 先按 blockValid 掩码
            % 再切片)，无需再过滤。该指标是判决导向而非真值参考：闭眼判错时误差
            % 相对"错误的"电平计算，单块读数可能偏乐观——实测中一个未锁定、相位
            % 持续旋转的环路会周期性扫过眼心并给出高读数。因此它只能配合
            % loop_monitor 的 EWMA 使用，不可逐块直接判阈。
            if isempty(decision) || isempty(sliceError)
                snrDb = NaN;
                return;
            end
            errorPower = mean(double(sliceError) .^ 2);
            if ~(errorPower > 0)
                snrDb = Inf;
                return;
            end
            snrDb = 10 * log10(mean(double(decision) .^ 2) / errorPower);
        end
    end

    methods (Access = private)
        function latched = gateLatched(obj)
            %GATELATCHED 第二级门控是否已闩锁(与所选判据一致)。
            %
            % center-touch 的闩锁是 loop_monitor.Frozen，freq-state 的闩锁是
            % FreqGateDone。两者必须按当前判据分别读取：早期版本固定读
            % Frozen，在 freq-state 下它永远为 false，会让 'freeze' 模式的
            % FFE 写抑制和 GateEngaged 报告全部失效。
            if ~obj.Config.FfeGateEnable
                latched = false;
            elseif strcmp(obj.Config.FfeGateCriterion, 'freq-state')
                latched = obj.Monitor.FreqGateDone;
            else
                latched = obj.Monitor.Frozen;
            end
        end

        function constructConfigured(obj, config)
            cfg = obj.validateConfig(config);
            obj.Config = cfg;
            obj.Detector = cfg.Detector;
            obj.TransitionFilter = cfg.TransitionFilter;

            obj.Pd = cdr_pd('pam4', cfg.PdPolarity);
            obj.Voter = cdr_voter(cfg.VoterMode, cfg.BlockSize, 8, ...
                cfg.VoterDenominator);
            obj.LoopFilter = cdr_loop(cfg.Kp, cfg.Ki, ...
                -cfg.FrequencyLimit, cfg.FrequencyLimit, cfg.MaxDeltaCode);
            obj.PhaseInterpolator = cdr_pi(cfg.PiNumBit, ...
                cfg.SamplesPerSymbol);
            obj.Ffe = cdr_ffe(cfg.FfeInitCoefficients, cfg.FfePreTapCount);
            obj.Dlev = dlev_loop(cfg.DlevStepSize, cfg.BlockSize, ...
                cfg.DlevInnerInit, cfg.DlevOuterInit, cfg.DlevPolarity);
            obj.FfeLoop = cdr_ffe_loop(cfg.FfeStepSize, obj.Ffe.TapCount, ...
                obj.Ffe.MainTapIndex, cfg.BlockSize, cfg.FfeAdaptEnableMask);
            obj.Monitor = loop_monitor( ...
                cfg.FfeGateMinModeOccurrences, cfg.FfeGateMinEvents, ...
                cfg.FfeGateBandHalfWidth, cfg.FfeGateStartBlock, ...
                cfg.DlevSettleWindow, cfg.DlevSettleTol);
            if strcmp(cfg.SettleGate, 'snr')
                obj.Monitor.enableSnrSettle(cfg.SnrSettleThresholdDb, ...
                    cfg.SnrSettleAlpha, cfg.SnrSettleMinBlock);
            end
            if cfg.FfeGateEnable && strcmp(cfg.FfeGateCriterion, 'freq-state')
                obj.Monitor.enableFreqStateGate( ...
                    cfg.FfeGateFreqWindowBlocks, ...
                    cfg.FfeGateFreqExpectedRate, ...
                    cfg.FfeGateFreqMeanHalfDiffTol, ...
                    cfg.FfeGateFreqStdTol, cfg.FfeGateFreqRateTol, ...
                    cfg.FfeGateFreqMinBlock);
            end
            obj.resetState();
        end

        function output = processConfiguredBlock(obj, centeredCode)
            cfg = obj.Config;
            isValid = isnumeric(centeredCode) && isreal(centeredCode) && ...
                isrow(centeredCode) && numel(centeredCode) == cfg.BlockSize && ...
                all(isfinite(centeredCode));
            if ~isValid
                error('cdr_top:InvalidCenteredCode', ...
                    'centeredCode must be a finite real 1-by-BlockSize numeric vector.');
            end
            centeredCode = double(centeredCode);

            % 必须先快照本次输入块实际采用的 PI 状态，再处理 pending 并更新 PI。
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

        function output = processPending(obj, haveFuture, futureSamples)
            cfg = obj.Config;
            inputWindow = [obj.PendingPast, obj.PendingCentered, futureSamples];
            [blockOutput, blockRegressor] = obj.Ffe.processBlock(inputWindow);

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
            [decision, sliceError, dataSymbol, errorBit] = ...
                cdr_top.slicePam4(ffeOutput, obj.Dlev.DLevInner, ...
                obj.Dlev.DLevOuter, obj.Dlev.Threshold);

            if strcmp(obj.Detector, 'mmpd')
                % SS-MMPD 只是把符号化输入送入同一条 mmpd 数值路径。
                if isempty(obj.PreviousDataSymbol)
                    obj.PreviousDataSymbol = dataSymbol(1);
                    obj.PreviousErrorBit = errorBit(1);
                end
                dataPrev = [obj.PreviousDataSymbol, dataSymbol(1:end - 1)];
                errorPrev = [obj.PreviousErrorBit, errorBit(1:end - 1)];
                [phaseDecision, validTransition] = obj.Pd.mmpdFast( ...
                    dataPrev, errorPrev, dataSymbol, errorBit, ...
                    obj.TransitionFilter);
                obj.PreviousDataSymbol = dataSymbol(end);
                obj.PreviousErrorBit = errorBit(end);
            else
                if isempty(obj.PreviousDataSymbol)
                    obj.PreviousDataSymbol = dataSymbol(1);
                end
                dataPrev = [obj.PreviousDataSymbol, dataSymbol(1:end - 1)];
                [phaseDecision, validTransition] = obj.Pd.bbpdFast( ...
                    dataPrev, errorBit, dataSymbol);
                obj.PreviousDataSymbol = dataSymbol(end);
            end

            phaseError = obj.Voter.vote(phaseDecision);
            deltaCode = obj.LoopFilter.update(phaseError);
            obj.PhaseInterpolator.update(deltaCode);

            % 策略判决全部委托给 loop_monitor：它只判决，由本类施加动作。
            % 第一级降档(capture -> settle)：两个环路同时降，门控见 SettleGate。
            snrDb = cdr_top.blockSnrDb(decision, sliceError);
            if strcmp(cfg.SettleGate, 'snr')
                settleTriggered = obj.Monitor.updateSnrSettle(blockIndex, snrDb);
            else
                settleTriggered = obj.Monitor.updateDlevSettle(blockIndex, ...
                    obj.Dlev.DLevOuter);
            end
            if settleTriggered
                obj.Dlev.setStepSize(cfg.DlevStepSizeSettle);
                obj.FfeLoop.setStepSize(cfg.FfeStepSizeSettle);
            end

            if numel(ffeOutput) == cfg.BlockSize
                obj.Dlev.dlevSsLms(decision, sliceError);
            end

            gateTriggered = false;
            if cfg.FfeGateEnable
                if strcmp(cfg.FfeGateCriterion, 'freq-state')
                    % 环路滤波器已在本块更新过(见上方 LoopFilter.update)，
                    % 因此这里读到的积分频率态与随后记录进 trace 的
                    % LoopFrequencyState 是同一个值，在线判定与离线判据
                    % 逐块对齐。
                    gateTriggered = obj.Monitor.updateFreqStateGate( ...
                        blockIndex, obj.LoopFilter.FrequencyState);
                else
                    unwrapped = uiSlip * cfg.SamplesPerSymbol + codeWrapped;
                    gateTriggered = obj.Monitor.updateFfeGate(unwrapped, ...
                        blockIndex);
                end
                if gateTriggered
                    obj.GatedCoefficients = obj.Ffe.Coefficients;
                    if strcmp(cfg.FfeGateMode, 'pvt-track')
                        % 第二级降档(settle -> PVT tracking)：锁定确认后两个
                        % 环路再各降一档，只保留跟踪 PVT 漂移的能力。
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
            gateInhibitsWrite = strcmp(cfg.FfeGateMode, 'freeze');
            if numel(ffeOutput) == cfg.BlockSize
                errorBlock = decision - ffeOutput;
                rawDelta = obj.FfeLoop.updateSsLms(blockRegressor, errorBlock);
                rawDelta(obj.Ffe.MainTapIndex) = 0;
                proposedCoefficients = obj.Ffe.Coefficients + rawDelta;
                adaptationCalculated = true;
                if ~obj.gateLatched() || ~gateInhibitsWrite
                    obj.Ffe.applyCoefficientDelta(rawDelta);
                    appliedDelta = rawDelta;
                    writeApplied = true;
                end
            end

            obj.Monitor.recordDlevOuter(blockIndex, obj.Dlev.DLevOuter);
            obj.BlockIndex = blockIndex;
            obj.CurrentLocalIndexFloat = ...
                obj.PhaseInterpolator.getLocalIndex();

            output = struct();
            output.HasOutput = true;
            output.BlockIndex = blockIndex;
            output.SampleCodeWrapped = codeWrapped;
            output.SampleUiSlip = uiSlip;
            output.UnwrappedCode = uiSlip * cfg.SamplesPerSymbol + codeWrapped;
            output.FfeOutput = ffeOutput;
            output.ValidMask = blockValid;
            output.Decision = decision;
            output.SliceError = sliceError;
            output.DataSymbol = dataSymbol;
            output.ErrorBit = errorBit;
            output.PhaseDecision = phaseDecision;
            output.ValidTransition = validTransition;
            output.PhaseError = phaseError;
            output.DeltaCode = deltaCode;
            % 环路滤波器的亚码连续量：LoopControl 是量化前的相位速度需求
            % (code/block)，LoopFrequencyState 是积分态。整数 PI code 会把
            % 亚码运动藏起来，这两个量用于区分"真抖动"与"缓慢漂移"。
            output.LoopControl = obj.LoopFilter.LastControl;
            output.LoopFrequencyState = obj.LoopFilter.FrequencyState;
            output.LoopCodeResidue = obj.LoopFilter.CodeResidue;
            output.LoopPendingCode = obj.LoopFilter.PendingCode;
            output.NextCodeWrapped = obj.PhaseInterpolator.CodeWrapped;
            output.NextUiSlip = obj.PhaseInterpolator.UiSlip;
            output.DlevInner = obj.Dlev.DLevInner;
            output.DlevOuter = obj.Dlev.DLevOuter;
            output.DlevThreshold = obj.Dlev.Threshold;
            output.FfeCoefficients = obj.Ffe.Coefficients;
            output.FfeRawDelta = rawDelta;
            output.FfeAppliedDelta = appliedDelta;
            output.FfeProposedCoefficients = proposedCoefficients;
            output.FfeAdaptationCalculated = adaptationCalculated;
            output.FfeWriteApplied = writeApplied;
            output.GateTriggered = gateTriggered;
            output.GateEngaged = obj.gateLatched();
            output.SettleDone = obj.SettleDone;
            output.SnrDb = snrDb;
            output.SnrEwmaDb = obj.Monitor.SnrEwmaDb;
            output.SnrSettleDone = obj.Monitor.SnrSettleDone;
            output.SnrSettleBlock = obj.Monitor.SnrSettleBlock;
            output.DlevStepSize = obj.Dlev.StepSize;
            output.FfeStepSize = obj.FfeLoop.StepSize;
        end

        function output = emptyConfiguredOutput(obj)
            output = struct();
            output.HasOutput = false;
            output.BlockIndex = 0;
            output.SampleCodeWrapped = NaN;
            output.SampleUiSlip = NaN;
            output.UnwrappedCode = NaN;
            output.FfeOutput = zeros(1, 0);
            output.ValidMask = false(1, obj.Config.BlockSize);
            output.Decision = zeros(1, 0);
            output.SliceError = zeros(1, 0);
            output.DataSymbol = zeros(1, 0);
            output.ErrorBit = zeros(1, 0);
            output.PhaseDecision = zeros(1, 0, 'int8');
            output.ValidTransition = false(1, 0);
            output.PhaseError = NaN;
            output.DeltaCode = NaN;
            output.LoopControl = NaN;
            output.LoopFrequencyState = obj.LoopFilter.FrequencyState;
            output.LoopCodeResidue = obj.LoopFilter.CodeResidue;
            output.LoopPendingCode = obj.LoopFilter.PendingCode;
            output.NextCodeWrapped = obj.PhaseInterpolator.CodeWrapped;
            output.NextUiSlip = obj.PhaseInterpolator.UiSlip;
            output.DlevInner = obj.Dlev.DLevInner;
            output.DlevOuter = obj.Dlev.DLevOuter;
            output.DlevThreshold = obj.Dlev.Threshold;
            output.FfeCoefficients = obj.Ffe.Coefficients;
            output.FfeRawDelta = nan(1, obj.Ffe.TapCount);
            output.FfeAppliedDelta = zeros(1, obj.Ffe.TapCount);
            output.FfeProposedCoefficients = nan(1, obj.Ffe.TapCount);
            output.FfeAdaptationCalculated = false;
            output.FfeWriteApplied = false;
            output.GateTriggered = false;
            output.GateEngaged = obj.gateLatched();
            output.SettleDone = obj.SettleDone;
            output.SnrDb = NaN;
            output.SnrEwmaDb = obj.Monitor.SnrEwmaDb;
            output.SnrSettleDone = obj.Monitor.SnrSettleDone;
            output.SnrSettleBlock = obj.Monitor.SnrSettleBlock;
            output.DlevStepSize = obj.Dlev.StepSize;
            output.FfeStepSize = obj.FfeLoop.StepSize;
        end

        function configurePiNonideal(obj)
            if strcmp(obj.Config.PiNonideal, 'ideal')
                obj.PhaseInterpolator.resetNonideal();
            else
                obj.PhaseInterpolator.setDefaultNonideal();
            end
        end

        function cfg = validateConfig(obj, cfg)
            if ~isscalar(cfg)
                error('cdr_top:InvalidConfig', 'config must be a scalar struct.');
            end
            expected = fieldnames(cdr_top.defaultConfig());
            for index = 1:numel(expected)
                field = expected{index};
                if ~isfield(cfg, field)
                    error(['cdr_top:Invalid' field], ...
                        'config.%s is required.', field);
                end
            end

            obj.requirePositiveInteger(cfg.BlockSize, 'BlockSize');
            if cfg.BlockSize > double(intmax('int16'))
                obj.invalidField('BlockSize');
            end
            obj.requirePositiveInteger(cfg.SamplesPerSymbol, 'SamplesPerSymbol');
            cfg.Detector = obj.requireTextChoice(cfg.Detector, 'Detector', ...
                {'bbpd', 'mmpd', 'ssmmpd'});
            if strcmp(cfg.Detector, 'ssmmpd')
                cfg.Detector = 'mmpd';
            end
            if ~(isscalar(cfg.TransitionFilter) && ...
                    (islogical(cfg.TransitionFilter) || ...
                    (isnumeric(cfg.TransitionFilter) && ...
                    isreal(cfg.TransitionFilter) && ...
                    ismember(double(cfg.TransitionFilter), [0 1 2]))))
                error('cdr_top:InvalidTransitionFilter', ...
                    'TransitionFilter must be logical or numeric 0/1/2.');
            end
            cfg.TransitionFilter = double(cfg.TransitionFilter);
            obj.requirePolarity(cfg.PdPolarity, 'PdPolarity');
            cfg.VoterMode = obj.requireTextChoice(cfg.VoterMode, ...
                'VoterMode', {'linear', 'constant', 'mean'});
            cfg.VoterDenominator = obj.requireDenominator(cfg.VoterDenominator);
            obj.requireNonnegativeScalar(cfg.Kp, 'Kp');
            obj.requireNonnegativeScalar(cfg.Ki, 'Ki');
            obj.requireNonnegativeScalar(cfg.FrequencyLimit, 'FrequencyLimit');
            obj.requirePositiveInteger(cfg.MaxDeltaCode, 'MaxDeltaCode');
            obj.requirePositiveInteger(cfg.PiNumBit, 'PiNumBit');
            if cfg.PiNumBit > 30
                obj.invalidField('PiNumBit');
            end
            cfg.PiNonideal = obj.requireTextChoice(cfg.PiNonideal, ...
                'PiNonideal', {'ideal', 'ab_constant'});
            obj.requireIntegerScalar(cfg.PiInitialCode, 'PiInitialCode');
            if cfg.PiInitialCode < 0 || cfg.PiInitialCode >= 2^cfg.PiNumBit
                obj.invalidField('PiInitialCode');
            end
            obj.requirePositiveScalar(cfg.DlevInnerInit, 'DlevInnerInit');
            obj.requirePositiveScalar(cfg.DlevOuterInit, 'DlevOuterInit');
            if cfg.DlevOuterInit <= cfg.DlevInnerInit
                obj.invalidField('DlevOuterInit');
            end
            obj.requirePolarity(cfg.DlevPolarity, 'DlevPolarity');
            obj.requirePositiveScalar(cfg.DlevStepSize, 'DlevStepSize');
            obj.requirePositiveScalar(cfg.DlevStepSizeSettle, ...
                'DlevStepSizeSettle');
            obj.requirePositiveInteger(cfg.DlevSettleWindow, ...
                'DlevSettleWindow');
            obj.requireNonnegativeScalar(cfg.DlevSettleTol, 'DlevSettleTol');

            if ~(isnumeric(cfg.FfeInitCoefficients) && ...
                    isreal(cfg.FfeInitCoefficients) && ...
                    isvector(cfg.FfeInitCoefficients) && ...
                    ~isempty(cfg.FfeInitCoefficients) && ...
                    all(isfinite(cfg.FfeInitCoefficients(:))))
                obj.invalidField('FfeInitCoefficients');
            end
            cfg.FfeInitCoefficients = reshape( ...
                double(cfg.FfeInitCoefficients), 1, []);
            obj.requireNonnegativeInteger(cfg.FfePreTapCount, 'FfePreTapCount');
            if cfg.FfePreTapCount >= numel(cfg.FfeInitCoefficients)
                obj.invalidField('FfePreTapCount');
            end
            mainTapIndex = cfg.FfePreTapCount + 1;
            if cfg.FfeInitCoefficients(mainTapIndex) ~= 1
                obj.invalidField('FfeInitCoefficients');
            end
            obj.requireNonnegativeScalar(cfg.FfeStepSize, 'FfeStepSize');
            obj.requireNonnegativeScalar(cfg.FfeStepSizeSettle, ...
                'FfeStepSizeSettle');
            if ~((islogical(cfg.FfeAdaptEnableMask) || ...
                    isnumeric(cfg.FfeAdaptEnableMask)) && ...
                    isvector(cfg.FfeAdaptEnableMask) && ...
                    numel(cfg.FfeAdaptEnableMask) == ...
                    numel(cfg.FfeInitCoefficients) && ...
                    all(ismember(cfg.FfeAdaptEnableMask(:), [0 1])))
                obj.invalidField('FfeAdaptEnableMask');
            end
            cfg.FfeAdaptEnableMask = logical( ...
                reshape(cfg.FfeAdaptEnableMask, 1, []));
            cfg.FfeGateEnable = obj.requireLogicalScalar( ...
                cfg.FfeGateEnable, 'FfeGateEnable');
            cfg.FfeGateMode = obj.requireTextChoice(cfg.FfeGateMode, ...
                'FfeGateMode', {'freeze', 'pvt-track'});
            obj.requireNonnegativeScalar(cfg.FfeStepSizePvtTrack, ...
                'FfeStepSizePvtTrack');
            obj.requirePositiveInteger(cfg.FfeGateMinModeOccurrences, ...
                'FfeGateMinModeOccurrences');
            obj.requirePositiveInteger(cfg.FfeGateMinEvents, ...
                'FfeGateMinEvents');
            obj.requireNonnegativeInteger(cfg.FfeGateBandHalfWidth, ...
                'FfeGateBandHalfWidth');
            obj.requirePositiveInteger(cfg.FfeGateStartBlock, ...
                'FfeGateStartBlock');
            cfg.FfeGateCriterion = obj.requireTextChoice( ...
                cfg.FfeGateCriterion, 'FfeGateCriterion', ...
                {'center-touch', 'freq-state'});
            obj.requirePositiveInteger(cfg.FfeGateFreqWindowBlocks, ...
                'FfeGateFreqWindowBlocks');
            if cfg.FfeGateFreqWindowBlocks < 2
                % 判据要取前后半均值之差，窗口至少要有两个样本。
                obj.invalidField('FfeGateFreqWindowBlocks');
            end
            % 期望漂移率允许为 NaN(只判平坦性，不比对速率)。
            if ~(isnumeric(cfg.FfeGateFreqExpectedRate) && ...
                    isreal(cfg.FfeGateFreqExpectedRate) && ...
                    isscalar(cfg.FfeGateFreqExpectedRate) && ...
                    (isfinite(cfg.FfeGateFreqExpectedRate) || ...
                    isnan(cfg.FfeGateFreqExpectedRate)))
                obj.invalidField('FfeGateFreqExpectedRate');
            end
            obj.requireNonnegativeScalar(cfg.FfeGateFreqMeanHalfDiffTol, ...
                'FfeGateFreqMeanHalfDiffTol');
            obj.requireNonnegativeScalar(cfg.FfeGateFreqStdTol, ...
                'FfeGateFreqStdTol');
            % 速率容差允许为 Inf，与 NaN 期望速率等效地跳过速率比对。
            if ~(isnumeric(cfg.FfeGateFreqRateTol) && ...
                    isreal(cfg.FfeGateFreqRateTol) && ...
                    isscalar(cfg.FfeGateFreqRateTol) && ...
                    ~isnan(cfg.FfeGateFreqRateTol) && ...
                    cfg.FfeGateFreqRateTol >= 0)
                obj.invalidField('FfeGateFreqRateTol');
            end
            obj.requirePositiveInteger(cfg.FfeGateFreqMinBlock, ...
                'FfeGateFreqMinBlock');
            cfg.SettleGate = obj.requireTextChoice(cfg.SettleGate, ...
                'SettleGate', {'dlev', 'snr'});
            obj.requirePositiveScalar(cfg.DlevStepSizePvtTrack, ...
                'DlevStepSizePvtTrack');
            if ~(isnumeric(cfg.SnrSettleThresholdDb) && ...
                    isreal(cfg.SnrSettleThresholdDb) && ...
                    isscalar(cfg.SnrSettleThresholdDb) && ...
                    isfinite(cfg.SnrSettleThresholdDb))
                obj.invalidField('SnrSettleThresholdDb');
            end
            if ~(isnumeric(cfg.SnrSettleAlpha) && isreal(cfg.SnrSettleAlpha) && ...
                    isscalar(cfg.SnrSettleAlpha) && ...
                    isfinite(cfg.SnrSettleAlpha) && cfg.SnrSettleAlpha > 0 && ...
                    cfg.SnrSettleAlpha <= 1)
                obj.invalidField('SnrSettleAlpha');
            end
            obj.requirePositiveInteger(cfg.SnrSettleMinBlock, ...
                'SnrSettleMinBlock');

            numericFields = setdiff(expected, {'Detector', 'VoterMode', ...
                'VoterDenominator', 'PiNonideal', 'FfeInitCoefficients', ...
                'FfeAdaptEnableMask', 'FfeGateMode', 'TransitionFilter', ...
                'FfeGateEnable', 'SettleGate', 'FfeGateCriterion'});
            for index = 1:numel(numericFields)
                field = numericFields{index};
                cfg.(field) = double(cfg.(field));
            end
        end

        function value = requireTextChoice(obj, value, field, choices)
            if isstring(value) && isscalar(value)
                value = char(value);
            end
            if ~(ischar(value) && isrow(value) && ~isempty(value))
                obj.invalidField(field);
            end
            value = lower(value);
            if ~any(strcmp(value, choices))
                obj.invalidField(field);
            end
        end

        function value = requireLogicalScalar(obj, value, field)
            valid = isscalar(value) && (islogical(value) || ...
                (isnumeric(value) && isreal(value) && isfinite(value) && ...
                (value == 0 || value == 1)));
            if ~valid
                obj.invalidField(field);
            end
            value = logical(value);
        end

        function value = requireDenominator(obj, value)
            if isstring(value) && isscalar(value)
                value = char(value);
            end
            if ischar(value) && isrow(value) && strcmpi(value, 'auto')
                value = 'auto';
                return;
            end
            if ~(isnumeric(value) && isreal(value) && isscalar(value) && ...
                    isfinite(value) && value > 0)
                obj.invalidField('VoterDenominator');
            end
            value = double(value);
        end

        function requirePositiveInteger(obj, value, field)
            if ~(isnumeric(value) && isreal(value) && isscalar(value) && ...
                    isfinite(value) && value >= 1 && value == fix(value))
                obj.invalidField(field);
            end
        end

        function requireNonnegativeInteger(obj, value, field)
            if ~(isnumeric(value) && isreal(value) && isscalar(value) && ...
                    isfinite(value) && value >= 0 && value == fix(value))
                obj.invalidField(field);
            end
        end

        function requireIntegerScalar(obj, value, field)
            if ~(isnumeric(value) && isreal(value) && isscalar(value) && ...
                    isfinite(value) && value == fix(value))
                obj.invalidField(field);
            end
        end

        function requirePositiveScalar(obj, value, field)
            if ~(isnumeric(value) && isreal(value) && isscalar(value) && ...
                    isfinite(value) && value > 0)
                obj.invalidField(field);
            end
        end

        function requireNonnegativeScalar(obj, value, field)
            if ~(isnumeric(value) && isreal(value) && isscalar(value) && ...
                    isfinite(value) && value >= 0)
                obj.invalidField(field);
            end
        end

        function requirePolarity(obj, value, field)
            if ~(isnumeric(value) && isreal(value) && isscalar(value) && ...
                    isfinite(value) && (value == 1 || value == -1))
                obj.invalidField(field);
            end
        end

        function invalidField(~, field)
            error(['cdr_top:Invalid' field], ...
                'config.%s has an invalid type or value.', field);
        end
    end
end
