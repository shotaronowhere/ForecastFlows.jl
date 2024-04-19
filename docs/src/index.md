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
]
Depth = 1
```

#### Advanced Usage:
```@contents
Pages = [
    "advanced/opf.md",
]
Depth = 1
```


## Overview

ConvexFlows solves convex optimization problems of the form

```math
\begin{array}{ll}
\text{maximize}     & U(y) + \sum_{i=1}^m V_i(x_i) \\
\text{subject to}   & y = \sum_{i=1}^m A_i x_i \\
&& x_i \in T_i
\end{array}
```
where $x_i \in \mathbb{R}^{n_i}$ and $y \in \mathbb{R}^n$ are the optimization variables.
The functions $U$ and $\{V_i\}$ are concave nondecreasing utility functions,
and the matrices $\{A_i\}$ map the flow over edge $i$ from the local indices to
the global indices.


Compared to general conic form programs, the form we use in ConvexFlows takes advantage of underlying (hyper)graph structure in these problems and facilitates custom subroutines that often provide significant speedups. To ameliorate the extra complexity, we provide a few interfaces that allow for easy problem specification.

### Interfaces

#### Gain functions


##### Closed-form edge arbitrage

#### Generic interface

### Algorithm

## Getting Started

Please see the [User Guide](@ref) for a full explanation of the solver parameter
options. Check out the examples as well.


## References
[^1]: Diamandis, T., Angeris, G., & Edelman, A. (2024). [Convex Network Flows.](https://arxiv.org/abs/2404.00765) arXiv preprint arXiv:2404.00765.