module DynamicPPLMCMCChainsExt

using DynamicPPL: DynamicPPL
using MCMCChains: MCMCChains

_has_varname_to_symbol(info::NamedTuple{names}) where {names} = :varname_to_symbol in names
function DynamicPPL.supports_varname_indexing(chain::MCMCChains.Chains)
    return _has_varname_to_symbol(chain.info)
end

# TODO: Add proper overload of `Base.getindex` to Turing.jl?
function _getindex(c::MCMCChains.Chains, sample_idx, vn::DynamicPPL.VarName, chain_idx)
    DynamicPPL.supports_varname_indexing(c) ||
        error("Chains do not support indexing using $vn.")
    return c[sample_idx, c.info.varname_to_symbol[vn], chain_idx]
end

function DynamicPPL.generated_quantities(
    model::DynamicPPL.Model, chain_full::MCMCChains.Chains
)
    chain = MCMCChains.get_sections(chain_full, :parameters)
    varinfo = DynamicPPL.VarInfo(model)
    iters = Iterators.product(1:size(chain, 1), 1:size(chain, 3))
    return map(iters) do (sample_idx, chain_idx)
        if DynamicPPL.supports_varname_indexing(chain)
            # First we need to set every variable to be resampled.
            for vn in keys(varinfo)
                DynamicPPL.set_flag!(varinfo, vn, "del")
            end
            # Then we set the variables in `varinfo` from `chain`.
            for vn in keys(chain.info.varname_to_symbol)
                vn_updated = DynamicPPL.nested_setindex_maybe!(
                    varinfo, _getindex(chain, sample_idx, vn, chain_idx), vn
                )

                # Unset the `del` flag if we found something.
                if vn_updated !== nothing
                    # NOTE: This will be triggered even if only a subset of a variable has been set!
                    DynamicPPL.unset_flag!(varinfo, vn_updated, "del")
                end
            end
        else
            # NOTE: This can be quite unreliable (but will warn the uesr in that case).
            # Hence the above path is much more preferable.
            DynamicPPL.setval_and_resample!(varinfo, chain, sample_idx, chain_idx)
        end
        # TODO: Some of the variables can be a view into the `varinfo`, so we need to
        # `deepcopy` the `varinfo` before passing it to `model`.
        model(deepcopy(varinfo))
    end
end

end
