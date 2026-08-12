classdef sar_adc_tah
    %SAR_ADC_TAH differential track-and-hold model.
    %
    %   Behavior:
    %   - During the track phase, Vip/Vin follows the input.
    %   - After the track phase ends, Vip/Vin/Vdiff are held for the SAR core.

    properties
        Vip
        Vin
        Vdiff
        Track
    end

    methods
        function obj = sar_adc_tah()
            obj = obj.reset();
        end

        function obj = startTrack(obj, Vip, Vin)
            %STARTTRACK Start a new track phase and update held output.
            obj.Track = true;
            obj = obj.updateTrack(Vip, Vin);
        end

        function obj = updateTrack(obj, Vip, Vin)
            %UPDATETRACK Update track-and-hold output while track phase is active.
            obj.Vip = Vip;
            obj.Vin = Vin;
            obj.Vdiff = Vip - Vin;
        end

        function obj = stopTrack(obj)
            %STOPTRACK End track phase and keep the last tracked input.
            obj.Track = false;
        end

        function obj = reset(obj)
            %RESET Clear held output and return to hold state.
            obj.Vip = 0;
            obj.Vin = 0;
            obj.Vdiff = 0;
            obj.Track = false;
        end
    end
end
