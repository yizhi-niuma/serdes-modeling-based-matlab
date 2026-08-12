classdef RxClocking < matlab.System
    properties
        num_tap = 8;
        SamplesPerSymbol = 128;
        baud_rate = 56e9;
        % skew = (rand(1,8)*2 - 1) *1e-13;
        skew = zeros(8,1);
        pi_register_resolution = 64*8; %256
        pi_register = 50;%1;
        dt = 0;
        SamplesPerClk;
        SamplesPerPI;
        jitter_rms = 0; % 50fs
        pre_rising_edge
        dnl = zeros(1,64*8);
        inl = zeros(1,64*8);
        ini_idx
        skew_idx
        clk_4G
        pi_devcon(2, 4);
        pi_code_16bit = 0;
        pi_code_9bit_pre = 88;
        pi_code_9bit = 0;
        pi_code_9bit_delta
    end

    methods
        function obj = RxClocking(varargin)
            setProperties(obj,nargin,varargin{:})
            obj.dt = 1/obj.baud_rate/obj.SamplesPerSymbol;
            obj.SamplesPerPI = obj.num_tap * obj.SamplesPerSymbol;
            obj.SamplesPerClk = round(obj.ini_inl/obj.dt);
            obj.skew_idx = round(obj.skew/obj.dt);
        end

        function obj = adder_4G(obj, pi_delta)
            for clk_8G = 1:4
                obj.pi_code_9bit_pre = obj.pi_code_9bit;
                if clk_8G==1 || clk_8G==3  % 处理4GHz时钟逻辑
                    obj.pi_code_16bit = pi_delta + obj.pi_code_16bit;
                    obj.pi_code_16bit = mod(obj.pi_code_16bit, 2^16);
                    obj.pi_code_9bit = floor(obj.pi_code_16bit / 2^7);  % 转换为9位相位码
                    obj.pi_code_9bit_delta = obj.pi_code_9bit_pre - obj.pi_code_9bit;
                    % 相位码变化量的溢出处理
                    if obj.pi_code_9bit_delta > 256
                        obj.pi_code_9bit_delta = obj.pi_code_9bit_delta - 512;
                    end
                    if obj.pi_code_9bit_delta < -256
                        obj.pi_code_9bit_delta = obj.pi_code_9bit_delta + 512;
                    end
                    % 计算上升沿时刻
                    if obj.cnt == 0
                        cur_rising_edge = obj.pi_code_9bit * obj.SamplesPerPI + 1 + obj.SamplesPerClk / 2 + obj.ini_idx(obj.pi_code_9bit + 1);
                    else
                        cur_rising_edge = obj.pre_rising_edge + obj.SamplesPerClk + obj.pi_code_9bit_delta * obj.SamplesPerPI + obj.ini_idx(obj.pi_code_9bit + 1);
                    end
                else
                    % 8GHz时钟逻辑：直接在上一上升沿基础上加时钟周期
                    cur_rising_edge = obj.pre_rising_edge + obj.SamplesPerClk;
                end
                % 存储当前上升沿，更新计数与上一次上升沿
                obj.clk2(mod(obj.cnt, 4) + 1) = cur_rising_edge;
                obj.cnt = obj.cnt + 1;
                obj.pre_rising_edge = cur_rising_edge;
            end
        end

        function [rising_edge_array, obj] = clk8_gen(obj) %clk@8GHz
            rising_edge_array = zeros(obj.num_tnh, 4);
            jitter_idx = round(obj.jitter_rms * randn(obj.num_tnh, 1)/obj.dt);
            for i = 1:obj.num_tnh/2
                rising_edge_array(i, :) = obj.clk2(1,:) + obj.SamplesPerSymbol * (i - 1) + jitter_idx(i) + obj.skew_idx(i);
            end
            for i = obj.num_tnh/2 + 1:obj.num_tnh
                rising_edge_array(i, :) = obj.clk2(2,:) + obj.SamplesPerSymbol * (i - 1 - obj.num_tnh/2) + jitter_idx(i) + obj.skew_idx(i);
            end
        end

    end
end