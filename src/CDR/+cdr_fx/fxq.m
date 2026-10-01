classdef fxq
%FXQ 定点量化/饱和工具。+cdr_fx 包内所有定点类的共同底座。
%
%   存储策略：用 double 承载，但**每个节点都在其声明格式上显式量化并饱和**。
%   只要中间量不超过 double 的 53 位尾数，这与整数运算逐位等价，而速度与浮点
%   相同 —— 这对 15000 block × 32 相位的闭环仿真是必要条件（fi 对象会慢 10~100
%   倍，长跑不可行）。本设计最宽的乘积是 FFE 系数 (1,24,22) × ADC 码 (1,7,0)
%   = 31 位，6 抽头求和 34 位，远在 53 位之内。
%
%   格式记法统一用 (signed, WordLength, FractionLength)，与 MATLAB 的
%   numerictype 实参一致。整数位 = WordLength - signed - FractionLength。
%
%   取整模式必须显式指定，不提供默认值。原因见 docs/CDR_FIXED_POINT.md §5.3：
%   cdr_loop 用的是 fix()(向零取整)，而算术右移是 floor(向负无穷)，对负数结果
%   不同。本项目已存在负 ppm 方向的捕获不对称，一旦混进 floor/fix 错误极易被
%   误诊为物理现象，因此这里拒绝"默认取整"。

    methods (Static)

        function f = fmt(isSigned, wordLength, fracBits)
            %FMT 构造一个格式描述结构体。
            f = struct( ...
                'Signed', logical(isSigned), ...
                'WordLength', double(wordLength), ...
                'FracBits', double(fracBits), ...
                'IntBits', double(wordLength) - double(logical(isSigned)) - double(fracBits));
            if f.IntBits < 0
                error('cdr_fx:fxq:InvalidFormat', ...
                    'WordLength %d 不足以容纳符号位与 %d 位小数。', ...
                    wordLength, fracBits);
            end
        end

        function v = lsb(fracBits)
            %LSB 该小数位数对应的最小分辨率。
            v = 2 ^ (-double(fracBits));
        end

        function [lo, hi] = limits(f)
            %LIMITS 该格式可表示的闭区间 [lo, hi]。
            step = cdr_fx.fxq.lsb(f.FracBits);
            if f.Signed
                lo = -2 ^ f.IntBits;
                hi = 2 ^ f.IntBits - step;
            else
                lo = 0;
                hi = 2 ^ f.IntBits - step;
            end
        end

        function y = quant(x, fracBits, mode)
            %QUANT 把 x 量化到 2^-fracBits 的栅格上。
            %   mode 必须显式给出：
            %     'floor'  向负无穷（等价于算术右移）
            %     'fix'    向零（等价于 MATLAB fix，cdr_loop 用这个）
            %     'round'  四舍五入，.5 远离零
            %     'ceil'   向正无穷
            scale = 2 ^ double(fracBits);
            switch mode
                case 'floor'
                    y = floor(x .* scale) ./ scale;
                case 'fix'
                    y = fix(x .* scale) ./ scale;
                case 'round'
                    y = round(x .* scale) ./ scale;
                case 'ceil'
                    y = ceil(x .* scale) ./ scale;
                otherwise
                    error('cdr_fx:fxq:InvalidRoundingMode', ...
                        '未知取整模式 ''%s''，必须是 floor/fix/round/ceil 之一。', mode);
            end
        end

        function [y, nOverflow] = sat(x, f)
            %SAT 按格式饱和，并返回被钳住的元素个数。
            %   溢出计数是一等公民输出：定点模型的验收不能只有 pass/fail，
            %   必须能回答"哪个节点在什么工况下溢出了多少次"。
            [lo, hi] = cdr_fx.fxq.limits(f);
            over = x > hi;
            under = x < lo;
            nOverflow = sum(over(:)) + sum(under(:));
            y = x;
            y(over) = hi;
            y(under) = lo;
        end

        function [y, nOverflow] = apply(x, f, mode)
            %APPLY 量化 + 饱和一步到位。定点类里最常用的入口。
            y = cdr_fx.fxq.quant(x, f.FracBits, mode);
            [y, nOverflow] = cdr_fx.fxq.sat(y, f);
        end

        function y = fixToZero(x, fracBits)
            %FIXTOZERO 向零取整到指定小数位。
            %
            %   这是 docs/CDR_FIXED_POINT.md §5.3 点名要求的函数：浮点参考
            %   cdr_loop.updateFast 用的是 fix()，直接写算术右移会把 -1.7 变成
            %   -2 而不是 -1，在零点附近引入方向不对称的偏置。作为对照
            %   cdr_pi 用的本来就是 floor，那里可以直接移位。两种语义在同一个
            %   仓库里并存，必须逐处核对。
            y = cdr_fx.fxq.quant(x, fracBits, 'fix');
        end

        function s = sign3(x)
            %SIGN3 三值符号函数，显式保留 sign(0) = 0。
            %
            %   SS-LMS 依赖这一点：dlev_loop 把环外样本置零后，sign(0)=0 正是
            %   "环外样本不贡献"的实现机制。RTL 的符号位是两值的，若照搬会让
            %   环外样本开始贡献，破坏内外环解耦。见 §5.4。
            s = sign(x);
        end

        function tf = representable(x, f, mode)
            %REPRESENTABLE 判断 x 是否已经落在该格式的栅格与范围内。
            %   供单元测试与断言使用。
            q = cdr_fx.fxq.quant(x, f.FracBits, mode);
            [lo, hi] = cdr_fx.fxq.limits(f);
            tf = all(q(:) == x(:)) && all(x(:) >= lo) && all(x(:) <= hi);
        end

        function s = describe(f)
            %DESCRIBE 返回人可读的格式说明，用于日志与报告。
            [lo, hi] = cdr_fx.fxq.limits(f);
            if f.Signed
                signTag = 's';
            else
                signTag = 'u';
            end
            s = sprintf('%s(%d,%d,%d) 范围[%g, %g] LSB=%g', ...
                signTag, double(f.Signed), f.WordLength, f.FracBits, ...
                lo, hi, cdr_fx.fxq.lsb(f.FracBits));
        end
    end
end
