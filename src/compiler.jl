const INTERNALNAMES = (:__model__, :__sampler__, :__context__, :__varinfo__, :__rng__)
const DEPRECATED_INTERNALNAMES = (:_model, :_sampler, :_context, :_varinfo, :_rng)

"""
    isassumption(expr)

Return an expression that can be evaluated to check if `expr` is an assumption in the
model.

Let `expr` be `:(x[1])`. It is an assumption in the following cases:
    1. `x` is not among the input data to the model,
    2. `x` is among the input data to the model but with a value `missing`, or
    3. `x` is among the input data to the model with a value other than missing,
       but `x[1] === missing`.

When `expr` is not an expression or symbol (i.e., a literal), this expands to `false`.
"""
function isassumption(expr::Union{Symbol,Expr})
    vn = gensym(:vn)

    return quote
        let $vn = $(varname(expr))
            if $(DynamicPPL.contextual_isassumption)(__context__, $vn)
                # Considered an assumption by `__context__` which means either:
                # 1. We hit the default implementation, e.g. using `DefaultContext`,
                #    which in turn means that we haven't considered if it's one of
                #    the model arguments, hence we need to check this.
                # 2. We are working with a `ConditionContext` _and_ it's NOT in the model arguments,
                #    i.e. we're trying to condition one of the latent variables.
                #    In this case, the below will return `true` since the first branch
                #    will be hit.
                # 3. We are working with a `ConditionContext` _and_ it's in the model arguments,
                #    i.e. we're trying to override the value. This is currently NOT supported.
                #    TODO: Support by adding context to model, and use `model.args`
                #    as the default conditioning. Then we no longer need to check `inargnames`
                #    since it will all be handled by `contextual_isassumption`.
                if !($(DynamicPPL.inargnames)($vn, __model__)) ||
                   $(DynamicPPL.inmissings)($vn, __model__)
                    true
                else
                    $(maybe_view(expr)) === missing
                end
            else
                false
            end
        end
    end
end

"""
    contextual_isassumption(context, vn)

Return `true` if `vn` is considered an assumption by `context`.

The default implementation for `AbstractContext` always returns `true`.
"""
contextual_isassumption(::IsLeaf, context, vn) = true
function contextual_isassumption(::IsParent, context, vn)
    return contextual_isassumption(childcontext(context), vn)
end
function contextual_isassumption(context::AbstractContext, vn)
    return contextual_isassumption(NodeTrait(context), context, vn)
end
function contextual_isassumption(context::ConditionContext, vn)
    if hasvalue(context, vn)
        val = getvalue(context, vn)
        # TODO: Do we even need the `>: Missing`, i.e. does it even help the compiler?
        if eltype(val) >: Missing && val === missing
            return true
        else
            return false
        end
    end

    # We might have nested contexts, e.g. `ContextionContext{.., <:PrefixContext{..., <:ConditionContext}}`
    # so we defer to `childcontext` if we haven't concluded that anything yet.
    return contextual_isassumption(childcontext(context), vn)
end
function contextual_isassumption(context::PrefixContext, vn)
    return contextual_isassumption(childcontext(context), prefix(context, vn))
end

# failsafe: a literal is never an assumption
isassumption(expr) = :(false)

# If we're working with, say, a `Symbol`, then we're not going to `view`.
maybe_view(x) = x
maybe_view(x::Expr) = :($(DynamicPPL.maybe_unwrap_view)(@view($x)))

# If the result of a `view` is a zero-dim array then it's just a
# single element. Likely the rest is expecting type `eltype(x)`, hence
# we extract the value rather than passing the array.
maybe_unwrap_view(x) = x
maybe_unwrap_view(x::SubArray{<:Any,0}) = x[1]

"""
    isliteral(expr)

Return `true` if `expr` is a literal, e.g. `1.0` or `[1.0, ]`, and `false` otherwise.
"""
isliteral(e) = false
isliteral(::Number) = true
isliteral(e::Expr) = !isempty(e.args) && all(isliteral, e.args)

"""
    check_tilde_rhs(x)

Check if the right-hand side `x` of a `~` is a `Distribution` or an array of
`Distributions`, then return `x`.
"""
function check_tilde_rhs(@nospecialize(x))
    return throw(
        ArgumentError(
            "the right-hand side of a `~` must be a `Distribution` or an array of `Distribution`s",
        ),
    )
end
check_tilde_rhs(x::Distribution) = x
check_tilde_rhs(x::AbstractArray{<:Distribution}) = x

"""
    unwrap_right_vn(right, vn)

Return the unwrapped distribution on the right-hand side and variable name on the left-hand
side of a `~` expression such as `x ~ Normal()`.

This is used mainly to unwrap `NamedDist` distributions.
"""
unwrap_right_vn(right, vn) = right, vn
unwrap_right_vn(right::NamedDist, vn) = unwrap_right_vn(right.dist, right.name)

"""
    unwrap_right_left_vns(right, left, vns)

Return the unwrapped distributions on the right-hand side and values and variable names on the
left-hand side of a `.~` expression such as `x .~ Normal()`.

This is used mainly to unwrap `NamedDist` distributions and adjust the indices of the
variables.

# Example
```jldoctest; setup=:(using Distributions)
julia> _, _, vns = DynamicPPL.unwrap_right_left_vns(MvNormal([1.0, 1.0], [1.0 0.0; 0.0 1.0]), randn(2, 2), @varname(x)); string(vns[end])
"x[:,2]"

julia> _, _, vns = DynamicPPL.unwrap_right_left_vns(Normal(), randn(1, 2), @varname(x[:])); string(vns[end])
"x[:][1,2]"

julia> _, _, vns = DynamicPPL.unwrap_right_left_vns(Normal(), randn(3), @varname(x[1])); string(vns[end])
"x[1][3]"

julia> _, _, vns = DynamicPPL.unwrap_right_left_vns(Normal(), randn(1, 2, 3), @varname(x)); string(vns[end])
"x[1,2,3]"
```
"""
unwrap_right_left_vns(right, left, vns) = right, left, vns
function unwrap_right_left_vns(right::NamedDist, left, vns)
    return unwrap_right_left_vns(right.dist, left, right.name)
end
function unwrap_right_left_vns(
    right::MultivariateDistribution, left::AbstractMatrix, vn::VarName
)
    # This an expression such as `x .~ MvNormal()` which we interpret as
    #     x[:, i] ~ MvNormal()
    # for `i = size(left, 2)`. Hence the symbol should be `x[:, i]`,
    # and we therefore add the `Colon()` below.
    vns = map(axes(left, 2)) do i
        return VarName(vn, (vn.indexing..., (Colon(), i)))
    end
    return unwrap_right_left_vns(right, left, vns)
end
function unwrap_right_left_vns(
    right::Union{Distribution,AbstractArray{<:Distribution}},
    left::AbstractArray,
    vn::VarName,
)
    vns = map(CartesianIndices(left)) do i
        return VarName(vn, (vn.indexing..., Tuple(i)))
    end
    return unwrap_right_left_vns(right, left, vns)
end

#################
# Main Compiler #
#################

"""
    @model(expr[, warn = false])

Macro to specify a probabilistic model.

If `warn` is `true`, a warning is displayed if internal variable names are used in the model
definition.

# Examples

Model definition:

```julia
@model function model(x, y = 42)
    ...
end
```

To generate a `Model`, call `model(xvalue)` or `model(xvalue, yvalue)`.
"""
macro model(expr, warn=false)
    # include `LineNumberNode` with information about the call site in the
    # generated function for easier debugging and interpretation of error messages
    return esc(model(__module__, __source__, expr, warn))
end

function model(mod, linenumbernode, expr, warn)
    modelinfo = build_model_info(expr)

    # Generate main body
    modelinfo[:body] = generate_mainbody(mod, modelinfo[:modeldef][:body], warn)

    return build_output(modelinfo, linenumbernode)
end

"""
    build_model_info(input_expr)

Builds the `model_info` dictionary from the model's expression.
"""
function build_model_info(input_expr)
    # Break up the model definition and extract its name, arguments, and function body
    modeldef = MacroTools.splitdef(input_expr)

    # Check that the function has a name
    # https://github.com/TuringLang/DynamicPPL.jl/issues/260
    haskey(modeldef, :name) ||
        throw(ArgumentError("anonymous functions without name are not supported"))

    # Print a warning if function body of the model is empty
    warn_empty(modeldef[:body])

    ## Construct model_info dictionary

    # Shortcut if the model does not have any arguments
    if !haskey(modeldef, :args) && !haskey(modeldef, :kwargs)
        modelinfo = Dict(
            :allargs_exprs => [],
            :allargs_syms => [],
            :allargs_namedtuple => NamedTuple(),
            :defaults_namedtuple => NamedTuple(),
            :modeldef => modeldef,
        )
        return modelinfo
    end

    # Extract the positional and keyword arguments from the model definition.
    allargs = vcat(modeldef[:args], modeldef[:kwargs])

    # Split the argument expressions and the default values.
    allargs_exprs_defaults = map(allargs) do arg
        MacroTools.@match arg begin
            (x_ = val_) => (x, val)
            x_ => (x, NO_DEFAULT)
        end
    end

    # Extract the expressions of the arguments, without default values.
    allargs_exprs = first.(allargs_exprs_defaults)

    # Extract the names of the arguments.
    allargs_syms = map(allargs_exprs) do arg
        MacroTools.@match arg begin
            (::Type{T_}) | (name_::Type{T_}) => T
            name_::T_ => name
            x_ => x
        end
    end

    # Build named tuple expression of the argument symbols and variables of the same name.
    allargs_namedtuple = to_namedtuple_expr(allargs_syms)

    # Extract default values of the positional and keyword arguments.
    default_syms = []
    default_vals = []
    for (sym, (expr, val)) in zip(allargs_syms, allargs_exprs_defaults)
        if val !== NO_DEFAULT
            push!(default_syms, sym)
            push!(default_vals, val)
        end
    end

    # Build named tuple expression of the argument symbols with default values.
    defaults_namedtuple = to_namedtuple_expr(default_syms, default_vals)

    modelinfo = Dict(
        :allargs_exprs => allargs_exprs,
        :allargs_syms => allargs_syms,
        :allargs_namedtuple => allargs_namedtuple,
        :defaults_namedtuple => defaults_namedtuple,
        :modeldef => modeldef,
    )

    return modelinfo
end

"""
    generate_mainbody(mod, expr, warn)

Generate the body of the main evaluation function from expression `expr` and arguments
`args`.

If `warn` is true, a warning is displayed if internal variables are used in the model
definition.
"""
generate_mainbody(mod, expr, warn) = generate_mainbody!(mod, Symbol[], expr, warn)

generate_mainbody!(mod, found, x, warn) = x
function generate_mainbody!(mod, found, sym::Symbol, warn)
    if sym in DEPRECATED_INTERNALNAMES
        newsym = Symbol(:_, sym, :__)
        Base.depwarn(
            "internal variable `$sym` is deprecated, use `$newsym` instead.",
            :generate_mainbody!,
        )
        return generate_mainbody!(mod, found, newsym, warn)
    end

    if warn && sym in INTERNALNAMES && sym ∉ found
        @warn "you are using the internal variable `$sym`"
        push!(found, sym)
    end

    return sym
end
function generate_mainbody!(mod, found, expr::Expr, warn)
    # Do not touch interpolated expressions
    expr.head === :$ && return expr.args[1]

    # If it's a macro, we expand it
    if Meta.isexpr(expr, :macrocall)
        return generate_mainbody!(mod, found, macroexpand(mod, expr; recursive=true), warn)
    end

    # Modify dotted tilde operators.
    args_dottilde = getargs_dottilde(expr)
    if args_dottilde !== nothing
        L, R = args_dottilde
        return Base.remove_linenums!(
            generate_dot_tilde(
                generate_mainbody!(mod, found, L, warn),
                generate_mainbody!(mod, found, R, warn),
            ),
        )
    end

    # Modify tilde operators.
    args_tilde = getargs_tilde(expr)
    if args_tilde !== nothing
        L, R = args_tilde
        return Base.remove_linenums!(
            generate_tilde(
                generate_mainbody!(mod, found, L, warn),
                generate_mainbody!(mod, found, R, warn),
            ),
        )
    end

    return Expr(expr.head, map(x -> generate_mainbody!(mod, found, x, warn), expr.args)...)
end

"""
    generate_tilde(left, right)

Generate an `observe` expression for data variables and `assume` expression for parameter
variables.
"""
function generate_tilde(left, right)
    # If the LHS is a literal, it is always an observation
    if isliteral(left)
        return quote
            _, __varinfo__ = $(DynamicPPL.tilde_observe!!)(
                __context__, $(DynamicPPL.check_tilde_rhs)($right), $left, __varinfo__
            )
        end
    end

    # Otherwise it is determined by the model or its value,
    # if the LHS represents an observation
    @gensym vn inds isassumption
    return quote
        $vn = $(varname(left))
        $inds = $(vinds(left))
        $isassumption = $(DynamicPPL.isassumption(left))
        if $isassumption
            $left, __varinfo__ = $(DynamicPPL.tilde_assume!!)(
                __context__,
                $(DynamicPPL.unwrap_right_vn)(
                    $(DynamicPPL.check_tilde_rhs)($right), $vn
                )...,
                $inds,
                __varinfo__,
            )
        else
            # If `vn` is not in `argnames`, we need to make sure that the variable is defined.
            if !$(DynamicPPL.inargnames)($vn, __model__)
                $left = $(DynamicPPL.getvalue_nested)(__context__, $vn)
            end

            $(DynamicPPL.tilde_observe!!)(
                __context__,
                $(DynamicPPL.check_tilde_rhs)($right),
                $(maybe_view(left)),
                $vn,
                $inds,
                __varinfo__,
            )
        end
    end
end

"""
    generate_dot_tilde(left, right)

Generate the expression that replaces `left .~ right` in the model body.
"""
function generate_dot_tilde(left, right)
    # If the LHS is a literal, it is always an observation
    if isliteral(left)
        return quote
            _, __varinfo__ = $(DynamicPPL.dot_tilde_observe!!)(
                __context__, $(DynamicPPL.check_tilde_rhs)($right), $left, __varinfo__
            )
        end
    end

    # Otherwise it is determined by the model or its value,
    # if the LHS represents an observation
    @gensym vn inds isassumption
    return quote
        $vn = $(varname(left))
        $inds = $(vinds(left))
        $isassumption = $(DynamicPPL.isassumption(left))
        if $isassumption
            _, __varinfo__ = $(DynamicPPL.dot_tilde_assume!!)(
                __context__,
                $(DynamicPPL.unwrap_right_left_vns)(
                    $(DynamicPPL.check_tilde_rhs)($right), $(maybe_view(left)), $vn
                )...,
                $inds,
                __varinfo__,
            )
        else
            # If `vn` is not in `argnames`, we need to make sure that the variable is defined.
            if !$(DynamicPPL.inargnames)($vn, __model__)
                $left .= $(DynamicPPL.getvalue_nested)(__context__, $vn)
            end

            $(DynamicPPL.dot_tilde_observe!!)(
                __context__,
                $(DynamicPPL.check_tilde_rhs)($right),
                $(maybe_view(left)),
                $vn,
                $inds,
                __varinfo__,
            )
        end
    end
end

"""
    isfuncdef(expr)

Return `true` if `expr` is any form of function definition, and `false` otherwise.
"""
function isfuncdef(e::Expr)
    return if Meta.isexpr(e, :function)
        # Classic `function f(...)`
        true
    elseif Meta.isexpr(e, :->)
        # Anonymous functions/lambdas, e.g. `do` blocks or `->` defs.
        true
    elseif Meta.isexpr(e, :=) && Meta.isexpr(e.args[1], :call)
        # Short function defs, e.g. `f(args...) = ...`.
        true
    else
        false
    end
end

"""
    replace_returns(expr)

Return `Expr` with all `return ...` statements replaced with
`return ..., DynamicPPL.return_values(__varinfo__)`.

Note that this method will _not_ replace `return` statements within function
definitions. This is checked using [`isfuncdef`](@ref).
"""
replace_returns(e) = e
replace_returns(e::Symbol) = e
function replace_returns(e::Expr)
    if isfuncdef(e)
        return e
    end

    if Meta.isexpr(e, :return)
        # NOTE: `return` always has an argument. In the case of
        # `return`, the parsed expression will be `return nothing`.
        # Hence we don't need any special handling for empty returns.
        retval_expr = if length(e.args) > 1
            Expr(:tuple, e.args...)
        else
            e.args[1]
        end

        return :(return $(DynamicPPL.return_values)($retval_expr, __varinfo__))
    end

    return Expr(e.head, map(replace_returns, e.args)...)
end

"""
    return_values(retval, varinfo)

Return `(retval, varinfo)` if `retval` is not a `Tuple` with second
component being a `AbstractVarInfo`.

Used together with [`replace_returns`](@ref), it handles the following case.

# Example

Suppose the following is the return-value:

```julia
return x ~ Normal()
```

Without `return_values`, once expanded in [`generated_mainbody!`](@ref), this would be

```julia
return (x, __varinfo__ = tilde_assume!!(...)), __varinfo__
```

i.e. the return-value of the model would end up `(x, __varinfo__), __varinfo__`
which in turn would lead to a `(::Model)(args...)` call returning `(x, __varinfo__)`,
breaking with the expectation of the user.

In such a scenario `return_values` effectively results in the following

```julia
return x, __varinfo__ = tilde_assume!!(...)
```

preserving user expectation, as desired.
"""
return_values(retval, varinfo::AbstractVarInfo) = (retval, varinfo)
return_values(retval::Tuple{<:Any,<:AbstractVarInfo}, ::AbstractVarInfo) = retval

# If it's just a symbol, e.g. `f(x) = 1`, then we make it `f(x) = return 1`.
make_returns_explicit!(body) = Expr(:return, body)
function make_returns_explicit!(body::Expr)
    # If the last statement is a return-statement, we don't do anything.
    if Meta.isexpr(body.args[end], :return)
        return body
    end

    # Otherwise we replace the last statement with a `return` statement.
    body.args[end] = Expr(:return, body.args[end])
    return body
end

const FloatOrArrayType = Type{<:Union{AbstractFloat,AbstractArray}}
hasmissing(T::Type{<:AbstractArray{TA}}) where {TA<:AbstractArray} = hasmissing(TA)
hasmissing(T::Type{<:AbstractArray{>:Missing}}) = true
hasmissing(T::Type) = false

"""
    build_output(modelinfo, linenumbernode)

Builds the output expression.
"""
function build_output(modelinfo, linenumbernode)
    ## Build the anonymous evaluator from the user-provided model definition.

    # Remove the name.
    evaluatordef = deepcopy(modelinfo[:modeldef])
    delete!(evaluatordef, :name)

    # Add the internal arguments to the user-specified arguments (positional + keywords).
    evaluatordef[:args] = vcat(
        [
            :(__model__::$(DynamicPPL.Model)),
            :(__varinfo__::$(DynamicPPL.AbstractVarInfo)),
            :(__context__::$(DynamicPPL.AbstractContext)),
        ],
        modelinfo[:allargs_exprs],
    )

    # Delete the keyword arguments.
    evaluatordef[:kwargs] = []

    # Replace the user-provided function body with the version created by DynamicPPL.
    # NOTE: We need to replace statements of the form `return ...` with
    # `return DynamicPPL.return_values(..., __varinfo__)` to ensure that the second
    # element in the returned value is always the most up-to-date `__varinfo__`.
    # See the docstrings of `replace_returns` and `return_values` for more info.
    evaluatordef[:body] = replace_returns(make_returns_explicit!(modelinfo[:body]))

    ## Build the model function.

    # Extract the named tuple expression of all arguments and the default values.
    allargs_namedtuple = modelinfo[:allargs_namedtuple]
    defaults_namedtuple = modelinfo[:defaults_namedtuple]

    # Update the function body of the user-specified model.
    # We use a name for the anonymous evaluator that does not conflict with other variables.
    modeldef = modelinfo[:modeldef]
    @gensym evaluator
    # We use `MacroTools.@q begin ... end` instead of regular `quote ... end` to ensure
    # that no new `LineNumberNode`s are added apart from the reference `linenumbernode`
    # to the call site
    modeldef[:body] = MacroTools.@q begin
        $(linenumbernode)
        $evaluator = $(MacroTools.combinedef(evaluatordef))
        return $(DynamicPPL.Model)(
            $(QuoteNode(modeldef[:name])),
            $evaluator,
            $allargs_namedtuple,
            $defaults_namedtuple,
        )
    end

    return :($(Base).@__doc__ $(MacroTools.combinedef(modeldef)))
end

function warn_empty(body)
    if all(l -> isa(l, LineNumberNode), body.args)
        @warn("Model definition seems empty, still continue.")
    end
    return nothing
end

"""
    matchingvalue(sampler, vi, value)
    matchingvalue(context::AbstractContext, vi, value)

Convert the `value` to the correct type for the `sampler` or `context` and the `vi` object.

For a `context` that is _not_ a `SamplingContext`, we fall back to
`matchingvalue(SampleFromPrior(), vi, value)`.
"""
function matchingvalue(sampler, vi, value)
    T = typeof(value)
    if hasmissing(T)
        _value = convert(get_matching_type(sampler, vi, T), value)
        if _value === value
            return deepcopy(_value)
        else
            return _value
        end
    else
        return value
    end
end
function matchingvalue(sampler::AbstractSampler, vi, value::FloatOrArrayType)
    return get_matching_type(sampler, vi, value)
end

function matchingvalue(context::AbstractContext, vi, value)
    return matchingvalue(NodeTrait(matchingvalue, context), context, vi, value)
end
function matchingvalue(::IsLeaf, context::AbstractContext, vi, value)
    return matchingvalue(SampleFromPrior(), vi, value)
end
function matchingvalue(::IsParent, context::AbstractContext, vi, value)
    return matchingvalue(childcontext(context), vi, value)
end
function matchingvalue(context::SamplingContext, vi, value)
    return matchingvalue(context.sampler, vi, value)
end

"""
    get_matching_type(spl::AbstractSampler, vi, ::Type{T}) where {T}

Get the specialized version of type `T` for sampler `spl`.

For example, if `T === Float64` and `spl::Hamiltonian`, the matching type is
`eltype(vi[spl])`.
"""
get_matching_type(spl::AbstractSampler, vi, ::Type{T}) where {T} = T
function get_matching_type(spl::AbstractSampler, vi, ::Type{<:Union{Missing,AbstractFloat}})
    return Union{Missing,floatof(eltype(vi, spl))}
end
function get_matching_type(spl::AbstractSampler, vi, ::Type{<:AbstractFloat})
    return floatof(eltype(vi, spl))
end
function get_matching_type(spl::AbstractSampler, vi, ::Type{<:Array{T,N}}) where {T,N}
    return Array{get_matching_type(spl, vi, T),N}
end
function get_matching_type(spl::AbstractSampler, vi, ::Type{<:Array{T}}) where {T}
    return Array{get_matching_type(spl, vi, T)}
end

floatof(::Type{T}) where {T<:Real} = typeof(one(T) / one(T))
floatof(::Type) = Real # fallback if type inference failed
