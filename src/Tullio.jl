module Tullio

export @tullio, @moltullio

using MacroTools, GPUifyLoops

const UNROLLOK = VERSION >= v"1.2.0-DEV.462"

"""
    @tullio A[i,j] := B[i] * log(C[j])
    @moltullio A[i,j] := B[i] * log(C[j])

This loops over all indices, but unlike `@einsum`/`@vielsum` the idea is to experiment with
map/generator expressions, GPUifyLoops.jl, and loop unrolling...

    @tullio A[i] := B[i,j] * C[k]                            # implicit sum over j
    @tullio A[i] := B[i,j] * C[k]  (+, j,k)                  # explicit sum, must give all indices
    @tullio A[i] := B[i,j] * C[k]  (+, j, unroll(4), k)      # unrolled by 4 only k loop, innermost
    @tullio A[i] := B[i,j] * C[k]  (+, unroll, j<=10, k<=10) # completely unroll j and k

Reduction by summing over `j`, but with all the same things.
"""
macro tullio(exs...)
    _tullio(exs...)
end

macro moltullio(exs...)
    _tullio(exs...; multi=true)
end

function _tullio(leftright, after=nothing; multi=false)

    @capture(leftright, left_ += right_ ) &&
        return _tullio(:($left = $left + $right); after=after, multi=multi)
    @capture(leftright, left_ -= right_ ) &&
        return _tullio(:($left = $left - ($right) ); after=after, multi=multi)
    @capture(leftright, left_ *= right_ ) &&
        return _tullio(:($left = $left * ($right) ); after=after, multi=multi)

    #===== parse input =====#

    # TODO catch primes here

    store = (axes=Dict(), flags=Set(), checks=[], arrays=[], rightind=[],
        redop=Ref(:+), loop=[], unroll=[], rolln=Ref(0), init=Ref{Any}(:(zero(T))),)

    newarray = @capture(leftright, left_ := right_ )
    newarray || @capture(leftright, left_ = right_ ) || error("wtf?")

    @capture(left, Z_[leftind__] | [leftind__] ) || error("can't understand LHS")
    isnothing(Z) && @gensym Z

    readred(after, store)

    MacroTools.postwalk(rightwalk(store), right)
    unique!(store.arrays)
    unique!(store.rightind)
    redind = setdiff(store.rightind, leftind)

    isempty(store.loop) && isempty(store.unroll) ?
        append!(store.loop, redind) :
        @assert sort(redind) == sort(vcat(store.loop, store.unroll)) "if you give any reduction indices, you must give them all"

    isempty(store.unroll) || UNROLLOK ||
        @warn "can't unroll loops on Julia $VERSION" maxlog=1 _id=hash(leftright)

    #===== preliminary expressions =====#

    outex = quote end

    push!(outex.args, :( local @inline g($(store.rightind...), $(store.arrays...)) = begin @inbounds $right end))

    append!(outex.args, store.checks)

    if newarray
        allone = map(_->1, store.rightind)
        push!(outex.args, :( local T = typeof(g($(allone...), $(store.arrays...))) ))
    else
        push!(outex.args, :( local T = eltype($Z) ))
    end

    if isempty(redind)
         rex = :( @inbounds $Z[$(leftind...)] = g($(leftind...), $(store.arrays...)) )
    else
        #===== reduction function f(i,j,A,B) = sum(g(i,j,k,l,A,B)) =====#
        if multi
            push!(outex.args, :(local cache = Vector{T}(undef, Threads.nthreads()) ))
            σ, cache = :( cache[Threads.threadid()] ), [:cache]
        else
            σ, cache = :σ, []
        end

        ex = :( $σ = $(store.redop[])($σ, g($(store.rightind...), $(store.arrays...)) ) )
        ex = recurseloops(ex, store)
        ex = :( $σ = $(store.init[]); $ex; return $σ; )
        multi && (ex = :(@inbounds $ex) )
        ex = :( local f($(leftind...), $(store.arrays...), ::Val{T}, $(cache...)) where {T} = $ex)
        push!(outex.args, ex)

        rex = :( @inbounds $Z[$(leftind...)] = f($(leftind...), $(store.arrays...), Val(T), $(cache...)) )
    end

    #===== final loops =====#

    if newarray
        Zsize = map(i -> :(length($(store.axes[i]))), leftind)
        push!(outex.args, :( $Z = Array{T,$(length(leftind))}(undef, $(Zsize...)) ))
    end

    ex = recurseloops(rex, (axes=store.axes, loop=leftind, unroll=[], rolln=Ref(0)))
    if multi
        push!(outex.args, :( Threads.@threads $ex ))
    else
        push!(outex.args, ex)
    end

    push!(outex.args, Z)

    esc(outex)
end

#===== ingestion =====#

rightwalk(store) = ex -> begin
        @capture(ex, A_[inds__]) || return ex
        push!(store.arrays, A)
        append!(store.rightind, filter(i -> i isa Symbol, inds))
        saveaxes(A, inds, store, true)
    end

saveaxes(A, inds, store, onright) =
    for (d,i) in enumerate(inds)
        i isa Symbol || continue
        if haskey(store.axes, i)
            str = "range of index $i must agree"
            push!(store.checks, :( @assert $(store.axes[i]) == axes($A,$d) $str ))
        else
            store.axes[i] = :( axes($A,$d) )
        end
        if onright
            push!(store.rightind, i)
        end
    end

readred(ex::Nothing, store) = nothing
readred(ex, store) =
    if @capture(ex, (op_Symbol, inds__,)) ||  @capture(ex, op_Symbol)
        store.redop[] = op
        store.init[] = op == :* ? :(one(T)) :
            op == :max ? :(typemin(T)) :
            op == :min ? :(typemin(T)) :
            :(zero(T))
        foreach(savered(store), something(inds,[]))
    else
        error("expected something like (+,i,j,unroll,k) but got $ex")
    end

savered(store) = i ->
    if i == :unroll
        push!(store.flags, :unroll)
    elseif @capture(i, unroll(n_Int))
        push!(store.flags, :unroll)
        store.rolln[] = n

    elseif i isa Symbol
        unrollpush(store, i)
    elseif @capture(i, j_ <= m_)
        unrollpush(store, j)
        store.axes[j] = :( Base.OneTo($m) )
    elseif @capture(i, n_ <= j_ <= m_)
        unrollpush(store, j)
        store.axes[j] = :( $n:$m )

    elseif  @capture(i, init = z_)
        store.init[] = z==0 ? :(zero(T)) : z==1 ? :(one(T)) : z
    else
        @warn "wtf is index $i"
    end

unrollpush(store, i) = (:unroll in store.flags) ? push!(store.unroll, i) : push!(store.loop, i)

#===== digestion =====#

recurseloops(ex, store) =
    if !isempty(store.unroll)
        i = pop!(store.unroll)

        r = store.axes[i]
        ex = iszero(store.rolln[]) ?
            :(@unroll for $i in $r; $ex; end) :
            :(@unroll $(store.rolln[]) for $i in $r; $ex; end)
        return recurseloops(ex, store)

    elseif !isempty(store.loop)
        i = pop!(store.loop)
        r = store.axes[i]
        ex = :(for $i in $r; $ex; end)
        return recurseloops(ex, store)

    else
        return ex
    end

#===== action =====#

struct UndefArray{T,N} end

UndefArray{T,N}(ax...) where {T,N} = Array{T,N}(undef, map(length, ax)...)


#= === TODO ===

Damn, now it's slow again.
Do I need a function f? Maybe it should go directly into the loops.
Should left indices always be outermost loops?
Perhaps they should all be treated together...

* Perhaps make one more function k!(Z, A,B,C)
* GPUifyloops -- can this do threading for me?

* index shifts including reverse should be easy to allow, adjust the ranges... but not yet.
* constant indices A[i,3,$k] will be easy

=#
end # module
