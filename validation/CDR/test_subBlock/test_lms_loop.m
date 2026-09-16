clear;
clc;

% test_lms_loop  验证 dlev_loop 环路在 LMS 与 SS-LMS 两种模式下的收敛过程。
%
% 测试目的:
%   1. 生成理想 PAM4 符号序列 {-3,-1,+1,+3} 并叠加高斯噪声,作为接收样本。
%   2. 用一个刻意偏置的初始判决电平(内/外环标称值远离真值)构造 dlev_loop,
%      逐块喂入样本,观察内/外环幅度是否能收敛到真实幅度 1 与 3。
%   3. 分别跑全精度 LMS(dlevLms)与符号-符号 SS-LMS(dlevSsLms)两条环路,
%      各自绘制 DLevInner/DLevOuter 随块更新次数的收敛曲线,并叠加真值参考线,
%      直观确认 dLev 环路可正常工作。
%   4. 结果图运行后自动显示并保存为 PNG,便于回归对比。
%
% 说明:
%   - 两条环路使用完全相同的样本序列与偏置初值,唯一区别是更新项是否取符号,
%     便于对比两种模式的收敛速度与稳态抖动。
%   - 使用 dlevLms / dlevSsLms(而非 Fast 变体),因为需要记录轨迹用于绘图。

% 获取脚本所在目录,并把源码目录加入 MATLAB path,确保能找到 dlev_loop.m。
validationDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(fileparts(fileparts(validationDir)));
sourceDir = fullfile(repoRoot, 'src', 'CDR');
addpath(sourceDir);

% 创建结果输出目录 results/CDR/subBlock/test_lms_loop,不存在则逐级创建。
resultDir = fullfile(repoRoot, 'results', 'CDR', 'subBlock', 'test_lms_loop');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

% 固定随机种子,保证每次运行的样本序列与收敛曲线可复现。
rng(0);

% 理想 PAM4 电平与折叠后的真实幅度(内环对应 |±1|,外环对应 |±3|)。
pamLevels = [-3, -1, 1, 3];
innerTrue = 1;
outerTrue = 3;

% 环路参数:块长 64 UI,共 400 块;噪声标准差取 0.15。
blockSize = 64;
numBlock = 400;
noiseSigma = 0.15;

% 刻意偏置的初始标称幅度:内环偏低、外环偏高,用于演示环路从错误初值收敛到真值。
initInner = 0.5;
initOuter = 4.0;

% 步长:全精度 LMS 与符号-符号 SS-LMS 各取一个稳定收敛的值。
% SS-LMS 更新项已被归一化为 ±1 的符号,故步长略大以获得相近的收敛速度。
stepLms = 0.02;
stepSsLms = 0.05;

% 预生成所有块的接收样本:每块随机抽取 PAM4 符号并叠加高斯噪声。
% 两条环路复用同一份样本,保证对比公平。
totalSamples = blockSize * numBlock;
symIndex = randi(numel(pamLevels), 1, totalSamples);
cleanSamples = pamLevels(symIndex);
rxSamples = cleanSamples + noiseSigma * randn(1, totalSamples);

% 例化两条环路:构造函数末位参数保持默认极性 +1。
% LevelsInner/LevelsOuter 传入偏置初值,reset 后即以该偏置值作为起点。
lmsObj = dlev_loop(stepLms, blockSize, initInner, initOuter);
ssLmsObj = dlev_loop(stepSsLms, blockSize, initInner, initOuter);

% 逐块喂入样本:全精度 LMS 环路。
for k = 1:numBlock
    idx = (k - 1) * blockSize + (1:blockSize);
    lmsObj.dlevLms(rxSamples(idx));
end

% 逐块喂入样本:符号-符号 SS-LMS 环路(使用同一份样本序列)。
for k = 1:numBlock
    idx = (k - 1) * blockSize + (1:blockSize);
    ssLmsObj.dlevSsLms(rxSamples(idx));
end

% 取出两条环路的收敛轨迹。
lmsState = lmsObj.getState();
ssLmsState = ssLmsObj.getState();
blockAxis = 1:numBlock;

% ---- 图 1:全精度 LMS 收敛过程 ----
figLms = figure('Name', 'dlev_loop LMS convergence', 'Color', 'w', 'Visible', 'on');
plot(blockAxis, lmsState.DLevInnerTrace, 'LineWidth', 1.2);
hold on;
plot(blockAxis, lmsState.DLevOuterTrace, 'LineWidth', 1.2);
yline(innerTrue, '--', 'inner true = 1', 'Color', [0.3, 0.3, 0.3]);
yline(outerTrue, '--', 'outer true = 3', 'Color', [0.3, 0.3, 0.3]);
hold off;
grid on;
xlabel('Block update count');
ylabel('dLev amplitude');
title('dlev\_loop full-precision LMS convergence');
legend('DLevInner', 'DLevOuter', 'Location', 'best');

% ---- 图 2:符号-符号 SS-LMS 收敛过程 ----
figSs = figure('Name', 'dlev_loop SS-LMS convergence', 'Color', 'w', 'Visible', 'on');
plot(blockAxis, ssLmsState.DLevInnerTrace, 'LineWidth', 1.2);
hold on;
plot(blockAxis, ssLmsState.DLevOuterTrace, 'LineWidth', 1.2);
yline(innerTrue, '--', 'inner true = 1', 'Color', [0.3, 0.3, 0.3]);
yline(outerTrue, '--', 'outer true = 3', 'Color', [0.3, 0.3, 0.3]);
hold off;
grid on;
xlabel('Block update count');
ylabel('dLev amplitude');
title('dlev\_loop sign-sign LMS convergence');
legend('DLevInner', 'DLevOuter', 'Location', 'best');

% 强制刷新图像窗口,确保脚本运行时实时显示两张收敛曲线。
drawnow;

% 保存两张 PNG 到结果目录,便于查看与后续回归对比。
lmsPng = fullfile(resultDir, 'dlev_loop_lms_convergence.png');
ssPng = fullfile(resultDir, 'dlev_loop_sslms_convergence.png');
exportgraphics(figLms, lmsPng, 'Resolution', 200);
exportgraphics(figSs, ssPng, 'Resolution', 200);

% 打印最终收敛值与输出路径,方便在命令行确认环路工作正常。
disp(['LMS    final dLev = [', num2str(lmsState.DLevInner), ', ', num2str(lmsState.DLevOuter), ']']);
disp(['SS-LMS final dLev = [', num2str(ssLmsState.DLevInner), ', ', num2str(ssLmsState.DLevOuter), ']']);
disp(['Saved PNG: ', lmsPng]);
disp(['Saved PNG: ', ssPng]);
