classdef dlev_loop < handle
    % dlev_loop  按块处理的 PAM4 判决电平(dLev)自适应引擎。
    %
    % 调用方通过 dlevLms/dlevSsLms(或其 Fast 变体)一次喂入正好一个块的
    % 带符号判决 d 与判决误差 e = x - d:两者均为长度等于 BlockSize(默认
    % 64 UI)的向量,且都在 code 域。判决由 cdr 顶层用 dlev 维护的门限/电平
    % 统一完成(单判决器),再把 (d, e) 同时喂给 MMPD 与本环,保证两者使用
    % 完全一致的判决,本环不再自行切片。折叠误差 sign(d).*e 恒等于 |x|-|d|,
    % 即该样本对其所属电平的幅度误差,归属由 |d| 命中哪一环电平决定。
    %
    % 采用 ± 对称折叠的两环方案(方案 R):PAM4 的四个电平 ±1/±3 折叠为两个
    % 被跟踪的正幅度——内环 DLevInner(对应 |±1|)与外环 DLevOuter(对应
    % |±3|),负电平视为正电平的镜像。正侧判决门限取相邻电平中点
    % Threshold = (DLevInner + DLevOuter)/2,由类内自动维护;整条星座的三个
    % 门限即 {-Threshold, 0, +Threshold}。该结构与参考 RTL 及业界做法一致。
    %
    % 每调用一次就完成一次块更新:按 |d| 把样本归属到内/外环,各环用块平均
    % 更新项(÷BlockSize)分别移动其幅度,再刷新门限,返回更新后的
    % [DLevInner, DLevOuter]。dlevLms 用全精度折叠误差 sign(d).*e;dlevSsLms
    % 用其符号 sign(sign(d).*e)(对应 RTL 的 bang-bang)。
    %
    % Polarity(极性)为 +1/-1 的方向因子:当接收信号被反相时,环路修正方向
    % 需随之翻转才能继续收敛,该因子统一乘在两环的块更新量上,默认 +1(即
    % 保持原有行为)。
    %
    % Fast 变体只保留核心更新逻辑,不记录任何调试轨迹;正常版本调用对应的
    % Fast 变体完成更新,并额外追加内/外环幅度与各环误差均值轨迹,便于 debug。
    % NRZ 是单幅度的退化情形,可只用其中一环表示,由调用方负责电平路由。

    properties (SetAccess = private)
        StepSize            % mu,作用在两环块平均更新项上
        BlockSize = 64      % 每块样本数(UI),默认 64
        LevelsInner = 1     % 内环标称幅度(|±1|),reset 时恢复
        LevelsOuter = 3     % 外环标称幅度(|±3|),reset 时恢复
        Polarity = 1        % 极性方向因子(+1/-1),乘在两环块更新量上
        DLevInner           % 内环自适应幅度估计(对应 ±1)
        DLevOuter           % 外环自适应幅度估计(对应 ±3)
        Threshold           % 正侧判决门限 (DLevInner+DLevOuter)/2,内部维护
        DLevInnerTrace      % 每次块更新后的内环幅度(仅正常版本记录)
        DLevOuterTrace      % 每次块更新后的外环幅度(仅正常版本记录)
        ErrInnerTrace       % 每块内环幅度误差均值(仅正常版本记录)
        ErrOuterTrace       % 每块外环幅度误差均值(仅正常版本记录)
        UpdateCount = 0     % 已完成的块更新次数
    end

    methods
        function obj = dlev_loop(stepSize, blockSize, levelsInner, levelsOuter, polarity)
            % dlev_loop  构造一个按块处理的 PAM4 dLev 自适应引擎。
            if nargin < 1
                error('dlev_loop:MissingStepSize', 'stepSize must be provided explicitly.');
            end
            if nargin < 2
                blockSize = 64;
            end
            if nargin < 3
                levelsInner = 1;
            end
            if nargin < 4
                levelsOuter = 3;
            end
            if nargin < 5
                polarity = 1;
            end

            obj.StepSize = double(stepSize);
            obj.BlockSize = double(blockSize);
            obj.LevelsInner = double(levelsInner);
            obj.LevelsOuter = double(levelsOuter);
            obj.Polarity = double(polarity);
            obj.resetState();
        end

        function dLev = dlevLmsFast(obj, d, e)
            % dlevLmsFast  处理一块标准全精度 dLev LMS 样本(仅核心逻辑)。
            %
            % 输入为 cdr 顶层单判决器给出的带符号判决 d 与判决误差 e = x - d。
            % 逐样本更新项为折叠后的幅度误差 sign(d).*e(即 |x| - |d|),误差保留
            % 完整幅度。不记录任何调试轨迹。
            [innerErr, outerErr] = obj.sliceErrors(d, e);
            dLev = obj.applyUpdate(innerErr, outerErr);
        end

        function dLev = dlevSsLmsFast(obj, d, e)
            % dlevSsLmsFast  处理一块符号-符号 dLev LMS 样本(仅核心逻辑)。
            %
            % 逐样本更新项为 sign(sign(d).*e),只取更新方向,对应 RTL 的
            % bang-bang 累加。不记录任何调试轨迹。
            [innerErr, outerErr] = obj.sliceErrors(d, e);
            dLev = obj.applyUpdate(sign(innerErr), sign(outerErr));
        end

        function dLev = dlevLms(obj, d, e)
            % dlevLms  全精度 dLev LMS:调用 Fast 变体更新,并记录调试轨迹。
            [innerErr, outerErr] = obj.sliceErrors(d, e);
            dLev = obj.dlevLmsFast(d, e);
            obj.recordTrace(innerErr, outerErr);
        end

        function dLev = dlevSsLms(obj, d, e)
            % dlevSsLms  符号-符号 dLev LMS:调用 Fast 变体更新,并记录轨迹。
            [innerErr, outerErr] = obj.sliceErrors(d, e);
            dLev = obj.dlevSsLmsFast(d, e);
            obj.recordTrace(innerErr, outerErr);
        end

        function resetState(obj)
            % resetState  恢复标称幅度与门限,并清空轨迹。
            obj.DLevInner = obj.LevelsInner;
            obj.DLevOuter = obj.LevelsOuter;
            obj.Threshold = (obj.DLevInner + obj.DLevOuter) / 2;
            obj.DLevInnerTrace = [];
            obj.DLevOuterTrace = [];
            obj.ErrInnerTrace = [];
            obj.ErrOuterTrace = [];
            obj.UpdateCount = 0;
        end

        function state = getState(obj)
            % getState  返回配置、当前两环幅度、门限以及各条轨迹。
            state = struct();
            state.StepSize = obj.StepSize;
            state.BlockSize = obj.BlockSize;
            state.LevelsInner = obj.LevelsInner;
            state.LevelsOuter = obj.LevelsOuter;
            state.Polarity = obj.Polarity;
            state.DLevInner = obj.DLevInner;
            state.DLevOuter = obj.DLevOuter;
            state.Threshold = obj.Threshold;
            state.DLevInnerTrace = obj.DLevInnerTrace;
            state.DLevOuterTrace = obj.DLevOuterTrace;
            state.ErrInnerTrace = obj.ErrInnerTrace;
            state.ErrOuterTrace = obj.ErrOuterTrace;
            state.UpdateCount = obj.UpdateCount;
        end

        function setStepSize(obj, stepSize)
            % setStepSize  运行中切换 mu(学习率),用于两档 mu 换挡。
            %
            % 只改步长,不动两环幅度/门限/轨迹与更新计数,故换挡瞬间自适应
            % 状态连续,仅后续块的更新增益改变。捕获档用大 mu 快速逼近真值,
            % 相位环锁定后切到稳态档小 mu 压低稳态抖动。
            if ~(isscalar(stepSize) && isnumeric(stepSize) && stepSize > 0)
                error('dlev_loop:InvalidStepSize', ...
                    'stepSize must be a positive scalar.');
            end
            obj.StepSize = double(stepSize);
        end
    end

    methods (Access = private)
        function [innerErr, outerErr] = sliceErrors(obj, d, e)
            % sliceErrors  用 cdr 顶层判决 (d, e) 给出内/外环的折叠幅度误差。
            %
            % 归属由带符号判决 d 的幅度命中哪一环电平决定:|d| == DLevInner 归
            % 内环,|d| == DLevOuter 归外环(d 只会取 ±DLevInner/±DLevOuter)。
            % 折叠误差 sign(d).*e 恒等于 |x| - |d|,即该样本对其电平的幅度误差;
            % 环外样本置零,故 innerErr 与 outerErr 互补且逐样本至多一个非零。
            isInner = abs(d) == obj.DLevInner;
            isOuter = abs(d) == obj.DLevOuter;
            foldedErr = sign(d) .* e;
            innerErr = foldedErr .* isInner;
            outerErr = foldedErr .* isOuter;
        end

        function dLev = applyUpdate(obj, innerTerm, outerTerm)
            % applyUpdate  用两环各自的块平均更新项移动幅度并刷新门限。
            %
            % 两个变体共用的块更新逻辑;dlevLmsFast 与 dlevSsLmsFast 之间只有
            % 更新项算法不同(全精度误差 vs 其符号)。每环按 StepSize 乘以块
            % 平均更新项(÷BlockSize),再乘以极性因子 Polarity 移动一次幅度,
            % 最后重算判决门限。极性用于在信号反相时翻转修正方向以保证收敛。
            gradInner = sum(innerTerm) / obj.BlockSize;
            gradOuter = sum(outerTerm) / obj.BlockSize;

            obj.DLevInner = obj.DLevInner + obj.StepSize * obj.Polarity * gradInner;
            obj.DLevOuter = obj.DLevOuter + obj.StepSize * obj.Polarity * gradOuter;
            obj.Threshold = (obj.DLevInner + obj.DLevOuter) / 2;
            obj.UpdateCount = obj.UpdateCount + 1;

            dLev = [obj.DLevInner, obj.DLevOuter];
        end

        function recordTrace(obj, innerErr, outerErr)
            % recordTrace  追加内/外环幅度与各环误差均值轨迹(仅正常版本调用)。
            %
            % 内/外环误差均值分别记录,分母统一用 BlockSize(与梯度口径一致,
            % 便于直接反推该环的块平均更新量);两条轨迹与 DLev 轨迹一一对应。
            obj.DLevInnerTrace(end + 1) = obj.DLevInner;
            obj.DLevOuterTrace(end + 1) = obj.DLevOuter;
            obj.ErrInnerTrace(end + 1) = sum(innerErr) / obj.BlockSize;
            obj.ErrOuterTrace(end + 1) = sum(outerErr) / obj.BlockSize;
        end
    end
end
