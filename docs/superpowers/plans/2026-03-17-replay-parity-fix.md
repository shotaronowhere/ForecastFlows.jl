# ForecastFlows Solver Parity Fix — Implementation Plan (v3, final)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 111.50 sUSD net-EV gap between the ForecastFlows convex solver and the native waterfall heuristic on the 18-outcome pathological test case.

**Architecture:** Two structural changes rooted in the Diamandis-Angeris-Edelman convex flow framework:
1. **Moreau-Yosida smoothing** of the split/merge support function eliminates the codimension-1 non-differentiability in the dual, enabling L-BFGS-B convergence at large B.
2. **Algorithmic symmetry** in the Rust replay makes the affordability binary search use identical FP operations to the execution path.

**Tech Stack:** Julia (ForecastFlows.jl), Rust (deep_trading)

---

## Theoretical Foundation

### The dual decomposition (thesis §4.1–4.2)

The convex flow problem decomposes via Lagrange multipliers ν (shadow prices):

$$g(\nu) = \bar{U}(\nu) + \sum_{k} f_k(A_k^T \nu)$$

where $f_k(\eta) = \sup_{x \in T_k} \eta^T x$ is the **support function** of the allowable flow set $T_k$. Each `find_arb!` call evaluates $f_k$ and its (sub)gradient.

### The split/merge support function

For the mint/merge hyperedge with bound B:

$$f_{sm}(\eta) = \max_{w \in [-B,B]} w \cdot \text{gap}, \quad \text{gap} = \sum_{i=1}^N \nu_i - \nu_0$$

This equals $B \cdot |\text{gap}|$ — the support function of a polytope. It is **not differentiable** at gap = 0. The (sub)gradient jumps by $2B$ across the kink on every coordinate of the hyperedge.

### Why B=208 fails certification

At B=104, the solver certifies (primal ≈ 101.8). At B=208, primal = −∞. The mechanism:

1. During BFGS, each time the gap crosses zero, the oracle switches between w = +208 (mint) and w = −208 (merge), creating a **gradient discontinuity of magnitude 416** on 19 coordinates.
2. Per Lewis-Overton (2013), full BFGS incorporates this as high curvature in the Hessian approximation. At B=208, the curvature is so extreme that step sizes collapse.
3. The solver terminates prematurely at a bad dual point ν* where the gap is slightly positive.
4. `find_arb!` snaps to w = +208 (mint 208 collateral), but the user has only 6.5 sUSD.
5. The net flow violates `y[0] < -h0[0]` → `U(y) = -Inf` → primal = −∞ → uncertified.

### The smoothing fix (thesis §5, "strict concavity trick")

The thesis explicitly endorses this approach:

> "A non-strictly concave U may be transformed into a strictly concave one by, for example, subtracting a very small quadratic term." — Diamandis thesis §5

Applied to the split/merge edge: add a quadratic penalty μ/2 · w² to the primal:

$$f_{sm}^\mu(\eta) = \max_{w \in [-B,B]} \left\{ w \cdot \text{gap} - \frac{\mu}{2} w^2 \right\}$$

The smoothed oracle: **w* = clamp(gap/μ, −B, B)**, which is Lipschitz-continuous with constant 1/μ. The full dual becomes C¹, and L-BFGS-B converges with superlinear rate.

### Primal recovery is unaffected (thesis §5.2)

The thesis defines primal recovery as a **reconstruction problem** over the optimal face:

$$T_{sm}^*(\eta^*) = T_{sm} \cap \partial f_{sm}(\eta^*)$$

At the converged dual (gap ≈ 0), this face is the **entire interval** {(−w, w, …, w) : w ∈ [−B, B]}. The reconstruction selects the w that minimizes the flow residual ‖y* − Σ A_k x_k‖. This is exactly what `recover_splitmerge_flow!` already implements via its residual-based least-squares.

**The smoothing affects only the BFGS trajectory, not the final primal.** After convergence, the existing recovery procedure selects the correct fractional w from the full face.

### Smoothing parameter selection

Bias bound: μB²/2 is the maximum deviation in the dual objective.

For certification gap_tol to hold: μB²/2 ≤ gap_tol/10 (leaving 90% headroom for the optimizer).

$$\mu = \frac{\text{gap\_tol}}{5 B^2}$$

With gap_tol = 5×10⁻³ (from `_solve_certificate_tolerances` with pgtol=1e-5) and B=208: μ ≈ 2.3×10⁻⁸.

Hessian condition at kink: 1/μ ≈ 4.3×10⁷. Manageable for L-BFGS-B.

### Critique of the external review

The Gemini/Tao review contained three actionable recommendations and one error:

1. **μ = gap_tol/(10·B²)** — ACCEPTED. More conservative than our original gap_tol/B².
2. **"Primal recovery must use the smoothed flow"** — REJECTED. The thesis §5.2 reconstruction problem selects w from the face T_sm*(η*), which at gap ≈ 0 is the full interval [−B, B]. The residual-based recovery already implements this correctly. The smoothed w = gap/μ is biased by the regularization and is NOT the reconstruction-optimal w. Our existing `recover_splitmerge_flow!` is the theoretically correct implementation.
3. **B_max conditioning concern** — PARTIALLY ACCEPTED. We keep the doubling loop (starts at small B → well-conditioned) and cap at analytical B_max. We do NOT set B = B_max upfront.
4. **Algorithmic symmetry in Rust replay** — ACCEPTED. Dimensionally correct fix.

---

## Chunk 1: Commit Existing Julia Fixes

### Task 1: Commit the bound-doubling certification fix

**Files:**
- Modified: `src/prediction_market_api.jl` (bound-doubling early-stop on uncertified)
- Modified: `src/prediction_markets.jl` (gap tolerance scaling by N)
- Modified: `src/solver.jl` (ν0 passthrough via structdiff)
- Modified: `test/prediction_markets.jl` (expect certified instead of uncertified)

- [ ] **Step 1: Stage and commit**

```bash
cd /Users/shotaro/proj/ForecastFlows.jl
git add src/prediction_market_api.jl src/prediction_markets.jl src/solver.jl test/prediction_markets.jl
git commit -m "fix: bound-doubling returns best certified result instead of overwriting with uncertified

The _solve_prediction_market_mixed doubling loop unconditionally overwrote
best_result with later iterations, losing certified results when higher
split_bounds failed certification. Now stops doubling on first uncertified
result and returns the best certified result from an earlier iteration.

Also:
- Scale recover_splitmerge_flow! gap tolerance by length(η) to prevent
  false snapping when individual term noise accumulates
- Pass ν0 through solve_with_fixed_gas! via Base.structdiff
- Update tests to expect certified status"
```

- [ ] **Step 2: Run tests to verify**

Run: `cd /Users/shotaro/proj/ForecastFlows.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass

---

## Chunk 2: Moreau-Yosida Smoothing of the SplitMerge Hyperedge

### Task 2: Add smoothing parameter to SplitMergeEdge

**Files:**
- Modify: `src/prediction_markets.jl:195-233`
- Add tests: `test/prediction_markets.jl`

**Mathematical specification:**

When μ > 0, `find_arb!` returns w = clamp(gap/μ, −B, B) and sets the flow vector x = (−w, w, …, w). When μ = 0, the exact bang-bang oracle is preserved. `is_nonsmooth` returns false when μ > 0, steering `_select_method` to `:lbfgsb`.

`recover_splitmerge_flow!` is **unchanged** — it always uses the exact reconstruction procedure from thesis §5.2.

- [ ] **Step 1: Write the failing test**

Add to `test/prediction_markets.jl`:

```julia
@testset "smoothed split/merge oracle" begin
    e_smooth = ForecastFlows.SplitMergeEdge([1, 2, 3], 100.0; μ=0.01)
    x = zeros(3)

    # Large gap → saturates at B (linear regime)
    ForecastFlows.find_arb!(x, e_smooth, [0.5, 0.8, 0.9])
    @test x[1] ≈ -100.0
    @test x[2] ≈ 100.0

    # Small gap → smoothed intermediate flow (quadratic regime)
    ForecastFlows.find_arb!(x, e_smooth, [1.0, 0.502, 0.502])
    @test x[1] ≈ -0.4 atol=1e-10   # w = 0.004/0.01 = 0.4

    # Zero gap → zero flow
    ForecastFlows.find_arb!(x, e_smooth, [1.0, 0.5, 0.5])
    @test all(x .≈ 0.0)

    # Nonsmooth flag
    @test !ForecastFlows.is_nonsmooth(e_smooth)
    @test ForecastFlows.is_nonsmooth(ForecastFlows.SplitMergeEdge([1, 2, 3], 100.0))
end
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `SplitMergeEdge` doesn't accept `μ` keyword yet

- [ ] **Step 3: Implement the smoothed SplitMergeEdge**

In `src/prediction_markets.jl`, replace the SplitMergeEdge definition:

```julia
struct SplitMergeEdge{T} <: Edge{T}
    Ai::Vector{Int}
    B::T
    μ::T   # Moreau-Yosida smoothing parameter; 0 = exact (nonsmooth)

    function SplitMergeEdge(Ai, B; μ=0)
        length(Ai) >= 3 || throw(ArgumentError(
            "SplitMergeEdge requires local ordering [collateral, outcomes...] with at least two outcomes"))
        T = promote_type(typeof(float(B)), typeof(float(μ)))
        mu = convert(T, μ)
        mu >= zero(T) || throw(ArgumentError("smoothing parameter μ must be nonnegative"))
        return new{T}(collect(Int, Ai), convert(T, B), mu)
    end
end

is_nonsmooth(e::SplitMergeEdge) = iszero(e.μ)

function find_arb!(x::Vector{T}, e::SplitMergeEdge{T}, η::AbstractVector{T}) where T
    gap = splitmerge_gap(η)
    if iszero(e.μ)
        tol = sqrt(eps(T))
        if gap > tol
            splitmerge_flow!(x, e, e.B)
        elseif gap < -tol
            splitmerge_flow!(x, e, -e.B)
        else
            fill!(x, zero(T))
        end
    else
        w = clamp(gap / e.μ, -e.B, e.B)
        abs(w) < sqrt(eps(T)) ? fill!(x, zero(T)) : splitmerge_flow!(x, e, w)
    end
    return nothing
end
```

- [ ] **Step 4: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/prediction_markets.jl test/prediction_markets.jl
git commit -m "feat: Moreau-Yosida smoothing for SplitMerge hyperedge

Add optional μ parameter to SplitMergeEdge (thesis §5 'strict concavity
trick'). When μ > 0, find_arb! returns w = clamp(gap/μ, -B, B) instead of
the bang-bang oracle, making the dual C¹. is_nonsmooth returns false so the
solver routes to L-BFGS-B (appropriate for C¹ objectives per Asl-Overton
2020). Primal recovery (recover_splitmerge_flow!) is unchanged — it uses
the exact reconstruction procedure from thesis §5.2."
```

### Task 3: Wire smoothing into the prediction market API

**Files:**
- Modify: `src/prediction_market_api.jl`

**Design:** Keep the doubling loop for conditioning (small B → well-conditioned Hessian). Add smoothing at each doubling level. Cap B at analytical B_max from AMM reserves.

- [ ] **Step 1: Add _analytical_split_bound**

```julia
function _analytical_split_bound(problem::PredictionMarketProblem{T}) where T
    # Physical upper bound: B ≤ min_i(h_i + R_outcome_i)
    # No flow can exceed the total obtainable tokens for any outcome.
    outcome_caps = Dict{String,T}()
    for outcome in problem.outcomes
        outcome_caps[outcome.outcome_id] = outcome.initial_holding
    end
    for market in problem.markets
        if market isa ConstantProductMarketSpec
            cap = get(outcome_caps, market.outcome_id, zero(T))
            outcome_caps[market.outcome_id] = cap + market.outcome_reserve
        end
    end
    isempty(outcome_caps) && return max(problem.collateral_balance, eps(T))
    return minimum(values(outcome_caps))
end
```

- [ ] **Step 2: Add smoothing parameter computation**

```julia
function _smoothing_parameter(::Type{T}, B::T, gap_tol::T) where T
    # μ = gap_tol / (5 * B²) ensures smoothing bias ≤ gap_tol/10
    B_safe = max(B, one(T))
    return gap_tol / (convert(T, 5) * B_safe * B_safe)
end
```

- [ ] **Step 3: Thread smoothing through _prediction_market_edges and _solve_prediction_market_once**

In `_prediction_market_edges`, add `smoothing::T=zero(T)` parameter and pass μ to SplitMergeEdge:

```julia
push!(edges, SplitMergeEdge(collect(1:(length(problem.outcomes) + 1)), bound; μ=smoothing))
```

Thread `smoothing` keyword through `_solve_prediction_market_once` → `_prediction_market_solver` / `_workspace_solver!`.

- [ ] **Step 4: Update _solve_prediction_market_mixed**

Replace the mixed solve function. Key changes:
1. Compute B_max as cap on doubling
2. Compute μ = gap_tol / (5 · B²) at each doubling level
3. Pass smoothing to _solve_prediction_market_once

```julia
function _solve_prediction_market_mixed(
    problem::PredictionMarketProblem{T};
    max_doublings::Int=6,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    solver_options::NamedTuple=(;),
    workspace::Union{Nothing,PredictionMarketWorkspace{T}}=nothing,
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}=nothing,
) where T
    max_doublings >= 0 || throw(ArgumentError("max_doublings must be nonnegative"))

    split_bound = isnothing(problem.split_bound) ? _default_split_bound(problem) : problem.split_bound
    B_max = _analytical_split_bound(problem)
    best_result = nothing
    ν_seed = !isnothing(workspace) ? _workspace_seed(workspace, :direct_only) : nothing

    # Compute gap_tol to match _solve_certificate_tolerances
    pgtol = haskey((; solver_options...,), :pgtol) ? (;solver_options...,).pgtol : 1e-5
    gap_tol = max(convert(T, 500) * sqrt(eps(T)), convert(T, 500) * convert(T, pgtol))

    for doubling in 0:max_doublings
        μ = _smoothing_parameter(T, split_bound, gap_tol)
        result, ν_seed = _solve_prediction_market_once(
            problem;
            mode=:mixed_enabled,
            split_bound=split_bound,
            certify=certify,
            throw_on_fail=false,
            solver_options=solver_options,
            workspace=workspace,
            ν0=ν_seed,
            gas_model=gas_model,
            smoothing=μ,
        )
        if certify && result.status == "uncertified"
            if !isnothing(best_result)
                return best_result
            end
            if throw_on_fail
                throw(_PredictionMarketSolveFailed(
                    "mixed solve failed certification at split_bound=$(split_bound)"))
            end
            return result
        end
        best_result = result
        if max(result.split_merge.mint, result.split_merge.merge) < convert(T, 0.8) * split_bound
            return result
        end
        if doubling == max_doublings
            message = "split/merge bound remained near-active after $(max_doublings) doublings (bound=$(split_bound))"
            if throw_on_fail
                throw(_PredictionMarketSolveFailed(message))
            end
            return _mark_prediction_market_uncertified(result, message)
        end
        split_bound = min(split_bound * convert(T, 2), B_max)
    end
    return best_result
end
```

- [ ] **Step 5: Run all tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add src/prediction_market_api.jl test/prediction_markets.jl
git commit -m "feat: smoothed doubling loop with analytical B_max cap

Wire Moreau-Yosida smoothing into the mixed solver's doubling loop:
- μ = gap_tol / (5·B²) at each level, ensuring bias ≤ gap_tol/10
- Analytical B_max from AMM reserves caps the doubling to prevent
  exploring physically impossible bounds
- Doubling loop preserved for conditioning (start small, grow as needed)

This enables certification at B > 104, where the unsmoothed BFGS oracle
previously oscillated between mint-B and merge-B, corrupting the Hessian
and producing primal = -Inf."
```

---

## Chunk 3: Fix Rust Replay with Algorithmic Symmetry

### Task 4: Replace aggregate affordability check with sequential simulation

**Files:**
- Modify: `deep_trading/src/portfolio/core/forecastflows/translate.rs:850-933`

**Rationale:** Floating-point error is O(ε · Σ|c_i|), relative to cost magnitudes. An absolute margin (EPS × N) is dimensionally wrong. The correct fix: make the binary search predicate use identical sequential cash subtraction as `replay_buy`, so the search and execution agree at every floating-point bit.

- [ ] **Step 1: Replace merge_round_buy_cost with simulate_merge_round_affordable**

```rust
/// Simulates a merge round's sequential buys using the same FP operations
/// as replay_buy. Returns true iff all buys are affordable.
fn simulate_merge_round_affordable(
    sims: &[super::super::sim::PoolSim],
    sim_idx_by_market: &HashMap<&'static str, usize>,
    sim_balances: &BalanceMap,
    ordered_route: &[OrderedTradeRoute],
    amount: f64,
    cash: f64,
) -> Result<bool, ForecastFlowsTranslationError> {
    let mut simulated_cash = cash;
    for route in ordered_route {
        let holding = sim_balances
            .get(route.market_name)
            .copied()
            .unwrap_or(0.0)
            .max(0.0);
        let shortfall = (amount - holding).max(0.0);
        if shortfall <= DUST || amounts_match_within_replay_tolerance(shortfall, 0.0) {
            continue;
        }
        let idx = *sim_idx_by_market.get(route.market_name).ok_or_else(|| {
            ForecastFlowsTranslationError::invalid_response(format!(
                "missing sim for market {}",
                route.market_name
            ))
        })?;
        let Some((bought, cost, _)) = sims[idx].buy_exact(shortfall) else {
            return Ok(false);
        };
        if bought + EPS < shortfall || !cost.is_finite() {
            return Ok(false);
        }
        if simulated_cash + EPS < cost {
            return Ok(false);
        }
        simulated_cash -= cost;
    }
    Ok(true)
}
```

- [ ] **Step 2: Update affordable_merge_round to use sequential predicate**

Replace the body of `affordable_merge_round` to use `simulate_merge_round_affordable` in both the fast-path check and the binary search.

- [ ] **Step 3: Delete unused merge_round_buy_cost**

- [ ] **Step 4: Run Rust tests**

Run: `cd /Users/shotaro/proj/deep_trading && cargo test --lib portfolio::core::forecastflows`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/shotaro/proj/deep_trading
git checkout -b fix/replay-buy-merge-algorithmic-symmetry
git add src/portfolio/core/forecastflows/translate.rs
git commit -m "fix: algorithmic symmetry for buy-merge round affordability

Replace merge_round_buy_cost (aggregate sum: total = Σcost_i) with
simulate_merge_round_affordable (sequential: cash -= cost_i per step).
The binary search now uses identical FP operations as replay_buy,
eliminating non-associativity discrepancies without arbitrary margins."
```

---

## Chunk 4: End-to-End Verification

### Task 5: Run the full pathological benchmark

- [ ] **Step 1: Run ForecastFlows.jl test suite**

Run: `cd /Users/shotaro/proj/ForecastFlows.jl && julia --project -e 'using Pkg; Pkg.test()'`

- [ ] **Step 2: Run the pathological benchmark**

```bash
cd /Users/shotaro/proj/deep_trading
FORECASTFLOWS_BENCHMARK_ASSERT=1 cargo test \
  forecastflows_pathological_stress_cases_show_material_net_ev_gap_when_enabled \
  -- --nocapture --test-threads=1
```

Expected:
- Mixed solver certifies at B > 104 (likely B ∈ [104, 208] or higher)
- Replay succeeds
- Mixed net EV approaches or exceeds native's 132.03 sUSD

- [ ] **Step 3: Record and analyze results**

| Case | B_certified | Mixed Net EV | Native Net EV | Gap | Winner |
|------|------------|-------------|---------------|-----|--------|
| 18-outcome | ? | ? | 132.03 | ? | ? |
| multiband | ? | ? | 39.39 | ? | ? |

If mixed EV < native: investigate whether the BFGS has converged to a suboptimal local minimum. Consider:
- Increasing max_iter for L-BFGS-B
- Continuation: solve first with large μ, warm-start with small μ
- Reducing pgtol for tighter convergence

### Task 6: Revert deep_trading Manifest.toml

- [ ] **Step 1: Restore remote repo pointer**

```bash
cd /Users/shotaro/proj/deep_trading
julia --project=julia/forecastflows -e 'using Pkg; Pkg.update("ForecastFlows")'
git add julia/forecastflows/Manifest.toml
git commit -m "chore: update ForecastFlows.jl to include smoothed mixed solver"
```

---

## Summary of Expected Outcomes

| Metric | Before | After (Expected) |
|--------|--------|-------------------|
| Split/merge dual | Nonsmooth kink at Σν_i = ν_0 | C¹ via Moreau-Yosida (μ = gap_tol/5B²) |
| BFGS method at B>104 | :bfgs_exact (fails: gradient jump = 2B) | :lbfgsb (smooth dual, superlinear convergence) |
| Primal recovery | Thesis §5.2 reconstruction (unchanged) | Same — smoothing only affects BFGS trajectory |
| Replay binary search | Aggregate sum (FP mismatch) | Sequential simulation (algorithmic symmetry) |
| 18-outcome FF net EV | 20.53 (direct only; mixed blocked) | ~130+ (merge leverage at B > 132) |
| FF vs native gap | −111.50 | Near zero or positive |

## References

- [Convex Network Flows (paper)](https://arxiv.org/abs/2404.00765) — §4 (dual decomposition), §5.2 (primal recovery)
- [Diamandis PhD thesis](https://dspace.mit.edu/handle/1721.1/158483) — §5 (strict concavity trick), §5.2 (reconstruction problem)
- [Lewis & Overton (2013)](https://people.orie.cornell.edu/aslewis/publications/bfgs_inexactLS.pdf) — BFGS on nonsmooth functions
- [Asl & Overton (2020)](https://arxiv.org/abs/2006.11336) — L-BFGS on Nesterov smoothings: "much more efficient" than on nonsmooth directly
- [Moreau-Yosida regularization (SIAM)](https://epubs.siam.org/doi/10.1137/S1052623494267127) — practical aspects, parameter selection
