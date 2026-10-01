classdef cdr_voter < handle
%CDR_VOTER 块内 PD 判决归约（定点版）。
%
%   与浮点参考 src/CDR/cdr_voter.m 的差别只有一处结构性改动：
%   **除法被消掉了**。
%
%   浮点版的 'mean' 模式做 sum/denominator，且默认 denominator='auto' 取
%   numel(phaseDecision) —— 块长相关的除数在 RTL 里不可实现。本类直接输出整数
%   求和，把 1/BlockSize 折进下游 cdr_loop 的 Kp/Ki：
%
%       Kp: 8.0  -> 8.0/64  = 0.125
%       Ki: 0.03 -> 0.03/64 = 4.6875e-4
%
%   这是严格等价变换，省掉一个除法器。实测佐证：浮点 phaseError 范围
%   -0.219..+0.188，乘回 64 得 -14..+12，与每块有效跳变数 0..22 同量级。
%
%   注意每块跳变数**最小值为 0**（存在零事件的块）。浮点版靠除法的自然行为把
%   这种块变成 0，定点版必须显式处理，见 voteFast 里的说明。

    properties (SetAccess = private)
        BlockSize       double
        OutFormat       struct
        OverflowCount   double
        LastSum         double
    end

    methods
        function obj = cdr_voter(blockSize)
            %CDR_VOTER 构造定点 voter。
            %   只保留块长一个参数：'linear'/'constant'/'mean' 三种模式在定点
            %   模型里已无意义 —— 求和就是求和，定标统一由下游增益承担。
            if nargin < 1 || isempty(blockSize)
                blockSize = 64;
            end
            if ~isnumeric(blockSize) || ~isscalar(blockSize) || ...
                    ~isfinite(blockSize) || blockSize <= 0 || ...
                    blockSize ~= floor(blockSize)
                error('cdr_fx:cdr_voter:InvalidBlockSize', ...
                    'blockSize 必须是正整数。');
            end
            obj.BlockSize = double(blockSize);
            obj.OutFormat = cdr_fx.fxfmt.phaseError();
            obj.resetState();
        end

        function phaseError = voteFast(obj, phaseDecision)
            %VOTEFAST 块内求和，不做输入校验。
            %
            %   phaseDecision 取值必须是 -1/0/+1。求和结果天然是整数，因此量化
            %   是空操作，只有饱和可能生效：块长 64 时理论极值 ±64，正好用满
            %   s(1,7,0) 的 -64..63，+64 会被钳到 63。实测范围 -14..+12，余量充足。
            if isempty(phaseDecision)
                % 零事件块：显式产出 0，不依赖除法的自然行为。
                phaseError = 0;
                obj.LastSum = 0;
                return;
            end
            raw = sum(double(phaseDecision(:)));
            obj.LastSum = raw;
            [phaseError, nOv] = cdr_fx.fxq.sat(raw, obj.OutFormat);
            obj.OverflowCount = obj.OverflowCount + nOv;
        end

        function phaseError = vote(obj, phaseDecision)
            %VOTE 带校验的入口。数值与 voteFast 完全一致。
            if ~isnumeric(phaseDecision) && ~islogical(phaseDecision)
                error('cdr_fx:cdr_voter:InvalidPhaseDecision', ...
                    'phaseDecision 必须是数值或逻辑数组。');
            end
            v = double(phaseDecision(:));
            if ~isempty(v) && (~all(isfinite(v)) || ~all(ismember(v, [-1 0 1])))
                error('cdr_fx:cdr_voter:InvalidPhaseDecision', ...
                    'phaseDecision 只能取 -1/0/+1。');
            end
            phaseError = obj.voteFast(phaseDecision);
        end

        function resetState(obj)
            %RESETSTATE 清空统计量。本类无跨块状态。
            obj.OverflowCount = 0;
            obj.LastSum = 0;
        end

        function s = getState(obj)
            %GETSTATE 只读快照。
            s = struct( ...
                'BlockSize', obj.BlockSize, ...
                'OutFormat', obj.OutFormat, ...
                'LastSum', obj.LastSum, ...
                'OverflowCount', obj.OverflowCount);
        end
    end
end
