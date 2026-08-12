classdef sar_adc_channel
    %SAR_ADC_CHANNEL differential SAR ADC channel composed of TAH and SAR core.
    %
    %   Behavior:
    %   - The first high level of clk is the TAH track/sample phase.
    %   - After that sample phase, later rising edges advance the SAR core by one bit decision.
    %   - A full conversion takes one high-level sample phase plus N SAR decision phases.
    %   - Dout/Dout_dec/Vout update only after the Nth SAR bit is resolved.
    %   - Between completed conversions the output is held unchanged.

    properties
        Tah
        Core

        PrevClk
        Busy
        TAHTrack
    end

    methods
        function obj = sar_adc_channel(VL, VH, N, nonideal_en)
            if nargin < 4
                nonideal_en = false;
            end
            if nargin < 3
                N = 7;
            end
            if nargin < 2
                VH = 0.3;
            end
            if nargin < 1
                VL = -0.3;
            end

            obj.Tah = sar_adc_tah();
            obj.Core = sar_adc_core(VL, VH, N, nonideal_en);
            obj.PrevClk = false;
            obj.Busy = false;
            obj.TAHTrack = false;
        end

        function [obj, Dout, Dout_dec, Vout, conversionDone, varargout] = convertByClock(obj, Vip, Vin, clk)
            %CONVERTBYCLOCK Advance TAH and SAR core by current Vip/Vin/clk.
            clkHigh = clk > 0.5;
            prevHigh = obj.PrevClk;
            risingEdge = clkHigh && ~prevHigh;
            conversionDone = false;

            if ~obj.Busy
                [core, Dout, Dout_dec, Vout, ~] = obj.Core.convertByClock(obj.Tah.Vip, obj.Tah.Vin, false);
                obj.Core = core;
                if risingEdge
                    obj.Busy = true;
                    obj.TAHTrack = true;
                    obj.Tah = obj.Tah.startTrack(Vip, Vin);
                end
            elseif obj.TAHTrack
                [core, Dout, Dout_dec, Vout, ~] = obj.Core.convertByClock(obj.Tah.Vip, obj.Tah.Vin, false);
                obj.Core = core;
                if clkHigh
                    obj.Tah = obj.Tah.updateTrack(Vip, Vin);
                else
                    obj.Tah = obj.Tah.stopTrack();
                    obj.TAHTrack = false;
                end
            else
                [core, Dout, Dout_dec, Vout, conversionDone] = obj.Core.convertByClock(obj.Tah.Vip, obj.Tah.Vin, clk);
                obj.Core = core;
                if conversionDone
                    obj.Busy = false;
                    obj.TAHTrack = false;
                end
            end

            obj.PrevClk = clkHigh;
            if nargout > 5
                varargout{1} = obj.Core.getLastTrace();
            end
        end

        function obj = setIdealMode(obj)
            %SETIDEALMODE Configure SAR core ideal mode.
            obj.Core = obj.Core.setIdealMode();
        end

        function obj = setNonideal(obj, varargin)
            %SETNONIDEAL Configure selected SAR core nonideal terms with name-value pairs.
            obj.Core = obj.Core.setNonideal(varargin{:});
        end

        function obj = setCapUnit(obj, Cu)
            %SETCAPUNIT Set SAR core unit capacitance and update capacitor array.
            obj.Core = obj.Core.setCapUnit(Cu);
        end

        function obj = reset(obj)
            %RESET Clear TAH, SAR core, channel state, and held output.
            obj.Tah = obj.Tah.reset();
            obj.Core = obj.Core.reset();
            obj.PrevClk = false;
            obj.Busy = false;
            obj.TAHTrack = false;
        end

        function obj = setTraceMode(obj, trace_en)
            %SETTRACEMODE Enable or disable SAR core bit-by-bit trace recording.
            obj.Core = obj.Core.setTraceMode(trace_en);
        end

        function trace = getLastTrace(obj)
            %GETLASTTRACE Return SAR core latest complete conversion trace.
            trace = obj.Core.getLastTrace();
        end
    end
end
