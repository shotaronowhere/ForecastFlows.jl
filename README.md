# ForecastFlows.jl

`ForecastFlows.jl` is a Julia package for convex-flow optimization on graphs and
hypergraphs, with a prediction-market routing extension built on the dual
decomposition framework from Theo Diamandis's *Convex Network Flows*.

The package now exposes two supported prediction-market integration surfaces:

- an in-process Julia facade:
  - `PredictionMarketProblem`
  - `ConstantProductMarketSpec`
  - `UniV3MarketSpec`
  - `solve_prediction_market`
  - `compare_prediction_market_families`
- an out-of-process worker:
  - `bin/forecastflows-worker.jl`

The prediction-market router models:

- one collateral asset
- one AMM edge per collateral/outcome market
- one fee-free mint/merge hyperedge

This lets the solver discover direct and synthetic routes from shadow-price
equilibration instead of explicit path enumeration.

## Install v1.0.0

Until the package is published in the General registry, install the tagged
source release directly:

```julia
using Pkg

Pkg.add(url="https://github.com/shotaronowhere/ForecastFlows.jl", rev="v1.0.0")
```

The supported v1 dependency surfaces are:

- the Julia prediction-market facade
- the newline-delimited JSON worker at `bin/forecastflows-worker.jl`

## Dependency quickstart

Use the Julia facade directly:

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

result = solve_prediction_market(problem; mode=:mixed_enabled, max_doublings=0, throw_on_fail=false)
```

Prediction-market solves fail closed by default. If certification fails, or if a
mixed solve still has a near-active split/merge bound after the allowed
doublings, the facade and worker return a solve failure unless you explicitly set
`throw_on_fail=false` to inspect an uncertified result.

Or run the worker and call it from Rust or another driver:

```bash
julia --project bin/forecastflows-worker.jl
```

Worker requests are newline-delimited JSON with `protocol_version = 1`. The
worker returns:

- signed direct AMM trades keyed by `market_id`
- aggregate mint and merge amounts
- initial and final EV
- final cash and holdings
- certification metadata

Worker numeric inputs must be decimal-scaled token units, not raw wei or other
base-unit integers.

For `UniV3`-style liquidity, the preferred external representation is a list of
bands:

```json
{
  "type": "univ3",
  "market_id": "u1",
  "outcome_index": 1,
  "current_price": 0.5,
  "bands": [
    {"lower_price": 1.0, "liquidity_L": 10.0},
    {"lower_price": 0.5, "liquidity_L": 12.0},
    {"lower_price": 0.25, "liquidity_L": 10.0}
  ],
  "fee_multiplier": 0.997
}
```

The legacy low-level form using `lower_ticks` and `liquidity` remains accepted,
but those fields are less intuitive: `lower_ticks` are descending prices, not
integer ticks, and `liquidity` is the internal `L^2` weight.

Gas modeling, tx construction, tx packing, and chain interaction remain driver
responsibilities.

## v1 support matrix

- Julia compat floor: `1.10`
- CI-tested Julia versions: `1.10`, `1.12`
- Linux `x64`
- macOS `x64`
- supported interfaces: Julia facade and JSON worker only

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

## v1.0.0 release scope

See `CHANGELOG.md` for the v1.0.0 release notes. The important scope boundary is:

- `ForecastFlows` v1 is a dependency-grade solver release, not a full trading engine
- Rust or another driver still owns supervision, timeouts, gas, tx building, and chain I/O
- `solve_with_fixed_gas!` remains a rough fixed-charge proxy, not benchmark truth

The intended production boundary is the solver and worker contract. Live
rebalancing still depends on the external driver layer that owns execution,
timeouts, reserve freshness, gas, simulation, and kill switches.

## Run the benchmark

Run the full test suite:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Run the opt-in Deep-Trading benchmark sweep:

```bash
FORECASTFLOWS_RUN_DEEPTRADING_BENCHMARK=1 julia --project -e 'using Pkg; Pkg.test()'
```

Run the full v1 release gate:

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
- `solve_with_fixed_gas!` remains a rough fixed-charge proxy, not the
  Deep-Trading benchmark comparator.
- The Deep-Trading benchmark sweep is opt-in, not a default CI gate.
- Driver-side production safeguards such as tx simulation, reserve freshness,
  block-level gas budgeting, monitoring, and automated shutdown logic are out
  of scope for this package.

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
