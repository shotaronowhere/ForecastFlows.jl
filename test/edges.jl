
# parameters
edge_tol = 1e-6
Random.seed!(1)


# TODO: test piecewise linear function
@testset "nonlinear" begin

    @testset "quadratic" begin
        ub = 1.0
        h(w) = 2w - w^2
        dh(w) = 2 - 2w
        wstar(ηrat, ub) = ηrat ≥ 2.0 ? 0.0 : min(1 - ηrat/2, ub)

        e = Edge((1, 2); h=h, ub=ub)
        e_closed = Edge((1, 2); h=h, ub=ub, wstar= w -> wstar(w, ub))
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
        
        e = Edge((1, 2); h=h, ub=ub)
        e_closed = Edge((1, 2); h=h, ub=ub, wstar= w -> wstar(w, ub))

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
