# ForecastFlows.jl

`ForecastFlows.jl` is a Julia package for convex-flow optimization on graphs and
hypergraphs, with a prediction-market routing extension built on the dual
decomposition framework from Theo Diamandis's *Convex Network Flows*.

The public routing surface is centered on the root solver API:

- `Solver`
- `solve!`
- `SplitMergeEdge`
- `EndowmentLinear`
- `certify_solution`
- `solve_with_fixed_gas!`

The prediction-market router models:

- one collateral asset
- one AMM edge per collateral/outcome market
- one fee-free mint/merge hyperedge

This lets the solver discover direct and synthetic routes from shadow-price
equilibration instead of explicit path enumeration.

## Validated 98-market benchmark

The package includes an opt-in benchmark based on the realistic 98-market
Deep-Trading fixture, evaluated under an aligned single-tick replay model.

Current validated raw results:

- baseline EV: `150.22005815295148`
- direct raw / replayed EV: `150.25828864961397` / `150.25828864961383`
- mixed raw / replayed EV: `150.38032237147735` / `150.3803223714772`

The current rough fixed-charge gas proxy gives:

- gas-proxy net EV: `150.36336211734135`

This gas-adjusted value is a Julia-local approximation, not an apples-to-apples
comparison to the Deep-Trading grouped L2/L1 gas model.

## Run the benchmark

Run the full test suite:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Run the opt-in raw 98-market benchmark:

```bash
FORECASTFLOWS_RUN_DEEPTRADING_BENCHMARK=1 julia --project -e 'using Pkg; Pkg.test()'
```

Run the opt-in raw + gas-proxy 98-market benchmark:

```bash
FORECASTFLOWS_RUN_DEEPTRADING_BENCHMARK=1 FORECASTFLOWS_RUN_DEEPTRADING_GAS_BENCHMARK=1 julia --project -e 'using Pkg; Pkg.test()'
```

## Scope and limitations

- The optimizer certifies the continuous convex routing problem.
- Executable benchmark results come from a no-flash replay layer.
- Split/merge recovery is specialized to a single `SplitMergeEdge`.
- The current gas model is a rough fixed-charge proxy.
- The 98-market benchmark is opt-in, not a default CI gate.

## Attribution

This package is a public-facing fork/adaptation of the original
`ConvexFlows.jl` research codebase and keeps the convex-flow formulation and
core solver ideas while extending the root solver to prediction-market routing.

See `docs/` for public package documentation and `ROADMAP.md` for remaining
work.
