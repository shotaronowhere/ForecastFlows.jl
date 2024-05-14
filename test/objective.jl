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
        ConvexFlows.∇Ubar!(g, obj, ν)
        @test U(obj, -g) - dot(ν, -g) ≈ Ubar(obj, ν) atol=obj_tol
    end
end

@testset "markowitz" begin
    Σ = 2.0*I
    μ = [1.0, 2.0]
    obj = Markowitz(μ, Σ)
    @test U(obj, [1.0, 2.0]) ≈ 0.0 atol=obj_tol

    for _ in 1:5
        ν = rand(2)
        g = similar(ν)
        ConvexFlows.∇Ubar!(g, obj, ν)
        @test U(obj, -g) - dot(ν, -g) ≈ Ubar(obj, ν) atol=obj_tol
    end
end


@testset "linear nonnegative" begin
    obj = LinearNonnegative([1.0, 2.0]./10)
    @test U(obj, [3.0, 4.0]) ≈ 1.1 atol=obj_tol

    for _ in 1:5
        ν = rand(2)
        g = similar(ν)
        ConvexFlows.∇Ubar!(g, obj, ν)
        
        if any(obj.μ - ν .> 0)
            @test abs(U(obj, -g)) > 1/obj_tol && Ubar(obj, ν) > 1/obj_tol
        else
            @test U(obj, -g) - dot(ν, -g) ≈ Ubar(obj, ν) atol=obj_tol
        end
    end
end