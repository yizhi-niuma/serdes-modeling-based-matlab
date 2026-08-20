classdef tx_channel
    % tx_channel  Minimal symbol-source and S-parameter channel model.

    properties (SetAccess = private)
        ChannelFile
        SymbolRate
        SamplesPerSymbol
        SampleRate
        SampleInterval
        ImpulseResponse
    end

    methods
        function obj = tx_channel(channelFile, symbolRate, samplesPerSymbol)
            % tx_channel  Load a differential four-port channel model.

            if nargin < 1 || isempty(channelFile)
                classDir = fileparts(mfilename('fullpath'));
                repoRoot = fileparts(fileparts(classDir));
                channelFile = fullfile(repoRoot, 'data', 'Channel', ...
                    'DPO_4in_Meg7_THRU.s4p');
            end
            if nargin < 2
                symbolRate = 56e9;
            end
            if nargin < 3
                samplesPerSymbol = 128;
            end

            if ~(ischar(channelFile) || (isstring(channelFile) && isscalar(channelFile)))
                error('tx_channel:InvalidChannelFile', ...
                    'ChannelFile must be a character vector or string scalar.');
            end
            channelFile = char(channelFile);
            if ~isfile(channelFile)
                error('tx_channel:ChannelFileNotFound', ...
                    'Channel file does not exist: %s', channelFile);
            end
            if ~(isnumeric(symbolRate) && isscalar(symbolRate) && ...
                    isreal(symbolRate) && isfinite(symbolRate) && symbolRate > 0)
                error('tx_channel:InvalidConfiguration', ...
                    'SymbolRate must be a positive finite scalar.');
            end
            if ~(isnumeric(samplesPerSymbol) && isscalar(samplesPerSymbol) && ...
                    isreal(samplesPerSymbol) && isfinite(samplesPerSymbol) && ...
                    samplesPerSymbol > 0 && samplesPerSymbol == fix(samplesPerSymbol))
                error('tx_channel:InvalidConfiguration', ...
                    'SamplesPerSymbol must be a positive integer scalar.');
            end

            obj.ChannelFile = channelFile;
            obj.SymbolRate = double(symbolRate);
            obj.SamplesPerSymbol = double(samplesPerSymbol);
            obj.SampleRate = obj.SymbolRate * obj.SamplesPerSymbol;
            obj.SampleInterval = 1 / obj.SampleRate;

            channel = SParameterChannel('FileName', obj.ChannelFile, ...
                'Signaling', 'differential', 'PortOrder', [1 2 3 4], ...
                'SampleInterval', obj.SampleInterval, ...
                'StopTime', 1000 / obj.SymbolRate, ...
                'TxR', 50, 'TxC', 0, 'RxR', 50, 'RxC', 0);
            obj.ImpulseResponse = channel.ImpulseResponse * obj.SampleInterval;
        end

        function txWaveform = symbolsToWaveform(obj, symbols)
            % symbolsToWaveform  Apply ideal zero-order hold to voltage symbols.

            obj.validateSymbols(symbols);
            txWaveform = repelem(double(symbols), obj.SamplesPerSymbol);
        end

        function [outputWaveform, time] = process(obj, symbols)
            % process  Send one complete symbol vector through the channel.

            txWaveform = obj.symbolsToWaveform(symbols);
            inputSize = size(txWaveform);
            outputWaveform = fftfilt(obj.ImpulseResponse, txWaveform(:));
            outputWaveform = reshape(outputWaveform, inputSize);
            time = reshape((0:numel(txWaveform) - 1) * obj.SampleInterval, ...
                inputSize);
        end
    end

    methods (Access = private)
        function validateSymbols(~, symbols)
            if ~(isnumeric(symbols) && isvector(symbols) && ~isempty(symbols) && ...
                    isreal(symbols) && all(isfinite(symbols), 'all'))
                error('tx_channel:InvalidSymbols', ...
                    'Symbols must be a nonempty finite real numeric vector.');
            end
        end
    end
end
