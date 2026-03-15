
# parameters
edge_tol = 1e-6
Random.seed!(1)

@inline ref_prod_arb_δ(m, r, k, γ) = max(sqrt(γ * m * k) - r, 0) / γ
@inline ref_prod_arb_λ(m, r, k, γ) = max(r - sqrt(k / (m * γ)), 0)

function reference_product_flow(R, γ, η)
    k = R[1] * R[2]
    return [
        ref_prod_arb_λ(η[1] / η[2], R[1], k, γ) - ref_prod_arb_δ(η[2] / η[1], R[1], k, γ),
        ref_prod_arb_λ(η[2] / η[1], R[2], k, γ) - ref_prod_arb_δ(η[1] / η[2], R[2], k, γ),
    ]
end

struct RefBoundedProduct{T}
    k::T
    α::T
    β::T
    R_1::T
    R_2::T
end

ref_tick_high_price(lower_ticks, idx) = lower_ticks[idx]
ref_tick_low_price(lower_ticks, idx) = idx < length(lower_ticks) ? lower_ticks[idx + 1] : zero(eltype(lower_ticks))
ref_is_empty_pool(t::RefBoundedProduct{T}) where T = iszero(t.k)
ref_flip_sides(t::RefBoundedProduct{T}) where T = RefBoundedProduct{T}(t.k, t.β, t.α, t.R_2, t.R_1)

function ref_compute_at_tick(current_price, current_tick, lower_ticks, liquidity, idx)
    k = liquidity[idx]
    pminus = ref_tick_low_price(lower_ticks, idx)
    pplus = ref_tick_high_price(lower_ticks, idx)
    α = sqrt(k / pplus)
    β = sqrt(k * pminus)

    p = if idx > current_tick
        pplus
    elseif idx < current_tick
        pminus
    else
        current_price
    end

    R_1 = sqrt(k / p) - α
    R_2 = sqrt(k * p) - β
    return RefBoundedProduct(k, α, β, R_1, R_2)
end

function ref_find_arb_pos(t::RefBoundedProduct{T}, price) where T
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

function reference_univ3_flow(current_price, lower_ticks, liquidity, γ, η)
    p = η[1] / η[2]
    x = zeros(eltype(lower_ticks), 2)
    current_tick = searchsortedlast(lower_ticks, current_price, rev=true)

    if γ * current_price <= p <= current_price / γ
        return x
    end

    if p < γ * current_price
        δ_total = zero(eltype(lower_ticks))
        λ_total = zero(eltype(lower_ticks))
        initial = true
        for idx in current_tick:length(lower_ticks)
            pool = ref_compute_at_tick(current_price, current_tick, lower_ticks, liquidity, idx)
            if ref_is_empty_pool(pool)
                initial = false
                continue
            end
            δ, λ = ref_find_arb_pos(pool, p / γ)
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
        δ_total = zero(eltype(lower_ticks))
        λ_total = zero(eltype(lower_ticks))
        initial = true
        for idx in current_tick:-1:1
            pool = ref_flip_sides(ref_compute_at_tick(current_price, current_tick, lower_ticks, liquidity, idx))
            if ref_is_empty_pool(pool)
                initial = false
                continue
            end
            δ, λ = ref_find_arb_pos(pool, inv(γ * p))
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

    return x
end


# TODO: test piecewise linear function
@testset "nonlinear" begin

    @testset "quadratic" begin
        ub = 1.0
        h(w) = 2w - w^2
        dh(w) = 2 - 2w
        wstar(ηrat, ub) = ηrat ≥ 2.0 ? 0.0 : min(1 - ηrat/2, ub)
        closed_form = w -> wstar(w, ub)

        e = Edge((1, 2); h=h, ub=ub)
        e_closed = Edge((1, 2); h=h, ub=ub, wstar=closed_form)
        @test e isa EdgeGain{Float64,typeof(h)}
        @test e_closed isa EdgeClosedForm{Float64,typeof(h),typeof(closed_form)}
        x = zeros(2)
        xc = zeros(2)
        # ηrat = η1/η2
        for ηrat in [0.25, 0.75, 1.25, 1.75, 2.25]
            find_arb!(x, e, ηrat)
            find_arb!(xc, e_closed, ηrat)
            
            # test that x has form (-w, h(w)) where w ≥ 0
            w, wc = -x[1], -xc[1]
            @test h(w) ≈ x[2] atol=edge_tol
            @test h(wc) ≈ xc[2] atol=edge_tol

            # closed form and regular should be same
            @test x ≈ xc atol=edge_tol

            # optimality condition (smooth function)
            dh_ub, dh_lb = dh(ub), dh(0.0)
            if ηrat ≥ dh_lb
                @test w ≈ 0.0 atol=edge_tol
                @test wc ≈ 0.0 atol=edge_tol
            elseif ηrat ≤ dh_ub
                @test w ≈ ub atol=edge_tol
                @test wc ≈ ub atol=edge_tol
            else
                @test dh(w) ≈ ηrat atol=edge_tol
                @test dh(wc) ≈ ηrat atol=edge_tol
            end
        end

    end

    @testset "general" begin
        # from OPF example
        ub = 3.0
        h(w) = 3w - 16.0*(log1pexp(0.25 * w) - log(2))
        dh(w) = 3 - 4 * logistic(0.25 * w)
        wstar(ηrat, b) = ηrat ≥ 1.0 ? 0.0 : min(4.0 * log((3.0 - ηrat)/(1.0 + ηrat)), b)
        closed_form = w -> wstar(w, ub)
        
        e = Edge((1, 2); h=h, ub=ub)
        e_closed = Edge((1, 2); h=h, ub=ub, wstar=closed_form)
        @test e isa EdgeGain{Float64,typeof(h)}
        @test e_closed isa EdgeClosedForm{Float64,typeof(h),typeof(closed_form)}

        x = zeros(2)
        xc = zeros(2)
        # ηrat = η1/η2
        for ηrat in [0.25, 0.5, 0.75, 1.0, 1.25]
            find_arb!(x, e, ηrat)
            find_arb!(xc, e_closed, ηrat)
            
            # test that x has form (-w, h(w)) where w ≥ 0
            w, wc = -x[1], -xc[1]
            @test h(w) ≈ x[2] atol=edge_tol
            @test h(wc) ≈ xc[2] atol=edge_tol

            # closed form and regular should be same
            @test x ≈ xc atol=edge_tol

            # optimality condition (smooth function)
            dh_ub, dh_lb = dh(ub), dh(0.0)
            if ηrat ≥ dh_lb
                @test w ≈ 0.0 atol=edge_tol
                @test wc ≈ 0.0 atol=edge_tol
            elseif ηrat ≤ dh_ub
                @test w ≈ ub atol=edge_tol
                @test wc ≈ ub atol=edge_tol
            else
                @test dh(w) ≈ ηrat atol=edge_tol
                @test dh(wc) ≈ ηrat atol=edge_tol
            end
        end
    end
    
end

@testset "prediction edges" begin
    @testset "product two coin" begin
        e = ProductTwoCoin([200.0, 100.0], 0.997, [1, 2])
        η = [1.0, 0.5]
        x = zeros(2)
        find_arb!(x, e, η)
        expected = reference_product_flow([200.0, 100.0], 0.997, η)
        @test x ≈ expected atol=edge_tol
    end

    @testset "split merge oracle" begin
        e = SplitMergeEdge([1, 2, 3], 2.0)
        x = zeros(3)

        find_arb!(x, e, [1.0, 0.75, 0.75])
        @test x ≈ [-2.0, 2.0, 2.0] atol=edge_tol

        find_arb!(x, e, [2.0, 0.5, 0.5])
        @test x ≈ [2.0, -2.0, -2.0] atol=edge_tol

        find_arb!(x, e, [1.0, 0.5, 0.5])
        @test x ≈ zeros(3) atol=edge_tol

        residual = [-0.6, 0.3, 0.3]
        w = ForecastFlows.recover_splitmerge_flow!(x, e, [1.0, 0.5, 0.5], residual)
        @test w ≈ 0.4 atol=edge_tol
        @test x ≈ [-0.4, 0.4, 0.4] atol=edge_tol
    end

    @testset "univ3 parity" begin
        e = UniV3(1.0, [2.0, 1.0, 0.5], [100.0, 150.0, 100.0], 0.997, [1, 2])
        for η in ([1.0, 1.0], [0.6, 1.0], [1.4, 1.0])
            x = zeros(2)
            find_arb!(x, e, collect(η))
            expected = reference_univ3_flow(1.0, [2.0, 1.0, 0.5], [100.0, 150.0, 100.0], 0.997, collect(η))
            @test x ≈ expected atol=1e-8
        end
    end

    @testset "univ3 validation" begin
        e_int = UniV3(1, [2, 1], [100, 0], 0.997, [1, 2])
        @test e_int isa UniV3{Float64}
        @test e_int.current_price == 1.0
        @test e_int.lower_ticks == [2.0, 1.0]
        @test e_int.liquidity == [100.0, 0.0]

        x = zeros(2)
        η = [1.4, 1.0]
        find_arb!(x, e_int, η)
        expected = reference_univ3_flow(1.0, [2.0, 1.0], [100.0, 0.0], 0.997, η)
        @test x ≈ expected atol=edge_tol

        @test_throws ArgumentError UniV3(1.0, [0.5, 1.0], [100.0, 100.0], 0.997, [1, 2])
        @test_throws ArgumentError UniV3(3.0, [2.0, 1.0], [100.0, 0.0], 0.997, [1, 2])
        @test_throws ArgumentError UniV3(1.0, [2.0, 1.0], [100.0], 0.997, [1, 2])
        @test_throws ArgumentError UniV3(1.0, Float64[], Float64[], 0.997, [1, 2])
        @test_throws ArgumentError UniV3(1.0, [2.0, 1.0], [100.0, 0.0], 0.0, [1, 2])
        @test_throws ArgumentError UniV3(1.0, [2.0, 1.0], [100.0, 0.0], 1.1, [1, 2])
        @test_throws ArgumentError UniV3(1.0, [2.0, 1.0], [100.0, 0.0], -0.1, [1, 2])
        @test_throws ArgumentError UniV3(NaN, [2.0, 1.0], [100.0, 0.0], 0.997, [1, 2])
        @test_throws ArgumentError UniV3(1.0, [Inf, 1.0], [100.0, 0.0], 0.997, [1, 2])
        @test_throws ArgumentError UniV3(1.0, [2.0, 1.0], [Inf, 0.0], 0.997, [1, 2])
        @test_throws ArgumentError UniV3(1.0, [2.0, 1.0], [100.0, 0.0], NaN, [1, 2])
    end
end
