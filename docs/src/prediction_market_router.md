# Prediction Market Router

The prediction-market extension treats routing as a convex-flow problem over a
hypergraph:

- node `1`: collateral
- nodes `2:(N+1)`: mutually exclusive outcome tokens
- one AMM edge per collateral/outcome market
- one fee-free `SplitMergeEdge` with local ordering `[collateral, outcomes...]`

The router is independent of the Deep-Trading waterfall algorithm. It uses the
convex-flow dual decomposition to discover direct and synthetic routes from the
shadow prices, while the Deep-Trading fixture is used only as a benchmark state
and replay reference.

## Recommended API

Use the prediction-market facade:

```julia
using ForecastFlows

problem = PredictionMarketProblem(
    predictions,
    cash0,
    holdings0,
    markets;
    split_bound=split_bound,
)

result = solve_prediction_market(problem; mode=:mixed_enabled)
```

The public routing surface for this extension is:

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

The lower-level `Solver` / `SplitMergeEdge` / `EndowmentLinear` interface
remains available and is still the right escape hatch for custom routing
experiments. The new facade is the stable package boundary for the standard
one-collateral, one-market-per-outcome use case.

For non-Julia drivers, the supported v1 production interface is the worker
protocol, not embedded Julia or FFI.

The benchmark-only single-tick edge and replay engine live in tests on purpose.
They are comparison machinery for the vendored Deep-Trading fixtures, not
public package API.

## Worker integration

For Rust or other non-Julia drivers, use the worker:

```bash
julia --project bin/forecastflows-worker.jl
```

The worker uses newline-delimited JSON with `protocol_version = 1` and supports:

- `health`
- `solve_prediction_market`
- `compare_prediction_market_families`

See the [Integration Guide](integration.md) for request and response shapes.
That guide also documents the preferred `UniV3` liquidity shape and the
decimal-unit convention for worker inputs. The worker is serial: one request at
a time per process.

## Deep-Trading benchmark sweep

The package ships an opt-in benchmark sweep over the six vendored
Deep-Trading fixtures, under an aligned single-tick replay model.

The benchmark tracks three distinct quantities:

- mixed convex raw upper bound from the continuous mixed-enabled solve
- executable raw EV after replay
- best-family executable net EV under the pinned Deep-Trading OP snapshot

The pinned benchmark snapshot used by the test-local pricing layer is:

- `gas_price_wei = 1_002_325`
- `eth_usd = 3000`
- `l1_fee_per_byte_wei = 1_643_855.3414634147`
- `l1_data_fee_floor_susd = 0`

The raw provenance fixture remains `test/fixtures/rebalancer_ab_expected.json`.
The Julia-local net benchmark regression fixture is
`test/fixtures/rebalancer_ab_net_expected.json`.

For the heterogeneous 98-outcome L1-like case, the current benchmark winner is
`mixed`, with best-family net EV `150.36411702995255`.

This benchmark is a release regression benchmark under the aligned surrogate
execution model. It is not an exact on-chain execution guarantee, and it should
not be described as blanket proof of solver dominance over other systems.

Run the opt-in raw benchmark with:

```bash
FORECASTFLOWS_RUN_DEEPTRADING_BENCHMARK=1 julia --project -e 'using Pkg; Pkg.test()'
```

Run the full manual release gate with:

```bash
julia --project bin/release-check.jl
```

## Known Limitations

- The solver certifies the continuous convex routing problem, not direct
  on-chain execution.
- The public API returns route plans and certificates, not transaction bundles.
- The executable benchmark value comes from a no-flash replay layer.
- Split/merge recovery is specialized to a single `SplitMergeEdge`.
- `solve_with_fixed_gas!` remains a rough fixed-charge proxy, not the
  Deep-Trading benchmark comparator.
- The Deep-Trading benchmark sweep is opt-in and is not a default CI gate.
- v1 scope is solver dependency use only; tx construction and chain interaction
  stay outside this package.

## Benchmark provenance

The benchmark comparison is apples-to-apples for raw EV under the aligned
single-tick replay model. The net-EV regression is Julia-local, but it is
priced against a pinned Deep-Trading-style grouped gas snapshot instead of the
generic fixed-charge pruning helper.

Only the benchmark fixture data is shared with Deep-Trading. The convex solver,
its split/merge hyperedge, the replay adapter, and the grouped pricing layer in
this package are independent implementations.

The benchmark fixtures themselves are vendored under `test/fixtures/`, with
upstream commit provenance recorded in `test/fixtures/PROVENANCE.md`.
