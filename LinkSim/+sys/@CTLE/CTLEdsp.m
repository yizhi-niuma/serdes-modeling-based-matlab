classdef (StrictDefaults) CTLE < serdes.SerdesAbstractSystemObject
   
    properties(Nontunable) %port/property duality
        %ModePort ModePort
        % Specify Mode from input port in Simulink
        ModePort (1, 1) logical = true;
    end
    properties
        %Mode Mode (0: Off, 1: Fixed, 2: Adapt Init only)
        % When Mode=0, the CTLE is bypassed and the waveform is not
        % modified. When Mode=1, the CTLE applies the transfer function
        % specified by the ConfigSelect property. When Mode=2 and
        % WaveType is 'Impulse' or 'Waveform', the CTLE selects and
        % applies the ConfigSelect which best opens the eye. When Mode=2
        % and WaveType is 'Sample' the CTLE behavior is the same Mode=1
        % (fixed).
        Mode = 2;

        %adaptation
        dc_adapt_en = 1;
        pk_adapt_en = 0;
        dc_code_init = 8;
        pk_code_init = 8;
        dc_tap_wght = [1 1 1 1  1 1 1 1  1 1 1 1  1 1 1 1];
        pk_tap_wght = [1 1 1 1  1 1 1 1  1 1 1 1  1 1 1 1];
        dc_line_num = 32;
        pk_line_num = 32;
        %tap_weight = [15 10 6 4 2 1 1 1 1  1 1 1 1 1  0 0 0 0 0];
        idx_start =1;
        idx_len =16;
        predata_sum = zeros(1,32);
        acc = 0;
        mu = 8;

        %ctle train slv=------------------------------
        adc_data;
        dfe_data;
        adc_data_int;
        pst_cursor_adc_data_int;
        bst_en = 1;
        fpk_en =0;
        dlevel_r = [-30 -10 10 30]*1;
        ctle_th_adapt_gain_r;
        bst_dis_req
        % bst_code_init = 15;  % 4-bit
        fpk_dis_req
        % fpk_code_init = 15;  % 4-bit

        error;
        dlev_acc_nxt = [0 0 0 0];
        dlev_acc_nxt_pre = [0 0 0 0];
        dlev_vote_nxt;
        dlev_vote_acc_nxt= [0 0 0 0];
        dlev_vote_acc_nxt2= [0 0 0 0];
        dlev_vote_acc_nxt2_pre = [0 0 0 0];
        dlev_vote_acc_r = [0 0 0 0];

        dlev_acc_r_pre = [-30 -10 10 30]*1*2^6;
        dlev_acc_r = [-30 -10 10 30]*1*2^6;
        dlev_acc_update_nxt = [0 0 0 0];
        PAML = 4;
        adcr_frac = 2;

        num_update = 8;%8
        taps = 5;
        isi_th_scaled_r = [120  90  30   0   0];
        isi_th_scaled_isi = [120  90  30   0   0];
        residual_isi;
        corr_per_tap_int = zeros(8,5);
        corr_per_tap_int_pre ;%= zeros(8,5);
        corr_acc_nxt_p1m1 = ones(1,8);
        corr_acc_nxt2=8;
        corr_acc_nxt3= 8;
        corr_acc_r = 0;
        ctle_acc_nxt=(0+8)*2^(6+6);
        ctle_acc_r = (0+8)*2^(6+6);
        corr_per_tap_x_wght = zeros(8,5);
        corr_acc_nxt
        ctle_bst_code
        ctle_fpk_code = 7;

    end
    properties %ISI
        %===CFG
        isi_num_update = 16;%16
        itaps = 7;
        isi_th_taps_frac=[0 1 2 3 0 0 0];%C(-3):C(4)- C(0)
        isi_gain = 0;
        isi_mode_sel = [0 0 0 0 0 0 0];
        isi_stat_en_s3r = 1;
        isi_acc_en =1;
        %stats_sample_on_cycle_d1 =1;  %stats_doing
        ctle_isi_acc_reverse = 0;
        isi_corr_sign_mode = 0;
        %===internal signal
        taps_dfe_data_mod;
        isi_th_scaled_pre_r;
        error_adj;
        residual_isi_adj;
        crsr_adc_data;
        crsr_dfe_data;
        corr_isi_per_tap_int;
        corr_isi_acc_nxt;
        corr_isi_sign_per_tap_r;
        corr_isi_acc_r = [0 0 0 0 0 0 0];
        corr_isi_acc_update;
        cor_isi_acc2_nxt = [0 0 0 0 0 0 0];
        cor_isi_acc2_r=[0 0 0 0 0 0 0];
        isi_cor=[0 0 0 0 0 0 0];
    end
    properties (Nontunable)
        %Specification
        % Set the Specification to 'DC Gain and Peaking Gain', 'DC Gain
        % and AC Gain', 'AC Gain and Peaking Gain' or 'GPZ Matrix'. The
        % default is 'DC Gain and Peaking Gain'.
        Specification = 'DC Gain and Peaking Gain';
    end

    properties(Constant, Hidden)
        SpecificationSet = matlab.system.StringSet({ ...
            'DC Gain and Peaking Gain', ...
            'DC Gain and AC Gain', ...
            'AC Gain and Peaking Gain', ...
            'GPZ Matrix'});
    end

    properties(Nontunable) %port/property duality
        %SliceSelectPort SliceSelectPort
        % Specify SliceSelect from input port in Simulink
        SliceSelectPort (1, 1) logical = false;
    end

    properties
        %Slice index select
        % Dimensional selection of the GPZ Matrix, SliceSelect is a
        % zero-based index. Default is SliceSelect = 0.
        SliceSelect = 0;
    end

    properties(Nontunable) %port/property duality
        %ConfigSelectPort ConfigSelectPort
        %Enable input port in Simulink
        ConfigSelectPort (1, 1) logical = true;
    end

    properties
        %Configuration select
        % Selects which member of the transfer function to apply when
        % Mode=1. ConfigSelect is a zero-based index.
        ConfigSelect = 0;
    end

    methods
        % Constructor
        function obj = CTLE(varargin)
            % Support name-value pair arguments when constructing object
            obj.BlockName = 'CTLE';
            setProperties(obj,nargin,varargin{:})
            if obj.ctle_fast_en
                if obj.DCGain>-9
                    obj.mu = obj.ctle_adapt_gain_pre_lock+7;
                else
                    obj.mu = obj.ctle_adapt_gain_pre_lock+8;
                end
            else
                obj.mu = obj.ctle_adapt_gain_post_lock+8;
            end
            obj.dc_code_init = obj.DCGain + 10;
            %obj.pk_code_init = obj.DCGain + 10;
        end

        % adaptation DCGAIN
        function obj = adaptation_DCGAIN(obj, data, data_pre, error, error_pre, iclk_1G,stats_sample_on_cycle,stats_sample_valid)
            % if iclk_1G == 9134+490
            %  pause(1)
            % end
            err_2clk = [error_pre error];
            data_2clk = [data_pre data];
            %for id_ui = 32:-1:32-obj.dc_line_num+1
            for id_ui = 32:-1:1
                % obj.predata_sum(id_ui) = sum(obj.dc_tap_wght.*sign( data_2clk(id_ui+32 - obj.idx_start - obj.idx_len+1: id_ui+32 - obj.idx_start)) ...
                %  .*sign(error(id_ui)));
                obj.predata_sum(id_ui) = sum(obj.dc_tap_wght.*sign( data_2clk(id_ui+32 - obj.idx_start -1: id_ui+32 - obj.idx_start - obj.idx_len+1)) ...
                    .*sign(error(id_ui)));
            end
            delta = sum(sign(obj.predata_sum(32:-1:32-obj.dc_line_num+1)));
            if stats_sample_on_cycle
                if obj.acc>2^obj.mu -1 || obj.acc<-2^obj.mu
                    obj.acc = obj.acc;
                else
                    obj.acc = obj.acc+delta;
                end
            end

            if stats_sample_valid
                if obj.acc > 2^obj.mu -1
                    obj.DCGain = obj.DCGain +1* (0.5-obj.ctle_acc_reverse )*2;
                    %obj.PeakingFrequency = obj.PeakingFrequency -0.5e9;
                    obj.acc = obj.acc - 2^obj.mu;
                elseif obj.acc < -2^obj.mu
                    obj.DCGain = obj.DCGain -1*(0.5-obj.ctle_acc_reverse )*2;
                    % obj.PeakingFrequency = obj.PeakingFrequency+0.5e9;
                    obj.acc = obj.acc + 2^obj.mu;
                end
            end
            % obj.DCGain=min(15, max(obj.DCGain, -15));
            ctle_dc_code = obj.DCGain + 10;
            %ctle_pk_code = obj.DCGain + 10;
        end

        function obj = ctle_train(obj, adc_data, dfe_data, stats_doing, stats_vld, stats_doing_d1, stats_vld_d1, stats_sample_on_cycle_d1, stats_sample_doing_d1, stats_sample_valid_d2, stats_sample_on_cycle_d3, iclk_1G)
            stats_sample_on_cycle_d1 = stats_doing_d1;
            obj.adc_data = adc_data;
            obj.dfe_data = dfe_data;
            dfe_data_int = (dfe_data(end-obj.num_update+1:end)+3)/2;
            obj.dfe_data = (dfe_data + 3)/2;

            dlev_ctle_adapt_en = obj.dlev_adapt_en || obj.ctle_boost_adapt_en || obj.ctle_fpk_adapt_en;
            dlev_ctle_pam4 = dlev_ctle_adapt_en && obj.pam4_mode;
            dlev_ctle_adapt_en_pam_mode = [dlev_ctle_adapt_en, dlev_ctle_pam4, dlev_ctle_pam4, dlev_ctle_adapt_en];

            dlev_pam4 = obj.dlev_adapt_en&&obj.pam4_mode;
            dlev_adapt_en_mode = [obj.dlev_adapt_en, dlev_pam4, dlev_pam4, obj.dlev_adapt_en];

            if ~obj.i_ctle_fst_en
                obj.ctle_th_adapt_gain_r = obj.ctle_th_adapt_gain_pstlock;
            else
                obj.ctle_th_adapt_gain_r = obj.ctle_th_adapt_gain_prelock;
            end
            pst_cursor_dfe_data_int = dfe_data(end - (obj.num_update + obj.taps)+1: end);
            switch obj.cursor_sel
                case 32
                    obj.adc_data_int = adc_data(end-obj.num_update+1: end);
                    obj.pst_cursor_adc_data_int = adc_data(end-(obj.num_update + obj.taps)+1: end);
                case 16
                    obj.adc_data_int = adc_data(end-1 - obj.num_update+1: end-1);
                    obj.pst_cursor_adc_data_int = adc_data(end-1 - (obj.num_update + obj.taps)+1: end-1);
                case 8
                    obj.adc_data_int = adc_data(end-2 - obj.num_update+1: end-2);
                    obj.pst_cursor_adc_data_int = adc_data(end-2 - (obj.num_update + obj.taps)+1: end-2);
                case 4
                    obj.adc_data_int = adc_data(end-3 - obj.num_update+1: end-3);
                    obj.pst_cursor_adc_data_int = adc_data(end-3 - (obj.num_update + obj.taps)+1: end-3);
                case 2
                    obj.adc_data_int = adc_data(end-4 - obj.num_update+1: end-4);
                    obj.pst_cursor_adc_data_int = adc_data(end-4 - (obj.num_update + obj.taps)+1: end-4);
                case 1
                    obj.adc_data_int = adc_data(end-5 - obj.num_update+1: end-5);
                    obj.pst_cursor_adc_data_int = adc_data(end-5 - (obj.num_update + obj.taps)+1: end-5);
            end

            %============LMS Error Computation=============
            for id = 1:obj.num_update
                obj.error(id) = obj.adc_data_int(id).^2*obj.adcr_frac - obj.dlevel_r(dfe_data_int(id)+1);
            end
            obj.error = max(-2^9, min(obj.error,2^9-1));
            % obj.ctle_err = obj.error;
            %========dlev adaptation======================

            for ipam = 1: obj.PAML
                for j=1: obj.num_update
                    if dfe_data_int(j)+1 == ipam
                        if obj.error(j) < 0
                            obj.dlev_vote_nxt(ipam, j) = -1;
                        else
                            obj.dlev_vote_nxt(ipam, j) = +1;
                        end
                    else
                        obj.dlev_vote_nxt(ipam, j) = 0;
                    end
                end

                obj.dlev_vote_acc_nxt(ipam) = obj.dlev_vote_acc_r(ipam);
                for j = 1:obj.num_update
                    obj.dlev_vote_acc_nxt(ipam) = obj.dlev_vote_acc_nxt(ipam) + obj.dlev_vote_nxt(ipam, j);
                end

                % obj.dlev_vote_acc_nxt2_pre(ipam) = obj.dlev_vote_acc_nxt2(ipam);
                if obj.dlev_vote_acc_nxt(ipam) > 1023
                    obj.dlev_vote_acc_nxt2(ipam) = 1023;
                elseif obj.dlev_vote_acc_nxt(ipam) < -1024
                    obj.dlev_vote_acc_nxt2(ipam) = -1024;
                else
                    obj.dlev_vote_acc_nxt2(ipam) = obj.dlev_vote_acc_nxt(ipam);
                end

                if dlev_ctle_adapt_en_pam_mode(ipam) && stats_doing
                    % obj.dlev_vote_acc_r(ipam) = obj.dlev_vote_acc_nxt2_pre(ipam);
                    obj.dlev_vote_acc_r(ipam) = obj.dlev_vote_acc_nxt2(ipam);
                elseif ~stats_sample_on_cycle_d1
                    obj.dlev_vote_acc_r(ipam) = 0;
                end

                if obj.dlev_vote_acc_r(ipam) >= 0  %match with rtl
                    obj.dlev_acc_update_nxt(ipam) = 1*sign(0.5-obj.dlev_acc_reverse);
                else
                    obj.dlev_acc_update_nxt(ipam) = -1*sign(0.5-obj.dlev_acc_reverse);
                end

                %obj.dlev_acc_r_pre(ipam) = obj.dlev_acc_r(ipam);
                %obj.dlev_acc_nxt_pre(ipam) = obj.dlev_acc_nxt(ipam);
                obj.dlev_acc_nxt(ipam) = obj.dlev_acc_r(ipam) + 2*obj.ctle_th_adapt_gain_r * obj.dlev_acc_update_nxt(ipam);

                if dlev_adapt_en_pam_mode(ipam) && stats_vld
                    obj.dlev_acc_r(ipam) = max(-2^14, min(2^14-1,obj.dlev_acc_nxt(ipam)));
                    obj.dlev_acc_nxt(ipam) = obj.dlev_acc_r(ipam) + 2*obj.ctle_th_adapt_gain_r * obj.dlev_acc_update_nxt(ipam);
                end
                obj.dlevel_r(ipam) = floor(obj.dlev_acc_r(ipam) / 2^6);
            end
            %obj.dlevel_r =[-120 -40 40 120];
            dlevel_for_scaling =obj.dlevel_r (~obj.pam4_mode+3);
            % obj.ctle_dlev_o =obj.dlevel_r;

            post_cursor_dfe_data_mod = abs(pst_cursor_dfe_data_int(1:obj.num_update + obj.taps));

            for k=1: obj.taps
                obj.isi_th_scaled_r(k) = dlevel_for_scaling * obj.isi_th_frac(k);
            end
            obj.corr_per_tap_int_pre = obj.corr_per_tap_int;
            for j=1:obj.num_update
                for k=1:obj.taps
                    if obj.pam4_mode
                        obj.residual_isi(j,k) = floor( post_cursor_dfe_data_mod(j+k-1)*obj.isi_th_scaled_r(k)/2^5);  %%6-k@10 clk
                    else
                        obj.residual_isi(j,k) = floor(obj.isi_th_scaled_r(k)/2^5);
                    end

                    if obj.pst_cursor_adc_data_int(j+k-1) < 0
                        obj.corr_per_tap_int(j,k) = -obj.error(j) - obj.residual_isi(j,k);
                    else
                        obj.corr_per_tap_int(j,k) =  obj.error(j) - obj.residual_isi(j,k);
                    end
                end
            end
            corr_per_tap_r =  obj.corr_per_tap_int_pre;  %%% delay one clk

            corr_per_tap_x_wght_r =obj.corr_per_tap_x_wght;  %%% delay one clk
            for k = 1: length(obj.bst_tap_weight_mode1)
                obj.corr_per_tap_x_wght(k) = corr_per_tap_r(:,k).*obj.bst_tap_weight_mode1(k);
            end
            % corr_per_tap_x_wght_r =obj.corr_per_tap_x_wght;  %%% delay one clk

            corr_acc_nxt_p1m1_r = obj.corr_acc_nxt_p1m1;  %%% delay one clk

            for j=1:obj.num_update
                obj.corr_acc_nxt(j) = sum(corr_per_tap_x_wght_r(j,:));
                if obj.corr_acc_nxt(j) >= 0
                    obj.corr_acc_nxt_p1m1(j) = 1;
                else
                    obj.corr_acc_nxt_p1m1(j) = -1;
                end
            end
            corr_acc_nxt3_pre = obj.corr_acc_nxt3;

            if (obj.dlev_adapt_en || obj.ctle_boost_adapt_en) && stats_sample_on_cycle_d2  % stats_doing_d1
                obj.corr_acc_r = corr_acc_nxt3_pre;
            elseif ~stats_sample_on_cycle_d3  %%%%should delay one clk
                obj.corr_acc_r = 0;
            end

            obj.corr_acc_nxt2 = obj.corr_acc_r + sum(corr_acc_nxt_p1m1_r);
            % obj.corr_acc_nxt2 = obj.corr_acc_r + sum(obj.corr_acc_nxt_p1m1);
            obj.corr_acc_nxt3 = min(1023,max(-1024, obj.corr_acc_nxt2));  %%%%should delay one clk

            reg_coef = 1;
            ctle_acc_nxt_pre = obj.ctle_acc_nxt;

            if obj.ctle_boost_adapt_en && stats_sample_valid_d2
                obj.ctle_acc_r = min(2^(10+6)-1,max(0, ctle_acc_nxt_pre));
            end

            corr_acc_sign_r = sign(0.5 - obj.bst_acc_reverse)*reg_coef*sign(obj.corr_acc_r+0.1);
            if obj.ctle_fast_en
                obj.ctle_acc_nxt = obj.ctle_acc_r + corr_acc_sign_r*2^(obj.bst_adapt_gain_prelock);
            else
                obj.ctle_acc_nxt =  obj.ctle_acc_r + corr_acc_sign_r*2^(obj.bst_adapt_gain_pstlock);
            end

            % if obj.ctle_acc_nxt <0
            %
            %     pause(1)
            %
            % end


            % obj.ctle_bst_code = floor(obj.ctle_acc_r/2^(6+6));

            obj.ctle_bst_code = floor(obj.ctle_acc_r/2^(6+6));

            obj.DCGain = obj.ctle_bst_code -8;
            %===================ISI====================
            csr_adj = 3;
            %===
            obj.taps_dfe_data_mod = abs(dfe_data(32-(obj.isi_num_update-1)-(obj.itaps-1)+1 : ...
                32-(obj.isi_num_update-1)-(obj.itaps-1)+22 ));
            taps_adc_data_int =  adc_data(end - csr_adj-21: end - csr_adj-2 - obj.isi_num_update - obj.itaps+1);
            taps_dfe_data_int =  obj.dfe_data(end-1: end-1 - obj.isi_num_update);

            obj.crsr_adc_data = adc_data(end - csr_adj-5: end-csr_adj-5-obj.isi_num_update+1);
            obj.crsr_dfe_data = obj.dfe_data(end - csr_adj-1: end-csr_adj-obj.isi_num_update+1);

            for k = 1:obj.itaps
                if ~obj.isi_stat_en_s3r
                    obj.isi_th_scaled_pre_r(k) = 0;
                else
                    obj.isi_th_scaled_pre_r(k) = dlevel_for_scaling*obj.isi_th_taps_frac(k);
                end
            end

            for i= 1: obj.isi_num_update
                obj.error_adj(i) = obj.crsr_adc_data(i)*2^2 - obj.dlevel_r(obj.crsr_dfe_data(i)+1);
            end

            for j=1:obj.isi_num_update
                k=1;
                if obj.pam4_mode
                    obj.residual_isi_adj(j,1) = floor(obj.taps_dfe_data_mod(j+k-1)*obj.isi_th_scaled_pre_r(k)/2^5);
                else
                    obj.residual_isi_adj(j,1) = floor(obj.isi_th_scaled_pre_r(k)/2^5);
                end
                if (obj.isi_corr_sign_mode && taps_adc_data_int(j) < 0) || (~obj.isi_corr_sign_mode && taps_dfe_data_int(j)<2)
                    obj.corr_isi_per_tap_int(j,1) = -1*obj.error_adj(j)-obj.residual_isi_adj(j,1);
                else
                    obj.corr_isi_per_tap_int(j,1) = obj.error_adj(j)-obj.residual_isi_adj(j,1);
                end
                for k=2:obj.itaps
                    if obj.pam4_mode
                        obj.residual_isi_adj(j,k) = floor(obj.taps_dfe_data_mod(j+k-1)*obj.isi_th_scaled_pre_r(k)/2^5);
                    else
                        obj.residual_isi_adj(j,k) = floor(obj.isi_th_scaled_pre_r(k)/2^5);
                    end
                    if (obj.isi_corr_sign_mode && taps_adc_data_int(j+k-1) < 0) || (~obj.isi_corr_sign_mode && taps_dfe_data_int(j+k-1)<2)
                        obj.corr_isi_per_tap_int(j,k) = -1*obj.error_adj(j)-obj.residual_isi_adj(j,k);
                    else
                        obj.corr_isi_per_tap_int(j,k) = obj.error_adj(j)-obj.residual_isi_adj(j,k);
                    end
                end
            end


            for j = 1:obj.num_update
                for k = 1:obj.itaps

                    if obj.isi_mode_sel(k)
                        obj.corr_isi_sign_per_tap_r(j,k) = sign(obj.corr_isi_per_tap_int(j,k)-1e-15);
                    else
                        obj.corr_isi_sign_per_tap_r(j,k) = 0;
                    end
                end
            end

            for k=1:obj.itaps
                for j=1:obj.num_update
                    if j==1
                        obj.corr_isi_acc_nxt(k) = obj.corr_isi_acc_r(k) + obj.corr_isi_sign_per_tap_r(1,k);
                    else
                        obj.corr_isi_acc_nxt(k) = obj.corr_isi_acc_nxt(k) + obj.corr_isi_sign_per_tap_r(j,k);
                    end
                end
            end
            obj.corr_isi_acc_nxt = min(max(obj.corr_isi_acc_nxt, -1024), 1023);

            for ig=1:obj.itaps
                if ~obj.isi_stat_en_s3r || ~obj.isi_acc_en || stats_sample_on_cycle_d1
                    obj.corr_isi_acc_r(ig) = 0;
                else
                    obj.corr_isi_acc_r(ig) = obj.corr_isi_acc_nxt(ig);
                end

                if obj.corr_isi_acc_r(ig)>=0  %%%?
                    obj.corr_isi_acc_update(ig) = 2*(0.5 - obj.ctle_isi_acc_reverse);
                else
                    obj.corr_isi_acc_update(ig) = 2*(obj.ctle_isi_acc_reverse - 0.5);
                end

                obj.cor_isi_acc2_nxt(ig) = obj.cor_isi_acc2_r(ig) + 2^obj.isi_gain*obj.corr_isi_acc_update(ig);

                if ~obj.isi_stat_en_s3r || ~obj.isi_acc_en
                    obj.cor_isi_acc2_r(ig) = 0;
                else
                    obj.cor_isi_acc2_r(ig) = min(4095, max(obj.cor_isi_acc2_nxt(ig), -4096));
                end

                obj.isi_cor(ig) = floor(obj.cor_isi_acc2_r(ig)/2^6);
            end



        end
    end

end