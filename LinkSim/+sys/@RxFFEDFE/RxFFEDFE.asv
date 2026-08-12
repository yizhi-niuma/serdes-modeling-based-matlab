classdef RxFFEDFE
    properties
        modulation = 4;
        pam_sliced = [-3 -1 1 3];
        dmx_num = 32;
        data_cachelk = zeros(1,4^64);
        data_sliced;
        data_err;
        data_sliced_pre;
        data_err_pre;
        num_cache_clk;

        %dfe/ffe heh lms
        heh;
        heh_init = [-200 -100 100 200];
        heh_mu = 6;
        heh_lms_en = 1;
        heh_lms_num = 4; % NRZ=1, PAM4=4
        acc_heh = zeros(1,4);

        % ffe parameters
        % ffe_coef_len = 15;
        ffe_coef = [-1 -5 64 -7 -2 0];
        ffe_main_idx = 3;
        ffe_npre = 2;
        ffe_npst = 3;
        acc_ffe;
        ffe_lmsen_vec = [1 1 1 1 1 1]; % fix the tap coef
        ffe_mu = 7;
        ffe_out;
        ffe_coef_nbit = 7;
        ffe_out_nbits = 12;

        %dfe parameters
        % dfe_coef_len = 3 % default 2 tap
        dfe_ntap = 2;
        dfe_coef = [0 0 0];
        dfe_input = zeros(1,3);
        acc_dfe = zeros(1,3);
        dfe_lmsen_vec = [0 0 0];   % fix the tap coef
        dfe_input_pre;
        % dfe_coef_init = [3 0];
        dfe_mu = 6;
        dfe_out;
        % dfe_coef_nbit = 6;
        % dfe_out_nbits = 12;

        % floating ffe
        floating_flag; % Floating search switch
        fffe_en = 1;   % Floating ffe switch
        ffe_npst_fx;   % Fixed ffe length
        floating_pos;
        posi;  % floating ffe position
        fl_ffe_coef;

        %tunc
        nbit_trunc = 0;
        nbit_sat = 20;
    end

    methods
        function obj = RxFFEDFE(modulation, heh_init, heh_lms_en, heh_lms_num, ffe_coef_init, ffe_lmsen_vec, ffe_npst_fx, fffe_en, dfe_coef_init, dfe_lmsen_vec, num_dmx_rx)
            obj.modulation = modulation;
            obj.dmx_num = num_dmx_rx;
            obj.num_cache_clk = 128/num_dmx_rx; % cache length is fixed to 128, cache clk is variable according to input UI
            obj.data_cachelk = zeros(1,obj.num_cache_clk*obj.dmx_num);
            obj.data_err = zeros(1,obj.dmx_num);
            obj.data_sliced = -3*ones(1,obj.dmx_num);
            obj.heh = heh_init;
            obj.heh_lms_en = heh_lms_en;   % Enable ffe heh adaption,set zero when DFE is used
            obj.heh_lms_num = heh_lms_num;
            %ffe
            if fffe_en == 1
                obj.ffe_coef = zeros(1, 60); % roaming tap length
                obj.ffe_coef(5) = 64;
                obj.ffe_lmsen_vec = ones(1,60); % fix tap
                obj.ffe_lmsen_vec(5:6) = 0; % main and post-one equal to zero
            else
                obj.ffe_coef = ffe_coef_init;
                obj.ffe_lmsen_vec = ffe_lmsen_vec;
            end
            [~, obj.ffe_main_idx] = max(obj.ffe_coef); % find the main cursor
            obj.ffe_npre = obj.ffe_main_idx - 1;
            obj.ffe_npst = length(obj.ffe_coef) - obj.ffe_main_idx;
            obj.acc_ffe = zeros(1, length(obj.ffe_coef));

            %dfe
            obj.dfe_coef = dfe_coef_init;
            obj.dfe_ntap = length(dfe_coef_init);
            obj.dfe_input = zeros(1,length(dfe_coef_init));
            obj.acc_dfe = zeros(1,length(dfe_coef_init));
            obj.ffe_lmsen_vec = dfe_lmsen_vec;% fix dfe tap

            % floating ffe
            obj.fffe_en = fffe_en;
            obj.floating_flag = 1;
            obj.ffe_npst_fx = ffe_npst_fx; % fixed ffe length
            obj.fl_ffe_coef = zeros(1, obj.ffe_main_idx+ffe_npst_fx+12); % for floating ffe coefficients
        end
        function obj = ffe_dfe(obj, data_in, iclk)
            obj.data_sliced_pre = obj.data_sliced;
            obj.data_err_pre = obj.data_err;
            obj.data_cachelk = [obj.data_cachelk(obj.dmx_num*1 + 1: end) data_in]; % 每次丢掉一个clk
            num_cache_clk_idx = obj.num_cache_clk/2;

            if iclk >= 2000 && obj.fffe_en == 1 % floating ffe switch
                if obj.floating_flag == 1
                    obj = obj.floating_pos_sel(obj.ffe_coef);
                    obj.floating_flag = 0; % only search one time
                end
                % floating ffe 抽头重新开关设置
                all_Indices = 1:numel(obj.ffe_lmsen_vec); % 获取所有full ffe所有tap的开关索引
                remaining_Indices = setdiff(all_Indices, obj.posi); % 计算剩余的索引
                obj.ffe_lmsen_vec(remaining_Indices) = 0; % 关闭未被选中的fffe抽头的更新开关

                obj.fl_ffe_coef = obj.ffe_coef(obj.posi); % floating ffe
                conv_out = zeros(1, obj.dmx_num);

                for i = 1:obj.dmx_num
                    bufferfixed = obj.data_cachelk(obj.dmx_num*num_cache_clk_idx - i - obj.ffe_npst_fx*obj.dmx_num*num_cache_clk_idx + i + obj.ffe_npre);
                    bufferfloating = bufferfixed;
                    data_conv = [bufferfloating bufferfixed(end-(end-11) + obj.ffe_main_idx)];
                    conv_out(i) = obj.fl_ffe_coef(2:17)*data_conv';
                end
                obj.ffe_out = round(conv_out/2^obj.nbit_trunc); %
                obj.ffe_out = min(2^(obj.nbit_sat-1)-1, max(obj.ffe_out, -2^(obj.nbit_sat-1)));
                % obj.ffe_out = max(-2^(nbit_sat-1)-1, min(obj.ffe_out, 2^(nbit_sat-1)-1));
            else % ffe
                data_conv = obj.data_cachelk(obj.dmx_num*num_cache_clk_idx - 1 - obj.ffe_npst: (num_cache_clk_idx-1)*obj.dmx_num + obj.ffe_npre); % Proceeding the current clk's data
                conv_out = conv(data_conv, obj.ffe_coef);
                % conv_out = round(conv(data_conv, obj.ffe_coef)/divid_value);
                obj.ffe_out = conv_out(obj.ffe_npre + 1: end - obj.ffe_npst - obj.ffe_npre);
                obj.ffe_out = round(obj.ffe_out/2^obj.nbit_trunc); % 2 先截位
                obj.ffe_out = min(2^(obj.nbit_sat-1)-1, max(obj.ffe_out, -2^(obj.nbit_sat-1))); %11 再饱和
            end

            for idx = 1:obj.dmx_num
                if idx < obj.dfe_ntap + 1 % 当前clk dfe输出还不够作为输入的长度
                    data_dfe = [obj.data_sliced(idx - 1: -1: 1)   obj.data_sliced_pre(end - 1: end - obj.dfe_ntap + 1 + length(obj.data_sliced(idx - 1: -1: 1)))];
                else
                    data_dfe = obj.data_sliced(idx - 1: -1: idx-obj.dfe_ntap);
                end

                id_heh = (data_dfe + 3)/2 + 1;
                data_dfe_heh = obj.heh(id_heh);
                obj.dfe_out(idx) = obj.ffe_out(idx) - round(data_dfe_heh*obj.dfe_coef/2^6); % limit dfe bitwidth to 6bit
                [~, obj.data_sliced(idx), obj.data_err(idx)] = f_slicer(obj.modulation, obj.dfe_out(idx), obj.heh);
            end
            obj.dfe_out = max(-2^(obj.nbit_sat-1)-1, min(obj.dfe_out, 2^(obj.nbit_sat-1)-1));
            delta_heh = zeros(1,4);
            delta_ffe_tap = zeros(1, length(obj.ffe_coef));
            delta_dfe_tap = zeros(1, obj.dfe_ntap);
            % HEH LMS
            if obj.heh_lms_en
                if obj.heh_lms_num == 1
                    delta_heh(3) = sum( sign(obj.data_sliced) .* sign(obj.data_err) );
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
                        delta_heh(id_heh) = sum( sign(obj.data_sliced).*sign(obj.data_err) .* (obj.data_sliced == obj.pam_sliced(id_heh)) );
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
            obj.heh = max(-2^(obj.nbit_sat-1)-1, min(obj.heh, 2^(obj.nbit_sat-1)-1));

            % FFE LMS
            for id_tap = 1:length(obj.ffe_coef)
                if obj.ffe_lmsen_vec(id_tap) ~= 0
                    x_vec = obj.data_cachelk( (obj.dmx_num*num_cache_clk_idx + 1: (num_cache_clk_idx+1)*obj.dmx_num) - (id_tap - obj.ffe_main_idx) );
                    delta_ffe_tap(id_tap) = sum( sign(x_vec) .* sign(obj.data_err) );
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
            % DFE LMS
            for id_tap = 1: obj.dfe_ntap
                if obj.dfe_lmsen_vec(id_tap) ~= 0
                    data_vec = [obj.data_sliced_pre(end-id_tap+1 : end) obj.data_sliced(1:end- id_tap)];
                    delta_dfe_tap(id_tap) = sum( sign(data_vec).* sign(obj.data_err) );
                    obj.acc_dfe(id_tap) = obj.acc_dfe(id_tap) + delta_dfe_tap(id_tap);
                    if obj.acc_dfe(id_tap) > 2^obj.dfe_mu - 1
                        obj.dfe_coef(id_tap) = obj.dfe_coef(id_tap) - 1;
                        obj.acc_dfe(id_tap) = obj.acc_dfe(id_tap) - 2^obj.dfe_mu;
                    elseif obj.acc_dfe(id_tap) < -2^obj.dfe_mu
                        obj.dfe_coef(id_tap) = obj.dfe_coef(id_tap) + 1;
                        obj.acc_dfe(id_tap) = obj.acc_dfe(id_tap) + 2^obj.dfe_mu;
                    end
                end
            end
        end
        
        function obj = floating_pos_sel(obj, ffe_coef) % 动态规划
            array = ffe_coef(obj.ffe_main_idx + obj.ffe_npst_fx + 1: end); % 取post-cursor固定抽头长度之后的抽头值
            n = length(array);
            if n < 12 % Need at least 12 elements to form 6 pairs
                maxSum = 0;
                bestCombination = [];
                return;
            end
            DP = zeros(n, 6);
            DP(2, 1) = sum(abs(array(1:2)));

            for i = 3:n
                for j = 1:6
                    DP(i, j) = DP(i-1, j); % Default: Don't use the current pair
                    if j == 1
                        DP(i,1) = max(DP(i,1), abs(array(i-1)) + abs(array(i)));
                        continue
                    end
                    if i >= 2*j % Check for valid pair and sufficient elements
                        DP(i,j) = max(DP(i,j), DP(i-2, j-1) + abs(array(i-1)) + abs(array(i)));
                    end
                end
            end
            maxSum = DP(n, 6);

            % Backtracking
            bestCombination = backtrack(DP); % recall back
            if length(bestCombination) < 12
                bestCombination = [1:12-length(bestCombination), bestCombination];
            end
            obj.posi = [(1:obj.ffe_main_idx + obj.ffe_npst_fx), obj.ffe_main_idx + obj.ffe_npst_fx + bestCombination];

            function bestComb = backtrack(DP)
                bestComb = [];
                i = n;
                j = 6;
                while j > 1 && i >= 2
                    if DP(i,j) > DP(i-1,j)
                        bestComb = [i-1, i, bestComb];
                        i = i - 2;
                        j = j - 1;
                    else
                        i = i - 1;
                    end
                end
            end
        end
    end
end
