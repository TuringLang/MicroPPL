"""
    @submodel x = model(args...)
    @submodel prefix x = model(args...)

Treats `model` as a distribution, where `x` is the return-value of `model`.

If `prefix` is specified, then variables sampled within `model` will be
prefixed by `prefix`. This is useful if you have variables of same names in
several models used together.
"""
macro submodel(expr)
    return submodel(expr)
end

macro submodel(prefix, expr)
    ctx = :(PrefixContext{$(esc(Meta.quot(prefix)))}($(esc(:__context__))))
    return submodel(expr, ctx)
end

function submodel(expr, ctx=esc(:__context__))
    args_assign = getargs_assignment(expr)
    return if args_assign === nothing
        # In this case we only want to get the `__varinfo__`.
        quote
            $(esc(:_)), $(esc(:__varinfo__)) = _evaluate(
                $(esc(expr)), $(esc(:__varinfo__)), $(ctx)
            )
        end
    else
        # Here we also want the return-variable.
        # TODO: Should we prefix by `L` by default?
        L, R = args_assign
        quote
            $(esc(L)), $(esc(:__varinfo__)) = _evaluate(
                $(esc(R)), $(esc(:__varinfo__)), $(ctx)
            )
        end
    end
end
