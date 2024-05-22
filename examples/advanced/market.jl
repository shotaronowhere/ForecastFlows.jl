#=
# Market Clearing
This example uses `ConvexFlows` to solve a market clearing problem
=#

using ConvexFlows
using Random, LinearAlgebra, SparseArrays
using Plots, LogExpFunctions

const CF = ConvexFlows

#=
## Generating the problem data
=#

Random.seed!(1)
nb = 3
ng = 2
budgets = ones(nb)

#=
## Construct the problem

First, we build a graph with 3 buyers and 2 goods. Buyer $b$ gets utility
$u(x) = \sqrt{b + gx} - \sqrt{b}$ from $x$ units of a good $g$.
=#

## Edges
u(x, b, g) = sqrt(b + g*x) - sqrt(b)

edges = Edge[]
for b in 1:nb, g in 1:ng
    ## ub = 1.0 since only one unit of each good
    push!(edges, Edge((nb + g, b); h=x->u(x, b, g), ub=1e3))
end

#=
## Objective function
Here, we use a custom objective function and must define the associated methods.
=#
struct MarketClearingObjective{T} <: Objective
    budget::Vector{T}
    nb::Int
    ng::Int
    ϵ::T
end
function MarketClearingObjective(budget::Vector{T}, nb::Int, ng::Int; tol=1e-8) where T
    @assert length(budget) == nb
    return MarketClearingObjective{T}(budget, nb, ng, tol)
end
Base.length(obj::MarketClearingObjective) = obj.nb + obj.ng

function CF.U(obj::MarketClearingObjective{T}, y) where T
    any(y[obj.nb+1] .< -1) && return -Inf
    return sum(obj.budget .* log.(y[1:obj.nb])) - obj.ϵ/2*sum(abs2, y[obj.nb+1:end])
end

function CF.Ubar(obj::MarketClearingObjective{T}, ν) where T
    return sum(log.(obj.budget ./ ν[1:obj.nb]) .- 1) + sum(ν[obj.nb+1:end])
end

function CF.∇Ubar!(g, obj::MarketClearingObjective{T}, ν) where T
    g[1:obj.nb] .= -obj.budget ./ ν[1:obj.nb]
    g[obj.nb+1:end] .= 1.0
    return nothing
end

# function CF.Ubar(obj::MarketClearingObjective{T}, ν) where T
#     ystar_goods = max.(-ν[obj.nb+1:end]/obj.ϵ, -1)

#     return sum(log.(1 ./ ν[1:obj.nb]) .- 1) + 
#         (-obj.ϵ/2*sum(abs2, ystar_goods) - dot(ν[obj.nb+1:end], ystar_goods))
# end

# function CF.∇Ubar!(g, obj::MarketClearingObjective{T}, ν) where T
#     g[1:obj.nb] .= -1 ./ ν[1:obj.nb]
#     g[obj.nb+1:end] .= -max.(-ν[obj.nb+1:end]/obj.ϵ, -1)
#     return nothing
# end

obj = MarketClearingObjective(budgets, nb, ng)


#=
## Solve the problem

Note that we could opt to use the LBFGS-B solver instead.
=#
prob = problem(obj=obj, edges=edges)
result = solve!(prob; options=BFGSOptions(max_iters=200, print_iter=50))


#=
## Display results
=#

## Allocation of each good
println("Final utilities: ", prob.y[1:nb])
for b in 1:nb, g in 1:ng
    println("Buyer $b gets $(-prob.xs[2(b-1) + g][1]) units of good $g for utility $(prob.xs[2(b-1) + g][2])")
end