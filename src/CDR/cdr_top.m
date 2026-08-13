classdef cdr_top < handle
    % cdr_top  以并行 block 为更新单位的数字 CDR 顶层行为模型。
    %
    % 本类负责把已经完成建模的 CDR 子模块串接为一条闭环数字控制链：
    %
    %   data/edge 数字判决
    %       -> cdr_pd（逐 UI 产生 early/late 判决）
    %       -> cdr_voter（一个 block 聚合为一次相位误差）
    %       -> cdr_loop（生成整数 PI code 增量）
    %       -> cdr_pi（更新下一 block 使用的采样相位）
    %
    % 顶层的主要职责不是重复各子模块内部算法，而是统一管理：
    %   1. block 之间的 previous-symbol 重叠状态；
    %   2. PD、voter、loop filter 和 PI 的调用顺序；
    %   3. “当前 block 使用旧相位、更新后相位供下一 block 使用”的时序；
    %   4. 调试路径和 BER/长序列 fast 路径的一致状态推进；
    %   5. 所有动态子模块的同步复位。
    %
    % 建模边界：
    %   - dataCurrBlock 和 edgeBitBlock 必须是上游 slicer 输出的数字码；
    %   - 均衡、独立 CDR FFE、模拟波形采样、ADC 量化和 slicer 不属于本类；
    %   - 默认一个顶层调用对应一个 voter block，block 长度由 Voter.BlockSize
    %     决定，当前工程常用配置为 64 UI/block；
    %   - PI 输出为浮点 waveform sample index 偏移；具体采用 round、floor
    %     或插值由下游 sampler 决定。

    properties (SetAccess = private)
        % Pd  数字相位检测器对象，类型必须为 cdr_pd。
        % 输入 D[n-1]、E[n]、D[n]，逐 UI 输出 {-1,0,+1} 相位判决。
        Pd

        % Voter  block voter 对象，类型必须为 cdr_voter。
        % 将一个 block 内的逐 UI 相位判决聚合为一个 phaseError。
        Voter

        % LoopFilter  比例-积分环路滤波器对象，类型必须为 cdr_loop。
        % 每个 block 更新一次，输出整数 PI code 增量 deltaCode。
        LoopFilter

        % PhaseInterpolator  相位插值器对象，类型必须为 cdr_pi。
        % 负责 PI code 累加、code wrap、UI slip 和 sample index LUT 映射。
        PhaseInterpolator

        % PreviousSymbol  上一个 block 最后一个 data symbol 的数字码。
        % 下一 block 构造 D[n-1] 时，将该值放在 dataPrevBlock 首元素。
        % NRZ 合法范围为 0~1，PAM4 合法范围为 0~3。
        PreviousSymbol

        % BlockIndex  已完成处理的 block 数量，从 0 开始累计。
        % processBlock/processBlockFast 成功完成一次后递增 1。
        BlockIndex = 0

        % CurrentLocalIndexFloat  下一个待处理 block 应使用的本地 PI 相位。
        % 单位为 waveform sample index，可为小数，只表示当前 UI 内的 wrapped
        % 相位；跨 UI 的累计滑移量由 PhaseInterpolator.UiSlip 单独保存。
        CurrentLocalIndexFloat = 0

        % LastOutput  最近一次 processBlock 调试路径的完整输出快照。
        % processBlockFast 为减少热路径开销，刻意不更新该结构体。
        LastOutput
    end

    methods
        function obj = cdr_top(pd, voter, loopFilter, phaseInterpolator, initialSymbol)
            % cdr_top  使用已经配置好的四个子模块构造 CDR 顶层。
            %
            % 输入：
            %   pd                - cdr_pd 对象，决定 NRZ/PAM4 模式和极性；
            %   voter             - cdr_voter 对象，决定 block 长度和投票模式；
            %   loopFilter        - cdr_loop 对象，包含 Kp/Ki 和积分限幅；
            %   phaseInterpolator - cdr_pi 对象，包含 PI 位宽、LUT 和非理想配置；
            %   initialSymbol     - 第一个 block 之前的真实历史 symbol。
            %
            % 顶层直接持有调用方传入的 handle 对象，不复制配置。构造末尾调用
            % resetState，使 PD/loop/PI 动态状态和顶层 previous-symbol 状态从
            % 同一个明确的初始条件开始。
            if nargin < 5
                error('cdr_top:MissingInput', ...
                    ['pd, voter, loopFilter, phaseInterpolator, and ' ...
                    'initialSymbol must be provided.']);
            end

            obj.validateComponents(pd, voter, loopFilter, phaseInterpolator);
            obj.Pd = pd;
            obj.Voter = voter;
            obj.LoopFilter = loopFilter;
            obj.PhaseInterpolator = phaseInterpolator;
            obj.resetState(initialSymbol);
        end

        function output = processBlock(obj, dataCurrBlock, edgeBitBlock)
            % processBlock  检查并处理一个完整的数字判决 block（调试路径）。
            %
            % 输入：
            %   dataCurrBlock - 当前 block 的 data symbol 判决向量；NRZ 为 0/1，
            %                   PAM4 为 0/1/2/3，长度必须为 Voter.BlockSize；
            %   edgeBitBlock  - 与 dataCurrBlock 同尺寸、同方向的中心阈值 edge
            %                   判决向量，每个元素为 0/1。
            %
            % 时序约定非常重要：
            %   sampleIndexForBlock 在进入本函数时立即保存，它代表“产生本 block
            %   data/edge 判决时已经使用的 PI 相位”。随后本 block 的相位误差经过
            %   voter 和 loop filter 更新 PI；更新结果 NextLocalIndexFloat 只能用于
            %   下一 block，不能反过来影响已经获得的当前 block 判决。
            %
            % 本路径执行完整输入检查，并返回 PD 详细调试结构 PdOutput；适用于
            % 单步调试、波形验证和回归测试。长 BER 仿真优先使用 processBlockFast。
            obj.validateBlockShape(dataCurrBlock, edgeBitBlock);

            % cdr_pd 本身不保存跨 block 的 D[n-1]。这里将顶层保存的上一 symbol
            % 与当前 block 内部移位后的 data symbol 组合成完整 dataPrevBlock。
            dataPrevBlock = obj.buildPreviousBlock(dataCurrBlock);

            % 保存进入 block 时的相位和历史 symbol，防止后续状态更新覆盖调试信息。
            sampleIndexForBlock = obj.CurrentLocalIndexFloat;
            previousSymbolIn = obj.PreviousSymbol;

            % 逐级执行数字 CDR 控制链。phaseDecision/valid 与 data block 等长；
            % phaseError 和 deltaCode 每个 block 只产生一个标量。
            [phaseDecision, valid, pdOutput] = obj.Pd.bbpd( ...
                dataPrevBlock, edgeBitBlock, dataCurrBlock);
            phaseError = obj.Voter.vote(phaseDecision);
            deltaCode = obj.LoopFilter.update(phaseError);
            obj.PhaseInterpolator.update(deltaCode);

            % PI 更新后的本地 index 作为下一 block 的采样相位。与此同时保存当前
            % block 最后一个 symbol，供下一次调用构造跨 block 的首个 D[n-1]。
            obj.CurrentLocalIndexFloat = ...
                obj.PhaseInterpolator.getLocalIndex();
            obj.PreviousSymbol = dataCurrBlock(end);
            obj.BlockIndex = obj.BlockIndex + 1;

            % 输出同时包含当前 block 的输入/判决、控制量以及 PI 更新后状态，便于
            % 验证调用时序。SampleIndexForBlock 与 NextLocalIndexFloat 分别对应
            % 更新前和更新后相位，二者不能混用。
            output = struct();
            output.BlockIndex = obj.BlockIndex;
            % 本 block 已经使用的 wrapped 浮点采样 index。
            output.SampleIndexForBlock = sampleIndexForBlock;
            % 构造本 block D[n-1] 时使用的跨 block 历史 symbol。
            output.PreviousSymbolIn = previousSymbolIn;
            % 实际送入 PD 的 D[n-1]、D[n] 和 E[n] 数字向量。
            output.DataPrevBlock = dataPrevBlock;
            output.DataCurrBlock = dataCurrBlock;
            output.EdgeBitBlock = edgeBitBlock;
            % 逐 UI BBPD 判决及其有效标志；无效/未选 transition 的判决为 0。
            output.PhaseDecision = phaseDecision;
            output.Valid = valid;
            % voter 聚合结果和 loop filter 产生的整数 PI code 增量。
            output.PhaseError = phaseError;
            output.DeltaCode = deltaCode;
            % 更新后、供下一 block 使用的 wrapped 浮点采样 index。
            output.NextLocalIndexFloat = obj.CurrentLocalIndexFloat;
            % 更新后的 PI wrapped code 和累计整 UI slip，便于观察跨 UI 行为。
            output.PiCodeWrapped = obj.PhaseInterpolator.CodeWrapped;
            output.PiUiSlip = obj.PhaseInterpolator.UiSlip;
            % cdr_pd 调试路径返回的完整内部判决快照。
            output.PdOutput = pdOutput;

            % 仅调试路径保留完整输出，避免 fast 路径每 block 分配大型结构体。
            obj.LastOutput = output;
        end

        function [sampleIndexForBlock, nextLocalIndexFloat, ...
                phaseError, deltaCode] = processBlockFast( ...
                obj, dataCurrBlock, edgeBitBlock)
            % processBlockFast  处理一个由调用方保证合法的数字判决 block。
            %
            % 调用前提：
            %   - dataCurrBlock/edgeBitBlock 均为合法数字向量；
            %   - 两者尺寸和方向一致，元素数等于 Voter.BlockSize；
            %   - symbol/edge 码值满足当前 PD 模式，不包含 NaN/Inf。
            %
            % 为降低长 BER 仿真的每 block 开销，本路径不调用 validateBlockShape，
            % 且分别调用各子模块的 Fast 接口。它只返回 sampler/控制循环所需的
            % 四个标量，不构造 PdOutput，也不更新顶层 LastOutput。
            %
            % 返回值：
            %   sampleIndexForBlock - 当前 block 使用的更新前本地采样 index；
            %   nextLocalIndexFloat - PI 更新后供下一 block 使用的本地采样 index；
            %   phaseError          - voter 的 block 聚合结果；
            %   deltaCode           - loop filter 输出的整数 PI code 增量。
            dataPrevBlock = obj.buildPreviousBlock(dataCurrBlock);
            sampleIndexForBlock = obj.CurrentLocalIndexFloat;

            % Fast 路径与 processBlock 保持完全相同的模块顺序和 block 时序。
            [phaseDecision, ~] = obj.Pd.bbpdFast( ...
                dataPrevBlock, edgeBitBlock, dataCurrBlock);
            phaseError = obj.Voter.voteFast(phaseDecision);
            deltaCode = obj.LoopFilter.updateFast(phaseError);
            nextLocalIndexFloat = ...
                obj.PhaseInterpolator.updateFast(deltaCode);

            % 虽然省略调试结构，影响闭环后续行为的动态状态仍必须完整推进。
            obj.CurrentLocalIndexFloat = nextLocalIndexFloat;
            obj.PreviousSymbol = dataCurrBlock(end);
            obj.BlockIndex = obj.BlockIndex + 1;
        end

        function resetState(obj, initialSymbol)
            % resetState  同步复位所有 CDR 动态状态并设置首 block 历史码元。
            %
            % initialSymbol 不是任意占位值，而是第一个待处理 block 之前的真实
            % data symbol 判决。显式传入它可以保证第一个 UI 的 transition 不会因
            % 缺少 D[n-1] 而丢失或产生伪判决。
            %
            % 复位只清除动态状态，不改变各子模块配置：PD 模式/极性、voter 模式、
            % Kp/Ki、积分限幅、PI 位宽和相位非理想 LUT 均保持不变。
            obj.validateInitialSymbol(initialSymbol);

            % voter 是无状态 block 聚合器，因此无需单独 reset。
            obj.Pd.resetState();
            obj.LoopFilter.resetState();
            obj.PhaseInterpolator.resetState();

            % 顶层调度状态与 PI 复位后的本地 index 同步回到初始状态。
            obj.PreviousSymbol = initialSymbol;
            obj.BlockIndex = 0;
            obj.CurrentLocalIndexFloat = ...
                obj.PhaseInterpolator.getLocalIndex();
            obj.LastOutput = struct();
        end

        function state = getState(obj)
            % getState  返回顶层调度状态和有状态子模块的完整调试快照。
            %
            % 该接口用于回归、调试和 trace，不建议在长 BER 主循环中每个 block
            % 调用，因为 cdr_pi.getState 会包含相位表等较大的派生数据。
            % Voter 本身无跨 block 动态状态，因此这里不重复生成 voter state。
            state = struct();
            state.BlockIndex = obj.BlockIndex;
            state.PreviousSymbol = obj.PreviousSymbol;
            state.CurrentLocalIndexFloat = obj.CurrentLocalIndexFloat;
            state.LastOutput = obj.LastOutput;
            state.Pd = obj.Pd.getState();
            state.LoopFilter = obj.LoopFilter.getState();
            state.PhaseInterpolator = obj.PhaseInterpolator.getState();
        end
    end

    methods (Access = private)
        function dataPrevBlock = buildPreviousBlock(obj, dataCurrBlock)
            % buildPreviousBlock  构造与 D[n] 对齐的 D[n-1] block。
            %
            % 对当前 block：
            %   Dprev(1)     = 上一个 block 保存的最后一个 symbol；
            %   Dprev(2:end) = Dcurr(1:end-1)。
            %
            % 显式区分行/列向量，保证输出方向与输入完全一致，从而满足 cdr_pd
            % 对 dataPrev、edgeBit、dataCurr 三者 same-size 的接口要求。
            if isrow(dataCurrBlock)
                dataPrevBlock = [obj.PreviousSymbol, dataCurrBlock(1:end - 1)];
            else
                dataPrevBlock = [obj.PreviousSymbol; dataCurrBlock(1:end - 1)];
            end
        end

        function validateBlockShape(obj, dataCurrBlock, edgeBitBlock)
            % validateBlockShape  检查顶层 validated 路径的单 block 结构约定。
            %
            % 这里只检查数据类型、实数性、向量形状、block 长度及两个输入的尺寸
            % 一致性。具体 symbol/edge 码值合法性由 cdr_pd.bbpd 继续检查，避免在
            % 顶层复制 NRZ/PAM4 模式相关规则。
            if ~(isnumeric(dataCurrBlock) || islogical(dataCurrBlock)) || ...
                    ~isreal(dataCurrBlock) || ~isvector(dataCurrBlock) || ...
                    numel(dataCurrBlock) ~= obj.Voter.BlockSize
                error('cdr_top:InvalidDataBlock', ...
                    ['dataCurrBlock must be a real vector with ' ...
                    'Voter.BlockSize elements.']);
            end
            if ~(isnumeric(edgeBitBlock) || islogical(edgeBitBlock)) || ...
                    ~isreal(edgeBitBlock) || ~isvector(edgeBitBlock) || ...
                    ~isequal(size(edgeBitBlock), size(dataCurrBlock))
                error('cdr_top:InvalidEdgeBlock', ...
                    ['edgeBitBlock must be a real vector with the same ' ...
                    'size and orientation as dataCurrBlock.']);
            end
        end

        function validateInitialSymbol(obj, initialSymbol)
            % validateInitialSymbol  检查首 block 之前的显式历史 symbol。
            %
            % initialSymbol 必须是有限实整数标量；合法码值范围随 Pd.Mode 变化：
            % NRZ 使用 0/1，PAM4 使用 0/1/2/3。这里提前检查可避免 reset 之后才在
            % 第一次 PD 调用中暴露不合法的跨 block 状态。
            if ~isnumeric(initialSymbol) || ~isreal(initialSymbol) || ...
                    ~isscalar(initialSymbol) || ~isfinite(initialSymbol) || ...
                    initialSymbol ~= round(initialSymbol)
                error('cdr_top:InvalidInitialSymbol', ...
                    'initialSymbol must be a finite integer scalar.');
            end

            if strcmp(obj.Pd.Mode, 'nrz')
                isValid = initialSymbol >= 0 && initialSymbol <= 1;
            else
                isValid = initialSymbol >= 0 && initialSymbol <= 3;
            end
            if ~isValid
                error('cdr_top:InvalidInitialSymbol', ...
                    'initialSymbol is invalid for the configured PD mode.');
            end
        end

        function validateComponents(~, pd, voter, loopFilter, phaseInterpolator)
            % validateComponents  确认顶层接入的是当前工程定义的四类 CDR 对象。
            %
            % 使用明确 isa 检查，而不是仅检查同名方法，可以尽早发现错误接线，
            % 并确保 processBlock/processBlockFast 所依赖的属性和状态语义一致。
            if ~isa(pd, 'cdr_pd') || ~isa(voter, 'cdr_voter') || ...
                    ~isa(loopFilter, 'cdr_loop') || ...
                    ~isa(phaseInterpolator, 'cdr_pi')
                error('cdr_top:InvalidComponent', ...
                    ['Components must be cdr_pd, cdr_voter, cdr_loop, ' ...
                    'and cdr_pi objects.']);
            end
        end
    end
end
