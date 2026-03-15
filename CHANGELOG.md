# Changelog

## v2.0.0 - 2026-03-12

- Establish the stable prediction-market dependency boundary:
  - exported facade centered on `OutcomeSpec`, `PredictionMarketProblem`, market specs, pure-data solve results, `solve_prediction_market`, and `compare_prediction_market_families`
  - stable public qualified APIs for `PredictionMarketWorkspace`, `solve_prediction_market!`, and the typed NDJSON protocol helpers
  - v2-only stateless NDJSON worker contract with strict request parsing and stable `invalid_request` / `solve_failed` / `internal_error` error codes
- Clean up the prediction-market model for dependency use:
  - stable `outcome_id`-based inputs and results
  - collateral-denominated result terminology
  - zero, one, or many direct markets per outcome
  - direct-only zero-market problems return the trivial no-trade route
  - `UniV3LiquidityBand(lower_price, liquidity_L)` is the stable concentrated-liquidity shape, with one optional trailing zero-liquidity terminal band
- Add the reusable Julia hot-loop API via `PredictionMarketWorkspace`, with topology checks for repeated solves.
- Keep the package gas-free at the stable dependency boundary:
  - ForecastFlows owns continuous route optimization, split/merge-aware recovery, and certification
  - external drivers own gas schedules, native-token pricing, collateral conversion, tx grouping, calldata pricing, simulation, submission, retries, and safety policy
  - internal gas-pruning helpers remain research-only qualified Julia APIs and are not part of the stable v2 contract
- Keep the Deep-Trading-style grouped gas schedule and pricing snapshot as pinned benchmark provenance only; they are not stable API defaults or recommended production inputs.
- Add release tooling and verification:
  - `bin/worker-smoke.jl`
  - `bin/latency-smoke.jl` with the realistic 98-outcome latency case
  - `bin/release-boundary-check.jl`
  - `bin/release-check.jl`
  - protocol fixtures and API-boundary tests
- Benchmark and release notes:
  - the realistic 98-outcome benchmark remains informational and machine-dependent
  - the Deep-Trading benchmark sweep is an opt-in regression benchmark under the documented surrogate execution model, not proof of exact on-chain net EV
  - Julia 1.12 docs builds currently emit upstream `Compose` / `GraphPlot` world-age warnings from example dependencies; this is a non-blocking follow-up item for v2.0.0
