const protocol_fixture_dir = joinpath(@__DIR__, "fixtures", "protocol_v2")

function protocol_fixture_problem()
    return PredictionMarketProblem(
        [
            OutcomeSpec("1", 0.55, 0.0),
            OutcomeSpec("2", 0.45, 0.0),
        ],
        1.0,
        [
            ConstantProductMarketSpec("m1", "1", 40.0, 100.0, 1.0),
            ConstantProductMarketSpec("m2", "2", 70.0, 100.0, 1.0),
        ];
        split_bound=5.0,
    )
end

function protocol_fixture_request(name::AbstractString)
    problem = protocol_fixture_problem()
    if name == "health"
        return (protocol_version=2, request_id="health-fixture", command="health")
    elseif name == "solve_direct"
        return (
            protocol_version=2,
            request_id="solve-direct-fixture",
            command="solve_prediction_market",
            mode="direct_only",
            problem=problem,
            solve_options=(throw_on_fail=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000),
        )
    elseif name == "solve_mixed"
        return (
            protocol_version=2,
            request_id="solve-mixed-fixture",
            command="solve_prediction_market",
            mode="mixed_enabled",
            problem=problem,
            solve_options=(throw_on_fail=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000, max_doublings=0),
        )
    elseif name == "compare"
        return (
            protocol_version=2,
            request_id="compare-fixture",
            command="compare_prediction_market_families",
            problem=problem,
            solve_options=(throw_on_fail=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000, max_doublings=0),
        )
    elseif name == "invalid_request"
        return (protocol_version=2, request_id="invalid-fixture", command="wat")
    elseif name == "unsupported_version"
        return (protocol_version=3, request_id="bad-version-fixture", command="health")
    end
    throw(ArgumentError("unknown protocol fixture: $name"))
end

read_protocol_fixture(name::AbstractString) =
    JSON3.read(read(joinpath(protocol_fixture_dir, "$(name)_response.json"), String))

function assert_json_subset(actual, expected)
    if expected isa JSON3.Object
        for key in propertynames(expected)
            @test hasproperty(actual, key)
            assert_json_subset(getproperty(actual, key), getproperty(expected, key))
        end
        return
    end

    if expected isa JSON3.Array
        @test length(actual) == length(expected)
        for (actual_item, expected_item) in zip(actual, expected)
            assert_json_subset(actual_item, expected_item)
        end
        return
    end

    if expected isa Number
        @test actual isa Number
        @test isapprox(Float64(actual), Float64(expected); atol=1e-9, rtol=1e-9)
        return
    end

    @test actual == expected
end

assert_finite_number(value) = (@test value isa Number; @test isfinite(Float64(value)))
assert_nonnegative_number(value) = (@test value isa Number; @test Float64(value) >= 0.0)

function assert_optional_number(value)
    if isnothing(value)
        @test isnothing(value)
    else
        assert_finite_number(value)
    end
end

function assert_certificate_schema(certificate)
    @test hasproperty(certificate, :passed)
    @test certificate.passed isa Bool
    @test hasproperty(certificate, :message)
    @test certificate.message isa AbstractString
    @test hasproperty(certificate, :primal_value)
    assert_optional_number(certificate.primal_value)
    @test hasproperty(certificate, :dual_value)
    assert_optional_number(certificate.dual_value)
    @test hasproperty(certificate, :duality_gap)
    assert_optional_number(certificate.duality_gap)
    @test hasproperty(certificate, :target_residual)
    assert_optional_number(certificate.target_residual)
    @test hasproperty(certificate, :bound_residual)
    assert_optional_number(certificate.bound_residual)
end

function assert_trade_schema(trade)
    @test hasproperty(trade, :market_id)
    @test trade.market_id isa AbstractString
    @test hasproperty(trade, :outcome_id)
    @test trade.outcome_id isa AbstractString
    @test !hasproperty(trade, :outcome_index)
    @test hasproperty(trade, :collateral_delta)
    assert_finite_number(trade.collateral_delta)
    @test hasproperty(trade, :outcome_delta)
    assert_finite_number(trade.outcome_delta)
end

function assert_split_merge_schema(split_merge)
    @test hasproperty(split_merge, :mint)
    assert_nonnegative_number(split_merge.mint)
    @test hasproperty(split_merge, :merge)
    assert_nonnegative_number(split_merge.merge)
end

function assert_solve_result_schema(result)
    @test hasproperty(result, :status)
    @test result.status isa AbstractString
    @test hasproperty(result, :mode)
    @test result.mode isa AbstractString
    @test hasproperty(result, :certificate)
    assert_certificate_schema(result.certificate)
    @test hasproperty(result, :solver_time_sec)
    assert_nonnegative_number(result.solver_time_sec)
    @test hasproperty(result, :initial_ev)
    assert_finite_number(result.initial_ev)
    @test hasproperty(result, :final_ev)
    assert_finite_number(result.final_ev)
    @test hasproperty(result, :ev_gain)
    assert_finite_number(result.ev_gain)
    @test hasproperty(result, :outcome_ids)
    @test all(outcome_id -> outcome_id isa AbstractString, result.outcome_ids)
    @test !isempty(result.outcome_ids)
    @test hasproperty(result, :initial_collateral)
    assert_finite_number(result.initial_collateral)
    @test !hasproperty(result, :initial_cash)
    @test hasproperty(result, :final_collateral)
    assert_finite_number(result.final_collateral)
    @test !hasproperty(result, :final_cash)
    @test hasproperty(result, :initial_holdings)
    @test hasproperty(result, :final_holdings)
    @test length(result.outcome_ids) == length(result.initial_holdings) == length(result.final_holdings)
    @test all(value -> value isa Number, result.initial_holdings)
    @test all(value -> value isa Number, result.final_holdings)
    @test hasproperty(result, :trades)
    @test all(trade -> begin
        assert_trade_schema(trade)
        true
    end, result.trades)
    @test hasproperty(result, :split_merge)
    assert_split_merge_schema(result.split_merge)
end

function assert_health_response_schema(response)
    @test response.protocol_version == 2
    @test response.request_id == "health-fixture"
    @test response.ok === true
    @test response.command == "health"
    result = response.result
    @test result.status == "ok"
    @test result.package == "ForecastFlows"
    @test result.package_version == "2.0.0"
    @test result.supported_commands == ["health", "solve_prediction_market", "compare_prediction_market_families"]
    @test result.supported_modes == ["direct_only", "mixed_enabled"]
    @test result.supported_market_types == ["constant_product", "univ3"]
    @test result.stable_interfaces == ["prediction_market_facade", "ndjson_protocol"]
    @test result.public_interfaces == [
        "PredictionMarketWorkspace",
        "PredictionMarketFixedGasModel",
        "solve_prediction_market!",
        "PREDICTION_MARKET_PROTOCOL_VERSION",
        "HealthRequest",
        "SolveRequest",
        "CompareRequest",
        "HealthResponse",
        "SolveResponse",
        "CompareResponse",
        "ErrorResponse",
        "parse_protocol_request",
        "handle_protocol_request",
        "render_protocol_response",
        "handle_protocol_json",
        "serve_protocol",
    ]
    @test result.numeric_units == "decimal collateral and outcome token units"
    @test result.execution_model == "stateless NDJSON; one request at a time per worker process"
end

function assert_error_response_schema(response, request_id::AbstractString, message::AbstractString)
    @test response.protocol_version == 2
    @test response.request_id == request_id
    @test response.ok === false
    @test !hasproperty(response, :command)
    @test !hasproperty(response, :result)
    @test hasproperty(response, :error)
    @test response.error.code == "invalid_request"
    @test response.error.message == message
end

@testset "protocol fixtures" begin
    fixture_names = [
        "health",
        "solve_direct",
        "solve_mixed",
        "compare",
        "invalid_request",
        "unsupported_version",
    ]

    for name in fixture_names
        response = JSON3.read(ForecastFlows.handle_protocol_json(JSON3.write(protocol_fixture_request(name))))
        assert_json_subset(response, read_protocol_fixture(name))

        if name == "health"
            assert_health_response_schema(response)
        elseif name == "solve_direct"
            @test response.command == "solve_prediction_market"
            assert_solve_result_schema(response.result)
            @test response.result.mode == "direct_only"
            @test response.result.status == "certified"
        elseif name == "solve_mixed"
            @test response.command == "solve_prediction_market"
            assert_solve_result_schema(response.result)
            @test response.result.mode == "mixed_enabled"
            @test response.result.status == "uncertified"
        elseif name == "compare"
            @test response.command == "compare_prediction_market_families"
            @test hasproperty(response, :result)
            @test hasproperty(response.result, :direct_only)
            @test hasproperty(response.result, :mixed_enabled)
            assert_solve_result_schema(response.result.direct_only)
            assert_solve_result_schema(response.result.mixed_enabled)
        elseif name == "invalid_request"
            assert_error_response_schema(
                response,
                "invalid-fixture",
                "ArgumentError: unsupported command: wat",
            )
        elseif name == "unsupported_version"
            assert_error_response_schema(
                response,
                "bad-version-fixture",
                "ArgumentError: unsupported protocol_version 3",
            )
        end
    end
end
