#!/usr/bin/env julia

using JSON3

const REPO_ROOT = dirname(@__DIR__)
const WORKER_SCRIPT = joinpath(REPO_ROOT, "bin", "forecastflows-worker.jl")
const EXPECTED_EXECUTION_MODEL = "NDJSON; one request at a time per worker process; serve_protocol reuses compatible compare workspaces; handle_protocol_json is stateless"

function main()
    cmd = `$(Base.julia_cmd()) --project=$(REPO_ROOT) $(WORKER_SCRIPT)`
    requests = [
        (protocol_version=2, request_id="health", command="health"),
        (
            protocol_version=2,
            request_id="solve",
            command="solve_prediction_market",
            mode="direct_only",
            problem=(
                outcomes=[
                    (outcome_id="1", fair_value=0.55, initial_holding=0.0),
                    (outcome_id="2", fair_value=0.45, initial_holding=0.0),
                ],
                collateral_balance=1.0,
                markets=[
                    (type="constant_product", market_id="m1", outcome_id="1", collateral_reserve=40.0, outcome_reserve=100.0, fee_multiplier=1.0),
                    (type="constant_product", market_id="m2", outcome_id="2", collateral_reserve=70.0, outcome_reserve=100.0, fee_multiplier=1.0),
                ],
            ),
            solve_options=(pgtol=1e-8, max_iter=5_000, max_fun=10_000),
        ),
        (
            protocol_version=2,
            request_id="uncertified-json",
            command="solve_prediction_market",
            mode="mixed_enabled",
            problem=(
                outcomes=[
                    (outcome_id="1", fair_value=0.55, initial_holding=0.0),
                    (outcome_id="2", fair_value=0.45, initial_holding=0.0),
                ],
                collateral_balance=1.0,
                markets=[
                    (type="constant_product", market_id="m1", outcome_id="1", collateral_reserve=40.0, outcome_reserve=100.0, fee_multiplier=1.0),
                    (type="constant_product", market_id="m2", outcome_id="2", collateral_reserve=70.0, outcome_reserve=100.0, fee_multiplier=1.0),
                ],
            ),
            solve_options=(throw_on_fail=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000),
        ),
    ]

    output = read(pipeline(IOBuffer(join(JSON3.write.(requests), "\n") * "\n"), cmd), String)
    responses = JSON3.read.(filter(!isempty, split(chomp(output), '\n')))
    length(responses) == 3 || error("worker smoke expected 3 responses, got $(length(responses))")

    responses[1].ok || error("worker health request failed: $(responses[1])")
    responses[1].result.status == "ok" || error("worker health status was not ok")
    String(responses[1].result.execution_model) == EXPECTED_EXECUTION_MODEL ||
        error("worker execution_model did not match the documented v2 contract")

    responses[2].ok || error("worker solve request failed: $(responses[2])")
    responses[2].result.mode == "direct_only" || error("worker solve returned unexpected mode")
    responses[2].result.status in ("certified", "solved") || error("worker solve returned unexpected status")
    responses[2].result.trades[1].outcome_id == "1" || error("worker solve returned unexpected outcome_id")

    responses[3].ok || error("worker uncertified-json request failed: $(responses[3])")
    responses[3].result.status == "uncertified" || error("worker uncertified-json request should be uncertified")
    isnothing(responses[3].result.certificate.primal_value) || error("worker uncertified-json response should sanitize non-finite certificate fields")

    println("worker smoke checks passed")
end

main()
