clear;
clc;

% test_cdr_pi_plot  扫描 cdr_pi 的 code / phase / index 行为并保存结果图。
%
% 测试目的：
%   1. 例化 8-bit PI，使用 cdr_pi 默认的 a+b=constant 非理想相位表。
%   2. 连续输入 deltaCode = 1，观察 PI code 在两个完整 UI 周期内的 wrap 行为。
%   3. 同时记录 wrapped / accumulated 两类状态，确认 CodeWrapped、UiSlip、Phase、Index
%      之间的关系是否符合预期。
%   4. 生成可视化图片，便于后续修改 PI 模型后进行直观回归对比。
%
% 说明：
%   - wrapped 量表示当前 UI 内的本地状态，例如 CodeWrapped、PhaseWrappedUI、IndexWrappedFloat。
%   - accumulated 量叠加了 UiSlip，用于观察跨 UI 后的长期累计状态。
%   - 本脚本主要用于调试和可视化，因此使用 update + getState，而不是 BER 热路径的 updateFast。

% 获取脚本所在目录，并将该目录加入 MATLAB path，确保能找到同目录下的 cdr_pi.m。
scriptDir = fileparts(mfilename('fullpath'));
addpath(scriptDir);

% 创建结果输出目录。若 result 文件夹不存在，则自动创建。
resultDir = fullfile(scriptDir, 'result');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

% 使用 8-bit PI：NumCode = 2^8 = 256。
% SamplesPerSymbol 表示 1 UI 对应的 waveform sample 数，用于把 phase(UI) 换算成 sample index。
NumBit = 8;
SamplesPerSymbol = 128;
piObj = cdr_pi(NumBit, SamplesPerSymbol);

% 扫描两个完整 PI code 周期，并额外多取一个点，便于观察第二次回到 code 0 后的状态。
% stepIndex 从 0 开始，和“已经执行了多少次 update”保持一致。
NumCode = piObj.NumCode;
numStep = NumCode * 2 + 1;
stepIndex = 0:numStep - 1;

% 预分配 trace 数组，避免循环中动态扩展数组影响脚本运行效率。
% codeWrapped：当前 UI 内 wrapped code，范围 [0, NumCode - 1]。
% codeAccum：包含 UiSlip 的累计 code，可用于观察跨 UI 后的长期推进。
% uiSlip：累计跨越完整 UI 的次数。
codeWrapped = zeros(1, numStep);
codeAccum = zeros(1, numStep);
uiSlip = zeros(1, numStep);

% phaseWrappedUI：当前 UI 内相位，单位 UI，范围通常 wrap 到 [0, 1)。
% phaseAccumUI：包含 UiSlip 的累计相位，单位 UI。
phaseWrappedUI = zeros(1, numStep);
phaseAccumUI = zeros(1, numStep);

% indexWrappedFloat：当前 UI 内 sample index 偏移，可为小数。
% indexAccumFloat：包含 UiSlip 的累计 sample index 偏移。
indexWrappedFloat = zeros(1, numStep);
indexAccumFloat = zeros(1, numStep);

for k = 1:numStep
    % 第一个点记录构造后的初始状态；从第二个点开始每步输入 deltaCode = 1。
    % 这样 stepIndex = 0 对应 code 0 初始状态，后续点对应逐步推进后的状态。
    if k > 1
        piObj.update(1);
    end

    % getState 返回完整调试快照。本脚本需要同时画 wrapped 和 accumulated 量，
    % 因此直接从 state 中取数，而不是只调用 getLocalIndex。
    state = piObj.getState();
    codeWrapped(k) = state.CodeWrapped;
    codeAccum(k) = state.CodeAccum;
    uiSlip(k) = state.UiSlip;
    phaseWrappedUI(k) = state.PhaseWrappedUI;
    phaseAccumUI(k) = state.PhaseAccumUI;
    indexWrappedFloat(k) = state.IndexWrappedFloat;
    indexAccumFloat(k) = state.IndexAccumFloat;
end

% 创建可见 figure。Visible = 'on' 用于运行脚本时实时显示图像。
fig = figure('Name', 'cdr_pi code phase index sweep', 'Color', 'w', 'Visible', 'on');

% 使用 3 行 1 列 tiledlayout，分别展示 code、phase 和 index。
% compact 设置减少子图之间的空白，便于保存为单张 PNG 观察。
t = tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
title(t, 'cdr\_pi 8-bit default nonideal sweep: code, phase, and index');

% 第一张图：观察硬件 wrapped code 和长期累计 code。
% CodeWrapped 每 256 个 code 回绕一次；CodeAccum 则持续单调递增。
nexttile;
yyaxis left;
plot(stepIndex, codeWrapped, 'LineWidth', 1.2);
ylabel('CodeWrapped');
yyaxis right;
plot(stepIndex, codeAccum, '--', 'LineWidth', 1.2);
ylabel('CodeAccum');
grid on;
xlabel('Update step');
title('PI code wrap and accumulated code');
legend('CodeWrapped', 'CodeAccum', 'Location', 'best');

% 第二张图：观察 PI 输出相位。
% PhaseWrappedUI 是当前 UI 内的相位；PhaseAccumUI 叠加 UiSlip 后可显示跨 UI 的累计相位。
nexttile;
yyaxis left;
plot(stepIndex, phaseWrappedUI, 'LineWidth', 1.2);
ylabel('PhaseWrappedUI');
yyaxis right;
plot(stepIndex, phaseAccumUI, '--', 'LineWidth', 1.2);
ylabel('PhaseAccumUI');
grid on;
xlabel('Update step');
title('PI phase in UI');
legend('PhaseWrappedUI', 'PhaseAccumUI', 'Location', 'best');

% 第三张图：观察相位换算到 waveform sample index 后的结果。
% IndexWrappedFloat 是给 ADC / sampler 使用的当前 UI 内本地偏移；
% IndexAccumFloat 用于观察长期累计采样点偏移。
nexttile;
yyaxis left;
plot(stepIndex, indexWrappedFloat, 'LineWidth', 1.2);
ylabel('IndexWrappedFloat');
yyaxis right;
plot(stepIndex, indexAccumFloat, '--', 'LineWidth', 1.2);
ylabel('IndexAccumFloat');
grid on;
xlabel('Update step');
title('PI sampling index');
legend('IndexWrappedFloat', 'IndexAccumFloat', 'Location', 'best');

% 强制刷新图像窗口，确保脚本运行时能看到实时绘图结果。
drawnow;

% 保存 PNG 图片，便于快速查看、插入文档或作为后续回归对比结果。
pngPath = fullfile(resultDir, 'cdr_pi_code_phase_index.png');
exportgraphics(fig, pngPath, 'Resolution', 200);

% 打印输出路径，方便用户在命令行中直接定位结果文件。
disp(['Saved PNG: ', pngPath]);
