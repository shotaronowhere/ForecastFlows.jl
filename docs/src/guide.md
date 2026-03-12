# User Guide

For generic convex-flow work, use the root solver API:

- construct a `Solver` with a flow objective and edge list
- call `solve!`
- inspect `s.y`, `s.xs`, and `s.certificate`

For the standard prediction-market router, prefer the dedicated facade:

- `PredictionMarketProblem`
- `ConstantProductMarketSpec`
- `UniV3MarketSpec`
- `solve_prediction_market`
- `compare_prediction_market_families`

The lower-level prediction-market pieces remain available when needed:

- `SplitMergeEdge` for fee-free mint/merge
- `EndowmentLinear` for portfolio-EV benchmarking
- `solve_with_fixed_gas!` for rough fixed-charge pruning; the Deep-Trading
  benchmark sweep uses a separate test-local grouped pricing layer

For non-Julia drivers, use the JSON worker documented in the
[Integration Guide](integration.md).

The older two-node `problem` / `solver_bfgs.jl` path is legacy. It remains in
the package for compatibility and reference, but it is not the recommended API
for new routing implementations.

See the **Examples** and **Advanced Examples** for generic convex-flow usage.
