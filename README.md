# ForecastFlows.jl

`ForecastFlows.jl` is a Julia package for convex-flow optimization on graphs and
hypergraphs, with a prediction-market routing extension built on the dual
decomposition framework from Theo Diamandis's *Convex Network Flows*.

The package now exposes two supported prediction-market integration surfaces:

- an in-process Julia facade:
  - `OutcomeSpec`
  - `PredictionMarketProblem`
  - `ConstantProductMarketSpec`
  - `UniV3MarketSpec`
  - `solve_prediction_market`
  - `compare_prediction_market_families`
- an out-of-process worker:
  - `bin/forecastflows-worker.jl`

The prediction-market router models:

- one collateral asset
- zero or more AMM edges per outcome
- one fee-free mint/merge hyperedge

This lets the solver discover direct and synthetic routes from shadow-price
equilibration instead of explicit path enumeration.

## Install v2.0.0

Once `v2.0.0` is tagged, install the source release directly:

```julia
using Pkg

Pkg.add(url="https://github.com/shotaronowhere/ForecastFlows.jl", rev="v2.0.0")
```

For local development in a checkout, use `Pkg.develop(path=pwd())`.

The supported v2 dependency surfaces are:

- the Julia prediction-market facade
- the newline-delimited JSON worker at `bin/forecastflows-worker.jl`

The advanced repeated-solve Julia API is available by qualified access:

- `ForecastFlows.PredictionMarketWorkspace`
- `ForecastFlows.solve_prediction_market!`

## Dependency quickstart

Use the Julia facade directly:

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

For hot loops, reuse a workspace:

```julia
workspace = ForecastFlows.PredictionMarketWorkspace(problem)

result = ForecastFlows.solve_prediction_market!(
    workspace,
    problem;
    mode=:direct_only,
    solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000),
)
```

Prediction-market solves fail closed by default. If certification fails, or if a
mixed solve still has a near-active split/merge bound after the allowed
doublings, the facade and worker return a solve failure unless you explicitly set
`throw_on_fail=false` to inspect an uncertified result.

Or run the worker and call it from Rust or another driver:

```bash
julia --project bin/forecastflows-worker.jl
```

Worker requests are newline-delimited JSON with `protocol_version = 2`. The
worker returns:

- signed direct AMM trades keyed by `market_id`
- trades and holdings keyed by stable `outcome_id`
- aggregate mint and merge amounts
- initial and final EV
- final collateral and holdings
- certification metadata

Worker numeric inputs must be decimal-scaled token units, not raw wei or other
base-unit integers.

For `UniV3`-style liquidity, the preferred external representation is a list of
bands:

```json
{
  "type": "univ3",
  "market_id": "u1",
  "outcome_id": "YES",
  "current_price": 0.5,
  "bands": [
    {"lower_price": 1.0, "liquidity_L": 10.0},
    {"lower_price": 0.5, "liquidity_L": 12.0},
    {"lower_price": 0.25, "liquidity_L": 10.0}
  ],
  "fee_multiplier": 0.997
}
```

Markets may omit some outcomes entirely when no direct venue is available, and
multiple markets may share the same `outcome_id` when several venues exist for
one outcome. Concentrated-liquidity boundaries are handled inside the `UniV3`
edge model; once a side is exhausted, that edge simply contributes no further
flow. When a venue has a hard terminal price boundary, represent it with one
optional final `bands` entry whose `liquidity_L` is `0.0`.

If `markets=[]`, `mode=:direct_only` returns the trivial no-trade route.
`mode=:mixed_enabled` remains valid because the split/merge hyperedge is still a
real edge even without any direct AMMs.

Gas modeling, tx construction, tx packing, and chain interaction remain driver
responsibilities.

## v2 support matrix

- Julia compat floor: `1.12`
- CI-tested Julia versions: `1.12`
- CI-tested platforms: Linux `x64`, macOS `x64`
- locally release-verified: macOS `arm64`, Julia `1.12`
- supported interfaces: Julia facade and NDJSON worker only

## Deep-Trading Benchmark Sweep

The package includes an opt-in benchmark sweep over the six vendored
Deep-Trading fixtures, evaluated under an aligned single-tick replay model.

The benchmark now tracks three distinct quantities:

- mixed convex raw upper bound from the continuous solver
- executable raw EV after replay
- best-family executable net EV under the pinned Deep-Trading OP snapshot

The raw Deep-Trading provenance fixture remains `test/fixtures/rebalancer_ab_expected.json`.

The Julia-local net benchmark regression fixture is now `test/fixtures/rebalancer_ab_net_expected.json`.

For the heterogeneous 98-outcome L1-like case, the current best-family net EV
under that pinned snapshot is `150.36411702995255`, with `mixed` beating
`direct`.

The benchmark fixtures are vendored under `test/fixtures/`. External solver
repositories are used only as provenance/reference sources and are not part of
the public package source.

This benchmark is a release regression benchmark under the aligned surrogate
execution model. It is not a claim of exact on-chain net EV or blanket
solver-vs-solver dominance.

The realistic 98-outcome latency smoke at `bin/latency-smoke.jl` now uses the
same public `bands` representation with one exact trailing zero-liquidity
terminal band, so its repeated-solve measurements no longer rely on an
approximate extra band.

## v2.0.0 release scope

See `CHANGELOG.md` for the v2.0.0 release notes. The important scope boundary is:

- `ForecastFlows` v2 is a dependency-grade solver release, not a full trading engine
- Rust or another driver still owns supervision, timeouts, gas, tx building, and chain I/O
- the stable public API is the prediction-market facade plus the NDJSON worker
- low-level solver interfaces and gas-pruning helpers remain available only as research-oriented qualified Julia APIs

The intended production boundary is the solver and worker contract. Live
rebalancing still depends on the external driver layer that owns execution,
timeouts, reserve freshness, gas, simulation, and kill switches.

## Run the benchmark

Run the full test suite:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Run the opt-in Deep-Trading compatibility sweep:

```bash
FORECASTFLOWS_RUN_DEEPTRADING_COMPAT=1 julia --project -e 'using Pkg; Pkg.test()'
```

Run the full v2 release gate:

```bash
julia --project bin/release-check.jl
```

This runs:

- the default test suite
- the worker smoke script
- the docs build
- the opt-in Deep-Trading benchmark sweep

## Build docs locally

Bootstrap the docs environment:

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
```

Build the docs:

```bash
julia --project=docs docs/make.jl
```

## Scope and limitations

- The optimizer certifies the continuous convex routing problem.
- The public dependency API returns abstract route plans, not executable tx bundles.
- Executable benchmark results come from a no-flash replay layer.
- Split/merge recovery is specialized to a single `SplitMergeEdge`.
- Internal gas-pruning helpers are research APIs, not part of the stable v2 dependency surface.
- Any future reusable pricing helper should remain non-stable and caller-supplied:
  action schedule, gas price in the native token, `native_token_price_in_collateral`,
  L1 data-fee inputs, and packing limits.
- The Deep-Trading benchmark sweep is opt-in, not a default CI gate.
- Driver-side production safeguards such as tx simulation, reserve freshness,
  block-level gas budgeting, monitoring, and automated shutdown logic are out
  of scope for this package.
- Julia 1.12 docs builds currently emit upstream `Compose` / `GraphPlot`
  warnings from example dependencies; they are non-blocking for `v2.0.0`.

## Optional sysimage

For lower worker cold-start, use:

```bash
julia --project bin/build-worker-sysimage.jl
```

The helper writes the sysimage under `build/` and prints the full output path.
On Linux the extension is `.so`; on macOS it is `.dylib`.

Then start the worker with the generated sysimage path:

```bash
julia --project -J build/forecastflows-worker.<dlext> bin/forecastflows-worker.jl
```

This helper is optional and kept outside the default runtime path.

## Attribution

This package is a public-facing fork/adaptation of the original
`ConvexFlows.jl` research codebase and keeps the convex-flow formulation and
core solver ideas while extending the root solver to prediction-market routing.

See `docs/` for public package documentation and `ROADMAP.md` for remaining
work.
