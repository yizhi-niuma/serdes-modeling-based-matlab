classdef RxCDR < matlab.System
    %UNTITLED3 Summary of this class goes here
    % Detailed explanation goes here

    properties
        nclk_sim
        pam_sliced = [-3 -1 1 3];
        phase_init = 0;  %BB/MM/SMM/ABS
        pd_mode = 'MM';
        %'vote' can track 3000 ppm fixed offset with control path dither bit = 0, i path dither bit = 3;
        %'sum' can track 5000 ppm fixed offset with control path dither bit = 4, i path dither bit = 2;
        dec_mode = 'sum';
        sum_trunc = 0;
        p_trunc = 0;
        i_trunc = 0;
        p_dec_out_max = 1023;
        p_dec_out_min = -1024;
        p_path_max;
        i_dec_out_max = 1023;
        i_dec_out_min = -1024;
        i_path_max;
        p_i_path_sum_max;
        p_i_path_sum_trunc = 2;
        pi_code_max = 2^11-1;
        pi_code_min = -2^11;
        pi_code_th;
        pi_comb_sum_reg
        pi_shift_code_map = [0, 0, 0, 0;
            1, 0, 0, 0;
            1, 0, 1, 0;
            1, 1, 1, 0;
            1, 1, 1, 1];
        pi_shift_dir_reg;
        pi_shift_not0_flag_reg;
        pi_shift_code_reg;
        pi_shift_dir;
        pi_shift_code;
        abs_pd_trunc = 2;
        phase_step = 1/128;
        modulation = 4;

        num_dmx = 64;
        data_3clk;
        data_reg_length;
        data_sliced;
        data_sliced_pre;
        data_err;
        data_err_pre;
        data_sliced0123;

        ffe_npre = 2;
        ffe_npst = 2;
        ffe_coef_nbit = 7;
        ffe_main_idx = 3;
        ffe_coef_init = [-1 -5 64 -7 -2 0];
        ffe_coef;
        ffe_lms_en = 0;
        ffe_mu = 9;
        ffe_out;
        ffe_out_pre;
        ffe_out_nbits = 12;
        acc_ffe;

        heh;
        heh_mu = 6;
        heh_lms_en = 1;
        heh_lms_num = 1; % 4
        heh_init = [-300 -100 100 300];
        acc_heh = zeros(1,4);
        acc_heh_pre = zeros(1,4);

        p_path;
        p_path_reg;
        i_path = 0;
        i_path_reg;
        r_path = 0;
        rp_path = 0;
        rn_path = 0;
        rp_path_acc = 0;
        rn_path_acc = 0;
        r_path_sign = 0;
        r_path_sign_reg;
        r_path_sign_acc = 0;
        r_path_en = 0;
        rp_path_dither = 0;
        rn_path_dither = 0;
        r_path_dither_bit = 12;
        ctrl_path = 0;
        i_path_mean = 0;
        i_path_err;
        i_err_acc = 0;
        ssc_period_num;
        ssc_p_path;
        ssc_i_path = 0;
        ssc_i_path_dither = 0;
        ssc_i_path_dither_bit = 12;
        i_path_mean_dither_bit = 20;
        r_path_start_clk = 5000;
        i_err_acc_en = 0;

        clk_cnt = 1;
        ssc_f;
        r_path_sign_acc_reg;
        ssc_period_cnt = 1;
        i_path_th;
        rp_track_mode;
        th1_rise_clk_reg;
        th1_fall_clk_reg;
        th1_rise_cnt = 1;
        th1_fall_cnt = 1;
        unique_th = 10;
        th_tmp_reg;
        th_comp_reg;
        th_tmp_cnt = 1;
        th_tmp_num = 128;
        th_tmp_pre = 1;
        th_clk_reg;
        th_clk_cnt = 1;
        th_sign_reg;
        deflec_now;
        ssc_period_now;
        deflec_pred;
        ssc_period_acc = 0;
        ssc_period_mean_cnt = 0;
        ssc_period_mean;
        ssc_period_final;
        ssc_period_mean_start = 4;
        ssc_period_mean_num = 8;

        kp = 2^18;
        ki = 2^24;
        kc = 2^10;
        kr = 2^34;
        ssc_kp = 2^42;
        ssc_ki = 2^50;

        ctrl_path_dither = 0;
        ctrl_path_dither_bit = 3;%4;
        i_path_dither = 0;
        % i_path_dither_bit = 5;%4;the larger the value, the smoother the tracking profile, the longer the lag
        SamplesPerSymbol = 128;
        ui_acc = 0;
        pi_code = 0;
        ui_acc_delay = 0;
        pi_code_delay = 0;
        pd_out_sign_reg;
        pd_test_sign_reg;
        dec_out_reg;
        pi_code_reg;
        ui_acc_reg;
        cdr_clk_delay = 7;%the larger the delay, the larger the CDR bandwidth required; dither_bit should be reduced;

        num_adc = 64;
        ssc_depth = 5000 * 1e-6;
        ssc_fm = 33e3;
        baud_rate = 5e9;
        ssc_period_clk = 2e4;
        phase_res_comp_en = 1;
        phase_shift_ratio = 0;
        phase_shift_final = 0;
        phase_res_comp_start = 0;

        cdr_ffe_in;
        p_i_path_sum_cutoff;
        p_i_path_sum;
    end
    methods
        %Constructor
        function obj = RxCDR(varargin)
            setProperties(obj,nargin,varargin{:})
            obj.ffe_coef = obj.ffe_coef_init;
            [~, obj.ffe_main_idx] = max(obj.ffe_coef);
            obj.ffe_npre = obj.ffe_main_idx - 1;
            obj.ffe_npst = length(obj.ffe_coef) - obj.ffe_main_idx;

            obj.heh = obj.heh_init;
            obj.ssc_i_path = 0;%i_path_mean;
            obj.data_3clk = zeros(1,3*obj.num_dmx);
            obj.data_reg_length = length(obj.data_3clk);
            obj.acc_ffe = zeros(1, length(obj.ffe_coef));
            obj.th_tmp_reg = zeros(1, obj.th_tmp_num);
            obj.th_comp_reg = zeros(1, obj.th_tmp_num);
            obj.dec_out_reg = zeros(obj.nclk_sim * 2, 1);

            obj.r_path_sign_reg = zeros(obj.nclk_sim * 2, 1);
            obj.i_path_reg = zeros(obj.nclk_sim * 2, 1);
            obj.p_path_reg = zeros(obj.nclk_sim * 2, 1);
            obj.pi_code_reg = zeros(obj.nclk_sim * 2, 1);
            obj.ui_acc_reg = zeros(obj.nclk_sim * 2, 1);
            obj.p_i_path_sum_reg = zeros(obj.nclk_sim * 2, 1);
            obj.ssc_period_clk = round(obj.baud_rate/obj.num_adc/obj.ssc_fm);
            obj.p_path_max = obj.num_dmx/2^obj.p_trunc * obj.kp;
            obj.i_path_max = round(obj.ssc_depth * obj.SamplesPerSymbol * obj.num_dmx);
            obj.p_i_path_sum_max = obj.p_path_max + obj.i_path_max;
            obj.pi_code_th = 0;%round(obj.p_i_path_sum_max/obj.pi_code_max/2);
            obj.pi_shift_dir_reg = zeros(obj.nclk_sim * 2, 1);
            obj.pi_shift_code_reg = zeros(obj.nclk_sim * 2, 4);
            obj.pi_shift_not0_flag_reg = zeros(obj.nclk_sim * 2, 1);
            obj.unique_th = round(obj.ssc_period_clk/4);
            obj.i_path_th(1) = round(obj.i_path_max/2);
            obj.i_path_th(2) = obj.i_path_th(1) + 5;

            obj.th1_rise_clk_reg = zeros(obj.ssc_period_num, 1);
            obj.th1_fall_clk_reg = zeros(obj.ssc_period_num, 1);

            obj.data_sliced = zeros(1, obj.num_dmx);
            obj.data_err = zeros(1, obj.num_dmx);
            obj.ffe_out = zeros(1, obj.num_dmx);
        end
        function obj = ffe(obj, data_in) %delay one clk-cycle
            obj.data_3clk = [obj.data_3clk(obj.num_dmx + 1: end), data_in];
            %data_conv = obj.data_3clk(obj.num_dmx + 1 - obj.ffe_npst: 2*obj.num_dmx+obj.ffe_npre); %Proceeding the current clk's data
            ui_idx = (obj.data_reg_length - obj.num_dmx + 1: obj.data_reg_length) - obj.ffe_npre;
            data_conv = obj.data_3clk(ui_idx(1) - obj.ffe_npst: ui_idx(end) + obj.ffe_npre);
            conv_out = round(conv(data_conv, obj.ffe_coef)/2^0);
            obj.cdr_ffe_in = obj.data_3clk(ui_idx(1): ui_idx(1)+obj.num_dmx-1);
            obj.ffe_out_pre = obj.ffe_out;
            obj.ffe_out = conv_out(obj.ffe_npre + 1: obj.ffe_npre + 1 + obj.ffe_npst: end - obj.ffe_npst - obj.ffe_npre);
            obj.data_sliced_pre = obj.data_sliced;
            obj.data_err_pre = obj.data_err;
            [obj.data_sliced0123, obj.data_sliced, obj.data_err] = f_slicer(obj.modulation, obj.ffe_out, obj.heh);
            sig_pre_vec = [obj.ffe_out_pre(end), obj.ffe_out(1: end - 1)];
            sig_now_vec = obj.ffe_out;
            a_pre_vec = [obj.data_sliced_pre(end), obj.data_sliced(1: end - 1)];
            err_pre_vec = [obj.data_err_pre(end), obj.data_err(1: end - 1)];
            a_now_vec = obj.data_sliced;
            err_now_vec = obj.data_err;
            switch obj.pd_mode
                case 'MM'
                    pd_out = a_pre_vec.*err_now_vec - a_now_vec.*err_pre_vec;
                    pd_out = sign(pd_out);
                case 'SMM'
                    pd_out = sign(a_pre_vec).*sign(err_now_vec) - sign(a_now_vec).*sign(err_pre_vec);
                case 'SMM2'
                    pd_out = sign(a_pre_vec).*err_now_vec - sign(a_now_vec).*err_pre_vec;
                    pd_out = sign(pd_out);
                case 'ABS'
                    %pd_out = abs(obj.data_err(1: end - 1) + obj.data_err(2: end)).*(abs(obj.data_err(1: end - 1)) - abs(obj.data_err(2: end)));
                    pd_out = round((abs(err_pre_vec + err_now_vec))/2^obj.abs_pd_trunc).*sign(round((abs(err_pre_vec) - abs(err_now_vec))/2^obj.abs_pd_trunc));
                    %pd_out = round((abs(err_pre_vec + err_now_vec)).*sign(abs(err_pre_vec) - abs(err_now_vec)))/2^obj.abs_pd_trunc;
                otherwise
                    error('PD mode should be checked');
            end
            switch obj.dec_mode
                case 'sum'
                    dec_out = sum(pd_out);
                    p_dec_out = dec_out;
                    i_dec_out = dec_out;
                case 'vote'
                    dec_out = sign(sum(pd_out));
                    p_dec_out = dec_out;
                    i_dec_out = dec_out;
                case 'adapt'
                    dec_out = round(sum(pd_out)/2^obj.sum_trunc);
                    p_dec_out = dec_out;
                    i_dec_out = dec_out;
                case 'path_adapt'
                    dec_out = sum(pd_out);
                    p_dec_out = round(dec_out/2^obj.p_trunc);
                    p_dec_out = min(obj.p_dec_out_max, max(obj.p_dec_out_min, p_dec_out));
                    i_dec_out = round(dec_out/2^obj.i_trunc);
                    i_dec_out = min(obj.i_dec_out_max, max(obj.i_dec_out_min, i_dec_out));
                otherwise
                    error('Decimation mode should be checked')
            end
            %---------------------cdr loop---------------------
            if obj.ssc_period_cnt > 2
                obj.rp_path_dither = obj.rp_path_dither + i_dec_out * obj.kr * (obj.r_path_sign > 0);% r_path_dither_bit should be adjusted
                obj.rn_path_dither = obj.rn_path_dither + i_dec_out * obj.kr * (obj.r_path_sign < 0);
                if obj.rp_path_dither > 2^obj.r_path_dither_bit
                    obj.rp_path_dither = obj.rp_path_dither - 2^obj.r_path_dither_bit;
                    obj.rp_path = obj.rp_path + 1;
                elseif obj.rp_path_dither < -2^obj.r_path_dither_bit
                    obj.rp_path_dither = obj.rp_path_dither + 2^obj.r_path_dither_bit;
                    obj.rp_path = obj.rp_path - 1;
                end

                if obj.rn_path_dither > 2^obj.r_path_dither_bit
                    obj.rn_path_dither = obj.rn_path_dither - 2^obj.r_path_dither_bit;
                    obj.rn_path = obj.rn_path + 1;
                elseif obj.rn_path_dither < -2^obj.r_path_dither_bit
                    obj.rn_path_dither = obj.rn_path_dither + 2^obj.r_path_dither_bit;
                    obj.rn_path = obj.rn_path - 1;
                end

                obj.r_path_en = 1;
                obj.r_path = obj.rp_path * (obj.r_path_sign > 0) + obj.rn_path * (obj.r_path_sign < 0);
            end
            obj.p_path = p_dec_out * obj.kp;
            obj.i_path_dither = obj.path_dither + i_dec_out * obj.ki + obj.r_path * obj.r_path_en;
            i_path_delta = fix(obj.path_dither/2^obj.i_path_dither_bit);
            obj.i_path_dither = rem(obj.path_dither, 2^obj.i_path_dither_bit);
            obj.i_path = obj.i_path + i_path_delta;
            obj.p_i_path_sum = obj.p_path + obj.i_path;
            obj.ctrl_path_dither = obj.ctrl_path_dither + obj.p_path + obj.i_path;
            pi_delta = fix(obj.ctrl_path_dither/2^obj.ctrl_path_dither_bit);
            obj.pi_code = obj.pi_code + pi_delta;
            if abs(obj.pi_code) >= obj.SamplesPerSymbol
                obj.ui_acc = obj.ui_acc + sign(obj.pi_code);
                obj.pi_code = rem(obj.pi_code, obj.SamplesPerSymbol);
            end
            obj.ctrl_path = obj.ui_acc * obj.SamplesPerSymbol + obj.pi_code;
            obj.pi_code_reg(obj.clk_cnt) = obj.pi_code;
            obj.ui_acc_reg(obj.clk_cnt) = obj.ui_acc;
            obj.p_path_reg(obj.clk_cnt) = obj.p_path;
            obj.i_path_reg(obj.clk_cnt) = obj.i_path;
            obj.dec_out_reg(obj.clk_cnt) = dec_out;
            obj.p_i_path_sum_reg(obj.clk_cnt) = obj.p_i_path_sum;

            %---------------------add cdr loop delay---------------------
            if obj.clk_cnt <= obj.cdr_clk_delay + 1
                obj.pi_code_delay = 0;
                obj.ui_acc_delay = 0;
            else
                obj.pi_code_delay = obj.pi_code_reg(obj.clk_cnt - 1 - obj.cdr_clk_delay);
                obj.ui_acc_delay = obj.ui_acc_reg(obj.clk_cnt - 1 - obj.cdr_clk_delay);
            end

            %---------------------pi_code decoder---------------------

            obj.p_i_path_sum_cutoff = round(obj.p_i_path_sum/2^obj.p_i_path_sum_trunc);
            obj.p_i_path_sum_cutoff = max(obj.pi_code_min, min(obj.pi_code_max, obj.p_i_path_sum_cutoff));

            obj.pi_shift_dir = sign(obj.p_i_path_sum_cutoff) < 0;
            %     obj.pi_shift_code = obj.pi_shift_code_map(abs(obj.p_i_path_sum_cutoff) + 1, :);
            obj.pi_shift_dir_reg(obj.clk_cnt) = obj.pi_shift_dir;
            obj.pi_shift_not0_flag_reg(obj.clk_cnt) = obj.p_i_path_sum_cutoff ~= 0;
            %     obj.pi_shift_code_reg(obj.clk_cnt, :) = obj.pi_shift_code;

            %---------------------phase resolution compensation---------------------
            if obj.clk_cnt > obj.phase_res_comp_start
                phase_shift_range = round(obj.i_path/2^obj.ctrl_path_dither_bit);
                phase_shift_mean = round(phase_shift_range * obj.phase_shift_ratio);
                obj.phase_shift_final = (round(phase_shift_range * (1-obj.num_adc/obj.num_adc)) - phase_shift_mean) * obj.phase_res_comp_en;
            else
                obj.phase_shift_final = 0;
            end

            switch obj.rp_track_mode
                case 'integral'
                    if obj.clk_cnt > obj.r_path_start_clk
                        if abs(obj.i_path) < 10
                            obj.i_err_acc_en = 1;
                        end
                        if obj.i_err_acc_en == 1
                            obj.i_path_err = obj.i_path - obj.i_path_mean;
                            obj.i_err_acc = obj.i_err_acc + obj.i_path_err;
                            obj.r_path_sign = sign(obj.i_err_acc);
                            obj.r_path_sign_reg(obj.clk_cnt) = obj.r_path_sign;
                            if obj.clk_cnt > 1
                                if (obj.r_path_sign_reg(obj.clk_cnt) - obj.r_path_sign_reg(obj.clk_cnt - 1)) == 2
                                    obj.ssc_period_cnt = obj.r_path_sign_acc;
                                    if obj.ssc_period_cnt > 1
                                        obj.ssc_p_path = obj.r_path_sign_acc * obj.ssc_kp;
                                        obj.ssc_i_path_dither = obj.ssc_i_path_dither + obj.r_path_sign_acc * obj.ssc_ki;
                                        if obj.ssc_i_path_dither > 2^obj.ssc_i_path_dither_bit
                                            obj.ssc_i_path_dither = obj.ssc_i_path_dither - 2^obj.ssc_i_path_dither_bit;
                                            obj.ssc_i_path = obj.ssc_i_path + 1;
                                        elseif obj.ssc_i_path_dither < -2^obj.ssc_i_path_dither_bit
                                            obj.ssc_i_path_dither = obj.ssc_i_path_dither + 2^obj.ssc_i_path_dither_bit;
                                            obj.ssc_i_path = obj.ssc_i_path - 1;
                                        end
                                        obj.i_path_mean = obj.i_path_mean + round((obj.ssc_p_path + obj.ssc_i_path)/2^obj.i_path_mean_dither_bit);
                                        obj.r_path_sign_acc = 0;
                                        obj.ssc_period_cnt = obj.ssc_period_cnt + 1;
                                    end
                                end
                            end
                            obj.r_path_sign_acc = obj.r_path_sign_acc + obj.r_path_sign;
                        end
                    end
                case 'threshold'
                    obj.th_sign_reg(obj.clk_cnt) = sign(obj.i_path - obj.i_path_th(1));
                    if obj.i_path > obj.i_path_th(1) && obj.i_path < obj.i_path_th(2)
                        if obj.th_tmp_cnt == 1 && obj.clk_cnt == 1
                            obj.th_tmp_reg(obj.th_tmp_cnt) = obj.clk_cnt;
                            obj.th_tmp_pre = obj.clk_cnt;
                            obj.th_tmp_cnt = obj.th_tmp_cnt + 1;
                        else
                            if (obj.clk_cnt - obj.th_tmp_reg(obj.th_tmp_cnt - 1)) < obj.unique_th
                                if obj.th_tmp_cnt <= obj.th_tmp_num
                                    obj.th_tmp_reg(obj.th_tmp_cnt) = obj.clk_cnt;
                                    obj.th_comp_reg(obj.th_tmp_cnt) = obj.i_path_reg(obj.clk_cnt) > obj.i_path_reg(obj.clk_cnt - 1);
                                    obj.th_tmp_cnt = obj.th_tmp_cnt + 1;
                                end
                            else
                                th_final_num = 2^(floor(log2(obj.th_tmp_cnt - 1)));
                                slope_sign = sign(sum(obj.th_comp_reg));
                                if slope_sign == -1
                                    obj.th_clk_reg(obj.clk_cnt) = round(sum(obj.th_tmp_reg(1:th_final_num))/th_final_num);
                                else
                                    obj.th_clk_reg(obj.clk_cnt) = round(sum(obj.th_tmp_reg(obj.th_tmp_cnt - th_final_num:obj.th_tmp_cnt - 1))/th_final_num);
                                end
                                if rem(obj.th_clk_cnt - 1, 2) == 0
                                    obj.ssc_period_cnt = (obj.th_clk_cnt - 1)/2;
                                    if obj.ssc_period_cnt > 0
                                        obj.deflec_now = [round((obj.th_clk_reg(obj.ssc_period_cnt * 2 - 1) + obj.th_clk_reg(obj.ssc_period_cnt * 2))/2), ...
                                            round((obj.th_clk_reg(obj.ssc_period_cnt * 2 + 1) + obj.th_clk_reg(obj.ssc_period_cnt * 2))/2)];
                                        obj.deflec_pred = [obj.deflec_now + obj.ssc_period_final, obj.deflec_now(1) + 2 * obj.ssc_period_final];
                                        if obj.ssc_period_cnt >= obj.ssc_period_mean_start
                                            obj.ssc_period_acc = obj.ssc_period_acc + obj.ssc_period_now;
                                            obj.ssc_period_mean_cnt = obj.ssc_period_mean_cnt + 1;
                                        end
                                        if obj.ssc_period_mean_cnt == obj.ssc_period_mean_num
                                            obj.ssc_period_mean = round(obj.ssc_period_acc/obj.ssc_period_mean_num);
                                            obj.ssc_period_acc = 0;
                                            obj.ssc_period_mean_cnt = 0;
                                        end
                                        if obj.ssc_period_cnt > obj.ssc_period_mean_start + obj.ssc_period_mean_num
                                            obj.ssc_period_final = obj.ssc_period_mean;
                                        else
                                            obj.ssc_period_final = obj.ssc_period_now;
                                        end
                                        obj.deflec_pred = [obj.deflec_now + obj.ssc_period_final, obj.deflec_now(1) + 2 * obj.ssc_period_final];
                                        polarity = sign(obj.th_sign_reg(obj.deflec_now(1)) - obj.th_sign_reg(obj.deflec_now(2)));
                                        obj.r_path_sign_reg(obj.deflec_pred(1):obj.deflec_pred(2)) = polarity;
                                        obj.r_path_sign_reg(obj.deflec_pred(2) + 1:obj.deflec_pred(3)) = -polarity;
                                        obj.r_path_sign_reg(obj.deflec_pred(3) + 1:obj.deflec_pred(3) + round(obj.ssc_period_final/2)) = polarity;
                                    end
                                end
                                obj.th_clk_cnt = obj.th_clk_cnt + 1;
                                obj.th_tmp_cnt = 2;
                                obj.th_tmp_reg(1) = obj.clk_cnt;
                            end
                        end

                    end
                    obj.r_path_sign = obj.r_path_sign_reg(obj.clk_cnt + 1);
            end

            obj.clk_cnt = obj.clk_cnt + 1;
            obj.heh = zeros(1,4);
            delta_heh = zeros(1,4);
            delta_ffe_tap = zeros(1, length(obj.ffe_coef));

            %====================HEH LMS====================
            if obj.heh_lms_en
                if obj.heh_lms_num == 1
                    delta_heh(3) = sum( sign(obj.data_sliced) .* sign(obj.data_err) );
                    obj.acc_heh(3) = delta_heh(3) + obj.acc_heh(3);
                    if obj.acc_heh(3) > 2^obj.heh_mu - 1
                        obj.heh(3) = obj.heh(3) - 1;
                        obj.acc_heh(3) = obj.acc_heh(3) - 2^obj.heh_mu;
                    elseif obj.acc_heh(3) < -2^obj.heh_mu
                        obj.heh(3) = obj.heh(3) + 1;
                        obj.acc_heh(3) = obj.acc_heh(3) + 2^obj.heh_mu;
                    end
                    obj.heh = obj.heh(3) * [-3 -1 1 3];
                else  % lms_heh_num = 4
                    for id_heh = 1:4
                        delta_heh(id_heh) = sum( sign(obj.data_sliced) .* sign(obj.data_err) .* (obj.data_sliced == obj.pam_sliced(id_heh)) );
                        obj.acc_heh(id_heh) = delta_heh(id_heh) + obj.acc_heh(id_heh);
                        if obj.acc_heh(id_heh) > 2^obj.heh_mu - 1
                            obj.heh(id_heh) = obj.heh(id_heh) - 1 * sign(obj.pam_sliced(id_heh));
                            obj.acc_heh(id_heh) = obj.acc_heh(id_heh) - 2^obj.heh_mu;
                        elseif obj.acc_heh(id_heh) < -2^obj.heh_mu
                            obj.heh(id_heh) = obj.heh(id_heh) + 1 * sign(obj.pam_sliced(id_heh));
                            obj.acc_heh(id_heh) = obj.acc_heh(id_heh) + 2^obj.heh_mu;
                        end
                    end
                end
            end

            %====================================FFE Coef LMS====================================
            if obj.ffe_lms_en
                for id_tap = 1: length(obj.ffe_coef)
                    if id_tap ~= obj.ffe_main_idx
                        %x_vec = obj.data_3clk ((obj.dmux_num +1: 2*obj.dmux_num) - (id_tap - obj.ffe_main_idx));
                        x_vec = obj.data_3clk (ui_idx - (id_tap - obj.ffe_main_idx));
                        delta_ffe_tap(id_tap) = sum( sign(x_vec).* sign(obj.data_err) );
                        obj.acc_ffe(id_tap) = obj.acc_ffe(id_tap) + delta_ffe_tap(id_tap);
                        if obj.acc_ffe(id_tap) > 2^obj.ffe_mu -1
                            obj.ffe_coef(id_tap) = obj.ffe_coef(id_tap) + 1;
                            obj.acc_ffe(id_tap) = obj.acc_ffe(id_tap) - 2^obj.ffe_mu;
                        elseif obj.acc_ffe(id_tap) < -2^obj.ffe_mu
                            obj.ffe_coef(id_tap) = obj.ffe_coef(id_tap) - 1;
                            obj.acc_ffe(id_tap) = obj.acc_ffe(id_tap) + 2^obj.ffe_mu;
                        end
                    end
                end
            end




        end
    end
end
