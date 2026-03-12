#!/usr/bin/env julia

using ForecastFlows
using JSON3

const REPO_ROOT = dirname(@__DIR__)
const WORKER_SCRIPT = joinpath(REPO_ROOT, "bin", "forecastflows-worker.jl")
const CASE_FIXTURE = joinpath(REPO_ROOT, "test", "fixtures", "rebalancer_ab_cases.json")
const CASE_ID = "heterogeneous_ninety_eight_outcome_l1_like_case"
const SOLVER_OPTIONS = (; pgtol=1e-8, max_iter=5_000, max_fun=10_000)
const TERMINAL_BAND_L = 0.0

to_tokens(x) = Float64(x) / 1e18

function sqrt_price_x96_at_tick(tick::Integer)
    return setprecision(BigFloat, 256) do
        (big"1.0001" ^ (BigFloat(tick) / big(2))) * (BigFloat(2) ^ 96)
    end
end

function outcome_price_from_sqrt_x96(sqrt_price_x96::BigFloat, is_token1::Bool)
    return setprecision(BigFloat, 256) do
        price = (sqrt_price_x96 / (BigFloat(2) ^ 96))^2
        return Float64(is_token1 ? inv(price) : price)
    end
end

function outcome_price_from_tick(tick::Integer, is_token1::Bool)
    return outcome_price_from_sqrt_x96(sqrt_price_x96_at_tick(tick), is_token1)
end

function benchmark_tick_limit_prices(tick_lo::Integer, tick_hi::Integer, is_token1::Bool)
    lo = min(tick_lo, tick_hi)
    hi = max(tick_lo, tick_hi)
    if is_token1
        return (
            buy_limit_price=outcome_price_from_tick(lo, true),
            sell_limit_price=outcome_price_from_tick(hi, true),
        )
    end
    return (
        buy_limit_price=outcome_price_from_tick(hi, false),
        sell_limit_price=outcome_price_from_tick(lo, false),
    )
end

function build_latency_problem(case_id::AbstractString=CASE_ID)
    payload = JSON3.read(read(CASE_FIXTURE, String))
    case = getproperty(payload, Symbol(case_id))

    predictions = to_tokens.(collect(case.predictions_wad))
    holdings0 = to_tokens.(collect(case.initial_holdings_wad))
    cash0 = to_tokens(case.initial_cash_budget_wad)
    current_prices = to_tokens.(collect(case.starting_prices_wad))
    liquidity_L = to_tokens.(collect(case.liquidity))
    is_token1 = Bool.(collect(case.is_token1))
    ticks = [Int[Int(tick[1]), Int(tick[2])] for tick in case.ticks]
    fee_multiplier = 1.0 - Float64(case.fee_tier) / 1e6

    outcomes = OutcomeSpec[]
    sizehint!(outcomes, length(predictions))
    markets = UniV3MarketSpec[]
    sizehint!(markets, length(predictions))

    for i in eachindex(predictions)
        limits = benchmark_tick_limit_prices(ticks[i][1], ticks[i][2], is_token1[i])
        push!(outcomes, OutcomeSpec(string(i), predictions[i], holdings0[i]))
        # The vendored benchmark case has a hard lower price boundary. A terminal
        # zero-liquidity band preserves that boundary exactly on the public
        # prediction-market facade and worker protocol.
        push!(markets, UniV3MarketSpec(
            "m$(i)",
            string(i),
            current_prices[i],
            [
                UniV3LiquidityBand(limits.buy_limit_price, liquidity_L[i]),
                UniV3LiquidityBand(limits.sell_limit_price, TERMINAL_BAND_L),
            ],
            fee_multiplier,
        ))
    end

    return PredictionMarketProblem(outcomes, cash0, markets)
end

function timed_stateless(problem; mode::Symbol)
    return @elapsed solve_prediction_market(
        problem;
        mode=mode,
        throw_on_fail=false,
        max_doublings=0,
        solver_options=SOLVER_OPTIONS,
    )
end

function timed_workspace(problem; mode::Symbol)
    workspace = ForecastFlows.PredictionMarketWorkspace(problem)
    ForecastFlows.solve_prediction_market!(
        workspace,
        problem;
        mode=mode,
        throw_on_fail=false,
        max_doublings=0,
        solver_options=SOLVER_OPTIONS,
    )
    return @elapsed ForecastFlows.solve_prediction_market!(
        workspace,
        problem;
        mode=mode,
        throw_on_fail=false,
        max_doublings=0,
        solver_options=SOLVER_OPTIONS,
    )
end

function read_worker_response(io::IO)
    response = JSON3.read(readline(io))
    response.ok || error("worker request failed: $(response)")
    return response
end

function timed_worker(problem; mode::String)
    request = JSON3.write((
        protocol_version=2,
        request_id="latency",
        command="solve_prediction_market",
        mode=mode,
        problem=problem,
        solve_options=(throw_on_fail=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000, max_doublings=0),
    ))
    cmd = `$(Base.julia_cmd()) --project=$(REPO_ROOT) $(WORKER_SCRIPT)`
    io = open(cmd, "r+")
    try
        println(io, JSON3.write((protocol_version=2, request_id="health", command="health")))
        flush(io)
        read_worker_response(io)

        println(io, request)
        flush(io)
        read_worker_response(io)

        return @elapsed begin
            println(io, request)
            flush(io)
            read_worker_response(io)
        end
    finally
        close(io)
    end
end

function main()
    problem = build_latency_problem()

    cold_stateless_direct = timed_stateless(problem; mode=:direct_only)
    warm_stateless_direct = timed_stateless(problem; mode=:direct_only)
    warm_workspace_direct = timed_workspace(problem; mode=:direct_only)
    warm_stateless_mixed = begin
        timed_stateless(problem; mode=:mixed_enabled)
        timed_stateless(problem; mode=:mixed_enabled)
    end
    warm_worker_direct = timed_worker(problem; mode="direct_only")

    println("informational latency smoke")
    println("case_id=$(CASE_ID)")
    println("outcome_count=$(length(problem.outcomes))")
    println("market_count=$(length(problem.markets))")
    println("terminal_band_liquidity_L=$(TERMINAL_BAND_L)")
    println("cold_stateless_direct_sec=$(cold_stateless_direct)")
    println("warm_stateless_direct_sec=$(warm_stateless_direct)")
    println("warm_workspace_direct_sec=$(warm_workspace_direct)")
    println("warm_stateless_mixed_sec=$(warm_stateless_mixed)")
    println("warm_worker_direct_roundtrip_sec=$(warm_worker_direct)")
end

main()
