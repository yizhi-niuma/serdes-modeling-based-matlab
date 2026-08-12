classdef Chan_Est
    properties
        modulation = 4;
        pam_sliced = [-3 -1 1 3];
        dmx_num = 32;
        data_cachelk = zeros(1,4^64);
        data_err;
        %dfe/ffe heh lms
        heh;
        heh_init = [-30 -10 10 30];
        heh_mu = 6;
        heh_lms_en = 1;
        heh_lms_num = 4; % NRZ=1, PAM4=4
        acc_heh = zeros(1,4);
        % ffe parameters
        % ffe_coef_len = 15;
        ffe_coef = [0 -1 0 9 64 40 11 -6 -8 -5 -2];
        ffe_main_idx = 3;
        ffe_npre = 4;
        ffe_npst = 7;
        acc_ffe;
        ffe_lmsen_vec = [1 1 1 1 0 1 1 1 1 1 1]; % fix the tap coef
        ffe_mu = 7;
        ffe_out;
    end

    methods
        function obj = Chan_Est(modulation, heh_init, heh_lms_en, heh_lms_num, num_dmx_rx)
            obj.modulation = modulation;
            obj.dmx_num = num_dmx_rx;
            obj.data_cachelk = zeros(1,3*obj.dmx_num);
            obj.data_err = zeros(1,obj.dmx_num);
            obj.heh = heh_init;
            obj.heh_lms_en = heh_lms_en;  % Enable ffe heh adaption,set zero when DFE is used
            obj.heh_lms_num = heh_lms_num;
            %ffe
            % [~, obj.ffe_main_idx] = max(obj.ffe_coef); % find the main cursor
            obj.ffe_npre = obj.ffe_main_idx - 1;
            obj.ffe_npst = length(obj.ffe_coef) - obj.ffe_main_idx;
            obj.acc_ffe = zeros(1, length(obj.ffe_coef));
        end

        function obj = ffe(obj, adc_in, data_pre, data_in, data_pst, acc_pre, coef_pre, clk)
            obj.acc_ffe = acc_pre;
            obj.ffe_coef = coef_pre;
            obj.data_cachelk = [data_pre data_in data_pst];
            data_conv = conv(obj.data_cachelk(obj.dmx_num + 1 - obj.ffe_npst: 2*obj.dmx_num + obj.ffe_npre), obj.ffe_coef); % Proceeding the current clk's data
            conv_out = data_conv(obj.ffe_npre + 1: end - obj.ffe_npst - obj.ffe_npre);
            obj.ffe_out = (adc_in - conv_out)/2^(6) + obj.ffe_out;
            delta_ffe_tap = zeros(1, length(obj.ffe_coef));
            % FFE LMS
            for id_tap = 1:length(obj.ffe_coef)
                if obj.ffe_lmsen_vec(id_tap) ~= 0
                    data_vec = obj.data_cachelk(obj.dmx_num + 1: 2*obj.dmx_num) - (id_tap - obj.ffe_main_idx);
                    delta_ffe_tap(id_tap) = sum(sign(data_vec) .* sign(obj.data_err));
                    obj.acc_ffe(id_tap) = obj.acc_ffe(id_tap) + delta_ffe_tap(id_tap);
                    if obj.acc_ffe(id_tap) > 2^obj.ffe_mu -1
                        obj.ffe_coef(id_tap) = obj.ffe_coef(id_tap) - 1;
                        obj.acc_ffe(id_tap) = obj.acc_ffe(id_tap) - 2^obj.ffe_mu;
                    elseif obj.acc_ffe(id_tap) < -2^obj.ffe_mu
                        obj.ffe_coef(id_tap) = obj.ffe_coef(id_tap) + 1;
                        obj.acc_ffe(id_tap) = obj.acc_ffe(id_tap) + 2^obj.ffe_mu;
                    end
                end
            end
            delta_heh = zeros(1,4);
            % HEH LMS
            if obj.heh_lms_en
                if obj.heh_lms_num == 1
                    delta_heh(3) = sum( sign(data_in) .* sign(obj.data_err) );
                    obj.acc_heh(3) = delta_heh(3) + obj.acc_heh(3);
                    if obj.acc_heh(3) > 2^obj.heh_mu -1
                        obj.heh(3) = obj.heh(3) - 1;
                        obj.acc_heh(3) = obj.acc_heh(3) - 2^obj.heh_mu;
                    elseif obj.acc_heh(3) < -2^obj.heh_mu
                        obj.heh(3) = obj.heh(3) + 1;
                        obj.acc_heh(3) = obj.acc_heh(3) + 2^obj.heh_mu;
                    end
                    obj.heh = obj.heh(3)*[-3 -1 1 3];
                else  % lms heh.num =4
                    for id_heh = 1:4
                        % delta_heh(id_heh) = sum( sign(obj.data_sliced).*sign(obj.data_err) .* (obj.data_sliced == obj.pam_sliced(id_heh)) );
                        delta_heh(id_heh) = sum( sign(data_in) .* sign(obj.data_err) .* (data_in == obj.pam_sliced(id_heh)) );
                        obj.acc_heh(id_heh) = delta_heh(id_heh) + obj.acc_heh(id_heh);
                        if obj.acc_heh(id_heh) > 2^obj.heh_mu -1
                            obj.heh(id_heh) = obj.heh(id_heh) - 1 * sign(obj.pam_sliced(id_heh));
                            obj.acc_heh(id_heh) = obj.acc_heh(id_heh) - 2^obj.heh_mu;
                        elseif obj.acc_heh(id_heh) < -2^obj.heh_mu
                            obj.heh(id_heh) = obj.heh(id_heh) + 1 * sign(obj.pam_sliced(id_heh));
                            obj.acc_heh(id_heh) = obj.acc_heh(id_heh) + 2^obj.heh_mu;
                        end
                    end
                end
            end
        end
    end
end
