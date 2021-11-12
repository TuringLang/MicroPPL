# singleton for indicating if no default arguments are present
struct NoDefault end
const NO_DEFAULT = NoDefault()

"""
    @addlogprob!(ex)

Add the result of the evaluation of `ex` to the joint log probability.
"""
macro addlogprob!(ex)
    return quote
        $(esc(:(__varinfo__))) = acclogp!!($(esc(:(__varinfo__))), $(esc(ex)))
    end
end

"""
    getargs_dottilde(x)

Return the arguments `L` and `R`, if `x` is an expression of the form `L .~ R` or
`(~).(L, R)`, or `nothing` otherwise.
"""
getargs_dottilde(x) = nothing
function getargs_dottilde(expr::Expr)
    return MacroTools.@match expr begin
        (.~)(L_, R_) => (L, R)
        (~).(L_, R_) => (L, R)
        # Julia 1.6: see https://github.com/TuringLang/Turing.jl/issues/1525
        (L_ .~ R_) => (L, R)
        x_ => nothing
    end
end

"""
    getargs_tilde(x)

Return the arguments `L` and `R`, if `x` is an expression of the form `L ~ R`, or `nothing`
otherwise.
"""
getargs_tilde(x) = nothing
function getargs_tilde(expr::Expr)
    return MacroTools.@match expr begin
        (~)(L_, R_) => (L, R)
        x_ => nothing
    end
end

"""
    getargs_assignment(x)

Return the arguments `L` and `R`, if `x` is an expression of the form `L = R`, or `nothing`
otherwise.
"""
getargs_assignment(x) = nothing
function getargs_assignment(expr::Expr)
    return MacroTools.@match expr begin
        (L_ = R_) => (L, R)
        x_ => nothing
    end
end

function to_namedtuple_expr(syms, vals=syms)
    length(syms) == 0 && return :(NamedTuple())

    names_expr = Expr(:tuple, QuoteNode.(syms)...)
    vals_expr = Expr(:tuple, vals...)
    return :(NamedTuple{$names_expr}($vals_expr))
end

#####################################################
# Helper functions for vectorize/reconstruct values #
#####################################################

vectorize(d::UnivariateDistribution, r::Real) = [r]
vectorize(d::MultivariateDistribution, r::AbstractVector{<:Real}) = copy(r)
vectorize(d::MatrixDistribution, r::AbstractMatrix{<:Real}) = copy(vec(r))

# NOTE:
# We cannot use reconstruct{T} because val is always Vector{Real} then T will be Real.
# However here we would like the result to be specifric type, e.g. Array{Dual{4,Float64}, 2},
# otherwise we will have error for MatrixDistribution.
# Note this is not the case for MultivariateDistribution so I guess this might be lack of
# support for some types related to matrices (like PDMat).
reconstruct(d::Distribution, val::AbstractVector) = reconstruct(size(d), val)
reconstruct(::Tuple{}, val::AbstractVector) = val[1]
reconstruct(s::NTuple{1}, val::AbstractVector) = copy(val)
reconstruct(s::NTuple{2}, val::AbstractVector) = reshape(copy(val), s)
function reconstruct!(r, d::Distribution, val::AbstractVector)
    return reconstruct!(r, d, val)
end
function reconstruct!(r, d::MultivariateDistribution, val::AbstractVector)
    r .= val
    return r
end
function reconstruct(d::Distribution, val::AbstractVector, n::Int)
    return reconstruct(size(d), val, n)
end
function reconstruct(::Tuple{}, val::AbstractVector, n::Int)
    return copy(val)
end
function reconstruct(s::NTuple{1}, val::AbstractVector, n::Int)
    return copy(reshape(val, s[1], n))
end
function reconstruct(s::NTuple{2}, val::AbstractVector, n::Int)
    tmp = reshape(val, s..., n)
    orig = [tmp[:, :, i] for i in 1:n]
    return orig
end
function reconstruct!(r, d::Distribution, val::AbstractVector, n::Int)
    return reconstruct!(r, d, val, n)
end
function reconstruct!(r, d::MultivariateDistribution, val::AbstractVector, n::Int)
    r .= val
    return r
end

# Uniform random numbers with range 4 for robust initializations
# Reference: https://mc-stan.org/docs/2_19/reference-manual/initialization.html
randrealuni(rng::Random.AbstractRNG) = 4 * rand(rng) - 2
randrealuni(rng::Random.AbstractRNG, args...) = 4 .* rand(rng, args...) .- 2

const Transformable = Union{
    PositiveDistribution,
    UnitDistribution,
    TransformDistribution,
    SimplexDistribution,
    PDMatDistribution,
}
istransformable(dist) = false
istransformable(::Transformable) = true

#################################
# Single-sample initialisations #
#################################

inittrans(rng, dist::UnivariateDistribution) = invlink(dist, randrealuni(rng))
function inittrans(rng, dist::MultivariateDistribution)
    return invlink(dist, randrealuni(rng, size(dist)[1]))
end
inittrans(rng, dist::MatrixDistribution) = invlink(dist, randrealuni(rng, size(dist)...))

################################
# Multi-sample initialisations #
################################

inittrans(rng, dist::UnivariateDistribution, n::Int) = invlink(dist, randrealuni(rng, n))
function inittrans(rng, dist::MultivariateDistribution, n::Int)
    return invlink(dist, randrealuni(rng, size(dist)[1], n))
end
function inittrans(rng, dist::MatrixDistribution, n::Int)
    return invlink(dist, [randrealuni(rng, size(dist)...) for _ in 1:n])
end

#######################
# Convenience methods #
#######################
collectmaybe(x) = x
collectmaybe(x::Base.AbstractSet) = collect(x)

#######################
# BangBang.jl related #
#######################
function set!!(obj, vn::VarName{sym}, value) where {sym}
    lens = BangBang.prefermutation(Setfield.PropertyLens{sym}() ∘ AbstractPPL.getlens(vn))
    return Setfield.set(obj, lens, value)
end

#############################
# AbstractPPL.jl extensions #
#############################
# This is preferable to `haskey` because the order of arguments is different, and
# we're more likely to specialize on the key in these settings rather than the container.
# TODO: I'm not sure about this name.
"""
    canview(lens, container)

Return `true` if `lens` can be used to view `container`, and `false` otherwise.

# Examples
```jldoctest; setup=:(using Setfield; using DynamicPPL: canview)
julia> canview(@lens(_.a), (a = 1.0, ))
true

julia> canview(@lens(_.a), (b = 1.0, )) # property `a` does not exist
false

julia> canview(@lens(_.a[1]), (a = [1.0, 2.0], ))
true

julia> canview(@lens(_.a[3]), (a = [1.0, 2.0], )) # out of bounds
false
```
"""
canview(lens, container) = false
canview(::Setfield.IdentityLens, _) = true
function canview(lens::Setfield.PropertyLens{field}, x) where {field}
    return haskey(x, field)
end
# `IndexLens`: only relevant if `x` supports indexing.
canview(lens::Setfield.IndexLens, x) = false
canview(lens::Setfield.IndexLens, x::AbstractArray) = checkbounds(Bool, x, lens.indices...)

# `ComposedLens`: check that we can view `.outer` and `.inner`, but using
# value extracted using `.outer`.
function canview(lens::Setfield.ComposedLens, x)
    return canview(lens.outer, x) && canview(lens.inner, get(x, lens.outer))
end

"""
    parent(vn::VarName)

Return the parent `VarName`.

# Examples
```julia-repl
julia> parent(@varname(x.a[1]))
x.a

julia> (parent ∘ parent)(@varname(x.a[1]))
x

julia> (parent ∘ parent ∘ parent)(@varname(x.a[1]))
x
```
"""
function parent(vn::VarName)
    p = parent(getlens(vn))
    return p === nothing ? VarName(vn, Setfield.IdentityLens()) : VarName(vn, p)
end

"""
    parent(lens::Setfield.Lens)

Return the parent lens.

See also: [`parent_and_child`].

# Examples
```jldoctest; setup=:(using Setfield; using DynamicPPL: parent)
julia> parent(@lens(_.a[1]))
(@lens _.a)

julia> (parent ∘ parent)(@lens(_.a[1]))
(@lens _)

julia> # parent of `IdentityLens` is `IdentityLens`
       (parent ∘ parent ∘ parent)(@lens(_.a[1]))
(@lens _)
```
"""
parent(lens::Setfield.Lens) = first(parent_and_child(lens))

"""
    parent(lens::Setfield.Lens)

Return a 2-tuple of lenses `(parent, child)` where

See also: [`parent`].

# Examples
```jldoctest; setup=:(using Setfield; using DynamicPPL: parent_and_child)
julia> parent_and_child(@lens(_.a[1]))
((@lens _.a), (@lens _[1]))

julia> parent_and_child(@lens(_.a))
(nothing, (@lens _.a))
```
"""
parent_and_child(lens::Setfield.Lens) = (nothing, lens)
function parent_and_child(lens::Setfield.ComposedLens)
    p, child = parent_and_child(lens.inner)
    parent = p === nothing ? lens.outer : lens.outer ∘ p
    return parent, child
end

"""
    splitlens(condition, lens)

Return a 3-tuple `(parent, child, issuccess)` where, if `issuccess` is `true`,
`parent` is a lens such that `condition(parent)` is `true` and `parent ∘ child == lens`.

If `issuccess` is `false`, then no such split could be found.

# Examples
```jldoctest; setup=:(using Setfield; using DynamicPPL: splitlens)
julia> p, c, issucesss = splitlens(@lens(_.a[1])) do parent
           # Succeeds!
           parent == @lens(_.a)
       end
((@lens _.a), (@lens _[1]), true)

julia> p ∘ c
(@lens _.a[1])

julia> splitlens(@lens(_.a[1])) do parent
           # Fails!
           parent == @lens(_.b)
       end
(nothing, (@lens _.a[1]), false)
```
"""
function splitlens(condition, lens)
    current_parent, current_child = parent_and_child(lens)
    # We stop if either a) `condition` is satisfied, or b) we reached the root.
    while !condition(current_parent) && current_parent !== nothing
        current_parent, c = parent_and_child(current_parent)
        current_child = c ∘ current_child
    end

    return current_parent, current_child, condition(current_parent)
end
