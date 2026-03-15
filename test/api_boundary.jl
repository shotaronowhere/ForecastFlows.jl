@testset "api boundary" begin
    exported = sort!(string.(filter(s -> s != :ForecastFlows && Base.isexported(ForecastFlows, s), names(ForecastFlows; all=false, imported=false))))
    publics = sort!(string.(filter(s -> s != :ForecastFlows && Base.ispublic(ForecastFlows, s), names(ForecastFlows; all=false, imported=false))))

    @test exported == sort!([
        "ConstantProductMarketSpec",
        "OutcomeSpec",
        "PredictionMarketFixedGasModel",
        "PredictionMarketProblem",
        "PredictionMarketSolveResult",
        "PredictionMarketTrade",
        "SolveCertificateSummary",
        "SplitMergePlan",
        "UniV3LiquidityBand",
        "UniV3MarketSpec",
        "compare_prediction_market_families",
        "solve_prediction_market",
    ])

    @test publics == sort!([
        "CompareRequest",
        "CompareResponse",
        "ConstantProductMarketSpec",
        "ErrorResponse",
        "HealthRequest",
        "HealthResponse",
        "OutcomeSpec",
        "PREDICTION_MARKET_PROTOCOL_VERSION",
        "PredictionMarketFixedGasModel",
        "PredictionMarketProblem",
        "PredictionMarketSolveResult",
        "PredictionMarketTrade",
        "PredictionMarketWorkspace",
        "SolveCertificateSummary",
        "SolveRequest",
        "SolveResponse",
        "SplitMergePlan",
        "UniV3LiquidityBand",
        "UniV3MarketSpec",
        "compare_prediction_market_families",
        "compare_prediction_market_families!",
        "handle_protocol_json",
        "handle_protocol_request",
        "parse_protocol_request",
        "render_protocol_response",
        "serve_protocol",
        "solve_prediction_market",
        "solve_prediction_market!",
    ])

    @test !Base.isexported(ForecastFlows, :PredictionMarketWorkspace)
    @test !Base.isexported(ForecastFlows, :handle_protocol_json)
    @test !Base.ispublic(ForecastFlows, :Solver)
    @test !Base.ispublic(ForecastFlows, :FixedGasModel)
    @test !Base.ispublic(ForecastFlows, :problem)
    @test Base.ispublic(ForecastFlows, :PredictionMarketWorkspace)
    @test Base.ispublic(ForecastFlows, :handle_protocol_json)
end
