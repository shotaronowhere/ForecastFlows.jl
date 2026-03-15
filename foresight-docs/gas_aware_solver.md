# Gas-Aware Solver: Theory, Status, and Plan

## Problem Statement

On-chain execution of prediction-market trades incurs fixed gas costs per pool
interaction, independent of trade volume. The optimal routing problem with gas
fees is therefore a **mixed-integer** optimization: we must jointly decide which
edges to activate (combinatorial) and how much to flow through each active edge
(continuous convex).

This problem is **NP-hard** — Diamandis proves this via reduction from
knapsack [1, Chapter 7]. No polynomial-time exact algorithm exists. All
practical approaches solve a continuous relaxation and round.

## Theoretical Foundations

### The Convex Flow Framework (Diamandis, 2024)

The ForecastFlows solver is built on the dual decomposition of the convex
network flow problem [1, 2]. The dual objective decomposes over edges:

$$g(\nu) = \bar{U}(\nu) + \sum_{i=1}^{m} f_i(A_i^T \nu)$$

where $f_i(\eta_i) = \sup_{x_i \in T_i} \eta_i^T x_i$ is the support function
(arbitrage subproblem) for edge $i$. This is solved by L-BFGS-B or exact BFGS
on the dual variables $\nu$ (shadow prices), with each edge oracle computed in
parallel.

### Fixed Edge Fees (Diamandis, Chapter 7)

Adding a fixed activation cost $q_i \geq 0$ per edge, the problem becomes:

$$\max \; U(y) + \sum_i V_i(x_i) + q_i \lambda_i \quad \text{s.t.} \; (x_i, \lambda_i) \in \{0\} \cup (T_i \times \{-1\})$$

The constraint set $Q_i = \{0\} \cup (T_i \times \{-1\})$ is **nonconvex** (not
even connected). The convex relaxation replaces $Q_i$ with its convex hull
$\bar{K}_i = K_i \cap (\mathbb{R}^n \times [-1, 0])$, and the dual support
function becomes:

$$\sup_{(x_i, \lambda_i) \in Q_i} (\eta_i^T x_i + \lambda_i q_i) = \max(f_i(\eta_i) - q_i, 0)$$

The **Shapley-Folkman** bound guarantees that at most $n+1$ edges can be
fractional in the relaxation, giving an integrality gap of at most
$(n+1) \max_i q_i$ [1, §7.4].

### KKT Characterization (Escudero, Lara & Sama, 2026)

Escudero et al. [3] provide the first rigorous primal-space treatment of
gas-aware CFMM routing. They formulate the problem with explicit binary
activation variables $\eta_i \in \{0,1\}$ and trade bounds $y^i \leq \eta_i b^i$,
then study the continuous relaxation $\eta_i \in [0,1]$.

Key results:

1. **KKT system** (Theorem 3.1): At optimality, the gas fee relates to
   activation multipliers via $q_i = (\mu^i)^\top b^i$ for active markets.
   Inactive markets satisfy $q_i \geq (\mu^i)^\top b^i$ — the gas fee exceeds
   the marginal value of activation.

2. **Sufficient conditions without convexity** (Theorem 3.2): Under
   pseudoconcavity of the utility and quasilinearity of the trade functions,
   KKT conditions are necessary and sufficient for global optimality of the
   relaxation. This is stronger than requiring global convexity.

3. **Tighter approximation bound** (Theorem 3.4): The gap between the relaxed
   and integer-optimal solutions is bounded by:

   $$\varepsilon(q, \bar{\eta}) = q_{\max}(\|\bar{\eta}\|_0 - \|\bar{\eta}\|_1) + (q_{\max} - q_{\min})\|\bar{\eta}\|_1$$

   This is computable a priori from the relaxed solution and is typically
   tighter than the Shapley-Folkman bound.

4. **No-trade characterization** (Theorem 4.1): Gas fees expand the no-trade
   region. Prices must lie in $K_i^{\gamma_i} + \prod_j [-q_i / b_j^i, 0]$ —
   the standard no-arbitrage cone perturbed by a gas-dependent interval.

5. **Fractional activations are generic** (Remark 3.3): Under their constraint
   qualification, active markets with $q_i > 0$ generically have
   $\bar{\eta}_i < 1$ in the relaxation. Binary on/off forcing inside the
   optimization loop is therefore **mathematically incorrect** — it solves a
   harder problem than the relaxation with fewer guarantees.

### Complementary Approaches

- **Frank-Wolfe + Shapley-Folkman** (Dubois-Taine & d'Aspremont, 2025) [4]:
  Constructive two-stage algorithm for nonconvex separable problems under
  affine constraints. Provides a principled path from relaxation to
  near-integral primal solutions. Julia implementation available.

- **Hermes** (IEEE Blockchain'25) [5]: Exploits treewidth of DEX liquidity
  graphs for parameterized routing with formal quality guarantees. Achieves 4
  orders of magnitude speedup over convex methods on suitable graph topologies.

- **GeNIOS** (Diamandis et al., 2026) [6]: Generalized Newton inexact
  operator-splitting solver. Potential replacement for L-BFGS-B as the inner
  solver for the smooth convex phases.

## Current Implementation: What Went Wrong

The initial gas-aware implementation attempted to embed the Chapter 7 dual
modification directly inside the optimization loop:

1. After each edge oracle computes candidate flow, the solver zeroes out the
   edge if `edge_execution_value <= gas_cost`.
2. `dual_objective` subtracts `gas_cost` for active edges.
3. `primal_objective` subtracts `gas_cost` for active edges.

### Why This Fails

**Nonsmoothness**: The function $\max(f_i(\eta) - q_i, 0)$ has a kink at
$f_i(\eta) = q_i$. The gradient is discontinuous there: it jumps from the
edge's arb flow to zero. L-BFGS-B and BFGS build Hessian approximations from
gradient differences, and discontinuous gradients produce spurious curvature
estimates. This causes the optimizer to oscillate or stall near the kink.

**Primal feasibility coupling**: When gas thresholding kills one leg of a
coupled trade (e.g., a sell leg that frees collateral for a buy leg), the dual
prices still reflect both legs being active, but primal recovery sees only one.
The collateral constraint can become violated, producing infeasible or
uncertified solutions.

**Binary forcing in a continuous relaxation**: The thesis's relaxation allows
fractional activations $\lambda_i \in [-1, 0]$. Escudero et al. confirm this
is generic when $q_i > 0$. The in-loop thresholding forces binary on/off,
solving a strictly harder problem without the relaxation's guarantees.

### Observed Failures

1. Low-dimensional tests with high gas fail to fully zero out solutions
   (`norm(y) ~ 1e-5`, expected `<= 1e-8`).
2. Direct-only endowment cases produce uncertified/infeasible primals (infinite
   duality gap) because the buy leg survives but the compensating sell leg is
   killed.
3. Conservative scalar proxies (`max(buy_cost, sell_cost)`) change
   merge-vs-direct routing in unexpected ways.

## Planned Solution: Two-Phase Warm-Started Method

### Algorithm

```
Phase 1: solve!(s)
    — Gas-free certified convex solve.
    — Returns optimal dual prices ν* and edge flows x_i*.

Phase 2: Active-set determination
    — For each edge i, compute edge_value = f_i(A_i^T ν*)
    — If edge_value <= q_i + margin: mark edge as pruned.
    — The margin can be zero or a small adaptive buffer.

Phase 3: solve!(s_reduced; ν0 = ν*)
    — Reduced edge set, warm-started from Phase 1 duals.
    — Full certified convex solve on the surviving edges.
    — Converges fast from the nearby warm start.

Phase 4: Post-hoc accounting
    — net_objective = primal_objective(s_reduced) - Σ_{active} q_i
    — If net_objective < 0: return no-trade.
    — Compute Escudero bound ε(q, η̄) for diagnostics.
```

### Why This Works

- **Phases 1 and 3 are standard smooth convex solves** with full certification.
  No nonsmoothness is introduced into the optimizer.
- **Warm-starting Phase 3** from Phase 1 duals means few iterations to
  converge. For the 98-outcome benchmark, total time should be well under 5s.
- **The active-set decision (Phase 2) is outside the optimization loop.** It is
  a simple post-hoc comparison, not an in-loop perturbation.
- **Correctness is guaranteed by certification.** Both phases produce certified
  primal-dual pairs. The gas accounting is exact arithmetic on the certified
  solution.
- **The approximation gap is bounded** by Diamandis's Shapley-Folkman bound
  ($(n+1) \max_i q_i$) and more tightly by Escudero et al.'s
  $\varepsilon(q, \bar{\eta})$.

### Handling the SplitMergeEdge

Escudero et al. [3] treat only 2-node CFMM edges. The SplitMergeEdge is an
$(N+1)$-node hyperedge with a bang-bang (nonsmooth) oracle. For gas purposes:

- The split/merge edge gets its own activation cost $q_{sm}$.
- In Phase 2, `edge_value = |gap| * B` where `gap = Σ η_outcomes - η_collateral`
  and `B` is the split/merge bound.
- If `|gap| * B <= q_sm`: the split/merge edge is pruned.
- Phase 3 re-solves without the split/merge edge if pruned.

For multiple split/merge groups with gas cost $q = b_{\text{base}} + \ell \cdot N_{\text{outcomes}}$,
each group is a separate SplitMergeEdge with its own $q_i$.

### Directional Edge Splitting (Future Optimization)

The current conservative proxy assigns each AMM edge
`max(buy_swap_cost, sell_swap_cost)`. This over-charges edges that only flow in
one direction. The structural fix:

- Model each AMM as two directed edges sharing reserves but with different gas
  costs: one for buy ($q_{\text{buy}}$), one for sell ($q_{\text{sell}}$).
- This doubles the edge count but each edge has a tight gas cost.
- Phase 2 then prunes each direction independently.

This is a correctness-improving optimization, not a correctness requirement.
The scalar proxy is conservative (may over-prune, never under-prune).

## What Remains Open

1. **Integrality conditions**: No one has identified a structural condition
   that guarantees the relaxation is always tight. Diamandis and Escudero et al.
   both observe empirical tightness but leave the characterization open.

2. **Robust routing under stale reserves**: No formal DRO formulation exists
   for CFMM routing under uncertain/changing reserves. This is a genuine
   research gap at the intersection of robust optimization and DeFi.

3. **Distributed/tatonnement algorithms**: The dual decomposition naturally
   suggests distributed price-update algorithms. Unexplored.

4. **Frank-Wolfe alternative**: The Dubois-Taine & d'Aspremont [4] algorithm
   provides a constructive path from relaxation to near-integral primal via
   approximate Carathéodory representations. Worth benchmarking against the
   two-phase approach for the fixed-fee problem.

## References

[1] T. Diamandis, "Convex Network Flows," PhD Thesis, MIT, 2024.
    See `foresight-docs/phd_thesis.md` for extracted text.
    Chapter 7 (Fixed Edge Fees): §7.1–7.5.

[2] T. Diamandis, G. Angeris, A. Edelman, "Convex Network Flows,"
    arXiv:2404.00765, March 2024.
    See `foresight-docs/2404.00765v2.md` for extracted text.

[3] C. Escudero, F. Lara, M. Sama, "Optimal Routing across Constant Function
    Market Makers with Gas Fees," arXiv:2603.02844, March 2026.
    See `foresight-docs/2603.02844v1.md` for extracted text.

[4] B. Dubois-Taine, A. d'Aspremont, "Frank-Wolfe meets Shapley-Folkman:
    a systematic approach for solving nonconvex separable problems with linear
    constraints," Mathematical Programming, 2025. arXiv:2406.18282.

[5] M. Schlegel et al., "Hermes: Scalable and Robust Structure-Aware Optimal
    Routing for DEXes," IEEE International Conference on Blockchain, 2025.
    HAL hal-05320618.

[6] T. Diamandis, K. Dong, Y. Sidford, "GeNIOS: an (almost) free
    lunch for solving large-scale operator splitting problems,"
    Mathematical Programming Computation, January 2026. arXiv:2310.08333.

[7] T. Diamandis, G. Angeris, "The Convex Geometry of Network Flows,"
    arXiv:2408.12761, August 2024.

[8] E. Baude et al., "Optimal Execution on Uniswap v2/v3 under Transient
    Price Impact," arXiv:2601.03799, January 2026.
