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
            % Stage-1 (capture -> settle) mu-downshift gate: the averaged
            % decision-directed eye SNR crossing SnrSettleThresholdDb. The eye
            % being open is the actual precondition for slowing the FFE. (A
            % legacy outer-dLev displacement gate was removed on 2026-09-26; it
            % was an implicit drift-rate threshold that a slowly ramping dLev
            % satisfied while the eye was still closed.)
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
            % 以下三项只配置 loop_monitor 内部那台 center-touch 检测器,而
            % cdr_top 自 2026-09-28 起再也不调 updateFfeGate,所以它们对本类
            % 的行为没有任何影响。保留而不是删除的原因有二:loop_monitor 的
            % 构造器要求这三个位置参数;v4 runner、ppm runner 与
            % test_cdr_top_configured 目前都还在写这三个字段,删掉会同时改到
            % 三处调用方的选项面。注意离线回放(make_ppm_stage_eyes /
            % write_ppm_lock_summary_txt)另建自己的 loop_monitor,用的是
            % result.RunOptions.FfeFreeze*,而不是这里的值。
            cfg.FfeGateMinModeOccurrences = 500;
            cfg.FfeGateMinEvents = 100;
            cfg.FfeGateBandHalfWidth = 3;
            cfg.FfeGateStartBlock = 1;
            % 第二级降档的门控判据。唯一判据为 'freq-state'：用环路积分频率态的
            % 平坦性判据，与离线 loop_monitor.detectFrequencyStateLock 同源，在
            % 任意 ppm(含 0)下都成立。历史上的码域众数 'center-touch' 判据已于
            % 2026-09-28 从 cdr_top 删除：0 ppm 下 freq-state 与它 32/32 一致，
            % 有 ppm 时 center-touch 因 PI code 持续爬升永不触发。loop_monitor
            % 仍保留 updateFfeGate 供旧 MAT 的离线回放，cdr_top 不再选用它。
            cfg.FfeGateCriterion = 'freq-state';
            cfg.FfeGateFreqWindowBlocks = 2000;
            cfg.FfeGateFreqExpectedRate = NaN;
            cfg.FfeGateFreqMeanHalfDiffTol = 1e-3;
            cfg.FfeGateFreqStdTol = 5e-3;
            cfg.FfeGateFreqRateTol = Inf;
            cfg.FfeGateFreqMinBlock = 1;
            % 饱和守卫。撞在 ±FrequencyLimit 上的积分频率态是"完美平坦"的
            % (半差=0、std=0)，而默认口径是纯平坦性(ExpectedRate=NaN /
            % RateTol=Inf)，detectFrequencyStateLock 会把它判成锁定——但那是
            % railed 而不是锁定，此时眼睛通常还没开、环路根本没在跟踪。门控
            % 因此拒绝把 |FrequencyState| >= FfeGateFreqSatFrac*FrequencyLimit
            % 的块喂进判决窗口。设 >1 可关闭；FrequencyLimit=Inf 时自动失效。
            cfg.FfeGateFreqSatFrac = 0.9;
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
            %GATELATCHED 第二级门控(freq-state)是否已闩锁。
            %
            % freq-state 的闩锁是 FreqGateDone。'freeze' 模式的 FFE 写抑制和
            % GateEngaged 报告都依赖它。(历史上 center-touch 判据闩锁读的是
            % Monitor.Frozen，该判据已从 cdr_top 删除。)
            if obj.Config.FfeGateEnable
                latched = obj.Monitor.FreqGateDone;
            else
                latched = false;
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
                cfg.FfeGateBandHalfWidth, cfg.FfeGateStartBlock);
            obj.Monitor.enableSnrSettle(cfg.SnrSettleThresholdDb, ...
                cfg.SnrSettleAlpha, cfg.SnrSettleMinBlock);
            % FfeGateCriterion 目前只接受 'freq-state' 这一个值(见
            % validateConfig 的 requireTextChoice)，所以这里的 strcmp 恒真。
            % 刻意保留而不是简化成 if cfg.FfeGateEnable:它是判据的显式接入
            % 点，将来再加一种判据时只需在这里分支，不必重新推导语义。
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

            % ValidMask 与数据数组的长度契约(容易读错,这里写死):
            % blockValid 始终是 BlockSize 长的整块掩码,标出这一块里哪些槽位
            % 产生了有效输出;而 ffeOutput 以及由它派生的 Decision /
            % SliceError / DataSymbol / ErrorBit 等**已经按该掩码筛过**,因此
            % 在流水线未填满的块上比掩码短(6 抽头 FFE 的首块是 64 -> 61)。
            % 也就是说 Decision 与 ValidMask 是"已筛数据 + 槽位说明",不要再
            % 做 Decision(ValidMask) 这种二次索引。稳态块两者等长。
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

            % 这里及下面几处一律走 Fast 变体：输入全部由本类自己刚生成
            % (phaseDecision 来自上面的 mmpdFast/bbpdFast，只可能是 -1/0/+1)，
            % 非 Fast 版本唯一多做的就是再校验一遍这些数据。顶层对 PD 早已
            % 采用同样的约定。
            phaseError = obj.Voter.voteFast(phaseDecision);
            deltaCode = obj.LoopFilter.update(phaseError);
            obj.PhaseInterpolator.update(deltaCode);

            % 策略判决全部委托给 loop_monitor：它只判决，由本类施加动作。
            % 第一级降档(capture -> settle)：两个环路同时降，门控为 SNR EWMA
            % 越过 SnrSettleThresholdDb（眼睛张开才降 mu）。
            snrDb = cdr_top.blockSnrDb(decision, sliceError);
            eyeOpenedEvent = obj.Monitor.updateSnrSettle(blockIndex, snrDb);
            if eyeOpenedEvent && ~obj.gateLatched()
                % 只在第二级门控尚未闩锁时才降第一级。两级都是一次性闩锁且
                % stage-1 在本函数里先执行，若 stage-2 曾在更早的块先触发，
                % 这里再施加 settle 档会把已降到 PVT 档的步长抬回去(0.02 ->
                % 0.1)，调度反向。同块内两者都触发时 stage-2 在后覆盖，仍是
                % 正确的终态。
                obj.Dlev.setStepSize(cfg.DlevStepSizeSettle);
                obj.FfeLoop.setStepSize(cfg.FfeStepSizeSettle);
            end

            if numel(ffeOutput) == cfg.BlockSize
                % Fast 变体：非 Fast 版本只多记 4 条调试轨迹(每块 4 次
                % end+1 的数组增长)，而本类从不读它们，且其中的 dLev 两条
                % 与下面 output.DlevInner/DlevOuter 完全重复。长跑时那是
                % 无界增长。需要轨迹的调用方直接驱动 dlev_loop 即可。
                obj.Dlev.dlevSsLmsFast(decision, sliceError);
            end

            loopLockedEvent = false;
            if cfg.FfeGateEnable
                % 门控判据只有 freq-state。环路滤波器已在本块更新过(见上方
                % LoopFilter.update)，因此这里读到的积分频率态与随后记录进
                % trace 的 LoopFrequencyState 是同一个值，在线判定与离线判据
                % 逐块对齐。
                freqState = obj.LoopFilter.FrequencyState;
                % 饱和守卫(定义见 defaultConfig 的 FfeGateFreqSatFrac)：钳在
                % 积分限幅上的频率态是平坦的，但那是 railed 而非锁定。把这种
                % 块排除出门控窗口，否则纯平坦口径会误闩锁，进而过早把
                % dLev/FFE 降到 PVT 档且再也追不回来。与 updateFreqStateGate
                % 跳过非有限样本是同一性质的输入过滤。
                if abs(freqState) < cfg.FfeGateFreqSatFrac * cfg.FrequencyLimit
                    loopLockedEvent = obj.Monitor.updateFreqStateGate( ...
                        blockIndex, freqState);
                end
                if loopLockedEvent
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
                % Fast 变体：blockRegressor 是 Ffe 刚返回的 BlockSize x
                % TapCount double 矩阵，errorBlock 是等长 double 行向量
                % (进入本分支的前提就是 numel(ffeOutput)==BlockSize，即这一
                % 块没有任何样本被 blockValid 滤掉)，Fast 版所要求的形状前提
                % 在此处恒成立。非 Fast 版另外维护的 LastGradient/LastDelta/
                % UpdateCount 只是诊断量，本类与任何 runner 都不读。
                rawDelta = obj.FfeLoop.updateSsLmsFast(blockRegressor, errorBlock);
                % 主抽头保持固定的单位增益锚点。FfeAdaptEnableMask 默认
                % [1 1 0 1 1 1]，updateSsLms 已按 mask 把这一项清零，所以这
                % 一行在默认配置下是冗余的；保留它是因为 mask 由配置提供，
                % 而 cdr_ffe.applyCoefficientDelta 会拒绝非零的主抽头增量
                % (cdr_ffe:MainTapUpdate)。它是本层对该不变量的兜底。
                rawDelta(obj.Ffe.MainTapIndex) = 0;
                proposedCoefficients = obj.Ffe.Coefficients + rawDelta;
                adaptationCalculated = true;
                if ~obj.gateLatched() || ~gateInhibitsWrite
                    obj.Ffe.applyCoefficientDelta(rawDelta);
                    appliedDelta = rawDelta;
                    writeApplied = true;
                end
            end

            obj.BlockIndex = blockIndex;
            % 一次 struct(...) 构造输出,而不是 38 次 output.<field> 增量赋值:
            % 每加一个字段都要重排结构体的字段表,逐字段写是 O(nField^2)。
            % 子模块句柄也先取进局部变量,省掉几十次 obj.X.Y 两级查找。
            % 字段名与顺序必须与 emptyConfiguredOutput 严格一致,否则两种
            % 输出拼不进同一个 struct 数组。
            phaseInterp = obj.PhaseInterpolator;
            obj.CurrentLocalIndexFloat = phaseInterp.getLocalIndex();
            loopFilter = obj.LoopFilter;
            dlev = obj.Dlev;
            monitor = obj.Monitor;
            % 环路滤波器的亚码连续量：LoopControl 是量化前的相位速度需求
            % (code/block)，LoopFrequencyState 是积分态。整数 PI code 会把
            % 亚码运动藏起来，这两个量用于区分"真抖动"与"缓慢漂移"。
            output = struct( ...
                'HasOutput', true, ...
                'BlockIndex', blockIndex, ...
                'SampleCodeWrapped', codeWrapped, ...
                'SampleUiSlip', uiSlip, ...
                'UnwrappedCode', uiSlip * cfg.SamplesPerSymbol + codeWrapped, ...
                'FfeOutput', ffeOutput, ...
                'ValidMask', blockValid, ...
                'Decision', decision, ...
                'SliceError', sliceError, ...
                'DataSymbol', dataSymbol, ...
                'ErrorBit', errorBit, ...
                'PhaseDecision', phaseDecision, ...
                'ValidTransition', validTransition, ...
                'PhaseError', phaseError, ...
                'DeltaCode', deltaCode, ...
                'LoopControl', loopFilter.LastControl, ...
                'LoopFrequencyState', loopFilter.FrequencyState, ...
                'LoopCodeResidue', loopFilter.CodeResidue, ...
                'LoopPendingCode', loopFilter.PendingCode, ...
                'NextCodeWrapped', phaseInterp.CodeWrapped, ...
                'NextUiSlip', phaseInterp.UiSlip, ...
                'DlevInner', dlev.DLevInner, ...
                'DlevOuter', dlev.DLevOuter, ...
                'DlevThreshold', dlev.Threshold, ...
                'FfeCoefficients', obj.Ffe.Coefficients, ...
                'FfeRawDelta', rawDelta, ...
                'FfeAppliedDelta', appliedDelta, ...
                'FfeProposedCoefficients', proposedCoefficients, ...
                'FfeAdaptationCalculated', adaptationCalculated, ...
                'FfeWriteApplied', writeApplied, ...
                'LoopLockedEvent', loopLockedEvent, ...
                'GateEngaged', obj.gateLatched(), ...
                'SnrDb', snrDb, ...
                'SnrEwmaDb', monitor.SnrEwmaDb, ...
                'SnrSettleDone', monitor.SnrSettleDone, ...
                'SnrSettleBlock', monitor.SnrSettleBlock, ...
                'DlevStepSize', dlev.StepSize, ...
                'FfeStepSize', obj.FfeLoop.StepSize);
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
            output.LoopLockedEvent = false;
            output.GateEngaged = obj.gateLatched();
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
                {'freq-state'});
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
            obj.requirePositiveScalar(cfg.FfeGateFreqSatFrac, ...
                'FfeGateFreqSatFrac');
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
                'FfeGateEnable', 'FfeGateCriterion'});
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
