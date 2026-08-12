这个脚本的目标是：
读取 waveform.csv 中的 CTLE 输出波形；
按照 112 Gbps PAM4、oversample = 128 推导 UI；
自动识别并去掉前面因信道延迟产生的近零段；
保持眼图张开位置居中；
叠加绘制 -1 UI 到 +1 UI 的 2 UI 眼图；

