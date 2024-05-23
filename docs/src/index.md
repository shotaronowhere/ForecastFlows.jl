```@meta
CurrentModule = ConvexFlows
```

# ConvexFlows.jl
`ConvexFlows` is a solver for the convex flow problem, introduced by Diamandis
et al. in [Convex Network Flows](https://arxiv.org/abs/2404.00765)[^1].

### Documentation Contents:
```@contents
Pages = ["index.md", "method.md", "guide.md", "api.md"]
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

ConvexFlows solves convex optimization problems of the form

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


Compared to general conic form programs, the form we use in ConvexFlows takes advantage of underlying (hyper)graph structure in these problems and facilitates custom subroutines that often provide significant speedups. To ameliorate the extra complexity, we provide a few interfaces that allow for easy problem specification.

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
Please see the [User Guide](@ref) for a full explanation of the solver parameter
options. Check out the examples in the documentation, as well as the more
advanced examples in the `paper` folder on GitHub.


## References
[^1]: Diamandis, T., Angeris, G., & Edelman, A. (2024). [Convex Network Flows.](https://arxiv.org/abs/2404.00765) arXiv preprint arXiv:2404.00765.