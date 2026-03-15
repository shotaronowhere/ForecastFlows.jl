# API Reference

The supported v2 dependency interfaces are the prediction-market facade plus
the NDJSON worker protocol.

Stable exported facade:

- `OutcomeSpec`
- `PredictionMarketProblem`
- `ConstantProductMarketSpec`
- `UniV3MarketSpec`
- `UniV3LiquidityBand`
- `PredictionMarketTrade`
- `SplitMergePlan`
- `PredictionMarketFixedGasModel`
- `SolveCertificateSummary`
- `PredictionMarketSolveResult`
- `solve_prediction_market`
- `compare_prediction_market_families`

Stable public qualified APIs:

- `ForecastFlows.PredictionMarketWorkspace`
- `ForecastFlows.solve_prediction_market!`
- `ForecastFlows.compare_prediction_market_families!`
- `ForecastFlows.PREDICTION_MARKET_PROTOCOL_VERSION`
- `ForecastFlows.HealthRequest`
- `ForecastFlows.SolveRequest`
- `ForecastFlows.CompareRequest`
- `ForecastFlows.HealthResponse`
- `ForecastFlows.SolveResponse`
- `ForecastFlows.CompareResponse`
- `ForecastFlows.ErrorResponse`
- `ForecastFlows.parse_protocol_request`
- `ForecastFlows.handle_protocol_request`
- `ForecastFlows.render_protocol_response`
- `ForecastFlows.handle_protocol_json`
- `ForecastFlows.serve_protocol`

Research and generic convex-flow APIs remain available as qualified Julia names,
but they are outside the stable exported dependency surface.

For the exported `UniV3MarketSpec`, the stable external shape is `bands`. The
normalized `lower_ticks` / `liquidity_k` storage is internal.

For `ForecastFlows.PredictionMarketWorkspace`, normal public introspection
exposes topology summary only; the stored solver fields are implementation
details.

## Stable Facade

```@docs
OutcomeSpec
PredictionMarketProblem
ConstantProductMarketSpec
UniV3LiquidityBand
UniV3MarketSpec
PredictionMarketTrade
SplitMergePlan
PredictionMarketFixedGasModel
SolveCertificateSummary
PredictionMarketSolveResult
solve_prediction_market
compare_prediction_market_families
```

## Public Qualified APIs

```@docs
ForecastFlows.PredictionMarketWorkspace
ForecastFlows.solve_prediction_market!
ForecastFlows.compare_prediction_market_families!
ForecastFlows.PREDICTION_MARKET_PROTOCOL_VERSION
ForecastFlows.HealthRequest
ForecastFlows.SolveRequest
ForecastFlows.CompareRequest
ForecastFlows.HealthResponse
ForecastFlows.SolveResponse
ForecastFlows.CompareResponse
ForecastFlows.ErrorResponse
ForecastFlows.handle_protocol_request
ForecastFlows.parse_protocol_request
ForecastFlows.render_protocol_response
ForecastFlows.handle_protocol_json
ForecastFlows.serve_protocol
```
