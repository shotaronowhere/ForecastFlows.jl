#=
# Optimal Power Flow
This example uses `ConvexFlows` to solve am optimal power flow problem.

The optimal power flow problem seeks a cost-minimizing plan 
to generate power satisfying demand in each region. We consider a network of $m$ 
transmission lines (edges) between $n$ regions (nodes). Each node has a demand 
$d_i$ and incurs cost $c_i(y_i) = (d_i - y_i)_+^2$ for power $y_i$. 

Each transmission line (edge) has a loss that's a function of the power flow through it.
the line and given by

```math
    \ell(w) = \alpha \left(\log(1 + \exp(\beta w)) - \log 2\right) - 2w.
```

The output of a line is then $h(w) = w - \ell(w)$. The optimal power flow 
problem is then to minimize the total cost (maximize its negative) subject to
the power flow constraints and net flow constraint:

```math
\begin{aligned}
    & \text{maximize} && -\sum_{i=1}^n (d_i - y_i)_+^2 \\
    & \text{subject to} &&  y = \sum_{i=1}^n A_i x_i \\
    &&& h(-(x_i)_1) \le (x_i)_2 ~ \text{for} i = 1, \dots, m. \\
\end{aligned}
```

We will solve the same problem as in the standard example, but with additional
optimizations.

=#

using ConvexFlows
using Random, LinearAlgebra, SparseArrays
using Plots, LogExpFunctions, StatsBase
using Graphs: Graph, connected_components
import GraphPlot
import Cairo

const CF = ConvexFlows
const GP = GraphPlot


#=
## Generating the problem data
=#

function build_graph(n; d=0.11, α=0.8, rseed=1)
    Random.seed!(rseed)
    xys = [sqrt(n)*rand(2) for _ in 1:n]
    I = Vector{Int}()
    sizehint!(I, n)
    J = Vector{Int}()
    sizehint!(J, n)
    V = Vector{Int}()
    sizehint!(V, n)
    for i in 1:n, j in i+1:n
        dist = norm(xys[i] - xys[j])
        γ = α * min(1.0, d^2 / dist^2)
        if rand() ≤ γ
            push!(I, i)
            push!(J, j)
            push!(V, 1)
        end
    end
    Adj = sparse(I, J, V, n, n)
    Adj = Adj + Adj'
    
    for i in 1:n
        sum(Adj[i, :]) > 0 && continue
        dists = [norm(xys[i] - xys[j]) for j in 1:n if j ≠ i]
        jmin = argmin(dists)
        Adj[i, jmin] = 1
        Adj[jmin, i] = 1
    end

    ccs = connected_components(Graph(Adj))
    nccs = length(ccs)
    remaining = Set(1:nccs)
    while nccs > 1
        cc_i, cc_j = sample(collect(remaining), 2, replace=false)
        i = rand(ccs[cc_i])
        j = rand(ccs[cc_j])
        Adj[i, j] = 1
        Adj[j, i] = 1
        ccs[cc_i] = union(ccs[cc_i], ccs[cc_j])
        remaining = setdiff(remaining,  Set([cc_j]))
        nccs -= 1
    end

    return Adj, xys
end

Random.seed!(1)
n = 100

## Build a graph:
Adj, xys = build_graph(n)
network_fig_n100 = GP.gplot(
    Graph(Adj),
    [xy[1] for xy in xys],
    [xy[2] for xy in xys],
    NODESIZE=2.0/n,
    nodefillc="black",
    edgestrokec="dark gray",
)


#=
## Closed form solutions to arbitrage problem
=#

## Edge gain function
h(w) = 3w - 16.0*(log1pexp(0.25 * w) - log(2))

## Closed for solution to the arbitrage problem, i.e. the w⋆ that solves 
##  h'(w) == ratio
wstar(ηrat, b) = ηrat ≥ 1.0 ? 0.0 : min(4.0 * log((3.0 - ηrat)/(1.0 + ηrat)), b)

lines = Edge[]
for i in 1:n, j in i+1:n
    Adj[i, j] ≤ 0 && continue

    ## Random upper bound ub ∈ {1, 2, 3}
    ub_i = rand((1., 2., 3.))

    push!(lines, Edge((i, j); h=h, ub=ub_i, wstar = @inline w -> wstar(w, ub_i)))
    push!(lines, Edge((j, i); h=h, ub=ub_i, wstar = @inline w -> wstar(w, ub_i)))
end

## Objective function
d = rand((0.5, 1., 2.), n)
obj = NonpositiveQuadratic(d)

#=
### Solve the problem
=#
prob = problem(obj=obj, edges=lines)
result = solve!(prob)


#=
### Visualize the results

Some nodes with demand 0 are generator nodes, which we see have a net outflow.
=#

inds = sortperm(d)
plt = bar(
    prob.y[inds], 
    label="net flow", 
    color=:blue,
    xticks=nothing
)
bar!(plt, d[inds], label="demand", alpha=0.5, color=:red)


#=
## Generic interface

We may also define the subproblems at each iteration directly
=#

#=
## Arbitrage problem

We may also define the `find_arb!` function directly.
=#


## ----- TransmissionLine edge ----
struct TransmissionLine{T} <: CF.Edge{T}
    b::T
    α::T
    β::T
    p_min::T
    p_max::T
    flow_max::T
    Ai::Vector{Int}
end
function TransmissionLine(b::T, Ai::Vector{Int}) where T <: AbstractFloat
    α, β = T(16), T(1/4)
    p_max = one(T)
    p_min = 3 - α * β * logistic(β * b)
    flow_max = 3b -  α * (log1pexp(β * b) - log(2)) 
    return TransmissionLine(b, α, β, p_min, p_max, flow_max, Ai)
end

function gain(w::T, e::TransmissionLine{T}) where T
    α, β, b = e.α, e.β, e.b
    w = w > b ? b : w
    return w - (α * (log1pexp(β * w) - log(2))  - 2w)
end

function CF.find_arb!(x::Vector{T}, e::TransmissionLine{T}, η::Vector{T}) where T
    η1, η2 = η[1], η[2]
    x[1] = -clamp(1/e.β * log((3η2 - η1)/(η2 + η1)), zero(T), e.b)
    x[2] = gain(-x[1], e)
    return nothing
end

#=
### Objective
=#
struct QuadraticPowerCost{T} <: Objective
    n::Int
    d::Vector{T}
end
QuadraticPowerCost(d::Vector{T}) where T = QuadraticPowerCost(length(d), d)


function U(obj::QuadraticPowerCost{T}, y) where T
    return -0.5*sum(x->abs2(max(x, zero(T))), obj.d - y)
end

function grad_U(obj::QuadraticPowerCost{T}, y) where T
    return obj.d - y
end

function CF.Ubar(obj::QuadraticPowerCost{T}, ν) where T
    return 0.5*sum(abs2, ν) - dot(obj.d, ν)
end

function CF.grad_Ubar!(g, obj::QuadraticPowerCost{T}, ν) where T
    @. g = ν - obj.d
    return nothing
end

CF.lower_limit(obj::QuadraticPowerCost{T}) where {T} = zeros(T, obj.n)
CF.upper_limit(obj::QuadraticPowerCost{T}) where {T} = convert(T, Inf) .+ zeros(T, obj.n)


#=
### Construct problem
=#

## Define objective function
Uy = QuadraticPowerCost(d)

## Build lines
lines_generic = TransmissionLine[]
for line in lines
    push!(lines_generic, TransmissionLine(line.ub, [line.Ai[1], line.Ai[2]]))
end

#=
### Solve with ConvexFlows.jl
=#
s = Solver(
    flow_objective=Uy,
    edges=lines_generic,
    n=n,   
)
solve!(s, verbose=true)


sol_norm = norm(s.y - prob.y)
println("Norm of solution difference: $sol_norm")