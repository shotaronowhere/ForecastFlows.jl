


# Notes on Prediction Market Trade Routing via Convex Network Flows

**To:** Incoming Graduate Student  
**From:** Graduate Senior Student
**Date:** March 10, 2026  
**Subject:** Formulation and Implementation of Prediction Market Routing  

It is a general principle in mathematical optimization that complex, globally coupled systems can often be elegantly decoupled by passing to the dual space. The prediction market order routing problem you are investigating is a beautiful realization of this principle. 

In a prediction market, a user can trade collateral (e.g., USDC) for specific outcome tokens (e.g., YES or NO) via independent Automated Market Makers (AMMs). However, they also have access to structural **split (mint)** and **merge (redeem)** operations, where 1 unit of collateral can be converted into 1 unit of *every* outcome token, and vice versa. This allows for sophisticated synthetic routing: for example, to buy a large amount of YES, one might directly buy YES from the YES/USDC AMM, but one might simultaneously *mint* YES + NO using USDC, and then sell the NO tokens back to the NO/USDC AMM. 

Instead of writing brittle, combinatorial path-finding heuristics to discover these routes, we can embed the entire structure into the continuous **Convex Network Flow** formalism developed by Diamandis, Angeris, and Edelman. It is a pleasant exercise to see that the hypergraph structure natively supports the mint/merge mechanism, and the dual decomposition algorithm naturally finds the optimal synthetic routes.

Below is a concise guide to the mathematical formulation and your roadmap for implementation.

---

### 1. Mathematical Formulation

Let us define the universe of $N+1$ assets. Let index $0$ represent the Collateral token ($C$), and indices $1, \dots, N$ represent the $N$ mutually exclusive outcome tokens ($O_1, \dots, O_N$).

We model the network as a hypergraph where nodes are assets and edges are trading venues. We represent a trade executed through an edge $k$ as a vector $x_k$, where positive components denote assets received and negative components denote assets tendered.

**The AMM Edges:**
For each outcome $i \in \{1, \dots, N\}$, there typically exists an independent AMM trading $C$ against $O_i$. This is a standard 2-node edge. The allowable flow set $T_i \subset \mathbb{R}^2$ is bounded and downward-closed, defined by the AMM's constant function $\varphi_i$:
$$ T_i = \left\{ (\Delta_C, \Delta_{O_i}) \in \mathbb{R}^2 \;\bigg|\; \varphi_i(R - \gamma \Delta^- - \Delta^+) \ge \varphi_i(R) \right\} $$

**The Split/Merge Hyperedge:**
The structural mint/merge operation connects the collateral node $0$ to *all* outcome nodes $1, \dots, N$ simultaneously. 
* **Minting** $w > 0$ units means tendering $-w$ collateral and receiving $+w$ of each outcome.
* **Merging** $w < 0$ units means tendering $+w$ (i.e., giving up $-w$) of each outcome and receiving $-w$ collateral.

We define the allowable flow set for this hyperedge, bounded by some practical transaction size limit $B$, and downward closed (to satisfy the general framework):
$$ T_{sm} = \left\{ z \in \mathbb{R}^{N+1} \;\bigg|\; \exists w \in[-B, B] \text{ s.t. } z_0 \le -w, \text{ and } z_i \le w \text{ for } i=1, \dots, N \right\} $$

**The Global Problem:**
Given a concave, non-decreasing utility function $U(y)$ reflecting the user's ultimate desired net trade $y = \sum A_k x_k$ (for instance, maximizing $O_1$ received while tendering at most $D$ collateral), the optimal routing problem is:
$$
\begin{aligned}
\max_{y, x} \quad & U(y) \\
\text{s.t.} \quad & y = \sum_{i=1}^N A_i x_i + A_{sm} x_{sm} \\
& x_i \in T_i \quad \forall i \in \{1, \dots, N\} \\
& x_{sm} \in T_{sm}
\end{aligned}
$$

### 2. Dual Decomposition and Shadow Prices

Because the only coupling between these markets is the net flow constraint, we pass to the dual problem using Lagrange multipliers $\nu \in \mathbb{R}^{N+1}$, which we intuitively interpret as the shadow prices of the assets. 

The dual problem minimizes a dual function $g(\nu)$ that separates beautifully across the edges:
$$ g(\nu) = \bar{U}(\nu) + \sum_{i=1}^N f_i(A_i^T \nu) + f_{sm}(A_{sm}^T \nu) $$

To evaluate $g(\nu)$ and its gradient, you merely need to solve an independent **arbitrage subproblem** for each edge.

**AMM Arbitrage Subproblem ($f_i$):**
For a local price vector $\eta_i = (\nu_0, \nu_i)$, we maximize $\eta_i^T x_i$ over $x_i \in T_i$. This is the standard 1D convex root-finding problem detailed in the Diamandis thesis (e.g., Section 5.1).

**Split/Merge Arbitrage Subproblem ($f_{sm}$):**
This is where the structure shines. For the hyperedge, we are given the full price vector $\eta = (\nu_0, \nu_1, \dots, \nu_N)$. We must evaluate:
$$ f_{sm}(\eta) = \max_{x \in T_{sm}} \eta^T x $$
Because $\eta \ge 0$ (prices are non-negative), the downward closure implies the maximum occurs on the boundary $x = (-w, w, \dots, w)$. Thus, the problem reduces to a trivial linear program over a scalar $w \in [-B, B]$:
$$ \max_{w \in [-B, B]} \quad w \left( \sum_{i=1}^N \nu_i - \nu_0 \right) $$

The solution is immediate:
* If $\sum \nu_i > \nu_0$, then $w^* = B$ (The sum of the parts is greater than the whole; the algorithm exploits this by **minting**).
* If $\sum \nu_i < \nu_0$, then $w^* = -B$ (The whole is greater than the sum of the parts; the algorithm exploits this by **merging**).
* If $\sum \nu_i = \nu_0$, then $w^* = 0$ (Structural no-arbitrage is satisfied).

Notice what happens here: *you do not need to write logic to determine whether a complex synthetic route is profitable*. The L-BFGS-B optimization over $\nu$ will automatically shift the prices. If a synthetic route is optimal, the shadow price $\nu_0$ will temporarily diverge from $\sum \nu_i$, triggering the $f_{sm}$ subproblem to mint or merge, which in turn pushes gradients back to adjust the AMM trades until global equilibrium is reached.

### 3. Implementation Roadmap

I suggest you begin by extending the `ConvexFlows.jl` or `CFMMRouter.jl` packages to support this hyperedge. 

**Step 1: Fork and Setup**
Clone https://github.com/tjdiamandis/ConvexFlows.jl. Currently, their high-level interface (`Edge` struct) assumes two-node edges. You will need to drop down to the lower-level interface or define a custom hyperedge type.

**Step 2: Define the Mint/Merge Market**
If you prefer starting with `CFMMRouter.jl` (which natively handles multi-asset networks), you can define a custom `Market` struct.

```julia
struct SplitMergeMarket <: Market
    bounds::Float64 # B
end

# Implement the arbitrage oracle required by the solver
function find_arb!(Δ::Vector{Float64}, Λ::Vector{Float64}, mkt::SplitMergeMarket, ν::Vector{Float64})
    # ν is [ν_C, ν_O1, ν_O2, ..., ν_ON]
    profit_gradient = sum(ν[2:end]) - ν[1]
    
    fill!(Δ, 0.0)
    fill!(Λ, 0.0)
    
    if profit_gradient > 1e-8 # Minting is profitable
        Δ[1] = mkt.bounds             # Tender Collateral
        Λ[2:end] .= mkt.bounds        # Receive Outcomes
    elseif profit_gradient < -1e-8 # Merging is profitable
        Δ[2:end] .= mkt.bounds        # Tender Outcomes
        Λ[1] = mkt.bounds             # Receive Collateral
    end
    return nothing
end
```

**Step 3: Graph Construction**
Instantiate your AMMs as standard `ProductTwoCoin` or `GeometricMeanTwoCoin` markets between Node 0 and Node $i$. Add exactly one `SplitMergeMarket` bridging Node 0 and Nodes $1 \dots N$. 

**Step 4: Objective Function**
Define your $U(y)$. If you are looking to maximize $O_1$ obtained for a fixed input of $C$, use a standard `BasketLiquidation` objective. The L-BFGS-B solver will query your `find_arb!` methods, seamlessly distributing the flow across direct swaps and synthetic mint/merge loops.

Take some time to digest the geometry described in Chapter 2 of the thesis. The elegance of reducing complex financial mechanisms to convex sets and shadow prices is a powerful tool you will use repeatedly in your career.

Best of luck with the implementation. Let me know when you have the initial test cases running.