using JSON3

const pm_tol = 1e-6
const dt_case_id = "heterogeneous_ninety_eight_outcome_l1_like_case"
const benchmark_opt_in_env = "FORECASTFLOWS_RUN_DEEPTRADING_BENCHMARK"
const benchmark_gas_opt_in_env = "FORECASTFLOWS_RUN_DEEPTRADING_GAS_BENCHMARK"
const replay_atol = 1e-9
const dt_cases_fixture = joinpath(@__DIR__, "fixtures", "rebalancer_ab_cases.json")
const dt_expected_fixture = joinpath(@__DIR__, "fixtures", "rebalancer_ab_expected.json")

const dt_expected_case = let
    payload = JSON3.read(read(dt_expected_fixture, String))
    getproperty(payload, Symbol(dt_case_id))
end

const dt_direct_ev = Float64(dt_expected_case.offchain_direct_ev_wei) / 1e18
const dt_mixed_ev = Float64(dt_expected_case.offchain_mixed_ev_wei) / 1e18
const dt_full_rebalance_only_ev = Float64(dt_expected_case.offchain_full_rebalance_only_ev_wei) / 1e18

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
end

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
    payload = JSON3.read(read(dt_cases_fixture, String))
    case = getproperty(payload, Symbol(case_id))

    preds = to_tokens.(collect(case.predictions_wad))
    prices = to_tokens.(collect(case.starting_prices_wad))
    holdings0 = to_tokens.(collect(case.initial_holdings_wad))
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
        is_token1 = Bool(case.is_token1[i])
        lo = Int(case.ticks[i][1])
        hi = Int(case.ticks[i][2])
        limits = benchmark_tick_limit_prices(lo, hi, is_token1)
        liquidity = to_tokens(case.liquidity[i])
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
            is_token1,
        ))
    end

    return assemble_benchmark_case(
        case_id,
        preds,
        prices,
        holdings0,
        cash0,
        markets;
        deep_trading_direct_ev=dt_direct_ev,
        deep_trading_mixed_ev=dt_mixed_ev,
        deep_trading_full_rebalance_only_ev=dt_full_rebalance_only_ev,
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
    end

    while merge_remaining > atol
        direct_merge = min(merge_remaining, minimum(holdings))
        direct_merge <= atol && break
        holdings .-= direct_merge
        cash += direct_merge
        merge_remaining = max(merge_remaining - direct_merge, 0.0)
        executed_merge += direct_merge
        counts = ReplayActionCounts(counts.direct_buys, counts.direct_sells, counts.mint_rounds, counts.direct_merge_rounds + 1, counts.buy_merge_rounds)
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
        end

        holdings .-= round_amount
        cash += round_amount
        merge_remaining = max(merge_remaining - round_amount, 0.0)
        executed_merge += round_amount
        counts = ReplayActionCounts(counts.direct_buys, counts.direct_sells, counts.mint_rounds, counts.direct_merge_rounds, counts.buy_merge_rounds + 1)
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

    @testset "deep trading 98-market fixture translation" begin
        benchmark = build_case_from_deep_trading(dt_case_id)

        @test benchmark.initial_ev ≈ 150.22005815295148 atol=1e-9
        @test benchmark.objective isa EndowmentLinear
        @test benchmark.cash0 ≈ 150.0 atol=1e-12
        @test sum(benchmark.holdings0) ≈ 20.0 atol=1e-12
        @test sum(benchmark.predictions) ≈ 1.0 atol=1e-12
        @test sum(benchmark.current_prices) ≈ 1.0442842940877832 atol=1e-12
        @test all(==(1), benchmark.tick_lo)
        @test all(==(92_108), benchmark.tick_hi)
        @test benchmark.deep_trading_direct_ev ≈ dt_direct_ev atol=1e-12
        @test benchmark.deep_trading_mixed_ev ≈ dt_mixed_ev atol=1e-12
        @test benchmark.deep_trading_full_rebalance_only_ev ≈ dt_full_rebalance_only_ev atol=1e-12
    end

    @testset "deep trading single-tick parity" begin
        benchmark = build_case_from_deep_trading(dt_case_id)
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

    if get(ENV, benchmark_opt_in_env, "0") == "1"
        @testset "deep trading 98-market benchmark" begin
            benchmark = build_case_from_deep_trading(dt_case_id)
            benchmark_pgtol = 1e-6
            benchmark_max_iter = 10_000
            benchmark_max_fun = 20_000

            direct = solve_direct_benchmark(
                benchmark;
                method=:auto,
                pgtol=benchmark_pgtol,
                max_iter=benchmark_max_iter,
                max_fun=benchmark_max_fun,
            )
            mixed = solve_mixed_benchmark(
                benchmark;
                method=:auto,
                pgtol=benchmark_pgtol,
                max_iter=benchmark_max_iter,
                max_fun=benchmark_max_fun,
            )

            direct_route = desired_route_from_solver(benchmark, direct.solver)
            mixed_route = desired_route_from_solver(benchmark, mixed.solver)
            direct_replay = replay_desired_route(benchmark, direct_route)
            mixed_replay = replay_desired_route(benchmark, mixed_route)
            direct_certified = !isnothing(direct.solver.certificate) && direct.solver.certificate.passed
            mixed_certified = !isnothing(mixed.solver.certificate) && mixed.solver.certificate.passed
            direct_raw_upper_ev = direct_certified ? direct_route.raw_upper_ev : NaN
            mixed_raw_upper_ev = mixed_certified ? mixed_route.raw_upper_ev : NaN

            @test direct_certified
            @test mixed_certified
            @test direct_replay.final_cash >= -1e-8
            @test mixed_replay.final_cash >= -1e-8
            @test all(direct_replay.final_holdings .>= -1e-8)
            @test all(mixed_replay.final_holdings .>= -1e-8)
            @test isfinite(direct_replay.final_raw_ev)
            @test isfinite(mixed_replay.final_raw_ev)
            @test 0.0 <= direct_replay.fill_fraction <= 1.0
            @test 0.0 <= mixed_replay.fill_fraction <= 1.0
            @test direct_replay.final_raw_ev <= direct_raw_upper_ev + 1e-6
            @test mixed_replay.final_raw_ev <= mixed_raw_upper_ev + 1e-6

            run_gas_benchmark = get(ENV, benchmark_gas_opt_in_env, "0") == "1"
            gas_certified = missing
            gas_raw_upper_ev = missing
            gas_replayed_executable_ev = missing
            gas_net_upper_ev = missing
            gas_action_count = missing
            gas_solve_time = missing
            gas_replay_counts = missing
            gas_replay_residuals = missing

            if run_gas_benchmark
                gas_costs = vcat(fill(0.00018, length(benchmark.amm_edges)), [0.00021])
                split_edge = SplitMergeEdge(copy(benchmark.split_nodes), mixed.split_bound)
                s = Solver(
                    flow_objective=benchmark.objective,
                    edges=vcat(benchmark.amm_edges, Edge[split_edge]),
                    n=benchmark.n,
                )
                result = solve_with_fixed_gas!(s, FixedGasModel(gas_costs); pgtol=benchmark_pgtol, max_iter=benchmark_max_iter, max_fun=benchmark_max_fun)
                gas_route = desired_route_from_solver(benchmark, s)
                gas_replay = replay_desired_route(benchmark, gas_route)
                gas_certified = !isnothing(s.certificate) && s.certificate.passed
                gas_raw_upper_ev = gas_certified ? gas_route.raw_upper_ev : NaN
                gas_replayed_executable_ev = gas_replay.final_raw_ev
                gas_net_upper_ev = gas_raw_upper_ev - sum(gas_costs[i] for i in eachindex(gas_costs) if result.kept_edges[i] && ForecastFlows.edge_is_active(s.xs[i]))
                gas_action_count = active_edge_count(s)
                gas_solve_time = result.solve_time
                gas_replay_counts = gas_replay.counts
                gas_replay_residuals = gas_replay.residuals
            end

            @info "deep-trading 98-market benchmark" ev_before=benchmark.initial_ev direct_certified=direct_certified mixed_certified=mixed_certified gas_enabled=run_gas_benchmark gas_certified=gas_certified direct_raw_upper_ev=direct_raw_upper_ev direct_replayed_executable_ev=direct_replay.final_raw_ev direct_ev_gap=direct_certified ? direct_raw_upper_ev - direct_replay.final_raw_ev : NaN direct_fill_fraction=direct_replay.fill_fraction mixed_raw_upper_ev=mixed_raw_upper_ev mixed_replayed_executable_ev=mixed_replay.final_raw_ev mixed_ev_gap=mixed_raw_upper_ev - mixed_replay.final_raw_ev mixed_fill_fraction=mixed_replay.fill_fraction gas_raw_upper_ev=gas_raw_upper_ev gas_replayed_executable_ev=gas_replayed_executable_ev gas_net_upper_ev=gas_net_upper_ev gap_to_dt_direct=direct_replay.final_raw_ev - benchmark.deep_trading_direct_ev gap_to_dt_mixed=mixed_replay.final_raw_ev - benchmark.deep_trading_mixed_ev gap_to_dt_full_rebalance_only=mixed_replay.final_raw_ev - benchmark.deep_trading_full_rebalance_only_ev direct_action_count=active_edge_count(direct.solver) mixed_action_count=active_edge_count(mixed.solver) gas_action_count=gas_action_count split_flow=mixed.split_flow split_bound=mixed.split_bound direct_solve_time=direct.solve_time mixed_solve_time=mixed.solve_time gas_solve_time=gas_solve_time direct_replay_counts=direct_replay.counts mixed_replay_counts=mixed_replay.counts gas_replay_counts=gas_replay_counts direct_replay_residuals=direct_replay.residuals mixed_replay_residuals=mixed_replay.residuals gas_replay_residuals=gas_replay_residuals
        end
    end
end
