# Changelog

## v1.0.0 - 2026-03-11

- Freeze the supported dependency surface to the Julia prediction-market facade plus the JSON worker protocol.
- Add the first dependency-oriented worker contract hardening pass:
  - strict request parsing
  - stable `invalid_request` / `solve_failed` / `internal_error` error codes
  - explicit serial worker execution model
  - preferred `UniV3LiquidityBand(lower_price, liquidity_L)` liquidity shape
- Add the Deep-Trading net-EV benchmark sweep as a release benchmark under the aligned single-tick replay model.
- Add release tooling:
  - `bin/worker-smoke.jl`
  - `bin/release-check.jl`
  - platform-correct sysimage helper output under `build/`
- Fix the L-BFGS-B workspace sizing so larger `memory` settings do not exceed the preallocated solver buffers.
- Add docs toolchain compat bounds for the v1 release environment.
- Keep v1 scoped to solver dependency use only. Gas modeling, tx construction, packing, submission, and chain interaction remain driver responsibilities.
- Do not treat the benchmark as proof of exact on-chain net EV or blanket solver-vs-solver dominance; it is a pinned regression benchmark under the documented surrogate execution model.
