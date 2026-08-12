classdef (StrictDefaults) CTLE < serdes.SerdesAbstractSystemObject
    
    properties(Nontunable) %port/property duality
        %ModePort ModePort 
        %   Specify Mode from input port in Simulink
        ModePort (1, 1) logical = true;
    end
    properties
        %Mode Mode (0: Off, 1: Fixed, 2: Adapt Init only)
        %   When Mode=0, the CTLE is bypassed and the waveform is not
        %   modified.  When Mode=1, the CTLE applies the transfer function
        %   specified by the ConfigSelect property.  When Mode=2 and
        %   WaveType is 'Impulse' or 'Waveform', the CTLE selects and
        %   applies the ConfigSelect which best opens the eye.  When Mode=2
        %   and WaveType is 'Sample' the CTLE behavior is the same Mode=1
        %   (fixed).
        Mode = 2;
    end
    properties (Nontunable)
        %Specification
        %   Set the Specification to 'DC Gain and Peaking Gain', 'DC Gain
        %   and AC Gain', 'AC Gain and Peaking Gain' or 'GPZ Matrix'.  The
        %   default is 'DC Gain and Peaking Gain'.
        Specification = 'DC Gain and Peaking Gain';
    end    
    properties(Constant, Hidden)
        SpecificationSet = matlab.system.StringSet( { ...
            'DC Gain and Peaking Gain', ...
            'DC Gain and AC Gain', ...
            'AC Gain and Peaking Gain', ...
            'GPZ Matrix'} );
    end    
    properties(Nontunable) %port/property duality
        %SliceSelectPort SliceSelectPort
        %   Specify SliceSelect from input port in Simulink
        SliceSelectPort (1, 1) logical = false;
    end
    properties
        %Slice index select
        %   Dimensional selection of the GPZ Matrix, SliceSelect is a
        %   zero-based index. Default is SliceSelect = 0.
        SliceSelect = 0;
    end
    properties(Nontunable) %port/property duality
        %ConfigSelectPort ConfigSelectPort
        %Enable Config input port in Simulink
        ConfigSelectPort (1, 1) logical = true;
    end    
    properties
        %Configuration select
        %   Selects which member of the transfer function to apply when
        %   Mode=1.  ConfigSelect is a zero-based index.
        ConfigSelect = 0;
    end
    
    properties (Nontunable)
        %Peaking frequency (Hz)
        %   The approximate frequency at which the peaking filter transfer
        %   function peaks in magnitude.  Specify a scalar or a vector that
        %   agrees in length with DCGain, ACGain and PeakingGain.
        PeakingFrequency = 5e9
        
        %DC gain (dB)
        %   The gain at 0 Hz in dB for the peaking filter transfer
        %   function. Specify a scalar or a vector that agrees in length
        %   with PeakingFrequency, ACGain and PeakingGain.
        DCGain = 0:-1:-8
        
        %AC gain (dB)
        %   The gain in dB at the peaking frequency for the peaking filter
        %   transfer function. Specify a scalar or a vector that agrees in
        %   length with PeakingFrequency, DCGain and PeakingGain.
        ACGain = 0;
        
        %Peaking gain (dB)
        %   The peaking gain in dB (i.e. the difference between the AC and
        %   DC gain) for the peaking filter transfer function. Specify a
        %   scalar or a vector that agrees in length with PeakingFrequency,
        %   ACGain and DCGain.
        PeakingGain = 0:8;
        
        %Gain pole zero matrix
        %   A matrix which explicitly defines the family of transfer
        %   functions by specifying the DC gain (dB) in column 1 and then
        %   poles and zeros (Hz) in alternating columns.  When FilterMethod
        %   is Cascaded repeated poles and zeros are allowed otherwise when
        %   FilterMethod is PartialFraction, no repeated poles or zeros
        %   allowed. Complex poles or zeros must have a conjugate and more
        %   poles than zeros are required to ensure stability. Poles and
        %   Zeros of 0 Hz will be ignored and can be used to zero pad the
        %   matrix. GPZ can define multiple slices/families/corners of CTLE
        %   responses by extending into the 3rd dimension. The choice of
        %   which slice is controlled by the SliceSelect parameter. Utilize
        %   static methods, CombineSlices and GainPoleZeroToGPZ to aid in
        %   creating GPZ matrices.
 
        GPZ = [0 -23771428571 -10492857142 -13092857142;
            -1 -17603571428 -7914982142  -13344642857;
            -2 -17935714285 -6845464285  -13596428571;
            -3 -15321428571 -5574642857  -13848214285;
            -4 -15600000000 -4960100000  -14100000000;
            -5 -15878571428 -4435821428  -14351785714;
            -6 -16157142857 -3981285714  -14603571428;
            -7 -16435714285 -3581089285  -14855357142;
            -8 -16714285714 -3227142857  -15107142857];
    end
    
    properties(Constant, Hidden)
        GPZAttributes = {'Matrix'};
        WaveTypeAttributes = {'NoDisplayInSerDesDesignerApp'};
        SymbolTimeAttributes = {'NoDisplayInSerDesDesignerApp'};
        SampleIntervalAttributes = {'NoDisplayInSerDesDesignerApp'};
        ModulationAttributes = {'NoDisplayInSerDesDesignerApp'};
        PeakingFrequencyAttributes = {'Vector'};
        DCGainAttributes = {'Vector'};
        ACGainAttributes = {'Vector'};
        PeakingGainAttributes = {'Vector'};
        OutputOptMetricAttributes = {'NoDisplayInSerDesDesignerApp'};
        
        Mode_ToolTip = getString(message('serdes:serdesdesigner:CTLEMode_ToolTip'));
        PeakingFrequency_NameInGUI = getString(message('serdes:serdesdesigner:CTLEPeakingFrequency_NameInGUI'));
        PeakingFrequency_ToolTip   = getString(message('serdes:serdesdesigner:CTLEPeakingFrequency_ToolTip'));
        ConfigSelect_NameInGUI = getString(message('serdes:serdesdesigner:CTLEConfigSelect_NameInGUI'));
        ConfigSelect_ToolTip   = getString(message('serdes:serdesdesigner:CTLEConfigSelect_ToolTip'));
        SliceSelect_NameInGUI = getString(message('serdes:serdesdesigner:SliceSelect_NameInGUI'));       
        SliceSelect_ToolTip  = getString(message('serdes:serdesdesigner:CTLESliceSelect_ToolTip'));
        DCGain_NameInGUI = getString(message('serdes:serdesdesigner:CTLEDCGain_NameInGUI'));
        DCGain_ToolTip   = getString(message('serdes:serdesdesigner:CTLEDCGain_ToolTip'))
        ACGain_NameInGUI = getString(message('serdes:serdesdesigner:CTLEACGain_NameInGUI'));
        ACGain_ToolTip   = getString(message('serdes:serdesdesigner:CTLEACGain_ToolTip'));
        PeakingGain_NameInGUI = getString(message('serdes:serdesdesigner:CTLEPeakingGain_NameInGUI'));
        PeakingGain_ToolTip   = getString(message('serdes:serdesdesigner:CTLEPeakingGain_ToolTip'));
        GPZ_NameInGUI = getString(message('serdes:serdesdesigner:CTLEGPZ_NameInGUI'));
        GPZ_ToolTip   = getString(message('serdes:serdesdesigner:CTLEGPZ_ToolTip'));
        PerformanceCriteria_NameInGUI = getString(message('serdes:serdesdesigner:PerformanceCriteria_NameInGUI'));
        PerformanceCriteria_ToolTip = getString(message('serdes:serdesdesigner:PerformanceCriteria_ToolTip'));    
        FilterMethod_NameInGUI = getString(message('serdes:serdesdesigner:CTLEFilterMethod_NameInGUI'));
        FilterMethod_ToolTip   = getString(message('serdes:serdesdesigner:CTLEFilterMethod_ToolTip'));        
    end
    
    properties (SetAccess=protected, Hidden)
        ConfigCount = 9;
        SliceCount = 1;
    end
    
    properties (SetAccess=protected, Hidden)
        %FilterCoefficients holds the discrete z-domain filter coefficients
        %after their conversion from the continuous s-domain poles, zeros
        %and gains.
        FilterCoefficients  = struct();
        
        isUpToDate = false;
    end
    properties (Constant, Hidden) %port/property duality
        SliceSelectSet = matlab.system.SourceSet( ...
            {'PropertyOrInput', 'SystemBlock', 'SliceSelectPort', 3, 'SliceSelect'}, ...
            {'Property', 'MATLAB', 'SliceSelectPort'})

        ConfigSelectSet = matlab.system.SourceSet( ...
            {'PropertyOrInput', 'SystemBlock', 'ConfigSelectPort', 2, 'ConfigSelect'}, ...
            {'Property', 'MATLAB', 'ConfigSelectPort'})
        
        ModeSet = matlab.system.SourceSet(...
            {'PropertyOrInput', 'SystemBlock', 'ModePort', 1, 'Mode'}, ...
            {'Property', 'MATLAB', 'ModePort'});
    end
    
    properties (Nontunable)
        %Input Waveform Type
        %   Set the input wave type as one of 'Sample' | 'Impulse' |
        %   'Waveform'.  The default is 'Sample'.
        WaveType = 'Sample';
        
        %CTLE adaptation optimization criteria control
        %   Set to 'SNR' | 'maxEyeHeight' | 'maxEyeHeight' | 'maxMeanEyeHeight' |
        %   'maxCOM' | 'eyeArea' | 'eyeWidth' | 'centerEyeHeight' | 
        %   'centerMeanEyeHeight' | 'centerCOM'.  The default is 'SNR'
        PerformanceCriteria = 'SNR';
        
        %Filter Method
        %   FilterMethod can be either 'Cascaded' or 'PartialFraction'        
        FilterMethod = 'PartialFraction';

        %Output optimization metric value (Init only)
        OutputOptMetric (1, 1) logical = false;        
    end
    
    properties (Hidden,Constant)
        %Metric BER level used for pulse goodness calculation
        MetricBER = 1e-6;
        
        WaveTypeSet = matlab.system.StringSet({'Sample','Impulse','Waveform'});
        PerformanceCriteriaSet = matlab.system.StringSet({'SNR','maxEyeHeight',...
            'maxMeanEyeHeight','maxCOM','eyeArea','eyeWidth',...
            'centerEyeHeight','centerMeanEyeHeight','centerCOM'}); 
        FilterMethodSet = matlab.system.StringSet({'Cascaded','PartialFraction'});
    end
    
    properties (SetAccess = immutable, Nontunable, Hidden)
        IsLinear = true;
        IsTimeInvariant = true;
    end
    properties (Access=protected)
        privConfigInitial
        privConfigInitialFlag = true;
    end
    properties (SetAccess=protected, Hidden)
        %Cascaded Filter Properties
        FilterNumerator
        FilterNumeratorCount
        FilterDenominator
        FilterDenominatorCount
        FilterGain
        FilterStates
        FilterStatesCount
        pFilterMethod
    end
    
    methods
        % Constructor
        function obj = CTLE(varargin)
            % Support name-value pair arguments when constructing object
            obj.BlockName = 'CTLE';
            setProperties(obj,nargin,varargin{:})
        end
    end
    methods (Hidden)
        % The below methods, getAMIParameters, getAMIInputNames and
        % getAMIOutputNames are for use only within the serdesDesigner App
        % and will not influence the AMI parameters in Simulink whatsoever.
        function amiParams = getAMIParameters(obj)            

            ModeAMI = serdes.internal.ibisami.ami.parameter.SerDesModelSpecificParameter(...
                'Name', 'Mode',...
                'Description', 'CTLE Mode: 0=off, 1=fixed, 2=adapt',...
                'Usage', 'In',...
                'Type', 'Integer',...
                'Format', "List 2 0 1",...
                'CurrentValue', obj.Mode);
            ModeAMI.Format.ListTips = {'adapt','off','fixed'};
            ModeAMI.Format.Default=2;
            
            configFormat = sprintf('List %s',+sprintf(' %i',(0:obj.ConfigCount-1)));

            %Get valid ConfigSelect.  If the user changed the Specification
            %then it is possible that the current ConfigSelect is stale, so
            %ensure here that a valid configuration setting is output.
            localConfig = min(obj.ConfigCount-1,obj.ConfigSelect);
            
            ConfigSelectAMI = serdes.internal.ibisami.ami.parameter.SerDesModelSpecificParameter(...
                'Name', 'ConfigSelect',...
                'Description', 'CTLE config transfer function selection.',...
                'Usage', 'InOut',...
                'Type', 'Integer',...
                'Format', configFormat,...
                'CurrentValue', localConfig);

            sliceFormat = sprintf('List %s',+sprintf(' %i',(0:obj.SliceCount-1)));            
            SliceSelectAMI = serdes.internal.ibisami.ami.parameter.SerDesModelSpecificParameter(...
                'Name', 'SliceSelect',...
                'Description', 'CTLE slice/family/corner transfer function selection.',...
                'Usage', 'In',...
                'Type', 'Integer',...
                'Format', sliceFormat,...
                'CurrentValue', obj.SliceSelect);
            
            amiParams = {ModeAMI, ConfigSelectAMI, SliceSelectAMI};
        end
        function names = getAMIInputNames(~)
            names = {'Mode','ConfigSelect','SliceSelect'};
        end
        function names = getAMIOutputNames(~)
            names = {'ConfigSelect'};
        end
    end
    methods
        function set.ConfigSelect(obj,val)
            obj.ConfigSelect = double(val);
            
            %Do not validate ConfigSelect at set time as it is not
            %guaranteed that other dependent properties (i.e.
            %Specification, GPZ, etc) have been set previously. Otherwise,
            %codegen issues will arise.
            %validateConfig(obj,val);
        end
        
        function set.Mode(obj,val)
            %Mode: 0=off, 1=fixed, 2=adapt
            validateattributes(val,...
                {'numeric'},...
                {'scalar'},...
                '','Mode');
            mustBeMember(val, [0,1,2])
            obj.Mode = double(val);
        end
        
        function set.PeakingFrequency(obj,val)
            validateattributes(val,...
                {'numeric'},...
                {'vector','finite','positive'},...
                '','PeakingFrequency');
            obj.PeakingFrequency = val;
            notUpToDate(obj);
        end
        function set.DCGain(obj,val)
            validateattributes(val,...
                {'numeric'},...
                {'vector','finite'},...
                '','DCGain');
            obj.DCGain = val;
            notUpToDate(obj);
        end
        function set.ACGain(obj,val)
            validateattributes(val,...
                {'numeric'},...
                {'vector','finite'},...
                '','ACGain');
            obj.ACGain = val;
            notUpToDate(obj);
        end
        function set.PeakingGain(obj,val)
            validateattributes(val,...
                {'numeric'},...
                {'vector','finite','nonnegative'},...
                '','PeakingGain');
            obj.PeakingGain = val;
            notUpToDate(obj);
        end
        function set.GPZ(obj,val)
            validateattributes(val,...
                {'numeric'},...
                {'3d','finite','nonempty'},...
                '','GPZ');

            for ii = 1:size(val,3)
                %Loop over each GPZ slice and validate it.                
                G = real(val(:,1,ii));
                P = val(:,2:2:end,ii);
                Z = val(:,3:2:end,ii);

                serdes.CTLE.validateGPZ(G,P,Z,ii-1);
            end
            obj.GPZ = val;
            notUpToDate(obj);
        end
        function set.FilterMethod(obj,val)
            obj.FilterMethod = val;
            notUpToDate(obj);
        end
        function set.SliceSelect(obj,val)
            obj.SliceSelect = val;
            notUpToDate(obj);
        end        
        function set.OutputOptMetric(obj,val)
            validateattributes(val,{'numeric','logical'},{'scalar','finite'},'','OutputOptMetric');
            mustBeMember(val, [0, 1]);
            obj.OutputOptMetric = logical(val);
        end
        function val = get.ConfigCount(obj)
            
            lenvec = [length(obj.PeakingFrequency),length(obj.DCGain),...
                length(obj.ACGain),length(obj.PeakingGain),size(obj.GPZ,1)];
            %Config Count is calculated as the minimum vector length
            %(excluding scalar vectors) of the specified input vectors.
            if strcmpi(obj.Specification,'DC Gain and Peaking Gain')
                dontCareMask = logical([1 1 0 1 0]);
                val = max([1,min(lenvec((lenvec~=1)&dontCareMask))]);
                obj.ConfigCount = val;
            elseif strcmpi(obj.Specification,'DC Gain and AC Gain')
                dontCareMask = logical([1 1 1 0 0]);
                val = max([1,min(lenvec((lenvec~=1)&dontCareMask))]);
                obj.ConfigCount = val;
            elseif strcmpi(obj.Specification,'AC Gain and Peaking Gain')
                dontCareMask = logical([1 0 1 1 0]);
                val = max([1,min(lenvec((lenvec~=1)&dontCareMask))]);
                obj.ConfigCount = val;
            else %if strcmpi(obj.Specification,'GPZ Matrix')                
                val = size(obj.GPZ,1);
                obj.ConfigCount = val;
            end
        end
        function val = get.SliceCount(obj)
            if strcmpi(obj.Specification,'GPZ Matrix')
                val = size(obj.GPZ,3);
            else
                val = 1;
            end
        end
        function varargout=response(obj,varargin)
            %RESPONSE   Returns the serdes.CTLE transfer function response
            %
            %[f,H]=response(serdes.CTLE) returns the transfer function
            %response H, and the frequency vector f.
            %
            %[f,H]=response(serdes.CTLE,f) returns the transfer function
            %family at the frequency points defined by f in Hz.
            
            %Frequency input definition
            if nargin == 1 || isempty(varargin{1})
                %Define max frequency
                fmax = 1/obj.SymbolTime*4;
                
                %Create Frequency vector
                f = linspace(0,fmax,5001);
            else
                f = varargin{1};
                validateattributes(f,{'numeric'},{'vector'},'','f');
            end          
            
            %Ensure CTLE is setup. Primarily ensure that pole/zeros are
            %valid and switch to cascaded if there are repeated poles.
            setupImpl(obj);

            %Retrieve Gain, Pole, Zero values    
            [G,P,Z]=getGPZ(obj);
            
            %Determine size of CTLE family
            N = length(G);
            
            %Calculate Frequency Domain Transfer Function
            H = zeros(N,length(f));
            for ii = 1:N
                
                g = G(ii);
                p = P(ii,P(ii,:)~=0);  %GPZ matrix is zero padded.  Remove any extra zero entries.
                z = Z(ii,Z(ii,:)~=0);
                
                %Calculate gain coefficient
                k = g*abs(serdes.CTLE.cprod(p)/serdes.CTLE.cprod(z));
                
                %Calculate transfer function
                H(ii,:) = k*polyval(poly(z),1i*f)./polyval(poly(p),1i*f);
            end
            
            if nargout ==1
                varargout{1} = f;
            elseif nargout == 2
                varargout{1} = f;
                varargout{2} = H;
            end
            
        end
        
        function varargout=plot(obj,varargin)
            %PLOT   Plot the serdes.CTLE transfer function magnitude and
            %phase response from 0 to 4 times the baud rate of the system
            %as defined by SymbolTime and Modulation.
            %
            %plot(serdes.CTLE) plots the transfer function family to the
            %current figure.
            %
            %[f,H]=plot(serdes.CTLE) returns the transfer function family,
            %H, and the frequency vector f.
            %
            %plot(serdes.CTLE,fhandle) plots the transfer function family
            %to the figure defined by fhandle.
            %
            %plot(serdes.CTLE,fhandle,f) plots or returns the transfer
            %function family at the frequency points defined by f in Hz.
            
            if nargin==3
                [f,H]=response(obj,varargin{2});
            else
                [f,H]=response(obj);
            end
            
            if nargout==0
                
                if nargin>=2 && ~isempty(ishandle(varargin{1})) && ...
                        ishandle(varargin{1}) && strcmp(get(varargin{1}, 'type'), 'figure')
                    figure(varargin{1})
                end
                
                nconfigs = obj.ConfigCount;
                
                subplot(211)
                semilogx(f,serdes.utilities.db(H))
                xlabel('Hz'),ylabel('dB')
                legend(cellstr(num2str((0:nconfigs-1)')))
                grid on
                title(getString(message('serdes:serdessystem:CTLEPlotTitle',obj.SliceSelect)))
                subplot(212)
                semilogx(f,unwrap(angle(H),[],2))
                xlabel('Hz'),ylabel('radians')
                legend(cellstr(num2str((0:nconfigs-1)')))
                grid on
            elseif nargout ==1
                varargout{1} = f;
            elseif nargout == 2
                varargout{1} = f;
                varargout{2} = H;
            end
        end

        function varargout = print(obj)
            %Print out gain, poles, zeros for the CTLE transfer function
            %specified by ConfigSelect
            
            narginchk(1,1)
            nargoutchk(0,1)
            
            %Retrieve Gain, Pole, Zero values
            [G,P,Z]=getGPZ(obj);
            
            %Determine 1 based index
            index = obj.ConfigSelect + 1;
            
            %Extract out selected config
            g1 = G(index);
            p1 = P(index,:);
            z1 = Z(index,:);
            
            %remove any zero padding
            pgoodNdx = p1~=0;
            zgoodNdx = z1~=0;
            p = p1(pgoodNdx);
            z = z1(zgoodNdx);
            
            %Print out report
            reportOut = cell(3+length(p)+length(z)+1,1);
            reportOut{1} = sprintf('For SliceSelect = %i & ConfigSelect = %i',obj.SliceSelect,obj.ConfigSelect);
            reportOut{2} = sprintf('Gain: %g V/V or %g dB',g1,20*log10(abs(g1)));
            reportOut{3} = sprintf('Zeros:');
            jj = 4;
            for ii = 1:length(z)
                reportOut{jj} = sprintf('    %g GHz = | %g + %gi |*1e9',sign(real(z(ii)))*abs(z(ii))*1e-9,real(z(ii)*1e-9),imag(z(ii)*1e-9));
                jj = jj+1;
            end
            reportOut{jj} = sprintf('Poles:');
            jj = jj+1;
            for ii = 1:length(p)
                reportOut{jj} = sprintf('    %g GHz = | %g + %gi |*1e9',sign(real(p(ii)))*abs(p(ii))*1e-9,real(p(ii)*1e-9),imag(p(ii)*1e-9));
                jj = jj+1;
            end
            
            if nargout==0
                for ii = 1:length(reportOut)
                    fprintf('%s\n',reportOut{ii});
                end
            else
                varargout{1} = reportOut;
            end
        end
    end
    
    methods (Hidden)
        function [G,P,Z]=getGPZ(obj)
            %getGPZ     return gain, pole and zeros.  Gain in units of magnitude.
           
            if ~obj.isUpToDate
                %Update
                processTunedPropertiesImpl(obj)
            end
            
            if strcmpi(obj.Specification,'DC Gain and Peaking Gain')
                %Inputs are validated in setters
                [G1,P,Z] = serdes.utilities.poleZeroDefine('PeakingFrequency',obj.PeakingFrequency...
                    ,'DCGain',obj.DCGain ...
                    ,'PeakingGain',obj.PeakingGain);
                G = 10.^(G1/20);
            elseif strcmpi(obj.Specification,'DC Gain and AC Gain')
                %Inputs are validated in setters
                [G1,P,Z] = serdes.utilities.poleZeroDefine('PeakingFrequency',obj.PeakingFrequency...
                    ,'DCGain',obj.DCGain ...
                    ,'ACGain',obj.ACGain);
                G = 10.^(G1/20);
            elseif strcmpi(obj.Specification,'AC Gain and Peaking Gain')
                %Inputs are validated in setters
                [G1,P,Z] = serdes.utilities.poleZeroDefine('PeakingFrequency',obj.PeakingFrequency...
                    ,'ACGain',obj.ACGain ...
                    ,'PeakingGain',obj.PeakingGain);
                G = 10.^(G1/20);
            else %if strcmpi(obj.Specification,'GPZ Matrix')
                %Inputs are validated in setter
                nconfig = obj.ConfigCount;
                G = 10.^(real(obj.GPZ(1:nconfig,1,      obj.SliceSelect+1))/20);
                P =           obj.GPZ(1:nconfig,2:2:end,obj.SliceSelect+1);
                Z =           obj.GPZ(1:nconfig,3:2:end,obj.SliceSelect+1);
            end
        end
    end
    methods (Access = protected, Hidden)
        function secondarySetter(obj)
            notUpToDate(obj);
        end
        
        function notUpToDate(obj)
            obj.isUpToDate = false;
        end
        
        function validateConfig(obj,val)
            coder.internal.errorIf(...
                ~isnumeric(val) || ~isscalar(val) || val ~= round(val) || val < 0 || val > obj.ConfigCount-1, ...
                'serdes:serdessystem:ConfigNotValid',...
                obj.SliceSelect,'ConfigSelect',obj.ConfigCount-1);
        end
        function validateSlice(obj,val)
            validateattributes(val,{'numeric'},...
                {'scalar','integer','>=',0,'<=',obj.SliceCount-1},...
                '','SliceSelect');        
        end
        
        function calculateFilterCoefficients(obj)
            
            obj.isUpToDate = true;
            
            %Retrieve Gain, Pole, Zero values
            [G,P,Z]=getGPZ(obj);
               
            %Validate Zeros, Poles and Gains
            serdes.CTLE.validateGPZ(G, P, Z, obj.SliceSelect);
            
            %Repeated pole/zero checks that couldn't be done inside the
            %static method validateGPZ
            repeatedPoleZeroCheck(obj,G, P, Z, sum(P~=0,2), sum(Z~=0,2));
            
            %Ensure that aspect ratio between sample interval and smallest
            %Pole/Zero is acceptable.
            ptmp = P(P~=0);
            ztmp = Z(Z~=0);
            minpz = min(abs([ptmp(:);ztmp(:)]));
            fundamentalFrequency = 1/obj.SymbolTime/2;
            
            if ~isCascaded(obj) && (minpz < fundamentalFrequency/10000)
                %Warn if a pole/zero is too small as it can cause
                %downstream errors.
                coder.internal.warning('serdes:serdessystem:PoleZeroTooSmall',...
                    round(minpz),round(fundamentalFrequency/minpz),round(fundamentalFrequency));
            end
                        
            %Both Cascaded and PartialFilter filter coefficients need to be
            %initialized for code generation reasons.            
            
            %Form input structure
            dat.info.nz = sum(Z~=0,2);
            dat.info.np = sum(P~=0,2);
            dat.info.maxpoles = max(sum(P~=0,2));
            dat.info.nconfig = length(G);
            dat.z = Z;
            dat.p = P;
            dat.DCg = G;
            
            if ~isCascaded(obj)
                fc = serdes.utilities.calculateCTLECoefficients(obj.SampleInterval,dat);
                
                %Save Coefficients to CTLE Object Property
                obj.FilterCoefficients = fc;
            else
                maxpoles = dat.info.maxpoles;
                nconfig = dat.info.nconfig;                

                fc.inCoeff  = zeros(maxpoles+1,nconfig);
                fc.outCoeff = zeros(maxpoles,nconfig);
                fc.inDelay  = zeros(maxpoles+1,1);
                fc.outDelay = zeros(maxpoles,1);
                fc.nz = dat.info.nz;
                fc.np = dat.info.np;
                fc.dt = obj.SampleInterval;
                fc.setSelection = 1;
                fc.isdefined = false;
                
                obj.FilterCoefficients = fc;
            end
            
            calculateCascaded(obj,G,P,Z);

        end
        function calculateCascaded(obj,G,P,Z)
            nConfig = length(G);
            nFamilies = 1; %Reserved for future use
            maxPoleCount = size(P,2);
            maxsections = ceil(maxPoleCount/2);
            maxstates = maxsections + 1;
            
            obj.FilterStates           = zeros(maxstates,5,nConfig,nFamilies);
            obj.FilterStatesCount      = zeros(nConfig,nFamilies);
            obj.FilterNumerator        = zeros(maxsections,5,nConfig,nFamilies);
            obj.FilterNumeratorCount   = zeros(nConfig,nFamilies);
            obj.FilterDenominator      = zeros(maxsections,4,nConfig,nFamilies);
            obj.FilterDenominatorCount = zeros(nConfig,nFamilies);
            obj.FilterGain             = zeros(nFamilies,nConfig);
            
            for ii = 1:nConfig
                p = P(ii,P(ii,:)~=0)*2*pi; %select the non-zero poles
                z = Z(ii,Z(ii,:)~=0)*2*pi; %select the non-zero zeros
                filtersos = serdes.internal.laplace2fos( p(:), z(:), obj.SampleInterval  );
                ns = size(filtersos,1)+1; %number of states
                obj.FilterNumerator(1:ns-1,:,ii,1)   = filtersos(:,1:5);
                obj.FilterNumeratorCount(ii,1)       = ns-1;
                obj.FilterDenominator(1:ns-1,:,ii,1) = filtersos(:,7:10);
                obj.FilterDenominatorCount(ii,1)     = ns-1;
                obj.FilterGain(1,ii)                 = G(ii);
                obj.FilterStatesCount(ii,1)          = ns;
            end
        end
        function waveOut = applyCascaded(obj,waveIn,Index)
            %Apply Cascaded Filter
            
            waveOut = coder.nullcopy(waveIn);
            
            %Create local variables to reduce overhead of property access
            localFilterStates = squeeze(obj.FilterStates(1:obj.FilterStatesCount(Index,1),:,Index,1));
            localNumerator = obj.FilterNumerator(1:obj.FilterNumeratorCount(Index,1),:,Index,1);
            localDenominator = obj.FilterDenominator(1:obj.FilterDenominatorCount(Index,1),:,Index,1);
            for ii = 1:length(waveIn)
                [waveOut(ii),localFilterStates] = serdes.internal.stepFilter(...
                    waveIn(ii),localNumerator,localDenominator,localFilterStates);
            end
            waveOut = waveOut*obj.FilterGain(1,Index);            
            obj.FilterStates(1:obj.FilterStatesCount(Index,1),:,Index,1) = localFilterStates;
        end
        function repeatedPoleZeroCheck(obj,G, P, Z, np, nz)
            %Repeated pole/zero checks that couldn't be done inside the
            %static method validateGPZ
            
            if ~isCascaded(obj)
                %If repeated pole/zeros are identified or there are no
                %poles, then warning is issued and FilterMethod is changed
                %to Cascaded
                
                N = length(G); %Number of transfer functions in family
                for ii = 1:N %Loop over each transfer function family
                    ptmp = P(ii,1:np(ii));
                    %Repeat test: Eliminate conjugate pairs, sort vector, take
                    %difference of sequential entries and if there are not
                    %repeats then the difference should not be zero.
                    repeatPoleTest = any(diff(sort(ptmp(imag(ptmp)>=0)))==0);
                    if repeatPoleTest || isempty(ptmp)
                        obj.pFilterMethod = true; %Cascaded
                        coder.internal.warning('serdes:serdessystem:RepeatsDetectedSwitchToCascade','Poles');
                        return
                    end
                end
                
                for ii = 1:N %Loop over each transfer function family
                    ztmp = Z(ii,1:nz(ii));
                    repeatZeroTest = any(diff(sort(ztmp(imag(ztmp)>=0)))==0);
                    if repeatZeroTest
                        obj.pFilterMethod = true; %Cascaded
                        coder.internal.warning('serdes:serdessystem:RepeatsDetectedSwitchToCascade','Zeros');
                        return
                    end
                end
            end
        end
        function val = isCascaded(obj)
            val = obj.pFilterMethod==1;
        end
        function val = modeIsOff(obj)
            val = obj.Mode==double(0);
        end
        function val = modeIsFixed(obj)
            val = obj.Mode==double(1);
        end
        function val = modeIsAdapt(obj)
            val = obj.Mode==double(2);
        end
        function val = isImpulse(obj)
            val = strcmpi(obj.WaveType,'Impulse');
        end
        function val = isWaveform(obj)
            val = strcmpi(obj.WaveType,'Waveform');
        end
        function val = isSample(obj)
            val = strcmpi(obj.WaveType,'Sample');
        end
        
        function val = PulseGoodness(obj,pulse,SamplesPerSymbol)
            %PulseGoodness  Quantify the performance of a pulse response
                        
            if isnan(obj.MetricBER)
                localMetricBER = 1e-6;
            elseif isinf(obj.MetricBER)
                localMetricBER = 0;
            else
                localMetricBER = obj.MetricBER;
            end
            
            metric = optPulseMetric(pulse,SamplesPerSymbol,obj.SampleInterval,localMetricBER);
            val = metric.(obj.PerformanceCriteria);
        end
    end
    
    methods(Access = protected)
        function validateInputsImpl(obj,waveIn)
            validateattributes(waveIn,{'numeric'},{'finite'},'','waveIn');
            
            if isImpulse(obj)
                %Validate Impulse Response
                validateattributes(waveIn,{'numeric'},{'2d'},'','waveIn')
                %Ensure non-zero
                validateattributes(sum(abs(waveIn)),{'numeric'},{},'','waveIn')
            end
        end
        
        function processTunedPropertiesImpl(obj)
            validateConfig(obj,obj.ConfigSelect)
        end
        
        function setupImpl(obj)
            
            %Assign private FilterMethod. This property is necessary so if
            %using PartialFraction method and have repeated poles/zeros the
            %block can automatically change to Cascaded.
            obj.pFilterMethod = strcmpi(obj.FilterMethod,'Cascaded');
            
            %Validate Slice Select
            validateSlice(obj,obj.SliceSelect);

            %validate ConfigSelect
            validateConfig(obj,obj.ConfigSelect);

            %Calculate discrete filters:
            calculateFilterCoefficients(obj);
        end
        
        function [waveOut, Config, varargout] = stepImpl(obj,waveIn)
            %[waveOut, Config] = stepImpl(obj,waveIn)
            %
            % To enable the OptMetric output, set the OutputOptMetric
            % property to true.
            %[waveOut, Config, OptMetric] = stepImpl(obj,waveIn)

            if isSample(obj) && (modeIsFixed(obj) || modeIsAdapt(obj))
                %Note that step or time domain adaptation of the CTLE must be
                %done in an exterior block.
                
                if modeIsFixed(obj)
                    Config = obj.ConfigSelect;
                else
                    if obj.privConfigInitialFlag
                        obj.privConfigInitial = obj.ConfigSelect;
                        obj.privConfigInitialFlag = false;
                    else
                        obj.privConfigInitial = obj.ConfigSelect;
                    end
                    Config = obj.privConfigInitial;
                end
                
                %Filter waveform
                if isCascaded(obj)                    
                    waveOut = applyCascaded(obj,waveIn,Config+1);
                else
                    psel = 1:obj.FilterCoefficients.np(Config+1)+1;
                    rsel = 1:obj.FilterCoefficients.np(Config+1);
                    inCoeff = obj.FilterCoefficients.inCoeff(psel,Config+1);
                    outCoeff= obj.FilterCoefficients.outCoeff(rsel,Config+1);
                    
                    inDelay = obj.FilterCoefficients.inDelay(psel);
                    outDelay = obj.FilterCoefficients.outDelay(rsel);
                    
                    [waveOut, inDelay, outDelay]=applyLinearFilter(waveIn, inDelay, outDelay, inCoeff, outCoeff );
                    
                    obj.FilterCoefficients.inDelay(psel)  = inDelay;
                    obj.FilterCoefficients.outDelay(rsel) = outDelay;
                end

                %Optimization metric not calculated in sample-by-sample
                %mode
                OptMetric = -1; 
            elseif modeIsOff(obj)
                waveOut = waveIn;
                Config = obj.ConfigSelect;
                OptMetric = -1;
            else %(isImpulse(obj) || isWaveform(obj))
                
                %Validate waveIn to ensure it is a column matrix.
                [nrows,ncol]=size(waveIn);
                coder.internal.errorIf(nrows<ncol, 'serdes:serdessystem:ImpulseWaveShouldBeColumnMatrix');
                
                SamplesPerSymbol = round(obj.SymbolTime/obj.SampleInterval);

                %Determine config
                if modeIsAdapt(obj)
                                        
                    if isImpulse(obj)
                        %1)convert impulse to pulse
                        wavetmp1 = impulse2pulse(waveIn(:,1), SamplesPerSymbol, obj.SampleInterval);
                        
                        %pulseRecoverClock does an excellent job of validating
                        %pulse response.
                        pulseRecoverClock( wavetmp1, SamplesPerSymbol );
                        
                        %shorten the pulse response to improve
                        %computational efficiency since CTLE doesn't
                        %address long tail ISI very well.
                        pct = 0.0001;
                        penergy = cumsum(wavetmp1.^2); %Create monotonic signal
                        penergy1 = penergy/penergy(end);
                        test1 = (penergy1>pct/2)&(penergy1<1-pct/2);
                        
                        %Ensure that the shortened pulse has at least 3 UI
                        %prior to cursor and 3 UI after cursor.
                        [~,mxndx] = max(abs(wavetmp1));
                        startndx = max([1,mxndx-SamplesPerSymbol*3]);
                        endndx = min([numel(wavetmp1),mxndx+SamplesPerSymbol*3]);
                        test2 = false(size(wavetmp1));
                        test2(startndx:endndx)=true;
                        wavetmp = wavetmp1(test1|test2);
                    else %if isWaveform(obj)
                        wavetmp = waveIn(:,1);
                    end
                    
                    %2)Through exhaustive search optimize the goodness function                        
                    goodness = zeros(1,obj.ConfigCount);
                    
                    for configCanidate = 1:obj.ConfigCount
                        %Apply filter waveform, calculate goodness
                        
                        %LTI adaptation application of CTLE filter
                        if isCascaded(obj)
                            %Clear any prior state information
                            obj.FilterStates = obj.FilterStates*0;
                            %Apply filter
                            wavetmp3 = applyCascaded(obj,[wavetmp;wavetmp],configCanidate);
                            wavetmp2 = wavetmp3(length(wavetmp)+1:end);
                        else
                            psel = 1:obj.FilterCoefficients.np(configCanidate)+1;
                            rsel = 1:obj.FilterCoefficients.np(configCanidate);
                            inCoeff = obj.FilterCoefficients.inCoeff(psel,configCanidate);
                            outCoeff= obj.FilterCoefficients.outCoeff(rsel,configCanidate);
                            
                            inDelay = obj.FilterCoefficients.inDelay(psel)*0;
                            outDelay = obj.FilterCoefficients.outDelay(rsel)*0;
                            
                            %Apply to pulse twice to avoid start up issues
                            [wavetmp3, ~,~]=applyLinearFilter([wavetmp;wavetmp], inDelay, outDelay, inCoeff, outCoeff );
                            wavetmp2 = wavetmp3(length(wavetmp)+1:end);
                        end
                        
                        if isImpulse(obj)
                            %Note wavetmp2 is a pulse response
                            goodness(configCanidate) = PulseGoodness(obj,wavetmp2,SamplesPerSymbol);
                            
                        else %isWaveform(obj)
                            goodness(configCanidate) = serdes.utilities.WaveEyeHeight(wavetmp2,SamplesPerSymbol);
                        end
                    end
                    
                    %3) Select best config
                    [~,Config]=max(goodness);
                    Config = Config-1; %-1 is to transform to 0 based indexing
                    
                else %if modeIsFixed(obj)
                    Config = obj.ConfigSelect;
                end
                
                %Apply CTLE config to waveform
                psel = 1:obj.FilterCoefficients.np(Config+1)+1;
                rsel = 1:obj.FilterCoefficients.np(Config+1);
                inCoeff = obj.FilterCoefficients.inCoeff(psel,Config+1);
                outCoeff= obj.FilterCoefficients.outCoeff(rsel,Config+1);
                
                waveOut = coder.nullcopy(waveIn);
                
                for ii = 1:ncol
                    %In order to apply the filter to the complete waveform.  We
                    %assume that the stimulus signal is circulant (i.e. the
                    %signal is continuous if we wrap it around with circshift).
                    %We therefore apply the filter to two repetitions of the
                    %stimulus and discard the first part.
                    
                    w = waveIn(:,ii);
                    
                    if isCascaded(obj)
                        %Clear any prior state information
                        obj.FilterStates = obj.FilterStates*0;
                        %Apply filter
                        w2 = applyCascaded(obj,[w;w],Config+1);
                    else
                        %Clear any prior state information
                        inDelay = obj.FilterCoefficients.inDelay(psel)*0;
                        outDelay = obj.FilterCoefficients.outDelay(rsel)*0;
                        %Apply filter
                        w2 = applyLinearFilter([w;w], inDelay, outDelay, inCoeff, outCoeff );
                    end
                    waveOut(:,ii) = w2(length(w)+1:end);
                end
                
                %Calculate pulse optimization metric. Note that this is
                %slightly different from above where the input impulse
                %response is converted to a pulse response, filtered with
                %the CTLE and then the metric is calculated, whereas here
                %we take the filtered impulse response, convert it to a
                %pulse and then calculate the metric. In general this
                %should result in the same results but for numerically
                %unstable situations, differences could emerge.
                wavetmp1 = impulse2pulse(waveOut(:,1), SamplesPerSymbol, obj.SampleInterval);
                OptMetric = PulseGoodness(obj,wavetmp1,SamplesPerSymbol);
            end

            if nargout==3
                varargout{1} = OptMetric;
            end
        end
        
        function resetImpl(obj)
            % Initialize / reset discrete-state properties
            
            obj.FilterCoefficients.inDelay = obj.FilterCoefficients.inDelay*0;
            obj.FilterCoefficients.outDelay = obj.FilterCoefficients.outDelay*0;
            obj.FilterStates = obj.FilterStates*0;
        end
        
        %% Simulink functions
        function icon = getIconImpl(~)
            % Define icon for System block
            icon = "CTLE";
        end
                
        function plotButton(obj,actionData)
            ud = actionData.UserData;
            if isempty(ud) || ~isfield(ud,'f') || ~ishandle(ud.f)
                ud.f = figure;
                actionData.UserData = ud;
            else
                figure(ud.f);
            end
            
            plot(obj,ud.f)
        end
    end
    methods (Hidden)
        function fitterButton(~,block,wsSymbolTime)
            blockHandle = getSimulinkBlockHandle(block); %get handle of block
            mdlWks = get_param(bdroot(blockHandle),'ModelWorkspace');
            blockGPZ = get_param(blockHandle,'GPZ');
            % Check model workspace for previous CTLE fits
            if ~hasVariable(mdlWks,'CTLEFitData')
                %Initialize to default
                CTLEFitLocal = ctlefit;
            else % Found CTLE fit array
                CTLEFitData = mdlWks.getVariable('CTLEFitData');
                % Find correct fit data by gpz variable name.  Confirm mask edit field contains 
                % name string (str2num returns empty) and then check model workspace for variable
                if isempty(str2num(blockGPZ,Evaluation="restricted")) && ...
                        mdlWks.hasVariable(blockGPZ) %#ok<ST2NM,EMS2N>
                    CTLEFitIdx = find(strcmp({CTLEFitData.GPZName}, blockGPZ)==1);
                else
                    CTLEFitIdx = '';
                end
                if any(CTLEFitIdx)
                    %Get prior CTLEFit object                    
                    CTLEFitLocal = CTLEFitData(CTLEFitIdx).CTLEFitObj;
                else
                    %Initialize to default
                    CTLEFitLocal = ctlefit;
                end
            end
            % Setup fit object
            CTLEFitLocal.pSymbolTime = wsSymbolTime*1e12;
            CTLEFitLocal.pSliceSelect = str2double(get_param(blockHandle,'SliceSelect'));
            CTLEFitLocal.pPriorGPZ = slResolve(blockGPZ, bdroot(blockHandle));
            % Call CTLE Fitter App. Pass 1) CTLEFit object, 2) block handle                      
            ctlefitter(CTLEFitLocal,blockHandle);
            % When App closes, it stores the CTLEFit object in the model
            % workspace and sets the block GPZ.
        end
    end
    
    methods(Static, Access=protected)
        function group = getPropertyGroupsImpl(~)
            % Define property section(s) for System block dialog
            Actions = [matlab.system.display.Action(@(actionData,obj) ...
                        plotButton(obj,actionData),'Label','Visualize Response'),...
                       matlab.system.display.Action(@(actionData,obj) ...
                        fitterButton(obj,gcb,obj.SymbolTime),'Label','CTLE Fitter App')];

            mainGroup = matlab.system.display.SectionGroup(...
                'Title','Main',...
                'PropertyList',{'ModePort','Mode',...
                'Specification','PeakingFrequency',...
                'DCGain','ACGain','PeakingGain','GPZ',...
                'SliceSelectPort','SliceSelect',...
                'ConfigSelectPort','ConfigSelect'},...
                'Actions',Actions);
            
            advancedGroup = matlab.system.display.SectionGroup(...
                'Title','Advanced',...
                'PropertyList',{'SymbolTime','SampleInterval','WaveType',...
                'PerformanceCriteria','OutputOptMetric','FilterMethod'});
            group = [mainGroup,advancedGroup];
        end
    end
    methods(Static, Hidden)
        function validateGPZ(G, P, Z, sndx)
            %validateGPZ(G, P, Z, sndx) where G is the Gain, P are
            %the Poles, Z are Zeros, sndx is the slice index used in
            %creating useful error messages.           

            %Gain Validation: Any numeric non-empty finite and real vector.
            coder.internal.errorIf(...
                ~isnumeric(G) || ~isvector(G) || isempty(G) || ~all(isfinite(G)) || ~all(isreal(G)), ...
                'serdes:serdessystem:GainNotValid',sndx);
            N = length(G);
            
            %Pole Validation
            coder.internal.errorIf(...
                ~isnumeric(P) || ~ismatrix(P) || isempty(P) || ~all(isfinite(P(:))), ...
                'serdes:serdessystem:PoleOrZeroNotValid','Pole',sndx);
            %Complex entries must have conjugate
            for ii = 1:N
                ptmp = P(ii,P(ii,:)~=0);
                %Conjugate test: If there are conjugate pairs, then taking
                %the conjugate of the vector will result in the same vector.
                conjugatePoleTest = isequal(sort(ptmp),sort(conj(ptmp)));
                coder.internal.errorIf(~conjugatePoleTest, 'serdes:serdessystem:MustHaveConjugatePair',sndx,'Pole');
            end
            
            %Zero Validation
            coder.internal.errorIf(...
                ~isnumeric(Z) || ~ismatrix(Z) || isempty(Z) || ~all(isfinite(Z(:))), ...
                'serdes:serdessystem:PoleOrZeroNotValid','Zero',sndx);            
            %Complex entries must have conjugate
            for ii = 1:N
                ztmp = Z(ii,Z(ii,:)~=0);
                conjugateZeroTest = isequal(sort(ztmp),sort(conj(ztmp)));
                coder.internal.errorIf(~conjugateZeroTest, 'serdes:serdessystem:MustHaveConjugatePair',sndx,'Zero');
            end
            
            %More poles than zeros are required for stable filters. The
            %exception is when there are no poles and no zeros.  
            np = sum(P~=0,2);
            nz = sum(Z~=0,2);
            MorePolesThanZeroTest = ~all(np>nz | np==0);
            coder.internal.errorIf(MorePolesThanZeroTest, 'serdes:serdessystem:MorePolesThanZero',sndx);

        end
        function p = cprod(v)
            %cprod  complex product
            %   Take the product of the terms of a complex vector where care is taken
            %   to ensure that complex conjugate terms are first multiplied together.
            
            %Sort into complex pairs
            v1 = cplxpair(v);
            
            m = length(v1);
            m1 = ceil(m/2);
            
            %Arrange into 2D matrix
            v2 = ones(2,m1);
            v2(1:m) = v1;
            
            %First multiply the conjugates together and then everything else.
            p = prod(prod(v2,1));
        end
    end
    methods(Static)
        function gpz = CombineSlices(varargin)
            %COMBINESLICES  Concatenates together GPZ matrices
            %   gpz = CombineSlices(gpz1,gpz2) zero pads and concatenates         
            %   together in the 3rd dimension gpz1 and gpz2.  gpz1 and gpz2 
            %   can be 2-D or 3-D Gain-Pole-Zero matrices.
            %
            %   gpz = CombineSlices(gpzCell) zero pads and concatenates
            %   together in the 3rd dimension the GPZ matrices
            %   contained in the cell array 'gpzCell';

            %Validate input GPZs
            narginchk(1,2)
            nargoutchk(0,1)

            if nargin==2
                gpz1 = varargin{1};
                gpz2 = varargin{2};
                validateattributes(gpz1,{'numeric'},{'3d','finite','nonempty'},'','gpz1');
                validateattributes(gpz2,{'numeric'},{'3d','finite','nonempty'},'','gpz2');

                %Determine size of inputs
                gpz1size = size(gpz1,1,2,3);
                gpz2size = size(gpz2,1,2,3);

                %Validate gpz1
                for ii = 1:gpz1size(3)
                    %Loop over each GPZ slice and validate it.
                    G = real(gpz1(:,1,ii));
                    P = gpz1(:,2:2:end,ii);
                    Z = gpz1(:,3:2:end,ii);
                    serdes.CTLE.validateGPZ(G,P,Z,ii-1);
                end

                %Validate gpz2
                for jj = 1:gpz2size(3)
                    G = real(gpz2(:,1,jj));
                    P = gpz2(:,2:2:end,jj);
                    Z = gpz2(:,3:2:end,jj);
                    serdes.CTLE.validateGPZ(G,P,Z,ii+jj-1);
                end

                %Determine size of output gpz
                gpzOutsize = [max([gpz1size(1:2);gpz2size(1:2)],[],1),gpz1size(3)+gpz2size(3)];

                %Initialize and populate output gpz
                gpz = zeros(gpzOutsize);
                gpz(1:gpz1size(1),1:gpz1size(2),1:gpz1size(3))       = gpz1;
                gpz(1:gpz2size(1),1:gpz2size(2),  gpz1size(3)+1:end) = gpz2;
            else
                %Cell Input
                gpzcell = varargin{1};

                %Validate input
                validateattributes(gpzcell,{'cell'},{},'CombineSlices','gpzCell',1);                
                N = length(gpzcell);

                %Validate each entry in gpzcell
                nrows = zeros(1,N);
                ncols = zeros(1,N);
                nslices = zeros(1,N);
                cnt = 0;
                for ii = 1:N
                    cnt = cnt + 1;                    
                    validateattributes(gpzcell{ii},{'numeric'},{'3d'},'CombineSlices',...
                        sprintf('gpzCell{%i}',ii),1);

                    %Courtesy CTLE validation
                    for jj = 1:size(gpzcell{ii},3)
                        cnt = cnt + 1;
                        G = gpzcell{ii}(:,1,jj);
                        P = gpzcell{ii}(:,2:2:end,jj);
                        Z = gpzcell{ii}(:,3:2:end,jj);
                        serdes.CTLE.validateGPZ(G,P,Z,cnt-1);
                    end

                    nrows(ii) = size(gpzcell{ii},1);
                    ncols(ii) = size(gpzcell{ii},2);
                    nslices(ii) = size(gpzcell{ii},3);
                end                                

                %Initialize and populate output gpz
                gpz = zeros(max(nrows),max(ncols),sum(nslices));
                for ii = 1:N
                    s1 = sum(nslices(1:ii-1))+1;
                    s2 = sum(nslices(1:ii));
                    gpz(1:nrows(ii),1:ncols(ii),s1:s2) = gpzcell{ii};
                end                
            end
        end
        function gpz = GainPoleZeroToGPZ(G,P,Z)
            % GAINPOLEZEROTOGPZ     Convert separate gain, pole, zero variables into GPZ matrix            
            %   gpz = GainPoleZerotoGPZ(G,P,Z) helps the user convert G, P
            %   and Z representing the gain, poles and zeros of a CTLE
            %   family and returns a GPZ matrix for use in the serdes.CTLE
            %   system object.  G is a numeric vector.  P is either a
            %   numeric matrix or a cell of numeric vectors and Z is either
            %   a numeric matrix or a cell of numeric vectors.
            %
            %   %Example of matrix input
            %       G = [0;-1;-2];
            %       P = [-23771428571,-13092857142,0;...
            %            -17603571428,-13344642857,0;...
            %            -17935714285,-13596428571,-15321428571];
            %       Z = [-10492857142;-7914982142;-6845464285];
            %       gpz = serdes.CTLE.GainPoleZeroToGPZ(G,P,Z);
            % 
            %   %Example of cell input
            %       G = [0;-1;-2];
            %       P = {[-23771428571,-13092857142];...
            %            [-17603571428,-13344642857];...
            %            [-17935714285,-13596428571,-15321428571]};
            %       Z = {-10492857142;-7914982142;-6845464285};
            %       gpz = serdes.CTLE.GainPoleZeroToGPZ(G,P,Z);

            %Validate Inputs
            narginchk(3,3)
            nargoutchk(0,1)
            validateattributes(G,{'numeric'},{'vector','finite','nonempty','real'},'GainPoleZerotoGPZ','G');
            validateattributes(P,{'numeric','cell'},{},'GainPoleZerotoGPZ','P');
            validateattributes(Z,{'numeric','cell'},{},'GainPoleZerotoGPZ','Z');

            %If P or Z input is cell, convert to matrix version for validation.
            N = size(G,1);
            if iscell(P)
                %Validate length of cell
                coder.internal.errorIf(N ~= length(P),...
                    'The number of elements in G and P must agree in order to form them into a GPZ Matrix.');

                %Validate contents of P
                cellLength = zeros(1,N);
                for ii = 1:N
                    %Validate that each element of P is a numeric vector
                    pval = P{ii};
                    coder.internal.errorIf(~isnumeric(pval)|| ~ismatrix(pval),...
                        'Each element of P is expected to be a numeric vector');
                    cellLength(ii) = length(pval);
                end
                %Copy cell array to P matrix
                Ptmp = zeros(N,max(cellLength));
                for ii = 1:N
                    Ptmp(ii,1:cellLength(ii)) = P{ii};
                end
                P = Ptmp;
            end

            if iscell(Z)
                %Validate length of cell
                coder.internal.errorIf(N ~= length(Z),...
                    'The number of elements in G and Z must agree in order to form them into a GPZ Matrix.');

                %Validate contents of Z
                cellLength = zeros(1,N);
                for ii = 1:N
                    %Validate that each element of P is a numeric vector
                    zval = Z{ii};
                    coder.internal.errorIf(~isnumeric(zval)|| ~ismatrix(zval),...
                        'Each element of P is expected to be a numeric vector');
                    cellLength(ii) = length(zval);
                end
                %Copy cell array to Z matrix
                Ztmp = zeros(N,max(cellLength));
                for ii = 1:N
                    Ztmp(ii,1:cellLength(ii)) = Z{ii};
                end
                Z = Ztmp;
            end

            validateattributes(P,{'numeric'},{'2d','finite','nonempty'},'GainPoleZerotoGPZ','P');
            validateattributes(Z,{'numeric'},{'2d','finite','nonempty'},'GainPoleZerotoGPZ','Z');

            %Ensure each of G, P and Z have the same number of rows
            coder.internal.errorIf(N ~= size(P,1) || N ~= size(Z,1), ...
                'The number of rows in G, P and Z must agree in order to form them into a GPZ Matrix.');

            %Courtesy validation
            serdes.CTLE.validateGPZ(G,P,Z,0);

            %Form gpz
            gpz = zeros(N,size(P,2)*2);
            gpz(:,1) = G;
            gpz(:,2:2:end) = P;
            gpz(:,3:2:size(Z,2)*2+1) = Z;
        end
    end
    methods (Access=protected)
        %Enable Optional Output
        function num = getNumOutputsImpl(obj)
            if obj.OutputOptMetric == true
                num = 3;
            else
                num = 2;
            end
        end
        function varargout = getOutputNamesImpl(obj)
            varargout{1} = 'Out';
            varargout{2} = 'ConfigSelect';
            if obj.OutputOptMetric == true
                varargout{3} = 'OptMetric';
            end
        end
        
        function flag = isInactivePropertyImpl(obj, prop)
            flag = false;
            switch prop
                case {'DCGain'}
                    if ~(strcmpi(obj.Specification,'DC Gain and Peaking Gain') || ...
                            strcmpi(obj.Specification,'DC Gain and AC Gain'))
                        flag = true;
                    end
                case {'ACGain'}
                    if ~(strcmpi(obj.Specification,'DC Gain and AC Gain') || ...
                            strcmpi(obj.Specification,'AC Gain and Peaking Gain'))
                        flag = true;
                    end
                case {'PeakingGain'}
                    if ~(strcmpi(obj.Specification,'DC Gain and Peaking Gain') || ...
                            strcmpi(obj.Specification,'AC Gain and Peaking Gain'))
                        flag = true;
                    end
                case {'GPZ'}
                    if ~strcmpi(obj.Specification,'GPZ Matrix')
                        flag = true;
                    end
                case {'PeakingFrequency'}
                    if strcmpi(obj.Specification,'GPZ Matrix')
                        flag = true;
                    end
                otherwise
            end
        end
        
        function name = getInputNamesImpl(~)
            name = 'In';
        end
        
        %% Backup/restore functions
        function s = saveObjectImpl(obj)
            % Set properties in structure s to values in object obj
            
            % Set public properties and states
            s = saveObjectImpl@matlab.System(obj);
            
            % Set private and protected properties
            s.privConfigInitial = obj.privConfigInitial;
            s.privConfigInitialFlag = obj.privConfigInitialFlag;
            s.FilterCoefficients = obj.FilterCoefficients;
            s.ConfigCount = obj.ConfigCount;
            s.FilterStates = obj.FilterStates;
            s.FilterNumerator = obj.FilterNumerator;
            s.FilterDenominator = obj.FilterDenominator;
            s.FilterGain = obj.FilterGain;
            s.pFilterMethod = obj.pFilterMethod;            
            s.FilterNumeratorCount = obj.FilterNumeratorCount;
            s.FilterDenominatorCount = obj.FilterDenominatorCount;
            s.FilterStatesCount = obj.FilterStatesCount;

            s.SliceCount = obj.SliceCount;
            s.OutputOptMetric = obj.OutputOptMetric;
        end
        
        function loadObjectImpl(obj,s,wasLocked)
            % Set properties in object obj to values in structure s
            
            % Set private and protected properties
            obj.privConfigInitial = s.privConfigInitial;
            obj.privConfigInitialFlag = s.privConfigInitialFlag;
            obj.FilterCoefficients = s.FilterCoefficients;
            obj.ConfigCount = s.ConfigCount;
            if isfield(s,'FilterMethod')
                obj.FilterStates = s.FilterStates;                
                obj.FilterNumerator = s.FilterNumerator;                
                obj.FilterDenominator = s.FilterDenominator;                
                obj.FilterGain = s.FilterGain;
                obj.pFilterMethod = s.pFilterMethod;
            end
            if isfield(s,'FilterStatesCount')
                obj.FilterStatesCount = s.FilterStatesCount;
                obj.FilterNumeratorCount = s.FilterNumeratorCount;
                obj.FilterDenominatorCount = s.FilterDenominatorCount;
            end
            if isfield(s,'SliceCount')
                obj.SliceCount = s.SliceCount;
                obj.OutputOptMetric = s.OutputOptMetric;
            end

            % Set public properties and states
            loadObjectImpl@matlab.System(obj,s,wasLocked);
        end
        
    end
    methods (Access = protected) %Propagator methods
        function varargout = getOutputDataTypeImpl(obj)
            v1 = propagatedInputDataType(obj,1);
            varargout{1} = v1;
            varargout{2} = v1;
            if obj.OutputOptMetric == true            
                varargout{3} = v1;
            end
        end
        
        function varargout = getOutputSizeImpl(obj)
            varargout{1} = propagatedInputSize(obj,1);
            varargout{2} = [1 1];
            if obj.OutputOptMetric == true            
                varargout{3} = [1 1];
            end            
        end
        
        function varargout = isOutputFixedSizeImpl(obj)
            varargout{1} = propagatedInputFixedSize(obj,1);
            varargout{2} = true;
            if obj.OutputOptMetric == true
                varargout{3} = true;
            end
        end
        
        function varargout = isOutputComplexImpl(obj)
            varargout{1} = false;
            varargout{2} = false;
            if obj.OutputOptMetric == true
                varargout{3} = false;
            end
            
        end
    end
    
end
