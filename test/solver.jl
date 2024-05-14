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
    function ConvexFlows.find_arb!(x::Vector{T}, e::Uniswap{T}, η::Vector{T}) where T
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

    function U(obj::LinearNonnegativeCustom{T}, y) where T
        return dot(obj.c, y)
    end

    function grad_U(obj::LinearNonnegativeCustom{T}, y) where T
        return obj.c
    end

    # Assumes that ν - c ≥ 0
    function ConvexFlows.Ubar(obj::LinearNonnegativeCustom{T}, ν) where T
        return zero(T)
    end

    # Assumes that ν - c ≥ 0
    function ConvexFlows.grad_Ubar!(g, obj::LinearNonnegativeCustom{T}, ν) where T
        g .= zero(T)
        return nothing
    end

    # Add a small amount to the lower limit to avoid numerical issues
    ConvexFlows.lower_limit(obj::LinearNonnegativeCustom{T}) where {T} = obj.c .+ sqrt(eps(T))
    ConvexFlows.upper_limit(obj::LinearNonnegativeCustom{T}) where {T} = convert(T, Inf) .+ zeros(T, obj.n)

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

    # with edge costs
    Vis = [NonpositiveQuadratic(zeros(2)) for cfmm in cfmms]
    s_vi = Solver(
        flow_objective=Uy,
        edge_objectives=Vis,
        edges=cfmms,
        n=n
    )
    solve!(s_vi, verbose=false, memory=5)

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