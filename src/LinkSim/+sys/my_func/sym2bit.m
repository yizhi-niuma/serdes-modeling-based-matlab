function bit_out = sym2bit(modulation, sym_in)

if modulation==2
    bit_out = sym_in;
else

    bit_out= nan(1, log2(modulation)*length(sym_in));
    for id=1:length(sym_in)
        bit_out(log2(modulation)*id-1: log2(modulation)*id)=bitget(sym_in(id), log2(modulation):-1:1); % msb arrived first
    end
end

end