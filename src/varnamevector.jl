"""
    VarNameVector

A container that works like a `Vector` and an `OrderedDict` but is neither.

# Fields
$(FIELDS)
"""
struct VarNameVector{
    K<:VarName,V,TVN<:AbstractVector{K},TVal<:AbstractVector{V},TTrans<:AbstractVector,MData
}
    "mapping from the `VarName` to its integer index in `varnames`, `ranges` and `dists`"
    varname_to_index::OrderedDict{K,Int}

    "vector of identifiers for the random variables, where `varnames[varname_to_index[vn]] == vn`"
    varnames::TVN # AbstractVector{<:VarName}

    "vector of index ranges in `vals` corresponding to `varnames`; each `VarName` `vn` has a single index or a set of contiguous indices in `vals`"
    ranges::Vector{UnitRange{Int}}

    "vector of values of all the univariate, multivariate and matrix variables; the value(s) of `vn` is/are `vals[ranges[varname_to_index[vn]]]`"
    vals::TVal # AbstractVector{<:Real}

    "vector of transformations whose inverse takes us back to the original space"
    transforms::TTrans

    "additional entries which are considered inactive"
    num_inactive::OrderedDict{Int,Int}

    "metadata associated with the varnames"
    metadata::MData
end

function ==(vnv_left::VarNameVector, vnv_right::VarNameVector)
    return vnv_left.varname_to_index == vnv_right.varname_to_index &&
           vnv_left.varnames == vnv_right.varnames &&
           vnv_left.ranges == vnv_right.ranges &&
           vnv_left.vals == vnv_right.vals &&
           vnv_left.transforms == vnv_right.transforms &&
           vnv_left.num_inactive == vnv_right.num_inactive &&
           vnv_left.metadata == vnv_right.metadata
end

function VarNameVector(varname_to_index, varnames, ranges, vals, transforms)
    return VarNameVector(
        varname_to_index,
        varnames,
        ranges,
        vals,
        transforms,
        OrderedDict{Int,Int}(),
        nothing,
    )
end
# TODO: Do we need this?
function VarNameVector{K,V}() where {K,V}
    return VarNameVector(OrderedDict{K,Int}(), K[], UnitRange{Int}[], V[], Any[])
end

# Useful transformation going from the flattened representation.
struct FromVec{Sz}
    sz::Sz
end

FromVec(x::Union{Real,AbstractArray}) = FromVec(size(x))

# TODO: Should we materialize the `reshape`?
(f::FromVec)(x) = reshape(x, f.sz)
(f::FromVec{Tuple{}})(x) = only(x)

Bijectors.with_logabsdet_jacobian(f::FromVec, x) = (f(x), 0)

tovec(x::Real) = [x]
tovec(x::AbstractArray) = vec(x)

Bijectors.inverse(f::FromVec) = tovec
Bijectors.inverse(f::FromVec{Tuple{}}) = tovec

# More convenient constructors.
collect_maybe(x) = collect(x)
collect_maybe(x::AbstractArray) = x

VarNameVector() = VarNameVector{VarName,Real}()
VarNameVector(xs::Pair...) = VarNameVector(OrderedDict(xs...))
VarNameVector(x::AbstractDict) = VarNameVector(keys(x), values(x))
VarNameVector(varnames, vals) = VarNameVector(collect_maybe(varnames), collect_maybe(vals))
function VarNameVector(
    varnames::AbstractVector, vals::AbstractVector, transforms=map(FromVec, vals)
)
    # TODO: Check uniqueness of `varnames`?

    # Convert `vals` into a vector of vectors.
    vals_vecs = map(tovec, vals)

    # TODO: Is this really the way to do this?
    if !(eltype(varnames) <: VarName)
        varnames = convert(Vector{VarName}, varnames)
    end
    varname_to_index = OrderedDict{eltype(varnames),Int}()
    ranges = Vector{UnitRange{Int}}()
    offset = 0
    for (i, (vn, x)) in enumerate(zip(varnames, vals_vecs))
        # Add the varname index.
        push!(varname_to_index, vn => length(varname_to_index) + 1)
        # Add the range.
        r = (offset + 1):(offset + length(x))
        push!(ranges, r)
        # Update the offset.
        offset = r[end]
    end

    return VarNameVector(
        varname_to_index, varnames, ranges, reduce(vcat, vals_vecs), transforms
    )
end

"""
    replace_values(vnv::VarNameVector, vals::AbstractVector)

Replace the values in `vnv` with `vals`.

This is useful when we want to update the entire underlying vector of values
in one go or if we want to change the how the values are stored, e.g. alter the `eltype`.

!!! warning
    This replaces the raw underlying values, and so care should be taken when using this
    function. For example, if `vnv` has any inactive entries, then the provided `vals`
    should also contain the inactive entries to avoid unexpected behavior.

# Example

```jldoctest varnamevector-replace-values
julia> using DynamicPPL: VarNameVector, replace_values

julia> vnv = VarNameVector(@varname(x) => [1.0]);

julia> replace_values(vnv, [2.0])[@varname(x)] == [2.0]
true
```

This is also useful when we want to differentiate wrt. the values
using automatic differentiation, e.g. ForwardDiff.jl.

```jldoctest varnamevector-replace-values
julia> using ForwardDiff: ForwardDiff

julia> f(x) = sum(abs2, replace_values(vnv, x)[@varname(x)])
f (generic function with 1 method)

julia> ForwardDiff.gradient(f, [1.0])
1-element Vector{Float64}:
 2.0
```
"""
replace_values(vnv::VarNameVector, vals) = Setfield.@set vnv.vals = vals

# Some `VarNameVector` specific functions.
getidx(vnv::VarNameVector, vn::VarName) = vnv.varname_to_index[vn]

getrange(vnv::VarNameVector, idx::Int) = vnv.ranges[idx]
getrange(vnv::VarNameVector, vn::VarName) = getrange(vnv, getidx(vnv, vn))

gettransform(vnv::VarNameVector, vn::VarName) = vnv.transforms[getidx(vnv, vn)]

"""
    has_inactive(vnv::VarNameVector)

Returns `true` if `vnv` has inactive ranges. 
"""
has_inactive(vnv::VarNameVector) = !isempty(vnv.num_inactive)

"""
    num_inactive(vnv::VarNameVector, vn::VarName)

Returns the number of inactive entries for `vn` in `vnv`.
"""
num_inactive(vnv::VarNameVector, vn::VarName) = num_inactive(vnv, getidx(vnv, vn))
num_inactive(vnv::VarNameVector, idx::Int) = get(vnv.num_inactive, idx, 0)

"""
    num_allocated(vnv::VarNameVector)

Returns the number of allocated entries in `vnv`.
"""
num_allocated(vnv::VarNameVector) = length(vnv.vals)

"""
    num_allocated(vnv::VarNameVector, vn::VarName)

Returns the number of allocated entries for `vn` in `vnv`.
"""
num_allocated(vnv::VarNameVector, vn::VarName) = num_allocated(vnv, getidx(vnv, vn))
function num_allocated(vnv::VarNameVector, idx::Int)
    return length(getrange(vnv, idx)) + num_inactive(vnv, idx)
end

# Basic array interface.
Base.eltype(vnv::VarNameVector) = eltype(vnv.vals)
Base.length(vnv::VarNameVector) =
    if isempty(vnv.num_inactive)
        length(vnv.vals)
    else
        sum(length, vnv.ranges)
    end
Base.size(vnv::VarNameVector) = (length(vnv),)
Base.isempty(vnv::VarNameVector) = isempty(vnv.varnames)

# TODO: We should probably remove this
Base.IndexStyle(::Type{<:VarNameVector}) = IndexLinear()

# Dictionary interface.
Base.keys(vnv::VarNameVector) = vnv.varnames
Base.values(vnv::VarNameVector) = Iterators.map(Base.Fix1(getindex, vnv), vnv.varnames)
Base.pairs(vnv::VarNameVector) = (vn => vnv[vn] for vn in keys(vnv))

Base.haskey(vnv::VarNameVector, vn::VarName) = haskey(vnv.varname_to_index, vn)

# `getindex` & `setindex!`
Base.getindex(vnv::VarNameVector, i::Int) = getindex_raw(vnv, i)
function Base.getindex(vnv::VarNameVector, vn::VarName)
    x = getindex_raw(vnv, vn)
    f = gettransform(vnv, vn)
    return f(x)
end

getindex_raw(vnv::VarNameVector, i::Int) = vnv.vals[i]
function getindex_raw(vnv::VarNameVector, vn::VarName)
    return vnv.vals[getrange(vnv, vn)]
end

# `getindex` for `Colon`
function Base.getindex(vnv::VarNameVector, ::Colon)
    return if has_inactive(vnv)
        mapreduce(Base.Fix1(getindex, vnv.vals), vcat, vnv.ranges)
    else
        vnv.vals
    end
end

function getindex_raw(vnv::VarNameVector, ::Colon)
    return if has_inactive(vnv)
        mapreduce(Base.Fix1(getindex_raw, vnv.vals), vcat, vnv.ranges)
    else
        vnv.vals
    end
end

# HACK: remove this as soon as possible.
Base.getindex(vnv::VarNameVector, spl::AbstractSampler) = vnv[:]

Base.setindex!(vnv::VarNameVector, val, i::Int) = setindex_raw!(vnv, val, i)
function Base.setindex!(vnv::VarNameVector, val, vn::VarName)
    f = inverse(gettransform(vnv, vn))
    return setindex_raw!(vnv, f(val), vn)
end

setindex_raw!(vnv::VarNameVector, val, i::Int) = vnv.vals[i] = val
function setindex_raw!(vnv::VarNameVector, val::AbstractVector, vn::VarName)
    return vnv.vals[getrange(vnv, vn)] = val
end

# `empty!(!)`
function Base.empty!(vnv::VarNameVector)
    # TODO: Or should the semantics be different, e.g. keeping `varnames`?
    empty!(vnv.varname_to_index)
    empty!(vnv.varnames)
    empty!(vnv.ranges)
    empty!(vnv.vals)
    empty!(vnv.transforms)
    empty!(vnv.num_inactive)
    return nothing
end
BangBang.empty!!(vnv::VarNameVector) = (empty!(vnv); return vnv)

function Base.merge(left_vnv::VarNameVector, right_vnv::VarNameVector)
    # Return early if possible.
    isempty(left_vnv) && return deepcopy(right_vnv)
    isempty(right_vnv) && return deepcopy(left_vnv)

    # Determine varnames.
    vns_left = left_vnv.varnames
    vns_right = right_vnv.varnames
    vns_both = union(vns_left, vns_right)

    # Determine `eltype` of `vals`.
    T_left = eltype(left_vnv.vals)
    T_right = eltype(right_vnv.vals)
    T = promote_type(T_left, T_right)
    # TODO: Is this necessary?
    if !(T <: Real)
        T = Real
    end

    # Determine `eltype` of `varnames`.
    V_left = eltype(left_vnv.varnames)
    V_right = eltype(right_vnv.varnames)
    V = promote_type(V_left, V_right)
    if !(V <: VarName)
        V = VarName
    end

    # Determine `eltype` of `transforms`.
    F_left = eltype(left_vnv.transforms)
    F_right = eltype(right_vnv.transforms)
    F = promote_type(F_left, F_right)

    # Allocate.
    varnames_to_index = OrderedDict{V,Int}()
    ranges = UnitRange{Int}[]
    vals = T[]
    transforms = F[]

    # Range offset.
    offset = 0

    for (idx, vn) in enumerate(vns_both)
        # Extract the necessary information from `left` or `right`.
        if vn in vns_left && !(vn in vns_right)
            # `vn` is only in `left`.
            varnames_to_index[vn] = idx
            val = getindex_raw(left_vnv, vn)
            n = length(val)
            r = (offset + 1):(offset + n)
            f = gettransform(left_vnv, vn)
        else
            # `vn` is either in both or just `right`.
            varnames_to_index[vn] = idx
            val = getindex_raw(right_vnv, vn)
            n = length(val)
            r = (offset + 1):(offset + n)
            f = gettransform(right_vnv, vn)
        end
        # Update.
        append!(vals, val)
        push!(ranges, r)
        push!(transforms, f)
        # Increment `offset`.
        offset += n
    end

    return VarNameVector(varnames_to_index, vns_both, ranges, vals, transforms)
end

function subset(vnv::VarNameVector, vns::AbstractVector{<:VarName})
    # NOTE: This does not specialize types when possible.
    vnv_new = similar(vnv)
    # Return early if possible.
    isempty(vnv) && return vnv_new

    for vn in vns
        push!(vnv_new, vn, getval(vnv, vn), gettransform(vnv, vn))
    end

    return vnv_new
end

# `similar`
similar_metadata(::Nothing) = nothing
similar_metadata(x::Union{AbstractArray,AbstractDict}) = similar(x)
function Base.similar(vnv::VarNameVector)
    # NOTE: Whether or not we should empty the underlying containers or note
    # is somewhat ambiguous. For example, `similar(vnv.varname_to_index)` will
    # result in an empty `AbstractDict`, while the vectors, e.g. `vnv.ranges`,
    # will result in non-empty vectors but with entries as `undef`. But it's
    # much easier to write the rest of the code assuming that `undef` is not
    # present, and so for now we empty the underlying containers, thus differing
    # from the behavior of `similar` for `AbstractArray`s.
    return VarNameVector(
        similar(vnv.varname_to_index),
        similar(vnv.varnames, 0),
        similar(vnv.ranges, 0),
        similar(vnv.vals, 0),
        similar(vnv.transforms, 0),
        similar(vnv.num_inactive),
        similar_metadata(vnv.metadata),
    )
end

"""
    is_contiguous(vnv::VarNameVector)

Returns `true` if the underlying data of `vnv` is stored in a contiguous array.

This is equivalent to negating [`has_inactive(vnv)`](@ref).
"""
is_contiguous(vnv::VarNameVector) = !has_inactive(vnv)

function nextrange(vnv::VarNameVector, x)
    # If `vnv` is empty, return immediately.
    isempty(vnv) && return 1:length(x)

    # The offset will be the last range's end + its number of inactive entries.
    vn_last = vnv.varnames[end]
    idx = getidx(vnv, vn_last)
    offset = last(getrange(vnv, idx)) + num_inactive(vnv, idx)

    return (offset + 1):(offset + length(x))
end

# `push!` and `push!!`: add a variable to the varname vector.
function Base.push!(vnv::VarNameVector, vn::VarName, val, transform=FromVec(val))
    # Error if we already have the variable.
    haskey(vnv, vn) && throw(ArgumentError("variable name $vn already exists"))
    # NOTE: We need to compute the `nextrange` BEFORE we start mutating
    # the underlying; otherwise we might get some strange behaviors.
    val_vec = tovec(val)
    r_new = nextrange(vnv, val_vec)
    vnv.varname_to_index[vn] = length(vnv.varname_to_index) + 1
    push!(vnv.varnames, vn)
    push!(vnv.ranges, r_new)
    append!(vnv.vals, val_vec)
    push!(vnv.transforms, transform)
    return nothing
end

"""
    shift_right!(x::AbstractVector{<:Real}, start::Int, n::Int)

Shifts the elements of `x` starting from index `start` by `n` to the right.
"""
function shift_right!(x::AbstractVector{<:Real}, start::Int, n::Int)
    x[(start + n):end] = x[start:(end - n)]
    return x
end

"""
    shift_subsequent_ranges_by!(vnv::VarNameVector, idx::Int, n)

Shifts the ranges of variables in `vnv` starting from index `idx` by `n`.
"""
function shift_subsequent_ranges_by!(vnv::VarNameVector, idx::Int, n)
    for i in (idx + 1):length(vnv.ranges)
        vnv.ranges[i] = vnv.ranges[i] .+ n
    end
    return nothing
end

# `update!` and `update!!`: update a variable in the varname vector.
"""
    update!(vnv::VarNameVector, vn::VarName, val[, transform])

Either add a new entry or update existing entry for  `vn` in `vnv` with the value `val`.

If `vn` does not exist in `vnv`, this is equivalent to [`push!`](@ref).
"""
function update!(vnv::VarNameVector, vn::VarName, val, transform=FromVec(val))
    if !haskey(vnv, vn)
        # Here we just add a new entry.
        return push!(vnv, vn, val, transform)
    end

    # Here we update an existing entry.
    val_vec = tovec(val)
    idx = getidx(vnv, vn)
    # Extract the old range.
    r_old = getrange(vnv, idx)
    start_old, end_old = first(r_old), last(r_old)
    n_old = length(r_old)
    # Compute the new range.
    n_new = length(val_vec)
    start_new = start_old
    end_new = start_old + n_new - 1
    r_new = start_new:end_new

    #=
    Suppose we currently have the following:

      | x | x | o | o | o | y | y | y |    <- Current entries

    where 'O' denotes an inactive entry, and we're going to
    update the variable `x` to be of size `k` instead of 2.

    We then have a few different scenarios:
    1. `k > 5`: All inactive entries become active + need to shift `y` to the right.
        E.g. if `k = 7`, then

          | x | x | o | o | o | y | y | y |            <- Current entries
          | x | x | x | x | x | x | x | y | y | y |    <- New entries

    2. `k = 5`: All inactive entries become active.
        Then

          | x | x | o | o | o | y | y | y |            <- Current entries
          | x | x | x | x | x | y | y | y |            <- New entries

    3. `k < 5`: Some inactive entries become active, some remain inactive.
        E.g. if `k = 3`, then

          | x | x | o | o | o | y | y | y |            <- Current entries
          | x | x | x | o | o | y | y | y |            <- New entries

    4. `k = 2`: No inactive entries become active.
        Then

          | x | x | o | o | o | y | y | y |            <- Current entries
          | x | x | o | o | o | y | y | y |            <- New entries

    5. `k < 2`: More entries become inactive.
        E.g. if `k = 1`, then

          | x | x | o | o | o | y | y | y |            <- Current entries
          | x | o | o | o | o | y | y | y |            <- New entries
    =#

    # Compute the allocated space for `vn`.
    had_inactive = haskey(vnv.num_inactive, idx)
    n_allocated = had_inactive ? n_old + vnv.num_inactive[idx] : n_old

    if n_new > n_allocated
        # Then we need to grow the underlying vector.
        n_extra = n_new - n_allocated
        # Allocate.
        resize!(vnv.vals, length(vnv.vals) + n_extra)
        # Shift current values.
        shift_right!(vnv.vals, end_old + 1, n_extra)
        # No more inactive entries.
        had_inactive && delete!(vnv.num_inactive, idx)
        # Update the ranges for all variables after this one.
        shift_subsequent_ranges_by!(vnv, idx, n_extra)
    elseif n_new == n_allocated
        # => No more inactive entries.
        had_inactive && delete!(vnv.num_inactive, idx)
    else
        # `n_new < n_allocated`
        # => Need to update the number of inactive entries.
        vnv.num_inactive[idx] = n_allocated - n_new
    end

    # Update the range for this variable.
    vnv.ranges[idx] = r_new
    # Update the value.
    vnv.vals[r_new] = val_vec
    # Update the transform.
    vnv.transforms[idx] = transform

    # TODO: Should we maybe sweep over inactive ranges and re-contiguify
    # if we the total number of inactive elements is "large" in some sense?

    return nothing
end

function recontiguify_ranges!(ranges::AbstractVector{<:AbstractRange})
    offset = 0
    for i in 1:length(ranges)
        r_old = ranges[i]
        ranges[i] = (offset + 1):(offset + length(r_old))
        offset += length(r_old)
    end

    return ranges
end

"""
    contiguify!(vnv::VarNameVector)

Re-contiguify the underlying vector and shrink if possible.
"""
function contiguify!(vnv::VarNameVector)
    # Extract the re-contiguified values.
    # NOTE: We need to do this before we update the ranges.
    vals = vnv[:]
    # And then we re-contiguify the ranges.
    recontiguify_ranges!(vnv.ranges)
    # Clear the inactive ranges.
    empty!(vnv.num_inactive)
    # Now we update the values.
    for (i, r) in enumerate(vnv.ranges)
        vnv.vals[r] = vals[r]
    end
    # And (potentially) shrink the underlying vector.
    resize!(vnv.vals, vnv.ranges[end][end])
    # The rest should be left as is.
    return vnv
end

"""
    group_by_symbol(vnv::VarNameVector)

Return a dictionary mapping symbols to `VarNameVector`s with
varnames containing that symbol.
"""
function group_by_symbol(vnv::VarNameVector)
    # Group varnames in `vnv` by the symbol.
    d = OrderedDict{Symbol,Vector{VarName}}()
    for vn in vnv.varnames
        push!(get!(d, getsym(vn), Vector{VarName}()), vn)
    end

    # Create a `NamedTuple` from the grouped varnames.
    nt_vals = map(values(d)) do varnames
        # TODO: Do we need to specialize the inputs here?
        VarNameVector(
            map(identity, varnames),
            map(Base.Fix1(getindex, vnv), varnames),
            map(Base.Fix1(gettransform, vnv), varnames),
        )
    end

    return OrderedDict(zip(keys(d), nt_vals))
end

"""
    shift_index_left!(vnv::VarNameVector, idx::Int)

Shift the index `idx` to the left by one and update the relevant fields.

!!! warning
    This does not check if index we're shifting to is already occupied.
"""
function shift_index_left!(vnv::VarNameVector, idx::Int)
    # Shift the index in the lookup table.
    vn = vnv.varnames[idx]
    vnv.varname_to_index[vn] = idx - 1
    # Shift the index in the inactive ranges.
    if haskey(vnv.num_inactive, idx)
        # Done in increasing order =>  don't need to worry about
        # potentially shifting the same index twice.
        vnv.num_inactive[idx - 1] = pop!(vnv.num_inactive, idx)
    end
end

"""
    shift_subsequent_indices_left!(vnv::VarNameVector, idx::Int)

Shift the indices for all variables after `idx` to the left by one and update
the relevant fields.

This just
"""
function shift_subsequent_indices_left!(vnv::VarNameVector, idx::Int)
    # Shift the indices for all variables after `idx`.
    for idx_to_shift in (idx + 1):length(vnv.varnames)
        shift_index_left!(vnv, idx_to_shift)
    end
end

function Base.delete!(vnv::VarNameVector, vn::VarName)
    # Error if we don't have the variable.
    !haskey(vnv, vn) && throw(ArgumentError("variable name $vn does not exist"))

    # Get the index of the variable.
    idx = getidx(vnv, vn)

    # Delete the values.
    r_start = first(getrange(vnv, idx))
    n_allocated = num_allocated(vnv, idx)
    # NOTE: `deleteat!` also results in a `resize!` so we don't need to do that.
    deleteat!(vnv.vals, r_start:(r_start + n_allocated - 1))

    # Delete `vn` from the lookup table.
    delete!(vnv.varname_to_index, vn)

    # Delete any inactive ranges corresponding to `vn`.
    haskey(vnv.num_inactive, idx) && delete!(vnv.num_inactive, idx)

    # Re-adjust the indices for varnames occuring after `vn` so
    # that they point to the correct indices after the deletions below.
    shift_subsequent_indices_left!(vnv, idx)

    # Re-adjust the ranges for varnames occuring after `vn`.
    shift_subsequent_ranges_by!(vnv, idx, -n_allocated)

    # Delete references from vector fields, thus shifting the indices of
    # varnames occuring after `vn` by one to the left, as we adjusted for above.
    deleteat!(vnv.varnames, idx)
    deleteat!(vnv.ranges, idx)
    deleteat!(vnv.transforms, idx)

    return vnv
end

"""
    values_as(vnv::VarNameVector[, T])

Return the values/realizations in `vnv` as type `T`, if implemented.

If no type `T` is provided, return values as stored in `vnv`.

# Examples

```jldoctest
julia> using DynamicPPL: VarNameVector

julia> vnv = VarNameVector(@varname(x) => 1, @varname(y) => [2.0]);

julia> values_as(vnv) == [1.0, 2.0]
true

julia> values_as(vnv, Vector{Float32}) == Vector{Float32}([1.0, 2.0])
true

julia> values_as(vnv, OrderedDict) == OrderedDict(@varname(x) => 1.0, @varname(y) => [2.0])
true

julia> values_as(vnv, NamedTuple) == (x = 1.0, y = [2.0])
true
```
"""
values_as(vnv::VarNameVector) = values_as(vnv, Vector)
values_as(vnv::VarNameVector, ::Type{Vector}) = vnv[:]
function values_as(vnv::VarNameVector, ::Type{Vector{T}}) where {T}
    return convert(Vector{T}, values_as(vnv, Vector))
end
function values_as(vnv::VarNameVector, ::Type{NamedTuple})
    return NamedTuple(zip(map(Symbol, keys(vnv)), values(vnv)))
end
function values_as(vnv::VarNameVector, ::Type{D}) where {D<:AbstractDict}
    return ConstructionBase.constructorof(D)(pairs(vnv))
end
