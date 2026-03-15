# Implementation Plan: Prediction Market Order Router via Convex Network Flows

**Author:** Implementation guide for ForecastFlows.jl
**References:**
- Diamandis, Angeris, Edelman — *Convex Network Flows* (PhD thesis, Chapter 2–5) → `foresight-docs/phd_thesis.md`
- arXiv 2404.00765v2 → `foresight-docs/2404.00765v2.md`
- Peer review roadmap → `foresight-docs/grad_student_peer_review.md`

## Status Update

This document is the original implementation plan. The shipped implementation now differs from the older portfolio-rebalancing framing in two important ways:

- the root router is an execution solver, not an upstream portfolio optimizer
- nonsmooth prediction-market instances use the exact-BFGS path in the root `Solver`, with mandatory certification and fail-closed behavior

The canonical implementation note is now:

- `foresight-docs/prediction_market_router.md`

In particular, the imported Deep-Trading 98-outcome regression is no longer the older complete-set execution benchmark. The shipped benchmark now:

- uses the endowment-aware `EndowmentLinear` portfolio-EV objective
- maps the fixture into a benchmark-local single-tick AMM edge calibrated directly from the Deep-Trading market state
- compares certified raw convex solves to no-flash replayed executable EV under the same single-tick formulas
- keeps gas as a separate rough fixed-charge proxy in Julia, rather than the richer grouped gas model used inside Deep-Trading

Validated benchmark outputs for the current implementation are:

- direct raw EV: `150.25828864961397`
- mixed raw EV: `150.38032237147735`
- gas-proxy net EV: `150.36336211734135`

Those values are very close to the committed Deep-Trading raw references, but the gas-proxy net EV should still be treated as a Julia-local approximation rather than a direct Deep-Trading net-EV comparison.

---

## 0. Problem Statement

We have $N+1$ assets: 1 collateral $C$ (index 0) and $N$ mutually exclusive outcome tokens $O_1, \ldots, O_N$ (indices $1, \ldots, N$). There are $N$ AMM pools, each trading $C \leftrightarrow O_i$. There is a structural **mint/merge** operation: 1 unit of $C$ converts to 1 unit of every $O_i$, and vice versa.

A trader holds an existing portfolio $(h_0, h_1, \ldots, h_N) \geq 0$ and has predictions $(\mu_1, \ldots, \mu_N)$ for the probability that each outcome resolves to 1. They want to **rebalance** to maximize expected value.

The solver must automatically discover **all** trading routes:

| Route | Mechanism | When profitable |
|-------|-----------|-----------------|
| **Direct buy** $O_i$ | $C \xrightarrow{\text{AMM}_i} O_i$ | $\mu_i > p_i$ (outcome underpriced) |
| **Synthetic buy** $O_i$ | $C \xrightarrow{\text{mint}} (O_1,\ldots,O_N) \xrightarrow{\text{sell } O_{j \neq i}} C$ | Cheaper than direct when AMM_i is illiquid or expensive |
| **Direct sell** $O_i$ | $O_i \xrightarrow{\text{AMM}_i} C$ | $\mu_i < p_i$ (outcome overpriced) |
| **Synthetic sell** $O_i$ | $C \xrightarrow{\text{AMM}_{j \neq i}} (O_{j \neq i})$, then $(O_1,\ldots,O_N) \xrightarrow{\text{merge}} C$ | Cheaper than direct sell when AMM_i is illiquid |
| **Mint-sell arb** | $C \xrightarrow{\text{mint}} (O_1,\ldots,O_N) \xrightarrow{\text{sell all}} C$ | $\sum p_i > 1$ (overround) |
| **Buy-merge arb** | $C \xrightarrow{\text{AMMs}} (O_1,\ldots,O_N) \xrightarrow{\text{merge}} C$ | $\sum p_i < 1$ (underround) |

**Key insight (thesis §5.1):** We do not enumerate these routes. The dual decomposition discovers them automatically. Shadow prices $\nu$ adjust until the marginal value of each asset is consistent across all edges. If a synthetic route is optimal, the solver activates the hyperedge and the relevant AMMs simultaneously.

---

## 1. Mathematical Formulation

### 1.1 Network as Hypergraph

Nodes: $\{0, 1, \ldots, N\}$ (one per asset).

Edges:
- $N$ AMM edges $e_1, \ldots, e_N$, each connecting nodes $\{0, i\}$
- 1 split/merge hyperedge $e_{sm}$, connecting nodes $\{0, 1, \ldots, N\}$

Total edges: $m = N + 1$.

### 1.2 AMM Edge Flow Sets

For AMM $i$ trading $C \leftrightarrow O_i$ with reserves $(R_{i,0}, R_{i,1})$, fee $\gamma_i \in (0, 1]$, and constant-product invariant:

$$T_i = \left\{ x \in \mathbb{R}^2 \;\bigg|\; (R_{i,0} + \gamma_i \Delta_0 - \Lambda_0)(R_{i,1} + \gamma_i \Delta_1 - \Lambda_1) \geq R_{i,0} R_{i,1} \right\}$$

where $\Delta_j = \max(-x_j, 0)$ (tendered) and $\Lambda_j = \max(x_j, 0)$ (received). This is the standard CFMM constraint (thesis §4.2). The set is compact, convex, and downward-closed.

**Note on AMM type:** The on-chain pools may be Uniswap V3 (concentrated liquidity) rather than constant-product. The existing `UniV3` type in CFMMRouter.jl handles this. For the initial implementation, use constant-product (`ProductTwoCoin`) with reserves read from on-chain state. Upgrade to V3 tick-based later.

### 1.3 Split/Merge Hyperedge Flow Set

There is no split/merge protocol fee in this market. Let $B > 0$ be a transaction size bound.

The flow vector $z \in \mathbb{R}^{N+1}$ is parameterized by a scalar $w \in [-B, B]$:

**Minting ($w > 0$):** Tender $w$ collateral, receive $w$ of each outcome.
$$z_0 \leq -w, \quad z_i \leq w \quad \text{for } i = 1, \ldots, N$$

**Merging ($w < 0$, set $w = -|w|$):** Tender $|w|$ of each outcome, receive $|w|$ collateral.
$$z_0 \leq |w|, \quad z_i \leq -|w| \quad \text{for } i = 1, \ldots, N$$

Combining into a single set (with the sign convention that positive $w$ = mint, negative $w$ = merge):

$$T_{sm} = \left\{ z \in \mathbb{R}^{N+1} \;\bigg|\; \exists w \in [-B, B] : \begin{cases} z_0 \leq -w, \; z_i \leq w & \text{if } w \geq 0 \\ z_0 \leq -w, \; z_i \leq w & \text{if } w < 0 \end{cases} \right\}$$

**Downward closure (thesis §2.1):** If $z \in T_{sm}$ and $z' \leq z$ componentwise, then $z' \in T_{sm}$. This holds because all constraints are upper bounds. ∎

**Compactness:** Bounded by $B$ in every component. ∎

### 1.4 Arbitrage Subproblem for the Hyperedge

Given shadow prices $\nu = (\nu_0, \nu_1, \ldots, \nu_N) \geq 0$, we solve (thesis §3.2, eq. 3.5):

$$f_{sm}(\nu) = \max_{z \in T_{sm}} \nu^T z$$

Since $\nu \geq 0$, the maximum is attained on the boundary (equalities hold). This gives:

$$f_{sm}(\nu) = \max_{w \in [-B, B]} w\left[\sum_{i=1}^N \nu_i - \nu_0\right]$$

Define:
$$\sigma = \sum_{i=1}^N \nu_i - \nu_0$$

So the solution is:

| Condition | $w^*$ | Action | $f_{sm}$ |
|-----------|--------|--------|----------|
| $\sigma > 0$ | $+B$ | Mint | $B \cdot \sigma$ |
| $\sigma < 0$ | $-B$ | Merge | $B \cdot |\sigma|$ |
| $\sigma = 0$ | $0$ | Nothing | $0$ |

**Gradient contribution (thesis §3.3):** The optimal flow $z^*$ is returned to the solver, which accumulates it into $\nabla_\nu g$. Specifically, $\nabla_\nu f_{sm} = z^*$ (the optimal flow vector). This is used in `grad!` at [solver.jl:165](src/solver.jl#L165).

### 1.5 Objective Function: Portfolio Rebalancing

The trader holds $(h_0, h_1, \ldots, h_N)$ and wants to rebalance. The net flow $y \in \mathbb{R}^{N+1}$ represents trades executed; the final portfolio is $h + y$.

**Expected value objective:**
$$U(y) = \sum_{i=1}^N \mu_i (h_i + y_i) + (1 - \sum_{i=1}^N \mu_i)(h_0 + y_0)$$

But this is linear in $y$, so it has no finite maximum without constraints. We need **budget constraints**: can't sell more than you own, can't spend more collateral than you have.

**Penalized objective (practical formulation):**
$$U(y) = -\frac{1}{2} \sum_{i=0}^N a_i \left(b_i - y_i\right)_+^2$$

where $b_i$ encodes the desired trade (e.g., $b_0 = -D$ for spending $D$ collateral, $b_i = $ target position changes) and $a_i$ controls the penalty steepness. This is the `NonpositiveQuadratic` objective already implemented in [objectives.jl:55](src/objectives.jl#L55).

However, the simplest correct formulation uses the **Linear objective with box constraints on $\nu$**:

$$U(y) = c^T y$$

where $c_i = \mu_i$ for outcome tokens and $c_0 = 1 - \sum \mu_i$ (or simply $c_0 = \epsilon$ if we want to maximize outcome value and treat collateral as the numeraire). The conjugate $\bar{U}(\nu) = \sup_y \{c^T y - \nu^T y\} = 0$ when $\nu \geq c$, and $+\infty$ otherwise. The lower bound on $\nu$ is $c$, enforced by L-BFGS-B box constraints. This is implemented as `LinearNonnegativeCustom` in the test file [test/solver.jl:45-76](test/solver.jl#L45-L76).

**Handling the budget / existing holdings:** The budget constraint $y_0 \geq -D$ (don't spend more than $D$) and position constraints $y_i \geq -h_i$ (don't sell more than you own) should ideally be encoded in $U$. The `NonpositiveQuadratic` objective naturally enforces soft versions of these. For a hard constraint approach: add a "virtual edge" per asset that models the existing holdings as a bounded source (see §2.4 below).

### 1.6 The Global Routing Problem

$$\begin{aligned}
\min_\nu \quad g(\nu) &= \bar{U}(\nu) + \sum_{i=1}^N f_i(\nu_0, \nu_i) + f_{sm}(\nu_0, \nu_1, \ldots, \nu_N) \\
\text{s.t.} \quad \nu &\geq \ell \quad \text{(box constraints from objective)}
\end{aligned}$$

where each $f_i$ is the AMM arbitrage subproblem (solved by the existing `find_arb!` for `Uniswap`/`ProductTwoCoin` edges) and $f_{sm}$ is the split/merge subproblem derived above.

**Strong duality** holds by thesis Theorem 3.1, since all $T_i$ and $T_{sm}$ are compact convex and downward-closed, and $U$ is concave nondecreasing.

---

## 2. Implementation Steps

### 2.1 Step 1: Define `SplitMergeEdge`

**File:** `src/edges.jl` (add after existing edge types)

```julia
struct SplitMergeEdge{T} <: Edge{T}
    Ai::Vector{Int}    # [collateral_idx, outcome_1_idx, ..., outcome_N_idx]
    B::T               # Transaction size bound
end
```

`Ai` must list all $N+1$ node indices. `Ai[1]` = collateral, `Ai[2:end]` = outcomes.

**Implement `find_arb!`:**

```julia
function find_arb!(x::Vector{T}, e::SplitMergeEdge{T}, η::AbstractVector{T}) where T
    # η = [ν_0, ν_1, ..., ν_N] (local shadow prices for this edge's nodes)
    ν0 = η[1]
    Σν = sum(@view η[2:end])

    σ = Σν - ν0

    if σ > eps(T)
        # MINT: tender collateral, receive one of each outcome
        x[1] = -e.B
        @views x[2:end] .= e.B
    elseif σ < -eps(T)
        # MERGE: tender each outcome, receive collateral
        x[1] = e.B
        @views x[2:end] .= -e.B
    else
        # No-arbitrage region: do nothing
        fill!(x, zero(T))
    end
    return nothing
end
```

**Why this works with the solver:** The solver calls `find_arb!(s.xs[i], s.edges[i], view(s.ν, ...))` at [solver.jl:66](src/solver.jl#L66). It passes a view of $\nu$ indexed by `e.Ai`. The returned `x` vector has length $N+1$ matching the edge. The gradient at [solver.jl:165](src/solver.jl#L165) accumulates `x` back into the global gradient at the indices `e.Ai`. No changes to the solver needed.

**Verify:** `length(e::Edge)` returns `length(e.Ai)` via [edges.jl:6](src/edges.jl#L6). For `SplitMergeEdge`, this is $N+1$. The solver allocates `xs[i] = zeros(T, length(e.Ai))` at [solver.jl:39](src/solver.jl#L39). ✓

### 2.2 Step 2: Unit Test — Minimal Prediction Market

**File:** `test/split_merge.jl`

Test case: $N = 2$ outcomes, 2 AMM pools, 1 split/merge edge, 3 total nodes.

```
Nodes:  0 (Collateral)    1 (Outcome A)    2 (Outcome B)
Edges:  AMM_A: {0, 1}     AMM_B: {0, 2}    SplitMerge: {0, 1, 2}
```

**Test 2a — No-arbitrage baseline:**
Set AMM reserves such that $p_A + p_B = 1$ exactly. Use a linear objective with $c = (0, p_A, p_B)$ (predictions match market prices). Verify: solver produces zero net flows (nothing to trade).

**Test 2b — Synthetic buy is cheaper than direct:**
Set AMM_A with very low liquidity (high slippage) and AMM_B with high liquidity. Use objective wanting to acquire $O_A$. Verify: solver routes through mint + sell $O_B$ rather than direct buy from AMM_A.

**Test 2c — Synthetic sell:**
User holds lots of $O_A$ and wants to reduce exposure. AMM_A has low liquidity. Verify: solver buys $O_B$ via AMM_B, merges $(O_A, O_B) \to C$, i.e., a synthetic sell of $O_A$.

**Test 2d — Overround arbitrage:**
Set reserves such that $p_A + p_B > 1$. Use linear objective with $c_0 > 0$ (values collateral). Verify: solver mints and sells both outcomes, profiting from the overround.

**Verification conditions (per the test pattern in [test/solver.jl:91-99](test/solver.jl#L91-L99)):**
- Primal feasibility: `all(s.y .≥ -tolerance)`
- For each AMM: spot price matches shadow price ratio within tolerance
- For split/merge: either $|w^*| = B$ and $|\sigma| > 0$, or $w^* = 0$ and $\sigma^+ \leq 0 \leq \sigma^-$

### 2.3 Step 3: Objective Function for Portfolio Rebalancing

Start with the linear objective (already working in tests). Define $c$ from predictions:

```julia
# μ[i] = predicted probability of outcome i resolving to 1
# All outcomes sum to 1 (mutually exclusive, exhaustive)
c = vcat([1e-4], μ)  # small positive weight on collateral (numeraire)
obj = LinearNonnegativeCustom(c)
```

The L-BFGS-B box constraint $\nu \geq c$ ensures the conjugate is finite. The solver maximizes $c^T y$ subject to network flow constraints.

**Budget constraint:** Rather than modifying $U$, model the existing portfolio as a **source edge** — a trivial edge that supplies up to $h_i$ units of asset $i$:

```julia
struct PortfolioSource{T} <: Edge{T}
    Ai::Vector{Int}    # single node [i]
    supply::T          # maximum supply h_i
end

function find_arb!(x::Vector{T}, e::PortfolioSource{T}, η::AbstractVector{T}) where T
    # Can supply up to e.supply units at any positive price
    x[1] = η[1] > eps(T) ? e.supply : zero(T)
    return nothing
end
```

Add one `PortfolioSource` per asset where $h_i > 0$. This injects the holdings into the network — the solver decides how much of each holding to deploy.

**Alternative (simpler, recommended for v1):** Use `NonpositiveQuadratic` with $b_0 = -D$ (budget), $b_i = $ target net position. This penalizes deviation from target quadratically, giving a well-posed convex problem without needing source edges.

### 2.4 Step 4: Graph Construction for 98-Outcome Market

```julia
N = 98
n_nodes = N + 1  # node 0 = collateral, nodes 1..98 = outcomes

edges = Edge[]

# AMM edges: one per outcome
for i in 1:N
    R = get_reserves(i)     # (R_C, R_Oi) from on-chain query
    γ = get_fee_rate(i)     # e.g., 0.997 for 0.3% fee
    push!(edges, Uniswap(R, γ, [1, i + 1]))  # node indices: collateral=1, outcome_i=i+1
    # Note: ConvexFlows uses 1-based indexing for nodes
end

# Split/merge hyperedge: connects all nodes
sm_indices = collect(1:n_nodes)  # [1, 2, 3, ..., 99]
B = total_collateral_budget      # set to available capital
ϕ = 0.0                          # adjust if protocol charges fees
push!(edges, SplitMergeEdge(sm_indices, B, ϕ))

# Objective
μ = get_predictions()  # Vector of length 98
c = vcat([1e-4], μ)    # length 99
obj = LinearNonnegativeCustom(c)

# Solve
s = Solver(flow_objective=obj, edges=edges, n=n_nodes)
solve!(s, verbose=true)
```

**After solving:** `s.y` contains the optimal net flows. `s.xs[end]` contains the split/merge flow. `s.xs[i]` for $i = 1, \ldots, N$ contains the AMM trades.

**Handling pools with zero liquidity:** If AMM $i$ has no liquidity, either:
- Omit the edge entirely (reduces $m$, cleaner)
- Set reserves to effectively zero (the `find_arb!` will return zero flow)

The solver still finds synthetic routes through the mint/merge edge for illiquid outcomes — this is one of the framework's key advantages.

### 2.5 Step 5: Add Gas-Aware Post-Processing

Gas is a fixed cost per edge activation, which makes the problem mixed-integer. We handle this with an iterative heuristic:

```
1. Solve continuous relaxation (the convex flow problem above)
2. For each active edge (|x_i| > ε):
     Compute profit_i = ν^T x_i  (shadow-price-weighted flow)
     Compute gas_i = estimate_gas(edge_i)
     If profit_i < gas_i: deactivate edge (remove from problem)
3. Re-solve with reduced edge set
4. Repeat until stable
```

This converges quickly because deactivating low-profit edges barely changes the optimal routing for high-profit edges.

### 2.6 Step 6: Transaction Encoding (Downstream)

The solver output $(x_1, \ldots, x_N, x_{sm})$ maps directly to on-chain actions:

| Solver output | On-chain action |
|--------------|-----------------|
| $x_i$ with $x_{i,0} < 0$ | Swap collateral → outcome_i via AMM_i |
| $x_i$ with $x_{i,1} < 0$ | Swap outcome_i → collateral via AMM_i |
| $x_{sm,0} < 0$ (mint) | Call `splitPosition(collateral, |x_{sm,0}|)` |
| $x_{sm,0} > 0$ (merge) | Call `mergePositions(outcomes, x_{sm,0}/(1-ϕ))` |

Bundle into a single multicall transaction. The 40M gas limit chunking is a separate problem: partition the action set into groups that fit within the block gas limit, ordered by profitability.

---

## 3. What Changes in the Existing Codebase

| File | Change | Reason |
|------|--------|--------|
| `src/edges.jl` | Add `SplitMergeEdge` struct + `find_arb!` method | New edge type |
| `src/ConvexFlows.jl` | Add `SplitMergeEdge` to exports | Expose new type |
| `test/split_merge.jl` | New test file | Verify correctness |
| Nothing else | — | Solver, objectives, gradient logic all work unchanged |

The solver at [solver.jl:62-74](src/solver.jl#L62-L74) already handles variable-length edges via `SVector{length(s.edges[i])}(s.edges[i].Ai)`. The gradient accumulation at [solver.jl:165](src/solver.jl#L165) also generalizes. No solver modifications needed.

**One caveat:** `SVector{length(s.edges[i])}` creates a **compile-time sized** static vector. For $N+1 = 99$, this creates `SVector{99}` which is fine for a single hyperedge but would be inefficient if you had many large hyperedges. Since we have exactly one, this is acceptable. If needed later, switch to a regular `Vector` view (the commented-out line at solver.jl:165 shows this was considered).

---

## 4. Correctness Argument

**Claim:** The optimal solution to the dual problem, combined with the edge-level `find_arb!` solutions, yields the globally optimal routing across all six route types listed in §0.

**Proof sketch:**
1. By thesis Theorem 3.1, strong duality holds: the dual optimum equals the primal optimum.
2. The dual decomposes over edges (thesis §3.2): each edge subproblem is solved independently given $\nu$.
3. The L-BFGS-B optimizer over $\nu$ finds the dual minimum (the dual is convex, and the box-constrained L-BFGS-B converges to a stationary point which is globally optimal for convex problems).
4. At the optimum $\nu^*$, the primal flows $x_i^*$ (from `find_arb!`) satisfy complementary slackness, and $y^* = \sum A_i x_i^*$ is the optimal net trade.
5. All six route types are **emergent behaviors** of the composition of AMM edges + hyperedge. The solver doesn't know about "synthetic sells" — it just finds the $\nu^*$ where no edge can profitably arbitrage. ∎

**The synthetic sell, explicitly:** Suppose the solver wants to reduce $O_1$ exposure. The optimal $\nu^*$ will have $\nu_1$ relatively low. This makes it profitable for AMM edges $j \neq 1$ to buy $O_j$ (because $\nu_j$ is relatively high), and the hyperedge to merge when $\sum \nu_i < \nu_0$. The net effect: the solver buys $O_{j \neq 1}$ from AMMs, merges everything (consuming the user's held $O_1$ tokens), and receives collateral. This is exactly the synthetic sell — and the solver found it through price equilibration, not path enumeration.

---

## 5. Potential Issues and Mitigations

| Issue | Severity | Mitigation |
|-------|----------|------------|
| `SVector{99}` may cause compilation time overhead | Low | Only one hyperedge; compile once. If slow, use regular `Vector` views |
| Bang-bang solution ($w^* = \pm B$ or $0$) means gradient of $f_{sm}$ is discontinuous | Low | AMMs provide curvature that regularizes the overall dual. L-BFGS-B handles box constraints natively |
| $B$ too large → numerical issues, too small → suboptimal | Medium | Set $B = D$ (total capital). The solver will use $\leq B$ naturally |
| AMM reserves stale between solve and execution | Medium | Read reserves at execution time, re-solve if slippage exceeds threshold |
| Concentrated liquidity (Uni V3) not yet modeled | Medium | Start with constant-product approximation. CFMMRouter.jl has `UniV3` type to adopt later |
| 98 outcomes × ~99 dual variables | Low | L-BFGS-B is efficient for moderate dimensions. Expect solve in < 1 second |

---

## 6. Execution Order

```
Step 1  →  Define SplitMergeEdge + find_arb!
            verify: compiles, find_arb! returns correct x for manual ν inputs

Step 2  →  Write N=2 unit tests (2a–2d from §2.2)
            verify: all @test pass, solver finds synthetic routes

Step 3  →  Choose objective, test with N=2 + holdings/budget
            verify: solver respects budget, rebalances toward predictions

Step 4  →  Scale to N=98, plug in real AMM reserves
            verify: solver converges, solve time < 5s, flows are feasible

Step 5  →  Gas-aware pruning loop
            verify: unprofitable edges eliminated, total profit net of gas improves

Step 6  →  Encode solver output as on-chain transactions
            verify: dry-run against fork, compare expected vs actual fills
```
