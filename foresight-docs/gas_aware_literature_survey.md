# Gas-Aware DEX Routing: Literature Survey (as of March 2026)

This survey covers the state of the art on the open problems identified in
Diamandis's PhD thesis "Convex Network Flows" (MIT, 2024), with focus on
fixed-fee convex flows, gas-aware routing, stale-price robustness, and
distributed algorithms.

## 1. Fixed Edge Fees: Integrality of Relaxations

**Status: Partially addressed. Core "why tight?" question remains open.**

Diamandis [1, Chapter 7] proved the fixed-fee convex flow problem is NP-hard
and derived a convex relaxation with Shapley-Folkman integrality gap
$(n+1) \max_i q_i$. He observed empirically that solutions are often integral
but left the characterization of when this holds as an open question.

### Key developments

- **Diamandis & Angeris (2024)** [7] formalized the Shapley-Folkman rounding
  scheme in "The Convex Geometry of Network Flows" but did not identify
  structural conditions for exact integrality.

- **Escudero, Lara & Sama (March 2026)** [3] provided the first rigorous
  primal-space KKT characterization of gas-aware CFMM routing. Their Remark
  3.3(i) shows that under their constraint qualification, active markets with
  positive gas generically have *fractional* activations $\bar{\eta}_i < 1$ in
  the relaxation — the relaxation is **not** tight in general. Their Theorem
  3.4 gives a tighter approximation bound:
  $$\varepsilon(q, \bar{\eta}) = q_{\max}(\|\bar{\eta}\|_0 - \|\bar{\eta}\|_1) + (q_{\max} - q_{\min})\|\bar{\eta}\|_1$$

- **Dubois-Taine & d'Aspremont (Math. Programming, 2025)** [4] developed a
  Frank-Wolfe + Shapley-Folkman two-stage algorithm for nonconvex separable
  problems. Stage 1 uses Frank-Wolfe to approximate the dual optimum; Stage 2
  trims via approximate Carathéodory representations. Provides a constructive
  path from relaxation to near-integral primal, but does not identify
  integrality conditions. Julia implementation: github.com/bpauld/NonConvexOpt.

**Open gap**: No analogue of total unimodularity or network matrix structure has
been found that guarantees exact integrality for fixed-fee convex flows.

## 2. Optimal Algorithms for the Fixed-Fee Problem

**Status: Incremental progress. No head-to-head comparison.**

- **Diamandis thesis §7.5**: Proposed applying the same L-BFGS-B dual
  decomposition with edge support function $\max(f_i(\eta_i) - q_i, 0)$. This
  introduces nonsmoothness that L-BFGS-B handles poorly (see
  `gas_aware_solver.md` for failure analysis).

- **GeNIOS (Diamandis, Dong & Sidford, Math. Prog. Comp., January 2026)** [6]:
  Generalized Newton inexact operator-splitting solver, up to 10x faster than
  ADMM on large dense problems. Applicable as the inner smooth solver for the
  two-phase approach. Julia: github.com/tjdiamandis/GeNIOS.jl.

- **Frank-Wolfe + Shapley-Folkman** [4]: Legitimate alternative to L-BFGS-B +
  rounding for the nonconvex outer problem.

**No paper benchmarks** these strategies against each other on fixed-fee convex
flow instances.

## 3. Stale Prices and Robust Routing

**Status: Significant empirical work. No formal robust optimization treatment.**

No distributionally robust optimization (DRO) formulation exists for CFMM
routing under uncertain/changing reserves. This is a genuine research gap.

### Closest work

- **Baude et al. (January 2026)** [8]: "Optimal Execution on Uniswap v2/v3
  under Transient Price Impact." Closed-form optimal liquidation strategies
  under instantaneous + transient impact. Closest to rigorous execution under
  changing conditions, but models *price impact*, not *reserve uncertainty*.

- **"Execution Welfare Across Solver-based DEXes" (March 2025)**,
  arXiv:2503.00738: Empirically shows solver-based DEXes (CoWSwap, 1inch
  Fusion, UniswapX) improve execution by 4–5 bps on average vs vanilla AMM
  routing.

- **Bachu, Wan & Moallemi (2024)** "Quantifying Price Improvement in Order
  Flow Auctions," arXiv:2405.00537: Rigorous empirical framework attributing
  price improvement to routing efficiency, gas optimization, and priority fees.

- **"A Dynamic Equilibrium Model for AMMs" (March 2026)**, arXiv:2603.08603:
  Strategic interaction between arbitrageurs and LPs over time, incorporating
  slippage in closed form.

**Open opportunity**: A DRO formulation — "optimize routing assuming reserves
lie in a Wasserstein ball around observed values" — has not been published.

## 4. Gas-Aware DEX Routing (Joint Routing + Gas)

**Status: Active applied research. Limited mathematical rigor.**

- **Escudero, Lara & Sama (March 2026)** [3]: The strongest theoretical
  treatment. Mixed-integer formulation with binary activations, continuous
  relaxation, KKT necessary/sufficient conditions under generalized convexity,
  and explicit approximation bounds. Limitations: only 2-node CFMM edges (no
  hyperedges), small numerical examples (1–5 markets), uses SciPy.

- **Hermes (IEEE Blockchain'25, October 2025)** [5]: Exploits **treewidth** of
  DEX liquidity graphs for parameterized routing. 4 orders of magnitude faster
  than convex methods (0.0002s vs 2.81s) with formal quality guarantees. Most
  promising alternative paradigm — real DEX graphs have low treewidth.

- **Marfinetz (October 2025)** "Hybrid GA for Optimal User Order Routing,"
  arXiv:2510.21647: Multi-objective NSGA-II solver for CoW Protocol batch
  auctions, jointly optimizing surplus, gas, slippage, risk. Converges in
  ~0.5s within a 2s auction deadline.

- **"Measuring DEX Efficiency" (May 2025)**, arXiv:2508.03217: Introduces STAP
  (Standardized Total Arbitrage Profit) metric. Notes that convex-optimization
  routing has "extremely high computational complexity" and results are "almost
  impossible to execute."

- **"Fair Combinatorial Auction for Blockchain Trade Intents" (Canidio &
  Henneke, August 2024)**, arXiv:2408.12225: Formalizes fairness in
  combinatorial batch auctions for trade intents.

- **1inch Pathfinder v5.6 (2025)**: Production system with gas-optimized
  calldata, ~20–30% gas refunds, transaction batching. No academic paper.

**No convex-optimization-native gas model** has been published beyond the
Diamandis and Escudero et al. relaxation approaches.

## 5. Distributed / Tatonnement Algorithms

**Status: Essentially untouched.**

The thesis's dual decomposition naturally suggests distributed price-update
algorithms where edge subproblems are solved by different agents. No published
work exploits this structure.

Tangential:
- **"A Coincidence of Wants Mechanism for Swap Trade Execution" (Nag et al.,
  July 2025)**, arXiv:2507.10149: Decentralized CoW cycle discovery via asset
  matrix formulation. Operates in a distributed spirit but does not use dual
  decomposition.

## 6. Additional Relevant Work

- **Chitra, Kulkarni & Srinivasan (2025)** "Optimal Routing in the Presence of
  Hooks," arXiv:2502.02059: Extends CFMM routing to Uniswap v4 hooks — custom
  logic that modifies pool behavior pre/post-swap.

- **"Market Clearing with Semi-fungible Assets" (Diamandis, May 2025)**,
  arXiv:2505.19298: Combinatorial market clearing relevant to prediction-market
  structures.

- **"Perpetual Demand Lending Pools" (Diamandis, February 2025)**,
  arXiv:2502.06028: DeFi lending pool mechanisms.

- **"Multidimensional Blockchain Fees are (Essentially) Optimal" (Diamandis,
  AFT 2025)**, arXiv:2402.08661: Fee mechanism design for blockchains.

## Summary Table

| Open Problem | Status | Key Gap |
|---|---|---|
| Integrality of fixed-fee solutions | Partial: SF bounds + FW algorithm | No structural condition identified |
| Optimal fixed-fee algorithm | Incremental: GeNIOS, FW+SF | No head-to-head comparison |
| Robust routing (stale prices) | Empirical work only | Clean DRO formulation missing |
| Gas-aware routing | Escudero KKT + Hermes treewidth | No convex-native gas model at scale |
| Distributed algorithms | Wide open | Untouched |

## Implications for ForecastFlows

1. Our **two-phase warm-started method** (smooth solve → active-set pruning →
   re-solve) is at the frontier of what's published. Escudero et al. [3]
   validate the relaxation approach with provable bounds.

2. The **Frank-Wolfe + Shapley-Folkman** algorithm [4] is worth benchmarking as
   an alternative to the two-phase approach.

3. **Hyperedge gas handling** (SplitMergeEdge) is outside all published
   frameworks. This is our contribution.

4. **Directional edge splitting** for direction-dependent gas is not discussed
   in the literature but follows naturally from the activation variable
   formulation.

5. **Robust routing under stale reserves** is a genuine research opportunity.

## GitHub Activity

- **ConvexFlows.jl** (github.com/tjdiamandis/ConvexFlows.jl): Limited activity
  since mid-2024. Last documentation build July 2024.
- **CFMMRouter.jl** (github.com/bcc-research/CFMMRouter.jl): Low activity.
  Multiple forks suggest community interest.
- **GeNIOS.jl** (github.com/tjdiamandis/GeNIOS.jl): Diamandis's most actively
  maintained solver.
- **NonConvexOpt** (github.com/bpauld/NonConvexOpt): FW+SF implementation.

## Diamandis Recent Publications (2024–2026)

| Paper | Date | Venue |
|---|---|---|
| Convex Network Flows [2] | Apr 2024 | arXiv |
| Convex Geometry of Network Flows [7] | Aug 2024 | arXiv |
| Multidimensional Blockchain Fees | AFT 2025 | arXiv:2402.08661 |
| Perpetual Demand Lending Pools | Feb 2025 | arXiv:2502.06028 |
| Market Clearing with Semi-fungible Assets | May 2025 | arXiv:2505.19298 |
| GeNIOS [6] | Jan 2026 | Math. Prog. Comp. |

Diamandis is now at Gridmatic (energy optimization). Angeris is at Bain Capital
Crypto.

## References

[1] T. Diamandis, "Convex Network Flows," PhD Thesis, MIT, 2024.
    See `foresight-docs/phd_thesis.md`.

[2] T. Diamandis, G. Angeris, A. Edelman, "Convex Network Flows,"
    arXiv:2404.00765, March 2024.
    See `foresight-docs/2404.00765v2.md`.

[3] C. Escudero, F. Lara, M. Sama, "Optimal Routing across Constant Function
    Market Makers with Gas Fees," arXiv:2603.02844, March 2026.
    See `foresight-docs/2603.02844v1.md`.

[4] B. Dubois-Taine, A. d'Aspremont, "Frank-Wolfe meets Shapley-Folkman,"
    Mathematical Programming, 2025. arXiv:2406.18282.

[5] M. Schlegel et al., "Hermes: Scalable and Robust Structure-Aware Optimal
    Routing for DEXes," IEEE Blockchain'25. HAL hal-05320618.

[6] T. Diamandis, K. Dong, Y. Sidford, "GeNIOS," Mathematical Programming
    Computation, January 2026. arXiv:2310.08333.

[7] T. Diamandis, G. Angeris, "The Convex Geometry of Network Flows,"
    arXiv:2408.12761, August 2024.

[8] E. Baude et al., "Optimal Execution on Uniswap v2/v3 under Transient
    Price Impact," arXiv:2601.03799, January 2026.
