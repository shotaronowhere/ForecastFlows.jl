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

These fixtures provide only benchmark state and expected-value reference data.
They do not supply the optimization logic used by `ForecastFlows`.

## CFMMRouter

- upstream: `https://github.com/bcc-research/CFMMRouter.jl`
- pinned commit previously referenced during development:
  `5932e42e5077ffc7d8e02c3b3ad2e9ed1d441267`

No CFMMRouter source files are vendored into the public package. The current
tests use local reference formulas instead of including the submodule.
