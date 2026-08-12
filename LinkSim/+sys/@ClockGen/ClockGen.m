classdef ClockGen
    properties
        myRxClocking;
        clockLen
        % Fs
        TI_clock
        rising_edge_indices
        clk_array
        SamplesPerSymbol
        % num_clk
        freq_sub_clock
        f_tnh
        Phase_Initial
        num_tnh
        num_adc
        rising_edge_array
        % ssc_mod
        % final_rising_edge
        num_slice
        slice_counter
        diff_mod
        ssc_flag
        ssc_rising_edge
        rising_edge
        rising_edge_out
        ppm_rising_edge
        ssc_f
        rj_std
        dj
        dt
        f_modulated;
    end

    methods
        function obj = ClockGen(baud_rate, SamplesPerSymbol, num_tnh, num_slice, num_adc, freq_sub_clock, depth, fm, fm_offset, rj_std, dj_amp, dj_freq)
            obj.myRxClocking = sys.RxClocking('baud_rate', baud_rate);
            %obj.myRxClocking= obj.myRxClocking.clk8_dcc(0);
            obj.num_tnh = num_tnh;
            obj.clockLen = 2 * SamplesPerSymbol * num_adc;
            % obj.Fs = SamplesPerSymbol * num_tnh;
            obj.rising_edge_indices = zeros(1, num_adc);
            obj.SamplesPerSymbol = SamplesPerSymbol;
            obj.num_slice = num_slice;
            % 初始化时钟相关参数
            % obj.num_clk = num_adc/num_tnh;
            obj.freq_sub_clock = freq_sub_clock;
            obj.num_adc = num_adc;
            obj.clk_array = zeros(obj.num_tnh, obj.clockLen);
            obj.rising_edge_array = zeros(obj.num_tnh, num_adc / num_tnh);
            % obj.ssc_mod = zeros(1, obj.num_slice * num_adc);
            % obj.final_rising_edge = 0;
            obj.slice_counter = 0;
            obj.f_tnh = obj.num_adc / obj.num_tnh * obj.freq_sub_clock;
            % obj = obj.SSC(depth_fm, fm_offset);
            obj.rj_std = rj_std;
            obj = obj.dj_Gen(dj_amp, dj_freq);
            obj.dt = 1/(obj.num_adc * obj.freq_sub_clock * obj.SamplesPerSymbol);
        end

        % 确定性抖动（DJ）生成函数
        function obj = dj_Gen(obj, dj_amp, dj_freq)
            t = 0:obj.num_adc * obj.num_slice - 1;
            phaseshift = 0;
            obj.dj = dj_amp * sin(2 * pi * (dj_freq/(obj.freq_sub_clock * obj.num_adc)) * t + phaseshift);
        end

        % 8GHz时钟相位生成函数
        function [obj, rising_edge_array] = Clk8phaseGen(obj, pi_delta)
            % 先调用adder_4G生成2相位时钟
            obj.myRxClocking = obj.myRxClocking.adder_4G(pi_delta);
            % 再调用clk8_gen生成8相位时钟（对应8GHz场景）
            [rising_edge_array, obj.myRxClocking] = obj.myRxClocking.clk8_gen();
        end


        % function obj = SSC(obj, depth, fm, f_offset)
        %     delta_f = depth/2;
        %     t = 0 : obj.num_adc * obj.num_slice - 1;
        %     f0 = obj.freq_sub_clock * obj.num_adc;
        %     phaseshift = 0.5;
        %     obj.ssc_f = delta_f * sawtooth(2 * pi * (fm/f0 * t + phaseshift), 0.5) - delta_f;
        %     % figure()
        %     % plot(obj.ssc_f(1:end))
        %     ppm_f = 1 + f_offset * 1e-6;
        %     obj.f_modulated = ppm_f + obj.ssc_f;
        %     period_modulated = obj.SamplesPerSymbol./obj.f_modulated;
        %     idx_start = obj.SamplesPerSymbol/2;
        %     obj.ssc_rising_edge = idx_start + round(cumsum(period_modulated));
        %     obj.rising_edge = idx_start + obj.SamplesPerSymbol * (t + 1);
        %     obj.diff_mod = obj.ssc_rising_edge(1:obj.num_adc * obj.num_slice) - obj.rising_edge(1:obj.num_adc * obj.num_slice);
        %     % figure()
        %     % plot(obj.diff_mod)
        % end
    end
end
