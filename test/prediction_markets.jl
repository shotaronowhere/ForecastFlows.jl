using JSON3
using Libdl

const pm_tol = 1e-6
const facade_solver_options = (; pgtol=1e-8, max_iter=5_000, max_fun=10_000)
const dt_focus_case_id = "heterogeneous_ninety_eight_outcome_l1_like_case"
const deep_trading_compat_opt_in_env = "FORECASTFLOWS_RUN_DEEPTRADING_COMPAT"
const legacy_benchmark_opt_in_env = "FORECASTFLOWS_RUN_DEEPTRADING_BENCHMARK"
const replay_atol = 1e-9
const dt_cases_fixture = joinpath(@__DIR__, "fixtures", "rebalancer_ab_cases.json")
const dt_expected_fixture = joinpath(@__DIR__, "fixtures", "rebalancer_ab_expected.json")
const dt_net_expected_fixture = joinpath(@__DIR__, "fixtures", "rebalancer_ab_net_expected.json")

const dt_cases_payload = JSON3.read(read(dt_cases_fixture, String))
const dt_expected_payload = JSON3.read(read(dt_expected_fixture, String))
const dt_net_expected_payload = JSON3.read(read(dt_net_expected_fixture, String))

const dt_case_ids = sort!(String.(collect(propertynames(dt_cases_payload))))
const heterogeneous_mixed_raw_wobble_tol = 65_536 / 1e18

struct DeepTradingRawExpectedRow
    direct_ev::Float64
    mixed_ev::Float64
    full_rebalance_only_ev::Float64
    action_count::Int
    onchain_exact_ev::Float64
end

struct DeepTradingNetExpectedRow
    direct_net_ev::Float64
    mixed_net_ev::Float64
    best_family::String
    best_net_ev::Float64
end

function deep_trading_raw_expected(case_id::String)
    row = getproperty(dt_expected_payload, Symbol(case_id))
    return DeepTradingRawExpectedRow(
        Float64(row.offchain_direct_ev_wei) / 1e18,
        Float64(row.offchain_mixed_ev_wei) / 1e18,
        Float64(row.offchain_full_rebalance_only_ev_wei) / 1e18,
        Int(row.offchain_action_count),
        Float64(row.expected_onchain_exact_ev_wei) / 1e18,
    )
end

function deep_trading_net_expected(case_id::String)
    row = getproperty(dt_net_expected_payload, Symbol(case_id))
    return DeepTradingNetExpectedRow(
        Float64(row.direct_net_ev),
        Float64(row.mixed_net_ev),
        String(row.best_family),
        Float64(row.best_net_ev),
    )
end

deep_trading_compat_opted_in() =
    get(ENV, deep_trading_compat_opt_in_env, get(ENV, legacy_benchmark_opt_in_env, "0")) == "1"

struct SingleTickMarketSpec
    current_price::Float64
    buy_limit_price::Float64
    sell_limit_price::Float64
    liquidity_raw::Float64
    γ::Float64
    tick_lo::Int
    tick_hi::Int
    is_token1::Bool
end

struct DeepTradingBenchmarkCase
    case_id::String
    predictions::Vector{Float64}
    current_prices::Vector{Float64}
    holdings0::Vector{Float64}
    cash0::Float64
    liquidity_raw::Vector{Float64}
    buy_limit_prices::Vector{Float64}
    sell_limit_prices::Vector{Float64}
    γ::Float64
    tick_lo::Vector{Int}
    tick_hi::Vector{Int}
    markets::Vector{SingleTickMarketSpec}
    objective::EndowmentLinear{Float64}
    amm_edges::Vector{Edge}
    split_nodes::Vector{Int}
    initial_split_bound::Float64
    initial_ev::Float64
    deep_trading_direct_ev::Float64
    deep_trading_mixed_ev::Float64
    deep_trading_full_rebalance_only_ev::Float64
    n::Int
end

struct RouteDesiderata
    direct_buys::Vector{Float64}
    direct_sells::Vector{Float64}
    mint::Float64
    merge::Float64
    raw_upper_ev::Float64
end

struct ReplayResiduals
    direct_buy::Float64
    direct_sell::Float64
    mint::Float64
    merge::Float64
end

struct ReplayActionCounts
    direct_buys::Int
    direct_sells::Int
    mint_rounds::Int
    direct_merge_rounds::Int
    buy_merge_rounds::Int
end

struct ReplayReport
    final_cash::Float64
    final_holdings::Vector{Float64}
    final_raw_ev::Float64
    fill_fraction::Float64
    residuals::ReplayResiduals
    counts::ReplayActionCounts
    executed_direct_buy::Float64
    executed_direct_sell::Float64
    executed_mint::Float64
    executed_merge::Float64
    actions::Vector{NamedTuple}
end

const dt_benchmark_snapshot = (
    gas_price_wei=1_002_325.0,
    eth_usd=3000.0,
    l1_fee_per_byte_wei=1_643_855.3414634147,
    l1_data_fee_floor_susd=0.0,
)

const benchmark_direct_buy_l2_units = 57_542
const benchmark_direct_sell_l2_units = 38_099
const benchmark_direct_merge_l2_units = 21_502
const benchmark_mint_sell_base_l2_units = 17_783
const benchmark_mint_sell_per_sell_leg_l2_units = 50_649
const benchmark_buy_merge_base_l2_units = 37_370
const benchmark_buy_merge_per_buy_leg_l2_units = 29_670
const benchmark_max_packed_tx_l2_gas_units = 40_000_000
const benchmark_tx_envelope_bytes = 110
const benchmark_batch_call_base_bytes = 100
const benchmark_swap_bytes = 224
const benchmark_flash_route_extra_bytes = 160
const benchmark_direct_merge_call_bytes = 220

mutable struct ReplaySingleTickPool
    current_price::Float64
    buy_limit_price::Float64
    sell_limit_price::Float64
    liquidity_raw::Float64
    γ::Float64
end

struct SingleTickBenchmarkEdge{T} <: Edge{T}
    current_price::T
    buy_limit_price::T
    sell_limit_price::T
    liquidity_raw::T
    γ::T
    Ai::Vector{Int}

    function SingleTickBenchmarkEdge(current_price, buy_limit_price, sell_limit_price, liquidity_raw, γ, Ai)
        length(Ai) == 2 || throw(ArgumentError("SingleTickBenchmarkEdge requires two nodes"))
        T = promote_type(typeof(current_price), typeof(buy_limit_price), typeof(sell_limit_price), typeof(liquidity_raw), typeof(γ))
        current = convert(T, current_price)
        buy_limit = convert(T, buy_limit_price)
        sell_limit = convert(T, sell_limit_price)
        liquidity = convert(T, liquidity_raw)
        fee = convert(T, γ)
        zero(T) < sell_limit < current <= buy_limit || throw(ArgumentError("single-tick price bounds must satisfy 0 < sell < current <= buy"))
        liquidity > zero(T) || throw(ArgumentError("single-tick liquidity must be positive"))
        zero(T) < fee <= one(T) || throw(ArgumentError("single-tick fee multiplier must lie in (0, 1]"))
        return new{T}(current, buy_limit, sell_limit, liquidity, fee, collect(Int, Ai))
    end
end

function solve_router(edges, obj; n, kwargs...)
    s = Solver(flow_objective=obj, edges=edges, n=n)
    solve!(s; verbose=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000, kwargs...)
    @test !isnothing(s.certificate)
    @test s.certificate.passed
    return s
end

function solve_router_result(edges, obj; n, require_cert::Bool=true, kwargs...)
    s = Solver(flow_objective=obj, edges=edges, n=n)
    solve_time = solve!(s; verbose=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000, kwargs...)
    @test !isnothing(s.certificate)
    require_cert && @test s.certificate.passed
    return (solver=s, solve_time=solve_time)
end

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

@inline buy_lambda(pool::ReplaySingleTickPool) = pool.current_price > 0 ? sqrt(pool.current_price) / pool.liquidity_raw : 0.0
@inline sell_kappa(pool::ReplaySingleTickPool) = pool.current_price > 0 ? pool.γ * sqrt(pool.current_price) / pool.liquidity_raw : 0.0

function max_buy_tokens(pool::ReplaySingleTickPool)
    λ = buy_lambda(pool)
    λ <= 0 && return 0.0
    pool.buy_limit_price <= pool.current_price && return 0.0
    return (1.0 - sqrt(pool.current_price / pool.buy_limit_price)) / λ
end

function max_sell_tokens(pool::ReplaySingleTickPool)
    κ = sell_kappa(pool)
    κ <= 0 && return 0.0
    pool.sell_limit_price <= 0 && return 0.0
    pool.sell_limit_price >= pool.current_price && return 0.0
    return (sqrt(pool.current_price / pool.sell_limit_price) - 1.0) / κ
end

function buy_preview(pool::ReplaySingleTickPool, amount::Float64)
    amount <= 0 && return (0.0, 0.0, pool.current_price)
    actual = min(amount, max_buy_tokens(pool))
    actual <= 0 && return (0.0, 0.0, pool.current_price)
    d = 1.0 - actual * buy_lambda(pool)
    d <= 0 && return (0.0, Inf, pool.current_price)
    new_price = pool.current_price / (d * d)
    cost = actual * pool.current_price / (pool.γ * d)
    return (actual, cost, new_price)
end

function buy_to_price(pool::ReplaySingleTickPool, target_price::Float64)
    clamped = min(target_price, pool.buy_limit_price)
    clamped <= pool.current_price && return (0.0, 0.0, pool.current_price)
    amount = pool.liquidity_raw * (inv(sqrt(pool.current_price)) - inv(sqrt(clamped)))
    cost = pool.liquidity_raw * (sqrt(clamped) - sqrt(pool.current_price)) / pool.γ
    return (amount, cost, clamped)
end

function sell_preview(pool::ReplaySingleTickPool, amount::Float64)
    amount <= 0 && return (0.0, 0.0, pool.current_price)
    actual = min(amount, max_sell_tokens(pool))
    actual <= 0 && return (0.0, 0.0, pool.current_price)
    d = 1.0 + actual * sell_kappa(pool)
    new_price = pool.current_price / (d * d)
    proceeds = pool.current_price * actual * pool.γ / d
    return (actual, proceeds, new_price)
end

function sell_to_price(pool::ReplaySingleTickPool, target_price::Float64)
    clamped = max(target_price, pool.sell_limit_price)
    clamped >= pool.current_price && return (0.0, 0.0, pool.current_price)
    amount = pool.liquidity_raw * (inv(sqrt(clamped)) - inv(sqrt(pool.current_price))) / pool.γ
    proceeds = pool.liquidity_raw * (sqrt(pool.current_price) - sqrt(clamped))
    return (amount, proceeds, clamped)
end

function buy_exact!(pool::ReplaySingleTickPool, amount::Float64)
    bought, cost, new_price = buy_preview(pool, amount)
    pool.current_price = new_price
    return bought, cost, new_price
end

function sell_exact!(pool::ReplaySingleTickPool, amount::Float64)
    sold, proceeds, new_price = sell_preview(pool, amount)
    pool.current_price = new_price
    return sold, proceeds, new_price
end

function ForecastFlows.find_arb!(x::Vector{T}, edge::SingleTickBenchmarkEdge{T}, η::AbstractVector{T}) where T
    fill!(x, zero(T))
    q = η[2] / η[1]
    tol = sqrt(eps(T))

    if q > edge.current_price / edge.γ + tol
        target_price = min(edge.buy_limit_price, edge.γ * q)
        target_price <= edge.current_price + tol && return nothing
        amount = edge.liquidity_raw * (inv(sqrt(edge.current_price)) - inv(sqrt(target_price)))
        cost = edge.liquidity_raw * (sqrt(target_price) - sqrt(edge.current_price)) / edge.γ
        x[1] = -cost
        x[2] = amount
    elseif q < edge.γ * edge.current_price - tol
        target_price = max(edge.sell_limit_price, q / edge.γ)
        target_price >= edge.current_price - tol && return nothing
        amount = edge.liquidity_raw * (inv(sqrt(target_price)) - inv(sqrt(edge.current_price))) / edge.γ
        proceeds = edge.liquidity_raw * (sqrt(edge.current_price) - sqrt(target_price))
        x[1] = proceeds
        x[2] = -amount
    end

    return nothing
end

function affordable_buy_amount(pool::ReplaySingleTickPool, desired::Float64, cash::Float64; atol::Float64=replay_atol)
    upper = min(desired, max_buy_tokens(pool))
    upper <= atol && return 0.0
    _, cost_upper, _ = buy_preview(pool, upper)
    cost_upper <= cash + atol && return upper
    lo = 0.0
    hi = upper
    for _ in 1:64
        mid = (lo + hi) / 2
        _, cost_mid, _ = buy_preview(pool, mid)
        if cost_mid <= cash
            lo = mid
        else
            hi = mid
        end
    end
    return lo
end

function edge_derived_pool(edge::SingleTickBenchmarkEdge{T}) where T
    return ReplaySingleTickPool(
        Float64(edge.current_price),
        Float64(edge.buy_limit_price),
        Float64(edge.sell_limit_price),
        Float64(edge.liquidity_raw),
        Float64(edge.γ),
    )
end

replay_trade_action(kind::Symbol, market_idx::Int, amount::Float64, cash_quote::Float64) =
    NamedTuple{(:kind, :market_idx, :amount, :quote)}((kind, market_idx, amount, cash_quote))

replay_execution_group(
    kind::Symbol,
    buy_legs::Int,
    sell_legs::Int,
    planned_cost::Float64,
    planned_proceeds::Float64,
) = (; kind, buy_legs, sell_legs, planned_cost, planned_proceeds)

benchmark_fee_report(
    total_l2_fee::Float64,
    total_l1_fee::Float64,
    total_fee::Float64,
    group_count::Int,
    tx_count::Int,
    total_calldata_bytes::Int,
    total_l2_gas_units::Int,
) = (; total_l2_fee, total_l1_fee, total_fee, group_count, tx_count, total_calldata_bytes, total_l2_gas_units)

function benchmark_group_l2_gas_units(group)
    if group.kind == :direct_buy
        return benchmark_direct_buy_l2_units
    elseif group.kind == :direct_sell
        return benchmark_direct_sell_l2_units
    elseif group.kind == :direct_merge
        return benchmark_direct_merge_l2_units
    elseif group.kind == :mint_sell
        return benchmark_mint_sell_base_l2_units +
               benchmark_mint_sell_per_sell_leg_l2_units * max(group.sell_legs, 1)
    elseif group.kind == :buy_merge
        return benchmark_buy_merge_base_l2_units +
               benchmark_buy_merge_per_buy_leg_l2_units * max(group.buy_legs, 1)
    end
    throw(ArgumentError("unsupported replay execution group kind $(group.kind)"))
end

function benchmark_group_incremental_calldata_bytes(group)
    if group.kind == :direct_buy || group.kind == :direct_sell
        return benchmark_swap_bytes
    elseif group.kind == :mint_sell
        return benchmark_flash_route_extra_bytes + benchmark_swap_bytes * max(group.sell_legs, 1)
    elseif group.kind == :buy_merge
        return benchmark_flash_route_extra_bytes + benchmark_swap_bytes * max(group.buy_legs, 1)
    elseif group.kind == :direct_merge
        return benchmark_direct_merge_call_bytes
    end
    throw(ArgumentError("unsupported replay execution group kind $(group.kind)"))
end

function benchmark_group_calldata_bytes(group)
    return benchmark_tx_envelope_bytes +
           benchmark_batch_call_base_bytes +
           benchmark_group_incremental_calldata_bytes(group)
end

benchmark_l2_fee_susd(l2_gas_units::Integer, snapshot) =
    Float64(l2_gas_units) * snapshot.gas_price_wei * snapshot.eth_usd / 1e18

function benchmark_l1_fee_susd(calldata_bytes::Integer, snapshot)
    l1_fee = Float64(calldata_bytes) * snapshot.l1_fee_per_byte_wei * snapshot.eth_usd / 1e18
    return max(snapshot.l1_data_fee_floor_susd, l1_fee)
end

function replay_execution_groups(actions::AbstractVector{<:NamedTuple})
    groups = NamedTuple[]
    i = 1
    while i <= length(actions)
        action = actions[i]
        if action.kind == :buy
            start = i
            while i <= length(actions) && actions[i].kind == :buy
                i += 1
            end
            if i <= length(actions) && actions[i].kind == :merge
                action_slice = @view actions[start:i]
                push!(groups, replay_execution_group(
                    :buy_merge,
                    i - start,
                    0,
                    sum(a.quote for a in action_slice if a.kind == :buy),
                    actions[i].quote,
                ))
                i += 1
            else
                for j in start:(i - 1)
                    push!(groups, replay_execution_group(:direct_buy, 1, 0, actions[j].quote, 0.0))
                end
            end
        elseif action.kind == :sell
            push!(groups, replay_execution_group(:direct_sell, 0, 1, 0.0, action.quote))
            i += 1
        elseif action.kind == :merge
            push!(groups, replay_execution_group(:direct_merge, 0, 0, 0.0, action.quote))
            i += 1
        elseif action.kind == :mint
            start = i
            i += 1
            while i <= length(actions) && actions[i].kind == :sell
                i += 1
            end
            stop = i - 1
            stop > start || throw(ArgumentError("unsupported mint-only replay action block"))
            push!(groups, replay_execution_group(
                :mint_sell,
                0,
                stop - start,
                actions[start].quote,
                sum(actions[j].quote for j in (start + 1):stop),
            ))
        else
            throw(ArgumentError("unsupported replay action kind $(action.kind)"))
        end
    end
    return groups
end

function price_execution_groups(
    groups::AbstractVector{<:NamedTuple},
    snapshot=dt_benchmark_snapshot,
)
    isempty(groups) && return benchmark_fee_report(0.0, 0.0, 0.0, 0, 0, 0, 0)

    total_l2_fee = 0.0
    total_l1_fee = 0.0
    total_l2_gas_units = 0
    total_calldata_bytes = 0
    tx_count = 0
    chunk_l2_gas_units = 0
    chunk_calldata_bytes = 0

    function flush_chunk!()
        chunk_calldata_bytes == 0 && return nothing
        total_l2_fee += benchmark_l2_fee_susd(chunk_l2_gas_units, snapshot)
        total_l1_fee += benchmark_l1_fee_susd(chunk_calldata_bytes, snapshot)
        total_l2_gas_units += chunk_l2_gas_units
        total_calldata_bytes += chunk_calldata_bytes
        tx_count += 1
        chunk_l2_gas_units = 0
        chunk_calldata_bytes = 0
        return nothing
    end

    for group in groups
        l2_gas_units = benchmark_group_l2_gas_units(group)
        base_bytes = benchmark_group_calldata_bytes(group)
        incremental_bytes = benchmark_group_incremental_calldata_bytes(group)

        l2_gas_units < benchmark_max_packed_tx_l2_gas_units ||
            throw(ArgumentError("benchmark execution group exceeds packed gas cap"))

        if chunk_calldata_bytes == 0
            chunk_l2_gas_units = l2_gas_units
            chunk_calldata_bytes = base_bytes
            continue
        end

        tentative_l2_gas_units = chunk_l2_gas_units + l2_gas_units
        if tentative_l2_gas_units >= benchmark_max_packed_tx_l2_gas_units
            flush_chunk!()
            chunk_l2_gas_units = l2_gas_units
            chunk_calldata_bytes = base_bytes
            continue
        end

        chunk_l2_gas_units = tentative_l2_gas_units
        chunk_calldata_bytes += incremental_bytes
    end

    flush_chunk!()
    return benchmark_fee_report(
        total_l2_fee,
        total_l1_fee,
        total_l2_fee + total_l1_fee,
        length(groups),
        tx_count,
        total_calldata_bytes,
        total_l2_gas_units,
    )
end

price_replay_report(report::ReplayReport, snapshot=dt_benchmark_snapshot) =
    price_execution_groups(replay_execution_groups(report.actions), snapshot)

function benchmark_best_family(direct_net_ev::Float64, mixed_net_ev::Float64; atol::Float64=1e-12)
    return mixed_net_ev > direct_net_ev + atol ? "mixed" : "direct"
end

function raw_fixture_atol(case_id::String, family::Symbol)
    if case_id == dt_focus_case_id && family == :mixed
        return heterogeneous_mixed_raw_wobble_tol
    end
    return 1e-12
end

function assemble_benchmark_case(
    case_id::String,
    predictions::Vector{Float64},
    current_prices::Vector{Float64},
    holdings0::Vector{Float64},
    cash0::Float64,
    markets::Vector{SingleTickMarketSpec};
    deep_trading_direct_ev::Float64=NaN,
    deep_trading_mixed_ev::Float64=NaN,
    deep_trading_full_rebalance_only_ev::Float64=NaN,
)
    n_outcomes = length(predictions)
    n_outcomes == length(current_prices) || throw(ArgumentError("price length mismatch"))
    n_outcomes == length(holdings0) || throw(ArgumentError("holding length mismatch"))
    n_outcomes == length(markets) || throw(ArgumentError("market length mismatch"))

    liquidity_raw = Float64[]
    buy_limit_prices = Float64[]
    sell_limit_prices = Float64[]
    tick_lo = Int[]
    tick_hi = Int[]
    amm_edges = Edge[]
    for (i, market) in enumerate(markets)
        push!(liquidity_raw, market.liquidity_raw)
        push!(buy_limit_prices, market.buy_limit_price)
        push!(sell_limit_prices, market.sell_limit_price)
        push!(tick_lo, market.tick_lo)
        push!(tick_hi, market.tick_hi)
        push!(amm_edges, SingleTickBenchmarkEdge(market.current_price, market.buy_limit_price, market.sell_limit_price, market.liquidity_raw, market.γ, [1, i + 1]))
    end

    objective = EndowmentLinear(vcat([1.0], predictions), vcat([cash0], holdings0))
    return DeepTradingBenchmarkCase(
        case_id,
        predictions,
        current_prices,
        holdings0,
        cash0,
        liquidity_raw,
        buy_limit_prices,
        sell_limit_prices,
        markets[1].γ,
        tick_lo,
        tick_hi,
        markets,
        objective,
        amm_edges,
        collect(1:(n_outcomes + 1)),
        cash0 + sum(holdings0),
        initial_portfolio_ev(predictions, cash0, holdings0),
        deep_trading_direct_ev,
        deep_trading_mixed_ev,
        deep_trading_full_rebalance_only_ev,
        n_outcomes + 1,
    )
end

function build_case_from_deep_trading(case_id::String)
    case = getproperty(dt_cases_payload, Symbol(case_id))
    expected = deep_trading_raw_expected(case_id)

    uniform_count = Int(case.uniform_count)
    if uniform_count > 0
        pred = 1.0 / uniform_count
        preds = fill(pred, uniform_count)
        prices = fill(pred * Float64(case.uniform_price_bps) / 10_000.0, uniform_count)
        holdings0 = zeros(uniform_count)
        is_token1 = fill(true, uniform_count)
        liquidities = fill(to_tokens(case.uniform_liquidity), uniform_count)
        ticks = [Int[Int(case.uniform_tick_lo), Int(case.uniform_tick_hi)] for _ in 1:uniform_count]
    else
        preds = to_tokens.(collect(case.predictions_wad))
        prices = to_tokens.(collect(case.starting_prices_wad))
        holdings0 = to_tokens.(collect(case.initial_holdings_wad))
        is_token1 = Bool.(collect(case.is_token1))
        liquidities = to_tokens.(collect(case.liquidity))
        ticks = [Int[Int(tick[1]), Int(tick[2])] for tick in case.ticks]
    end

    cash0 = to_tokens(case.initial_cash_budget_wad)
    fee_tier = Float64(case.fee_tier)
    γ = 1.0 - fee_tier / 1e6

    n_outcomes = length(preds)
    tick_lo = Int[]
    tick_hi = Int[]
    liquidity_raw = Float64[]
    buy_limit_prices = Float64[]
    sell_limit_prices = Float64[]
    markets = SingleTickMarketSpec[]
    for i in 1:n_outcomes
        current_price = prices[i]
        token1 = is_token1[i]
        lo = ticks[i][1]
        hi = ticks[i][2]
        limits = benchmark_tick_limit_prices(lo, hi, token1)
        liquidity = liquidities[i]
        push!(tick_lo, lo)
        push!(tick_hi, hi)
        push!(liquidity_raw, liquidity)
        push!(buy_limit_prices, limits.buy_limit_price)
        push!(sell_limit_prices, limits.sell_limit_price)
        push!(markets, SingleTickMarketSpec(
            current_price,
            limits.buy_limit_price,
            limits.sell_limit_price,
            liquidity,
            γ,
            lo,
            hi,
            token1,
        ))
    end

    return assemble_benchmark_case(
        case_id,
        preds,
        prices,
        holdings0,
        cash0,
        markets;
        deep_trading_direct_ev=expected.direct_ev,
        deep_trading_mixed_ev=expected.mixed_ev,
        deep_trading_full_rebalance_only_ev=expected.full_rebalance_only_ev,
    )
end

function public_problem_from_benchmark(benchmark::DeepTradingBenchmarkCase)
    outcomes = OutcomeSpec[
        OutcomeSpec(string(i), benchmark.predictions[i], benchmark.holdings0[i])
        for i in eachindex(benchmark.predictions)
    ]
    markets = UniV3MarketSpec[
        UniV3MarketSpec(
            "m$(i)",
            string(i),
            market.current_price,
            [
                UniV3LiquidityBand(market.buy_limit_price, market.liquidity_raw),
                UniV3LiquidityBand(market.sell_limit_price, 0.0),
            ],
            market.γ,
        )
        for (i, market) in enumerate(benchmark.markets)
    ]
    return PredictionMarketProblem(
        outcomes,
        benchmark.cash0,
        markets;
        split_bound=benchmark.initial_split_bound,
    )
end

function route_desiderata_from_public_result(
    benchmark::DeepTradingBenchmarkCase,
    result::PredictionMarketSolveResult;
    atol::Float64=replay_atol,
)
    n_outcomes = length(benchmark.predictions)
    direct_buys = zeros(n_outcomes)
    direct_sells = zeros(n_outcomes)
    outcome_index_by_id = Dict(string(i) => i for i in 1:n_outcomes)

    for trade in result.trades
        idx = get(outcome_index_by_id, trade.outcome_id, 0)
        idx == 0 && error("unexpected outcome id $(trade.outcome_id) in public result")
        if trade.outcome_delta > atol
            direct_buys[idx] += trade.outcome_delta
        elseif trade.outcome_delta < -atol
            direct_sells[idx] += -trade.outcome_delta
        end
    end

    return RouteDesiderata(
        direct_buys,
        direct_sells,
        result.split_merge.mint,
        result.split_merge.merge,
        result.final_ev,
    )
end

function replay_public_result(
    benchmark::DeepTradingBenchmarkCase,
    result::PredictionMarketSolveResult;
    atol::Float64=replay_atol,
)
    route = route_desiderata_from_public_result(benchmark, result; atol=atol)
    replay = replay_desired_route(benchmark, route; atol=atol)
    fees = price_replay_report(replay)
    return (
        route=route,
        replay=replay,
        fees=fees,
        net_ev=replay.final_raw_ev - fees.total_fee,
    )
end

function toy_benchmark_case(predictions, current_prices, holdings0, cash0, markets; case_id="toy")
    return assemble_benchmark_case(
        case_id,
        Float64.(predictions),
        Float64.(current_prices),
        Float64.(holdings0),
        Float64(cash0),
        collect(markets),
    )
end

function portfolio_ev_gain(predictions, y)
    return y[1] + dot(predictions, y[2:end])
end

function initial_portfolio_ev(predictions, cash0, holdings)
    return cash0 + dot(predictions, holdings)
end

function final_portfolio_ev(predictions, cash0, holdings, y)
    return initial_portfolio_ev(predictions, cash0, holdings) + portfolio_ev_gain(predictions, y)
end

function final_cash(cash0, y)
    return cash0 + y[1]
end

function final_holdings(holdings, y)
    return holdings .+ y[2:end]
end

function split_flow_size(x)
    return isempty(x) ? 0.0 : maximum(abs, x[2:end])
end

function solve_prediction_market_low_level(problem::PredictionMarketProblem; mode::Symbol=:direct_only, split_bound=nothing, kwargs...)
    n_outcomes = length(problem.outcomes)
    outcome_index_by_id = Dict(outcome.outcome_id => i for (i, outcome) in enumerate(problem.outcomes))
    edges = Edge[]
    for spec in problem.markets
        if spec isa ConstantProductMarketSpec
            push!(edges, ProductTwoCoin([spec.collateral_reserve, spec.outcome_reserve], spec.fee_multiplier, [1, outcome_index_by_id[spec.outcome_id] + 1]))
        elseif spec isa UniV3MarketSpec
            push!(edges, ForecastFlows._build_prediction_market_edge(spec, outcome_index_by_id[spec.outcome_id]))
        else
            error("unsupported market spec type $(typeof(spec))")
        end
    end

    if mode == :mixed_enabled
        bound = isnothing(split_bound) ? (isnothing(problem.split_bound) ? ForecastFlows._default_split_bound(problem) : problem.split_bound) : split_bound
        push!(edges, SplitMergeEdge(collect(1:(n_outcomes + 1)), bound))
    end

    solver = Solver(
        flow_objective=EndowmentLinear(
            vcat([1.0], [outcome.fair_value for outcome in problem.outcomes]),
            vcat([problem.collateral_balance], [outcome.initial_holding for outcome in problem.outcomes]),
        ),
        edges=edges,
        n=n_outcomes + 1,
    )
    solve!(solver; verbose=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000, kwargs...)
    return solver
end

function desired_route_from_solver(benchmark::DeepTradingBenchmarkCase, s::Solver; atol::Float64=replay_atol)
    n_outcomes = length(benchmark.predictions)
    direct_buys = zeros(n_outcomes)
    direct_sells = zeros(n_outcomes)
    mint = 0.0
    merge = 0.0

    for (edge, x) in zip(s.edges, s.xs)
        if edge isa SplitMergeEdge
            length(x) <= 1 && continue
            w = sum(@view x[2:end]) / (length(x) - 1)
            if w > atol
                mint += w
            elseif w < -atol
                merge += -w
            end
            continue
        end
        outcome_idx = edge.Ai[2] - 1
        x[2] > atol && (direct_buys[outcome_idx] += x[2])
        x[2] < -atol && (direct_sells[outcome_idx] += -x[2])
    end

    raw_upper_ev = final_portfolio_ev(benchmark.predictions, benchmark.cash0, benchmark.holdings0, s.y)
    return RouteDesiderata(direct_buys, direct_sells, mint, merge, raw_upper_ev)
end

function merge_round_buy_cost(
    pools::Vector{ReplaySingleTickPool},
    holdings::Vector{Float64},
    amount::Float64;
    atol::Float64=replay_atol,
)
    total = 0.0
    for i in eachindex(pools)
        shortfall = max(amount - holdings[i], 0.0)
        shortfall <= atol && continue
        bought, cost, _ = buy_preview(pools[i], shortfall)
        bought + atol < shortfall && return Inf
        total += cost
    end
    return total
end

function affordable_merge_round(
    pools::Vector{ReplaySingleTickPool},
    holdings::Vector{Float64},
    buy_remaining::Vector{Float64},
    merge_remaining::Float64,
    cash::Float64;
    atol::Float64=replay_atol,
)
    upper = merge_remaining
    for i in eachindex(pools)
        upper = min(upper, holdings[i] + buy_remaining[i], holdings[i] + max_buy_tokens(pools[i]))
    end
    upper <= atol && return 0.0

    cost_upper = merge_round_buy_cost(pools, holdings, upper; atol=atol)
    cost_upper <= cash + atol && return upper

    lo = 0.0
    hi = upper
    for _ in 1:64
        mid = (lo + hi) / 2
        if merge_round_buy_cost(pools, holdings, mid; atol=atol) <= cash
            lo = mid
        else
            hi = mid
        end
    end
    return lo
end

function replay_desired_route(benchmark::DeepTradingBenchmarkCase, route::RouteDesiderata; atol::Float64=replay_atol)
    pools = [ReplaySingleTickPool(m.current_price, m.buy_limit_price, m.sell_limit_price, m.liquidity_raw, m.γ) for m in benchmark.markets]
    cash = benchmark.cash0
    holdings = copy(benchmark.holdings0)
    buy_remaining = copy(route.direct_buys)
    sell_remaining = copy(route.direct_sells)
    mint_remaining = route.mint
    merge_remaining = route.merge

    executed_direct_buy = 0.0
    executed_direct_sell = 0.0
    executed_mint = 0.0
    executed_merge = 0.0
    counts = ReplayActionCounts(0, 0, 0, 0, 0)
    actions = NamedTuple[]

    for i in eachindex(pools)
        desired = sell_remaining[i]
        desired <= atol && continue
        feasible = min(desired, holdings[i], max_sell_tokens(pools[i]))
        feasible <= atol && continue
        sold, proceeds, _ = sell_exact!(pools[i], feasible)
        sold <= atol && continue
        holdings[i] -= sold
        cash += proceeds
        sell_remaining[i] = max(sell_remaining[i] - sold, 0.0)
        executed_direct_sell += sold
        counts = ReplayActionCounts(counts.direct_buys, counts.direct_sells + 1, counts.mint_rounds, counts.direct_merge_rounds, counts.buy_merge_rounds)
        push!(actions, replay_trade_action(:sell, i, sold, proceeds))
    end

    while merge_remaining > atol
        direct_merge = min(merge_remaining, minimum(holdings))
        direct_merge <= atol && break
        holdings .-= direct_merge
        cash += direct_merge
        merge_remaining = max(merge_remaining - direct_merge, 0.0)
        executed_merge += direct_merge
        counts = ReplayActionCounts(counts.direct_buys, counts.direct_sells, counts.mint_rounds, counts.direct_merge_rounds + 1, counts.buy_merge_rounds)
        push!(actions, replay_trade_action(:merge, 0, direct_merge, direct_merge))
    end

    mint_iters = 0
    while mint_remaining > atol && cash > atol
        mint_iters += 1
        mint_iters > 256 && break
        round_amount = min(mint_remaining, cash)
        round_amount <= atol && break
        cash -= round_amount
        holdings .+= round_amount
        mint_remaining = max(mint_remaining - round_amount, 0.0)
        executed_mint += round_amount
        counts = ReplayActionCounts(counts.direct_buys, counts.direct_sells, counts.mint_rounds + 1, counts.direct_merge_rounds, counts.buy_merge_rounds)
        push!(actions, replay_trade_action(:mint, 0, round_amount, round_amount))

        for i in eachindex(pools)
            desired = min(sell_remaining[i], round_amount)
            desired <= atol && continue
            feasible = min(desired, holdings[i], max_sell_tokens(pools[i]))
            feasible <= atol && continue
            sold, proceeds, _ = sell_exact!(pools[i], feasible)
            sold <= atol && continue
            holdings[i] -= sold
            cash += proceeds
            sell_remaining[i] = max(sell_remaining[i] - sold, 0.0)
            executed_direct_sell += sold
            counts = ReplayActionCounts(counts.direct_buys, counts.direct_sells + 1, counts.mint_rounds, counts.direct_merge_rounds, counts.buy_merge_rounds)
            push!(actions, replay_trade_action(:sell, i, sold, proceeds))
        end
    end

    merge_iters = 0
    while merge_remaining > atol
        merge_iters += 1
        merge_iters > 256 && break
        round_amount = affordable_merge_round(pools, holdings, buy_remaining, merge_remaining, cash; atol=atol)
        round_amount <= atol && break

        for i in eachindex(pools)
            shortfall = max(round_amount - holdings[i], 0.0)
            shortfall <= atol && continue
            bought, cost, _ = buy_exact!(pools[i], shortfall)
            bought <= atol && continue
            holdings[i] += bought
            cash -= cost
            buy_remaining[i] = max(buy_remaining[i] - bought, 0.0)
            executed_direct_buy += bought
            counts = ReplayActionCounts(counts.direct_buys + 1, counts.direct_sells, counts.mint_rounds, counts.direct_merge_rounds, counts.buy_merge_rounds)
            push!(actions, replay_trade_action(:buy, i, bought, cost))
        end

        holdings .-= round_amount
        cash += round_amount
        merge_remaining = max(merge_remaining - round_amount, 0.0)
        executed_merge += round_amount
        counts = ReplayActionCounts(counts.direct_buys, counts.direct_sells, counts.mint_rounds, counts.direct_merge_rounds, counts.buy_merge_rounds + 1)
        push!(actions, replay_trade_action(:merge, 0, round_amount, round_amount))
    end

    for i in eachindex(pools)
        desired = buy_remaining[i]
        desired <= atol && continue
        feasible = affordable_buy_amount(pools[i], desired, cash; atol=atol)
        feasible <= atol && continue
        bought, cost, _ = buy_exact!(pools[i], feasible)
        bought <= atol && continue
        holdings[i] += bought
        cash -= cost
        buy_remaining[i] = max(buy_remaining[i] - bought, 0.0)
        executed_direct_buy += bought
        counts = ReplayActionCounts(counts.direct_buys + 1, counts.direct_sells, counts.mint_rounds, counts.direct_merge_rounds, counts.buy_merge_rounds)
        push!(actions, replay_trade_action(:buy, i, bought, cost))
    end

    final_raw_ev = cash + dot(benchmark.predictions, holdings)
    desired_volume = sum(route.direct_buys) + sum(route.direct_sells) + route.mint + route.merge
    executed_volume = executed_direct_buy + executed_direct_sell + executed_mint + executed_merge
    fill_fraction = desired_volume <= atol ? 1.0 : clamp(executed_volume / desired_volume, 0.0, 1.0)

    return ReplayReport(
        cash,
        holdings,
        final_raw_ev,
        fill_fraction,
        ReplayResiduals(sum(buy_remaining), sum(sell_remaining), mint_remaining, merge_remaining),
        counts,
        executed_direct_buy,
        executed_direct_sell,
        executed_mint,
        executed_merge,
        actions,
    )
end

function solve_mixed_benchmark(benchmark; max_doublings::Int=6, kwargs...)
    split_bound = benchmark.initial_split_bound
    for doubling in 0:max_doublings
        split_edge = SplitMergeEdge(copy(benchmark.split_nodes), split_bound)
        result = solve_router_result(
            vcat(benchmark.amm_edges, Edge[split_edge]),
            benchmark.objective;
            n=benchmark.n,
            kwargs...,
        )
        w = split_flow_size(result.solver.xs[end])
        w < 0.8 * split_bound && return (
            solver=result.solver,
            solve_time=result.solve_time,
            split_bound=split_bound,
            split_flow=w,
            doublings=doubling,
        )
        split_bound *= 2
    end
    error("split/merge bound remained near-active after $(max_doublings) doublings")
end

function solve_direct_benchmark(benchmark; method::Symbol=:bfgs_exact, kwargs...)
    return solve_router_result(benchmark.amm_edges, benchmark.objective; n=benchmark.n, method=method, kwargs...)
end

function solve_benchmark_case(
    benchmark::DeepTradingBenchmarkCase;
    method::Symbol=:auto,
    pgtol::Float64=1e-6,
    max_iter::Int=10_000,
    max_fun::Int=20_000,
)
    direct = solve_direct_benchmark(
        benchmark;
        method=method,
        pgtol=pgtol,
        max_iter=max_iter,
        max_fun=max_fun,
    )
    mixed = solve_mixed_benchmark(
        benchmark;
        method=method,
        pgtol=pgtol,
        max_iter=max_iter,
        max_fun=max_fun,
    )

    direct_route = desired_route_from_solver(benchmark, direct.solver)
    mixed_route = desired_route_from_solver(benchmark, mixed.solver)
    direct_replay = replay_desired_route(benchmark, direct_route)
    mixed_replay = replay_desired_route(benchmark, mixed_route)
    direct_fees = price_replay_report(direct_replay)
    mixed_fees = price_replay_report(mixed_replay)

    direct_certified = !isnothing(direct.solver.certificate) && direct.solver.certificate.passed
    mixed_certified = !isnothing(mixed.solver.certificate) && mixed.solver.certificate.passed
    direct_raw_upper_ev = direct_certified ? direct_route.raw_upper_ev : NaN
    mixed_raw_upper_ev = mixed_certified ? mixed_route.raw_upper_ev : NaN
    direct_net_ev = direct_replay.final_raw_ev - direct_fees.total_fee
    mixed_net_ev = mixed_replay.final_raw_ev - mixed_fees.total_fee
    best_family = benchmark_best_family(direct_net_ev, mixed_net_ev)
    best_net_ev = best_family == "mixed" ? mixed_net_ev : direct_net_ev

    return (
        direct=direct,
        mixed=mixed,
        direct_route=direct_route,
        mixed_route=mixed_route,
        direct_replay=direct_replay,
        mixed_replay=mixed_replay,
        direct_fees=direct_fees,
        mixed_fees=mixed_fees,
        direct_certified=direct_certified,
        mixed_certified=mixed_certified,
        direct_raw_upper_ev=direct_raw_upper_ev,
        mixed_raw_upper_ev=mixed_raw_upper_ev,
        direct_net_ev=direct_net_ev,
        mixed_net_ev=mixed_net_ev,
        best_family=best_family,
        best_net_ev=best_net_ev,
    )
end

function active_edge_count(s::Solver; atol=1e-8)
    return count(i -> ForecastFlows.edge_is_active(s.xs[i]; atol=atol), eachindex(s.edges))
end

@testset "prediction market routing" begin
    @testset "arbitrary hyperedge indexing" begin
        struct EchoEdge{T} <: Edge{T}
            Ai::Vector{Int}
        end

        function ForecastFlows.find_arb!(x::Vector{T}, e::EchoEdge{T}, η::AbstractVector{T}) where T
            x .= η
            return nothing
        end

        s = Solver(
            flow_objective=LinearNonnegative([0.1, 0.1, 0.1]),
            edges=Edge[EchoEdge{Float64}([2, 3, 1])],
            n=3,
        )
        s.ν .= [1.0, 2.0, 3.0]
        ForecastFlows.find_arb!(s)
        ForecastFlows.netflows!(s)
        @test s.xs[1] ≈ [2.0, 3.0, 1.0] atol=1e-12
        @test s.y ≈ [1.0, 2.0, 3.0] atol=1e-12
    end

    @testset "no-arbitrage baseline" begin
        s = solve_router(
            Edge[
                ProductTwoCoin([100.0, 200.0], 1.0, [1, 2]),
                ProductTwoCoin([100.0, 200.0], 1.0, [1, 3]),
                SplitMergeEdge([1, 2, 3], 2.0),
            ],
            LinearNonnegative([1.0, 0.5, 0.5]);
            n=3,
        )
        @test norm(s.y) ≤ 1e-8
        @test all(norm(x) ≤ 1e-8 for x in s.xs)
    end

    @testset "synthetic buy beats direct buy" begin
        obj = Swap(2, 1, 1.0, 3)
        base_edges = Edge[
            ProductTwoCoin([200.0, 100.0], 1.0, [1, 2]),
            ProductTwoCoin([100.0, 200.0], 1.0, [1, 3]),
        ]

        direct = solve_router(base_edges, obj; n=3)
        routed = solve_router(vcat(base_edges, Edge[SplitMergeEdge([1, 2, 3], 2.0)]), obj; n=3)

        @test routed.y[2] > direct.y[2] + 1e-3
        @test routed.xs[3] ≈ [-2.0, 2.0, 2.0] atol=1e-8
        @test routed.xs[2][2] < -1e-8
    end

    @testset "synthetic sell beats direct sell" begin
        obj = Swap(1, 2, 1.0, 3)
        base_edges = Edge[
            ProductTwoCoin([50.0, 200.0], 1.0, [1, 2]),
            ProductTwoCoin([100.0, 200.0], 1.0, [1, 3]),
        ]

        direct = solve_router(base_edges, obj; n=3)
        routed = solve_router(vcat(base_edges, Edge[SplitMergeEdge([1, 2, 3], 2.0)]), obj; n=3)

        @test routed.y[1] > direct.y[1] + 1e-3
        @test routed.xs[3] ≈ [2.0, -2.0, -2.0] atol=1e-8
        @test routed.xs[2][2] > 1e-8
    end

    @testset "synthetic route reduces exact-output acquisition cost" begin
        obj = SwapExactOutput(2, 1, 1.0, 3)
        base_edges = Edge[
            ProductTwoCoin([200.0, 100.0], 1.0, [1, 2]),
            ProductTwoCoin([100.0, 200.0], 1.0, [1, 3]),
        ]

        direct = solve_router(base_edges, obj; n=3)
        routed = solve_router(vcat(base_edges, Edge[SplitMergeEdge([1, 2, 3], 2.0)]), obj; n=3)

        @test isapprox(direct.y[2], 1.0; atol=1e-6)
        @test isapprox(routed.y[2], 1.0; atol=1e-6)
        @test routed.y[1] > direct.y[1] + 1e-3
        @test routed.xs[3] ≈ [-2.0, 2.0, 2.0] atol=1e-8
    end

    @testset "structural arbitrage" begin
        overround = solve_router(
            Edge[
                ProductTwoCoin([200.0, 100.0], 1.0, [1, 2]),
                ProductTwoCoin([200.0, 100.0], 1.0, [1, 3]),
                SplitMergeEdge([1, 2, 3], 2.0),
            ],
            LinearNonnegative([1.0, 0.5, 0.5]);
            n=3,
        )
        @test overround.y[1] > 0.0
        @test overround.xs[3] ≈ [-2.0, 2.0, 2.0] atol=1e-8

        underround = solve_router(
            Edge[
                ProductTwoCoin([100.0, 250.0], 1.0, [1, 2]),
                ProductTwoCoin([100.0, 250.0], 1.0, [1, 3]),
                SplitMergeEdge([1, 2, 3], 2.0),
            ],
            LinearNonnegative([1.0, 0.4, 0.4]);
            n=3,
        )
        @test underround.y[1] > 0.0
        @test underround.xs[3] ≈ [2.0, -2.0, -2.0] atol=1e-8
    end

    @testset "endowment direct-only rebalance" begin
        obj = EndowmentLinear([1.0, 0.25, 0.75], [0.0, 1.0, 0.0])
        s = solve_router(
            Edge[
                ProductTwoCoin([200.0, 100.0], 1.0, [1, 2]),
                ProductTwoCoin([100.0, 200.0], 1.0, [1, 3]),
            ],
            obj;
            n=3,
        )

        @test s.y[2] < -1e-4
        @test s.y[3] > 1e-4
        @test all(s.y .>= -obj.h0 .- 1e-8)
        @test isfinite(s.certificate.duality_gap)
    end

    @testset "endowment mixed rebalance beats direct-only" begin
        obj = EndowmentLinear([1.0, 0.7, 0.3], [1.0, 0.0, 0.0])
        base_edges = Edge[
            ProductTwoCoin([160.0, 200.0], 1.0, [1, 2]),
            ProductTwoCoin([100.0, 200.0], 1.0, [1, 3]),
        ]

        direct = solve_router(base_edges, obj; n=3)
        mixed = solve_router(vcat(base_edges, Edge[SplitMergeEdge([1, 2, 3], 2.0)]), obj; n=3)

        @test primal_objective(mixed) > primal_objective(direct) + 1e-4
        @test mixed.certificate.passed
        @test all(mixed.y .>= -obj.h0 .- 1e-5)
        @test ForecastFlows.edge_is_active(mixed.xs[end])
    end

    @testset "split merge recovery" begin
        struct FixedFlowEdge{T} <: Edge{T}
            Ai::Vector{Int}
        end

        s = Solver(
            flow_objective=NonpositiveQuadratic([0.6, 0.9, 0.9]),
            edges=Edge[SplitMergeEdge([1, 2, 3], 2.0)],
            n=3,
        )
        s.ν .= [1.0, 0.5, 0.5]
        recovered = recover_primal!(s)
        @test recovered
        @test s.xs[1] ≈ [-0.4, 0.4, 0.4] atol=1e-8
        @test s.y ≈ [-0.4, 0.4, 0.4] atol=1e-8

        merge_only = Solver(
            flow_objective=BasketLiquidation(1, [0.0, 0.4, 0.4]),
            edges=Edge[SplitMergeEdge([1, 2, 3], 2.0)],
            n=3,
        )
        merge_only.ν .= [1.0, 0.5, 0.5]
        @test recover_primal!(merge_only)
        @test merge_only.xs[1] ≈ [0.4, -0.4, -0.4] atol=1e-8

        impossible = Solver(
            flow_objective=BasketLiquidation(1, [0.0, 0.3, 0.1]),
            edges=Edge[SplitMergeEdge([1, 2, 3], 2.0)],
            n=3,
        )
        impossible.ν .= [1.0, 0.5, 0.5]
        @test recover_primal!(impossible)
        cert = certify_solution(impossible; gap_tol=1.0, target_tol=1e-8, bound_tol=1e-8)
        @test !cert.passed
        @test cert.target_residual > 1e-2

        endowment = Solver(
            flow_objective=EndowmentLinear([1.0, 0.6, 0.4], [1.0, 0.0, 0.5]),
            edges=Edge[FixedFlowEdge{Float64}([1, 2, 3]), SplitMergeEdge([1, 2, 3], 2.0)],
            n=3,
        )
        endowment.xs[1] .= [0.6, -1.1, -0.3]
        endowment.ν .= [1.0, 0.5, 0.5]
        @test recover_primal!(endowment)
        @test endowment.xs[2] ≈ [-1.1, 1.1, 1.1] atol=1e-8
        @test all(endowment.y .>= -endowment.flow_objective.h0 .- 1e-8)
    end

    @testset "smoothed split/merge oracle" begin
        e_smooth = ForecastFlows.SplitMergeEdge([1, 2, 3], 100.0; μ=0.01)
        x = zeros(3)

        # Large gap → saturates at B (linear regime)
        ForecastFlows.find_arb!(x, e_smooth, [0.5, 0.8, 0.9])
        @test x[1] ≈ -100.0
        @test x[2] ≈ 100.0

        # Small gap → smoothed intermediate flow (quadratic regime)
        # gap = 0.502 + 0.502 - 1.0 = 0.004, w = 0.004/0.01 = 0.4
        ForecastFlows.find_arb!(x, e_smooth, [1.0, 0.502, 0.502])
        @test x[1] ≈ -0.4 atol=1e-10

        # Zero gap → zero flow
        ForecastFlows.find_arb!(x, e_smooth, [1.0, 0.5, 0.5])
        @test all(x .≈ 0.0)

        # Nonsmooth flag
        @test !ForecastFlows.is_nonsmooth(e_smooth)
        @test ForecastFlows.is_nonsmooth(ForecastFlows.SplitMergeEdge([1, 2, 3], 100.0))

        # μ=0 default preserves original behavior
        e_exact = ForecastFlows.SplitMergeEdge([1, 2, 3], 100.0)
        @test e_exact.μ == 0.0
    end

    @testset "smooth solver parity" begin
        obj = Swap(2, 1, 1.0, 3)
        edges = Edge[
            ProductTwoCoin([200.0, 100.0], 0.997, [1, 2]),
            ProductTwoCoin([100.0, 200.0], 0.997, [1, 3]),
        ]

        s_bfgs = Solver(flow_objective=obj, edges=edges, n=3)
        solve!(s_bfgs; method=:bfgs_exact, verbose=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000)
        @test s_bfgs.certificate.passed

        s_lbfgsb = Solver(flow_objective=obj, edges=edges, n=3)
        solve!(s_lbfgsb; method=:lbfgsb, verbose=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000)
        @test s_lbfgsb.certificate.passed

        @test s_bfgs.y ≈ s_lbfgsb.y atol=1e-4
        @test primal_objective(s_bfgs) ≈ primal_objective(s_lbfgsb) atol=1e-5
    end

    @testset "fixed gas wrapper" begin
        useful = Solver(
            flow_objective=SwapExactOutput(2, 1, 0.4, 3),
            edges=Edge[
                ProductTwoCoin([200.0, 100.0], 1.0, [1, 2]),
                ProductTwoCoin([100.0, 200.0], 1.0, [1, 3]),
                SplitMergeEdge([1, 2, 3], 1.0),
            ],
            n=3,
        )
        solve!(useful; verbose=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000)

        gas_kept = Solver(
            flow_objective=SwapExactOutput(2, 1, 0.4, 3),
            edges=Edge[
                ProductTwoCoin([200.0, 100.0], 1.0, [1, 2]),
                ProductTwoCoin([100.0, 200.0], 1.0, [1, 3]),
                SplitMergeEdge([1, 2, 3], 1.0),
            ],
            n=3,
        )
        kept = solve_with_fixed_gas!(
            gas_kept,
            FixedGasModel([0.0, 0.0, 0.05]);
            pgtol=1e-8,
            max_iter=5_000,
            max_fun=10_000,
        )
        @test kept.kept_edges[3]
        @test gas_kept.certificate.passed
        @test isapprox(gas_kept.y[2], 0.4; atol=1e-5)

        gas_pruned = Solver(
            flow_objective=LinearNonnegative([1.0, 0.5, 0.5]),
            edges=Edge[
                ProductTwoCoin([200.0, 100.0], 1.0, [1, 2]),
                ProductTwoCoin([200.0, 100.0], 1.0, [1, 3]),
                SplitMergeEdge([1, 2, 3], 2.0),
            ],
            n=3,
        )
        pruned = solve_with_fixed_gas!(
            gas_pruned,
            FixedGasModel([0.0, 0.0, 6.0]);
            pgtol=1e-8,
            max_iter=5_000,
            max_fun=10_000,
        )
        @test pruned.kept_edges == BitVector([true, true, false])
        @test all(norm(x) ≤ 1e-8 for x in gas_pruned.xs)
        @test norm(gas_pruned.y) ≤ 1e-8

        tiny_zero_face = Solver(
            flow_objective=NonpositiveQuadratic([5e-5, 1e-4, 1e-4]),
            edges=Edge[SplitMergeEdge([1, 2, 3], 1.0)],
            n=3,
        )
        solve_with_fixed_gas!(
            tiny_zero_face,
            FixedGasModel([0.0]);
            method=:bfgs_exact,
            pgtol=1e-8,
            max_iter=5_000,
            max_fun=10_000,
        )
        @test all(iszero, tiny_zero_face.xs[1])
        @test all(iszero, tiny_zero_face.y)
        @test !tiny_zero_face.certificate.passed
        @test occursin("target residual", tiny_zero_face.certificate.message)
    end

    @testset "large smoke" begin
        Random.seed!(7)
        n_outcomes = 96
        n = n_outcomes + 1
        edges = Edge[]
        for i in 1:n_outcomes
            push!(edges, ProductTwoCoin([100.0 + rand(), 200.0 + rand()], 0.997, [1, i + 1]))
        end
        push!(edges, SplitMergeEdge(collect(1:n), 1.0))

        s = Solver(
            flow_objective=Swap(2, 1, 1.0, n),
            edges=edges,
            n=n,
        )
        solve!(s, verbose=false, pgtol=1e-6, max_iter=2_500, max_fun=5_000)

        @test s.certificate.passed
        @test all(isfinite, s.y)
        @test abs(s.y[1] + 1.0) ≤ 1e-4
        @test s.y[2] ≥ 0.0
        @test norm(s.y[3:end]) ≤ 1e-2
    end

    @testset "route replay" begin
        γ = 0.999
        markets = [
            SingleTickMarketSpec(0.70, 0.95, 0.35, 50.0, γ, 1, 92_108, true),
            SingleTickMarketSpec(0.30, 0.85, 0.10, 50.0, γ, 1, 92_108, true),
        ]
        benchmark = toy_benchmark_case([0.45, 0.55], [0.70, 0.30], [1.0, 1.0], 0.0, markets; case_id="replay")

        direct_sell = replay_desired_route(
            benchmark,
            RouteDesiderata([0.0, 0.0], [0.4, 0.0], 0.0, 0.0, 0.0),
        )
        expected_sell = sell_preview(ReplaySingleTickPool(markets[1].current_price, markets[1].buy_limit_price, markets[1].sell_limit_price, markets[1].liquidity_raw, γ), 0.4)
        @test direct_sell.final_cash ≈ expected_sell[2] atol=1e-10
        @test direct_sell.final_holdings[1] ≈ 0.6 atol=1e-10

        cash_clipped = replay_desired_route(
            benchmark,
            RouteDesiderata([2.0, 0.0], [0.0, 0.0], 0.0, 0.0, 0.0),
        )
        @test cash_clipped.executed_direct_buy ≤ 1e-9
        @test cash_clipped.residuals.direct_buy ≥ 2.0 - 1e-9

        mint_cash_clipped = replay_desired_route(
            toy_benchmark_case([0.45, 0.55], [0.70, 0.30], [0.0, 0.0], 0.3, markets; case_id="mint_sell"),
            RouteDesiderata([0.0, 0.0], [0.0, 0.0], 1.0, 0.0, 0.0),
        )
        @test mint_cash_clipped.executed_mint ≈ 0.3 atol=1e-9
        @test mint_cash_clipped.residuals.mint ≥ 0.7 - 1e-9

        tight_markets = [
            SingleTickMarketSpec(0.70, 0.95, 0.35, 50.0, γ, 1, 92_108, true),
            SingleTickMarketSpec(0.90, 0.95, 0.80, 1.0, γ, 1, 92_108, true),
        ]
        mint_sell = replay_desired_route(
            toy_benchmark_case([0.45, 0.55], [0.70, 0.90], [0.0, 0.0], 1.0, tight_markets; case_id="mint_sell_tight"),
            RouteDesiderata([0.0, 0.0], [1.0, 1.0], 1.0, 0.0, 0.0),
        )
        @test mint_sell.executed_mint ≈ 1.0 atol=1e-9
        @test mint_sell.residuals.direct_sell > 0.0

        buy_merge = replay_desired_route(
            toy_benchmark_case([0.45, 0.55], [0.70, 0.90], [1.0, 0.0], 0.05, tight_markets; case_id="buy_merge"),
            RouteDesiderata([0.0, 1.0], [0.0, 0.0], 0.0, 1.0, 0.0),
        )
        @test buy_merge.executed_merge < 1.0 - 1e-6
        @test buy_merge.residuals.merge > 0.0
        @test all(buy_merge.final_holdings .>= -1e-9)
        @test buy_merge.final_cash >= -1e-9
    end

    @testset "benchmark pricing formulas" begin
        direct_buy_fee = price_execution_groups([replay_execution_group(:direct_buy, 1, 0, 1.0, 0.0)])
        @test direct_buy_fee.total_l2_gas_units == benchmark_direct_buy_l2_units
        @test direct_buy_fee.total_calldata_bytes == 434
        @test direct_buy_fee.total_fee ≈ 0.00017516765510458535 atol=1e-18

        direct_sell_fee = price_execution_groups([replay_execution_group(:direct_sell, 0, 1, 0.0, 1.0)])
        @test direct_sell_fee.total_l2_gas_units == benchmark_direct_sell_l2_units
        @test direct_sell_fee.total_calldata_bytes == 434
        @test direct_sell_fee.total_fee ≈ 0.00011670304017958536 atol=1e-18

        direct_merge_fee = price_execution_groups([replay_execution_group(:direct_merge, 0, 0, 0.0, 1.0)])
        @test direct_merge_fee.total_l2_gas_units == benchmark_direct_merge_l2_units
        @test direct_merge_fee.total_calldata_bytes == 430
        @test direct_merge_fee.total_fee ≈ 6.67765498404878e-5 atol=1e-18

        mint_sell_fee = price_execution_groups([replay_execution_group(:mint_sell, 0, 1, 1.0, 0.4)])
        @test mint_sell_fee.total_l2_gas_units == benchmark_mint_sell_base_l2_units + benchmark_mint_sell_per_sell_leg_l2_units
        @test mint_sell_fee.total_calldata_bytes == 594
        @test mint_sell_fee.total_fee ≈ 0.0002087026634184878 atol=1e-18

        buy_merge_fee = price_execution_groups([replay_execution_group(:buy_merge, 1, 0, 0.4, 1.0)])
        @test buy_merge_fee.total_l2_gas_units == benchmark_buy_merge_base_l2_units + benchmark_buy_merge_per_buy_leg_l2_units
        @test buy_merge_fee.total_calldata_bytes == 594
        @test buy_merge_fee.total_fee ≈ 0.0002045169542184878 atol=1e-18

        packed_direct_buys = price_execution_groups([
            replay_execution_group(:direct_buy, 1, 0, 0.4, 0.0),
            replay_execution_group(:direct_buy, 1, 0, 0.4, 0.0),
        ])
        @test packed_direct_buys.group_count == 2
        @test packed_direct_buys.tx_count == 1
        @test packed_direct_buys.total_calldata_bytes == 658
        @test packed_direct_buys.total_fee ≈ 0.00034929968134404874 atol=1e-18
    end

    @testset "deep trading fixture translation" begin
        @test dt_case_ids == sort!(String.(collect(propertynames(dt_expected_payload))))
        @test dt_case_ids == sort!(String.(collect(propertynames(dt_net_expected_payload))))

        for case_id in dt_case_ids
            benchmark = build_case_from_deep_trading(case_id)
            raw_expected = deep_trading_raw_expected(case_id)
            net_expected = deep_trading_net_expected(case_id)

            @test benchmark.case_id == case_id
            @test benchmark.objective isa EndowmentLinear
            @test length(benchmark.markets) == length(benchmark.predictions)
            @test length(benchmark.amm_edges) == length(benchmark.predictions)
            @test sum(benchmark.predictions) ≈ 1.0 atol=1e-12
            @test benchmark.deep_trading_direct_ev ≈ raw_expected.direct_ev atol=1e-12
            @test benchmark.deep_trading_mixed_ev ≈ raw_expected.mixed_ev atol=1e-12
            @test benchmark.deep_trading_full_rebalance_only_ev ≈ raw_expected.full_rebalance_only_ev atol=1e-12
            @test net_expected.best_family in ("direct", "mixed")
            @test isfinite(net_expected.direct_net_ev)
            @test isfinite(net_expected.mixed_net_ev)
            @test isfinite(net_expected.best_net_ev)
        end

        benchmark = build_case_from_deep_trading(dt_focus_case_id)
        raw_expected = deep_trading_raw_expected(dt_focus_case_id)
        @test benchmark.initial_ev ≈ 150.22005815295148 atol=1e-9
        @test benchmark.cash0 ≈ 150.0 atol=1e-12
        @test sum(benchmark.holdings0) ≈ 20.0 atol=1e-12
        @test sum(benchmark.current_prices) ≈ 1.0442842940877832 atol=1e-12
        @test all(==(1), benchmark.tick_lo)
        @test all(==(92_108), benchmark.tick_hi)
        @test benchmark.deep_trading_direct_ev ≈ raw_expected.direct_ev atol=1e-12
        @test benchmark.deep_trading_mixed_ev ≈ raw_expected.mixed_ev atol=1e-12
        @test benchmark.deep_trading_full_rebalance_only_ev ≈ raw_expected.full_rebalance_only_ev atol=1e-12
    end

    @testset "deep trading single-tick parity" begin
        for case_id in dt_case_ids
            benchmark = build_case_from_deep_trading(case_id)
            for i in eachindex(benchmark.markets)
                market = benchmark.markets[i]
                canonical_pool = ReplaySingleTickPool(
                    market.current_price,
                    market.buy_limit_price,
                    market.sell_limit_price,
                    market.liquidity_raw,
                    market.γ,
                )
                edge = benchmark.amm_edges[i]::SingleTickBenchmarkEdge{Float64}
                edge_pool = edge_derived_pool(edge)
                @test edge_pool.current_price ≈ canonical_pool.current_price atol=1e-12
                @test edge_pool.buy_limit_price ≈ canonical_pool.buy_limit_price atol=1e-12
                @test edge_pool.sell_limit_price ≈ canonical_pool.sell_limit_price atol=1e-12
                @test edge_pool.liquidity_raw ≈ canonical_pool.liquidity_raw atol=1e-12
                @test max_buy_tokens(edge_pool) ≈ max_buy_tokens(canonical_pool) atol=1e-10
                @test max_sell_tokens(edge_pool) ≈ max_sell_tokens(canonical_pool) atol=1e-10
                for frac in (0.25, 0.5, 0.9)
                    buy_amount = frac * max_buy_tokens(canonical_pool)
                    sell_amount = frac * max_sell_tokens(canonical_pool)
                    edge_buy = buy_preview(edge_pool, buy_amount)
                    pool_buy = buy_preview(canonical_pool, buy_amount)
                    @test edge_buy[1] ≈ pool_buy[1] atol=1e-10
                    @test edge_buy[2] ≈ pool_buy[2] atol=1e-10
                    @test edge_buy[3] ≈ pool_buy[3] atol=1e-10

                    edge_sell = sell_preview(edge_pool, sell_amount)
                    pool_sell = sell_preview(canonical_pool, sell_amount)
                    @test edge_sell[1] ≈ pool_sell[1] atol=1e-10
                    @test edge_sell[2] ≈ pool_sell[2] atol=1e-10
                    @test edge_sell[3] ≈ pool_sell[3] atol=1e-10
                end

                x = zeros(2)
                for frac in (0.25, 0.5, 0.9)
                    buy_target = canonical_pool.current_price + frac * (canonical_pool.buy_limit_price - canonical_pool.current_price)
                    expected_buy = buy_to_price(canonical_pool, buy_target)
                    ForecastFlows.find_arb!(x, edge, [1.0, buy_target / canonical_pool.γ])
                    @test x[1] ≈ -expected_buy[2] atol=1e-10
                    @test x[2] ≈ expected_buy[1] atol=1e-10

                    sell_target = canonical_pool.current_price - frac * (canonical_pool.current_price - canonical_pool.sell_limit_price)
                    expected_sell = sell_to_price(canonical_pool, sell_target)
                    ForecastFlows.find_arb!(x, edge, [1.0, canonical_pool.γ * sell_target])
                    @test x[1] ≈ expected_sell[2] atol=1e-10
                    @test x[2] ≈ -expected_sell[1] atol=1e-10
                end
            end
        end
    end

    @testset "public UniV3 single-tick parity" begin
        for case_id in ("two_pool_single_tick_direct_only", "small_bundle_mixed_case")
            benchmark = build_case_from_deep_trading(case_id)
            problem = public_problem_from_benchmark(benchmark)
            for (i, market) in enumerate(benchmark.markets)
                edge = ForecastFlows._build_prediction_market_edge(problem.markets[i], i)
                x = zeros(2)
                canonical_pool = ReplaySingleTickPool(
                    market.current_price,
                    market.buy_limit_price,
                    market.sell_limit_price,
                    market.liquidity_raw,
                    market.γ,
                )
                for frac in (0.25, 0.5, 0.9)
                    buy_target = canonical_pool.current_price + frac * (canonical_pool.buy_limit_price - canonical_pool.current_price)
                    expected_buy = buy_to_price(canonical_pool, buy_target)
                    ForecastFlows.find_arb!(x, edge, [1.0, buy_target / canonical_pool.γ])
                    @test x[1] ≈ -expected_buy[2] atol=1e-10
                    @test x[2] ≈ expected_buy[1] atol=1e-10

                    sell_target = canonical_pool.current_price - frac * (canonical_pool.current_price - canonical_pool.sell_limit_price)
                    expected_sell = sell_to_price(canonical_pool, sell_target)
                    ForecastFlows.find_arb!(x, edge, [1.0, canonical_pool.γ * sell_target])
                    @test x[1] ≈ expected_sell[2] atol=1e-10
                    @test x[2] ≈ -expected_sell[1] atol=1e-10
                end
            end
        end
    end

    @testset "public UniV3 multi-band parity" begin
        public_spec = UniV3MarketSpec(
            "u_multi",
            "YES",
            0.72,
            [
                UniV3LiquidityBand(1.0, 5.0),
                UniV3LiquidityBand(0.6, 15.0),
                UniV3LiquidityBand(0.3, 10.0),
                UniV3LiquidityBand(0.1, 0.0),
            ],
            0.999,
        )
        public_edge = ForecastFlows._build_prediction_market_edge(public_spec, 1)
        internal_edge = UniV3(
            inv(0.72),
            [inv(0.1), inv(0.3), inv(0.6), inv(1.0)],
            [100.0, 225.0, 25.0, 0.0],
            0.999,
            [1, 2],
        )

        @test public_edge.lower_ticks == internal_edge.lower_ticks
        @test public_edge.liquidity == internal_edge.liquidity

        x_public = zeros(2)
        x_internal = zeros(2)
        for target in (0.81, 0.92)
            ForecastFlows.find_arb!(x_public, public_edge, [1.0, target / public_spec.fee_multiplier])
            ForecastFlows.find_arb!(x_internal, internal_edge, [1.0, target / public_spec.fee_multiplier])
            @test x_public ≈ x_internal atol=1e-10
        end

        for target in (0.58, 0.36)
            ForecastFlows.find_arb!(x_public, public_edge, [1.0, public_spec.fee_multiplier * target])
            ForecastFlows.find_arb!(x_internal, internal_edge, [1.0, public_spec.fee_multiplier * target])
            @test x_public ≈ x_internal atol=1e-10
        end

        gapped_spec = UniV3MarketSpec(
            "u_gap",
            "YES",
            0.8,
            [
                UniV3LiquidityBand(1.0, 5.0),
                UniV3LiquidityBand(0.75, 0.0),
                UniV3LiquidityBand(0.5, 8.0),
                UniV3LiquidityBand(0.25, 0.0),
            ],
            0.999,
        )
        gapped_edge = ForecastFlows._build_prediction_market_edge(gapped_spec, 1)
        gapped_internal = UniV3(
            inv(0.8),
            [inv(0.25), inv(0.5), inv(0.75), inv(1.0)],
            [64.0, 0.0, 25.0, 0.0],
            0.999,
            [1, 2],
        )

        @test gapped_edge.lower_ticks == gapped_internal.lower_ticks
        @test gapped_edge.liquidity == gapped_internal.liquidity

        x_public_gap = zeros(2)
        x_internal_gap = zeros(2)
        for target in (0.9, 0.6, 0.4)
            η = target > gapped_spec.current_price ?
                [1.0, target / gapped_spec.fee_multiplier] :
                [1.0, gapped_spec.fee_multiplier * target]
            ForecastFlows.find_arb!(x_public_gap, gapped_edge, η)
            ForecastFlows.find_arb!(x_internal_gap, gapped_internal, η)
            @test x_public_gap ≈ x_internal_gap atol=1e-10
        end
    end

    @testset "public prediction-market facade" begin
        expected_public_interfaces = [
            "PredictionMarketWorkspace",
            "PredictionMarketFixedGasModel",
            "solve_prediction_market!",
            "compare_prediction_market_families!",
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

        @testset "input validation" begin
            @test_throws ArgumentError OutcomeSpec("", 0.5, 0.0)
            @test_throws ArgumentError ConstantProductMarketSpec("", "YES", 100.0, 100.0, 1.0)
            @test_throws ArgumentError ConstantProductMarketSpec("m1", "", 100.0, 100.0, 1.0)
            @test_throws MethodError ConstantProductMarketSpec("m1", 1, 100.0, 100.0, 1.0)
            @test_throws MethodError UniV3MarketSpec("u1", "YES", 1.0, [0.5, 1.0], [100.0, 100.0], 0.997)
            @test_throws ArgumentError UniV3MarketSpec("u1", "YES", 0.5, [UniV3LiquidityBand(1.0, 0.0)], 0.997)
            @test_throws ArgumentError UniV3MarketSpec("u1", "YES", 0.75, [UniV3LiquidityBand(1.0, 0.0), UniV3LiquidityBand(0.5, 10.0)], 0.997)
            @test_throws ArgumentError UniV3MarketSpec(
                "u_gap",
                "YES",
                0.75,
                [UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.75, 0.0), UniV3LiquidityBand(0.5, 5.0)],
                0.997,
            )
            @test_throws ArgumentError UniV3MarketSpec("u1", "YES", 0.75, [UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.5, 0.0)], 0.0)
            @test_throws ArgumentError UniV3MarketSpec("u1", "YES", 0.75, [UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.5, 0.0)], 1.1)
            @test_throws ArgumentError UniV3MarketSpec("u1", "YES", 0.75, [UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.5, 0.0)], -0.1)
            @test_throws MethodError PredictionMarketProblem(
                [0.5, 0.5],
                1.0,
                [0.0, 0.0],
                [
                    ConstantProductMarketSpec("m1", "YES", 100.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m2", "NO", 100.0, 100.0, 1.0),
                ],
            )
            @test_throws MethodError solve_prediction_market(
                PredictionMarketProblem(
                    [OutcomeSpec("YES", 0.5, 0.0)],
                    1.0,
                    [ConstantProductMarketSpec("m1", "YES", 100.0, 100.0, 1.0)],
                );
                pgtol=1e-8,
            )
            @test_throws ArgumentError PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.5, 0.0),
                    OutcomeSpec("YES", 0.5, 0.0),
                ],
                1.0,
                [ConstantProductMarketSpec("m1", "YES", 100.0, 100.0, 1.0)],
            )
            @test_throws ArgumentError PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.5, 0.0),
                    OutcomeSpec("NO", 0.5, 0.0),
                ],
                1.0,
                [ConstantProductMarketSpec("m1", "MAYBE", 100.0, 100.0, 1.0)],
            )
            @test_throws ArgumentError PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.5, 0.0),
                    OutcomeSpec("NO", 0.5, 0.0),
                ],
                1.0,
                [
                    ConstantProductMarketSpec("m1", "YES", 100.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m1", "NO", 100.0, 100.0, 1.0),
                ],
            )

            zero_market_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.6, 0.0),
                    OutcomeSpec("NO", 0.4, 0.0),
                ],
                1.0,
                Any[],
            )
            one_market_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.6, 0.0),
                    OutcomeSpec("NO", 0.4, 0.0),
                ],
                1.0,
                [ConstantProductMarketSpec("m_yes", "YES", 50.0, 100.0, 1.0)],
            )
            multi_pool_problem = PredictionMarketProblem(
                [OutcomeSpec("YES", 0.25, 200.0)],
                0.0,
                [
                    ConstantProductMarketSpec("m_yes_a", "YES", 100.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m_yes_b", "YES", 60.0, 30.0, 1.0),
                ],
            )
            @test isempty(zero_market_problem.markets)
            @test length(one_market_problem.markets) == 1
            @test length(multi_pool_problem.markets) == 2
            @test all(spec -> spec.outcome_id == "YES", multi_pool_problem.markets)
            @test_throws ArgumentError solve_prediction_market(
                zero_market_problem;
                mode=:direct_only,
                gas_model=PredictionMarketFixedGasModel([0.1], 0.2),
            )
        end

        @testset "outcome_id and JSON roundtrip" begin
            problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES_A", 0.55, 0.0),
                    OutcomeSpec("NO_B", 0.45, 1.0),
                ],
                1.0,
                [
                    ConstantProductMarketSpec("m_yes", "YES_A", 40.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m_no", "NO_B", 70.0, 100.0, 1.0),
                ];
                split_bound=5.0,
            )

            encoded_problem = JSON3.read(JSON3.write(problem))
            @test String(encoded_problem.outcomes[1].outcome_id) == "YES_A"
            @test String(encoded_problem.markets[2].outcome_id) == "NO_B"
            @test hasproperty(encoded_problem, :collateral_balance)
            @test !hasproperty(encoded_problem, :initial_cash)
            @test !hasproperty(encoded_problem.markets[1], :outcome_index)

            result = solve_prediction_market(problem; mode=:direct_only, solver_options=facade_solver_options)
            @test result.outcome_ids == ["YES_A", "NO_B"]
            @test result.trades[1].outcome_id == "YES_A"
            @test !hasproperty(result, :initial_cash)
            @test !hasproperty(result, :final_cash)

            encoded_result = JSON3.read(JSON3.write(result))
            @test String.(collect(encoded_result.outcome_ids)) == ["YES_A", "NO_B"]
            @test String(encoded_result.trades[1].outcome_id) == "YES_A"
            @test hasproperty(encoded_result, :initial_collateral)
            @test hasproperty(encoded_result, :final_collateral)
            @test !hasproperty(encoded_result.trades[1], :outcome_index)
            @test !hasproperty(encoded_result, :initial_cash)
            @test !hasproperty(encoded_result, :final_cash)

            gas_model = PredictionMarketFixedGasModel([0.01, 0.02], 0.03)
            encoded_gas_model = JSON3.read(JSON3.write(gas_model))
            @test Float64.(collect(encoded_gas_model.market_action_costs)) == [0.01, 0.02]
            @test encoded_gas_model.split_merge_action_cost == 0.03

            gas_result = solve_prediction_market(
                problem;
                mode=:direct_only,
                gas_model=gas_model,
                solver_options=facade_solver_options,
            )
            encoded_gas_result = JSON3.read(JSON3.write(gas_result))
            @test encoded_gas_result.estimated_execution_cost >= 0.0
            @test encoded_gas_result.net_ev <= encoded_gas_result.final_ev + 1e-12
        end

        @testset "facade parity" begin
            direct_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.25, 1.0),
                    OutcomeSpec("NO", 0.75, 0.0),
                ],
                0.0,
                [
                    ConstantProductMarketSpec("m1", "YES", 200.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m2", "NO", 100.0, 200.0, 1.0),
                ],
            )
            direct_result = solve_prediction_market(direct_problem; mode=:direct_only, solver_options=facade_solver_options)
            direct_solver = solve_prediction_market_low_level(direct_problem; mode=:direct_only)
            direct_holdings0 = [outcome.initial_holding for outcome in direct_problem.outcomes]
            direct_values = [outcome.fair_value for outcome in direct_problem.outcomes]

            @test direct_result.status == "certified"
            @test direct_result.final_collateral ≈ direct_problem.collateral_balance + direct_solver.y[1] atol=1e-8
            @test direct_result.final_holdings ≈ direct_holdings0 .+ direct_solver.y[2:end] atol=1e-8
            @test direct_result.final_ev ≈ direct_problem.collateral_balance + dot(direct_values, direct_holdings0) + primal_objective(direct_solver) atol=1e-8

            mixed_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.55, 0.0),
                    OutcomeSpec("NO", 0.45, 0.0),
                ],
                1.0,
                [
                    ConstantProductMarketSpec("m1", "YES", 40.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m2", "NO", 70.0, 100.0, 1.0),
                ];
                split_bound=5.0,
            )
            mixed_result = solve_prediction_market(
                mixed_problem;
                mode=:mixed_enabled,
                max_doublings=0,
                throw_on_fail=false,
                solver_options=facade_solver_options,
            )
            mixed_solver = solve_prediction_market_low_level(mixed_problem; mode=:mixed_enabled, split_bound=5.0)
            mixed_holdings0 = [outcome.initial_holding for outcome in mixed_problem.outcomes]
            mixed_values = [outcome.fair_value for outcome in mixed_problem.outcomes]

            # The facade uses Moreau-Yosida smoothing (μ > 0) while the low-level
            # solver uses the exact oracle (μ = 0), so numerical values may differ
            # by O(μ). The parity test validates structural correctness of field
            # extraction, not bit-for-bit numerical match.
            @test mixed_result.status == "uncertified"
            @test mixed_result.final_collateral ≈ mixed_problem.collateral_balance + mixed_solver.y[1] atol=1e-5
            @test mixed_result.final_holdings ≈ mixed_holdings0 .+ mixed_solver.y[2:end] atol=1e-5
            @test mixed_result.final_ev ≈ mixed_problem.collateral_balance + dot(mixed_values, mixed_holdings0) + primal_objective(mixed_solver) atol=1e-5
            @test mixed_result.split_merge.mint ≈ 5.0 atol=1e-2
            @test mixed_result.split_merge.merge ≈ 0.0 atol=1e-2
        end

        @testset "release guardrails" begin
            clipped_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.55, 0.0),
                    OutcomeSpec("NO", 0.45, 0.0),
                ],
                1.0,
                [
                    ConstantProductMarketSpec("m1", "YES", 40.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m2", "NO", 70.0, 100.0, 1.0),
                ];
                split_bound=5.0,
            )
            let err = try
                    solve_prediction_market(clipped_problem; mode=:mixed_enabled, max_doublings=0, solver_options=facade_solver_options)
                    nothing
                catch err
                    err
                end
                @test err isa ForecastFlows._PredictionMarketSolveFailed
                @test occursin("split/merge bound remained near-active", sprint(showerror, err))
            end

            clipped_result = solve_prediction_market(
                clipped_problem;
                mode=:mixed_enabled,
                max_doublings=0,
                throw_on_fail=false,
                solver_options=facade_solver_options,
            )
            @test clipped_result.status == "uncertified"
            @test occursin("split/merge bound remained near-active", clipped_result.certificate.message)
            @test clipped_result.split_merge.mint ≈ 5.0 atol=1e-8

            default_mixed_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.55, 0.0),
                    OutcomeSpec("NO", 0.45, 0.0),
                ],
                1.0,
                [
                    ConstantProductMarketSpec("m1", "YES", 40.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m2", "NO", 70.0, 100.0, 1.0),
                ],
            )
            # The doubling loop now returns the best certified result from an earlier
            # iteration when later doublings fail certification, so this should succeed.
            default_result = solve_prediction_market(default_mixed_problem; mode=:mixed_enabled, solver_options=facade_solver_options)
            @test default_result.status == "certified"

            safe_result = solve_prediction_market(
                default_mixed_problem;
                mode=:mixed_enabled,
                throw_on_fail=false,
                solver_options=facade_solver_options,
            )
            @test safe_result.status == "certified"
            encoded = JSON3.write(safe_result)
            parsed = JSON3.read(encoded)
            @test !isnothing(parsed.certificate.primal_value)
            @test !isnothing(parsed.certificate.duality_gap)

            zero_balance_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.55, 0.0),
                    OutcomeSpec("NO", 0.45, 0.0),
                ],
                0.0,
                [
                    ConstantProductMarketSpec("m1", "YES", 40.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m2", "NO", 70.0, 100.0, 1.0),
                ],
            )
            zero_balance_result = solve_prediction_market(
                zero_balance_problem;
                mode=:mixed_enabled,
                solver_options=facade_solver_options,
            )
            @test zero_balance_result.status == "certified"
            @test zero_balance_result.split_merge.mint == 0.0
            @test zero_balance_result.split_merge.merge == 0.0
            @test maximum(abs, vcat([zero_balance_result.final_collateral], zero_balance_result.final_holdings)) ≤ 5e-6
            @test abs(zero_balance_result.final_ev) ≤ 1e-6
        end

        @testset "zero-market direct-only" begin
            zero_market_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.55, 0.0),
                    OutcomeSpec("NO", 0.45, 0.0),
                ],
                1.0,
                Any[];
                split_bound=5.0,
            )
            stateless_result = solve_prediction_market(
                zero_market_problem;
                mode=:direct_only,
                solver_options=facade_solver_options,
            )
            @test stateless_result.status == "certified"
            @test isempty(stateless_result.trades)
            @test stateless_result.split_merge.mint == 0.0
            @test stateless_result.split_merge.merge == 0.0
            @test stateless_result.initial_collateral == 1.0
            @test stateless_result.final_collateral == 1.0
            @test stateless_result.initial_holdings == [0.0, 0.0]
            @test stateless_result.final_holdings == [0.0, 0.0]
            @test stateless_result.initial_ev == 1.0
            @test stateless_result.final_ev == 1.0
            @test stateless_result.certificate.passed
            @test stateless_result.certificate.primal_value == 0.0
            @test stateless_result.certificate.duality_gap == 0.0

            encoded_problem = JSON3.read(JSON3.write(zero_market_problem))
            @test isempty(encoded_problem.markets)

            encoded_result = JSON3.read(JSON3.write(stateless_result))
            @test isempty(encoded_result.trades)
            @test encoded_result.initial_collateral == 1.0
            @test encoded_result.final_collateral == 1.0

            workspace = ForecastFlows.PredictionMarketWorkspace(zero_market_problem)
            workspace_result = ForecastFlows.solve_prediction_market!(
                workspace,
                zero_market_problem;
                mode=:direct_only,
                solver_options=facade_solver_options,
            )
            @test workspace_result.final_ev == stateless_result.final_ev
            @test workspace_result.final_holdings == stateless_result.final_holdings
            @test isempty(workspace_result.trades)

            uncertified_result = solve_prediction_market(
                zero_market_problem;
                mode=:direct_only,
                certify=false,
                solver_options=facade_solver_options,
            )
            @test uncertified_result.status == "solved"
            @test isnothing(uncertified_result.certificate)

            mixed_result = solve_prediction_market(
                zero_market_problem;
                mode=:mixed_enabled,
                throw_on_fail=false,
                max_doublings=0,
                solver_options=facade_solver_options,
            )
            @test mixed_result.mode == "mixed_enabled"
            @test isempty(mixed_result.trades)
            @test mixed_result.split_merge.mint == 0.0
            @test mixed_result.split_merge.merge == 0.0
            @test mixed_result.final_collateral == 1.0
            @test mixed_result.final_holdings == [0.0, 0.0]
        end

        @testset "route extraction" begin
            buy_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.8, 0.0),
                    OutcomeSpec("NO", 0.2, 0.0),
                ],
                1.0,
                [
                    ConstantProductMarketSpec("m1", "YES", 100.0, 200.0, 1.0),
                    ConstantProductMarketSpec("m2", "NO", 200.0, 100.0, 1.0),
                ],
            )
            buy_result = solve_prediction_market(buy_problem; mode=:direct_only, solver_options=facade_solver_options)
            @test length(buy_result.trades) == 1
            @test buy_result.trades[1].market_id == "m1"
            @test buy_result.trades[1].collateral_delta < 0.0
            @test buy_result.trades[1].outcome_delta > 0.0

            sell_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.25, 1.0),
                    OutcomeSpec("NO", 0.75, 0.0),
                ],
                0.0,
                [
                    ConstantProductMarketSpec("m1", "YES", 200.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m2", "NO", 100.0, 200.0, 1.0),
                ],
            )
            sell_result = solve_prediction_market(sell_problem; mode=:direct_only, solver_options=facade_solver_options)
            sell_trade = only(filter(t -> t.market_id == "m1", sell_result.trades))
            @test sell_trade.collateral_delta > 0.0
            @test sell_trade.outcome_delta < 0.0

            missing_direct_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.8, 0.0),
                    OutcomeSpec("NO", 0.2, 0.0),
                ],
                1.0,
                [ConstantProductMarketSpec("m_yes", "YES", 100.0, 200.0, 1.0)];
                split_bound=5.0,
            )
            missing_direct = solve_prediction_market(missing_direct_problem; mode=:direct_only, solver_options=facade_solver_options)
            @test !isempty(missing_direct.trades)
            @test all(trade -> trade.outcome_id == "YES", missing_direct.trades)

            missing_mixed_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.55, 0.0),
                    OutcomeSpec("NO", 0.45, 0.0),
                ],
                1.0,
                [ConstantProductMarketSpec("m_yes", "YES", 100.0, 40.0, 1.0)];
                split_bound=5.0,
            )
            missing_mixed = solve_prediction_market(
                missing_mixed_problem;
                mode=:mixed_enabled,
                max_doublings=0,
                throw_on_fail=false,
                solver_options=facade_solver_options,
            )
            @test missing_mixed.mode == "mixed_enabled"
            @test missing_mixed.split_merge.mint > 0.0
            @test all(trade -> trade.outcome_id == "YES", missing_mixed.trades)

            multi_pool_sell_problem = PredictionMarketProblem(
                [OutcomeSpec("YES", 0.25, 200.0)],
                0.0,
                [
                    ConstantProductMarketSpec("m_yes_a", "YES", 100.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m_yes_b", "YES", 60.0, 30.0, 1.0),
                ],
            )
            multi_pool_sell = solve_prediction_market(multi_pool_sell_problem; mode=:direct_only, solver_options=facade_solver_options)
            sell_trades = filter(trade -> trade.outcome_id == "YES" && trade.outcome_delta < 0.0, multi_pool_sell.trades)
            @test length(sell_trades) == 2
            @test Set(getfield.(sell_trades, :market_id)) == Set(["m_yes_a", "m_yes_b"])

            mint_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.55, 0.0),
                    OutcomeSpec("NO", 0.45, 0.0),
                ],
                1.0,
                [
                    ConstantProductMarketSpec("m1", "YES", 40.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m2", "NO", 70.0, 100.0, 1.0),
                ];
                split_bound=5.0,
            )
            mint_result = solve_prediction_market(
                mint_problem;
                mode=:mixed_enabled,
                max_doublings=0,
                throw_on_fail=false,
                solver_options=facade_solver_options,
            )
            @test mint_result.split_merge.mint > 0.0
            @test any(trade -> trade.outcome_delta < 0.0, mint_result.trades)

            merge_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.15, 3.0),
                    OutcomeSpec("NO", 0.15, 3.0),
                ],
                0.0,
                [
                    ConstantProductMarketSpec("m1", "YES", 20.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m2", "NO", 20.0, 100.0, 1.0),
                ];
                split_bound=5.0,
            )
            merge_result = solve_prediction_market(
                merge_problem;
                mode=:mixed_enabled,
                throw_on_fail=false,
                max_doublings=0,
                solver_options=facade_solver_options,
            )
            @test merge_result.split_merge.merge > 0.0
            @test any(trade -> trade.outcome_delta > 0.0, merge_result.trades)
        end

        @testset "public UniV3 support" begin
            uni_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.2, 1.0),
                    OutcomeSpec("NO", 0.35, 0.0),
                ],
                0.0,
                [
                    UniV3MarketSpec("u1", "YES", 0.5, [UniV3LiquidityBand(0.25, 10.0), UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.5, 12.0)], 0.997),
                    UniV3MarketSpec("u2", "NO", 0.5, [UniV3LiquidityBand(0.25, 8.0), UniV3LiquidityBand(1.0, 9.0), UniV3LiquidityBand(0.5, 11.0)], 0.997),
                ],
            )
            uni_result = solve_prediction_market(uni_problem; mode=:direct_only, solver_options=facade_solver_options)
            @test uni_result.status == "certified"
            @test length(uni_result.trades) == 1
            @test uni_result.trades[1].market_id == "u1"
            @test uni_result.trades[1].collateral_delta > 0.0
            @test uni_result.trades[1].outcome_delta < 0.0

            encoded = JSON3.read(JSON3.write(uni_problem))
            @test encoded.markets[1].type == "univ3"
            @test hasproperty(encoded.markets[1], :bands)
            @test !hasproperty(encoded.markets[1], :lower_ticks)
            @test String(encoded.markets[1].outcome_id) == "YES"
            @test encoded.markets[1].bands[1].lower_price == 1.0

            hard_boundary = UniV3MarketSpec(
                "u_boundary",
                "YES",
                0.75,
                [UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.5, 0.0)],
                1.0,
            )
            hard_boundary_json = JSON3.read(JSON3.write(hard_boundary))
            @test hard_boundary_json.bands[2].lower_price == 0.5
            @test hard_boundary_json.bands[2].liquidity_L == 0.0
            @test propertynames(hard_boundary) == (:market_id, :outcome_id, :current_price, :bands, :fee_multiplier)
            @test propertynames(hard_boundary, true) == (:market_id, :outcome_id, :current_price, :bands, :fee_multiplier, :lower_ticks, :liquidity_k)
            @test hard_boundary.bands == [UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.5, 0.0)]
            @test !hasproperty(hard_boundary, :lower_ticks)
            @test !hasproperty(hard_boundary, :liquidity_k)
            hard_boundary_repr = sprint(show, hard_boundary)
            @test occursin("UniV3MarketSpec", hard_boundary_repr)
            @test occursin("bands", hard_boundary_repr)
            @test !occursin("lower_ticks", hard_boundary_repr)
            @test !occursin("liquidity_k", hard_boundary_repr)

            @test_throws ArgumentError UniV3MarketSpec(
                "u_bad_leading",
                "YES",
                0.75,
                [UniV3LiquidityBand(1.0, 0.0), UniV3LiquidityBand(0.5, 10.0)],
                1.0,
            )
            gapped_boundary = UniV3MarketSpec(
                "u_gap",
                "YES",
                0.8,
                [
                    UniV3LiquidityBand(1.0, 5.0),
                    UniV3LiquidityBand(0.75, 0.0),
                    UniV3LiquidityBand(0.5, 8.0),
                    UniV3LiquidityBand(0.25, 0.0),
                ],
                0.999,
            )
            @test gapped_boundary.bands == [
                UniV3LiquidityBand(1.0, 5.0),
                UniV3LiquidityBand(0.75, 0.0),
                UniV3LiquidityBand(0.5, 8.0),
                UniV3LiquidityBand(0.25, 0.0),
            ]
        end

        @testset "public UniV3 outcome-price direct buy regression" begin
            buy_problem = PredictionMarketProblem(
                [OutcomeSpec("YES", 0.30, 0.0)],
                1.0,
                [UniV3MarketSpec("u_buy", "YES", 0.15, [UniV3LiquidityBand(1.0, 1.0), UniV3LiquidityBand(0.0001, 0.0)], 0.9999)],
            )
            buy_result = solve_prediction_market(buy_problem; mode=:direct_only, throw_on_fail=false, solver_options=facade_solver_options)
            @test buy_result.status == "certified"
            @test length(buy_result.trades) == 1
            buy_trade = only(buy_result.trades)
            @test buy_trade.market_id == "u_buy"
            @test buy_trade.collateral_delta < 0.0
            @test buy_trade.outcome_delta > 0.0
            @test buy_result.final_ev > buy_result.initial_ev + 1e-6
        end

        @testset "UniV3 boundary exhaustion" begin
            boundary_problem = PredictionMarketProblem(
                [OutcomeSpec("YES", 1.5, 0.0)],
                10.0,
                [UniV3MarketSpec("u1", "YES", 0.75, [UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.5, 0.0)], 1.0)],
            )
            boundary_result = solve_prediction_market(boundary_problem; mode=:direct_only, solver_options=facade_solver_options)
            buy_trade = only(boundary_result.trades)
            @test buy_trade.market_id == "u1"
            @test buy_trade.outcome_delta > 0.0
            @test buy_trade.collateral_delta < 0.0
            @test boundary_result.final_collateral > 0.0
            @test boundary_result.final_holdings[1] < 10.0
        end

        @testset "family comparison helper" begin
            comparison_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.55, 0.0),
                    OutcomeSpec("NO", 0.45, 0.0),
                ],
                1.0,
                [
                    ConstantProductMarketSpec("m1", "YES", 40.0, 100.0, 1.0),
                    ConstantProductMarketSpec("m2", "NO", 70.0, 100.0, 1.0),
                ];
                split_bound=5.0,
            )
            direct_result = solve_prediction_market(comparison_problem; mode=:direct_only, max_doublings=0, solver_options=facade_solver_options)
            mixed_result = solve_prediction_market(
                comparison_problem;
                mode=:mixed_enabled,
                max_doublings=0,
                throw_on_fail=false,
                solver_options=facade_solver_options,
            )
            comparison = compare_prediction_market_families(
                comparison_problem;
                max_doublings=0,
                throw_on_fail=false,
                solver_options=facade_solver_options,
            )
            workspace = ForecastFlows.PredictionMarketWorkspace(comparison_problem)
            workspace_comparison = ForecastFlows.compare_prediction_market_families!(
                workspace,
                comparison_problem;
                max_doublings=0,
                throw_on_fail=false,
                solver_options=facade_solver_options,
            )

            @test comparison.direct_only.final_ev ≈ direct_result.final_ev atol=1e-8
            @test comparison.direct_only.final_collateral ≈ direct_result.final_collateral atol=1e-8
            @test comparison.mixed_enabled.final_ev ≈ mixed_result.final_ev atol=1e-8
            @test comparison.mixed_enabled.split_merge.mint ≈ mixed_result.split_merge.mint atol=1e-8
            @test workspace_comparison.direct_only.final_ev ≈ comparison.direct_only.final_ev atol=1e-8
            @test workspace_comparison.direct_only.final_collateral ≈ comparison.direct_only.final_collateral atol=1e-8
            @test workspace_comparison.mixed_enabled.final_ev ≈ comparison.mixed_enabled.final_ev atol=1e-8
            @test workspace_comparison.mixed_enabled.split_merge.mint ≈ comparison.mixed_enabled.split_merge.mint atol=1e-8

            gas_model = PredictionMarketFixedGasModel(fill(0.01, length(comparison_problem.markets)), 0.03)
            direct_gas = solve_prediction_market(
                comparison_problem;
                mode=:direct_only,
                gas_model=gas_model,
                max_doublings=0,
                solver_options=facade_solver_options,
            )
            mixed_gas = solve_prediction_market(
                comparison_problem;
                mode=:mixed_enabled,
                gas_model=gas_model,
                max_doublings=0,
                throw_on_fail=false,
                solver_options=facade_solver_options,
            )
            comparison_gas = compare_prediction_market_families(
                comparison_problem;
                gas_model=gas_model,
                max_doublings=0,
                throw_on_fail=false,
                solver_options=facade_solver_options,
            )
            workspace_gas = ForecastFlows.compare_prediction_market_families!(
                workspace,
                comparison_problem;
                gas_model=gas_model,
                max_doublings=0,
                throw_on_fail=false,
                solver_options=facade_solver_options,
            )

            @test comparison_gas.direct_only.final_ev ≈ direct_gas.final_ev atol=1e-8
            @test comparison_gas.direct_only.net_ev ≈ direct_gas.net_ev atol=1e-8
            @test comparison_gas.mixed_enabled.final_ev ≈ mixed_gas.final_ev atol=1e-8
            @test comparison_gas.mixed_enabled.net_ev ≈ mixed_gas.net_ev atol=1e-8
            @test workspace_gas.direct_only.final_ev ≈ comparison_gas.direct_only.final_ev atol=1e-6
            @test workspace_gas.mixed_enabled.net_ev ≈ comparison_gas.mixed_enabled.net_ev atol=1e-6
        end

        @testset "public deep-trading facade spot checks" begin
            for (case_id, expected_family) in [
                ("two_pool_single_tick_direct_only", "direct"),
                ("small_bundle_mixed_case", "mixed"),
            ]
                benchmark = build_case_from_deep_trading(case_id)
                expected = deep_trading_net_expected(case_id)
                problem = public_problem_from_benchmark(benchmark)

                comparison = compare_prediction_market_families(
                    problem;
                    max_doublings=6,
                    throw_on_fail=false,
                    solver_options=(; pgtol=1e-6, max_iter=10_000, max_fun=20_000),
                )
                direct_public = replay_public_result(benchmark, comparison.direct_only)
                mixed_public = replay_public_result(benchmark, comparison.mixed_enabled)

                @test comparison.direct_only.status == "certified"
                @test comparison.mixed_enabled.status == "certified"
                @test direct_public.replay.final_raw_ev <= comparison.direct_only.final_ev + 1e-6
                @test mixed_public.replay.final_raw_ev <= comparison.mixed_enabled.final_ev + 1e-6
                @test direct_public.net_ev ≈ expected.direct_net_ev atol=1e-9
                @test mixed_public.net_ev ≈ expected.mixed_net_ev atol=1e-9
                @test benchmark_best_family(direct_public.net_ev, mixed_public.net_ev) == expected_family
                @test expected.best_family == expected_family
            end
        end

        @testset "workspace hot loop" begin
            workspace_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.8, 0.0),
                    OutcomeSpec("NO", 0.2, 0.0),
                ],
                1.0,
                [
                    ConstantProductMarketSpec("m_yes_a", "YES", 100.0, 200.0, 1.0),
                    ConstantProductMarketSpec("m_yes_b", "YES", 80.0, 160.0, 1.0),
                ];
                split_bound=5.0,
            )
            workspace = ForecastFlows.PredictionMarketWorkspace(workspace_problem)
            @test propertynames(workspace) == (:outcome_ids, :market_ids)
            @test propertynames(workspace, true) == (:outcome_ids, :market_ids, :layout, :direct_solver, :mixed_solver, :direct_seed, :mixed_seed)
            @test workspace.outcome_ids == ["YES", "NO"]
            @test workspace.market_ids == ["m_yes_a", "m_yes_b"]
            @test !hasproperty(workspace, :layout)
            @test !hasproperty(workspace, :direct_solver)
            workspace_repr = sprint(show, workspace)
            @test occursin("PredictionMarketWorkspace", workspace_repr)
            @test occursin("2 outcomes", workspace_repr)
            @test occursin("2 markets", workspace_repr)
            @test !occursin("layout", workspace_repr)
            @test !occursin("Solver", workspace_repr)
            stateless_direct = solve_prediction_market(
                workspace_problem;
                mode=:direct_only,
                solver_options=facade_solver_options,
            )
            workspace_direct = ForecastFlows.solve_prediction_market!(
                workspace,
                workspace_problem;
                mode=:direct_only,
                solver_options=facade_solver_options,
            )
            @test workspace_direct.final_ev ≈ stateless_direct.final_ev atol=1e-8
            @test workspace_direct.final_holdings ≈ stateless_direct.final_holdings atol=1e-8

            updated_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.7, 0.2),
                    OutcomeSpec("NO", 0.3, 0.0),
                ],
                0.9,
                [
                    ConstantProductMarketSpec("m_yes_a", "YES", 96.0, 210.0, 1.0),
                    ConstantProductMarketSpec("m_yes_b", "YES", 82.0, 150.0, 1.0),
                ];
                split_bound=4.0,
            )
            updated_stateless = solve_prediction_market(
                updated_problem;
                mode=:direct_only,
                solver_options=facade_solver_options,
            )
            updated_workspace = ForecastFlows.solve_prediction_market!(
                workspace,
                updated_problem;
                mode=:direct_only,
                solver_options=facade_solver_options,
            )
            @test updated_workspace.final_ev ≈ updated_stateless.final_ev atol=1e-8
            @test updated_workspace.outcome_ids == ["YES", "NO"]
            @test all(trade -> trade.outcome_id == "YES", updated_workspace.trades)

            mismatched_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("YES", 0.8, 0.0),
                    OutcomeSpec("NO", 0.2, 0.0),
                ],
                1.0,
                [
                    ConstantProductMarketSpec("m_yes_a", "YES", 100.0, 200.0, 1.0),
                    ConstantProductMarketSpec("m_no", "NO", 80.0, 160.0, 1.0),
                ];
                split_bound=5.0,
            )
            @test_throws ArgumentError ForecastFlows.solve_prediction_market!(
                workspace,
                mismatched_problem;
                mode=:direct_only,
                solver_options=facade_solver_options,
            )
        end

        @testset "worker protocol" begin
            worker_problem = PredictionMarketProblem(
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
            worker_gas_model = PredictionMarketFixedGasModel([0.01, 0.02], 0.03)
            problem_json = JSON3.write(worker_problem)
            roundtrip_problem = JSON3.read(problem_json)
            @test roundtrip_problem.markets[1].type == "constant_product"
            @test String(roundtrip_problem.markets[2].market_id) == "m2"

            worker_uni_problem = PredictionMarketProblem(
                [
                    OutcomeSpec("1", 0.2, 1.0),
                    OutcomeSpec("2", 0.35, 0.0),
                ],
                0.0,
                [
                    UniV3MarketSpec("u1", "1", 0.5, [UniV3LiquidityBand(0.25, 10.0), UniV3LiquidityBand(1.0, 10.0), UniV3LiquidityBand(0.5, 12.0)], 0.997),
                    UniV3MarketSpec("u2", "2", 0.5, [UniV3LiquidityBand(0.25, 8.0), UniV3LiquidityBand(1.0, 9.0), UniV3LiquidityBand(0.5, 11.0)], 0.997),
                ],
            )
            worker_uni_json = JSON3.read(JSON3.write(worker_uni_problem))
            @test worker_uni_json.markets[1].type == "univ3"
            @test hasproperty(worker_uni_json.markets[1], :bands)
            @test !hasproperty(worker_uni_json.markets[1], :lower_ticks)
            @test worker_uni_json.markets[1].bands[1].lower_price == 1.0

            parsed_health = ForecastFlows.parse_protocol_request(JSON3.write((
                protocol_version=2,
                request_id="health",
                command="health",
            )))
            @test parsed_health isa ForecastFlows.HealthRequest

            parsed_gas_solve = ForecastFlows.parse_protocol_request(JSON3.write((
                protocol_version=2,
                request_id="gas-parse",
                command="solve_prediction_market",
                mode="direct_only",
                problem=worker_problem,
                gas_model=worker_gas_model,
            )))
            @test parsed_gas_solve isa ForecastFlows.SolveRequest
            @test parsed_gas_solve.gas_model.market_action_costs == [0.01, 0.02]
            @test parsed_gas_solve.gas_model.split_merge_action_cost == 0.03

            unsafe_gas_units_response = JSON3.read(ForecastFlows.handle_protocol_json(JSON3.write((
                protocol_version=2,
                request_id="unsafe-gas-units",
                command="solve_prediction_market",
                mode="direct_only",
                problem=worker_problem,
                gas_model=(market_action_costs=["9007199254740992", 0.02], split_merge_action_cost=0.03),
            ))))
            @test !unsafe_gas_units_response.ok
            @test unsafe_gas_units_response.error.code == "invalid_request"
            @test occursin("decimal-scaled token units", String(unsafe_gas_units_response.error.message))

            rendered_health = JSON3.read(ForecastFlows.handle_protocol_json(JSON3.write((
                protocol_version=2,
                request_id="health",
                command="health",
            ))))
            @test rendered_health.ok
            @test rendered_health.result.status == "ok"
            @test rendered_health.result.package_version == "2.0.0"
            @test String.(collect(rendered_health.result.stable_interfaces)) == ["prediction_market_facade", "ndjson_protocol"]
            @test String.(collect(rendered_health.result.public_interfaces)) == expected_public_interfaces

            legacy_problem_shape_response = JSON3.read(ForecastFlows.handle_protocol_json(JSON3.write((
                protocol_version=2,
                request_id="legacy-problem-shape",
                command="solve_prediction_market",
                mode="direct_only",
                problem=(
                    outcome_values=[0.2, 0.35],
                    initial_cash=0.0,
                    initial_holdings=[1.0, 0.0],
                    markets=[
                        (type="constant_product", market_id="m1", outcome_id="1", collateral_reserve=40.0, outcome_reserve=100.0, fee_multiplier=1.0),
                        (type="constant_product", market_id="m2", outcome_id="2", collateral_reserve=70.0, outcome_reserve=100.0, fee_multiplier=1.0),
                    ],
                ),
            ))))
            @test !legacy_problem_shape_response.ok
            @test legacy_problem_shape_response.error.code == "invalid_request"
            @test occursin("problem.outcomes and problem.collateral_balance", String(legacy_problem_shape_response.error.message))

            legacy_univ3_shape_response = JSON3.read(ForecastFlows.handle_protocol_json(JSON3.write((
                protocol_version=2,
                request_id="legacy-univ3-shape",
                command="solve_prediction_market",
                mode="direct_only",
                problem=(
                    outcomes=[
                        (outcome_id="1", fair_value=0.2, initial_holding=1.0),
                        (outcome_id="2", fair_value=0.35, initial_holding=0.0),
                    ],
                    collateral_balance=0.0,
                    markets=[
                        (type="univ3", market_id="u1", outcome_id="1", current_price=0.5, lower_ticks=[1.0, 0.5], liquidity=[100.0, 0.0], fee_multiplier=0.997),
                        (type="univ3", market_id="u2", outcome_id="2", current_price=0.5, bands=[(lower_price=1.0, liquidity_L=9.0)], fee_multiplier=0.997),
                    ],
                ),
            ))))
            @test !legacy_univ3_shape_response.ok
            @test legacy_univ3_shape_response.error.code == "invalid_request"
            @test occursin("bands is required", String(legacy_univ3_shape_response.error.message))

            interior_zero_band_response = JSON3.read(ForecastFlows.handle_protocol_json(JSON3.write((
                protocol_version=2,
                request_id="interior-zero-band",
                command="solve_prediction_market",
                mode="direct_only",
                problem=(
                    outcomes=[(outcome_id="1", fair_value=0.75, initial_holding=0.0)],
                    collateral_balance=1.0,
                    markets=[(
                        type="univ3",
                        market_id="u1",
                        outcome_id="1",
                        current_price=0.75,
                        bands=[
                            (lower_price=1.0, liquidity_L=0.0),
                            (lower_price=0.5, liquidity_L=10.0),
                        ],
                        fee_multiplier=1.0,
                    )],
                ),
            ))))
            @test !interior_zero_band_response.ok
            @test interior_zero_band_response.error.code == "invalid_request"
            @test occursin("zero-liquidity gaps require a final zero-liquidity terminal band", String(interior_zero_band_response.error.message))

            duplicate_zero_band_response = JSON3.read(ForecastFlows.handle_protocol_json(JSON3.write((
                protocol_version=2,
                request_id="duplicate-zero-band",
                command="solve_prediction_market",
                mode="direct_only",
                problem=(
                    outcomes=[(outcome_id="1", fair_value=0.75, initial_holding=0.0)],
                    collateral_balance=1.0,
                    markets=[(
                        type="univ3",
                        market_id="u1",
                        outcome_id="1",
                        current_price=0.75,
                        bands=[
                            (lower_price=1.0, liquidity_L=10.0),
                            (lower_price=0.5, liquidity_L=0.0),
                            (lower_price=0.25, liquidity_L=0.0),
                        ],
                        fee_multiplier=1.0,
                    )],
                ),
            ))))
            @test duplicate_zero_band_response.ok
            @test duplicate_zero_band_response.result.status == "certified"

            worker_script = joinpath(dirname(@__DIR__), "bin", "forecastflows-worker.jl")
            cmd = `$(Base.julia_cmd()) --project=$(dirname(@__DIR__)) $(worker_script)`
            requests = [
                (protocol_version=2, request_id="health", command="health"),
                (
                    protocol_version=2,
                    request_id="solve",
                    command="solve_prediction_market",
                    mode="mixed_enabled",
                    problem=worker_problem,
                    solve_options=(throw_on_fail=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000, max_doublings=0),
                ),
                (
                    protocol_version=2,
                    request_id="clipped-default",
                    command="solve_prediction_market",
                    mode="mixed_enabled",
                    problem=worker_problem,
                    solve_options=(pgtol=1e-8, max_iter=5_000, max_fun=10_000, max_doublings=0),
                ),
                (
                    protocol_version=2,
                    request_id="compare",
                    command="compare_prediction_market_families",
                    problem=worker_problem,
                    solve_options=(throw_on_fail=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000, max_doublings=0),
                ),
                (
                    protocol_version=2,
                    request_id="compare-reused",
                    command="compare_prediction_market_families",
                    problem=worker_problem,
                    solve_options=(throw_on_fail=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000, max_doublings=0),
                ),
                (
                    protocol_version=2,
                    request_id="uni",
                    command="solve_prediction_market",
                    mode="direct_only",
                    problem=worker_uni_problem,
                    solve_options=(pgtol=1e-8, max_iter=5_000, max_fun=10_000),
                ),
                (
                    protocol_version=2,
                    request_id="uncertified-json",
                    command="solve_prediction_market",
                    mode="mixed_enabled",
                    problem=worker_problem,
                    solve_options=(throw_on_fail=false, pgtol=1e-8, max_iter=5_000, max_fun=10_000),
                ),
                (
                    protocol_version=2,
                    request_id="gas-solve",
                    command="solve_prediction_market",
                    mode="direct_only",
                    problem=worker_problem,
                    gas_model=worker_gas_model,
                    solve_options=(pgtol=1e-8, max_iter=5_000, max_fun=10_000),
                ),
                (
                    protocol_version=2,
                    request_id="wei",
                    command="solve_prediction_market",
                    mode="direct_only",
                    problem=(
                        outcomes=[
                            (outcome_id="1", fair_value=0.55, initial_holding=0.0),
                            (outcome_id="2", fair_value=0.45, initial_holding=0.0),
                        ],
                        collateral_balance="1000000000000000000",
                        markets=[
                            (type="constant_product", market_id="m1", outcome_id="1", collateral_reserve=40.0, outcome_reserve=100.0, fee_multiplier=1.0),
                            (type="constant_product", market_id="m2", outcome_id="2", collateral_reserve=70.0, outcome_reserve=100.0, fee_multiplier=1.0),
                        ],
                    ),
                ),
                (
                    protocol_version=2,
                    request_id="bool",
                    command="solve_prediction_market",
                    mode="direct_only",
                    problem=(
                        outcomes=[
                            (outcome_id="1", fair_value=0.55, initial_holding=0.0),
                            (outcome_id="2", fair_value=0.45, initial_holding=0.0),
                        ],
                        collateral_balance=true,
                        markets=[
                            (type="constant_product", market_id="m1", outcome_id="1", collateral_reserve=40.0, outcome_reserve=100.0, fee_multiplier=1.0),
                            (type="constant_product", market_id="m2", outcome_id="2", collateral_reserve=70.0, outcome_reserve=100.0, fee_multiplier=1.0),
                        ],
                    ),
                ),
                (
                    protocol_version=2,
                    request_id="invalid",
                    command="solve_prediction_market",
                    mode="bad_mode",
                    problem=worker_problem,
                ),
                (
                    protocol_version=2,
                    request_id="missing-market-id",
                    command="solve_prediction_market",
                    problem=(
                        outcomes=[
                            (outcome_id="1", fair_value=0.55, initial_holding=0.0),
                            (outcome_id="2", fair_value=0.45, initial_holding=0.0),
                        ],
                        collateral_balance=1.0,
                        markets=[
                            (type="constant_product", outcome_id="1", collateral_reserve=40.0, outcome_reserve=100.0, fee_multiplier=1.0),
                            (type="constant_product", market_id="m2", outcome_id="2", collateral_reserve=70.0, outcome_reserve=100.0, fee_multiplier=1.0),
                        ],
                    ),
                ),
                (
                    protocol_version=2,
                    request_id="missing-band-field",
                    command="solve_prediction_market",
                    mode="direct_only",
                    problem=(
                        outcomes=[
                            (outcome_id="1", fair_value=0.2, initial_holding=1.0),
                            (outcome_id="2", fair_value=0.35, initial_holding=0.0),
                        ],
                        collateral_balance=0.0,
                        markets=[
                            (type="univ3", market_id="u1", outcome_id="1", current_price=0.5, bands=[(lower_price=1.0,)], fee_multiplier=0.997),
                            (type="univ3", market_id="u2", outcome_id="2", current_price=0.5, bands=[(lower_price=1.0, liquidity_L=9.0)], fee_multiplier=0.997),
                        ],
                    ),
                ),
                (
                    protocol_version=2,
                    request_id="bad-max-iter",
                    command="solve_prediction_market",
                    problem=worker_problem,
                    solve_options=(max_iter="oops",),
                ),
                (
                    protocol_version=2,
                    request_id="bad-certify",
                    command="solve_prediction_market",
                    problem=worker_problem,
                    solve_options=(certify="oops",),
                ),
                (
                    protocol_version=2,
                    request_id="bad-number",
                    command="solve_prediction_market",
                    problem=(
                        outcomes=[
                            (outcome_id="1", fair_value=0.55, initial_holding=0.0),
                            (outcome_id="2", fair_value=0.45, initial_holding=0.0),
                        ],
                        collateral_balance="oops",
                        markets=[
                            (type="constant_product", market_id="m1", outcome_id="1", collateral_reserve=40.0, outcome_reserve=100.0, fee_multiplier=1.0),
                            (type="constant_product", market_id="m2", outcome_id="2", collateral_reserve=70.0, outcome_reserve=100.0, fee_multiplier=1.0),
                        ],
                    ),
                ),
                (
                    protocol_version=2,
                    request_id="bad-gas-model",
                    command="solve_prediction_market",
                    mode="direct_only",
                    problem=worker_problem,
                    gas_model=(market_action_costs=[0.01], split_merge_action_cost=0.03),
                ),
                (
                    protocol_version=2,
                    request_id="missing-problem",
                    command="solve_prediction_market",
                ),
                (
                    protocol_version=3,
                    request_id="bad-version",
                    command="health",
                ),
                (
                    protocol_version=2,
                    request_id="bad-command",
                    command="wat",
                ),
                (
                    protocol_version=2,
                    request_id="solve-failed",
                    command="solve_prediction_market",
                    mode="mixed_enabled",
                    problem=worker_problem,
                    solve_options=(throw_on_fail=true, max_iter=1, max_fun=1, max_doublings=0),
                ),
            ]
            input = join(JSON3.write.(requests), "\n") * "\n"
            output = read(pipeline(IOBuffer(input), cmd), String)
            response_lines = filter(!isempty, split(chomp(output), '\n'))
            responses = JSON3.read.(response_lines)

            @test length(responses) == 21
            @test responses[1].ok
            @test responses[1].request_id == "health"
            @test responses[1].result.status == "ok"
            @test String.(collect(responses[1].result.stable_interfaces)) == ["prediction_market_facade", "ndjson_protocol"]
            @test String.(collect(responses[1].result.public_interfaces)) == expected_public_interfaces
            @test responses[1].result.numeric_units == "decimal collateral and outcome token units"
            @test occursin("serve_protocol reuses compatible compare workspaces", String(responses[1].result.execution_model))
            @test occursin("handle_protocol_json is stateless", String(responses[1].result.execution_model))

            @test responses[2].ok
            @test responses[2].request_id == "solve"
            @test responses[2].result.mode == "mixed_enabled"
            @test responses[2].result.split_merge.mint > 0.0
            @test responses[2].result.trades[1].outcome_id == "1"

            @test !responses[3].ok
            @test responses[3].request_id == "clipped-default"
            @test responses[3].error.code == "solve_failed"
            @test occursin("split/merge bound remained near-active", String(responses[3].error.message))

            @test responses[4].ok
            @test responses[4].request_id == "compare"
            @test responses[4].result.direct_only.mode == "direct_only"
            @test responses[4].result.mixed_enabled.mode == "mixed_enabled"

            @test responses[5].ok
            @test responses[5].request_id == "compare-reused"
            @test responses[5].result.direct_only.mode == "direct_only"
            @test responses[5].result.mixed_enabled.mode == "mixed_enabled"

            @test responses[6].ok
            @test responses[6].request_id == "uni"
            @test responses[6].result.mode == "direct_only"
            @test responses[6].result.trades[1].market_id == "u1"
            @test responses[6].result.trades[1].outcome_id == "1"

            @test responses[7].ok
            @test responses[7].request_id == "uncertified-json"
            # The doubling loop returns the best certified result from an earlier
            # iteration when later doublings fail, so this is now certified.
            @test responses[7].result.status == "certified"
            @test !isnothing(responses[7].result.certificate.primal_value)
            @test !isnothing(responses[7].result.certificate.duality_gap)

            @test responses[8].ok
            @test responses[8].request_id == "gas-solve"
            @test responses[8].result.mode == "direct_only"
            @test responses[8].result.estimated_execution_cost >= 0.0
            @test responses[8].result.net_ev <= responses[8].result.final_ev + 1e-12

            @test !responses[9].ok
            @test responses[9].request_id == "wei"
            @test responses[9].error.code == "invalid_request"
            @test occursin("decimal-scaled token units", String(responses[9].error.message))

            @test !responses[10].ok
            @test responses[10].request_id == "bool"
            @test responses[10].error.code == "invalid_request"
            @test occursin("numeric, not boolean", String(responses[10].error.message))

            @test !responses[11].ok
            @test responses[11].request_id == "invalid"
            @test responses[11].error.code == "invalid_request"
            @test occursin("mode must be :direct_only or :mixed_enabled", String(responses[11].error.message))

            @test !responses[12].ok
            @test responses[12].request_id == "missing-market-id"
            @test responses[12].error.code == "invalid_request"
            @test occursin("problem.markets[1].market_id is required", String(responses[12].error.message))

            @test !responses[13].ok
            @test responses[13].request_id == "missing-band-field"
            @test responses[13].error.code == "invalid_request"
            @test occursin("problem.markets[1].bands[1].liquidity_L is required", String(responses[13].error.message))

            @test !responses[14].ok
            @test responses[14].request_id == "bad-max-iter"
            @test responses[14].error.code == "invalid_request"
            @test occursin("solve_options.max_iter must be parseable as Float64", String(responses[14].error.message))

            @test !responses[15].ok
            @test responses[15].request_id == "bad-certify"
            @test responses[15].error.code == "invalid_request"
            @test occursin("solve_options.certify must be boolean", String(responses[15].error.message))

            @test !responses[16].ok
            @test responses[16].request_id == "bad-number"
            @test responses[16].error.code == "invalid_request"
            @test occursin("problem.collateral_balance must be parseable as Float64", String(responses[16].error.message))

            @test !responses[17].ok
            @test responses[17].request_id == "bad-gas-model"
            @test responses[17].error.code == "invalid_request"
            @test occursin("one cost per problem market", String(responses[17].error.message))

            @test !responses[18].ok
            @test responses[18].request_id == "missing-problem"
            @test responses[18].error.code == "invalid_request"
            @test occursin("problem is required", String(responses[18].error.message))

            @test !responses[19].ok
            @test responses[19].request_id == "bad-version"
            @test responses[19].error.code == "invalid_request"
            @test occursin("unsupported protocol_version 3", String(responses[19].error.message))

            @test !responses[20].ok
            @test responses[20].request_id == "bad-command"
            @test responses[20].error.code == "invalid_request"
            @test occursin("unsupported command: wat", String(responses[20].error.message))

            @test !responses[21].ok
            @test responses[21].request_id == "solve-failed"
            @test responses[21].error.code == "solve_failed"
            @test occursin("failed certification", String(responses[21].error.message))

            malformed_response = JSON3.read(String(read(pipeline(IOBuffer("{\n"), cmd), String)))
            @test !malformed_response.ok
            @test isnothing(malformed_response.request_id)
            @test malformed_response.error.code == "invalid_request"
            @test occursin("invalid JSON", String(malformed_response.error.message))
        end

        @testset "release helper ergonomics" begin
            include(joinpath(dirname(@__DIR__), "bin", "build-worker-sysimage.jl"))

            helper_root = joinpath(tempdir(), "forecastflows-release-helper")
            default_sysimage = forecastflows_default_worker_sysimage_path(helper_root)
            @test default_sysimage == joinpath(helper_root, "build", "forecastflows-worker.$(Libdl.dlext)")
            @test occursin("/build/", read(joinpath(dirname(@__DIR__), ".gitignore"), String))
        end
    end

end
