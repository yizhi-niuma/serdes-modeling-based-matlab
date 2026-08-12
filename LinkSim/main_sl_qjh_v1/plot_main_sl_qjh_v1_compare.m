close all
clear
clc

script_dir = fileparts(mfilename('fullpath'));
parent_dir = fileparts(script_dir);
original_dir = pwd;
cleanup_obj = onCleanup(@() cd(original_dir));
addpath(parent_dir);
cd(parent_dir);
result_dir = fullfile(script_dir, 'result');
if ~exist(result_dir, 'dir')
    mkdir(result_dir);
end

run(fullfile(script_dir, 'main_sl_qjh_v1.m'));

script_dir = fileparts(mfilename('fullpath'));
parent_dir = fileparts(script_dir);
source_result_dir = fullfile(script_dir, 'result');
result_dir = fullfile(script_dir, 'result');
if ~exist(result_dir, 'dir')
    mkdir(result_dir);
end

num_adcs = 64;
hist_iclk_num = 20;
new_csv_source_file = fullfile(source_result_dir, 'main_sl_qjh_data2dsp_first1920.csv');
new_csv_file = fullfile(result_dir, 'main_sl_qjh_v1_data2dsp_first1920.csv');
new_png_file = fullfile(result_dir, 'main_sl_qjh_v1_data2dsp_first1280_histogram.png');
compare_txt_file = fullfile(result_dir, 'main_sl_qjh_v1_data2dsp_compare_diff.txt');
reference_csv_file = fullfile(parent_dir, 'result', 'main_sl_qjh_data2dsp_first1920.csv');

new_data2dsp_data = readmatrix(new_csv_source_file);
new_data2dsp_data = new_data2dsp_data(:);
writematrix(new_data2dsp_data, new_csv_file);

hist_data2dsp_data = new_data2dsp_data(1:min(num_adcs*hist_iclk_num, numel(new_data2dsp_data)));

figure()
histogram(hist_data2dsp_data, 'BinMethod', 'integers', 'Normalization', 'probability', 'FaceColor', [0.20 0.45 1.00], 'FaceAlpha', 0.70, 'EdgeColor', [0.20 0.45 1.00]);
hold on
grid on
box on
set(gca, 'FontSize', 12, 'LineWidth', 1);
xlabel('ADC Output Code (Signed Decimal)')
ylabel('Normalized probability')
title('64-lane TI ADC Signed Code Distribution')
xlim([-60 60])
ylim([0 0.065])

[~, pdf_edges] = histcounts(hist_data2dsp_data, 'BinMethod', 'integers', 'Normalization', 'probability');
bin_width = median(diff(pdf_edges));

hist_cluster_num = 4;
hist_sorted_data = sort(hist_data2dsp_data(:));
hist_cluster_edges = round(linspace(1, numel(hist_sorted_data) + 1, hist_cluster_num + 1));
code_centers = zeros(1, hist_cluster_num);
code_sigmas = zeros(1, hist_cluster_num);
cluster_weights = zeros(1, hist_cluster_num);
for code_idx = 1:hist_cluster_num
    cluster_data = hist_sorted_data(hist_cluster_edges(code_idx):hist_cluster_edges(code_idx + 1) - 1);
    code_centers(code_idx) = mean(cluster_data);
    code_sigmas(code_idx) = std(double(cluster_data), 1);
    cluster_weights(code_idx) = numel(cluster_data) / numel(hist_data2dsp_data);
end
[code_centers, center_order] = sort(code_centers);
code_sigmas = code_sigmas(center_order);
cluster_weights = cluster_weights(center_order);

for code_idx = 1:hist_cluster_num
    if code_sigmas(code_idx) > 0
        fit_x = linspace(code_centers(code_idx) - 4*code_sigmas(code_idx), code_centers(code_idx) + 4*code_sigmas(code_idx), 200);
        fit_y = cluster_weights(code_idx) * bin_width ./ (code_sigmas(code_idx) * sqrt(2*pi)) .* exp(-0.5*((fit_x - code_centers(code_idx))./code_sigmas(code_idx)).^2);
        plot(fit_x, fit_y, 'Color', [0.00 0.20 0.70], 'LineWidth', 1.8);
    end
end

for code_idx = 1:hist_cluster_num
    peak_code = round(code_centers(code_idx));
    peak_y = cluster_weights(code_idx) * bin_width ./ max(code_sigmas(code_idx), eps) ./ sqrt(2*pi);
    xline(peak_code, '--r', sprintf('Code=%d', peak_code), 'LabelOrientation', 'horizontal', 'LabelVerticalAlignment', 'top', 'LineWidth', 1.2);
    plot(peak_code, min(peak_y, 0.064), 'rv', 'MarkerFaceColor', 'r', 'MarkerSize', 6);
end
hold off
print(gcf, new_png_file, '-dpng', '-r300');

reference_data2dsp_data = readmatrix(reference_csv_file);
reference_data2dsp_data = reference_data2dsp_data(:);
compare_len = max(numel(reference_data2dsp_data), numel(new_data2dsp_data));
reference_compare_data = nan(compare_len, 1);
new_compare_data = nan(compare_len, 1);
reference_compare_data(1:numel(reference_data2dsp_data)) = reference_data2dsp_data;
new_compare_data(1:numel(new_data2dsp_data)) = new_data2dsp_data;
diff_data = new_compare_data - reference_compare_data;

fid = fopen(compare_txt_file, 'w');
fprintf(fid, '%18s    %18s    %18s\n', 'reference_csv', 'new_csv', 'diff');
for data_idx = 1:compare_len
    fprintf(fid, '%18.15g    %18.15g    %18.15g\n', reference_compare_data(data_idx), new_compare_data(data_idx), diff_data(data_idx));
end

valid_diff_data = diff_data(~isnan(diff_data));
nonzero_diff_data = valid_diff_data(valid_diff_data ~= 0);
fprintf(fid, '\nDiff Summary Report\n');
fprintf(fid, 'reference_csv_file: %s\n', reference_csv_file);
fprintf(fid, 'new_csv_file: %s\n', new_csv_file);
fprintf(fid, 'reference_count: %d\n', numel(reference_data2dsp_data));
fprintf(fid, 'new_count: %d\n', numel(new_data2dsp_data));
fprintf(fid, 'compared_count: %d\n', compare_len);
fprintf(fid, 'valid_diff_count: %d\n', numel(valid_diff_data));
fprintf(fid, 'nonzero_diff_count: %d\n', numel(nonzero_diff_data));
if isempty(valid_diff_data)
    fprintf(fid, 'max_abs_diff: NaN\n');
    fprintf(fid, 'mean_abs_diff: NaN\n');
    fprintf(fid, 'sum_abs_diff: NaN\n');
else
    fprintf(fid, 'max_abs_diff: %.15g\n', max(abs(valid_diff_data)));
    fprintf(fid, 'mean_abs_diff: %.15g\n', mean(abs(valid_diff_data)));
    fprintf(fid, 'sum_abs_diff: %.15g\n', sum(abs(valid_diff_data)));
end
fclose(fid);

disp(['Generated CSV: ', new_csv_file]);
disp(['Generated PNG: ', new_png_file]);
disp(['Generated TXT: ', compare_txt_file]);

compare_hist_png_file = fullfile(result_dir, 'main_sl_qjh_histogram_compare.png');
reference_hist_png_file = fullfile(result_dir, 'main_sl_qjh_data2dsp_first1280_histogram.png');
v1_hist_png_file = fullfile(result_dir, 'main_sl_qjh_v1_data2dsp_first1280_histogram.png');

reference_hist_img = imread(reference_hist_png_file);
v1_hist_img = imread(v1_hist_png_file);

figure()
tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile
image(reference_hist_img)
axis image off
title('main\_sl\_qjh Histogram')

nexttile
image(v1_hist_img)
axis image off
title('main\_sl\_qjh\_v1 Histogram')

print(gcf, compare_hist_png_file, '-dpng', '-r300');

disp(['Generated histogram compare PNG: ', compare_hist_png_file]);
