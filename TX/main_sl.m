close all
clear 
clc
nclk=10000; % sim nclk data for the whole link
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
%tx_dsp.tx_ffe_coef =[-1  2 -6  60 -8  5 -2  0];
tx_dsp.tx_ffe_coef = [ 0  0  0 84 0  0  0  0 ];
tx_dac.Sample_per_symbol = Sample_per_symbol;
tx_dac.tcoil_en = 1;
tx_dsp_out = tx_dsp.ffe(nclk);
[~,~,wave_tx_raw,~]=tx_dac.DAC_cal4(tx_dsp_out,'4TIDAC');
wave_tx = wave_tx_raw(192:192+Sample_per_symbol*(nclk-2)-1);
%---------------------------Tx waveform------------------------------------
figure()
plot(reshape(wave_tx(1:Sample_per_symbol*2*3000),Sample_per_symbol*2,[]));
grid on
title('Eyedigram of TX output')
%================================Channel===================================
Xtalk_en = 0;
Chan=sys.Channel('Loss',16,'TargetFrequency',TargetFrequency,'FEXTICN',0.8e-3,'NEXTICN',1.2e-3,'EnableCrosstalk',Xtalk_en);
if Xtalk_en
  [wave_main,fext,next] = Chan(wave_tx,wave_tx,wave_tx);
   wave_chan = wave_main+ fext + next;
else
   wave_chan = Chan(wave_tx);
end
figure()
plot(reshape(wave_chan(1:Sample_per_symbol*2*3000),Sample_per_symbol*2,[]));
grid on
title('Eyedigram of Channel output')
%===============================RX begin===================================
   %-------Pass-----CTLE---------------------------------------------------
  ctle= sys.CTLE('SymbolTime',SymbolTime,'SampleInterval',dt,...
      'Mode',1,'WaveType','Sample',...
      'DCGain',-2,'PeakingGain',10,...
      'PeakingFrequency',TargetFrequency*0.95);
  wave_ctle=ctle(wave_chan);
figure()
plot(reshape(wave_ctle(1:Sample_per_symbol*2*3000),Sample_per_symbol*2,[]));
grid on
title('Eyedigram of CTLE output')

num_adcs = 56; num_tnh = 8; vol_low =0 ; adc_nbits = 7; adc_fullscale =1;
digin_mux_size = 56; Tstep=0; NB_ADC_en=0; Tlen =1;gain_error_std=0;offset_error_std=0; gain_cali_en=0; offset_cali_en=0;
adc_top = sys.ADCFrontend(num_adcs, num_tnh, vol_low, adc_nbits, adc_fullscale, digin_mux_size, Tstep, NB_ADC_en, Tlen, ...
                gain_error_std, offset_error_std, gain_cali_en, offset_cali_en);
rxclocking = sys.RxClocking;
for iclk=1:nclk-10

    clk8_gen = rxclocking.clk8_gen;
    wave2dac = wave_ctle(sample_index);
    data2dsp = adc_top.digitize_data(wave2adc);

end
