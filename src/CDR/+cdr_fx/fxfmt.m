classdef fxfmt
%FXFMT 定点格式注册表。docs/CDR_FIXED_POINT.md §4 的可执行版本。
%
%   所有定点类的格式都从这里取，不在各自文件里硬编码。这样"文档 → 代码"只有
%   一条路径：改格式先改 docs/CDR_FIXED_POINT.md，再改这里，各类自动跟随。
%
%   两项由用户 2026-10-01 拍板的决策已固化在此：
%     1. FrequencyState 的整数位按**钳位值 FrequencyLimit=4** 定，而不是按实测
%        的 -0.928..+0.838。理由：三组工况全部锁定成功，积分器从未撞到钳位，
%        实测值带取样偏差；而 railed 频率态恰恰是 slew 饱和守卫要检测的对象，
%        字长按成功运行定会在那一刻溢出回绕，守卫本身就失效。
%     2. PendingCode 钳位取 ±1024（代理自行选定，待复核）。它比守卫阈值
%        SlewSatPendingTol=0.5 大三个数量级，不可能影响判决；同时避免按实测
%        ±66 定会在 +120~+130 ppm 边界溢出（实测该区间可达 5408~7883）。

    methods (Static)

        % ---------- 信号路径 ----------

        function f = adcCode()
            %ADCCODE ADC 码 / FFE 输入。7-bit TI ADC 满量程。
            f = cdr_fx.fxq.fmt(true, 7, 0);
        end

        function f = ffeOutput()
            %FFEOUTPUT FFE 输出。输入 ±64 乘 (1+Σ|c|≈1.3)，留 guard，保 2 位小数。
            f = cdr_fx.fxq.fmt(true, 11, 2);
        end

        function f = dlevSlice()
            %DLEVSLICE 送 slicer 的判决电平与门限（窄输出）。
            %   decision、d 的取值、dlev_loop 里的 == 比较三者必须同用这个格式，
            %   否则精确相等判归属永远不成立，dLev 环会静默死掉。见 §5.1。
            f = cdr_fx.fxq.fmt(true, 9, 2);
        end

        function f = sliceError()
            %SLICEERROR 判决残差，与 ffeOutput 同小数位。
            f = cdr_fx.fxq.fmt(true, 11, 2);
        end

        % ---------- 环路滤波器 ----------

        function f = phaseError()
            %PHASEERROR voter 输出。除法已折入 Kp/Ki，这里是整数求和。见 §5.2。
            f = cdr_fx.fxq.fmt(true, 7, 0);
        end

        function f = loopGainKp()
            %LOOPGAINKP 比例增益。原 8.0 折入 1/64 后为 0.125。
            f = cdr_fx.fxq.fmt(true, 12, 4);
        end

        function f = loopGainKi()
            %LOOPGAINKI 积分增益。原 0.03 折入 1/64 后为 4.6875e-4。
            f = cdr_fx.fxq.fmt(true, 20, 18);
        end

        function f = freqState()
            %FREQSTATE 环路积分器。整数位按钳位值 ±4 定，非实测。见类头决策 1。
            f = cdr_fx.fxq.fmt(true, 19, 15);
        end

        function f = loopControl()
            %LOOPCONTROL Kp*pe + freqState，比 freqState 多 1 个整数位。
            f = cdr_fx.fxq.fmt(true, 20, 15);
        end

        function f = codeResidue()
            %CODERESIDUE 小数残量，定义域 |·|<1。与 freqState 同小数位以便直接相加。
            f = cdr_fx.fxq.fmt(true, 17, 15);
        end

        function f = pendingCode()
            %PENDINGCODE 被 slew 限幅拒绝执行的整数积压。钳位 ±1024。见类头决策 2。
            f = cdr_fx.fxq.fmt(true, 12, 0);
        end

        function f = deltaCode()
            %DELTACODE 每块实际施加的 PI 码增量，受 MaxDeltaCode 限制。
            f = cdr_fx.fxq.fmt(true, 4, 0);
        end

        % ---------- 相位插值器 ----------

        function f = piCodeWrapped()
            %PICODEWRAPPED 回绕后的 PI 码，0..NumCode-1，无符号。
            f = cdr_fx.fxq.fmt(false, 7, 0);
        end

        function f = piUiSlip()
            %PIUISLIP 累计 UI 滑移，留 1.5 倍余量。
            f = cdr_fx.fxq.fmt(true, 10, 0);
        end

        % ---------- dLev 环 ----------

        function f = dlevAccum()
            %DLEVACCUM dLev 宽累加器。最小增量实测 3.125e-4，16 位小数留足余量。
            f = cdr_fx.fxq.fmt(true, 23, 16);
        end

        function f = dlevStep()
            %DLEVSTEP dLev 步长，三档 0.5/0.1/0.02 均可在 15 位小数上精确表示。
            f = cdr_fx.fxq.fmt(false, 16, 15);
        end

        % ---------- FFE 环 ----------

        function f = ffeCoeffMul()
            %FFECOEFFMUL 非主抽头送乘法器的窄格式。
            %   主抽头恒为 1 且四层硬冻结，根本不进乘法器（是一根直通线），
            %   因此不在本格式管辖范围内。
            f = cdr_fx.fxq.fmt(true, 12, 10);
        end

        function f = ffeCoeffAccum()
            %FFECOEFFACCUM 非主抽头 LMS 宽累加器。
            %   实测最小增量 3.125e-6 → 需 22 位小数。比先前凭经验估的 20 位多
            %   2 位；按 20 位做会让累加器进入死区，环路看着收敛实则冻结。
            f = cdr_fx.fxq.fmt(true, 24, 22);
        end

        function f = ffeStep()
            %FFESTEP FFE 步长，捕获 0.001 / settle 与 PVT 2e-4。
            f = cdr_fx.fxq.fmt(false, 20, 19);
        end

        % ---------- 策略判决器（仅在线部分算硅） ----------

        function f = snrEwma()
            %SNREWMA SNR 的 EWMA 累加器。α=1/128 即 acc += (x-acc)>>7。
            f = cdr_fx.fxq.fmt(true, 24, 12);
        end

        function f = freqEwma()
            %FREQEWMA 频率态 EWMA 累加器。
            %   用户 2026-10-01 要求：频率态在线门控不再取 2048 深滑窗的 mean，
            %   改用与 SNR 同款的指数平均。代价从 2048 个寄存器 + 一个宽加法树
            %   降到 3 个寄存器（快/慢两条 EWMA + 一个绝对差 EWMA），面积与功耗
            %   都低一个数量级以上。小数位与 freqState 对齐以便直接相减。
            f = cdr_fx.fxq.fmt(true, 24, 15);
        end
    end
end
