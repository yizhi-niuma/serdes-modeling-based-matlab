classdef TxDSP < matlab.System
    properties
        prbs_order = 7;
        gray_en = 0;
        precode_en = 0;
        modulation = 4;
        dmux_num = 64;
        tx_main_idx = 3;
        tx_npre = 2;
        tx_npst = 5;
        ffe_tap_num = 8;
        ffe_coef_nbit = 7;
        max_tap_value = 84;
        tx_ffe_coef = [0 0 84 0 0 0 0 0];
        pam2_en = 0;
        pam2_nclk = 2000;
    end
    methods(Access=private)
        function prbs_seq=prbs_gen(obj,nclk)
            init_state = [1 zeros(1, obj.prbs_order-1)];
            switch obj.prbs_order
                case 7
                    pn = comm.PNSequence('Polynomial','x^7+x^1+1', 'InitialConditions', init_state, ...
                        'SamplesPerFrame',nclk*obj.dmux_num * log2(obj.modulation)); % x^7 + x^1 + 1 in matlab is equivalent to x^7 + x^6 + 1 in ethernet
                case 9
                    pn = comm.PNSequence('Polynomial','x^9+x^4+1', 'InitialConditions', init_state, ...
                        'SamplesPerFrame',nclk*obj.dmux_num * log2(obj.modulation)); % x^9 + x^4 + 1 in matlab is equivalent to x^9 + x^5 + 1 in ethernet
                case 13
                    pn = comm.PNSequence('Polynomial','x^13+x^12+x^11+x^1+1', 'InitialConditions', init_state, ...
                        'SamplesPerFrame',nclk*obj.dmux_num * log2(obj.modulation)); % x^13 + x^12 + x^11 + x^1 + 1 in matlab is equivalent to x^13+x^12+x^2+x^1+1 in ethernet
                case 15
                    pn = comm.PNSequence('Polynomial','x^15+x^1+1', 'InitialConditions', init_state, ...
                        'SamplesPerFrame',nclk*obj.dmux_num * log2(obj.modulation)); % x^15 + x^1 + 1 in matlab is equivalent to x^15 + x^14 + 1 in ethernet
                case 23
                    pn = comm.PNSequence('Polynomial','x^23+x^5+1', 'InitialConditions', init_state, ...
                        'SamplesPerFrame',nclk*obj.dmux_num * log2(obj.modulation)); % x^23 + x^5 + 1 in matlab is equivalent to x^23 + x^18 + 1 in ethernet
                case 31
                    pn = comm.PNSequence('Polynomial','x^31+x^3+1', 'InitialConditions', init_state, ...
                        'SamplesPerFrame',nclk*obj.dmux_num * log2(obj.modulation)); % x^31 + x^3 + 1 in matlab is equivalent to x^31 + x^28 + 1 in ethernet
                otherwise
                    error('prbs_order ' + num2str(obj.prbs_order) + ' is invalid');
            end
            prbs_seq = pn()';
        end
    end
    methods
        %%Constructor
        function obj = TxDSP(varargin)
            setProperties(obj,nargin,varargin{:})
            [~, obj.tx_main_idx] = max(obj.tx_ffe_coef);
            obj.tx_npre = obj.tx_main_idx - 1;
            obj.tx_npst = length(obj.tx_ffe_coef) - obj.tx_main_idx;
        end

        function [tx_ffe_out, tx_symbol_0123] = ffe(obj, nclk)
            %%METHOD1 此处显示有关此方法的摘要
            % 此处显示详细说明
            %tx_seq=prbs(obj,prbs_order,obj.dmux_num * log2(obj.modulation)*nclk);

            if obj.modulation == 4
                if obj.pam2_en == 1
                    tx_seq_pam2 = obj.prbs_gen(round(obj.pam2_nclk/2));
                    msb_pam2 = tx_seq_pam2(1:end);
                    lsb_pam2 = msb_pam2;
                    tx_seq_pam4 = obj.prbs_gen(nclk - obj.pam2_nclk);
                    msb_pam4 = tx_seq_pam4(1:2:end-1);
                    lsb_pam4 = tx_seq_pam4(2:2:end);
                    msb = [msb_pam2, msb_pam4];
                    lsb = [lsb_pam2, lsb_pam4];
                else
                    tx_seq = obj.prbs_gen(nclk);
                    msb = tx_seq(1:2:end-1);
                    lsb = tx_seq(2:2:end);
                end
            else %NRZ
                tx_seq = obj.prbs_gen(nclk);
                msb = tx_seq(1:end);
                lsb = msb;
            end
            if sum(abs(obj.tx_ffe_coef))>obj.max_tap_value
                error('Sum of FFE coefficients should not exceed the limits');
            end
            tx_symbol_0123=(2*msb+lsb);
            if obj.modulation ==4
                tx_symbol_0123_orig = tx_symbol_0123;
                if obj.gray_en
                    tx_symbol_0123(tx_symbol_0123_orig ==2) = 3;
                    tx_symbol_0123(tx_symbol_0123_orig ==3) = 2;
                end
                if obj.precode_en
                    data_precode = zeros(1, length(tx_symbol_0123));
                    data_precode(1) = tx_symbol_0123 (1);
                    for id_sym = 2: length(tx_symbol_0123)
                        data_precode(id_sym) = mod(tx_symbol_0123(id_sym) - data_precode(id_sym-1), 4);
                    end
                    tx_symbol_0123 = data_precode;
                end
            end
            tx_symbol = tx_symbol_0123*2-3;
            conv_out = conv(obj.tx_ffe_coef, tx_symbol );
            tx_ffe_out = round(conv_out(1+obj.tx_npre: end - obj.tx_npst )/2^2);
        end
    end
end