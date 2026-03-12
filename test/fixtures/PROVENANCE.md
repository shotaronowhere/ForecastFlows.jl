# Fixture Provenance

The benchmark fixtures in this directory were vendored from the following
upstream repositories so the public package can run its tests without git
submodules.

## Deep-Trading

- upstream: `https://github.com/shotaronowhere/Deep-Trading`
- pinned commit: `7511997247cfb372455e99e34c7d6237ce596b0f`
- vendored files:
  - `rebalancer_ab_cases.json`
  - `rebalancer_ab_expected.json`
  - `rebalancer_ab_net_expected.json` (Julia-local derived regression snapshot)

These fixtures provide only benchmark state and expected-value reference data.
They do not supply the optimization logic used by `ForecastFlows`.

`rebalancer_ab_net_expected.json` is not copied from upstream output. It is a
local regression fixture derived from replaying the vendored Deep-Trading cases
in `ForecastFlows` and pricing the resulting grouped execution traces against a
pinned shared snapshot:

- `gas_price_wei = 1_002_325`
- `eth_usd = 3000`
- `l1_fee_per_byte_wei = 1_643_855.3414634147`
- `l1_data_fee_floor_susd = 0`

The grouped gas formulas were aligned to the benchmark semantics documented in
the pinned Deep-Trading sources, primarily:

- `Deep-Trading/src/execution/gas.rs`
- `Deep-Trading/src/portfolio/core/rebalancer.rs`

## CFMMRouter

- upstream: `https://github.com/bcc-research/CFMMRouter.jl`
- pinned commit previously referenced during development:
  `5932e42e5077ffc7d8e02c3b3ad2e9ed1d441267`

No CFMMRouter source files are vendored into the public package. The current
tests use local reference formulas instead of including the submodule.
