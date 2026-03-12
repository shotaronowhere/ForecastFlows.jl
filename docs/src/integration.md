# Integration Guide

ForecastFlows is now packaged for dependency use in two ways:

- in-process Julia via the public prediction-market facade
- out-of-process via the JSON worker at `bin/forecastflows-worker.jl`

Install the tagged source release with:

```julia
using Pkg

Pkg.add(url="https://github.com/shotaronowhere/ForecastFlows.jl", rev="v1.0.0")
```

For a Rust driver, the supported production path is the worker. Rust should own:

- market-state collection
- gas modeling
- tx construction and packing
- chain submission and retries

ForecastFlows should own:

- convex optimization
- route recovery
- certification metadata

## v1 support matrix

- Julia `1.10`
- Linux `x64`
- macOS `x64`
- supported dependency interfaces: Julia facade and JSON worker

## Public facade

The facade is the stable Julia API for the one-collateral, one-market-per-outcome
router:

- `PredictionMarketProblem`
- `ConstantProductMarketSpec`
- `UniV3MarketSpec`
- `solve_prediction_market`
- `compare_prediction_market_families`

Example:

```julia
using ForecastFlows

problem = PredictionMarketProblem(
    [0.55, 0.45],
    1.0,
    [0.0, 0.0],
    [
        ConstantProductMarketSpec("m1", 1, 40.0, 100.0, 1.0),
        ConstantProductMarketSpec("m2", 2, 70.0, 100.0, 1.0),
    ];
    split_bound=5.0,
)

result = solve_prediction_market(
    problem;
    mode=:mixed_enabled,
    pgtol=1e-8,
    max_iter=5_000,
    max_fun=10_000,
    max_doublings=0,
)
```

Returned data is deliberately abstract:

- signed direct AMM trades keyed by `market_id`
- aggregate mint and merge amounts
- initial and final EV
- final cash and holdings
- certification summary

It does not include tx grouping, gas pricing, calldata packing, or chain I/O.

Worker numeric inputs must be decimal-scaled token units. Do not send raw wei
or other base-unit integers.

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

spec = UniV3MarketSpec("u1", 1, 0.5, bands, 0.997)
```

Each band is:

- `lower_price`: the outcome price at the top of the band
- `liquidity_L`: the standard Uniswap-style liquidity parameter `L`

Bands may be supplied in any order; ForecastFlows normalizes them to the
descending order required by the low-level edge.

The legacy low-level form with `lower_ticks` and `liquidity` is still accepted,
but it is easier to misuse:

- `lower_ticks` are descending prices, not integer tick indices
- `liquidity` is the internal reserve-product weight `L^2`, not `L`

## Worker protocol

The worker speaks newline-delimited JSON on stdin/stdout.

- `protocol_version = 1`
- commands: `health`, `solve_prediction_market`, `compare_prediction_market_families`
- `outcome_index` is 1-based
- numeric inputs are decimal token units
- execution model: serial, one request at a time per worker process

Example request:

```json
{"protocol_version":1,"request_id":"solve-1","command":"solve_prediction_market","mode":"mixed_enabled","problem":{"outcome_values":[0.55,0.45],"initial_cash":1.0,"initial_holdings":[0.0,0.0],"markets":[{"type":"constant_product","market_id":"m1","outcome_index":1,"collateral_reserve":40.0,"outcome_reserve":100.0,"fee_multiplier":1.0},{"type":"constant_product","market_id":"m2","outcome_index":2,"collateral_reserve":70.0,"outcome_reserve":100.0,"fee_multiplier":1.0}],"split_bound":5.0},"solve_options":{"pgtol":1e-8,"max_iter":5000,"max_fun":10000,"max_doublings":0}}
```

Example success response:

```json
{"protocol_version":1,"request_id":"solve-1","ok":true,"command":"solve_prediction_market","result":{"status":"certified","mode":"mixed_enabled","trades":[{"market_id":"m1","outcome_index":1,"collateral_delta":0.6666661145101713,"outcome_delta":-1.6949138266566024},{"market_id":"m2","outcome_index":2,"collateral_delta":3.3333333236415967,"outcome_delta":-4.999999984735524}],"split_merge":{"mint":5.0,"merge":0.0}}}
```

Example error response:

```json
{"protocol_version":1,"request_id":"bad-1","ok":false,"error":{"code":"invalid_request","message":"mode must be :direct_only or :mixed_enabled"}}
```

## Process model

Recommended Rust-side lifecycle:

1. Start one long-lived Julia worker per process or per strategy shard.
2. Send `health` before the first solve request.
3. Send one request at a time to each worker process.
4. Set a driver-side timeout for each request and kill/restart the worker on timeout.
5. Reuse the worker for repeated solve requests.
6. Restart the worker if it exits, returns malformed JSON, or returns a response that fails local schema validation.

The worker is deterministic for fixed inputs and solver options.

For parallelism, run multiple worker processes. The worker itself does not expose
concurrent request handling.

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

The reproducible manual release gate for v1 is:

```bash
julia --project bin/release-check.jl
```

That script runs the default tests, the standalone worker smoke script, the docs
build, and the opt-in Deep-Trading benchmark sweep.
