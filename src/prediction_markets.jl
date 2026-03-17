struct ProductTwoCoin{T} <: Edge{T}
    R::Vector{T}
    γ::T
    Ai::Vector{Int}

    function ProductTwoCoin(R, γ, Ai)
        length(R) == 2 || throw(ArgumentError("R must have length 2"))
        length(Ai) == 2 || throw(ArgumentError("Ai must have length 2"))

        T = eltype(R) <: Integer ? Float64 : eltype(R)
        return new{T}(convert.(T, collect(R)), convert(T, γ), collect(Int, Ai))
    end
end

@inline prod_arb_δ(m, r, k, γ) = max(sqrt(γ * m * k) - r, 0) / γ
@inline prod_arb_λ(m, r, k, γ) = max(r - sqrt(k / (m * γ)), 0)

function find_arb!(x::Vector{T}, e::ProductTwoCoin{T}, η::AbstractVector{T}) where T
    R, γ = e.R, e.γ
    k = R[1] * R[2]

    x[1] = prod_arb_λ(η[1] / η[2], R[1], k, γ) - prod_arb_δ(η[2] / η[1], R[1], k, γ)
    x[2] = prod_arb_λ(η[2] / η[1], R[2], k, γ) - prod_arb_δ(η[1] / η[2], R[2], k, γ)
    return nothing
end

mutable struct UniV3{T} <: Edge{T}
    current_price::T
    current_tick::Int
    lower_ticks::Vector{T}
    liquidity::Vector{T}
    γ::T
    Ai::Vector{Int}

    function UniV3(current_price, lower_ticks, liquidity, γ, Ai)
        length(Ai) == 2 || throw(ArgumentError("Ai must have length 2"))
        length(lower_ticks) == length(liquidity) || throw(ArgumentError("tick and liquidity arrays must match"))
        isempty(lower_ticks) && throw(ArgumentError("tick and liquidity arrays must be nonempty"))

        T = promote_type(
            Float64,
            typeof(float(current_price)),
            typeof(float(γ)),
            Base.promote_op(float, eltype(lower_ticks)),
            Base.promote_op(float, eltype(liquidity)),
        )
        price = convert(T, current_price)
        ticks = convert.(T, collect(lower_ticks))
        liq = convert.(T, collect(liquidity))
        fee = convert(T, γ)

        isfinite(price) && price > zero(T) || throw(ArgumentError("current_price must be finite and positive"))
        isfinite(fee) && zero(T) < fee <= one(T) || throw(ArgumentError("fee multiplier must lie in (0, 1]"))
        all(isfinite, ticks) || throw(ArgumentError("tick prices must be finite"))
        all(isfinite, liq) || throw(ArgumentError("liquidity must be finite"))
        all(ticks .> zero(T)) || throw(ArgumentError("tick prices must be strictly positive"))
        all(liq .>= zero(T)) || throw(ArgumentError("liquidity must be nonnegative"))
        issorted(ticks; rev=true) || throw(ArgumentError("tick prices must be sorted in descending order"))
        any(i -> ticks[i] == ticks[i + 1], 1:max(length(ticks) - 1, 0)) &&
            throw(ArgumentError("tick prices must be strictly decreasing"))
        price <= ticks[1] || throw(ArgumentError("current_price must lie within the represented tick range"))
        current_tick = searchsortedlast(ticks, price, rev=true)
        current_tick == 0 && throw(ArgumentError("current_price must lie within the represented tick range"))
        return new{T}(
            price,
            current_tick,
            ticks,
            liq,
            fee,
            collect(Int, Ai),
        )
    end
end

struct BoundedProduct{T}
    k::T
    α::T
    β::T
    R_1::T
    R_2::T
end

tick_high_price(cfmm::UniV3{T}, idx) where T = cfmm.lower_ticks[idx]

function tick_low_price(cfmm::UniV3{T}, idx) where T
    idx < length(cfmm.lower_ticks) && return cfmm.lower_ticks[idx + 1]
    return zero(T)
end

max_price(t::BoundedProduct{T}) where T = t.α > 0 ? t.k / (t.α^2) : typemax(T)
min_price(t::BoundedProduct{T}) where T = t.k > 0 ? (t.β^2) / t.k : zero(T)
curr_price(t::BoundedProduct{T}) where T = (t.R_2 + t.β) / (t.R_1 + t.α)
is_empty_pool(t::BoundedProduct{T}) where T = iszero(t.k)
flip_sides(t::BoundedProduct{T}) where T = BoundedProduct{T}(t.k, t.β, t.α, t.R_2, t.R_1)

function compute_at_tick(cfmm::UniV3{T}, idx) where T
    k = cfmm.liquidity[idx]
    pminus = tick_low_price(cfmm, idx)
    pplus = tick_high_price(cfmm, idx)
    α = sqrt(k / pplus)
    β = sqrt(k * pminus)

    if idx > cfmm.current_tick
        p = pplus
    elseif idx < cfmm.current_tick
        p = pminus
    else
        p = cfmm.current_price
    end

    R_1 = sqrt(k / p) - α
    R_2 = sqrt(k * p) - β

    return BoundedProduct{T}(k, α, β, R_1, R_2)
end

get_upper_pools(cfmm::UniV3{T}) where T = (compute_at_tick(cfmm, i) for i in cfmm.current_tick:length(cfmm.lower_ticks))
get_lower_pools(cfmm::UniV3{T}) where T = (compute_at_tick(cfmm, i) for i in cfmm.current_tick:-1:1)

function find_arb_pos(t::BoundedProduct{T}, price) where T
    δ = sqrt(t.k / price) - (t.R_1 + t.α)

    if δ <= 0
        return zero(T), zero(T)
    end

    δ_max = t.k / t.β - (t.R_1 + t.α)
    if δ >= δ_max
        return δ_max, t.R_2
    end

    λ = (t.R_2 + t.β) - sqrt(price * t.k)
    return δ, λ
end

function find_arb!(x::Vector{T}, cfmm::UniV3{T}, η::AbstractVector{T}) where T
    p = η[1] / η[2]
    γ = cfmm.γ

    fill!(x, zero(T))

    if γ * cfmm.current_price <= p <= cfmm.current_price / γ
        return nothing
    end

    if p < γ * cfmm.current_price
        δ_total = zero(T)
        λ_total = zero(T)
        initial = true
        for pool in get_upper_pools(cfmm)
            if is_empty_pool(pool)
                initial = false
                continue
            end

            δ, λ = find_arb_pos(pool, p / γ)
            if !initial && (iszero(δ) || iszero(λ))
                break
            end

            δ_total += δ
            λ_total += λ
            initial = false
        end

        x[1] = -δ_total / γ
        x[2] = λ_total
    else
        δ_total = zero(T)
        λ_total = zero(T)
        initial = true
        for pool in flip_sides.(get_lower_pools(cfmm))
            if is_empty_pool(pool)
                initial = false
                continue
            end

            δ, λ = find_arb_pos(pool, inv(γ * p))
            if !initial && (iszero(δ) || iszero(λ))
                break
            end

            δ_total += δ
            λ_total += λ
            initial = false
        end

        x[1] = λ_total
        x[2] = -δ_total / γ
    end

    return nothing
end

"""
    SplitMergeEdge(Ai, B; μ=0)

Fee-free mint/merge hyperedge with local node ordering `[collateral, outcomes...]`.
`Ai[1]` must be the collateral node, and `Ai[2:end]` must be the outcome nodes.

When `μ > 0`, the support function is Moreau-Yosida smoothed (thesis §5):
`f_sm^μ(η) = max_{w∈[-B,B]} {w·gap - μ/2·w²}`, giving oracle `w = clamp(gap/μ, -B, B)`.
This makes the dual C¹ and steers the solver to L-BFGS-B.
"""
struct SplitMergeEdge{T} <: Edge{T}
    Ai::Vector{Int}
    B::T
    μ::T

    function SplitMergeEdge(Ai, B; μ=0)
        length(Ai) >= 3 || throw(ArgumentError("SplitMergeEdge requires local ordering [collateral, outcomes...] with at least two outcomes"))
        T = promote_type(B isa Integer ? Float64 : typeof(float(B)), typeof(float(μ)))
        mu = convert(T, μ)
        mu >= zero(T) || throw(ArgumentError("smoothing parameter μ must be nonnegative"))
        return new{T}(collect(Int, Ai), convert(T, B), mu)
    end
end

is_nonsmooth(e::SplitMergeEdge) = iszero(e.μ)

splitmerge_gap(η::AbstractVector{T}) where T = sum(@view η[2:end]) - η[1]

function splitmerge_flow!(x::AbstractVector{T}, e::SplitMergeEdge{T}, w::T) where T
    x[1] = -w
    @views x[2:end] .= w
    return nothing
end

function find_arb!(x::Vector{T}, e::SplitMergeEdge{T}, η::AbstractVector{T}) where T
    gap = splitmerge_gap(η)
    if iszero(e.μ)
        # Exact (nonsmooth) bang-bang oracle: support function of T_sm
        tol = sqrt(eps(T))
        if gap > tol
            splitmerge_flow!(x, e, e.B)
        elseif gap < -tol
            splitmerge_flow!(x, e, -e.B)
        else
            fill!(x, zero(T))
        end
    else
        # Moreau-Yosida smoothed oracle: w* = clamp(gap/μ, -B, B)
        w = clamp(gap / e.μ, -e.B, e.B)
        abs(w) < sqrt(eps(T)) ? fill!(x, zero(T)) : splitmerge_flow!(x, e, w)
    end
    return nothing
end

function recover_splitmerge_flow!(
    x::AbstractVector{T},
    e::SplitMergeEdge{T},
    η::AbstractVector{T},
    residual::AbstractVector{T},
    fixed::Union{Nothing,AbstractVector{Bool}}=nothing;
    current_flow::Union{Nothing,AbstractVector{T}}=nothing,
    lower_bounds::Union{Nothing,AbstractVector{T}}=nothing,
    tol::T=sqrt(eps(T)),
) where T
    gap = splitmerge_gap(η)
    # The gap is a sum of length(η) terms, each with O(tol) noise from BFGS
    # convergence. Scale the gap tolerance by the number of terms to avoid
    # false snapping when the gap is at noise level.
    gap_tol = tol * convert(T, length(η))
    if gap > gap_tol
        splitmerge_flow!(x, e, e.B)
        return e.B
    elseif gap < -gap_tol
        splitmerge_flow!(x, e, -e.B)
        return -e.B
    end

    num = zero(T)
    den = zero(T)
    for i in eachindex(residual)
        if !isnothing(fixed) && !fixed[i]
            continue
        end
        d = i == 1 ? -one(T) : one(T)
        num += d * residual[i]
        den += one(T)
    end

    if iszero(den)
        num = -residual[1] + sum(@view residual[2:end])
        den = convert(T, length(residual))
    end

    wlo = -e.B
    whi = e.B
    if !isnothing(current_flow) && !isnothing(lower_bounds)
        if isfinite(lower_bounds[1])
            whi = min(whi, current_flow[1] - lower_bounds[1])
        end
        for i in 2:length(current_flow)
            if isfinite(lower_bounds[i])
                wlo = max(wlo, lower_bounds[i] - current_flow[i])
            end
        end
    end

    if wlo > whi
        w = clamp(num / den, -e.B, e.B)
    else
        w = clamp(num / den, wlo, whi)
    end
    splitmerge_flow!(x, e, w)
    return w
end
