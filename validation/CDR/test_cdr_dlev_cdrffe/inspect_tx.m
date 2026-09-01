s = load('C:\Work\MatLab_Lib\validation\CDR\test_cdr\result\channel_ctle_cosim\tx_prbs20.mat');
fn = fieldnames(s);
for k = 1:numel(fn)
    v = s.(fn{k});
    fprintf('%s: class=%s size=%s\n', fn{k}, class(v), mat2str(size(v)));
    if isnumeric(v) && ~isempty(v)
        u = unique(v(:));
        fprintf('  numUnique=%d min=%g max=%g\n', numel(u), min(u), max(u));
        if numel(u) <= 8
            fprintf('  uniq=%s\n', mat2str(u(:)'));
        end
        fprintf('  first16=%s\n', mat2str(reshape(v(1:min(16, numel(v))), 1, [])));
    end
end
