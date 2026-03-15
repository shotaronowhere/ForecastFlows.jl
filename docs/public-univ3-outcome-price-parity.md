## Public Prediction-Market Parity

Date: 2026-03-14

### Summary

This note records the upstream public-surface fixes that make
`PredictionMarketProblem -> solve_prediction_market / compare_prediction_market_families`
match the low-level solver path on the canonical deep-trading net-EV benchmarks.

The public contract remains:

- `UniV3MarketSpec.current_price` is an outcome price
- `UniV3LiquidityBand.lower_price` is an outcome price
- `PredictionMarketProblem` is market state only
- execution costs are optional solve-time inputs, not embedded in the problem

The low-level `UniV3` edge and core solver were not redefined. The fixes live at the
public prediction-market boundary.

### What Was Wrong

There were three distinct gaps on the public path:

1. Public `UniV3` prices were documented in outcome-price space, but the low-level
   edge consumes the reciprocal convention.
2. True multi-band public `UniV3` markets needed the same band-order permutation for
   liquidity that was already being applied to lower ticks.
3. Public prediction-market solving optimized gross EV, while the downstream
   benchmark acceptance target is net EV after fixed execution costs.

These gaps showed up as certified direct no-ops on profitable direct-only cases and
economically weak mixed routes on benchmark cases that the low-level harness already
solved correctly.

### Canonical Benchmark Cases

The public prediction-market path is now guarded against these deep-trading cases:

| Case | Expected behavior |
| --- | --- |
| `two_pool_single_tick_direct_only` | direct should buy both underpriced outcomes |
| `ninety_eight_outcome_multitick_direct_only` | direct should buy broadly across profitable outcomes |
| `legacy_holdings_direct_only_case` | direct should sell the rich held leg and rotate into the cheap leg |
| `small_bundle_mixed_case` | mixed should beat direct with mint plus buys and sells |
| `mixed_route_favorable_synthetic_case` | mixed should dominate direct on the synthetic favorable route |
| `heterogeneous_ninety_eight_outcome_l1_like_case` | mixed should be globally competitive on the large heterogeneous case |

### Public `UniV3` Fixes

The public facade now converts documented outcome prices into the internal reciprocal
`UniV3` representation in one place:

- current price is inverted before validation and edge construction
- band lower prices are reversed and inverted
- liquidity is permuted to match the reversed active-band order
- if a public band ladder ends with a zero-liquidity terminal band, that terminal slot
  stays at the end while the active bands are reversed
- interior zero-liquidity gaps are preserved when the ladder is explicitly terminated
- public and low-level `UniV3` constructors now reject fee multipliers outside `(0, 1]`
- low-level `UniV3` construction now promotes mixed or integer real inputs to a stable
  floating-point edge type before validating or solving

This keeps the public JSON/API contract stable while making the constructed low-level
edge identical to the intended market.

### Gas-Aware Public Solving

The public prediction-market API now accepts an optional
`PredictionMarketFixedGasModel` at solve time and compare time:

- `market_action_costs` is aligned one-to-one with `problem.markets`
- `split_merge_action_cost` is charged when the mixed split/merge edge is active
- even the direct-only zero-market fast path still validates that alignment
- protocol `gas_model` quantities follow the same decimal-unit safe-integer rule as
  balances and reserves

When a gas model is present, the public facade runs the existing low-level
`solve_with_fixed_gas!` path instead of the gross-EV-only solve. Public solve results
still expose gross `final_ev`, and additionally expose:

- `estimated_execution_cost`
- `net_ev`

When no gas model is supplied, these new fields are `nothing`.

### Compare Path Reuse

`compare_prediction_market_families` now allocates one
`PredictionMarketWorkspace(problem)` and reuses it for both:

- `:direct_only`
- `:mixed_enabled`

This keeps the public compare entrypoint economically identical to standalone branch
solves while avoiding the old “two cold solves” behavior.

### Test Coverage

The upstream suite now covers:

- one-band public direct-buy regression
- one-band public parity against the benchmark single-tick formulas
- asymmetric multi-band public-vs-low-level `UniV3` parity
- optional gas-model JSON roundtrip
- zero-market gas-model length validation
- public worker protocol parsing for `gas_model`
- public worker rejection of unsafe integer gas quantities
- public compare parity with standalone direct and mixed solves under the same gas model
- env-gated canonical deep-trading public-facade parity
- env-gated canonical deep-trading waterfall net-EV competitiveness

### Validation Commands

Regular upstream coverage:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Focused prediction-market coverage:

```bash
julia --project=. -e 'using Pkg; Pkg.test(; test_args=["prediction_markets"])'
```

Full canonical compatibility coverage:

```bash
FORECASTFLOWS_RUN_DEEPTRADING_COMPAT=1 julia --project=. -e 'using Pkg; Pkg.test(; test_args=["prediction_markets"])'
```

The older `FORECASTFLOWS_RUN_DEEPTRADING_BENCHMARK=1` env var remains accepted
as a legacy alias during the transition.

### Remaining Follow-Ups

These fixes restore public-path correctness and net-EV competitiveness on the
canonical benchmark suite. Remaining follow-up work can focus on:

- richer per-branch diagnostics in compare responses
- clearer documentation of the executable route contract for exported actions
- additional latency work on the public compare/worker boundary
