# Complete-Set Arbitrage: Understanding the Native vs Convex Solver Gap

Date: 2026-03-17

## Discovery

The native waterfall achieves 132.03 sUSD EV from 6.5 sUSD capital on the
18-outcome pathological fixture. The ForecastFlows convex solver achieves
127.63 sUSD. The gap (4.4 sUSD) is now understood.

## The Complete-Set Arbitrage Mechanism

When AMM prices sum to < 1.0, a risk-free arbitrage exists:

1. **Buy** 1 token of each of N outcomes through AMMs (total cost ≈ sum of prices < 1)
2. **Merge** the complete set → receive 1 sUSD
3. **Profit** = 1 - total_buy_cost > 0

In the pathological fixture:
- Initial price sum = 0.6418
- Arb gap = 1.0 - 0.6418 = 0.3582 per set (before slippage)
- The arb continues until prices sum to ~1.0

### Cash amplification

Starting with 6.5 sUSD:
- Arb phase extracts **35.2 sUSD** profit (prices pushed from sum=0.64 to sum=1.0)
- Cash grows from 6.5 to **41.7 sUSD**
- The amplified cash is then deployed via the waterfall into profitable outcomes

### Julia simulation results

| Strategy | EV (sUSD) |
|----------|-----------|
| Direct-only (no arb) | 20.53 |
| Arb + direct deploy | 127.63 |
| Native waterfall | 132.03 |
| ForecastFlows solver (B=169) | 127.63 |

## The Convex Solver Captures the Arb

The ForecastFlows solver at B=169 correctly captures the complete-set arb
through the SplitMergeEdge. The merge flow (w ≈ -160) represents the arb
phase, and the AMM edge flows include both arb-phase buying and deploy-phase
buying. The solver finds the optimal joint solution.

Evidence: Julia simulation with explicit arb + deploy gives 127.63, matching
the convex solver exactly.

## The Remaining 4.4 sUSD Gap

The native achieves 132.03 vs the solver's 127.63. This gap is from
**sequential capital reuse** (Theory 3 from the debug report):

The native waterfall can interleave arb and deploy phases, potentially using
mint routes during deploy (which partially cancel the arb's merge flow,
allowing more gross merge capacity). The convex formulation models the
split/merge as a single bounded flow, which correctly captures the NET flow
but may not capture all benefits of gross flow decomposition.

The dual bound at B=170 proves the convex formulation's theoretical maximum
is 127.66 (= 6.5 + 121.16). Since 127.66 < 132.03, this confirms a genuine
modeling gap between the single-shot convex formulation and the sequential
native approach.

## Implications

1. The ForecastFlows solver is **optimal within its formulation** (127.63 ≈ 127.66 dual bound)
2. The arb is the dominant value driver (35.2 sUSD of the 121.13 total gain)
3. Closing the remaining 4.4 sUSD gap would require multi-stage formulations
   or iterative solve-replay cycles, which is a fundamentally different approach
4. The improvement from 20.53 → 127.63 (107 sUSD, 6.2x) already captures
   97% of the native's improvement (20.53 → 132.03, 111.5 sUSD)
