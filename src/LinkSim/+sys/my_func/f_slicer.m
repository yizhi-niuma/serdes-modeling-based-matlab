function [data_sliced_0123, data_sliced, data_err] = f_slicer(modulation, data_in, heh)
% heh = [heh(1) heh(2) heh(3) heh(4)]

%data_sliced_0123 = zeros(1, length(data_in));
data_err = zeros(1, length(data_in));

if modulation == 2
    vth = round(0.5*(heh(1) + heh(4)));
    data_sliced_0123 = (data_in >= vth);
    data_sliced = 6* data_sliced_0123 -3;
    for idx = 1: length(data_in)
        j =  data_sliced_0123 (idx)*3 + 1;
        data_err(idx) = - (data_in(idx) - heh(j));
    end
else
    vth(1) = round(0.5*(heh(1) + heh(2)));
    vth(2) = round(0.5*(heh(2) + heh(3)));
    vth(3) = round(0.5*(heh(3) + heh(4)));
    data_sliced_0123 = ( data_in > vth(1)) + (data_in > vth(2)) + (data_in > vth(3));
    data_sliced = 2* data_sliced_0123 -3;
    for idx = 1: length(data_in)
        j =  data_sliced_0123 (idx) + 1;
        data_err(idx) = - (data_in(idx) - heh(j));
    end
end