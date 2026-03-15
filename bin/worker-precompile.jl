using ForecastFlows
using JSON3

problem = PredictionMarketProblem(
    [
        OutcomeSpec("1", 0.55, 0.0),
        OutcomeSpec("2", 0.45, 0.0),
    ],
    1.0,
    [
        ConstantProductMarketSpec("m1", "1", 100.0, 70.0, 0.997),
        ConstantProductMarketSpec("m2", "2", 100.0, 55.0, 0.997),
    ],
)

solve_prediction_market(problem; mode=:direct_only, certify=true, throw_on_fail=false, solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000))
compare_prediction_market_families(problem; certify=true, throw_on_fail=false, solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000))

uni_problem = PredictionMarketProblem(
    [
        OutcomeSpec("1", 0.2, 1.0),
        OutcomeSpec("2", 0.35, 0.0),
    ],
    0.0,
    [
        UniV3MarketSpec("u1", "1", 0.5, [UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.5, 12.0), UniV3LiquidityBand(0.25, 9.0)], 0.997),
        UniV3MarketSpec("u2", "2", 0.5, [UniV3LiquidityBand(1.0, 9.0), UniV3LiquidityBand(0.5, 11.0), UniV3LiquidityBand(0.25, 8.0)], 0.997),
    ],
)
solve_prediction_market(uni_problem; mode=:direct_only, certify=true, throw_on_fail=false, solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000))
solve_prediction_market(problem; mode=:mixed_enabled, certify=true, throw_on_fail=false, max_doublings=0, solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000))

JSON3.write(problem)
