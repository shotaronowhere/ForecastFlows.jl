# User Guide

For new work, use the root solver API:

- construct a `Solver` with a flow objective and edge list
- call `solve!`
- inspect `s.y`, `s.xs`, and `s.certificate`

The prediction-market router additionally uses:

- `SplitMergeEdge` for fee-free mint/merge
- `EndowmentLinear` for portfolio-EV benchmarking
- `solve_with_fixed_gas!` for the current rough fixed-charge gas proxy

The older two-node `problem` / `solver_bfgs.jl` path is legacy. It remains in
the package for compatibility and reference, but it is not the recommended API
for new routing implementations.

See the **Examples** and **Advanced Examples** for generic convex-flow usage.
