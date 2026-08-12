classdef (StrictDefaults) TxDAC < matlab.System
    properties
        Skew1 = 0; % unit of skew is UI
        Skew2 = 0;
        Skew3 = 0;
        Skew4 = 0;
        ClockF = 14e9; % single DAC frequency
        lsb;
        Symbolrate = 56e9;
        tcoil;
        Symbolnum = 640;
        Sample_per_symbol = 128; % 1 symbol samples
        jitter_variance = 1e-26;
        dt;
        settling_time = 1e-12;
        gain_error = [0 0 0 0]; % gain error can be either a vector of size 4 or a single value
        offset_error = [0 0 0 0]; % offset error can be either a vector of size 4 or a single value
        Amp_DJ = [0 0 0 0];
        Fre_DJ = [0 0 0 0];
        DJ4_Enable = 1; % DJ4_Enable=1 means 4DJ in clock, DJ4_Enable=0 means 1DJ in clock
        Vswing = 1;
        nbits = 7;
        tcoil_en = 0;
        % ==property related to DAC INL/DNL
        Rout_vec = [35263 35263 35263 35263]; % Zeff=1/(1/Zon-1/Zoff)        Zon=86.97, Zoff=87.185
        Rout = 35263;
        RL = 45;              % Load R
        Vcode; % Correponding to INL transfer curve
        inl_table;
        dnl_table;
        SFDR;
        ssc_freq = 33e3;
        ssc_depth = 0;  %SSC OFF%3000;
        ssc_start_phase = 0.5;
        fixed_f = 0;%200;
        ssc_f;
        f_modulated;
        diff_mod;
        rising_edge;


        Cesd1=150e-15;   % ESD1 cap
        Cesd2=1e-15;     % ESD2 cap, no ESD2 in lr112g
        K12=0.4;         % Coupling factor of T-coil L1 and L2
        L1=150e-12;      % T-coil L1
        L2=120e-12;      % T-coil L2

        Cbump=75e-15;    % TX output Bump cap
        Cint=180e-15;    % DAC core loading cap.
        Rint=45;         % Internal Load Res.
        random_seed = 5;

    end
    properties(Access=public)
        time;
        clock;
        clock_xtalk;
    end

    methods

        %constructor function
        function obj=TxDAC()
            %obj = property_init(obj); %here to Init
            obj = inl_dnl_cal(obj);
            obj=create_tcoil(obj);
        end
        function obj = property_init(obj)
            obj.lsb=(1+obj.gain_error)*obj.Vswing*1/2^(obj.nbits);
            obj.time=0:1/(obj.Symbolrate*obj.Sample_per_symbol):(obj.Symbolnum + 8)/obj.Symbolrate;
            % clock_loc=struct();%local var clock
            % clock_loc.clock_DAC1=clockgen(obj);
            % % clock.clock_DAC2=[zeros(1,floor(0.25*obj.Sample_per_symbol)),clock.clock_DAC1(1:end-floor(0.25*obj.Sample_per_symbol))];
            % % clock.clock_DAC3=[zeros(1,floor(0.25*obj.Sample_per_symbol)),clock.clock_DAC2(1:end-floor(0.25*obj.Sample_per_symbol))];
            % % clock.clock_DAC4=[zeros(1,floor(0.25*obj.Sample_per_symbol)),clock.clock_DAC3(1:end-floor(0.25*obj.Sample_per_symbol))];
            % clock_loc.clock_DAC2=[zeros(1,floor(obj.Sample_per_symbol)),clock_loc.clock_DAC1(1:end-floor(obj.Sample_per_symbol))];
            % clock_loc.clock_DAC3=[zeros(1,floor(obj.Sample_per_symbol)),clock_loc.clock_DAC2(1:end-floor(obj.Sample_per_symbol))];
            % clock_loc.clock_DAC4=[zeros(1,floor(obj.Sample_per_symbol)),clock_loc.clock_DAC3(1:end-floor(obj.Sample_per_symbol))];
            % clock_loc.clock_4skew_4jitter=clockgen(obj, 1);

            obj.clock=clockgen(obj,2);
            rng(obj.random_seed - 1)
            obj.clock_xtalk = obj.clock + randi([-obj.Sample_per_symbol, obj.Sample_per_symbol], length(obj.clock),1);
            %xt_jitter=5;
            %obj.clock_xtalk = obj.clock + randi([-obj.Sample_per_symbol*xt_jitter, obj.Sample_per_symbol*xt_jitter], length(obj.clock),1);
            % clock_max=max(obj.clock);
            % clock_min=min(obj.clock);
            % obj.clock_xtalk=max(min(obj.clock_xtalk,clock_max),clock_min);
        end

        function obj = inl_dnl_cal(obj) % provided by mitch
            for idx_dac =1:4
                gl=1/obj.RL;
                N=2^obj.nbits;
                Itotal=obj.Vswing/obj.RL;
                ILSB=Itotal/N;
                go=1/obj.Rout_vec(idx_dac);

                Vout_k=zeros(N,1);
                Vout_k_1=zeros(N,1);
                DAC_therm_on=zeros(N,1);

                Voutp_k=zeros(N,1);
                Voutn_k=zeros(N,1);
                Voutp_k_1=zeros(N,1);
                Voutn_k_1=zeros(N,1);
                Voutdiff_k=zeros(N,1);
                Voutdiff_k_1=zeros(N,1);

                DNL_diff=zeros(N,1);
                Videal=zeros(N,1);

                INL_diff=zeros(N,1);


                for k=1:N
                    DAC_therm_on(k)=k;
                    Vout_k(k)=k*ILSB/(gl+go*k);
                    Vout_k_1(k)=(k-1)*ILSB/(gl+go*(k-1));
                    Voutp_k(k)=k*ILSB/(gl+go*k);
                    Voutn_k(k)=(N-k)*ILSB/(gl+go*(N-k));
                    Voutp_k_1(k)=(k-1)*ILSB/(gl+go*(k-1));
                    Voutn_k_1(k)=(N-k+1)*ILSB/(gl+go*(N-k+1));
                    Voutdiff_k(k)=Voutp_k(k)-Voutn_k(k);
                    Voutdiff_k_1(k)=Voutp_k_1(k)-Voutn_k_1(k);
                end

                Vstart=Voutdiff_k(1);
                Vend=Voutdiff_k(N);
                LSB=(Vend-Vstart)/(N-1);

                for i=1:1:N
                    DAC_therm_on(i)=i;
                    Videal(i)=(Vend-Vstart)*i/(N-1)+(Vstart*N-Vend)/(N-1);
                    DNL_diff(i)=(Voutdiff_k(i)-Voutdiff_k_1(i))/LSB-1;
                    INL_diff(i)=(Voutdiff_k(i)-Videal(i))/LSB;
                end
                INL_pp= max(INL_diff)-min(INL_diff);
                obj.SFDR(idx_dac)=20*log10(2^obj.nbits/INL_pp);
                obj.inl_table(idx_dac,:) = INL_diff;
                obj.dnl_table(idx_dac,:) = DNL_diff;
            end
        end

        function clock=clockgen(obj,mode)
            if mode==1
                sine=sin(2*pi*obj.ClockF*obj.time);
                clock=zeros(1,length(sine));
                for i=1:length(sine)
                    if sine(i)<0
                        clock(i)=1;
                    end
                end
            end
            obj.dt=1/(obj.Symbolrate*obj.Sample_per_symbol);
            if mode==2   %duty mode 4 clock sum
                % period=obj.Sample_per_symbol*4;
                % seq_length = length(obj.time);
                delta_f = obj.ssc_depth/2 * 1e-6;
                t = 0: obj.Symbolnum + 3;
                obj.ssc_f = delta_f * sawtooth(2 * pi * (obj.ssc_freq/obj.Symbolrate * t + obj.ssc_start_phase), 0.5) - delta_f;
                obj.f_modulated = 1 + obj.fixed_f * 1e-6 + obj.ssc_f;
                period_modulated = obj.Sample_per_symbol./obj.f_modulated;
                idx_start = obj.Sample_per_symbol/2;
                obj.rising_edge = idx_start + round(cumsum(period_modulated));
                rising_edge_ideal = idx_start + obj.Sample_per_symbol * (t + 1);
                obj.diff_mod = obj.rising_edge(1:obj.Symbolnum) - rising_edge_ideal(1:obj.Symbolnum);

                %rising_edge = obj.Sample_per_symbol/2:obj.Sample_per_symbol:obj.Sample_per_symbol/2 + obj.Sample_per_symbol * (obj.Symbolnum + 3);
                %+3 is extra for considering skew and jitter
                obj.rising_edge = reshape(obj.rising_edge,4,length(obj.rising_edge)/4);
                time_skew =round([obj.Skew1,obj.Skew2,obj.Skew3,obj.Skew4] * obj.Sample_per_symbol);
                obj.rising_edge = obj.rising_edge + time_skew';
                rng(obj.random_seed - 2)
                random_jitter=sqrt(obj.jitter_variance)*randn(size(obj.rising_edge));
                DJ_wave(1,:)=obj.Amp_DJ(1)*sin(2*pi*obj.Fre_DJ(1)*obj.rising_edge(1,:)*obj.dt);
                DJ_wave(2,:)=obj.Amp_DJ(2)*sin(2*pi*obj.Fre_DJ(2)*obj.rising_edge(2,:)*obj.dt);
                DJ_wave(3,:)=obj.Amp_DJ(3)*sin(2*pi*obj.Fre_DJ(3)*obj.rising_edge(3,:)*obj.dt);
                DJ_wave(4,:)=obj.Amp_DJ(4)*sin(2*pi*obj.Fre_DJ(4)*obj.rising_edge(4,:)*obj.dt);
                total_jitter = round((DJ_wave+random_jitter)/obj.dt);
                obj.rising_edge = max(obj.rising_edge + total_jitter, 1);
                % posedge(1)=obj.Sample_per_symbol;
                % posedge(2)=obj.Sample_per_symbol/2+obj.Sample_per_symbol+obj.Skew1*obj.Sample_per_symbol;
                % posedge(3)=obj.Sample_per_symbol/2+2*obj.Sample_per_symbol+obj.Skew2*obj.Sample_per_symbol;
                % posedge(4)=obj.Sample_per_symbol/2+3*obj.Sample_per_symbol+obj.Skew3*obj.Sample_per_symbol;
                % negedge=posedge+0.5*obj.Sample_per_symbol;
                % clock1=zeros(1,length(obj.time));
                % clock2=zeros(1,length(obj.time));
                % clock3=zeros(1,length(obj.time));
                % clock4=zeros(1,length(obj.time));
                % random_jitter=sqrt(obj.jitter_variance)*randn(1,length(obj.time),8);
                % random_jitter=random_jitter/(1/obj.Symbolrate/obj.Sample_per_symbol);
                % DJ_wave(1,:)=obj.Amp_DJ(1)*sin(2*pi*obj.Fre_DJ(1)*obj.time);
                % DJ_wave(2,:)=obj.Amp_DJ(2)*sin(2*pi*obj.Fre_DJ(2)*obj.time);
                % DJ_wave(3,:)=obj.Amp_DJ(3)*sin(2*pi*obj.Fre_DJ(3)*obj.time);
                % DJ_wave(4,:)=obj.Amp_DJ(4)*sin(2*pi*obj.Fre_DJ(4)*obj.time);
                % DJ_val=zeros(4,floor(length(obj.time)/periodn)+1);
                % switch obj.DJ4_Enable
                %     case 1%enable 4 DJ
                %         for i=1:floor(length(obj.time)/periodn)
                %             DJ_val(1,i)=round(DJ_wave(1,i*periodn)/obj.dt);
                %             DJ_val(2,i)=round(DJ_wave(2,i*periodn)/obj.dt);
                %             DJ_val(3,i)=round(DJ_wave(3,i*periodn)/obj.dt);
                %             DJ_val(4,i)=round(DJ_wave(4,i*periodn)/obj.dt);
                %         end
                %     case 0
                %         for i=1:floor(length(obj.time)/periodn)
                %             bias=periodn-1;
                %             DJ_val(1,i)=round(DJ_wave(1,i*periodn-bias)/obj.dt);
                %             DJ_val(2,i)=round(DJ_wave(1,i*periodn+obj.Sample_per_symbol-bias)/obj.dt);
                %             DJ_val(3,i)=round(DJ_wave(1,i*periodn+2*obj.Sample_per_symbol-bias)/obj.dt);
                %             DJ_val(4,i)=round(DJ_wave(1,i*periodn+3*obj.Sample_per_symbol-bias)/obj.dt);
                %         end
                %     otherwise
                %         error('value of obj.DJ4_Enable is not valid')
                % end
                % for i=1:length(obj.time)
                %     ind=mod(i,periodn);
                %     ind_jitter=floor(i/periodn)+1;
                %     clock1(i)=obj.edge_compare(ind,posedge(1)+random_jitter(1,ind_jitter,1)+DJ_val(1,ind_jitter),negedge(1)+random_jitter(1,ind_jitter,2));
                %     clock2(i)=obj.edge_compare(ind,posedge(2)+random_jitter(1,ind_jitter,3)+DJ_val(2,ind_jitter),negedge(2)+random_jitter(1,ind_jitter,4));
                %     clock3(i)=obj.edge_compare(ind,posedge(3)+random_jitter(1,ind_jitter,5)+DJ_val(3,ind_jitter),negedge(3)+random_jitter(1,ind_jitter,6));
                %     clock4(i)=obj.edge_compare(ind,posedge(4)+random_jitter(1,ind_jitter,7)+DJ_val(4,ind_jitter),negedge(4)+random_jitter(1,ind_jitter,8));
                % end
                clock=obj.rising_edge(:);
            end
        end

        function plot_clock(obj)
            figure()
            plot(obj.time,obj.clock.clock_DAC1,'LineWidth',3);
            figure()
            plot(obj.time,obj.clock.clock_DAC2,'LineWidth',3);
            figure()
            plot(obj.time,obj.clock.clock_DAC3,'LineWidth',3);
            figure()
            plot(obj.time,obj.clock.clock_DAC4,'LineWidth',3);

            figure()
            plot(obj.time,obj.clock.clock_DAC1,'LineWidth',3);
            hold on
            plot(obj.time,obj.clock.clock_DAC2,'LineWidth',3);
            hold on
            plot(obj.time,obj.clock.clock_DAC3,'LineWidth',3);
            hold on
            plot(obj.time,obj.clock.clock_DAC4,'LineWidth',3);
            hold on
            legend('DAC1','DAC2','DAC3','DAC4')
            figure()
            plot(obj.time,obj.clock.clock_4skew_4jitter,'LineWidth',3);
            title('clock_4skew_4jitter')
            xlim([0 10*1/obj.Symbolrate])
        end

        function [out,out_analog,t_analog]=DAC_cal(obj,t,digital_in,clock_in)   % replaced by DAC_cal4
            if nargin==3
                mode=1;%interal clcok
            end
            if nargin==4
                mode=2;%external clock
            end
            %sartuation=2^(obj.nbits-1);
            digital=digital_in;
            total_gain=(1+obj.gain_error(1)/2^(obj.nbits-1))*obj.lsb;
            total_bias=obj.lsb*obj.offset_error(1);
            digital=floor(digital);
            if mode==1%%interal clcok
                digital = interp1(t,digital,obj.time,'linear');
                out=zeros(1,length(obj.time));
                for i=1:length(obj.clock.clock_DAC1)
                    if obj.istriggers(obj.clock.clock_DAC1,i)==true
                        out(i)=digital(i)*total_gain(1)+total_bias(1);
                    else
                        if(i>1)
                            out(i)=out(i-1);
                        else
                            out(i)=0;
                        end
                    end
                end
            else

                if mode==2%external clock
                    out=zeros(1,length(t));
                    for i=1:length(t)
                        if obj.istriggers(clock_in,i)==true
                            out(i)=digital(i)*total_gain+total_bias;
                        else
                            if(i>1)
                                out(i)=out(i-1);%hold
                            else
                                out(i)=0;%initial output
                            end
                        end
                    end
                end
            end
            wn=4/obj.settling_time;
            num=wn*wn;
            DEN=[1 2*0.85*wn wn*wn];
            sys_DAC=tf(num,DEN);
            [out_analog,t_analog]=lsim(sys_DAC,out,t);
        end

        function [out,t,out_analog,t_analog]=DAC_cal4(obj,ffe_out,str)%4 ti dac or one dac model,controled by str
            obj.Symbolnum=length(ffe_out);
            v_inl = nan(4,length(ffe_out)/4);
            % obj.clock=clockgen(obj,2);
            obj.property_init;    %--------better to move to constructor-----------------
            digital = reshape(ffe_out,[4,obj.Symbolnum/4]);
            total_gain=zeros(1,4);
            total_bias=zeros(1,4);
            for i=1:4
                total_gain(i)=(1+obj.gain_error(i)/2^obj.nbits)*obj.lsb(i);
                total_bias(i)=obj.lsb(i)*obj.offset_error(i);
            end
            for i_dac=1:4
                for i_sym = 1:length(ffe_out)/4
                    v_inl(i_dac,i_sym) =obj.inl_table(digital(i_dac, i_sym) + 2^(obj.nbits-1)+1) * obj.lsb(i_dac);
                end
            end
            analog = digital.*total_gain' + total_bias' + v_inl;
            analog = analog(:);
            % cnt = 1;
            switch str
                case '4TIDAC'
                    out=zeros(1,length(obj.time));
                    for i = 1:obj.Symbolnum
                        out(obj.clock(i):obj.clock(i + 1)) = analog(i);
                        out_xtalk(obj.clock_xtalk(i):obj.clock_xtalk(i + 1)) = analog(i);
                    end

                case '1DAC'
                    out=zeros(1,length(obj.time));
                    for i = 1:obj.Symbolnum
                        out(obj.clock(i):obj.clock(i + 1)) = analog(i);
                        out_xtalk(obj.clock_xtalk(i):obj.clock_xtalk(i + 1)) = analog(i);
                    end
                    % out=zeros(1,length(obj.time));
                    % for i=1:length(obj.time)
                    %  if obj.istriggers(obj.clock.clock_4skew_4jitter,i)==true
                    %      out(i)=digital(i)*total_gain(1)+total_bias(1);
                    %  else
                    %      if(i>1)
                    %          out(i)=out(i-1);%hold
                    %       else
                    %           out(i)=0;%initial output
                    %       end
                    %   end
                    % end
                otherwise
                    error('Input string error, string should be 4TIDAC or 1DAC')
            end
            t=obj.time(1:obj.Symbolnum * obj.Sample_per_symbol);
            out = out(1:obj.Symbolnum * obj.Sample_per_symbol);
%            out_xtalk = out_xtalk(1:obj.Symbolnum * obj.Sample_per_symbol);
            %===================== settling time feature=====================
            % wn=4/obj.settling_time;
            % num=wn*wn;
            % den=[1 2*0.85*wn wn*wn];
            % sys_DAC=tf(num,den);
            % [out_analog,t_analog]=lsim(sys_DAC,out,t);
            % [out_analog,t_analog]=lsim(obj.tcoil,out_analog,t_analog);
            %===============================================================
            if obj.tcoil_en
                [out_analog,t_analog]=lsim(obj.tcoil,out,t);
%                [out_analog_xtalk,~]=lsim(obj.tcoil,out_xtalk,t);
                % revise
                % Ts = t(2)-t(1);
                % sys_ss = ss(obj.tcoil);
                % sys_d = c2d(sys_ss,Ts,'zoh');
                % Ad = sys_d.A;

                % Bd = sys_d.B;
                % Cd = sys_d.C;
                % Dd = sys_d.D;
                % t_analog = t';
                % out_analog = (simulate_lsim_mex(Ad,Bd,Cd,Dd,out));
                % out_analog_xtalk = (simulate_lsim_mex(Ad,Bd,Cd,Dd,out_xtalk));
                %codegen simulate_lsim.m -args {coder.typeof(0,[16,16]),coder.typeof(0,[16,1]),coder.typeof(0,[1,16]),coder.typeof(0,[0,1]),coder.typeof(0,[1,Inf])}
            else
                out_analog = out;
                t_analog = t;
              
            end
        end
        function plot_tcoil(obj)
            figure()
            bode(obj.tcoil);
        end
    end

    methods(Access=private)
        function out=edge_compare(ind, posedge, negedge)
            if (ind <= posedge)
                out = 0;
            else
                if (ind > posedge && ind <= negedge)
                    out = 1;
                else
                    out = 0;
                end
            end
        end

        function out=istriggers(obj, wave, ind, diff_val, diff_time)
            if nargin == 3
                diff_val = 1;
                diff_samp = 1;
            else
                diff_samp = floor(diff_time / obj.dt);
                if diff_samp < 1
                    diff_samp = 1;
                end
            end

            if ind + diff_samp > length(wave)
                out = false;
                return;
            end
            if (wave(ind + diff_samp) - wave(ind)) >= diff_val
                out = true;
            else
                out = false;
            end
        end

        function obj=create_tcoil(obj)
            % obj.tcoil=tf([0 0 0 0 -8.8265e+49 -7.2130e+64 -1.4832e+79 -3.9111e+91 -4.3387e+103 -3.2548e+115 ...
            % -1.8202e+127 -4.8621e+138 6.8805e+149 1.5738e+162 9.9698e+173 3.4179e+185 5.7486e+196], ...
            % [24.6025 3.0135e+16 1.2335e+31 1.7000e+45 5.2059e+57 7.9172e+69 8.8856e+81 7.7934e+93 ...
            % 5.4067e+105 3.1461e+117 1.4819e+129 5.7981e+140 1.8163e+152 4.4550e+163 7.9981e+174 9.8596e+185 5.7486e+196]);
            Cesd1 = obj.Cesd1;   % ESD1 cap
            Cesd2=obj.Cesd2;   % ESD2 cap, no ESD2 in lr112g
            K12=obj.K12;       % Coupling factor of T-coil L1 and L2
            K23=0.1; % Coupling factor of T-coil L2 and L3
            %K13=0.1;   % Coupling factor of T-coil L2 and L3
            L1=obj.L1;         % T-coil L1, near DAC
            L2=obj.L2;         % T-coil L2, center
            L3=0;              % T-coil L3, near bump, no L3 in lr112g
            M12=K12*sqrt(L1*L2); % Mutual inductor of L1 and L2

            M23=K23*sqrt(L2*L3); % Mutual inductor of L2 and L3
            %Coup_M13=K13*sqrt(L1*L3); % Mutual inductor of L2 and L3
            Cbump=obj.Cbump;   % TX output Bump cap
            RT=50;             % RX term
            Cb=5e-15;          % T-coil bridge cap.    Analog par

            Rint=obj.Rint;     % Internal Load Res.    Analog Par
            Cint=obj.Cint;     % DAC core loading cap.  Analog par
            Cr=20e-15;
            Cb_ls=15e-15;
            Lshunt=200e-12;    % Shunt inductance.
            w0=1/(Rint*Cint);

            m=Rint*Rint*Cint/Lshunt;

            R_Ls=5.7;  % EMX of Lshunt

            numShunt=[Lshunt R_Ls]; % Q of Lshunt =6
            denShunt=[1];
            TF_ShuntL=tf(numShunt,denShunt);

            numShuntC=[1];
            denShuntC=[Cb_ls 0];
            TF_ShuntC=tf(numShuntC,denShuntC);
            TF_Lshunt=TF_ShuntL*TF_ShuntC/(TF_ShuntL+TF_ShuntC);
            numR=[Rint];
            denR=[Rint*Cr 1];
            TF_R=tf(numR,denR); % Rint with C1.

            TF_Shunt=TF_Lshunt+TF_R;
            %
            numCint=[1];
            denCint=[Cint 0];
            TF_Cint=tf(numCint,denCint);
            TF_Zeq1=TF_Shunt*TF_Cint/(TF_Shunt+TF_Cint); %Z_shunt_peaking
            numZeq2 = [RT];
            denZeq2 = [RT*Cbump 1];
            TF_Zeq2 = minreal(tf(numZeq2, denZeq2)); % Output node_Z_eq2.

            R_L1 = 2.5; % EMX of Tcoil
            numZL1 = [L1+M12 R_L1];
            denZL1 = [1];
            TF_ZL1 = tf(numZL1, denZL1); % T-coil L1

            R_L2 = 2.5; % EMX of Tcoil
            numZL2 = [L2+M12+M23 R_L2];
            denZL2 = [1];
            TF_ZL2 = tf(numZL2, denZL2); % T-coil L2

            numZL3 = [L3+M23 0];
            denZL3 = [1];
            TF_ZL3 = tf(numZL3, denZL3); % T-coil L3 not used now

            numZM12 = [-M12 0];
            denZM12 = [1];
            TF_ZM12 = tf(numZM12, denZM12); % M12

            numZM23 = [-M23 0];
            denZM23 = [1];
            TF_ZM23 = tf(numZM23, denZM23); % M23

            numZesd1 = [1];
            denZesd1 = [Cesd1 0];
            TF_Zesd1 = tf(numZesd1, denZesd1);
            TF_Zeq3 = minreal(TF_ZM12 + TF_Zesd1); % ESD node Zeq3

            numZesd2 = [1];
            denZesd2 = [Cesd2 0];
            TF_Zesd2 = tf(numZesd2, denZesd2);
            TF_Zeq4 = minreal(TF_ZM23 + TF_Zesd2); % ESD node Zeq4

            Rint_total = Rint + R_Ls;
            Rout_total = RT + R_L1 + R_L2;
            DC_gain = Rint_total * Rout_total / (Rint_total + Rout_total) * RT / Rout_total;

            TF_Zeq5=minreal(TF_Zeq4*(TF_ZL3+TF_Zeq2)/(TF_Zeq2+TF_ZL3+TF_Zeq4)+TF_ZL2);
            TF_Zeq6=minreal(TF_Zeq3*TF_Zeq5/(TF_Zeq3+TF_Zeq5)+TF_ZL1);
            TF_lout=minreal(TF_Zeq1/(TF_Zeq1+TF_Zeq6)*TF_Zeq3/(TF_Zeq3+TF_Zeq5)*TF_Zeq4/(TF_Zeq4+TF_ZL3+TF_Zeq2));

            options = bodeoptions;
            options.FreqUnits = 'Hz'; % or 'rad/second', 'rpm', etc.
            w = logspace(8,11,500)*2*pi;
            Req=Rint*RT/(Rint+RT);

            TF_noBWET=tf;
            BW_noBWET=1/(2*pi/Req/(Cint+Cbump+Cesd1+Cesd2));

            TF_total=minreal(TF_Zeq2*TF_lout);

            obj.tcoil=TF_total/DC_gain;
        end
    end
end