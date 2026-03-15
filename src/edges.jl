abstract type Edge{T} end

@def add_generic_fields begin
    Ai::Vector{Int}
end
Base.length(e::Edge) = length(e.Ai)

function find_arb! end
is_nonsmooth(::Edge) = false

# Edge with gain function
struct EdgeGain{T,H} <: Edge{T}
    Ai::Vector{Int}
    h::H
    ub::T
end

# Edge with closed form solution
struct EdgeClosedForm{T,H,W} <: Edge{T}
    Ai::Vector{Int}
    h::H
    ub::T
    wstar::W
end
function Edge(
    inds::Tuple{Int, Int};
    h,
    ub::T,
    wstar=nothing,
) where T
    Ai = collect(Int, inds)

    isnothing(wstar) && return EdgeGain(Ai, h, ub)

    return EdgeClosedForm(Ai, h, ub, wstar)
end


function find_arb!(
    xs::Vector{V},
    ν::Vector{T}, 
    edges::Vector{<: Edge}
) where {T, V <: Vector{T}}

    Threads.@threads for i in 1:length(edges)
        find_arb!(xs[i], edges[i], view(ν, edges[i].Ai))
    end

    return nothing
end


function find_arb!(x::Vector{T}, e::EdgeGain{T,H}, ν::AbstractVector{T}) where {T,H}
    find_arb!(x, e, ν[1] / ν[2])
end

function find_arb!(x::Vector{T}, e::EdgeClosedForm{T,H,W}, ν::AbstractVector{T}) where {T,H,W}
    find_arb!(x, e, ν[1] / ν[2])
end

function find_arb!(x::Vector{T}, e::EdgeClosedForm{T,H,W}, ratio::T) where {T,H,W}
    x[1] = -e.wstar(ratio)
    x[2] = e.h(-x[1])
    return nothing
end

# let x = (-x₁, h(x₁)) be the solution to h'(x₁) - η₁/η₂ = 0
# ratio = η₁/η₂
function find_arb!(x::Vector{T}, e::EdgeGain{T,H}, ratio::T) where {T,H}
    # Truncated Netwon's method
    p_min = ForwardDiff.derivative(e.h, e.ub)
    p_max = ForwardDiff.derivative(e.h, 0.0)
    if isinf(ratio) || ratio ≥ p_max
        x[1] = 0.0
        x[2] = e.h(0.0)
        return nothing
    elseif ratio ≤ p_min
        x[1] = -e.ub
        x[2] = e.h(e.ub)
        return nothing
    end
    
    x[1] = e.ub / 2
    for _ in 1:20
        dh = ForwardDiff.derivative(e.h, x[1])
        d2h = ForwardDiff.derivative(x -> ForwardDiff.derivative(e.h, x), x[1])
        Δ = (ratio - dh) / d2h
        x[1] += Δ
        x[1] = clamp(x[1], 0.0, e.ub)

        abs(Δ) ≤ 1e-8 && break
    end

    x[1] = -x[1]
    x[2] = e.h(-x[1])
    return nothing
end
