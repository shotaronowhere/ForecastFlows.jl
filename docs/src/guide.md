# User Guide

For research or internal convex-flow work, the root solver API remains
available as qualified Julia API, but it is outside the stable prediction-market
dependency surface:

- construct a `ForecastFlows.Solver` with a flow objective and edge list
- call `ForecastFlows.solve!`
- inspect `s.y`, `s.xs`, and `s.certificate`

For the standard prediction-market router, prefer the dedicated facade:

- `OutcomeSpec`
- `PredictionMarketProblem`
- `ConstantProductMarketSpec`
- `UniV3MarketSpec`
- `solve_prediction_market`
- `compare_prediction_market_families`

The advanced repeated-solve Julia API remains available by qualified access:

- `ForecastFlows.PredictionMarketWorkspace`
- `ForecastFlows.solve_prediction_market!`

The lower-level prediction-market pieces remain available as qualified names for
Julia-side research when needed:

- `ForecastFlows.SplitMergeEdge` for fee-free mint/merge
- `ForecastFlows.EndowmentLinear` for portfolio-EV benchmarking

For external drivers, keep gas pricing, native-token conversion, tx grouping,
and execution policy outside the package.

`PredictionMarketFixedGasModel` is available when a caller wants a coarse
activation-cost penalty on the public prediction-market path, but it is not an
exact execution-cost oracle.

For non-Julia drivers, use the JSON worker documented in the
[Integration Guide](integration.md).

The older two-node `problem` / `solver_bfgs.jl` path is legacy. It remains in
the package for compatibility and reference, but it is not the recommended API
for new routing implementations.

See the **Examples** and **Advanced Examples** for generic convex-flow usage.
