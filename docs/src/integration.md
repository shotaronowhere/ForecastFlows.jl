# Integration Guide

ForecastFlows exposes two supported dependency boundaries:

- an in-process Julia prediction-market facade
- a cached NDJSON worker at `bin/forecastflows-worker.jl`

Once `v2.0.0` is tagged, install the source release with:

```julia
using Pkg

Pkg.add(url="https://github.com/shotaronowhere/ForecastFlows.jl", rev="v2.0.0")
```

For local development in a checkout, use `Pkg.develop(path=pwd())`.

Downstream drivers should own:

- market-state collection
- gas and native-token pricing
- tx grouping, calldata packing, and simulation
- RPC polling, submission, retries, and kill switches

ForecastFlows should own:

- convex route optimization
- split/merge-aware route recovery
- certification metadata

## v2 support matrix

- Julia compat floor: `1.12`
- CI-tested Julia versions: `1.12`
- CI-tested platforms: Linux `x64`, macOS `x64`
- locally release-verified: macOS `arm64`, Julia `1.12`
- supported dependency interfaces: Julia facade and NDJSON worker

## Stable Julia facade

The stable prediction-market facade is:

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

Example:

```julia
using ForecastFlows

problem = PredictionMarketProblem(
    [
        OutcomeSpec("YES", 0.55, 0.0),
        OutcomeSpec("NO", 0.45, 0.0),
    ],
    1.0,
    [
        ConstantProductMarketSpec("m1", "YES", 40.0, 100.0, 1.0),
        ConstantProductMarketSpec("m2", "NO", 70.0, 100.0, 1.0),
    ];
    split_bound=5.0,
)

result = solve_prediction_market(
    problem;
    mode=:mixed_enabled,
    max_doublings=0,
    throw_on_fail=false,
    solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000),
)
```

Prediction-market solves fail closed by default. If the solver cannot certify
the route, or if a mixed solve exhausts `max_doublings` while the split/merge
bound is still near-active, `solve_prediction_market` throws. Pass
`throw_on_fail=false` only when you explicitly want to inspect an uncertified
result.

Returned data is deliberately abstract:

- signed direct AMM trades keyed by `market_id` and `outcome_id`
- aggregate mint and merge amounts
- initial and final EV
- final collateral and holdings
- certification summary

It does not include gas pricing, tx grouping, calldata packing, or chain I/O.

If a downstream wants the public facade to penalize route activation, it may
pass one of two gas models at solve time:

- `PredictionMarketFixedGasModel`: one cost per direct market edge plus one cost
  for the split/merge edge
- `PredictionMarketExecutionGasModel`: execution-only additive pricing with
  separate buy/sell swap costs plus base-and-per-outcome mint/merge costs,
  scaled into collateral units by `gas_price_native * collateral_per_native`

Both gas models use the same bounded outer fixed-fee wrapper:

1. solve the full problem with the ordinary smooth solver
2. build an active set from edge execution value versus fixed cost
3. re-solve the reduced smooth problem from a warm start
4. allow one stabilization re-solve if the active set flips

This keeps the optimization loop smooth while still exposing gas-aware routing
through the public API.

`PredictionMarketFixedGasModel` supplies the per-edge fixed costs directly.
`PredictionMarketExecutionGasModel` is richer: ForecastFlows first solves the
gas-free problem, infers concrete per-edge buy/sell and mint/merge costs from
the realized route direction, then runs the fixed-fee wrapper on that
direction-aware edge-cost vector. Reported `estimated_execution_cost` and
`net_ev` are always computed from the final solved trades and split/merge plan,
not from an internal conservative proxy.

## Repeated solves

For hot loops, ForecastFlows exposes a public qualified workspace API:

- `ForecastFlows.PredictionMarketWorkspace`
- `ForecastFlows.solve_prediction_market!`
- `ForecastFlows.compare_prediction_market_families!`

Example:

```julia
workspace = ForecastFlows.PredictionMarketWorkspace(problem)

result = ForecastFlows.solve_prediction_market!(
    workspace,
    problem;
    mode=:direct_only,
    solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000),
)
```

Workspace reuse requires the same topology:

- the same `outcome_id` values in the same order
- the same `market_id` values in the same order
- the same market types
- the same `UniV3` band counts

`compare_prediction_market_families(problem)` already reuses one
`PredictionMarketWorkspace(problem)` internally, and
`compare_prediction_market_families!(workspace, problem)` lets callers keep that
workspace alive across repeated compatible direct-vs-mixed compares.

## Liquidity shape

For constant-product markets, callers specify:

- `collateral_reserve`
- `outcome_reserve`
- `fee_multiplier`

For multi-band `UniV3` markets, the preferred shape is a band list:

```julia
bands = [
    UniV3LiquidityBand(1.0, 10.0),
    UniV3LiquidityBand(0.5, 12.0),
    UniV3LiquidityBand(0.25, 10.0),
]

spec = UniV3MarketSpec("u1", "YES", 0.5, bands, 0.997)
```

Each band is:

- `lower_price`: the outcome price at the top of the band
- `liquidity_L`: the standard Uniswap-style liquidity parameter `L`

`liquidity_L = 0` is allowed only for one optional final band that marks a hard
exhausted-liquidity boundary while keeping the request on the stable public
`bands` representation.

`PredictionMarketProblem` may omit direct markets for some outcomes, and it may
include multiple direct markets with the same `outcome_id`. Omitted markets mean
"no direct venue"; there is no placeholder market type for empty liquidity.
Concentrated-liquidity exhaustion is handled inside the `UniV3` edge model. Once
the relevant side of a band is exhausted, that edge simply contributes no
further flow.

If `markets=[]`, `solve_prediction_market(problem; mode=:direct_only)` returns a
trivial no-trade result. `mode=:mixed_enabled` remains valid because the split/
merge hyperedge still spans the declared outcomes.

## Worker protocol

The worker speaks newline-delimited JSON on stdin/stdout.

- `protocol_version = 2`
- commands: `health`, `solve_prediction_market`, `compare_prediction_market_families`
- `outcome_id` is the stable outcome reference
- numeric inputs are decimal collateral/outcome units
- execution model: cached NDJSON, one request at a time per worker process

Compare requests may include either no gas model, the legacy fixed-activation
shape, or the tagged execution-gas union:

```json
{
  "kind": "execution_additive",
  "buy_swap_gas_units": 57542.0,
  "sell_swap_gas_units": 38099.0,
  "mint_base_gas_units": 17783.0,
  "mint_per_outcome_gas_units": 0.0,
  "merge_base_gas_units": 37370.0,
  "merge_per_outcome_gas_units": 0.0,
  "gas_price_native": 1.002325e-12,
  "collateral_per_native": 3000.0
}
```

Worker compare responses also include `workspace_reused` so callers can
distinguish cold topology setup from steady-state repeated compares.

Example request:

```json
{
  "protocol_version": 2,
  "request_id": "solve-1",
  "command": "solve_prediction_market",
  "mode": "mixed_enabled",
  "problem": {
    "outcomes": [
      {"outcome_id": "YES", "fair_value": 0.55, "initial_holding": 0.0},
      {"outcome_id": "NO", "fair_value": 0.45, "initial_holding": 0.0}
    ],
    "collateral_balance": 1.0,
    "markets": [
      {"type": "constant_product", "market_id": "m1", "outcome_id": "YES", "collateral_reserve": 40.0, "outcome_reserve": 100.0, "fee_multiplier": 1.0},
      {"type": "constant_product", "market_id": "m2", "outcome_id": "NO", "collateral_reserve": 70.0, "outcome_reserve": 100.0, "fee_multiplier": 1.0}
    ],
    "split_bound": 5.0
  },
  "solve_options": {
    "throw_on_fail": false,
    "pgtol": 1e-8,
    "max_iter": 5000,
    "max_fun": 10000,
    "max_doublings": 0
  }
}
```

Example success response:

```json
{
  "protocol_version": 2,
  "request_id": "solve-1",
  "ok": true,
  "command": "solve_prediction_market",
  "result": {
    "status": "uncertified",
    "mode": "mixed_enabled",
    "trades": [
      {"market_id": "m1", "outcome_id": "YES", "collateral_delta": 0.6666661145101713, "outcome_delta": -1.6949138266566024},
      {"market_id": "m2", "outcome_id": "NO", "collateral_delta": 3.3333333236415967, "outcome_delta": -4.999999984735524}
    ],
    "split_merge": {"mint": 5.0, "merge": 0.0}
  }
}
```

Worker solves also fail closed by default. To inspect an uncertified result over
JSON, set `solve_options.throw_on_fail=false`; in that mode, any non-finite
certificate numbers are encoded as `null` so the worker still returns valid
JSON.

Example error response:

```json
{"protocol_version":2,"request_id":"bad-1","ok":false,"error":{"code":"invalid_request","message":"unsupported command: wat"}}
```

Protocol v1 payloads are rejected intentionally. Use the v2 `outcomes` /
`collateral_balance` / `outcome_id` shape. Old `outcome_values` /
`initial_cash` / `outcome_index` payloads must be updated by the caller; they
are not parsed by the worker.

## Process model

Recommended driver-side lifecycle:

1. Start one long-lived Julia worker per process or per strategy shard.
2. Send `health` before the first solve request.
3. Send one request at a time to each worker process.
4. Set a driver-side timeout for each request and kill/restart the worker on timeout.
5. Reuse the worker for repeated solve requests.
6. Restart the worker if it exits, returns malformed JSON, or returns a response that fails local schema validation.

For parallelism, run multiple worker processes. The worker itself does not
expose concurrent request handling.

## Cold-start reduction

The optional sysimage helper is `bin/build-worker-sysimage.jl`.

It is intentionally outside the default runtime path. Use it only if startup
latency matters enough to justify a Julia deployment artifact.

If you build it, run the worker with:

```bash
julia --project -J build/forecastflows-worker.<dlext> bin/forecastflows-worker.jl
```

The helper writes the sysimage under `build/` and prints the exact path. The
extension is `.so` on Linux and `.dylib` on macOS.

## Release gate

The reproducible manual release gate for v2 is:

```bash
julia --project bin/release-check.jl
```

That script runs the default tests, the standalone worker smoke script, the docs
build, and the opt-in Deep-Trading benchmark sweep.
