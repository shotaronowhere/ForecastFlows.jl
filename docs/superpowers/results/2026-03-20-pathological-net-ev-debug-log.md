# Pathological Net-EV Debug Log

Date: 2026-03-20

## Scope

Continue debugging the remaining "ForecastFlows underperforms on pathological net-EV cases" narrative without assuming the native Rust waterfall is the mathematical ground truth. The goal is to keep the investigation rooted in the convex-flows decomposition and to distinguish:

- dual/solver failure
- primal recovery/certification failure
- replay or action-grammar mismatch
- benchmark-fixture/model mismatch

## Working Assumptions

- The convex mixed solve should be judged first on certified raw EV, because that is the object the dual decomposition actually optimizes.
- Net-EV underperformance can still appear after replay or gas pricing even when the continuous mixed solve is mathematically sound.
- The upstream native waterfall is a useful executable benchmark, but it is not the optimization target for ForecastFlows.

## Reproductions Run

### 1. Local 18-outcome convex bound sweep

Command:

```bash
julia --project=. test/convex_bound_diagnostic.jl
```

Observed:

- direct-only EV: about `20.53`
- mixed EV plateaus around `127.58` to `130.44` in the local diagnostic, depending on `B`
- the detailed `B=169` solve lands on a large merge flow and concentrates the final holdings in outcomes 1 and 2

Interpretation:

- under the current local single-band replay model, the convex solver is not obviously "missing" the complete-set arb mechanism
- the mixed solution already captures the large structural merge trade

### 2. Local "native waterfall" replay script

Command:

```bash
julia --project=. test/native_waterfall_sim.jl
```

Observed:

- baseline "arb + greedy deploy" EV: about `127.63`
- the script's own staged "Rust strategy replication" also lands around `127.62`
- it does **not** reproduce the comment-level `132.14` claim inside the file

Interpretation:

- this local script is currently an exploratory replay under the simplified price model, not a faithful reproduction of the upstream executable benchmark
- the apparent `132+` "native advantage" is therefore not reproduced locally from the same assumptions

### 3. Prior downstream benchmark notes

Existing result note:

- [`docs/superpowers/results/2026-03-17-mixed-solver-recovery-fix-results.md`](/Users/shotaro/proj/ForecastFlows.jl/docs/superpowers/results/2026-03-17-mixed-solver-recovery-fix-results.md)

Important prior observation:

- after the `EndowmentLinear` recovery-target fix, the Rust worker-backed pathological tests were reported passing

Interpretation:

- the committed worker baseline likely no longer suffers from the earlier "mixed path falls back to direct-only" failure mode
- the remaining confusion is more likely in local diagnostics, route compilation, or replay assumptions

### 4. Public API-level pathological diagnostic

Command:

```bash
julia --project=. test/pathological_api_diagnostic.jl
```

Observed:

- direct:
  - `status = certified`
  - `final_ev = 20.532482`
  - one active trade, entirely outcome 1
- mixed:
  - `status = certified`
  - `final_ev = 127.578338`
  - `split_merge.merge = 169.0`
  - recovered holdings concentrate in outcomes 1 and 2 after the full mixed route is netted out

Interpretation:

- this script is a **simplified one-band approximation**, not the exact
  deep_trading pathological benchmark shape
- it remains useful as a loose sanity check, but it should not be treated as
  benchmark-equivalent after the exact tick-aligned reconstruction below

### 5. Exact tick-aligned replay diagnostic

Command:

```bash
julia --project=. test/pathological_replay_diagnostic.jl
```

Observed:

- exact benchmark-aligned single-tick bounds derived from the deep_trading case:
  - tick range `[1, 92108]`
  - `buy_limit ≈ 0.999900009999`
  - `sell_limit ≈ 0.000100000088`
- direct:
  - `status = certified`
  - `final_ev = 20.532482`
- mixed continuation result:
  - `status = certified`
  - `final_ev = 64.947727`
  - `split_merge.merge = 43.875`
- replay of the certified mixed route:
  - `replay_raw_ev = 64.947453`
  - `replay_net_ev = 64.942061`
  - raw replay gap versus certified result only about `-2.75e-4`
  - grouped execution is:
    - `3` cash-recycling `buy_merge` rounds
    - `1` trailing `direct_buy`
- fixed-bound sweep on the exact tick-aligned case:
  - `B=13`: uncertified, `final_ev = 34.732178`, `merge = 13`
  - `B=26`: certified, but trivial no-trade `final_ev = 6.5`
  - `B=52`: uncertified, `final_ev = 72.044366`, `merge = 52`
  - `B=104`: uncertified, `final_ev = 108.307704`, `merge = 104`
  - `B=208` and `B=416`: certified, but again trivial no-trade `final_ev = 6.5`
  - at the uncertified `B=13`, `B=52`, and `B=104` points:
    - `bound_residual = 0`
    - `target_residual` stays around `1e-4`
    - the recovered portfolio has a small negative minimum holding (`-2.07e-4`, `-1.73e-4`, `-4.7e-5`)

Interpretation:

- the exact benchmark-aligned local case still shows the old qualitative
  pathology: high-value mixed candidates exist at larger split bounds, but they
  fail certification
- the returned certified mixed result `64.947727` is not the high-EV optimum;
  it is the highest certifiable point found by the current continuation/bisection
  logic between the certified `B=26` face and the uncertified `B=52` face
- the failure signature is specifically a recovery/target-matching failure, not
  a split-bound feasibility failure: `bound_residual` is zero while the
  recovered primal still has small negative holdings and nonzero target residual
- replay/action ordering is **not** the main source of the remaining gap on the
  exact case; the replay tracks the certified mixed route very closely
- the earlier `127.578338` local mixed result came from a looser model and
  should not be used as evidence that the exact pathological benchmark is fixed

### 6. Documentation chronology mismatch

Current workspace evidence is split across dates:

- archived deep_trading reports dated `2026-03-16` and `2026-03-17` describe
  the older mixed-certification failure, including the large net-EV loss versus
  native on `forecastflows_large_nonprefix_active_set_case`
- the current file
  [`/Users/shotaro/proj/deep_trading/docs/forecastflows_pathological_benchmarks.md`](/Users/shotaro/proj/deep_trading/docs/forecastflows_pathological_benchmarks.md)
  now states the target assertion in the opposite direction:
  `ForecastFlows net EV beats native by at least 0.001 sUSD`

Interpretation:

- benchmark expectations and the locally reproduced Julia behavior are not yet
  aligned
- before changing theory or solver architecture again, the worker-backed row
  should be rerun and recorded from the current checkout so the team knows
  whether the docs or the local reproduction are the stale artifact

### 7. Recovery diagnostic and internal continuation trace

Command:

```bash
julia --project=. test/pathological_recovery_diagnostic.jl
```

Observed:

- internal fixed-bound continuation using the direct solve as the dual seed:
  - `B=6.5`: internally uncertified, `final_ev = 27.738572`,
    `target_residual = 8.98e-4`
  - `B=13`: internally certified, `final_ev = 34.731958`,
    `target_residual = 1.00e-4`
  - `B=26`: internally certified, `final_ev = 48.067950`,
    `target_residual = 1.61e-4`
  - `B=52`: internally uncertified, `final_ev = 72.044445`,
    `target_residual = 5.42e-4`
- the mixed continuation then bisects exactly as the code says:
  - `mid=39`: certified
  - `mid=45.5`: uncertified
  - `mid=42.25`: certified
  - `mid=43.875`: certified
- the returned public mixed result `64.947727` is therefore the last certifiable
  bisection point, not a mysterious separate optimum
- the failing `B=52` point has:
  - `bound_residual = 0`
  - `duality_gap ≈ -8.09e-5`
  - `target_residual ≈ 5.42e-4`, just above the current `5e-4` tolerance
  - small signed inventory errors concentrated on fixed coordinates
  - one dominant free coordinate (outcome 1), plus the split edge pinned at
    `w = -52`

Interpretation:

- the exact transition responsible for the returned `43.875` solve is now
  identified precisely: the first internal target-residual failure occurs at
  `B=52`
- this reinforces the thesis-guided diagnosis that the remaining issue is a
  primal recovery problem on the active optimal face, not a failure of the
  convex dual itself
- the next mathematically justified improvement is to enlarge the recovery step
  beyond a single post-hoc split-edge correction, likely by solving a small
  face-projection problem over the relevant active edges

### 8. Certified-seed continuation fix and workspace-state alignment

Relevant files:

- [`src/prediction_market_api.jl`](/Users/shotaro/proj/ForecastFlows.jl/src/prediction_market_api.jl)
- [`test/pathological_recovery_diagnostic.jl`](/Users/shotaro/proj/ForecastFlows.jl/test/pathological_recovery_diagnostic.jl)
- [`test/prediction_markets.jl`](/Users/shotaro/proj/ForecastFlows.jl/test/prediction_markets.jl)

Code change:

- the mixed continuation now promotes `ν_seed` only after a **certified** mixed
  solve
- when bisection returns the best certified midpoint, the reusable workspace now
  restores `workspace.mixed_solver` to that certified state instead of leaving
  it on the final failed midpoint

Observed after the fix:

- on the exact tick-aligned pathological case, the public mixed solve now returns
  - `status = certified`
  - `final_ev = 127.578396`
  - `split_merge.merge = 169.0`
  - `target_residual = 1.3095e-4`
- replay of that public result remains very tight:
  - `replay_raw_ev = 127.578336`
  - raw replay gap about `-5.99e-5`
- the updated current-source continuation trace now shows:
  - `B=6.5`: uncertified, keep the direct seed and double
  - `B=13`: certified
  - `B=26`: certified
  - `B=52`: certified
  - `B=104`: certified
  - `B=208`: uncertified, then bisect to `156` certified, `182` uncertified,
    `169` certified, `175.5` uncertified
- the older `43.875` return is now reproduced only by the explicitly labeled
  **legacy** trace that overwrites the seed after the initial uncertified
  `B=6.5` solve

Interpretation:

- the main exact-case underperformance in the public ForecastFlows solve was a
  continuation-seed bug, not a replay bug and not evidence that the convex dual
  itself was missing the complete-set merge route
- fixed-bound `max_doublings=0` solves are still branch-sensitive and can land
  on trivial or uncertified faces at particular `B`; that is now a secondary
  fixed-face/recovery question rather than the main public API failure
- restoring the workspace solver state removes a real debugging hazard: after a
  successful mixed solve, the reusable workspace now agrees with the returned
  certified result even if the final attempted midpoint failed

### 9. Worker-backed pathological benchmark refresh attempt

Commands attempted:

```bash
cd /Users/shotaro/proj/deep_trading
FORECASTFLOWS_PATHOLOGICAL_CASE=forecastflows_large_nonprefix_active_set_case \
  cargo test print_forecastflows_pathological_rows_jsonl \
  -- --ignored --nocapture --test-threads=1

FORECASTFLOWS_PATHOLOGICAL_CASE=forecastflows_large_nonprefix_active_set_case \
  cargo test --release print_forecastflows_pathological_rows_jsonl \
  -- --ignored --nocapture --test-threads=1
```

Observed:

- debug mode entered the ignored printer test quickly but emitted no JSON row
  after more than `5` minutes
- release mode reused an existing `target/release` build and started
  immediately, but still emitted no JSON row after about `2m54s`
- both runs remained CPU-active at about `99%`, so this looked like a heavy
  benchmark path rather than an idle deadlock
- to avoid leaving stray long-running processes behind, both benchmark runs were
  terminated manually after the observation window

Interpretation:

- the cross-repo worker-backed refresh is still outstanding
- the most sensible next rerun is the **release** printer above, but with a
  longer patience window or from an interactive terminal session where the run
  can be left alone until completion

## Theory Notes

Primary references:

- [`foresight-docs/phd_thesis.md`](/Users/shotaro/proj/ForecastFlows.jl/foresight-docs/phd_thesis.md)
- [`foresight-docs/2404.00765v2.md`](/Users/shotaro/proj/ForecastFlows.jl/foresight-docs/2404.00765v2.md)

Most relevant takeaways:

- The dual decomposition minimizes
  `g(ν) = Ū(ν) + Σ_i arb_i(A_i^T ν)`.
- Each edge contributes only through its support function / arbitrage oracle.
- With zero edge utilities and non-strictly convex faces, primal recovery is a separate reconstruction problem.
- The split/merge hyperedge is exactly the kind of edge where recovery details matter because the optimal face can be set-valued.

Numerical optimization literature checked:

- Asl and Overton, "Behavior of Limited Memory BFGS when Applied to Nonsmooth Functions and their Nesterov Smoothings" (arXiv:2006.11336)
- Nesterov, "Smooth minimization of non-smooth functions"

Operational takeaway:

- For large-scale nonsmooth convex problems, L-BFGS tends to behave better on a smooth approximation than on the raw kinked objective.
- That supports the existing Moreau-Yosida smoothing choice for the split/merge support function.
- It does **not** explain the remaining local `127.6` vs `132+` discrepancy by itself.

## Concrete Bug Locked Down

### Split/merge contradictory-bound fallback

Relevant file:

- [`src/prediction_markets.jl`](/Users/shotaro/proj/ForecastFlows.jl/src/prediction_markets.jl)

Issue:

- In `recover_splitmerge_flow!`, when the feasible interval implied by lower bounds became contradictory (`wlo > whi`), the fallback previously clamped against `[-B, B]`.
- That could pick a `w` above `whi`, violating the collateral-side lower bound that had just been computed.

Working-tree fix direction already present when this pass started:

- keep the hard collateral cap by clamping to `whi` in the contradictory case

Regression coverage added in this pass:

- [`test/prediction_markets.jl`](/Users/shotaro/proj/ForecastFlows.jl/test/prediction_markets.jl)

Why this matters:

- it preserves the physically hard collateral bound even when the outcome lower bounds are jointly inconsistent
- this is exactly the kind of recovery-path bug that can turn a good dual point into an infeasible primal reconstruction

## Current Conclusion

The best current explanation is:

1. On the **simplified** one-band case, ForecastFlows mixed routing looks healthy.
2. On the **exact tick-aligned** pathological case, the public mixed
   continuation is now healthy as well: it certifies at about `127.578396` raw
   EV with a `169` merge, and replay tracks that route closely.
3. The earlier `64.947727` / `43.875` frontier was caused by seed contamination
   from an initial uncertified mixed iterate, not by replay loss and not by a
   fundamental failure of the convex-flow decomposition.
4. Fixed-bound solves at prescribed `B` values still expose interesting
   branch/recovery sensitivity, but that is now a more local numerical question
   than the dominant public API blocker.
5. Replay/action grammar still matters for net EV and execution design, but it
   is no longer the first-order explanation for the exact pathological gap seen
   in the Julia public solve.
6. The deep_trading docs and worker-backed benchmark rows still need a fresh
   synchronized rerun from the current checkout.

## Next To-Dos

- Finish a fresh worker-backed reproduction of the Rust pathological rows from
  the current workspace state and record the exact JSON row outputs.
- Use the updated recovery diagnostic to decide whether any remaining work is
  needed on **fixed-bound** face selection or recovery around the `B=208`
  transition, where the current-source continuation first fails and then
  bisects back to `B=169`.
- If we pursue another solver change, target the fixed-face recovery problem
  directly rather than changing the dual oracle or trying to imitate the native
  waterfall action sequence.
- Rerun the worker-backed benchmark row now that the public Julia continuation
  and workspace state are consistent, so the benchmark/docs mismatch can be
  resolved on current code instead of archived March 16-17 results.
- Only after the worker-backed rows are refreshed should we spend more time on
  residual replay/action-grammar differences between Julia and the Rust
  implementation.

## Verification

Code/document alignment for this round:

- the in-flight working-tree source changes under discussion are:
  - the contradictory-bounds recovery clamp in
  [`src/prediction_markets.jl`](/Users/shotaro/proj/ForecastFlows.jl/src/prediction_markets.jl)
  - the mixed continuation seed-promotion and workspace-state fix in
    [`src/prediction_market_api.jl`](/Users/shotaro/proj/ForecastFlows.jl/src/prediction_market_api.jl)
- the new regression coverage added in this pass is in
  [`test/prediction_markets.jl`](/Users/shotaro/proj/ForecastFlows.jl/test/prediction_markets.jl)
- the benchmark-aligned replay/certification diagnostic added in this pass is
  [`test/pathological_replay_diagnostic.jl`](/Users/shotaro/proj/ForecastFlows.jl/test/pathological_replay_diagnostic.jl)
- the recovery-focused internal continuation diagnostic added in this pass is
  [`test/pathological_recovery_diagnostic.jl`](/Users/shotaro/proj/ForecastFlows.jl/test/pathological_recovery_diagnostic.jl)
- the older simplified local sanity-check script is now explicitly labeled as a
  one-band approximation in
  [`test/pathological_api_diagnostic.jl`](/Users/shotaro/proj/ForecastFlows.jl/test/pathological_api_diagnostic.jl)
- this log documents both the reason for the change and the broader debugging state

Commands run after the continuation fix:

```bash
julia --project=. test/pathological_replay_diagnostic.jl
julia --project=. test/pathological_recovery_diagnostic.jl
julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'
```

Observed verification status:

- `Pkg.test()` passed
- the exact pathological public regression now passes inside
  [`test/prediction_markets.jl`](/Users/shotaro/proj/ForecastFlows.jl/test/prediction_markets.jl)
- the updated recovery diagnostic now cleanly separates:
  - the current-source `169` continuation path
  - the legacy pre-fix `43.875` continuation path
- the worker-backed pathological row printer was started in both debug and
  release mode, but neither run completed within the local observation window
