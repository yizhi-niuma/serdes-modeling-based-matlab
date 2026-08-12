classdef ADCFrontend < sys.sar_adc_nb

    properties
        num_adcs = 64;
        digin_mux_size
        adc_sample_offsets
        adc_gain_errors
        adc_clock_delays
        Tstep
        mux_counter
        adc_T1_analogMux
        adc_T1_analogMux_idx
        adc_T1_digitalMux
        adc_analogMux
        adc_digitalMux
        adc_fullscale
        adc_lsb
        SamplesPerSymbol = 512;
        NB_ADC_en
        ADC_input
        ADC_output
        ADC_output_NB
        ADC_diff
        % nb_adc
        Tlen_tdc
        num_tnh
        rising_edge_array
        gain_error
        compare_offset
        reg_off
        k
        Tlen
    end

    methods
        function obj = ADCFrontend(num_adcs, num_tnh, vol_low, adc_nbits, adc_fullscale, digin_mux_size, Tstep, NB_ADC_en, Tlen, ...
                gain_error_std, offset_error_std, gain_cali_en, offset_cali_en)
            obj.num_adcs = num_adcs;
            obj.digin_mux_size = digin_mux_size;
            obj.adc_sample_offsets = zeros(obj.num_adcs, obj.digin_mux_size / obj.num_adcs);
            obj.adc_gain_errors = ones(obj.num_adcs, obj.digin_mux_size / obj.num_adcs);
            obj.adc_clock_delays = zeros(num_adcs); %initial clock delays for each ADC
            obj.Tstep = Tstep;
            obj.N = adc_nbits;
            obj.mux_counter = 0;
            obj.adc_T1_analogMux = zeros(num_tnh, obj.digin_mux_size / num_tnh);
            obj.adc_T1_analogMux_idx = zeros(num_tnh, obj.digin_mux_size / num_tnh);
            obj.adc_T1_digitalMux = zeros(num_tnh, obj.digin_mux_size / num_tnh);

            obj.adc_analogMux = zeros(num_adcs, obj.digin_mux_size / num_adcs);
            obj.adc_digitalMux = zeros(num_tnh, obj.digin_mux_size / num_tnh);

            obj.adc_fullscale = adc_fullscale;
            obj.adc_clock_delays = zeros(obj.num_adcs);
            obj.VL = vol_low;
            obj.VH = obj.VL + obj.adc_fullscale;
            obj.adc_lsb = obj.adc_fullscale / (2^obj.N);
            obj.N = adc_nbits;
            obj.NB_ADC_en = NB_ADC_en;
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            obj.Vref=obj.VL+(obj.VH-obj.VL)/2;
            obj.Vref_cdac=(obj.VH-obj.VL)/2;
            obj.delta1=obj.adc_lsb;
            obj.delta2=0.5*obj.adc_lsb;

            obj.ADC_input = [];
            obj.ADC_output_NB = [];
            obj.ADC_output = [];
            obj.ADC_diff = [];
            obj.Tlen = Tlen;
            obj.num_tnh = num_tnh;

            obj.gain_error=ones(1,obj.num_adcs);
            obj.compare_offset=zeros(1,obj.num_adcs);
            obj.reg_off=zeros(1,obj.num_adcs);
            obj.k=ones(1,obj.num_adcs);

            reg_off=ones(1,obj.num_adcs);
            reg_fullscale=ones(1,obj.num_adcs);
            gain_error_seed = normrnd(1, gain_error_std * obj.adc_lsb/obj.VH, [1, obj.num_adcs]);
            offset_error = normrnd(0,offset_error_std*obj.adc_lsb, [1, obj.num_adcs]);%
            delta=zeros(1,obj.num_adcs);
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            enable_o_c=offset_cali_en;%%
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            k=ones(1,obj.num_adcs);
            i=zeros(1,obj.num_adcs);
            gain_error_seed(1)=1;
            if gain_cali_en
                for x = 1:obj.num_adcs
                    obj.Voffset = ones(1,obj.M).*offset_error(x);%*normrnd(0.04,0.02)
                    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                    obj.compare_offset(x)=obj.Voffset(1); %chuandi voffset
                    obj.gain_error(x)= gain_error_seed(x); %chuandi gain
                    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                    obj.reg_off(x)=obj.offset_cal(enable_o_c);%store offset
                    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

                    reg_fullscale(x)=obj.dout(obj.VH-2*obj.adc_lsb,true,obj.k(x),x);%
                    ndac=8;
                    dac_res=0.25/(2^ndac-1);
                    delta(x)=reg_fullscale(x)-reg_off(x);
                    obj.reg_off(x)=obj.reg_off(x)-64;%128-0:offset-64
                    i(x)=fix((delta(x)/delta(1)-1)/dac_res);%vref_gain_calibra_min_resonlution limit dac_res=0.25/(2^ndac-1)
                    k(x)=1+i(x)*dac_res;%%%
                    k(1)=1;
                end
            end
            obj.k=k;

        end

        function [out, obj] = digitize_data(obj, analog_input)
            if obj.Tlen
                for i = 1:obj.num_tnh
                    obj.adc_T1_analogMux(i, :) = analog_input(obj.rising_edge_array(i, :));
                end

            else
                adc_sample_idx = obj.SamplesPerSymbol * (0:ceil(length(T1_Output) / obj.SamplesPerSymbol) - 1);
                for i = 1:obj.num_adcs
                    for j = 1:(obj.digin_mux_size / obj.num_adcs)
                        obj.adc_T1_analogMux(i, j) = Tloutput(adc_sample_idx(i) + (j - 1) * obj.num_adcs);
                        obj.adc_T1_analogMux_idx(i, j) = adc_sample_idx(i) + (j - 1) * obj.num_adcs;
                    end
                end
            end
            % obj = apply_adc_sample_offset(obj, false);
            % obj = apply_adc_gain_error(obj, false);

            for x = 1:obj.num_tnh
                for y = 1:(obj.num_adcs/obj.num_tnh)
                    %offset;

                    obj.Voffset = ones(1,obj.M).* obj.compare_offset(x);
                    [obj.adc_digitalMux(x, y), ~, ~] = obj.dout(obj.adc_T1_analogMux(x, y), true,obj.k(x),x);
        
                                                               
                end
            end

            obj.ADC_output = obj.adc_digitalMux(:)';
            out = obj.ADC_output - 64;
        end

        function obj = get_clock(obj, rising_edge_array)
            obj.rising_edge_array = rising_edge_array;
        end

        % function obj = apply_adc_sample_offset(obj, enable)
        %     if enable
        %         sample_offset_seed = normrnd(0, 10e-3, [1, obj.num_adcs]);
        %         for i = 1:(obj.digin_mux_size / obj.num_adcs)
        %             obj.adc_sample_offsets(:, i) = sample_offset_seed;
        %         end
        %         obj.adc_T1_analogMux = obj.adc_T1_analogMux + obj.adc_sample_offsets;
        %     end
        % end
        %
        % function obj = apply_adc_gain_error(obj, enable)
        %     if enable
        %         gain_error_seed = normrnd(1, 0.1, [1, obj.num_adcs]);
        %         for i = 1:(obj.digin_mux_size / obj.num_adcs)
        %             obj.adc_gain_errors(:, i) = gain_error_seed;
        %         end
        %         obj.adc_T1_analogMux = obj.adc_T1_analogMux .* obj.adc_gain_errors;
        %     end
        % end

        function quanti_offset=offset_cal(obj, enable_o_c)
            if enable_o_c
                quanti_offset=obj.dout(obj.adc_lsb*3/4);%- 2^(obj.N - 1);
            else
                quanti_offset=2^(obj.N - 1);
            end
        end

        function clk_delay = apply_adc_sample_delay(obj, adc_index)
            clk_delay = round(obj.adc_clock_delays(adc_index));
        end
        function [delta_t, VDL, errors_array] = VDL_update(obj, VDL, delta_t, Tref, cycle_time, group_times, errors_array, min_delta_t, enhanced_calibration_en)
            if group_times == 0
                adc_idx = 5;
            end
            if group_times == 1
                adc_idx = [3 7];
            end
            if group_times == 2
                adc_idx = [2 4 6 8];
            end
            for idx = adc_idx
                if idx == 5
                    error = error_calculation(obj.adc_T1_digitalMux(1,1:end - 1), obj.adc_T1_digitalMux(idx,1:end - 1), obj.adc_T1_digitalMux(1,2:end));
                end
                if idx == 8
                    error = error_calculation(obj.adc_T1_digitalMux(idx - 1,1:end - 1), obj.adc_T1_digitalMux(idx,1:end - 1), obj.adc_T1_digitalMux(1,2:end));
                end
                if idx == 3
                    error = error_calculation(obj.adc_T1_digitalMux(idx - 2,:), obj.adc_T1_digitalMux(idx,:), obj.adc_T1_digitalMux(idx + 2,:));
                end
                if idx == 7
                    error = error_calculation(obj.adc_T1_digitalMux(idx - 2,1:end - 1), obj.adc_T1_digitalMux(idx,1:end - 1), obj.adc_T1_digitalMux(1,2:end));
                end
                if idx == 2 || idx == 4 || idx == 6
                    error = error_calculation(obj.adc_T1_digitalMux(idx - 1,:), obj.adc_T1_digitalMux(idx,:), obj.adc_T1_digitalMux(idx + 1,:));
                end
                % enhanced algorithm
                if enhanced_calibration_en
                    if cycle_time == 1
                        errors_array(idx, 1) = error;
                    end
                    if cycle_time == 2
                        errors_array(idx, 2) = error;
                        Tref(2) = round(abs(errors_array(idx, 2)) * VDL(idx - 1, 1) / (abs(errors_array(idx, 1)) - errors_array(idx, 2))) * min_delta_t;
                    end
                end

                if error > 0
                    delta_t(idx) = delta_t(idx) - Tref(cycle_time);
                    VDL(idx - 1, cycle_time + length(Tref) * group_times + 1) = VDL(idx - 1, cycle_time + length(Tref) * group_times) - Tref(cycle_time) / min_delta_t;
                else
                    if error < 0
                        delta_t(idx) = delta_t(idx) + Tref(cycle_time);
                        VDL(idx - 1, cycle_time + length(Tref) * group_times + 1) = VDL(idx - 1, cycle_time + length(Tref) * group_times) + Tref(cycle_time) / min_delta_t;
                    else
                        VDL(idx - 1, cycle_time + length(Tref) * group_times + 1) = VDL(idx - 1, cycle_time + length(Tref) * group_times);
                    end
                end
                if group_times == 0 && cycle_time == length(Tref)
                    for i = 1:2 * length(Tref)
                        VDL(idx - 1, length(Tref) + 1 + i) = VDL(idx - 1, length(Tref) + 1);
                    end
                end
                if group_times == 1 && cycle_time == length(Tref)
                    for i = 1:length(Tref)
                        VDL(idx - 1, (group_times + 1) * length(Tref) + 1 + i) = VDL(idx - 1, (group_times + 1) * length(Tref) + 1);
                    end
                end
            end
        end
    end
end

function error = error_calculation(s_first, s_mid, s_end)
         temp = abs(s_first - s_mid) - abs(s_mid - s_end);
         error = mean(temp);
end
