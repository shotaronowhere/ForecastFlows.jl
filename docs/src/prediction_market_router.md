# Prediction Market Router

The prediction-market extension treats routing as a convex-flow problem over a
hypergraph:

- node `1`: collateral
- nodes `2:(N+1)`: mutually exclusive outcome tokens
- zero or more AMM edges per outcome
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

The stable public routing surface is:

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

Direct-only problems with `markets=[]` are valid and return the trivial
no-trade route. Mixed-enabled problems with no direct AMMs are also valid
because split/merge remains a first-class hyperedge.

Prediction-market solves fail closed by default. If certification fails, or if a
mixed solve still has a near-active split/merge bound after the allowed
doublings, `solve_prediction_market` throws instead of quietly returning a
clipped route. Pass `throw_on_fail=false` only when you explicitly want to
inspect an uncertified result.

If `split_bound` is omitted, mixed solves seed it from
`collateral_balance + sum(initial_holding)` with a tiny positive floor. That
keeps a zero-balance portfolio on the zero-trade route instead of tripping the
near-active split/merge guard at a literal bound of `0`.

The lower-level `Solver` / `SplitMergeEdge` / `EndowmentLinear` interface
remains available as qualified Julia API for custom routing experiments, but it
is no longer part of the exported stable package surface.

## Repeated solves

For repeated calls from a Julia hot loop, use the workspace API:

```julia
workspace = ForecastFlows.PredictionMarketWorkspace(problem)

result = ForecastFlows.solve_prediction_market!(
    workspace,
    problem;
    mode=:direct_only,
    solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000),
)
```

The workspace reuses normalized topology and, when possible, solver buffers and
dual seeds. The input problem must keep the same outcome IDs and market layout,
including repeated markets that share one `outcome_id`.

## Worker integration

For Rust or other non-Julia drivers, use the worker:

```bash
julia --project=. bin/forecastflows-worker.jl
```

The worker uses newline-delimited JSON with `protocol_version = 2` and supports:

- `health`
- `solve_prediction_market`
- `compare_prediction_market_families`

See the [Integration Guide](integration.md) for request and response shapes.
That guide also documents the preferred `UniV3` liquidity shape and the
decimal-unit convention for worker inputs. Missing direct pools are represented
by omitting those markets from the problem entirely. The worker is stateless and
processes one request at a time per process.

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

These constants are benchmark provenance only. They are not stable API defaults.
Production drivers should supply their own action cost schedule, gas price,
native-token-to-collateral conversion, and L1 data-fee inputs.

The raw provenance fixture remains `test/fixtures/rebalancer_ab_expected.json`.
The Julia-local net benchmark regression fixture is
`test/fixtures/rebalancer_ab_net_expected.json`.

For the heterogeneous 98-outcome L1-like case, the current benchmark winner is
`mixed`, with best-family net EV `150.36411702995255`.

This benchmark is a release regression benchmark under the aligned surrogate
execution model. It is not an exact on-chain execution guarantee, and it should
not be described as blanket proof of solver dominance over other systems.

Run the opt-in downstream compatibility benchmark with:

```bash
FORECASTFLOWS_RUN_DEEPTRADING_COMPAT=1 julia --project -e 'using Pkg; Pkg.test()'
```

Run the full manual release gate with:

```bash
julia --project=. bin/release-check.jl
```

## Known Limitations

- The solver certifies the continuous convex routing problem, not direct
  on-chain execution.
- The public API returns route plans and certificates, not transaction bundles.
- The executable benchmark value comes from a no-flash replay layer.
- Split/merge recovery is specialized to a single `SplitMergeEdge`.
- The benchmark pricing layer is test-local provenance, not part of the stable
  dependency surface.
- The Deep-Trading benchmark sweep is opt-in and is not a default CI gate.
- Tx construction, chain interaction, gas pricing, and safety policy stay
  outside this package.

## Benchmark provenance

The benchmark comparison is apples-to-apples for raw EV under the aligned
single-tick replay model. The net-EV regression is Julia-local, but it is
priced against a pinned Deep-Trading-style grouped gas snapshot instead of any
stable package API.

Only the benchmark fixture data is shared with Deep-Trading. The convex solver,
its split/merge hyperedge, the replay adapter, and the grouped pricing layer in
this package are independent implementations.

The benchmark fixtures themselves are vendored under `test/fixtures/`, with
upstream commit provenance recorded in `test/fixtures/PROVENANCE.md`.
