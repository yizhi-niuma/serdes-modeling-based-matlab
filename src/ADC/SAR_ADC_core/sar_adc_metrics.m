classdef sar_adc_metrics
    %SAR_ADC_METRICS ADC dynamic and static performance analysis utilities.

    methods (Static)
        function [THD, SFDR, SNR, SNDR, ENOB] = Dynamic_test(Dout, Fs, Nsample, plot_en)
            %DYNAMIC_TEST Calculate ADC dynamic metrics from decimal output codes.
            %   Dout: decimal output code sequence.
            %   Fs: ADC sampling frequency.
            %   Nsample: number of samples used by FFT.
            %   plot_en: true to plot normalized spectrum.
            if nargin < 4
                plot_en = false;
            end
            if nargin < 3 || isempty(Nsample)
                Nsample = length(Dout);
            end
            if length(Dout) < Nsample
                error('sar_adc_metrics:InvalidNsample', 'Nsample must be less than or equal to length(Dout).');
            end

            Dout = Dout(:);
            Dout = Dout(1:Nsample);
            Dout = Dout - mean(Dout);

            nHalf = floor(Nsample / 2);
            signal_bin = 5;
            harmonic_bin = 30;
            start_power = 5;

            Amp_spectrum = abs(fft(Dout, Nsample));
            Power_spectrum = Amp_spectrum.^2;
            dB_spectrum = 10 * log10(Power_spectrum / (Nsample / 2) + eps);
            max_dBc = max(dB_spectrum(1:nHalf));
            [~, bin] = max(dB_spectrum(start_power:nHalf));
            bin = bin + start_power - 1;
            signal_frequency = bin;

            signalStart = max(start_power, bin - signal_bin);
            signalStop = min(nHalf, bin + signal_bin);
            signal_power = sum(Power_spectrum(signalStart:signalStop));
            total_power = sum(Power_spectrum(start_power:nHalf));

            harmonic_indices = signal_frequency * (2:10);
            harmonic_power_single = zeros(1, length(harmonic_indices));
            for i = 1:length(harmonic_indices)
                harmonicIndex = sar_adc_metrics.foldToNyquist(harmonic_indices(i), nHalf);
                if harmonicIndex >= start_power
                    harmonicStart = max(start_power, harmonicIndex - harmonic_bin);
                    harmonicStop = min(nHalf, harmonicIndex + harmonic_bin);
                    harmonic_power_single(i) = sum(Power_spectrum(harmonicStart:harmonicStop));
                end
            end
            harmonic_power = sum(harmonic_power_single);

            noiseAndDistortionPower = max(total_power - signal_power, eps);
            noisePower = max(total_power - signal_power - harmonic_power, eps);

            THD = 10 * log10(max(harmonic_power, eps) / signal_power);
            SNDR = 10 * log10(signal_power / noiseAndDistortionPower);
            SNR = 10 * log10(signal_power / noisePower);
            ENOB = (SNDR - 1.76) / 6.02;

            Dout_SFDR = abs(dB_spectrum - dB_spectrum(bin));
            Dout_SFDR = Dout_SFDR(1:nHalf);
            spurRanges = true(1, nHalf);
            spurRanges(1:start_power-1) = false;
            spurRanges(signalStart:signalStop) = false;
            if any(spurRanges)
                SFDR = min(Dout_SFDR(spurRanges));
            else
                SFDR = NaN;
            end

            if plot_en
                fs = Fs / 1e9;
                fin = bin * Fs / Nsample / 1e6;
                figure;
                Figure = plot((0:nHalf-1) * fs / Nsample, dB_spectrum(2:nHalf+1) - max_dBc, 'k');
                grid on;
                zoom;
                set(gca, 'linewidth', 3);
                set(gca, 'fontsize', 20, 'FontWeight', 'bold', 'fontname', 'Arial');
                set(Figure, 'linewidth', 2.5);
                title(sprintf('fin = %.2f MHz, fs = %.3g GHz', fin, fs), 'FontWeight', 'bold', 'fontsize', 20, 'fontname', 'Arial');
                xlabel('Frequency (GHz)', 'FontWeight', 'bold', 'fontsize', 20, 'fontname', 'Arial');
                ylabel('Amplitude (dBc)', 'FontWeight', 'bold', 'fontsize', 20, 'fontname', 'Arial');
                xlim([0 fs / 2]);
                ylim([-140 0]);
                text(fs / 5, -30, sprintf('THD = %.2f dB\nSFDR = %.2f dB\nSNR = %.2f dB\nSNDR = %.2f dB\nENOB = %.2f bit', THD, SFDR, SNR, SNDR, ENOB), ...
                    'LineWidth', 2, 'fontsize', 20, 'Margin', 5, 'FontWeight', 'bold', 'fontname', 'Arial');
                set(gcf, 'unit', 'centimeters', 'position', [10 5 18 14]);
                hold off;
            end
        end

        function [DNLmax, DNLmin, INLmax, INLmin] = ramp_INLDNL(Dout, N, plot_en)
            %RAMP_INLDNL Calculate ramp-code DNL and INL metrics.
            %   Dout: decimal output code sequence from ramp input.
            %   N: ADC resolution in bits.
            %   plot_en: true to plot DNL and INL.
            if nargin < 3
                plot_en = false;
            end

            Dout = Dout(:)';
            edges = -0.5:(2^N - 0.5);
            h = histcounts(Dout, edges);
            codeAxis = 0:length(h)-1;
            validCodeIndex = 2:length(h)-1;
            mean_l = mean(h(validCodeIndex));
            dnl = h(validCodeIndex) / mean_l - 1;
            inl = cumsum(dnl);
            inl = inl - linspace(inl(1), inl(end), length(inl));
            plotCodeAxis = codeAxis(validCodeIndex);
            DNLmax = max(dnl);
            DNLmin = min(dnl);
            INLmax = max(inl);
            INLmin = min(inl);

            if plot_en
                figure;
                subplot(2, 1, 1);
                Q_DNL = plot(plotCodeAxis, dnl, 'k');
                hold on;
                set(gca, 'linewidth', 2);
                set(gca, 'FontWeight', 'bold', 'fontsize', 15, 'fontname', 'Arial');
                set(Q_DNL, 'linewidth', 2);
                title(sprintf('DNL'), 'FontWeight', 'bold', 'fontsize', 20, 'fontname', 'Arial');
                xlabel('Digital Code [LSB]');
                ylabel('DNL [LSB]');
                grid on;
                box on;
                xlim([1 2^N - 2]);
                text(0.02, 0.5, sprintf('DNLmax = %.2f LSB\n\n\n\nDNLmin = %.2f LSB', DNLmax, DNLmin), ...
                    'sc', 'FontWeight', 'bold', 'fontsize', 15, 'fontname', 'Arial');

                subplot(2, 1, 2);
                Q_INL = plot(plotCodeAxis, inl, 'k');
                hold on;
                set(gca, 'linewidth', 2);
                set(gca, 'FontWeight', 'bold', 'fontsize', 15, 'fontname', 'Arial');
                set(Q_INL, 'linewidth', 2);
                title(sprintf('INL'), 'FontWeight', 'bold', 'fontsize', 20, 'fontname', 'Arial');
                xlabel('Digital Code [LSB]');
                ylabel('INL [LSB]');
                grid on;
                box on;
                xlim([1 2^N - 2]);
                set(gca, 'xgrid', 'off');
                set(gcf, 'unit', 'centimeters', 'position', [10 5 18 14]);
                text(0.02, 0.5, sprintf('INLmax = %.2f LSB\n\n\n\nINLmin = %.2f LSB', INLmax, INLmin), ...
                    'sc', 'FontWeight', 'bold', 'fontsize', 15, 'fontname', 'Arial');
            end
        end
    end

    methods (Static, Access = private)
        function foldedBin = foldToNyquist(inputBin, nHalf)
            foldedBin = mod(inputBin, 2 * nHalf);
            if foldedBin == 0
                foldedBin = 2 * nHalf;
            end
            if foldedBin > nHalf
                foldedBin = 2 * nHalf - foldedBin;
            end
            foldedBin = max(1, round(foldedBin));
        end
    end
end
