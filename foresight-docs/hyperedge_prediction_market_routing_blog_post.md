# Prediction Markets Need Hyperedges, Not Just Paths

Most onchain routing problems are described as pathfinding problems.

This is a good mental model for ordinary DEX routing. You have tokens as nodes, pools as edges, and you search for a good path from what you have to what you want. Even when the optimization is continuous under the hood, the picture is still basically graph-like.

Prediction markets quietly break this picture.

In a prediction market with mutually exclusive outcomes, there is usually a structural operation that is not a normal swap: you can mint a complete set, turning 1 unit of collateral into 1 unit of every outcome token, or merge a complete set back into collateral. In a binary market, this is the familiar operation "1 USDC becomes 1 YES + 1 NO", and the reverse. In an N-outcome market, it becomes "1 collateral becomes one share of every outcome".

That operation is not a pairwise edge. It touches every outcome token at once. So if we force ourselves to think only in terms of paths through a graph, we immediately start losing the shape of the problem.

The `forecast` branch of `ForecastFlows.jl` takes the more natural approach: it models prediction-market routing as a convex flow problem on a hypergraph, where the complete-set mint/merge mechanism is a real hyperedge. Once you do that, a lot of the complexity disappears. The structural venue stops being a special-case heuristic and becomes just another edge oracle in the dual decomposition.

This post explains what that means, why it is the right abstraction, and what the implementation in this branch is actually doing.

## The routing problem, from first principles

Suppose we have:

- one collateral asset, like USDC
- `N` mutually exclusive outcome tokens
- zero or more AMMs for each outcome against collateral
- one fee-free mint/merge mechanism for complete sets

We also have a portfolio: some collateral, maybe some existing outcome holdings, and a set of "fair values" for the outcomes. The routing problem is to find the best set of trades, across all venues, that improves the portfolio according to those fair values without spending assets we do not have.

The key thing to notice is that there are two qualitatively different ways to get an outcome token:

1. Buy it directly from an AMM.
2. Mint a full basket of all outcomes, then sell the unwanted ones.

Likewise, there are two ways to sell an outcome:

1. Sell it directly into an AMM.
2. Buy the missing outcomes, assemble a complete set, and merge.

This is why naive route enumeration becomes awkward. A "route" is no longer just a sequence of pairwise swaps. It can include a basket transformation that changes several assets simultaneously.

In the branch, this shows up in the model exactly as you would hope:

- node `1` is collateral
- nodes `2:(N+1)` are the outcome tokens
- each direct market is a two-node edge
- the complete-set venue is one `SplitMergeEdge` with local ordering `[collateral, outcomes...]`

That is the entire topology.

## Why a hyperedge is the correct abstraction

The thesis and paper make an important modeling move: an "edge" is not defined by a formula like `x*y=k`. An edge is defined by an allowable flow set `T_i`.

That is a much more general and more useful abstraction.

For an AMM, the allowable set is the set of all token baskets the pool will accept at the current state. For a prediction-market mint/merge mechanism, the allowable set is the set of baskets consistent with "one collateral turns into one of each outcome", or the reverse.

This point matters because the complete-set operation is not a hack on top of routing. It is itself a venue with a clean trading set.

There is also a subtle convex-analysis detail here that ends up being very practical: the trading set is taken to be downward closed. Informally, that means if a venue is willing to accept some trade, it is also willing to accept a trade where you give it more and ask for less. That sounds strange at first, but it is exactly the right formalization for "overpaying is allowed". It is also what makes the dual "arbitrage" subproblem become a support-function computation.

For the split/merge venue, the ideal exact exchange is the one-dimensional face

```math
(-w, w, w, \dots, w), \qquad w \in [-B, B],
```

where:

- `w > 0` means minting
- `w < 0` means merging
- `B` is a practical trade-size bound

The downward-closed allowable set is then

```math
T_{sm} = \left\{x \in \mathbb{R}^{N+1} \mid \exists w \in [-B,B] \text{ such that } x_0 \le -w,\; x_i \le w \text{ for } i=1,\dots,N \right\}.
```

This is the mathematically correct hyperedge object for the fee-free complete-set venue.

And importantly, because the solver's dual prices are nonnegative, the maximum value over this downward-closed set always occurs on the exact face `(-w, w, ..., w)`. So the "formal convex set" and the "intuitive mint/merge mechanism" agree at the optimum.

## The core idea: solve routing by finding prices

The nicest part of the convex-flow framework is that it shifts the global routing problem into the dual.

Instead of directly searching over all edge flows at once, the solver searches for a vector of shadow prices `ν`, one per asset. You can think of `ν` as the internal exchange rates that would make the whole network locally content.

Once you have candidate prices, each venue solves its own tiny local problem:

"At these prices, what trade would be most valuable for me to perform?"

This is the arbitrage subproblem from the paper. In the zero-edge-utility regime, which is exactly the regime used by the prediction-market router in this branch, the dual simplifies to

```math
g(\nu) = \bar U(\nu) + \sum_i f_i(A_i^T \nu),
```

where:

- `\bar U` comes from the portfolio objective
- each `f_i` is the support function of edge `i`'s allowable flow set
- `A_i^T \nu` is just the global price vector restricted to the assets that edge touches

This is a very powerful decomposition.

Each AMM only needs to answer a local arbitrage question against its own two prices. The split/merge venue only needs to answer a local arbitrage question against the price of collateral and the prices of the outcome tokens. The global optimizer then adjusts `ν` until the combination of all those local responses becomes globally consistent.

This is one of those ideas that feels almost too simple after you see it. The global route emerges from local profit maximization under the right shadow prices.

## The split/merge oracle is almost embarrassingly simple

For the complete-set hyperedge, the arbitrage subproblem is

```math
f_{sm}(\eta) = \max_{x \in T_{sm}} \eta^T x,
```

where `\eta = (\nu_0, \nu_1, \dots, \nu_N)` is the local shadow-price vector on:

- collateral
- outcome 1
- outcome 2
- ...
- outcome `N`

Because the optimum lies on the exact mint/merge face, we can write `x = (-w, w, \dots, w)` and reduce the whole thing to

```math
\max_{w \in [-B, B]} \; w \left(\sum_{i=1}^N \nu_i - \nu_0\right).
```

That is just a one-dimensional linear program.

So the answer is immediate:

- if `\sum_i \nu_i > \nu_0`, mint at full bound `w = B`
- if `\sum_i \nu_i < \nu_0`, merge at full bound `w = -B`
- if `\sum_i \nu_i = \nu_0`, anything on the interval is optimal

In words:

- if the shadow value of the parts exceeds the shadow value of the whole, create the parts
- if the whole is worth more than the parts, collapse the parts back into the whole
- if they are equal, the structure is internally priced correctly

This is exactly the behavior you want.

In a binary market, this is the familiar intuition that if YES plus NO is effectively worth more than 1 collateral unit, you should mint the pair; if YES plus NO is worth less than 1, you should buy both and merge.

The implementation in [`src/prediction_markets.jl`](/Users/shotaro/proj/ForecastFlows.jl/src/prediction_markets.jl#L180) really is this direct. It computes

```julia
splitmerge_gap(η) = sum(η[2:end]) - η[1]
```

and then:

- returns `[-B, B, ..., B]` if the gap is positive
- returns `[B, -B, ..., -B]` if the gap is negative
- returns zero if the gap is within tolerance

That is not a heuristic. It is the exact solution of the hyperedge's dual arbitrage subproblem.

## What the forecast branch actually adds

There is a tendency, especially in DeFi, to talk about "adding support for X" as if it means writing some routing if-statements. What is nice here is that the change is much cleaner than that.

The branch does not bolt prediction-market logic onto a swap router. It adds a new market geometry to a generic convex-flow solver:

- `SplitMergeEdge` is a first-class edge type
- the generic solver already knows how to ask every edge for its best trade via `find_arb!`
- the prediction-market API builds a network with direct AMM edges plus one split/merge hyperedge
- the public result type returns both direct trades and aggregate `mint` / `merge` amounts

So the extension is surgical in exactly the right way. The new idea lives at the edge level, not as a separate planner beside the solver.

The branch also supports both constant-product and `UniV3`-style direct markets, multiple direct venues for one outcome, and even missing direct venues for some outcomes. That last point is important: once the complete-set venue is part of the optimization graph, you can synthesize exposure to an outcome even if the direct pool for that outcome is thin or absent, as long as the rest of the network makes the trade worthwhile.

From the public API perspective, there are two route families:

- `direct_only`: only the AMMs
- `mixed_enabled`: the AMMs plus the split/merge hyperedge

That is a very clean way to compare "ordinary DEX routing" against "DEX routing plus structural prediction-market routing".

There is also a nice numerical detail around the bound `B`. In theory, the complete-set mechanism is structural, so it is tempting to model it as unbounded. In practice, the branch keeps it bounded for certification and numerical stability. If the caller does not specify `split_bound`, the API seeds it from `collateral_balance + sum(initial_holding)` and then automatically doubles it if a mixed solve is still leaning too hard on that cap. If the bound remains near-active after the allowed doublings, the solve fails closed instead of quietly pretending the clipped route is trustworthy.

## Why the recovery step matters

There is one subtlety that is easy to miss if you only look at the mint/merge oracle.

The split/merge edge is nonsmooth. At the knife-edge case

```math
\sum_{i=1}^N \nu_i = \nu_0,
```

the best trade is not unique. Any `w` in the feasible interval is optimal for the hyperedge subproblem.

This is not a bug. It is exactly what the theory predicts for a flat face of the allowable set. But it does mean that, after the dual optimizer converges, you still need to choose a particular feasible point on that face so that the recovered primal flows line up with the target portfolio flows.

The branch handles this explicitly.

The split/merge edge is marked nonsmooth, and there is a specialized recovery routine, [`recover_splitmerge_flow!`](/Users/shotaro/proj/ForecastFlows.jl/src/prediction_markets.jl#L219), used from the solver's primal-recovery pass in [`src/solver.jl`](/Users/shotaro/proj/ForecastFlows.jl/src/solver.jl#L128). When the gap is clearly positive or negative, recovery just chooses the saturated mint or merge solution. When the gap is approximately zero, it solves the remaining one-dimensional problem: pick the scalar `w` that best matches the residual target while respecting the trade bound and any lower-bound constraints from the portfolio objective.

This is important for two reasons.

First, it turns "a mathematically valid dual optimum" into "an actually usable route decomposition". Second, it makes certification meaningful. The branch does not just hand back a plausible-looking route. It checks target residuals, bound residuals, and the duality gap, and prediction-market solves fail closed by default if certification does not pass.

That is good engineering. A routing solver should be proud of its certificates.

## What behavior the tests confirm

The nice thing about this design is that the expected behaviors are not subtle. The branch's tests check for exactly the cases you would care about:

- a synthetic buy can beat a direct buy
- a synthetic sell can beat a direct sell
- structural overround and underround are detected through minting or merging
- mixed routing can outperform direct-only rebalancing
- the split/merge recovery logic can choose an interior flow when the dual prices are exactly tied

You can see these cases in [`test/edges.jl`](/Users/shotaro/proj/ForecastFlows.jl/test/edges.jl#L214) and [`test/prediction_markets.jl`](/Users/shotaro/proj/ForecastFlows.jl/test/prediction_markets.jl#L1059).

This is exactly the kind of test surface I would want for a feature like this, because it verifies not only that the new edge compiles, but that the router has genuinely learned the prediction-market structure.

## Why this is a better way to think about prediction-market routing

There is a deeper lesson here.

If we think of routing as path search, then the complete-set mechanism feels like a weird special case. If we think of routing as convex flow over trading sets, then the complete-set mechanism is almost boring. It is just another venue whose local arbitrage problem happens to have an especially nice closed form.

That shift in viewpoint matters.

It means:

- the solver does not need bespoke logic for "synthetic YES through mint and dump NO"
- direct pools and structural mint/merge are optimized in one unified objective
- the model scales naturally from binary markets to many outcomes
- the same decomposition idea works whether the direct venues are constant-product pools or concentrated-liquidity pools

And it gives a nice game-theoretic intuition too. Each venue is responding to the same vector of shadow prices. The global route is the fixed point where all of those local responses fit together into one consistent portfolio transformation.

That is exactly the kind of abstraction that tends to survive contact with reality.

## A note on scope

The branch is solving the routing problem, not the full execution problem.

It produces certified route plans: signed direct AMM trades, aggregate mint and merge amounts, final holdings, and certification metadata. Gas pricing, transaction construction, calldata packing, simulations, chain interaction, and safety policy still belong to the downstream driver.

That separation of concerns is the right one. The solver should be responsible for being mathematically honest about the optimization problem it solves, and the executor should be responsible for the messy real-world details of getting trades onto a chain safely.

## Closing thought

One of the recurring patterns in mechanism design and crypto is that a lot of things look combinatorial until you find the right convex object. Then the discrete-seeming complexity turns out to be a shadow cast by a much simpler geometry.

Prediction-market routing has this flavor.

The difficult part is not writing a longer list of route templates. The difficult part is using an abstraction that can express, in one language, both ordinary swaps and complete-set transformations. Hypergraphs do that. Convex-flow dual decomposition does that. And once those pieces are in place, the split/merge venue collapses to a one-line economic test:

"Are the parts worth more than the whole, or less?"

That is a very satisfying place to end up.
