
Random.seed!(1)
@testset "simple" begin
    Adj = spzeros(2,2)
    Adj[1,2] = 1
    Adj = (Adj + Adj' .> 0)
    
    n = 2
    μ = [1.0, 2.0]
    Σ = I
    obj = Markowitz(μ, Σ)
    h(w) = sqrt(w + eps())
    lines = Edge[]
    for i in 1:n, j in i+1:n
        Adj[i, j] ≤ 0 && continue
    
        push!(lines, Edge((i, j); h=h, ub=1.0))
        push!(lines, Edge((j, i); h=h, ub=1.0))
    end
    
    prob = @test_deprecated problem(obj=obj, edges=lines)
    result = solve!(prob; options=BFGSOptions(verbose=false, final_print=false))
    
    tol = 1e-6
    ystar = prob.y
    ν = μ - Σ * ystar
    x1 = prob.xs[1][1]
    @test 1/2 * 1/sqrt(-x1 + eps()) - ν[1] / ν[2] ≈ 0.0 atol=tol
    @test norm(prob.xs[2]) ≈ 0.0 atol=tol
end
