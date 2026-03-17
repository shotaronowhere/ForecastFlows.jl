# parameters
obj_tol = 1e-5
Random.seed!(1)

@testset "nonpositive quadratic" begin
    # U(y) = -0.5 * (b - y)₊²
    obj = NonpositiveQuadratic([1.0, 2.0])
    @test U(obj, [1.0, 2.0]) ≈ 0.0
    @test U(obj, [2.0, 2.0]) ≈ 0.0
    @test U(obj, [0.0, 0.0]) ≈ -2.5

    for _ in 1:5
        ν = rand(2)
        g = similar(ν)
        ForecastFlows.∇Ubar!(g, obj, ν)
        @test U(obj, -g) - dot(ν, -g) ≈ Ubar(obj, ν) atol=obj_tol
    end

    weighted = NonpositiveQuadratic([1.0, 2.0]; a=[4.0, 9.0])
    @test U(weighted, [0.0, 0.0]) ≈ -20.0 atol=obj_tol
    for _ in 1:5
        ν = rand(2)
        g = similar(ν)
        ForecastFlows.∇Ubar!(g, weighted, ν)
        @test U(weighted, -g) - dot(ν, -g) ≈ Ubar(weighted, ν) atol=obj_tol
    end
end

@testset "markowitz" begin
    Σ = 2.0*I
    μ = [1.0, 2.0]
    obj = Markowitz(μ, Σ)
    @test U(obj, [1.0, 2.0]) ≈ 0.0 atol=obj_tol

    Σmat = [2.0 0.0; 0.0 2.0]
    obj_mat = Markowitz(μ, Σmat)
    @test obj_mat isa Markowitz{Float64,Matrix{Float64}}

    for _ in 1:5
        ν = rand(2)
        g = similar(ν)
        ForecastFlows.∇Ubar!(g, obj, ν)
        @test U(obj, -g) - dot(ν, -g) ≈ Ubar(obj, ν) atol=obj_tol
    end
end


@testset "linear" begin
    obj = Linear([1.0, 2.0]./10)
    @test U(obj, [3.0, 4.0]) ≈ 1.1 atol=obj_tol

    for _ in 1:5
        ν = rand(2)
        g = similar(ν)
        ForecastFlows.∇Ubar!(g, obj, ν)
        
        if any(obj.μ - ν .> 0)
            @test abs(U(obj, -g)) > 1/obj_tol && Ubar(obj, ν) > 1/obj_tol
        else
            @test U(obj, -g) - dot(ν, -g) ≈ Ubar(obj, ν) atol=obj_tol
        end
    end
end

@testset "linear nonnegative" begin
    obj = LinearNonnegative([0.5, 0.75])
    @test U(obj, [2.0, 3.0]) ≈ 3.25 atol=obj_tol
    @test Ubar(obj, [0.5, 0.75] .+ 1e-3) ≈ 0.0 atol=obj_tol
    @test isinf(Ubar(obj, [0.4, 0.75]))

    g = zeros(2)
    ForecastFlows.∇Ubar!(g, obj, [0.5, 0.75] .+ 1e-3)
    @test g ≈ zeros(2) atol=obj_tol
end

@testset "endowment linear" begin
    obj = EndowmentLinear([1.0, 0.4, 0.6], [2.0, 1.5, 0.0])
    @test U(obj, [-2.0, -1.5, 0.25]) ≈ -2.45 atol=obj_tol
    @test isinf(U(obj, [-2.1, -1.5, 0.25]))
    @test Ubar(obj, [1.0, 0.4, 0.6] .+ 1e-3) ≈ 0.0035 atol=obj_tol
    @test isinf(Ubar(obj, [0.9, 0.4, 0.6]))

    g = zeros(3)
    ν = [1.3, 0.7, 0.9]
    ForecastFlows.∇Ubar!(g, obj, ν)
    @test g ≈ [2.0, 1.5, 0.0] atol=obj_tol

    y_face = -obj.h0
    @test U(obj, y_face) - dot(ν, y_face) ≈ Ubar(obj, ν) atol=obj_tol

    for _ in 1:5
        y = rand(3) .- obj.h0
        ν = obj.c .+ rand(3)
        @test U(obj, y) - dot(ν, y) <= Ubar(obj, ν) + obj_tol
    end

    zero_endowment = EndowmentLinear([0.5, 0.75], [0.0, 0.0])
    linear = LinearNonnegative([0.5, 0.75])
    y = [2.0, 3.0]
    ν = [0.7, 0.9]
    @test U(zero_endowment, y) ≈ U(linear, y) atol=obj_tol
    @test Ubar(zero_endowment, ν) ≈ Ubar(linear, ν) atol=obj_tol

    # When ν ≈ c, no coordinates are pinned
    target = zeros(3)
    fixed = trues(3)
    ν_at_c = obj.c .+ 0.0  # exactly at c
    ForecastFlows.recovery_targets!(target, fixed, obj, ν_at_c)
    @test target == zeros(3)
    @test fixed == falses(3)

    # Correct recovery_targets! behavior: pinned coordinates
    let
        obj2 = EndowmentLinear([1.0, 0.3, 0.7], [100.0, 50.0, 25.0])
        ν2 = [1.0, 0.8, 0.7]  # ν[2] > c[2], ν[1] ≈ c[1], ν[3] ≈ c[3]
        target2 = zeros(3)
        fixed2 = falses(3)
        ForecastFlows.recovery_targets!(target2, fixed2, obj2, ν2)
        @test fixed2[2] == true
        @test target2[2] ≈ -50.0
        @test fixed2[1] == false
        @test fixed2[3] == false
    end
end

@testset "basket liquidation" begin
    obj = BasketLiquidation(2, [1.0, 0.0, 0.0])
    @test Ubar(obj, [1.5, 1.1, 0.9]) ≈ 1.5 atol=obj_tol
    @test isinf(Ubar(obj, [1.5, 0.9, 0.9]))

    g = zeros(3)
    ForecastFlows.∇Ubar!(g, obj, [1.5, 1.1, 0.9])
    @test g ≈ [1.0, 0.0, 0.0] atol=obj_tol

    swap = Swap(2, 1, 1.0, 3)
    @test Ubar(swap, [1.5, 1.1, 0.9]) ≈ Ubar(obj, [1.5, 1.1, 0.9]) atol=obj_tol
end

@testset "basket acquisition" begin
    obj = BasketAcquisition(1, [0.0, 1.0, 0.5])
    @test Ubar(obj, [1.0, 1.2, 0.8]) ≈ -(1.2 + 0.4) atol=obj_tol
    @test isinf(Ubar(obj, [0.9, 1.2, 0.8]))

    g = zeros(3)
    ForecastFlows.∇Ubar!(g, obj, [1.0, 1.2, 0.8])
    @test g ≈ [0.0, -1.0, -0.5] atol=obj_tol

    swap = SwapExactOutput(2, 1, 1.0, 3)
    @test Ubar(swap, [1.0, 1.2, 0.8]) ≈ -1.2 atol=obj_tol
end
