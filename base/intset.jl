# This file is a part of Julia. License is MIT: https://julialang.org/license

struct IntSet <: AbstractSet{Int}
    bits::BitVector
    IntSet() = new(sizehint!(falses(0), 256))
end

"""
    IntSet([itr])

Construct a sorted set of positive `Int`s generated by the given iterable object, or an
empty set. Implemented as a bit string, and therefore designed for dense integer sets. Only
`Int`s greater than 0 can be stored. If the set will be sparse (for example holding a few
very large integers), use [`Set`](@ref) instead.
"""
IntSet(itr) = union!(IntSet(), itr)

eltype(::Type{IntSet}) = Int
similar(s::IntSet) = IntSet()
copy(s1::IntSet) = copy!(IntSet(), s1)
function copy!(dest::IntSet, src::IntSet)
    resize!(dest.bits, length(src.bits))
    copy!(dest.bits, src.bits)
    dest
end
eltype(s::IntSet) = Int
sizehint!(s::IntSet, n::Integer) = (n > length(s.bits) && _resize0!(s.bits, n); s)

# An internal function for setting the inclusion bit for a given integer n >= 0
@inline function _setint!(s::IntSet, idx::Integer, b::Bool)
    if idx > length(s.bits)
        b || return s # setting a bit to zero outside the set's bits is a no-op
        _resize0!(s.bits, idx)
    end
    @inbounds s.bits[idx] = b
    s
end

# An internal function to resize a bitarray and ensure the newly allocated
# elements are zeroed (will become unnecessary if this behavior changes)
@inline function _resize0!(b::BitVector, newlen::Integer)
    len = length(b)
    newlen = ((newlen+63) >> 6) << 6 # smallest multiple of 64 >= newlen
    resize!(b, newlen)
    len < newlen && @inbounds b[len+1:newlen] = false # resize! gives dirty memory
    b
end

# An internal function that takes a pure function `f` and maps across two BitArrays
# allowing the lengths to be different and altering b1 with the result
# WARNING: the assumptions written in the else clauses must hold
function _matched_map!(f, b1::BitArray, b2::BitArray)
    l1, l2 = length(b1), length(b2)
    _bit_map!(f, b1, b2)
    if l1 < l2
        if f(false, false) == f(false, true) == false
            # We don't need to worry about the trailing bits — they're all false
        else # @assert f(false, x) == x
            resize!(b1, l2)
            chk_offs = 1+l1>>6
            unsafe_copy!(b1.chunks, chk_offs, b2.chunks, chk_offs, 1+l2>>6-chk_offs)
        end
    elseif l1 > l2
        if f(false, false) == f(true, false) == false
            # We don't need to worry about the trailing bits — they're all false
            resize!(b1, l2)
        else # @assert f(x, false) == x
            # We don't need to worry about the trailing bits — they already have the
            # correct value
        end
    end
    b1
end

# similar to bit_map! in bitarray.jl, but lengths are multiple of 64,
# and may not match
function _bit_map!(f, b1::BitArray, b2::BitArray)
    b1c, b2c = b1.chunks, b2.chunks
    l = min(length(b1c), length(b2c))
    @inbounds for i = 1:l
        b1c[i] = f(b1c[i], b2c[i])
    end
    b1
end

@noinline _throw_intset_bounds_err() = throw(ArgumentError("elements of IntSet must be between 1 and typemax(Int)"))
@noinline _throw_keyerror(n) = throw(KeyError(n))

@inline function push!(s::IntSet, n::Integer)
    0 < n <= typemax(Int) || _throw_intset_bounds_err()
    _setint!(s, n, true)
end
push!(s::IntSet, ns::Integer...) = (for n in ns; push!(s, n); end; s)

@inline function pop!(s::IntSet)
    pop!(s, last(s))
end
@inline function pop!(s::IntSet, n::Integer)
    n in s ? (_delete!(s, n); n) : _throw_keyerror(n)
end
@inline function pop!(s::IntSet, n::Integer, default)
    n in s ? (_delete!(s, n); n) : default
end
@inline _delete!(s::IntSet, n::Integer) = _setint!(s, n, false)
@inline delete!(s::IntSet, n::Integer) = n > 0 ? _delete!(s, n) : s
shift!(s::IntSet) = pop!(s, first(s))

empty!(s::IntSet) = (fill!(s.bits, false); s)
isempty(s::IntSet) = !any(s.bits)

# Mathematical set functions: union!, intersect!, setdiff!, symdiff!

union(s::IntSet, sets...) = union!(copy(s), sets...)
union!(s1::IntSet, s2::IntSet) = (_matched_map!(|, s1.bits, s2.bits); s1)

intersect(s1::IntSet, s2::IntSet) =
    length(s1.bits) < length(s2.bits) ? intersect!(copy(s1), s2) : intersect!(copy(s2), s1)

intersect!(s1::IntSet, s2::IntSet) = (_matched_map!(&, s1.bits, s2.bits); s1)

setdiff!(s1::IntSet, s2::IntSet) = (_matched_map!((p, q) -> p & ~q, s1.bits, s2.bits); s1)

symdiff!(s::IntSet, ns) = foldl(symdiff!, s, ns)

function symdiff!(s::IntSet, n::Integer)
    0 < n < typemax(Int) || _throw_intset_bounds_err()
    val = !(n in s)
    _setint!(s, n, val)
    s
end

symdiff!(s1::IntSet, s2::IntSet) = (_matched_map!(xor, s1.bits, s2.bits); s1)

filter!(f, s::IntSet) = unsafe_filter!(f, s)

@inline in(n::Integer, s::IntSet) = get(s.bits, n, false)

# Use the next-set index as the state to prevent looking it up again in done
start(s::IntSet) = next(s, 0)[2]
function next(s::IntSet, i)
    nextidx = i == typemax(Int) ? 0 : findnext(s.bits, i+1)
    (i, nextidx)
end
done(s::IntSet, i) = i <= 0


@noinline _throw_intset_notempty_error() = throw(ArgumentError("collection must be non-empty"))

function first(s::IntSet)
    idx = findfirst(s.bits)
    idx == 0 ? _throw_intset_notempty_error() : idx
end

function last(s::IntSet)
    idx = findprev(s.bits, length(s.bits))
    idx == 0 ? _throw_intset_notempty_error() : idx
end

length(s::IntSet) = sum(s.bits)

function show(io::IO, s::IntSet)
    print(io, "IntSet([")
    first = true
    for n in s
        !first && print(io, ", ")
        print(io, n)
        first = false
    end
    print(io, "])")
end

function ==(s1::IntSet, s2::IntSet)
    l1 = length(s1.bits)
    l2 = length(s2.bits)
    # If the lengths are the same, simply punt to bitarray comparison
    l1 == l2 && return s1.bits == s2.bits

    # Swap so s1 is always longer
    if l1 < l2
        s2, s1 = s1, s2
        l2, l1 = l1, l2
    end
    # Iteratively check the chunks of the bitarrays
    c1 = s1.bits.chunks
    c2 = s2.bits.chunks
    @inbounds for i in 1:length(c2)
        c1[i] == c2[i] || return false
    end
    # Ensure remaining chunks are zero
    @inbounds for i in length(c2)+1:length(c1)
        c1[i] == UInt64(0) || return false
    end
    return true
end

issubset(a::IntSet, b::IntSet) = isequal(a, intersect(a,b))
<(a::IntSet, b::IntSet) = (a<=b) && !isequal(a,b)
<=(a::IntSet, b::IntSet) = issubset(a, b)

const hashis_seed = UInt === UInt64 ? 0x88989f1fc7dea67d : 0xc7dea67d
function hash(s::IntSet, h::UInt)
    h ⊻= hashis_seed
    bc = s.bits.chunks
    i = length(bc)
    while i > 0 && bc[i] == UInt64(0)
        # Skip trailing empty bytes to prevent extra space from changing the hash
        i -= 1
    end
    while i > 0
        h = hash(bc[i], h)
        i -= 1
    end
    h
end

minimum(s::IntSet) = first(s)
maximum(s::IntSet) = last(s)
extrema(s::IntSet) = (first(s), last(s))
issorted(s::IntSet) = true
