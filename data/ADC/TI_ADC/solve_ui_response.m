%% solve_ui_response.m
%% Load ctle_out.mat and solve the unit-UI (single-bit) response of the
%% CTLE + channel path directly from the CTLE output waveform.
%%
%% Method:
%%   1. Recover the TX symbol sequence from the (open) eye by slicing at the
%%      best sampling phase (NRZ, threshold = 0).
%%   2. For every sub-UI sample offset, least-squares solve
%%          y[k] = sum_n x[k-n] * h[n]
%%      to obtain the oversampled single-bit response (SBR).
%%   3. The cursor taps {h[-pre]..h[0]..h[+post]} at the optimal phase are the
%%      unit-UI response codes.
%%
%% Assumptions:
%%   baud_rate = 56e9 Baud (56 Gbaud), NRZ, decision threshold = 0.
%%   Change baud_rate / n_pre / n_post below if needed.

mat_path = fullfile(fileparts(mfilename('fullpath')), 'ctle_out.mat');

fprintf('Loading: %s\n', mat_path);
d = load(mat_path);
time = d.time;
amplitude = d.amplitude;

%% Parameters
baud_rate = 56e9;
ui_duration = 1 / baud_rate;
dt = mean(diff(time));
samples_per_ui = round(ui_duration / dt);
n_pre = 3;
n_post = 8;
threshold = 0;

fprintf('dt = %.4e s,  samples_per_ui = %d\n', dt, samples_per_ui);

%% Center the waveform about the decision threshold
y = amplitude(:) - threshold;
total_symbols = floor(length(y) / samples_per_ui);

%% Step 1: find the best sampling phase (maximum vertical eye opening)
phase_metric = zeros(samples_per_ui, 1);
for offset = 0 : samples_per_ui - 1
    idx = offset + samples_per_ui * (0 : total_symbols - 1)' + 1;
    idx = idx(idx <= length(y));
    phase_metric(offset + 1) = mean(abs(y(idx)));
end
[~, best_bin] = max(phase_metric);
best_offset = best_bin - 1;
fprintf('Best sampling phase: offset = %d / %d samples\n', best_offset, samples_per_ui);

%% Step 2: recover TX symbols at the best phase (NRZ +/-1)
sym_idx = best_offset + samples_per_ui * (0 : total_symbols - 1)' + 1;
sym_idx = sym_idx(sym_idx <= length(y));
symbols = sign(y(sym_idx));
symbols(symbols == 0) = 1;
n_sym = length(symbols);
fprintf('Recovered %d symbols (+1: %d, -1: %d)\n', ...
    n_sym, sum(symbols > 0), sum(symbols < 0));

%% Step 3: per-offset least-squares deconvolution -> oversampled SBR
tap_index = (-n_pre : n_post);
n_tap = length(tap_index);
sbr_matrix = zeros(samples_per_ui, n_tap);

k_range = (n_post + 1) : (n_sym - n_pre);
X = zeros(length(k_range), n_tap);
for col = 1 : n_tap
    n = tap_index(col);
    X(:, col) = symbols(k_range - n);
end

for offset = 0 : samples_per_ui - 1
    idx = offset + samples_per_ui * (k_range - 1)' + 1;
    valid = idx <= length(y);
    yv = y(idx(valid));
    sbr_matrix(offset + 1, :) = (X(valid, :) \ yv)';
end

%% Cursor taps at the optimal phase = unit-UI response codes
cursor_taps = sbr_matrix(best_offset + 1, :);
[~, main_rel] = max(abs(cursor_taps));
main_cursor = cursor_taps(main_rel);
norm_taps = cursor_taps / main_cursor;

fprintf('\n=== Unit-UI response (cursor taps) ===\n');
fprintf('%6s %14s %14s\n', 'tap', 'value', 'norm(/h0)');
for col = 1 : n_tap
    label = sprintf('%+d', tap_index(col));
    if tap_index(col) == tap_index(main_rel)
        label = [label ' *'];
    end
    fprintf('%6s %14.6f %14.6f\n', label, cursor_taps(col), norm_taps(col));
end
fprintf('Main cursor h0 = %.6f at tap %+d\n', main_cursor, tap_index(main_rel));

%% Save results
out_path = fullfile(fileparts(mfilename('fullpath')), 'ui_response_result.mat');
save(out_path, 'tap_index', 'cursor_taps', 'norm_taps', ...
    'sbr_matrix', 'samples_per_ui', 'best_offset', 'baud_rate');
fprintf('Saved: %s\n', out_path);

%% Plot: normalized oversampled SBR + UI-sampled cursor taps (main = 1)
sbr_wave = reshape(sbr_matrix, 1, []);
t_sbr = ((0 : numel(sbr_wave) - 1) - n_pre * samples_per_ui - best_offset) / samples_per_ui;

figure('Name', 'Unit-UI Response - CTLE Path', 'NumberTitle', 'off', ...
    'Position', [100, 100, 1100, 650]);
plot(t_sbr, sbr_wave / main_cursor, 'Color', [0, 0.45, 0.74], 'LineWidth', 1.4);
hold on;
stem(tap_index, norm_taps, 'filled', 'Color', [0.85, 0.33, 0.10], 'LineWidth', 1.2);

%% Annotate non-main cursor values in whitespace, connected by thin leaders
ylim([-0.25, 1.08]);
xlim([-n_pre - 0.6, n_post + 0.6]);

%   tap  text_x  text_y   (text positions chosen to sit in whitespace)
anno = [ -3, -3.0, 0.16;
         -2, -2.0, 0.26;
         -1, -1.7, 0.46;
          1,  1.6, 0.60;
          2,  2.6, 0.44;
          3,  3.0, 0.16;
          4,  4.0, 0.26;
          5,  5.0, 0.16;
          6,  6.0, 0.26;
          7,  7.0, 0.16;
          8,  8.0, 0.26 ];

for j = 1 : size(anno, 1)
    tapx = anno(j, 1);
    tx   = anno(j, 2);
    ty   = anno(j, 3);
    col  = find(tap_index == tapx);
    v    = norm_taps(col);
    plot([tapx, tx], [v, ty - 0.025], ':', 'Color', [0.5, 0.5, 0.5], ...
        'LineWidth', 0.7, 'HandleVisibility', 'off');
    text(tx, ty, sprintf('%+.3f', v), 'FontSize', 8.5, ...
        'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
        'Color', [0.15, 0.15, 0.15]);
end

hold off;
box on;
grid on;
xlabel('Time (UI)');
ylabel('Normalized response (main = 1)');
title('Single-Bit / Unit-UI Response (CTLE + Channel)');
legend('Oversampled SBR', 'Cursor taps', 'Location', 'northeast');
set(gca, 'FontSize', 11);

fprintf('Unit-UI response solved successfully.\n');

%% Export figure
fig_path = fullfile(fileparts(mfilename('fullpath')), 'ui_response_3p1m8p.png');
exportgraphics(gcf, fig_path, 'Resolution', 200);
fprintf('Figure saved: %s\n', fig_path);
