function [BER, err_idx, bit_rec, ktry] = PRBScheck2(sym_in, modulation, ord, len_compare)
% sym_in belongs to the set of [0 1] or [0 1 2 3]
switch ord
    case 7
        Polynomial = 'x^7+x^6+1';
    case 9
        Polynomial = 'x^9+x^5+1';
    case 13
        Polynomial = 'x^13+x^12+x^2 +x +1';
    case 15
        Polynomial = 'x^15+x^14 +1';
    case 23
        Polynomial = 'x^23+x^18 +1';
    case 31
        Polynomial = 'x^31+x^28 +1';
    otherwise
        error('PRBS order is not support!')
end
len = length(sym_in);
ktry = 0;
flag = 0;
if modulation == 4
    sym_in_bit = nan(1, 2*len);
    for id = 1:len
        sym_in_bit(2*id-1:2*id) = bitget(sym_in(id), 2:-1:1);
    end
    len = len * 2;
else
    sym_in_bit = sym_in;
end
ktry_max = floor(len / len_compare);
while ktry < ktry_max && ~flag
    sym_id_begin = ktry * len_compare;
    seed_try = sym_in_bit(sym_id_begin + 1 : sym_id_begin + ord);
    if sum(seed_try == 0) == ord
        ktry = ktry + 1;
    else
        pn_rec = comm.PNSequence('Polynomial', Polynomial, 'InitialConditions', flip(seed_try), ...
            'SamplesPerFrame', len_compare);
        sym_compare = pn_rec();
        flag = isequal(sym_compare, sym_in_bit(sym_id_begin + 1 : sym_id_begin + len_compare));
        ktry = ktry + 1;
    end
end
pn_rec = comm.PNSequence('Polynomial', Polynomial, 'InitialConditions', flip(seed_try), ...
    'SamplesPerFrame', len - sym_id_begin);
bit_rec = pn_rec();
bit_input = sym_in_bit(sym_id_begin + 1 : end);
Nbit_total = length(bit_rec);
BER = sum(xor(bit_rec, bit_input)) / Nbit_total;
err_idx = find(bit_input ~= bit_rec) + sym_id_begin;
end