module ForecastFlows

using LinearAlgebra
using ForwardDiff
using JSON3
using LBFGSB
using PrecompileTools: @compile_workload
using Printf
using StructTypes

include("utils.jl")

include("bfgs/types.jl")
include("bfgs/bfgs.jl")

include("edges.jl")
include("prediction_markets.jl")
include("objectives.jl")


include("solver.jl")
include("solver_bfgs.jl")
include("prediction_market_api.jl")

public PredictionMarketWorkspace, solve_prediction_market!, compare_prediction_market_families!
public PREDICTION_MARKET_PROTOCOL_VERSION
public HealthRequest, SolveRequest, CompareRequest
public HealthResponse, SolveResponse, CompareResponse, ErrorResponse
public parse_protocol_request, handle_protocol_request, render_protocol_response, handle_protocol_json, serve_protocol

export OutcomeSpec
export PredictionMarketProblem, ConstantProductMarketSpec, UniV3MarketSpec
export UniV3LiquidityBand
export PredictionMarketFixedGasModel
export PredictionMarketTrade, SplitMergePlan, SolveCertificateSummary, PredictionMarketSolveResult
export solve_prediction_market, compare_prediction_market_families

@compile_workload begin
    base_problem = PredictionMarketProblem(
        [
            OutcomeSpec("YES_A", 0.55, 0.0),
            OutcomeSpec("YES_B", 0.45, 0.0),
        ],
        1.0,
        [
            ConstantProductMarketSpec("m1", "YES_A", 40.0, 100.0, 1.0),
            ConstantProductMarketSpec("m2", "YES_B", 70.0, 100.0, 1.0),
        ];
        split_bound=5.0,
    )
    uni_problem = PredictionMarketProblem(
        [
            OutcomeSpec("YES_A", 0.5, 0.0),
            OutcomeSpec("YES_B", 0.5, 0.0),
        ],
        0.0,
        [
            UniV3MarketSpec("u1", "YES_A", 0.5, [UniV3LiquidityBand(0.25, 10.0), UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.5, 12.0)], 0.997),
            UniV3MarketSpec("u2", "YES_B", 0.5, [UniV3LiquidityBand(0.25, 8.0), UniV3LiquidityBand(1.0, 9.0), UniV3LiquidityBand(0.5, 11.0)], 0.997),
        ];
        split_bound=5.0,
    )
    solve_prediction_market(base_problem; mode=:direct_only, certify=true, throw_on_fail=false, solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000))
    solve_prediction_market(base_problem; mode=:mixed_enabled, certify=true, throw_on_fail=false, max_doublings=0, solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000))
    compare_prediction_market_families(base_problem; certify=true, throw_on_fail=false, max_doublings=0, solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000))
    solve_prediction_market(uni_problem; mode=:direct_only, certify=true, throw_on_fail=false, solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000))
    workspace = PredictionMarketWorkspace(base_problem)
    solve_prediction_market!(workspace, base_problem; mode=:direct_only, certify=true, throw_on_fail=false, solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000))
    compare_prediction_market_families!(workspace, base_problem; certify=true, throw_on_fail=false, max_doublings=0, solver_options=(; pgtol=1e-8, max_iter=5_000, max_fun=10_000))
    handle_protocol_json("""{"protocol_version":2,"request_id":"health","command":"health"}""")
end

end
