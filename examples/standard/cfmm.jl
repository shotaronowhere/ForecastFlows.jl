#=
# CFMM Routing
This example uses `ConvexFlows` to solve a CFMM order routing problem

=#

using ConvexFlows
using Random, LinearAlgebra, SparseArrays
using Plots
import Graphs: Graph
import GraphPlot
import Cairo


#=
## Construct the problem

First, we build a graph with 3 nodes (assets) and 3 edges (markets).
=#

n = 3
edge_inds = [
    (1, 2),
    (1, 3),
    (2, 3),
]
Adj = spzeros(Bool, n, n)
for (i, j) in edge_inds
    Adj[i, j] = true
    Adj[j, i] = true
end

## Uniswap v2 trading function
Random.seed!(1)
Rs = [10*rand(2) for _ in 1:length(edge_inds)]
f(δ, R1, R2) = R2*δ/(R1 + δ)

cfmms = Edge[]
for (i, inds) in enumerate(edge_inds)
    i1, i2 = inds
    push!(cfmms, Edge((i1, i2); h=δ->f(δ, Rs[i][1], Rs[i][2]), ub=1e6))
    push!(cfmms, Edge((i2, i1); h=δ->f(δ, Rs[i][2], Rs[i][1]), ub=1e6))
end

graph = GraphPlot.gplot(
    Graph(Adj),
    nodefillc="black",
    edgestrokec="dark gray",
    edgelabel=[
        "$(round(Rs[i][1], digits=2)), $(round(Rs[i][2], digits=2))" 
        for i in 1:length(edge_inds)
    ],
    edgelabelc="white",
)


#=
Next, we define a linear objective function that says we value each asset equally.
=#

## Objective function
c = ones(n)
obj = Linear(c);


#=
## Solve the problem
=#
prob = problem(obj=obj, edges=cfmms)
result = solve!(prob; options=BFGSOptions(max_iters=12, print_iter=1))


#=
## Show the results

Some nodes with demand 0 are generator nodes, which we see have a net outflow.
=#

println("Objective value: $(result.obj_val)")
println("Netflows: $(prob.y)")
for (i, x) in enumerate(prob.xs)
    iszero(x) && continue
    edge_ind = (i-1) ÷ 2 + 1
    edge = isodd(i) ? edge_inds[edge_ind] : reverse(edge_inds[edge_ind])
    println("$edge has flow $x")
end