classdef sar_adc_nb

    properties
        %电容阵列
        Cu=1e-15; % ADC的单位电容(F)
        sigmaCu=0.005; % ADC的电容失配(%) THD影响较大
        Cp_p=1e-15; % 正极板寄生电容
        C_arr_p
        C_tot_p
        C_act_p

        %Vrefin

        %定义比较器参数
        Comp_offset=0.00; % 比较器失调电压(V) (定值)
        Comp_noise=0.0015; % 比较器等效输入噪声，均方根电压(V)

        VL
        VH
        delta1 %比较器建立误差
        delta2

        M % the numbers of compare
        N % resolution
        Vref_step % the step of reference voltage
        delta % lsb
        Voffset %

        Vref
        Vref_cdac
    end

    methods
        function obj = sar_adc_nb(VL, VH, N, M, Vref_step, Voffset_en)
            if nargin < 6
                Voffset_en = false;
            end
            if nargin < 5
                Vref_step = [64, 32, 15, 6, 4, 4, 2, 1];
            end
            if nargin < 4
                M = 8;
            end
            if nargin < 3
                N = 7;
            end
            if nargin < 2
                VH = 0.3;
            end
            if nargin < 1
                VL = -0.3;
            end
            obj.VL = VL;
            obj.VH = VH;
            obj.M = M;
            obj.N = N;
            obj.Vref_step = Vref_step;
            obj.delta = (VH - VL) / (2^N);
            obj.Voffset = zeros(1, M);
            if ~Voffset_en
                obj.Voffset = zeros(1, M);
                % obj.Voffset(1) = normrnd(0, 1 * obj.delta);
            else
                obj.Voffset = normrnd(0, 1 * obj.delta, 1, M);
            end
            %定义电容阵列
            obj.C_arr_p=[2.^[(obj.N-2):-1:0],1]; % 电容阵列正极板，CDAC_P
            obj.C_act_p=obj.C_arr_p.*obj.Cu+obj.sigmaCu.*obj.Cu.*sqrt(obj.C_arr_p).*randn(1,obj.N);
            obj.C_tot_p=sum(obj.C_act_p)+obj.Cp_p;

            obj.Vref=obj.VL+(obj.VH-obj.VL)/2;%采样信号对应的vref外面
            obj.Vref_cdac=(obj.VH-obj.VL)/2;
            obj.delta1=obj.delta;
            obj.delta2=0.5*obj.delta;

        end


        function [Dout, D, Vout] = dout(obj, Vin, gainerror_en, k, x)
            lsb = obj.delta; % (obj.VH - obj.VL)/2^obj.N; % 移到外面
            % obj.delta1 = lsb;
            % obj.delta2 = 0.5*lsb;
            if nargin < 4
                k = 1;
            end
            if nargin < 3
                gainerror_en = false;
            end
            if gainerror_en
                Vin = Vin * obj.gain_error(x);
            end
            Vip = Vin; % + abs(obj.VH - obj.VL)/2; % 采样信号
            % Vref = obj.VL + (obj.VH - obj.VL)/2; % 采样信号对应的vref外面
            % Vref_cdac = (obj.VH - obj.VL)/2;
            for i = 1:obj.N - 1
                if Vip < obj.Vref + obj.Comp_offset + obj.Comp_noise * randn(1, 1) % Cdac上的电压只需要变换N - 1次
                    B(i) = 0;
                    if i == 1
                        Vip = Vip + obj.Vref_cdac * obj.C_act_p(i)/obj.C_tot_p + obj.delta1;
                    elseif i == 2
                        Vip = Vip + obj.Vref_cdac * obj.C_act_p(i)/obj.C_tot_p + obj.delta2;
                    else
                        Vip = Vip + obj.Vref_cdac * obj.C_act_p(i)/obj.C_tot_p;
                    end
                else
                    B(i) = 1;
                    if i == 1
                        Vip = Vip - obj.Vref_cdac * obj.C_act_p(i)/obj.C_tot_p - obj.delta1;
                    elseif i == 2
                        Vip = Vip - obj.Vref_cdac * obj.C_act_p(i)/obj.C_tot_p - obj.delta2;
                    else
                        Vip = Vip - obj.Vref_cdac * obj.C_act_p(i)/obj.C_tot_p;
                    end
                end
            end
            if Vip <= obj.Vref + obj.Comp_offset + obj.Comp_noise * randn(1, 1)
                B(obj.N) = 0;
            else
                B(obj.N) = 1;
            end
            D(:) = B; % ADC的数字码输出
            Dout = D * 2.^((obj.N-1):-1:0)'; % 数字码经过理想DAC复原之后的输出
            % lsb = (obj.VH + obj.VL)/2^obj.N;
            Vout = Dout * lsb; % 归一化之后的输出
        end



        function [THD, SFDR, SNR, SNDR, ENOB] = Dynamic_test(obj, Dout, Fs, Nsample, plot_en)
            % Dout: 十进制输出码
            % Fs: ADC采样率
            % Nsample: ADC采样点数
            Dout = Dout - mean(Dout); % 滤掉直流分量
            Amp_spectrum = abs(fft(Dout', Nsample)); % 幅度谱
            Power_spectrum = Amp_spectrum.^2; % 功率谱
            dB_spectrum = 10*log10(Amp_spectrum.^2/(Nsample/2)); % dB谱(why除以采样点数的1/2)
            max_dBc = max(dB_spectrum); % 输入信号功率(dB)
            [~, bin] = max(dB_spectrum(1:floor(Nsample/2))); % 找到输入信号位置(幅度最大值处)
            signal_frequency = bin;
            signal_bin = 5; % 将信号附近的旁瓣视作信号功率
            harmonic_bin = 30; % 将谐波附近的旁瓣视作谐波功率
            start_power = 5; % 忽略DC直流
            signal_power = sum(Power_spectrum(bin-signal_bin:bin+signal_bin)); % 输入信号功率，包括旁瓣
            total_power = sum(Power_spectrum(start_power:floor(Nsample/2))); % 总功率
            Power_spectrum_half = Power_spectrum(start_power:floor(Nsample/2)); % 半边谱功率，奈奎斯特区间总功率
            harmonic_indices = signal_frequency * (2:10); % 考虑到20次谐波

            for i = 1:length(harmonic_indices)
                if harmonic_indices(i) > Nsample / 2
                    division_result = harmonic_indices(i) / (Nsample / 2);
                    remainder_fs_2 = mod(harmonic_indices(i), Nsample / 2);

                    if rem(division_result, 2) == 1 % 如果除以N/2是奇数，说明落在偶数区间
                        if remainder_fs_2 == 0
                            harmonic_indices(i) = Nsample / 2;
                        else
                            harmonic_indices(i) = Nsample / 2 - abs(remainder_fs_2 - Nsample / 2);
                        end
                    else % 如果除以N/2是偶数，说明落在奇数区间
                        harmonic_indices(i) = remainder_fs_2;
                    end
                end
                harmonic_indices(i) = harmonic_indices(i);
                harmonic_power_single(i) = sum(Power_spectrum_half(harmonic_indices(i)-harmonic_bin:harmonic_indices(i)+harmonic_bin));
            end
            harmonic_power = sum(harmonic_power_single); % 计算总的谐波功率

            % 计算各项指标
            THD = 10*log10(harmonic_power/signal_power);
            SNDR = 10*log10(signal_power/(total_power-signal_power));
            SNR = 10*log10(signal_power/(total_power-signal_power-harmonic_power));
            ENOB = (SNDR-1.76)/6.02;
            Dout_SFDR = abs(dB_spectrum-dB_spectrum(bin)); % 减去最大dB功率（全为负值）
            Dout_SFDR = Dout_SFDR(1:Nsample/2);
            Dout_SFDR_1 = min(Dout_SFDR(start_power:(bin-signal_bin-1))); % 直流到信号功率的最小值（与信号功率相差最小的值）
            Dout_SFDR_2 = min(Dout_SFDR((bin+signal_bin+1):Nsample/2)); % 信号功率到fs/2
            SFDR = min(Dout_SFDR_1,Dout_SFDR_2);

            % 绘制指标图形
            if plot_en
                fs = Fs; % 是否除Samplepersymbol
                fs = fs/1e9; % 将X轴设置为GHz单位
                fin = bin*fs/(1e6*Nsample); % 输入信号实际频率
                figure; % 定义图片
                plot((0:Nsample/2-1)*fs/Nsample, dB_spectrum(2:Nsample/2+1)-max_dBc, 'k');
                Figure = plot((0:Nsample/2-1)*fs/Nsample, dB_spectrum(2:Nsample/2+1)-max_dBc, 'k'); % 绘图
                mindB = min(dB_spectrum(2:Nsample/2+1)-max_dBc); % 标准化Y轴
                grid on;
                zoom;
                set(gca, 'linewidth', 3);
                set(gca, 'fontsize', 20, 'FontWeight', 'bold', 'fontname', 'Arial');
                set(Figure, 'linewidth', 2.5);
                title(sprintf('fin = %.2f MHz, fs = %d GHz', fin, fs), 'FontWeight', 'bold', 'fontsize', 20, 'fontname', 'Arial');
                xlabel('Frequency (GHz)', 'FontWeight', 'bold', 'fontsize', 20, 'fontname', 'Arial');
                ylabel('Amplitude (dB)', 'FontWeight', 'bold', 'fontsize', 20, 'fontname', 'Arial');
                xlim([0 fs/2]); ylim([-140 0]);
                % 添加动态参数文本显示
                text(fs/5, -30, sprintf('THD = %.2f dB\nSFDR = %.2f dB\nSNR = %.2f dB\nSNDR = %.2f dB\nENOB = %.2f bit', ...
                    THD, SFDR, SNR, SNDR, ENOB), ...
                    'LineWidth', 2, 'fontsize', 20, 'Margin', 5, 'FontWeight', 'bold', 'fontname', 'Arial');
                set(gcf, 'unit', 'centimeters', 'position', [10 5 18 14]);
                hold off;
            end
        end

        function [DNLmax, DNLmin, INLmax, INLmin] = ramp_INLDNL(obj, Dout, N, plot_en)
            % 计算ramp信号DNL/INL
            % Dout: ramp信号十进制输出码
            % N: ADC的位数
            min_bin = min(Dout);
            max_bin = max(Dout);
            h = hist(Dout, min_bin:max_bin);        % 直方图(1 2 .. 范围内的数)
            mean_l = length(Dout)/2^N;
            hdnl = h/mean_l - 1;
            point = 0;
            dnl = hdnl(1+point:end-point);          % 删除增益误差,中心处DNL为0
            inl = cumsum(dnl);                      % INL是DNL的积分（求和）
            DNLmax = max(dnl);
            DNLmin = min(dnl);
            INLmax = max(inl);
            INLmin = min(inl);

            % 绘制DNL/INL图
            if plot_en
                figure;
                subplot(2,1,1) % 绘制DNL
                Q_DNL = plot(linspace(min_bin+point, max_bin-point, length(dnl)), dnl, 'k'); hold on;
                set(gca, 'linewidth', 2);
                set(gca, 'FontWeight', 'bold', 'fontsize', 15, 'fontname', 'Arial');
                set(Q_DNL, 'linewidth', 2);
                title(sprintf('DNL'), 'FontWeight', 'bold', 'fontsize', 20, 'fontname', 'Arial');
                xlabel('Digital Code [LSB]');
                ylabel('DNL [LSB]');
                grid on;
                box on;
                xlim([0 2^N]);
                text(0.02, 0.5, sprintf('DNLmax = %.2f LSB\n\n\n\nDNLmin = %.2f LSB', DNLmax, DNLmin), ...
                    'sc', 'FontWeight', 'bold', 'fontsize', 15, 'fontname', 'Arial');
                subplot(2,1,2) % 绘制INL
                Q_INL = plot(linspace(min_bin+point, max_bin-point, length(dnl)), inl, 'k'); hold on;
                set(gca, 'linewidth', 2);
                set(gca, 'FontWeight', 'bold', 'fontsize', 15, 'fontname', 'Arial');
                set(Q_INL, 'linewidth', 2);
                title(sprintf('INL'), 'FontWeight', 'bold', 'fontsize', 20, 'fontname', 'Arial');
                xlabel('Digital Code [LSB]');
                ylabel('INL [LSB]');
                grid on;
                box on;
                xlim([0 2^N]);
                set(gca, 'xgrid', 'off');
                set(gcf, 'unit', 'centimeters', 'position', [10 5 18 14]);
                text(0.02, 0.5, sprintf('INLmax = %.2f LSB\n\n\n\nINLmin = %.2f LSB', INLmax, INLmin), ...
                    'sc', 'FontWeight', 'bold', 'fontsize', 15, 'fontname', 'Arial');
            end
        end
    end

end
