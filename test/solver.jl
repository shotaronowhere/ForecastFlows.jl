Random.seed!(1)
@testset "cfmm" begin

    n = 10
    m = round(Int, n^2 / 4)

    # ----- Uniswap edge -----
    struct Uniswap{T} <: Edge{T}
        R::Vector{T}
        γ::T
        Ai::Vector{Int}

        function Uniswap(R::Vector{T}, γ::T, Ai::Vector{Int}) where T <: AbstractFloat
            length(R) != 2 && ArgumentError("R must be of length 2")
            length(Ai) != 2 && ArgumentError("Ai must be of length 2")
            return new{T}(R, γ, Ai)
        end
    end

    # Solves the maximum arbitrage problem for the two-coin constant product case.
    # Assumes that v > 0 and γ > 0.
    function ForecastFlows.find_arb!(x::Vector{T}, e::Uniswap{T}, η::AbstractVector{T}) where T
        # See App. A of "An Analysis of Uniswap Markets"
        @inline prod_arb_δ(m, r, k, γ) = max(sqrt(γ*m*k) - r, 0.0)/γ
        @inline prod_arb_λ(m, r, k, γ) = max(r - sqrt(k/(m*γ)), 0.0)

        R, γ = e.R, e.γ
        k = R[1]*R[2]

        x[1] = prod_arb_λ(η[1]/η[2], R[1], k, γ) - prod_arb_δ(η[2]/η[1], R[1], k, γ)
        x[2] = prod_arb_λ(η[2]/η[1], R[2], k, γ) - prod_arb_δ(η[1]/η[2], R[2], k, γ)
        return nothing
    end

    # build edges
    cfmms = Vector{Edge}()
    for i in 1:m
        γ = 0.997
        Ri = 100 * rand(2) .+ 100
        Ai = sample(collect(1:n), 2, replace=false)
        push!(cfmms, Uniswap(Ri, γ, Ai))    
    end

    # Define objective function
    struct LinearNonnegativeCustom{T} <: Objective 
        n::Int
        c::Vector{T}
    end
    function LinearNonnegativeCustom(c::Vector{T}) where T
        all(c .> 0) || throw(ArgumentError("all elements must be strictly positive"))
        n = length(c)
        return LinearNonnegativeCustom{Float64}(n, c)
    end

    function ForecastFlows.U(obj::LinearNonnegativeCustom{T}, y) where T
        return dot(obj.c, y)
    end

    function ForecastFlows.grad_U(obj::LinearNonnegativeCustom{T}, y) where T
        return obj.c
    end

    # Assumes that ν - c ≥ 0
    function ForecastFlows.Ubar(obj::LinearNonnegativeCustom{T}, ν) where T
        return zero(T)
    end

    # Assumes that ν - c ≥ 0
    function ForecastFlows.grad_Ubar!(g, obj::LinearNonnegativeCustom{T}, ν) where T
        g .= zero(T)
        return nothing
    end

    # Add a small amount to the lower limit to avoid numerical issues
    ForecastFlows.lower_limit(obj::LinearNonnegativeCustom{T}) where {T} = obj.c .+ sqrt(eps(T))
    ForecastFlows.upper_limit(obj::LinearNonnegativeCustom{T}) where {T} = convert(T, Inf) .+ zeros(T, obj.n)
    function ForecastFlows.recovery_targets!(target, fixed, obj::LinearNonnegativeCustom{T}, ν) where {T}
        fill!(target, zero(T))
        fill!(fixed, false)
        return nothing
    end

    min_price = 1e-2
    max_price = 1.0
    Random.seed!(1)
    c = rand(n) .* (max_price - min_price) .+ min_price
    Uy = LinearNonnegativeCustom(c)

    s = Solver(
        flow_objective=Uy,
        edges=cfmms,
        n=n,
    )
    solve!(s, verbose=false, memory=5)
    @test s.certificate.passed
    all(s.y .≥ -1e-5)       # pfeas
    for (i, cfmm) in enumerate(cfmms)
        Δ = max.(-s.xs[i], 0.0)
        Λ = max.(s.xs[i], 0.0)
        Rp = cfmm.R + cfmm.γ * Δ - Λ

        νi =  s.ν[cfmm.Ai][1] / s.ν[cfmm.Ai][2]
        p = Rp[2] / Rp[1]
        subopt_i = max(max(νi * cfmm.γ - p, 0.0), max(p - νi, 0.0))
        @test subopt_i ≤ 1e-2
    end

    s_memory = Solver(
        flow_objective=LinearNonnegative([1.0, 0.5, 0.5]),
        edges=Edge[
            ProductTwoCoin([200.0, 100.0], 1.0, [1, 2]),
            ProductTwoCoin([200.0, 100.0], 1.0, [1, 3]),
            SplitMergeEdge([1, 2, 3], 2.0),
        ],
        n=3,
    )
    solve!(s_memory, verbose=false, memory=18)
    @test s_memory.certificate.passed
    @test primal_objective(s_memory) > 0.0

    # with edge costs
    Vis = [NonpositiveQuadratic(zeros(2)) for cfmm in cfmms]
    s_vi = Solver(
        flow_objective=Uy,
        edge_objectives=Vis,
        edges=cfmms,
        n=n
    )
    solve!(s_vi, verbose=false, memory=5)
    @test s_vi.certificate.passed

    all(s_vi.y .≥ -1e-5)       # pfeas
    for (i, cfmm) in enumerate(cfmms)
        Δ = max.(-s_vi.xs[i], 0.0)
        Λ = max.(s_vi.xs[i], 0.0)
        Rp = cfmm.R + cfmm.γ * Δ - Λ
        η = s_vi.ηts[i] .+ s_vi.ν[cfmm.Ai]

        νi =  η[1] / η[2]
        p = Rp[2] / Rp[1]
        subopt_i = max(max(νi * cfmm.γ - p, 0.0), max(p - νi, 0.0))
        @test subopt_i ≤ 1e-2
    end

end

@testset "lbfgsb warm start and subset copies" begin
    s = Solver(
        flow_objective=EndowmentLinear([1.0, 0.5, 0.5], [1.0, 0.0, 0.0]),
        edge_objectives=[
            NonpositiveQuadratic(zeros(2)),
            NonpositiveQuadratic(zeros(3)),
        ],
        edges=Edge[
            ProductTwoCoin([200.0, 100.0], 1.0, [1, 2]),
            SplitMergeEdge([1, 2, 3], 2.0),
        ],
        n=3,
    )

    nis = [length(e.Ai) for e in s.edges]
    bounds = ForecastFlows._lbfgsb_bounds(s, nis)
    ν0 = [1.2, 0.8, 0.9]
    η0 = [[1.4, 1.1], [1.3, 1.2, 1.1]]
    ForecastFlows._initialize_lbfgsb_state!(s, bounds, nis, ν0, η0)

    expected = vcat(
        ν0,
        η0[1],
        η0[2],
    )
    @test s.μ0 == expected

    sub = ForecastFlows._subset_solver(s, [1, 2])
    @test sub.flow_objective !== s.flow_objective
    @test sub.flow_objective.c !== s.flow_objective.c
    @test sub.flow_objective.h0 !== s.flow_objective.h0
    @test sub.edge_objectives[1] !== s.edge_objectives[1]
    @test sub.edge_objectives[1].a !== s.edge_objectives[1].a
    @test sub.edge_objectives[1].b !== s.edge_objectives[1].b

    sub.flow_objective.h0[1] = 9.0
    sub.edge_objectives[1].b[1] = 7.0
    @test s.flow_objective.h0[1] == 1.0
    @test s.edge_objectives[1].b[1] == 0.0
end
