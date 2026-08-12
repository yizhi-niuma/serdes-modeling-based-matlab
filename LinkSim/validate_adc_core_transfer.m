close all
clear
clc

rng(1);

script_dir = fileparts(mfilename('fullpath'));
adc_path = 'C:\Work\MatLab_Lib\ADC\TI_ADC';
addpath(script_dir);
addpath(adc_path);

result_dir = fullfile(script_dir, 'result', 'adc_core_validation');
if ~exist(result_dir, 'dir')
    mkdir(result_dir);
end

num_adcs = 64; vol_low = -0.5; adc_nbits = 7; adc_fullscale = 1;
VL = vol_low;
VH = vol_low + adc_fullscale;
fullscale = VH - VL;
lsb = fullscale / 2^adc_nbits;

ramp_num = 2^adc_nbits * 256;
random_num = 100000;

adc_qjh = ti_adc_core(num_adcs, VL, VH, adc_nbits);
adc_nb = sys.sar_adc_nb(VL, VH, adc_nbits, num_adcs);
adc_nb_ideal = sys.sar_adc_nb(VL, VH, adc_nbits, num_adcs);
adc_nb_ideal.Comp_noise = 0;
adc_nb_ideal.C_act_p = [2.^((adc_nbits-2):-1:0), 1] .* adc_nb_ideal.Cu;
adc_nb_ideal.C_tot_p = sum(adc_nb_ideal.C_act_p) + adc_nb_ideal.Cp_p;
adc_nb_no_delta = sys.sar_adc_nb(VL, VH, adc_nbits, num_adcs);
adc_nb_no_delta.Comp_noise = 0;
adc_nb_no_delta.C_act_p = [2.^((adc_nbits-2):-1:0), 1] .* adc_nb_no_delta.Cu;
adc_nb_no_delta.C_tot_p = sum(adc_nb_no_delta.C_act_p) + adc_nb_no_delta.Cp_p;
adc_nb_no_delta.delta1 = 0;
adc_nb_no_delta.delta2 = 0;

vin_ramp = linspace(VL, VH - fullscale/ramp_num, ramp_num);
[qjh_ramp, nb_ramp, nb_ideal_ramp, nb_no_delta_ramp] = convert_adc_vectors(vin_ramp, adc_qjh, adc_nb, adc_nb_ideal, adc_nb_no_delta, num_adcs);

diff_ramp = double(nb_ramp) - double(qjh_ramp);
diff_ideal_ramp = double(nb_ideal_ramp) - double(qjh_ramp);
diff_no_delta_ramp = double(nb_no_delta_ramp) - double(qjh_ramp);
ramp_table = table((1:ramp_num).', vin_ramp.', qjh_ramp.', nb_ramp.', diff_ramp.', nb_ideal_ramp.', diff_ideal_ramp.', nb_no_delta_ramp.', diff_no_delta_ramp.', ...
    qjh_ramp.' - 64, nb_ramp.' - 64, nb_ideal_ramp.' - 64, nb_no_delta_ramp.' - 64, ...
    'VariableNames', {'idx','Vin','qjh_code','sar_nb_code','diff_nb_minus_qjh','sar_nb_ideal_code','diff_ideal_minus_qjh','sar_nb_no_delta_code','diff_no_delta_minus_qjh','qjh_signed','sar_nb_signed','sar_nb_ideal_signed','sar_nb_no_delta_signed'});
writetable(ramp_table, fullfile(result_dir, 'ramp_transfer_compare.csv'));

vin_random = VL + fullscale * rand(1, random_num);
[qjh_random, nb_random, nb_ideal_random, nb_no_delta_random] = convert_adc_vectors(vin_random, adc_qjh, adc_nb, adc_nb_ideal, adc_nb_no_delta, num_adcs);

diff_random = double(nb_random) - double(qjh_random);
diff_ideal_random = double(nb_ideal_random) - double(qjh_random);
diff_no_delta_random = double(nb_no_delta_random) - double(qjh_random);
random_table = table((1:random_num).', vin_random.', qjh_random.', nb_random.', diff_random.', nb_ideal_random.', diff_ideal_random.', nb_no_delta_random.', diff_no_delta_random.', ...
    qjh_random.' - 64, nb_random.' - 64, nb_ideal_random.' - 64, nb_no_delta_random.' - 64, ...
    'VariableNames', {'idx','Vin','qjh_code','sar_nb_code','diff_nb_minus_qjh','sar_nb_ideal_code','diff_ideal_minus_qjh','sar_nb_no_delta_code','diff_no_delta_minus_qjh','qjh_signed','sar_nb_signed','sar_nb_ideal_signed','sar_nb_no_delta_signed'});
writetable(random_table, fullfile(result_dir, 'random_vin_compare.csv'));

ramp_stats = calc_stats(diff_ramp);
ramp_ideal_stats = calc_stats(diff_ideal_ramp);
random_stats = calc_stats(diff_random);
random_ideal_stats = calc_stats(diff_ideal_random);
ramp_no_delta_stats = calc_stats(diff_no_delta_ramp);
random_no_delta_stats = calc_stats(diff_no_delta_random);

summary_file = fullfile(result_dir, 'summary.txt');
fid = fopen(summary_file, 'w');
fprintf(fid, 'ADC core 直接验证问题总结\n');
fprintf(fid, '生成脚本: validate_adc_core_transfer.m\n\n');
fprintf(fid, '一、验证目的\n');
fprintf(fid, '本脚本用于直接比较用户新建模 ADC ti_adc_core 与原链路使用的 sys.sar_adc_nb 的静态量化行为。\n');
fprintf(fid, '验证包含静态 ramp transfer 和随机 Vin 大样本两类输入，用于判断两者基础量化功能是否一致，以及剩余差异是否主要来自 sar_adc_nb 内部 delta1/delta2 补偿逻辑。\n\n');
fprintf(fid, '二、验证范围\n');
fprintf(fid, '本脚本不调用 ADCFrontend，也不使用 ADC AFE 封装，只直接调用 ti_adc_core 和 sys.sar_adc_nb。\n');
fprintf(fid, 'qjh_adc: ti_adc_core, path = %s\n', adc_path);
fprintf(fid, 'reference_adc: sys.sar_adc_nb, direct class call\n\n');
fprintf(fid, '三、公共配置\n');
fprintf(fid, 'num_adcs = %d\n', num_adcs);
fprintf(fid, 'adc_nbits = %d\n', adc_nbits);
fprintf(fid, 'VL = %.12g\n', VL);
fprintf(fid, 'VH = %.12g\n', VH);
fprintf(fid, 'lsb = %.12g\n\n', lsb);
fprintf(fid, '四、三组 sar_adc_nb 对比定义\n');
fprintf(fid, '1. default: sar_adc_nb 默认模型，保留比较器噪声、电容 mismatch、delta1/delta2。\n');
fprintf(fid, '2. idealized: 关闭 sar_adc_nb 的 Comp_noise，并设置理想 C_act_p/C_tot_p，但仍保留 delta1/delta2。\n');
fprintf(fid, '3. no_delta: 在 idealized 基础上进一步设置 delta1 = 0、delta2 = 0，用于隔离 delta1/delta2 对剩余 1 LSB 差异的影响。\n\n');
fprintf(fid, '五、统计项说明\n');
fprintf(fid, 'diff = sar_adc_nb_code - ti_adc_core_code，单位为 ADC code/LSB。\n');
fprintf(fid, 'mismatch_count 表示 diff 不为 0 的样本数；max_abs_diff 表示最大绝对码差；unique_diff 表示出现过的所有码差。\n');
fprintf(fid, 'within_1lsb_ratio/within_2lsb_ratio 分别表示差异不超过 1/2 LSB 的样本比例。\n\n');
fprintf(fid, '六、统计结果\n');
write_stats(fid, 'Ramp transfer: sar_adc_nb default - ti_adc_core', ramp_stats);
write_stats(fid, 'Ramp transfer: sar_adc_nb idealized - ti_adc_core', ramp_ideal_stats);
write_stats(fid, 'Ramp transfer: sar_adc_nb no_noise no_capmismatch no_delta - ti_adc_core', ramp_no_delta_stats);
write_stats(fid, 'Random Vin: sar_adc_nb default - ti_adc_core', random_stats);
write_stats(fid, 'Random Vin: sar_adc_nb idealized - ti_adc_core', random_ideal_stats);
write_stats(fid, 'Random Vin: sar_adc_nb no_noise no_capmismatch no_delta - ti_adc_core', random_no_delta_stats);
fprintf(fid, '七、问题判断\n');
fprintf(fid, '如果 idealized 组关闭噪声和电容 mismatch 后仍存在 +/-1 LSB 差异，而 no_delta 组差异明显下降或完全消失，则可以说明 delta1/delta2 是关闭非理想后剩余差异的主要来源。\n');
fprintf(fid, '如果 no_delta 组仍存在差异，则剩余差异还可能来自两套 SAR 判决流程本身的边界比较方式、量化阈值定义或端点处理差别。\n');
fprintf(fid, '具体结论以本文件上方 no_delta 统计结果和 CSV 中 diff_no_delta_minus_qjh 列为准。\n');
fclose(fid);

save(fullfile(result_dir, 'adc_core_validation.mat'), ...
    'num_adcs', 'adc_nbits', 'VL', 'VH', 'lsb', 'ramp_num', 'random_num', ...
    'vin_ramp', 'qjh_ramp', 'nb_ramp', 'nb_ideal_ramp', 'nb_no_delta_ramp', 'diff_ramp', 'diff_ideal_ramp', 'diff_no_delta_ramp', ...
    'vin_random', 'qjh_random', 'nb_random', 'nb_ideal_random', 'nb_no_delta_random', 'diff_random', 'diff_ideal_random', 'diff_no_delta_random', ...
    'ramp_stats', 'ramp_ideal_stats', 'ramp_no_delta_stats', 'random_stats', 'random_ideal_stats', 'random_no_delta_stats');

fprintf('ADC core validation finished. Result dir: %s\n', result_dir);
fprintf('Ramp default mismatch: %d / %d, max abs diff: %g\n', ramp_stats.mismatch_count, ramp_stats.count, ramp_stats.max_abs_diff);
fprintf('Ramp ideal mismatch: %d / %d, max abs diff: %g\n', ramp_ideal_stats.mismatch_count, ramp_ideal_stats.count, ramp_ideal_stats.max_abs_diff);
fprintf('Ramp no-delta mismatch: %d / %d, max abs diff: %g\n', ramp_no_delta_stats.mismatch_count, ramp_no_delta_stats.count, ramp_no_delta_stats.max_abs_diff);
fprintf('Random default mismatch: %d / %d, max abs diff: %g\n', random_stats.mismatch_count, random_stats.count, random_stats.max_abs_diff);
fprintf('Random ideal mismatch: %d / %d, max abs diff: %g\n', random_ideal_stats.mismatch_count, random_ideal_stats.count, random_ideal_stats.max_abs_diff);
fprintf('Random no-delta mismatch: %d / %d, max abs diff: %g\n', random_no_delta_stats.mismatch_count, random_no_delta_stats.count, random_no_delta_stats.max_abs_diff);

function [qjh_code, nb_code, nb_ideal_code, nb_no_delta_code] = convert_adc_vectors(vin, adc_qjh, adc_nb, adc_nb_ideal, adc_nb_no_delta, num_adcs)
    sample_num = numel(vin);
    qjh_code = zeros(1, sample_num);
    nb_code = zeros(1, sample_num);
    nb_ideal_code = zeros(1, sample_num);
    nb_no_delta_code = zeros(1, sample_num);

    block_num = ceil(sample_num / num_adcs);
    for iblk = 1:block_num
        idx_start = (iblk - 1) * num_adcs + 1;
        idx_end = min(iblk * num_adcs, sample_num);
        idx = idx_start:idx_end;

        vin_block = vin(idx);
        if numel(vin_block) < num_adcs
            vin_block_pad = [vin_block, repmat(vin_block(end), 1, num_adcs - numel(vin_block))];
        else
            vin_block_pad = vin_block;
        end
        qjh_block = adc_qjh.convertOneBlockFast(vin_block_pad);
        qjh_code(idx) = qjh_block(1:numel(idx));

        for ii = 1:numel(idx)
            nb_code(idx(ii)) = adc_nb.dout(vin_block(ii), false);
            nb_ideal_code(idx(ii)) = adc_nb_ideal.dout(vin_block(ii), false);
            nb_no_delta_code(idx(ii)) = adc_nb_no_delta.dout(vin_block(ii), false);
        end
    end
end

function stats = calc_stats(diff_code)
    stats.count = numel(diff_code);
    stats.mismatch_count = nnz(diff_code ~= 0);
    stats.mismatch_ratio = stats.mismatch_count / stats.count;
    stats.max_abs_diff = max(abs(diff_code));
    stats.mean_diff = mean(diff_code);
    stats.mean_abs_diff = mean(abs(diff_code));
    stats.rms_diff = sqrt(mean(diff_code.^2));
    stats.unique_diff = unique(diff_code);
    stats.within_1lsb_count = nnz(abs(diff_code) <= 1);
    stats.within_1lsb_ratio = stats.within_1lsb_count / stats.count;
    stats.within_2lsb_count = nnz(abs(diff_code) <= 2);
    stats.within_2lsb_ratio = stats.within_2lsb_count / stats.count;
end

function write_stats(fid, title_str, stats)
    fprintf(fid, '%s\n', title_str);
    fprintf(fid, '  count = %d\n', stats.count);
    fprintf(fid, '  mismatch_count = %d\n', stats.mismatch_count);
    fprintf(fid, '  mismatch_ratio = %.12g\n', stats.mismatch_ratio);
    fprintf(fid, '  max_abs_diff = %.12g LSB\n', stats.max_abs_diff);
    fprintf(fid, '  mean_diff = %.12g LSB\n', stats.mean_diff);
    fprintf(fid, '  mean_abs_diff = %.12g LSB\n', stats.mean_abs_diff);
    fprintf(fid, '  rms_diff = %.12g LSB\n', stats.rms_diff);
    fprintf(fid, '  within_1lsb_count = %d\n', stats.within_1lsb_count);
    fprintf(fid, '  within_1lsb_ratio = %.12g\n', stats.within_1lsb_ratio);
    fprintf(fid, '  within_2lsb_count = %d\n', stats.within_2lsb_count);
    fprintf(fid, '  within_2lsb_ratio = %.12g\n', stats.within_2lsb_ratio);
    fprintf(fid, '  unique_diff =');
    fprintf(fid, ' %.12g', stats.unique_diff);
    fprintf(fid, '\n\n');
end
