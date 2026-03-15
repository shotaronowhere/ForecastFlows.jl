# Prediction-Market Router on ConvexFlows

This note documents the prediction-market execution layer implemented in the root `ConvexFlows` package.

## Scope

The router is an execution solver, not an upstream portfolio optimizer.

- Upstream policy decides a target basket, liquidation basket, exact-input swap, exact-output swap, or no-trade band.
- The convex-flow layer computes the best execution route across AMMs plus the fee-free mint/merge hyperedge.

This follows the separation already implicit in the thesis: portfolio choice and route execution are distinct problems.

## Market Model

We work on `N + 1` asset nodes:

- node `1`: collateral
- nodes `2:(N+1)`: mutually exclusive outcome tokens

Implemented edge types:

- `ProductTwoCoin`
- `UniV3`
- `SplitMergeEdge`

The split/merge edge is fee-free and parameterized by a scalar `w`:

- mint: `x(w) = (-w, w, ..., w)` for `w > 0`
- merge: `x(w) = (-w, w, ..., w)` for `w < 0`

with `|w| <= B`.

Its exact support function is

`f_sm(eta) = max_{|w| <= B} w * (sum(eta[2:end]) - eta[1])`

so the oracle is bang-bang:

- mint at `w = +B` if `sum(eta[2:end]) > eta[1]`
- merge at `w = -B` if `sum(eta[2:end]) < eta[1]`
- no trade on the zero-gap face

This is the exact polyhedral zero-edge-utility model from the thesis. There is no smoothing in the production formulation.

## Solver Architecture

`solve!` now supports

- `method=:auto`
- `method=:bfgs_exact`
- `method=:lbfgsb`

`method=:auto` selects `:bfgs_exact` whenever the instance contains a nonsmooth edge, currently `SplitMergeEdge`, and the objective has only lower bounds and fixed coordinates. Otherwise it uses `:lbfgsb`.

### Exact BFGS path

The nonsmooth prediction-market path optimizes shifted variables `mu`, not raw dual variables `nu`.

- let `lb = lower_limit(objective)`
- fixed coordinates are those with `upper_limit == lower_limit`
- free coordinates use `mu = nu - lb > 0`

The implemented exact-BFGS path:

- runs on the root arbitrary-hyperedge `Solver`
- reuses the same edge oracles and gradient assembly as the `LBFGSB` path
- enforces `mu > 0` in the line search
- skips curvature updates when `s'y <= 0`
- resets the inverse-Hessian approximation after repeated stalled steps

The legacy limited-memory BFGS history-index bug was also fixed while updating this path.

### Smooth fallback

When `method=:bfgs_exact` is requested on a smooth edge set and the exact-BFGS retries do not certify, `solve!` now permits a certified `LBFGSB` fallback instead of failing on a problem that is better handled by box-constrained quasi-Newton updates.

This fallback is not used for nonsmooth prediction-market instances.

## Certification and Fail-Closed Behavior

The router now treats primal recovery as a candidate reconstruction, not as proof.

Implemented helpers:

- `dual_objective(s)`
- `primal_objective(s)`
- `certify_solution(s; ...) -> SolveCertificate`

Every certified solve checks:

- primal objective finiteness
- dual objective finiteness
- objective-specific fixed-coordinate residuals
- dual bound residuals
- split/merge structural bound residuals
- primal-dual gap

By default `solve!` fails closed:

- retry 1: exact BFGS from the standard positive seed
- retry 2: exact BFGS from a uniform positive seed
- retry 3: `LBFGSB` warm start, then exact-BFGS polish for nonsmooth problems

If certification still fails, the route is rejected.

## Primal Recovery

The raw dual oracle is not enough to recover an execution-ready split/merge size on the zero-gap face. The implemented recovery step:

1. computes the objective-implied target net flow
2. accumulates all non-split recovered edge flows
3. reconstructs each split/merge edge

Recovery rule for `SplitMergeEdge`:

- active dual gap: keep the saturated mint/merge direction
- zero-gap face: project the residual onto the split direction `(-1, 1, ..., 1)` and clip to `[-B, B]`

This is the implemented v1 recovery rule. It is exact on the active face and works well for the current execution objectives and tests. A more general face-recovery scheme for arbitrary zero-utility edges remains a phase-2 topic.

## Execution Objectives

Implemented execution-layer objectives:

- `LinearNonnegative`
- `EndowmentLinear`
- `BasketLiquidation`
- `BasketAcquisition`
- `Swap`
- `SwapExactOutput`

For exact-output acquisition, the input-asset shadow price is fixed to `1`, which removes the numeraire scaling degeneracy once the split/merge edge is present.

`EndowmentLinear` is the benchmark objective for portfolio-EV comparisons. It maximizes

`cash_trade + sum(prediction_i * outcome_trade_i)`

subject to the endowment domain

`y >= -h0`

so the final portfolio EV is

`EV0 + primal_objective(s)`

with

`EV0 = cash0 + sum(prediction_i * holding0_i)`.

Because the conjugate is nondifferentiable on the lower-bound face `nu = c`, the implementation uses the one-sided derivative `h0` on that face for the benchmark endowment solves.

## Fixed Gas

AMM fees remain inside each AMM edge oracle through `gamma`.

Fixed gas (per-edge activation costs) uses a two-phase warm-started method.
The theory, failure analysis of the prior in-loop thresholding approach, and
full plan are documented in `foresight-docs/gas_aware_solver.md`.

The short version: the fixed-fee problem is NP-hard (Diamandis, Chapter 7).
In-loop thresholding creates nonsmoothness that L-BFGS-B cannot reliably
handle. The correct approach is to solve a smooth gas-free problem first,
determine the active edge set by comparing edge values to gas costs, then
re-solve the reduced smooth problem with warm-started duals.

For the imported 98-market benchmark, the current gas layer uses benchmark-local
fixed action charges:

- `0.00018` per active AMM edge
- `0.00021` for the split/merge edge

This is useful as a coarse L2 proxy for fixed edge activation, but it is not
the same gas model as the Deep-Trading benchmark, which uses grouped execution
plans plus OP L2 and L1 calldata pricing.

## Imported Deep-Trading Benchmark

The repository now includes a real 98-market benchmark harness built from

`Deep-Trading/test/fixtures/rebalancer_ab_cases.json`

case

`heterogeneous_ninety_eight_outcome_l1_like_case`

The fixture is mapped to:

- one collateral node
- ninety-eight outcome nodes
- ninety-eight single-tick benchmark AMM edges
- one fee-free `SplitMergeEdge`

The benchmark objective is endowment-aware portfolio EV:

- values `c = [1; predictions]`
- initial endowment `h0 = [cash_budget; initial_holdings]`
- objective `EndowmentLinear(c, h0)`

The benchmark keeps the single-tick approximation from the Deep-Trading fixture, but it now uses a canonical single-tick case adapter:

- the actual fixture tick range for every pool
- exact tick-to-price conversion for the single active range
- fixture liquidity in the same token units as prices, holdings, and cash
- one canonical market description shared by both the convex solve and the replay comparison
- a benchmark-local AMM edge calibrated directly from `(current_price, buy_limit_price, sell_limit_price, liquidity_raw, gamma)`

The benchmark no longer treats the certified continuous Julia solution value as the comparison answer for the Deep-Trading snapshot. It now reports two values:

- `raw_convex_upper_ev`: the certified continuous optimum under the convex-flow model
- `replayed_executable_ev`: the no-flash, cash-feasible value obtained by replaying the recovered route through the same single-tick formulas used by the benchmark adapter

`raw_convex_upper_ev` is an optimistic upper bound. `replayed_executable_ev` is the realistic comparison target for the imported Deep-Trading raw-EV references.

If a benchmark flavor does not certify its raw convex solve, the harness still reports the replayed executable EV and treats the raw continuous value as diagnostic only.

The default test suite verifies:

- fixture translation
- single-tick parity between the benchmark adapter, the benchmark AMM edge, and the replay formulas
- benchmark-local replay invariants
- the endowment-aware objective wiring

An opt-in benchmark, enabled with `CONVEXFLOWS_RUN_DEEPTRADING_BENCHMARK=1`, compares:

- a certified direct-only Julia solve using only the AMM edges
- a certified mixed Julia solve using the same AMM edges plus the split edge
- an optional fixed-gas flavor when `CONVEXFLOWS_RUN_DEEPTRADING_GAS_BENCHMARK=1`

For each flavor, it reports:

- raw convex upper EV
- replayed executable EV
- the upper-minus-replay gap
- replay fill fraction

This benchmark is not yet used as a default hard regression gate.

The benchmark also reports, but does not assert equality against, the committed Deep-Trading raw-EV references:

- `offchain_direct_ev`
- `offchain_mixed_ev`
- `offchain_full_rebalance_only_ev`

Deep-Trading references are compared only against replayed executable EV, not against the raw convex upper bound.

Gas-adjusted EV remains a Julia-local fixed-fee benchmark via the same
Chapter 7 thresholding used by `solve_with_fixed_gas!`; the committed
Deep-Trading fixture fields used here are raw EV, not net EV. The fixture also
contains `expected_onchain_exact_ev`, but that value is computed under the
Deep-Trading on-chain artifact and gas model, not the Julia fixed-charge proxy.

A large gap between the raw convex upper bound and the replayed executable EV should be interpreted as missing execution-feasibility constraints in the relaxed convex program, not as evidence that the dual solve is numerically wrong.

### Validated 98-Market Results

Under the current shipped benchmark:

- baseline EV: `150.22005815295148`
- direct raw / replayed EV: `150.25828864961397` / `150.25828864961383`
- mixed raw / replayed EV: `150.38032237147735` / `150.3803223714772`

These are very close to the committed Deep-Trading raw references:

- Deep-Trading direct raw EV: `150.25810549022944`
- Deep-Trading mixed raw EV: `150.38024558964466`

The mixed convex-flow route therefore improves on the same benchmark baseline by about `0.1602642185`, and exceeds the committed Deep-Trading mixed raw EV by about `7.68e-5` under the shared single-tick benchmark model.

With the current Julia fixed-charge gas proxy enabled:

- gas-pruned raw EV: `150.38031211734125`
- gas-pruned net EV: `150.36336211734135`
- gas-pruned active action count: `94`

This gas-adjusted number is a reasonable rough benchmark under the local test model, but it should not be interpreted as an apples-to-apples comparison to Deep-Trading net EV until the gas models are aligned.

## Verification

The current test suite covers:

- split/merge mint, merge, no-trade, and interior recovery
- arbitrary hyperedge indexing in the low-level solver
- `ProductTwoCoin` and `UniV3` oracle behavior and validation
- smooth parity between `:bfgs_exact` and `:lbfgsb`
- synthetic buy and synthetic sell routing
- exact-output routing
- structural overround and underround arbitrage
- route-level fixed-gas pruning
- a large smoke test with one split/merge edge and many AMM edges
- canonical ninety-eight-outcome fixture translation and single-tick parity
- opt-in ninety-eight-outcome raw-versus-replay benchmark reporting

## Deliberate Limits

Not implemented in v1:

- split/merge protocol fees
- directional edge splitting for direction-dependent gas costs
- robust routing under stale/uncertain reserves
- block-level gas bundle packing
- on-chain reserve fetching and transaction construction
- general primal recovery for arbitrary zero-utility edges beyond the current split/merge specialization
