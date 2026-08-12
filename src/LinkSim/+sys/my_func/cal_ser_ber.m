function [ser, ber, sym_err_idx, bit_total, delay_nsym] = cal_ser_ber(modulation, sym_tx, sym_rx, start_isym, err_plt_en)

sym_tx = sym_tx(1:length(sym_rx));

sym_tx_dlv = 2*sym_tx-3;
sym_rx_dlv = 2*sym_rx-3;

[c, lags] = xcov(sym_rx_dlv, sym_tx_dlv);
[value, idx] = max(abs(c));
delay_nsym = lags(idx);
if delay_nsym < 0
    disp('rx signal should be delayed copy of tx signal !!!!')
end
sym_cut_rx = sym_rx(start_isym:end);
sym_cut_tx = sym_tx(start_isym-delay_nsym: end-delay_nsym);
sym_total = length(sym_cut_rx);
bit_total = log2(modulation)*sym_total;
err_dlv = sym_cut_rx-sym_cut_tx;
err_idx = find(err_dlv~=0);
bit_tx = sym2bit(modulation, sym_cut_tx(err_idx));
bit_rx = sym2bit(modulation, sym_cut_rx(err_idx));
sym_err_idx = start_isym + err_idx -1;
ser = nnz(sym_cut_rx-sym_cut_tx)/sym_total;
ber = sum(xor(bit_tx, bit_rx))/bit_total;

if err_plt_en
    figure
    stem(lags, c/value);
    title('X Covariance betwwen Tx Symbol and Rx Symbol')
    xlabel('Lags between Tx Symbols and Rx Symbols')
    figure
    stem(sym_err_idx, err_dlv(err_idx))
    xlim([start_isym,start_isym+sym_total])
    ylim([-3, 3 ])
    title('Error Distribution')
    xlabel('Symbol Index @ Rx side')
    ylabel('Error Amplitude')
end