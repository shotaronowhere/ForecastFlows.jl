#!/usr/bin/env julia
# Simulate the native waterfall strategy to verify 132.03 sUSD benchmark

const WEIGHTS = [180, 165, 150, 120, 118, 116, 114, 112, 110, 108, 106, 104, 102, 100, 98, 96, 94, 60]
const N = length(WEIGHTS)
const PREDICTIONS = [w / sum(WEIGHTS) for w in WEIGHTS]
const FF = 1.0 - 100.0/1e6  # fee factor 0.9999

function build_fixture()
    factors = zeros(Float64, N)
    liquidities = zeros(Float64, N)
    for idx in 0:N-1
        if idx < 3
            factors[idx+1] = (3150 + idx * 140) / 10000.0
            liquidities[idx+1] = 8000.0 + idx * 850.0
        elseif idx < 17
            factors[idx+1] = (6900 + ((idx - 3) % 6) * 105) / 10000.0
            liquidities[idx+1] = 90.0 + idx * 7.0
        else
            factors[idx+1] = 14500 / 10000.0
            liquidities[idx+1] = 2200.0 + idx * 120.0
        end
    end
    current_prices = [PREDICTIONS[i] * factors[i] for i in 1:N]
    return current_prices, liquidities
end

mutable struct SimState
    prices::Vector{Float64}
    holdings::Vector{Float64}
    cash::Float64
    Ls::Vector{Float64}
end

function buy_tokens!(s::SimState, i::Int, spend::Float64)
    p = s.prices[i]; L = s.Ls[i]
    lam = sqrt(p) / L
    m = FF * spend / (p + FF * spend * lam)
    m <= 0 && return (0.0, 0.0)
    d = 1.0 - m * lam
    d <= 1e-15 && return (0.0, 0.0)
    cost = m * p / (FF * d)
    s.prices[i] = p / (d * d)
    return (m, cost)
end

function sell_tokens!(s::SimState, i::Int, amount::Float64)
    amount <= 0 && return 0.0
    p = s.prices[i]; L = s.Ls[i]
    kap = FF * sqrt(p) / L
    d = 1.0 + amount * kap
    proceeds = p * amount * FF / d
    s.prices[i] = p / (d * d)
    return proceeds
end

function compute_ev(s::SimState)
    return s.cash + sum(PREDICTIONS[i] * s.holdings[i] for i in 1:N)
end

function profitability(s::SimState, i::Int)
    return (PREDICTIONS[i] - s.prices[i]) / s.prices[i]
end

function run_direct_only!(s::SimState)
    for _ in 1:200_000
        s.cash <= 1e-10 && break
        profs = [profitability(s, i) for i in 1:N]
        best_i = argmax(profs)
        profs[best_i] <= 0 && break
        spend = min(s.cash, 0.01)
        tokens, cost = buy_tokens!(s, best_i, spend)
        s.cash -= min(cost, s.cash)
        s.holdings[best_i] += tokens
    end
end

function run_mixed_waterfall!(s::SimState)
    for _ in 1:500_000
        s.cash <= 1e-10 && break
        profs = [profitability(s, i) for i in 1:N]
        best_i = argmax(profs)
        profs[best_i] <= 0 && break

        # Compare direct vs mint+sell
        price_sum = sum(s.prices)
        alt_price = 1.0 - (price_sum - s.prices[best_i])
        mint_prof = alt_price > 0 ? (PREDICTIONS[best_i] - alt_price) / alt_price : -Inf

        spend = min(s.cash, 0.05)

        if mint_prof > profs[best_i] && 0 < alt_price < 1.0
            # Mint route: mint sets, sell non-targets
            num_sets = min(spend, s.cash)
            s.cash -= num_sets
            for j in 1:N
                s.holdings[j] += num_sets
            end
            for j in 1:N
                j == best_i && continue
                if s.holdings[j] > 1e-12
                    proceeds = sell_tokens!(s, j, s.holdings[j])
                    s.cash += proceeds
                    s.holdings[j] = 0.0
                end
            end
        else
            # Direct buy
            tokens, cost = buy_tokens!(s, best_i, spend)
            s.cash -= min(cost, s.cash)
            s.holdings[best_i] += tokens
        end
    end
end

function buy_exact!(s::SimState, i::Int, amount::Float64)
    amount <= 0 && return (0.0, 0.0)
    p = s.prices[i]; L = s.Ls[i]
    lam = sqrt(p) / L
    d = 1.0 - amount * lam
    d <= 1e-15 && return (0.0, 0.0)
    cost = amount * p / (FF * d)
    s.prices[i] = p / (d * d)
    return (amount, cost)
end

function marginal_buy_cost(s::SimState, m::Float64)
    total = 0.0
    for i in 1:N
        lam = sqrt(s.prices[i]) / s.Ls[i]
        d = 1.0 - m * lam
        d <= 0 && return Inf
        total += s.prices[i] / (FF * d * d)
    end
    return total
end

function solve_arb_amount(s::SimState)
    # Bisect to find m where marginal_buy_cost(m) = 1.0
    if marginal_buy_cost(s, 0.0) >= 1.0
        return 0.0
    end
    # Find upper bound: min of max_buy_tokens for each pool
    cap = minimum(begin
        lam = sqrt(s.prices[i]) / s.Ls[i]
        lam > 0 ? (1.0 - 1e-10) / lam : 0.0
    end for i in 1:N)
    cap <= 0 && return 0.0
    if marginal_buy_cost(s, cap * 0.999) <= 1.0
        return cap * 0.999
    end
    lo, hi = 0.0, cap * 0.999
    for _ in 1:64
        mid = (lo + hi) / 2
        if marginal_buy_cost(s, mid) <= 1.0
            lo = mid
        else
            hi = mid
        end
    end
    return lo
end

function run_complete_set_arb!(s::SimState)
    total_profit = 0.0
    for round in 1:256
        m = solve_arb_amount(s)
        m <= 1e-15 && break
        # Cap by budget: total cost of buying m of each
        total_cost = 0.0
        for i in 1:N
            lam = sqrt(s.prices[i]) / s.Ls[i]
            d = 1.0 - m * lam
            d <= 0 && (total_cost = Inf; break)
            total_cost += m * s.prices[i] / (FF * d)
        end
        if total_cost > s.cash
            # Scale down m to fit budget
            m = m * s.cash / total_cost * 0.99
            m <= 1e-15 && break
        end
        # Execute: buy m of each, merge
        actual_cost = 0.0
        for i in 1:N
            _, c = buy_exact!(s, i, m)
            actual_cost += c
        end
        s.cash -= actual_cost
        s.cash += m  # merge proceeds
        total_profit += m - actual_cost
    end
    return total_profit
end

function main()
    init_prices, liq = build_fixture()

    println("Sum of initial prices: ", sum(init_prices))
    println()

    # Direct-only (no arb)
    s1 = SimState(copy(init_prices), zeros(N), 6.5, copy(liq))
    run_direct_only!(s1)
    println("Direct-only EV: ", round(compute_ev(s1), digits=2))
    println("  cash: ", round(s1.cash, digits=4))

    # Arb phase + direct deploy
    s5 = SimState(copy(init_prices), zeros(N), 6.5, copy(liq))
    arb_profit = run_complete_set_arb!(s5)
    println("\nAfter arb phase:")
    println("  arb profit: ", round(arb_profit, digits=2))
    println("  cash: ", round(s5.cash, digits=2))
    println("  price sum: ", round(sum(s5.prices), digits=6))
    # Now deploy via direct buy waterfall
    run_direct_only!(s5)
    println("Arb + direct-only EV: ", round(compute_ev(s5), digits=2))
    println("  cash: ", round(s5.cash, digits=4))
    println("  holdings[1:3]: ", round.(s5.holdings[1:3], digits=1))

    # Cyclic: (deploy → arb → deploy → arb → ...)
    s7 = SimState(copy(init_prices), zeros(N), 6.5, copy(liq))
    for cycle in 1:20
        arb_profit = run_complete_set_arb!(s7)
        run_direct_only!(s7)
        ev = compute_ev(s7)
        if cycle <= 5 || cycle == 20
            println("Cycle $cycle: arb_profit=$(round(arb_profit, digits=2)), ev=$(round(ev, digits=2)), cash=$(round(s7.cash, digits=4)), price_sum=$(round(sum(s7.prices), digits=6))")
        end
    end
    println("Cyclic EV: ", round(compute_ev(s7), digits=2))

    println("\nNative benchmark: 132.03")
end

main()
