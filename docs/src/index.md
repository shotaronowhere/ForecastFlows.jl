```@meta
CurrentModule = ForecastFlows
```

# ForecastFlows.jl
`ForecastFlows` is a solver for convex-flow problems on graphs and hypergraphs.
This fork keeps the original framework from Diamandis et al. and extends the
root solver to prediction-market trade routing with AMM edges plus a fee-free
mint/merge hyperedge.

### Documentation Contents:
```@contents
Pages = ["index.md", "prediction_market_router.md", "method.md", "guide.md", "api.md"]
Depth = 1
```
##### Examples:
```@contents
Pages = [
    "examples/opf.md",
    "examples/cfmm.md",
]
Depth = 1
```

#### Advanced Usage:
```@contents
Pages = [
    "advanced/opf.md",
    "advanced/market.md",
]
Depth = 1
```


## Overview

ForecastFlows solves convex optimization problems of the form

```math
\begin{array}{ll}
\text{maximize}     & U(y) + \sum_{i=1}^m V_i(x_i) \\
\text{subject to}   & y = \sum_{i=1}^m A_i x_i \\
& x_i \in T_i
\end{array}
```
where $x_i \in \mathbb{R}^{n_i}$ and $y \in \mathbb{R}^n$ are the optimization variables.
The functions $U$ and $\{V_i\}$ are concave nondecreasing utility functions,
and the matrices $\{A_i\}$ map the flow over edge $i$ from the local indices to
the global indices.


Compared to general conic form programs, the form we use in ForecastFlows takes advantage of underlying (hyper)graph structure in these problems and facilitates custom subroutines that often provide significant speedups. To ameliorate the extra complexity, we provide a few interfaces that allow for easy problem specification.

## Prediction-market extension

The prediction-market router is built on the same dual-decomposition idea:

- one collateral node
- one outcome node per market outcome
- one AMM edge per collateral/outcome market
- one `SplitMergeEdge` with local ordering `[collateral, outcomes...]`

The recommended public interface for new work is the root solver API:

- `Solver`
- `solve!`
- `SplitMergeEdge`
- `EndowmentLinear`
- `certify_solution`
- `solve_with_fixed_gas!`

The older two-node `problem` interface remains available as legacy code, but it
is not the recommended entrypoint for prediction-market routing.

## Objective interface
We define a few objective functions that may be used 'off the shelf', which we
list below:
- `NonpositiveQuadratic(b, a)` is defined as
```math
    U(y) = -(1/2)\sum_{i=1}^n a_i(b_i - y_i)^2
```
- `Markowitz(mu, Sigma)` is defined as
```math
    U(y) = \mu^Ty - (1/2)y^T\Sigma y
```

### Generic interface
To solve the dual problem, we work with the conjugate-like function
```math
\bar U(\nu) = \sup_{y}\left(U(y) - \nu^Ty\right)
```
A user may define custom objective functions by implementing the
following interface for an objective object that is a subtype of `Objective`"
- `U(obj, y)` evaluates objective `obj` at `y`
- `Ubar(obj, v)` evaluates the subproblem $\bar U$ at `v`
- `grad_Ubar!(g, obj, v)` (or `∇Ubar!`) evaluates the gradient of $\bar U$ at `v` and stores the result in `g`
- `Base.length(obj)` returns the number of nodes $n$

If using a custom linear objective, one should also define `lower_limit(obj)` and
`upper_limit(obj)` appropriately.


## Edge interfaces
Ultimately, we only need access to allowable edge flow sets via their support
function (equivalently, the ability to find arbitrage). This can be done in a
few ways.

### Two-node edges
For two node edges, we only have to define a gain function $h(w)$ which gives the
output from the edge for some positive input flow $w$. The solver then solves a
single-dimensional root finding problem to compute arbitrage. Alternatively, if
a closed form solution exists, it may be specified directly. These functions can
be specified in native Julia code; see examples for details.

### Generic interface
More generically, an edge must support the function
```julia
find_arb!(x, edge, eta).
```
For an edge object `edge` with allowable flows $T$, this function finds a solution to the problem
```math
\sup_{x \in T} \eta^T x
```
and stores it in the argument `x`.


### Algorithm
We use a first-order method to solve a particular dual of the convex flow problem.
Check out the [Algorithm]() page for details.

## Getting Started

Start with the [Prediction Market Router](@ref) page for the routing extension,
then see the [User Guide](@ref) and the example pages for the generic solver
interfaces.


## References
[^1]: Diamandis, T., Angeris, G., & Edelman, A. (2024). [Convex Network Flows.](https://arxiv.org/abs/2404.00765) arXiv preprint arXiv:2404.00765.
