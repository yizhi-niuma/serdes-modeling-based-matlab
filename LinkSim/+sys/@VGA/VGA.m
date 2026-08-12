classdef (StrictDefaults) VGA < serdes.SerdesAbstractSystemObject
    % VGA Variable Gain Amplifier (VGA)
    %   block = serdes.Gain returns a System object, block, that modifies a
    %   input waveform according to the variable gain amplifier block

    properties(Nontunable) %port/property duality
        %ModePort ModePort
        %   Specify Mode from input port in Simulink
        ModePort(1, 1) logical = true;
    end

    properties
        %Mode Mode (0: Off; 1: On)
        %   When Mode=0 the VGA is bypassed. When Mode=1, the VGA applies
        %   the gain to the input waveform.
        Mode = 1;
    end

    properties(Nontunable) %port/property duality
        %GainPort GainPort
        %Specify Gain from input port in Simulink
        GainPort(1, 1) logical = true;
    end

    properties
        %Gain
        %   Multiplicative gain used to scale the input waveform.
        vga_en = 1;
        vga_adapt_en = 1;
        peak_detect_en = 1;
        att_en = 1;
        att_adapt_en = 1;
        vga_fast_en = 0;
        peak_det_cnt = 1;
        vga_target = 52;
        vga_adapt_gain_pre_lock = 4;
        vga_adapt_gain_post_lock = 2;
        vga_init_code = 16;
        vga2att_cnt_max = 16;
        att_init_gain = 0;
        vga_code_max = 2047;
        vga_code_min = 0;%5*64;
        att_code_max = 127;
        att_code_min = 0;
        att_code0 = 0;
        att_code1 = 1;
        vga_init_code_for_att_chg = 15;
        vga_code_chg_reverse = 0;
        att_code_chg_reverse = 0;
        line_num = 32;

        data_adc;
        adc_data_mod_peak;
        peak_det_cnt_ff1 = 0; %default 0
        Gain;
        att_gain = 0;
        Num;
        Den;

        adc_data_peak_nxt = 0;
        adc_data_peak_accum_nxt = 0;
        adc_data_peak_accum_r = 0;
        adc_data_peak_cnt_ff1 = 0;
        adc_data_peak_r = 0;
        adc_data_peak_accum_avg_int = 0;
        adc_data_peak_accum_avg_nxt = 0;
        adc_data_peak_accum_avg_ff1 = 0;
        acc_update_nxt = 0;
        acc_ff1;
        att_acc_ff1 = 0;
        att_acc_nxt = 0;
        vga_sat_cnt = 0;
        code_vga;
        att_lvl_code = 0;
        att_lvl_int = 0;
        att_lvl_ff1 = 0;
        att_lvl_ff2 = 0;
        overflow_unflow_flag
        acc_ff1_ovf_uovf = 0;
    end

    properties (SetAccess = immutable, Nontunable, Hidden)
        IsLinear = true;
        IsTimeInvariant = true;
    end

    properties(Hidden, Constant)
        SymbolTimeAttributes = {'NoDisplayInSerDesDesignerApp'};
        SampleIntervalAttributes = {'NoDisplayInSerDesDesignerApp'};
        ModulationAttributes = {'NoDisplayInSerDesDesignerApp'};

        GainSet = matlab.system.SourceSet(...
            {'PropertyOrInput', 'SystemBlock', 'GainPort', 2, 'Gain'}, ...
            {'Property', 'MATLAB', 'GainPort'});

        ModeSet = matlab.system.SourceSet(...
            {'PropertyOrInput', 'SystemBlock', 'ModePort', 1, 'Mode'}, ...
            {'Property', 'MATLAB', 'ModePort'});

        Mode_ToolTip = getString(message('serdes:serdesdesigner:VGAMode_ToolTip'));
        Gain_ToolTip = getString(message('serdes:serdesdesigner:VGAGain_ToolTip'));
    end
        methods
            % Constructor
            function obj = VGA(varargin)
                obj.BlockName = 'VGA';
                obj.Gain = (obj.vga_init_code - 10)*1;
                obj.att_gain = obj.att_init_code*(-6); %round(obj.att_acc_ff1 / 2^6);
                obj.acc_ff1 = obj.vga_init_code*2^6;
                setProperties(obj,nargin,varargin{:})
            end

            function waveOut = wave_pass(obj,waveIn)
                t = 1:length(waveIn);

                %t=(1:10000)/10^4;
                if modelsOn(obj)
                    waveOut = waveIn*10^(obj.Gain/20);
                    % vga_tf = tf(obj.Num, obj.Den);
                    % waveOut = lsim(vga_tf, waveOut, t);
                else
                    waveOut = waveIn;
                end
            end

            function waveOut = wave_pass_att(obj,waveIn)
                t = 1:length(waveIn);

                %t=(1:10000)/10^4;
                if modelsOn(obj)
                    waveOut = waveIn*10^(obj.att_gain/20);
                    % vga_tf = tf(obj.Num, obj.Den);
                    % waveOut = lsim(vga_tf, waveOut, t);
                else
                    waveOut = waveIn;
                end
            end
            
            function [code_vga, att_lvl_code] = vga_train(obj, data_adc, clk_1G, stats_sample_on_cycle, stats_sample_valid, ...
                                                                          stats_sample_on_cycle_d1, stats_sample_valid_d1)

            % stats_sample_on_cycle = 1;
            obj.data_adc = data_adc;
            num_update = obj.line_num;
            switch obj.peak_det_cnt
                case 0
                    peak_det_cnt_max = 16;
                case 1
                    peak_det_cnt_max = 25;
                case 2
                    peak_det_cnt_max = 32;
                case 3
                    peak_det_cnt_max = 50;
                case 4
                    peak_det_cnt_max = 64;
                case 5
                    peak_det_cnt_max = 80;
                case 6
                    peak_det_cnt_max = 100;
                case 7
                    peak_det_cnt_max = 127;
            end
            % peak_det_cnt_max = 16;%25/32/50/64/80/100/127
            if obj.vga_fast_en
                vga_adapt_gain = obj.vga_adapt_gain_pre_lock; %2/4/8/16/32/64/128
            else
                vga_adapt_gain = obj.vga_adapt_gain_post_lock;
            end
            data_abs = abs(data_adc(end-num_update+1:end));

            if stats_sample_on_cycle
                obj.adc_data_mod_peak = max(data_abs);
            else
                % obj.adc_data_mod_peak = 0;
            end

            if obj.peak_detect_en && stats_sample_on_cycle_d1
                obj.adc_data_peak_r = obj.adc_data_peak_nxt;
                if obj.peak_det_cnt_ff1 == peak_det_cnt_max
                    obj.peak_det_cnt_ff1 = 0;
                else
                    obj.peak_det_cnt_ff1 = obj.peak_det_cnt_ff1 + 1;
                end
            end

            if obj.adc_data_mod_peak >= obj.adc_data_peak_r
                obj.adc_data_peak_nxt = obj.adc_data_mod_peak;
            elseif obj.peak_det_cnt_ff1 == peak_det_cnt_max
                obj.adc_data_peak_nxt = obj.adc_data_peak_r - 1;
            else
                obj.adc_data_peak_nxt = obj.adc_data_peak_r;
            end

            if obj.adc_data_peak_cnt_ff1 == 0
                obj.adc_data_peak_accum_nxt = obj.adc_data_peak_nxt;
            else
                obj.adc_data_peak_accum_nxt = obj.adc_data_peak_nxt + obj.adc_data_peak_accum_r;
            end
            obj.adc_data_peak_accum_avg_int = floor(obj.adc_data_peak_accum_nxt / 32);
            obj.adc_data_peak_accum_avg_nxt = floor((obj.adc_data_peak_accum_avg_int + obj.adc_data_peak_accum_avg_ff1) / 2);

            if obj.peak_detect_en && stats_sample_on_cycle  % %----delete d1
                if obj.adc_data_peak_cnt_ff1 == (32 - 1)
                    obj.adc_data_peak_cnt_ff1 = 0;
                    obj.adc_data_peak_accum_avg_ff1 = obj.adc_data_peak_accum_avg_nxt;
                else
                    obj.adc_data_peak_cnt_ff1 = obj.adc_data_peak_cnt_ff1 + 1;
                end
                obj.adc_data_peak_accum_r = obj.adc_data_peak_accum_nxt;
            end

            if obj.adc_data_peak_accum_avg_ff1 > obj.vga_target
                obj.acc_update_nxt = 1 * 2^(0 - obj.vga_code_chg_reverse);
            else
                obj.acc_update_nxt = -1 * 2^(0 - obj.vga_code_chg_reverse);
            end

            acc_nxt = obj.acc_ff1 - obj.acc_update_nxt * 2^vga_adapt_gain;

            if acc_nxt > 0 && ((acc_nxt > obj.vga_code_max) || (acc_nxt < obj.vga_code_min))
                obj.acc_ff1_ovf_uovf = 1;
            else
                obj.acc_ff1_ovf_uovf = 0;
            end

            if obj.att_lvl_ff1 ~= obj.att_lvl_int
                obj.acc_ff1 = obj.vga_init_code_for_att_chg * 2^6;
            elseif ~obj.vga_en
                obj.acc_ff1 = obj.vga_init_code * 2^6;
            elseif obj.vga_adapt_en && stats_sample_valid_d1
                obj.acc_ff1 = min(obj.vga_code_max, max(obj.vga_code_min, acc_nxt));
            end

            if obj.att_lvl_ff1 ~= obj.att_lvl_ff2
                vga_code_int = obj.vga_init_code_for_att_chg;
            else
                vga_code_int = floor(obj.acc_ff1 / 2^6);
            end

            obj.overflow_unflow_flag = 0;
            if acc_nxt > 2047 || acc_nxt < 0  % 1024
                obj.overflow_unflow_flag = 1;
            end

            if stats_sample_valid_d1 && obj.vga_adapt_en
                if (obj.overflow_unflow_flag || obj.acc_ff1_ovf_uovf) && obj.vga_sat_cnt < 63
                    if obj.att_adapt_en
                        if obj.vga_sat_cnt + 1 >= obj.vga2att_cnt_max
                            obj.vga_sat_cnt = 0;
                        else
                            obj.vga_sat_cnt = obj.vga_sat_cnt + 1;
                        end
                    end
                end
            end

            obj.att_acc_nxt = obj.att_acc_ff1 + obj.acc_update_nxt * 2^obj.att_adapt_gain;

            if obj.att_en == 0
                obj.att_acc_ff1 = obj.att_init_gain * 2^6;
            elseif stats_sample_valid_d1 && obj.att_adapt_en
                if (obj.overflow_unflow_flag || obj.acc_ff1_ovf_uovf) && obj.vga_sat_cnt < 63
                    if obj.vga_sat_cnt + 1 >= obj.vga2att_cnt_max || obj.att_acc_nxt >=64 || obj.att_acc_nxt > obj.att_code_max
                        obj.att_acc_ff1 = obj.att_code_max;
                    elseif obj.att_acc_nxt < 0 || obj.att_acc_nxt < obj.att_code_min
                        obj.att_acc_ff1 = obj.att_code_min;
                    else
                        obj.att_acc_ff1 = obj.att_acc_nxt;
                    end
                end
            end
            att_lvl_ff1_pre = obj.att_lvl_int;
            att_lvl_ff2_pre = obj.att_lvl_ff1;
            obj.att_lvl_int = floor(obj.att_acc_ff1 / 2^6);
            obj.att_lvl_ff1 = att_lvl_ff1_pre;
            obj.att_lvl_ff2 = att_lvl_ff2_pre;
            if obj.att_lvl_int > 0
                obj.att_lvl_code = obj.att_code1;
            else
                obj.att_lvl_code = obj.att_code0;
            end

            obj.code_vga = vga_code_int;
            code_vga = obj.code_vga;
            att_lvl_code = obj.att_lvl_code;
        end

        % function slv_print(obj)
        %     fid = fopen('\data\in\%slv_name.txt','a');
        %     format = 'vga_target: %d\n';
        %     fprintf(fid,format,obj.vga_target);
        %     format = 'vga_target: %d\n';
        %     fprintf(fid,format,obj.vga_target);
        %     % fprintf(fid,'%d\n', obj.vga_target);
        %     fclose(fid);
        % end

        function set.Mode(obj,val)
            validateattributes(val,...
                {'numeric'},...
                {'scalar'},...
                '',...
                'Mode');
            mustBeMember(val, [0,1])
            obj.Mode = double(val);
        end
        function set.Gain(obj,val)
            validateattributes(val,...
                {'numeric'},...
                {'scalar','finite','<=',10,'>=',-10},...
                '',...
                'Gain');
            obj.Gain = double(val);
        end
    end
    methods (Hidden)
        % The below methods, getAMIParameters, getAMIInputNames and
        % getAMIOutputNames are for use only within the serdesDesigner App
        % and will not influence the AMI parameters in Simulink whatsoever.
        function amiParams = getAMIParameters(obj)
            GainAMI = serdes.internal.libisami.ami.parameter.SerDesModelSpecificParameter(...
                'Name', 'Gain', ...
                'Description', 'VGA Gain', ...
                'Usage', 'In', ...
                'Type', 'Float', ...
                'Format', sprintf('Range %i %i %i', obj.Gain, -10, 10), ...
                'CurrentValue', obj.Gain);
            ModeAMI = serdes.internal.libisami.ami.parameter.SerDesModelSpecificParameter(...
                'Name', 'Mode', ...
                'Description', 'VGA Mode 0=off, 1=on', ...
                'Usage', 'In', ...
                'Type', 'Integer', ...
                'Format', 'List 1 0', ...
                'CurrentValue', obj.Mode);
            ModeAMI.Format.ListTips = {'on','off'};
            ModeAMI.Format.Default = 1;

            amiParams = {GainAMI, ModeAMI};
        end
        function names = getAMIInputNames(~)
            names = {'Mode','Gain'};
        end
        function names = getAMIOutputNames(~)
            names = {};
        end
    end

    methods (Access = protected, Hidden)
        function val = modelsOn(obj)
            val = obj.Mode == double(1);
        end
    end
    methods(Access = protected)

        function validateInputsImpl(~,waveIn)
            validateattributes(waveIn,{'numeric'},{'finite'},'', 'waveIn');
        end

        function waveOut = stepImpl(obj,waveIn)
            t = 1:length(waveIn);

            %t=(1:10000)/10^4;
            if modelsOn(obj)
                waveOut = waveIn*10^(obj.Gain/20);
                % vga_tf = tf(obj.Num, obj.Den);
                % waveOut = lsim(vga_tf, waveOut, t);
            else
                waveOut = waveIn;
            end
        end

        %% Simulink functions
        function icon = getIconImpl(~)
            % Define icon for System block
            icon = 'VGA';
        end
        function name = getInputNamesImpl(~)
            name = 'In';
        end
        function name = getOutputNamesImpl(~)
            name = 'Out';
        end

    end

    methods(Static, Access = protected)
        function group = getPropertyGroupsImpl(~)
            % Define property section(s) for System block dialog
            mainGroup = matlab.system.display.SectionGroup(...
                'TitleSource','Auto',...
                'PropertyList',{'ModePort','Mode','GainPort','Gain'});
            group = mainGroup;
        end
    end

end