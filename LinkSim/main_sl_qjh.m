close all
clear
clc
nclk=1000;
Sample_per_symbol = 128;
data_rate = 112e9;
mod_order = 4;
sym_rate = data_rate /log2(mod_order);
TargetFrequency = sym_rate/2;
SymbolTime = 1/sym_rate;
dt = SymbolTime/Sample_per_symbol;
%=================================Tx init==================================
tx_dsp=sys.TxDSP;
tx_dac= sys.TxDAC;
tx_dsp.tx_ffe_coef =[-2     6   -18    46     5     3     4  0];
%tx_dsp.tx_ffe_coef = [ 0  0  0 84 0  0  0  0 ];
tx_dac.Sample_per_symbol = Sample_per_symbol;
tx_dac.tcoil_en = 1;
tx_dsp_out = tx_dsp.ffe(nclk);
[~,~,wave_tx_raw,~]=tx_dac.DAC_cal4(tx_dsp_out,'4TIDAC');
wave_tx = wave_tx_raw(128*2+1:end);
%---------------------------Tx waveform------------------------------------
figure()
eye_plot_len = min(3000, floor(numel(wave_tx)/(Sample_per_symbol*2)));
plot(reshape(wave_tx(1:Sample_per_symbol*2*eye_plot_len),Sample_per_symbol*2,[]));
grid on
title('Eyedigram of TX output')
% %================================User's Defined Channel====================
% Xtalk_en = 0;
% Chan=sys.Channel('Loss',12,'dt', dt, 'TargetFrequency',TargetFrequency,'FEXTICN',0.8e-3,...
%     'NEXTICN',1.2e-3,'EnableCrosstalk',Xtalk_en);
% if Xtalk_en
%   [wave_main,fext,next] = Chan(wave_tx,wave_tx,wave_tx);
%    wave_chan = wave_main+ fext + next;
% else
%    wave_chan = Chan(wave_tx);
% end
%plot(Chan.privImpulse)
%max(Chan.privImpulse)
% figure()
% plot(reshape(wave_chan(1:Sample_per_symbol*2*10000),Sample_per_symbol*2,[]));
% grid on
% title('Eyedigram of Channel output')
%===========================IEEE 802.3 Channel=============================
Chan2 = sys.Chan_SnP('dt', dt, 'snp_file_name', 'DPO_4in_Meg7_THRU.s4p');
%max(Chan2.privImpulse)
% plot(Chan2.privImpulse)
% freqz(Chan2.privImpulse)
% wave_chan2 = Chan2(wave_tx);
wave_chan2 = Chan2.chan_conv(wave_tx);
figure()
eye_plot_len = min(3000, floor(numel(wave_chan2)/(Sample_per_symbol*2)));
plot(reshape(wave_chan2(1:Sample_per_symbol*2*eye_plot_len),Sample_per_symbol*2,[]));
grid on
title('Eyedigram of Channel output')
%===============================RX begin===================================
%-------Pass-----CTLE---------------------------------------------------
ctle= sys.CTLE('SymbolTime',SymbolTime,'SampleInterval',dt,...
    'Mode',1,'WaveType','Sample',...
    'DCGain',0,'PeakingGain',12,...
    'PeakingFrequency',TargetFrequency*1.07);
wave_ctle=ctle(wave_chan2);
figure()
eye_plot_len = min(3000, floor(numel(wave_ctle)/(Sample_per_symbol*2)));
wave_ctle_eye = reshape(wave_ctle(1:Sample_per_symbol*2*eye_plot_len),Sample_per_symbol*2,[]);
ctle_eye_zero_threshold = 5e-3;
ctle_eye_valid = max(abs(wave_ctle_eye), [], 1) >= ctle_eye_zero_threshold;
plot(wave_ctle_eye(:, ctle_eye_valid));
grid on
title('Eyedigram of CTLE output')
num_adcs = 64; num_tnh = 8; vol_low =-0.5 ; adc_nbits = 7; adc_fullscale =1;
adc_path = 'C:\Work\MatLab_Lib\ADC\TI_ADC';
addpath(adc_path);
adc_top = ti_adc_core(num_adcs, vol_low, vol_low + adc_fullscale, adc_nbits);
rxclocking = sys.RxClocking;
%clk8_gen = rxclocking.clk8_gen;
%clk_gen = sys.ClockGen(sym_rate);
index_init = 83;
index_init_base = index_init;
export_iclk_num = 30;
%---------------RX FFEDFE init---------------------------------------------
modulation=mod_order; heh_init=[-45 -15 15 45 ]; heh_lms_en = 1; heh_lms_num =1; ffe_coef_init =[0 0 0 0 64 0 0 0 0 0]; ...
    ffe_lmsen_vec=ones(1,length(ffe_coef_init)); ffe_npst_fx = 10; fffe_en = 0; dfe_coef_init =0 ; dfe_lmsen_vec = 1 ; num_dmx_rx = num_adcs;
%rx_ffe_dfe = sys.RxFFEDFE(modulation, heh_init, heh_lms_en, heh_lms_num, ffe_coef_init, ffe_lmsen_vec, ffe_npst_fx, fffe_en,...
%    dfe_coef_init, dfe_lmsen_vec, num_dmx_rx);
data2dsp = zeros(export_iclk_num, num_adcs);
for iclk=1:export_iclk_num
    % [clk_gen, rising_edge_array] = clk_gen.Clk8phaseGen(obj, pi_delta);
    % sample_index = rising_edge_array(:);
    sample_index = index_init_base + ((iclk-1)*num_adcs:1:iclk*num_adcs-1)*Sample_per_symbol;
  
    rising_edge_array = reshape(sample_index,num_adcs/num_tnh,num_tnh)';
    sample_index_adc = rising_edge_array(:)';
    data2dsp_temp = adc_top.convertOneBlockFast(wave_ctle(sample_index_adc)) - 64;
    data2dsp(iclk, :) = data2dsp_temp;
end
result_dir = fullfile(fileparts(mfilename('fullpath')), 'result');
if ~exist(result_dir, 'dir')
    mkdir(result_dir);
end
data2dsp_csv_data = reshape(data2dsp.', [], 1);
data2dsp_csv_data = data2dsp_csv_data(1:min(num_adcs*export_iclk_num, numel(data2dsp_csv_data)));
writematrix(data2dsp_csv_data, fullfile(result_dir, 'main_sl_qjh_data2dsp_first1920.csv'));
