function plot_imp(original_imp,n_pre_UI,n_post_UI,UI, SamplesPerSymbol)
    if nargin==1
        n_pre_UI=5;
        n_post_UI=30;
        UI=1/56e9;
        SamplesPerSymbol = 128;
    end
    [temp,ipr_max_idx] = max(original_imp);
    original_t = 0:UI/SamplesPerSymbol:(numel(original_imp) - 1)*UI/SamplesPerSymbol;
    imp = original_imp( ipr_max_idx - SamplesPerSymbol * (n_pre_UI + 3) :  ipr_max_idx + SamplesPerSymbol * (n_post_UI + 10))/temp;
    t = original_t(ipr_max_idx - SamplesPerSymbol * (n_pre_UI + 3):ipr_max_idx + SamplesPerSymbol * (n_post_UI + 10)) - original_t(ipr_max_idx);
    figure();
    plot(t/UI,imp);
    hold on;
    imp_up = original_imp(ipr_max_idx - SamplesPerSymbol * n_pre_UI:SamplesPerSymbol:ipr_max_idx + SamplesPerSymbol *n_post_UI)/temp;
    t_up = original_t(ipr_max_idx - SamplesPerSymbol * n_pre_UI:SamplesPerSymbol:ipr_max_idx + SamplesPerSymbol *n_post_UI) - original_t(ipr_max_idx);
    stem(t_up/UI, imp_up)
    ylim([-0.1 1])
end