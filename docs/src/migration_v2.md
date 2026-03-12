# Migration v2

ForecastFlows v2 cleans up the prediction-market dependency boundary.

## Julia facade changes

- `OutcomeSpec` is new and is now the canonical outcome input type.
- `PredictionMarketProblem` now takes `outcomes, collateral_balance, markets`.
- Public `outcome_index` has been replaced by stable `outcome_id`.
- `initial_cash` / `final_cash` have been renamed to `initial_collateral` / `final_collateral`.
- Solver tuning should now be passed through `solver_options=(; ...)`.
- Outcomes may now have zero, one, or many direct AMM markets.
- v1-style Julia constructors and legacy solve kwargs are not supported.

## Worker changes

- `protocol_version = 2` is required.
- `problem.outcomes` replaces `problem.outcome_values` and `problem.initial_holdings`.
- `problem.collateral_balance` replaces `problem.initial_cash`.
- `market.outcome_id` replaces `market.outcome_index`.
- `univ3` requests must send `bands`; the low-level `lower_ticks` / `liquidity_k`
  shape is not part of the v2 protocol.

Protocol v1 payloads are rejected intentionally rather than parsed in the hot
path.

## Repeated solves

v2 adds a public qualified workspace API:

```julia
workspace = ForecastFlows.PredictionMarketWorkspace(problem)
result = ForecastFlows.solve_prediction_market!(workspace, problem; mode=:direct_only)
```

Use this for repeated solves from Julia. Foreign-language drivers should keep
using the stateless worker unless a later measured bottleneck justifies a
different transport. The workspace stores internal solver state, but those
fields are implementation details rather than part of the stable contract.
