classdef ctle
    % ctle  Minimal continuous-time CTLE for MMPD debugging.

    properties
        SamplePerSymbol = 128
        SymbolRate = 56e9
        ZeroFrequency = 7e9
        FirstPoleFrequency = 14.3158150798686e9
        SecondPoleFrequency = 56e9
        DCGainDb = 0
    end

    methods
        function obj = ctle(samplePerSymbol)
            if nargin >= 1
                obj.SamplePerSymbol = samplePerSymbol;
            end
        end

        function system = transferFunction(obj)
            % transferFunction  Return H(s)=k1*(s+wz)/((s+wp1)*(s+wp2)).

            wz = 2 * pi * obj.ZeroFrequency;
            wp1 = 2 * pi * obj.FirstPoleFrequency;
            wp2 = 2 * pi * obj.SecondPoleFrequency;
            dcGain = 10^(obj.DCGainDb / 20);
            k1 = dcGain * wp1 * wp2 / wz;

            system = tf(k1 * [1 wz], conv([1 wp1], [1 wp2]));
        end

        function outputWaveform = process(obj, inputWaveform)
            % process  Apply the continuous-time CTLE to one waveform.

            inputSize = size(inputWaveform);
            sampleRate = obj.SymbolRate * obj.SamplePerSymbol;
            time = (0:numel(inputWaveform) - 1).' / sampleRate;
            outputWaveform = lsim(obj.transferFunction(), ...
                double(inputWaveform(:)), double(time(:)));
            outputWaveform = reshape(outputWaveform, inputSize);
        end
    end
end
