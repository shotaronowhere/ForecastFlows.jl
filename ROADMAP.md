# Post-v1 Roadmap

This file tracks the major items that remain after the v1 dependency release.

## Solver Research

- Generalize zero-face primal recovery beyond a single `SplitMergeEdge`
- Improve nonsmooth scaling and large-instance performance
- Explore limited-memory or Chapter 7 style fixed-fee variants where useful

## Execution Realism

- Add a shared execution-cost model that matches the production driver exactly
- Add transaction packing and block-level gas budgeting
- Add reserve freshness and robust-routing safeguards

## Benchmarking

- Add shared net-EV fixtures against the external production solver
- Extend the benchmark harness beyond the current single-tick Deep-Trading adapter
- Tighten benchmark gating once the opt-in runs are stable in CI

## Productization

- Evaluate embedded Julia or FFI only if worker IPC becomes the bottleneck
- Expand the facade beyond the current one-collateral / one-market-per-outcome scope
- Add a reference driver integration and production monitoring examples
