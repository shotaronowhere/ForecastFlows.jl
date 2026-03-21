# Pathological 18-Outcome Net EV Debug Log

**Date**: 2026-03-20
**Status**: FIXED — Rust solver now produces on-chain consistent EV (127.63, matching Julia)

## Problem Statement

The Julia convex solver achieves EV≈127.63 on an 18-outcome pathological test case, while the Rust native rebalancer reports EV≈132.14 — a ~4.5 sUSD gap. The investigation aimed to understand why and close the gap.

## Root Cause: Stored-Cost Accounting Bug in Rust Step Pruner

**The Rust's 132.14 EV is NOT achievable on-chain.** It is inflated by a stored-cost accounting inconsistency in the `baseline_step_prune_candidate_for_program_net_ev` function.

### Mechanism

1. The Rust solver runs a **Polish re-optimization loop** (`run_polish_reoptimization`) that iteratively: arb → sell overpriced → waterfall deploy → recycle. Each pass generates actions with costs computed at the current intermediate state.

2. The raw actions from all Polish passes are accumulated (arb rounds interleaved with waterfall buys and recycles).

3. `compact_raw_no_arb_plan_for_program_net_ev` then runs `baseline_step_prune`, which groups actions by "profitability step" and tries removing the least profitable groups. This improves EV by freeing cash.

4. **The bug**: When evaluating pruned plans, `apply_actions_to_solver_state` computes cash using `replay_actions_to_portfolio_state`, which sums **stored** buy costs and sell proceeds from the original action objects — NOT recomputed costs from AMM formulas. After removing intermediate waterfall/recycle actions that changed pool prices between arb rounds, the remaining arb rounds' stored costs no longer match what the AMM would actually charge at the now-different intermediate prices.

### Evidence

**File**: `test/verify_stored_cost_ev.jl`

Parsing all 1142 actions from the Rust output and computing EV two ways:

| Method | Cash | Holdings EV | Total EV |
|--------|------|-------------|----------|
| Stored-cost (Rust method) | 9.231 | 122.906 | **132.137** |
| Recomputed (AMM replay) | -4.373 | 122.906 | **118.533** |

- **Gap: 13.60 sUSD** — entirely from buy cost discrepancies
- The recomputed replay shows **negative cash** (-4.37), meaning the actions would overdraw the budget on-chain
- Cost differences start at action ~725 and grow to 0.245 per buy at action 1086
- After action ~920, psum exceeds 1.0 in the recomputed replay (arb rounds actively unprofitable)

### True Achievable EV

**File**: `test/true_achievable_ev.jl`

Testing every strategy with faithful AMM simulation:

| Strategy | EV |
|----------|-----|
| Arb → Deploy (Julia baseline) | **127.63** |
| Arb → Deploy → Polish loop | 127.63 (no improvement) |
| Arb → BUY → MINT+SELL → Polish (best) | 127.63 |
| Iterative MINT+SELL recycling | 127.60 |
| **Rust stored-cost EV** | **132.14 (not achievable)** |
| Rust recomputed EV | 118.53 |

The Julia convex solver's 127.63 IS the correct achievable optimum (or very close to it) for this test case.

## Key Technical Findings

### 1. Price Path Independence (Verified)
For constant-product AMMs, the final price after buying total M tokens is `p₀/(1-M·λ₀)²` regardless of how many rounds the purchase is split into. This was verified mathematically and empirically.

### 2. Polish Loop Generates Zero Incremental Value
When faithfully simulated (recomputing costs through AMM at each step), the Polish loop provides zero additional EV over simple arb → deploy. This is because after arb brings psum to ~1.0, deploying cash into outcomes increases prices, and subsequent arb finds nothing profitable.

### 3. MINT+SELL Route Offers Marginal Benefit
The MINT+SELL route (mint complete sets, sell inactive outcomes, keep active ones) provides at most ~0.001 sUSD improvement over direct deployment in this test case. The prices are dominated by the high-L outcomes (0-2, L=8000+) which absorb large buys with minimal slippage.

### 4. Action Log Structure
The Rust action log (1142 actions):
- Phase 0: 9 buy-all-merge arb rounds (172.85 total merged, 35.20 profit)
- Phase 1: BUY outcome_0 (1100.08 tokens, cost 31.32)
- Phase 2: 2 MINT+SELL rounds (mint 10.38 + 9.95)
- Phase 3: 49 buy-all-merge rounds (78.05 total merged) — **these are from pruned Polish passes**
- Phase 4: 3 final buys (outcome_0 and outcome_1)

## Files Created During Investigation

- `test/replay_rust_actions.jl` — Replay exact Rust actions, discovered psum divergence
- `test/verify_stored_cost_ev.jl` — **Key file**: proves stored-cost vs recomputed EV gap
- `test/true_achievable_ev.jl` — Comprehensive strategy comparison
- `test/arb_diagnostic.jl` — Earlier diagnostic for Phase 3 arb discrepancy
- `test/ev_peak_diagnostic.jl` — EV peak analysis during deployment
- `test/mint_sell_route_test.jl` — MINT+SELL route analysis

## Implications

1. **Julia solver is NOT underperforming** — it's within ~0.01 sUSD of the true optimum
2. **Rust benchmark needs fixing** — the step pruner should recompute costs through AMM when evaluating pruned action sequences, not use stored costs
3. **The convex flow framework works** — the dual decomposition approach correctly finds the optimal allocation
4. **No need for "action grammar" from waterfall** — the simple arb → deploy strategy is already optimal for this test case

## Rust Fix (Implemented 2026-03-21)

Added `apply_actions_to_solver_state_consistent` in `rebalancer.rs` — replays actions through PoolSim for both prices AND cash (instead of using stored costs for cash). Wired into all evaluation paths where actions may have been pruned or accumulated across Polish passes:

1. `baseline_step_prune_candidate_for_program_net_ev` (2 call sites — initial + pruned evaluation)
2. `route_group_prune_candidate_for_program_net_ev` (2 call sites — initial + pruned evaluation)
3. `compact_raw_no_arb_plan_for_program_net_ev` (1 call site — entry point `rich_terminal_state` used as target for `compile_target_delta` and `rich_raw_ev` threshold for `compile_staged_constant_l_mixed`)
4. `evaluate_forecastflows_action_set` (1 call site — used by ForecastFlows step/route pruners)

Call sites left on stored-cost `apply_actions_to_solver_state` (safe — freshly compiled sequential actions, no pruning):
- `compile_coupled_mixed_actions_for_entries_and_shift` (lines 3262, 3510)
- `compile_target_delta` (lines 4521, 4848)
- `run_positive_arb_plan_from_state` (line 5556 — single arb pass)
- Test helpers (lines 9297, 9313)

### Results After Fix

| Metric | Before fix | After fix |
|--------|-----------|-----------|
| Reported EV | 132.14 (inflated) | **127.63** (correct) |
| Actions | 1142 | **190** |
| Cash remaining | 9.23 | ~0.00 |
| On-chain executable | No (negative cash on replay) | **Yes** |

The Rust solver now matches the Julia convex solver's EV (127.63) on the pathological test case. The pruner correctly removes the worthless Polish arb rounds that only appeared profitable due to stored-cost accounting.

The function returns `Option<(SolverStateSnapshot, Vec<Action>)>` — both the terminal state AND updated actions with PoolSim-recomputed costs/proceeds. This ensures downstream code that re-replays actions (e.g., `assert_rebalance_action_invariants`) gets results consistent with the terminal state.

### Regression Test Results

Full test suite (371 tests): **305 passed, 17 failed, 43 ignored**. All 17 failures are **pre-existing** (confirmed by running the same tests on unmodified code). The one test affected by our change (`forecastflows_polish_prunes_coupled_buy_merge_steps`) was updated to accept the correct behavior: the pruner now keeps the buy-merge group intact when it is genuinely profitable under consistent evaluation.

## Future: Foundry Fork Validation Mode

A local Foundry fork of the Uniswap V3 pools could serve as ground truth for action plan validation — actual Solidity execution instead of PoolSim f64 math. This would be ~100-1000x slower but behind a flag could validate that PoolSim accurately models on-chain execution.
