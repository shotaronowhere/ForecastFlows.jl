# Roadmap

This file tracks the major items that remain after the first public
prediction-market router commit.

## Solver Research

- Generalize zero-face primal recovery beyond a single `SplitMergeEdge`
- Improve nonsmooth scaling and large-instance performance
- Explore limited-memory or Chapter 7 style fixed-fee variants where useful

## Execution Realism

- Replace the rough fixed-charge gas proxy with grouped gas accounting
- Add transaction packing and block-level gas budgeting
- Add reserve freshness and robust-routing safeguards

## Benchmarking

- Extend the benchmark harness beyond the single-tick 98-market case
- Add multi-band UniV3 parity checks
- Tighten benchmark gating once the opt-in runs are stable in CI

## Productization

- Build an on-chain execution layer from recovered actions
- Add safety checks, monitoring, and failure reporting
- Separate benchmark-only adapters from production execution code where needed
