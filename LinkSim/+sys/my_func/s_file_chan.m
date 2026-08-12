function [wave_out, h_norm] = s_file_chan(file_path, wave_in, fb, sample_point, plt_en, TxR, TxC, RxR, RxC)
channel = SParameterChannel('FileName', file_path);
channel.StopTime = 1000 * (1/fb);
channel.SampleInterval = 1/(fb * sample_point);
if nargin < 6
    TxR = 50;
    TxC = 1e-13;
    RxR = 50;
    RxC = 2e-13;
end
channel.TxR = TxR;
channel.TxC = TxC;
channel.RxR = RxR;
channel.RxC = RxC;
h = channel.ImpulseResponse;
h_norm = h / max(abs(h));
id = find(flipud(h) > 1e-3, 1, 'first');
h_cut = h(1: end - id);
wave_out = conv(h * channel.SampleInterval, wave_in);
wave_out = wave_out(1: length(wave_in));

if plt_en
    plot_imp(h_norm, 3, 150, 1/fb, sample_point);
    title('IPR of S-channel')
    xlabel('Unit is UI')
    figure;
    channel.plotSparameter
    title('Frequency domain Feature of S-channel')
end