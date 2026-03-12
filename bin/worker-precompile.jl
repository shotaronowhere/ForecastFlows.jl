using ForecastFlows
using JSON3

problem = PredictionMarketProblem(
    [0.55, 0.45],
    1.0,
    [0.0, 0.0],
    [
        ConstantProductMarketSpec("m1", 1, 100.0, 70.0, 0.997),
        ConstantProductMarketSpec("m2", 2, 100.0, 55.0, 0.997),
    ],
)

solve_prediction_market(problem; mode=:direct_only, certify=true, throw_on_fail=false)
compare_prediction_market_families(problem; certify=true, throw_on_fail=false)

uni_problem = PredictionMarketProblem(
    [0.2, 0.35],
    0.0,
    [1.0, 0.0],
    [
        UniV3MarketSpec("u1", 1, 0.5, [UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.5, 12.0), UniV3LiquidityBand(0.25, 9.0)], 0.997),
        UniV3MarketSpec("u2", 2, 0.5, [UniV3LiquidityBand(1.0, 9.0), UniV3LiquidityBand(0.5, 11.0), UniV3LiquidityBand(0.25, 8.0)], 0.997),
    ],
)
solve_prediction_market(uni_problem; mode=:direct_only, certify=true, throw_on_fail=false)
solve_prediction_market(problem; mode=:mixed_enabled, certify=true, throw_on_fail=false, max_doublings=0)

JSON3.write(problem)
