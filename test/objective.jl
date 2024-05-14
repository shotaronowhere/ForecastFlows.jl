# parameters
edge_tol = 1e-6
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
        @test U(obj, -g) - dot(ν, -g) ≈ Ubar(obj, ν)
    end

end