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

Use the root solver interface:

```julia
using ForecastFlows

objective = EndowmentLinear(vcat([1.0], predictions), vcat([cash0], holdings0))
s = Solver(flow_objective=objective, edges=edges, n=length(predictions) + 1)
solve!(s)
```

The public routing surface for this extension is:

- `Solver`
- `solve!`
- `SplitMergeEdge`
- `EndowmentLinear`
- `certify_solution`
- `solve_with_fixed_gas!`

The benchmark-only single-tick edge and replay engine live in tests on purpose.
They are comparison machinery for the 98-market fixture, not public package API.

## 98-market benchmark

The package ships an opt-in benchmark based on the realistic 98-market
Deep-Trading fixture, under an aligned single-tick replay model.

Validated raw results:

- baseline EV: `150.22005815295148`
- direct raw / replayed EV: `150.25828864961397` / `150.25828864961383`
- mixed raw / replayed EV: `150.38032237147735` / `150.3803223714772`

Validated gas-proxy result:

- gas-proxy net EV: `150.36336211734135`

Run the opt-in raw benchmark with:

```bash
FORECASTFLOWS_RUN_DEEPTRADING_BENCHMARK=1 julia --project -e 'using Pkg; Pkg.test()'
```

Run the opt-in raw + gas-proxy benchmark with:

```bash
FORECASTFLOWS_RUN_DEEPTRADING_BENCHMARK=1 FORECASTFLOWS_RUN_DEEPTRADING_GAS_BENCHMARK=1 julia --project -e 'using Pkg; Pkg.test()'
```

## Known Limitations

- The solver certifies the continuous convex routing problem, not direct
  on-chain execution.
- The executable benchmark value comes from a no-flash replay layer.
- Split/merge recovery is specialized to a single `SplitMergeEdge`.
- The current gas layer is a rough fixed-charge proxy.
- The 98-market benchmark is opt-in and is not a default CI gate.

## Benchmark provenance

The benchmark comparison is apples-to-apples for raw EV under the aligned
single-tick benchmark model. The gas-proxy number is Julia-local because the
Deep-Trading grouped gas model is not reproduced here.

Only the benchmark fixture data is shared with Deep-Trading. The convex solver,
its exact split/merge hyperedge, and the replay adapter in this package are
independent implementations.

The benchmark fixtures themselves are vendored under `test/fixtures/`, with
upstream commit provenance recorded in `test/fixtures/PROVENANCE.md`.
