# ForecastFlows Architecture

ForecastFlows v2 has one exported stable boundary and one public qualified
boundary.

## Exported stable boundary

The exported dependency surface is prediction-market-specific:

- `OutcomeSpec`
- `PredictionMarketProblem`
- `ConstantProductMarketSpec`
- `UniV3MarketSpec`
- `UniV3LiquidityBand`
- `PredictionMarketTrade`
- `SplitMergePlan`
- `SolveCertificateSummary`
- `PredictionMarketSolveResult`
- `solve_prediction_market`
- `compare_prediction_market_families`

This is the contract other projects should depend on by default.
Problems may omit direct venues for some outcomes or include multiple direct
markets for one `outcome_id`.

## Public qualified boundary

The advanced, still-stable qualified APIs are:

- `ForecastFlows.PredictionMarketWorkspace`
- `ForecastFlows.solve_prediction_market!`
- typed protocol helpers
- `ForecastFlows.handle_protocol_json`
- `ForecastFlows.serve_protocol`

These APIs are stable but intentionally not exported.

## Internal and research layer

The generic convex-flow solver, low-level edges, gas-pruning helpers, and legacy
two-node interfaces remain available as qualified Julia names for research and
custom experimentation. They are not part of the exported dependency surface.

## Ownership split

- ForecastFlows owns route optimization, split/merge-aware recovery, and certification metadata.
- Downstream drivers own gas, pricing, tx construction, RPC, simulation, submission, retries, and safety policy.
- The NDJSON worker is stateless and transport-oriented.
- The workspace API is Julia-only and is the package’s repeated-solve primitive.
