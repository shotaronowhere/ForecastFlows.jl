# Mixed Solver Recovery Fix — Results

**Date:** 2026-03-17
**Fix:** `recovery_targets!` for `EndowmentLinear` in `src/objectives.jl:214-226`
**Root cause:** Vacuous recovery targets (all `fixed=false`) → split/merge face recovery produced incorrect flows → certification failure → fallback to direct-only.

## Fix Details

Complementary slackness for U(y)=c'y, y≥-h0 requires y_i=-h0_i when ν_i>c_i. The previous implementation returned vacuous (target=0, fixed=false) for all coordinates. The fix checks each coordinate and pins it when the dual price exceeds the objective coefficient by more than `1000*sqrt(eps)*scale` (matching the tolerance used in `∇Ubar!`).

The tolerance was initially set to `sqrt(eps)*scale` (~1.5e-8) but this caused false pins at degenerate faces where BFGS converges ν_i ≈ c_i + O(pgtol). Widening to `1000*sqrt(eps)*scale` (~1.5e-5) avoids false pins while still capturing genuine pins (where ν_i - c_i >> tolerance).

## Additional Fix

The route extraction "merge" test was asserting buggy behavior — the test data (AMM prices summing to 1.0, no holdings) never produced a genuine merge. Replaced with a configuration where the user holds outcomes to liquidate and AMM prices sum < 1.0, making merge the correct action.

## Julia Test Suite

- All 8085 prediction market tests pass: YES
- `test/prediction_markets.jl:1914` remains "uncertified" (bound saturation, not recovery failure): unchanged
- 61 objective tests pass (3 new assertions added)

## Rust Integration Tests

All 35 `rebalancer_contract_ab` tests passed (23 ignored as expected):
- `forecastflows_pathological_stress_cases_show_material_net_ev_gap_when_enabled`: PASSED
- `forecastflows_real_multiband_fixture_cases_reach_worker_when_enabled`: PASSED
- `analytic_mixed_selection_improves_realistic_heterogeneous_case_net_ev`: PASSED
- `mixed_route_favorable_selection_never_loses_to_direct_only`: PASSED
- `ultimate_solver_mixed_ev_dominates_staged_reference`: PASSED
- `ultimate_solver_mixed_ev_dominates_end_arb_cyclic_hypothesis`: PASSED
