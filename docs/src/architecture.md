# Architecture

ForecastFlows v2 is structured around three layers.

## Stable exported facade

This is the dependency-grade prediction-market surface:

- `OutcomeSpec`
- `PredictionMarketProblem`
- market specs
- pure-data solve results
- `solve_prediction_market`
- `compare_prediction_market_families`

This layer is prediction-market-specific, collateral-denominated, and free of
execution policy. Problems may omit direct markets for some outcomes or include
multiple direct venues for one `outcome_id`.

## Stable public qualified APIs

These names are stable, but intentionally not exported:

- `ForecastFlows.PredictionMarketWorkspace`
- `ForecastFlows.solve_prediction_market!`
- typed protocol request/response helpers
- NDJSON helpers like `ForecastFlows.handle_protocol_json`

These are the right entrypoints for hot-loop Julia callers and foreign-language
drivers that want a typed protocol boundary.

## Internal and research APIs

The generic convex-flow solver, low-level edges, legacy two-node helpers, and
gas-pruning utilities remain in the package for research and custom Julia work.
They are accessible by qualified name, but they are not part of the exported
stable dependency surface.

## Boundary rules

- ForecastFlows owns continuous route optimization, route recovery, and solver certification.
- Downstream drivers own gas, native-token pricing, tx grouping, calldata packing, RPC, retries, and kill switches.
- The worker protocol is stateless and transport-oriented; it does not carry session or execution semantics.
- The workspace API is Julia-only and is the package’s answer for repeated solves with topology reuse.
