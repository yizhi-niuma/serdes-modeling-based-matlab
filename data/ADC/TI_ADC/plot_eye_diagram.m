%% plot_eye_diagram.m
%% Load ctle_out.mat and plot an eye diagram.
%%
%% Assumptions:
%%   baud_rate = 56e9 Baud (56 Gbaud)
%%   samples_per_ui derived from actual time step
%%   Change baud_rate below if needed.

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
fprintf('dt = %.4e s,  samples_per_ui = %d\n', dt, samples_per_ui);

ui_count = 2;
samples_per_window = samples_per_ui * ui_count;
total_samples = length(amplitude);
num_traces = floor(total_samples / samples_per_window);

if num_traces < 1
    error('Not enough samples for one eye window.');
end

fprintf('Plotting %d traces over %d UI windows...\n', num_traces, ui_count);

t_window = (0 : samples_per_window - 1)' * dt / ui_duration;

figure('Name', 'Eye Diagram - CTLE Output', 'NumberTitle', 'off');
hold on;

for k = 1 : num_traces
    idx_start = (k - 1) * samples_per_window + 1;
    idx_end   = idx_start + samples_per_window - 1;
    trace     = amplitude(idx_start : idx_end);
    plot(t_window, trace, 'Color', [0, 0.45, 0.74, 0.04], 'LineWidth', 0.3);
end

hold off;
box on;
grid on;
xlabel('Time (UI)');
ylabel('Amplitude');
title(sprintf('Eye Diagram CTLE Output  (56 Gbaud, %d traces)', num_traces));
xlim([0, ui_count]);
set(gca, 'FontSize', 11);

fprintf('Eye diagram plotted successfully.\n');
