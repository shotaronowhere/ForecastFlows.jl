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
=#

using ConvexFlows
using Random, LinearAlgebra, SparseArrays
using Plots, LogExpFunctions


#=
## Generating the problem data
=#

Random.seed!(1)
n = 10

## Build a graph:
Adj = sprand(Bool, n, n, 0.4)
Adj = (Adj + Adj' .> 0)
Adj[diagind(Adj)] .= 0
spy(Adj; size=(400, 400), markersize=5, markerstrokewidth=0, xticks=1:10, yticks=1:10)


#=
## Construct the problem
=#

## Objective function
d = 4*rand(n) .* rand((0,1), n)
obj = NonpositiveQuadratic(d)

## Edges
h(w) = 3w - 16.0*(log1pexp(0.25 * w) - log(2))

lines = Edge[]
for i in 1:n, j in i+1:n
    Adj[i, j] ≤ 0 && continue

    ## Random upper bound ub ∈ {1, 2, 3}
    ub_i = rand((1., 2., 3.))

    push!(lines, Edge((i, j); h=h, ub=ub_i))
    push!(lines, Edge((j, i); h=h, ub=ub_i))
end


#=
## Solve the problem
=#
prob = problem(obj=obj, edges=lines)
result = solve!(prob)


#=
## Visualize the results

Some nodes with demand 0 are generator nodes, which we see have a net outflow.
=#

p = d - prob.y
plt = bar(
    prob.y, 
    label="net flow", 
    color=:blue,
)
bar!(plt, d, label="demand", alpha=0.5, color=:red)


