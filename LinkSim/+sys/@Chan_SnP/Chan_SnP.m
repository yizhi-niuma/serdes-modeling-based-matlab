classdef (StrictDefaults) Chan_SnP < matlab.System

    properties
        snp_file_name
        privImpulse
        %Sample interval (s)
        %   The discrete fixed-step simulation sample interval.
        dt {mustBePositive(dt), mustBeFinite(dt), mustBeNonNan(dt)}= 1e-12;
        privBuffer
    end


    methods
        %Constrcutor

        function obj = Chan_SnP(varargin)
            setProperties(obj,nargin,varargin{:});
            chan_real = SParameterChannel('FileName', obj.snp_file_name,'SampleInterval',obj.dt, ...
                'TxC',0.1e-12,'RxC',0.2e-12);
            obj.privImpulse = chan_real.ImpulseResponse*obj.dt;
            obj.privImpulse= obj.privImpulse(1: round(length(obj.privImpulse)*0.5));
            obj.privBuffer = zeros(length(obj.privImpulse)-1,1);
        end

        function y = chan_conv(obj,waveIn)
                 y = conv(obj.privImpulse, waveIn);
                 y = y(length(obj.privImpulse):end);
                 
        end


    end

    methods(Access = protected)
        function [y,varargout] = stepImpl(obj,waveIn,varargin)
            
            [y,localPrivBuffer] = filter(obj.privImpulse,1,waveIn,obj.privBuffer);
            obj.privBuffer = localPrivBuffer;
        end


    end



end