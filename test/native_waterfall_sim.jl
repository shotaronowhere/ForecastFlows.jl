#!/usr/bin/env julia
# Faithful simulation of the Rust native waterfall strategy.
# Strategy discovered from full Rust action log (1142 actions):
#   Phase 0: Buy-all-merge arb (9 rounds, total merge=172.85)
#   Phase 1: Direct deploy 1100 tokens into outcome_0 (cost=31.32)
#   Phase 2: MINT+SELL for outcome_1 (2 rounds, ~20.3 tokens kept)
#   Phase 3: Post-deployment arb recycling (49 rounds, total merge=78.05)
#   Phase 4: Final direct buys (outcome_0: 127.2, outcome_1: 170.0)
#   Final EV: 132.14

const WEIGHTS = [180, 165, 150, 120, 118, 116, 114, 112, 110, 108, 106, 104, 102, 100, 98, 96, 94, 60]
const N = length(WEIGHTS)
const PREDICTIONS = [w / sum(WEIGHTS) for w in WEIGHTS]
const FF = 1.0 - 100.0/1e6

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
    return [PREDICTIONS[i] * factors[i] for i in 1:N], liquidities
end

mutable struct Sim
    prices::Vector{Float64}
    holdings::Vector{Float64}
    cash::Float64
    Ls::Vector{Float64}
end

lambda(s::Sim, i) = sqrt(s.prices[i]) / s.Ls[i]
kappa(s::Sim, i) = FF * sqrt(s.prices[i]) / s.Ls[i]

function buy_exact!(s::Sim, i, amount)
    amount <= 0 && return (0.0, 0.0)
    lam = lambda(s, i)
    d = 1.0 - amount * lam
    d <= 1e-15 && return (0.0, 0.0)
    cost = amount * s.prices[i] / (FF * d)
    s.prices[i] /= d * d
    return (amount, cost)
end

function sell_exact!(s::Sim, i, amount)
    amount <= 0 && return 0.0
    k = kappa(s, i)
    d = 1.0 + amount * k
    proceeds = s.prices[i] * amount * FF / d
    s.prices[i] /= d * d
    return proceeds
end

function buy_spend!(s::Sim, i, spend)
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

compute_ev(s::Sim) = s.cash + sum(PREDICTIONS[i] * s.holdings[i] for i in 1:N)
profitability(pred, price) = price > 0 ? (pred - price) / price : -Inf

function run_buy_merge_arb!(s::Sim)
    total_profit = 0.0
    for _ in 1:10_000
        cap = minimum(begin
            lam = lambda(s, i)
            lam > 0 ? (1.0 - 1e-10) / lam : 0.0
        end for i in 1:N)
        cap <= 0 && break
        lo, hi = 0.0, cap * 0.999
        mc_lo = sum(s.prices[i] / FF for i in 1:N)
        mc_lo >= 1.0 && break
        for _ in 1:64
            mid = (lo + hi) / 2
            mc = sum(begin
                lam = lambda(s, i)
                d = 1.0 - mid * lam
                d <= 0 ? Inf : s.prices[i] / (FF * d * d)
            end for i in 1:N)
            mc <= 1.0 ? (lo = mid) : (hi = mid)
        end
        m = lo
        m <= 1e-15 && break
        total_cost = sum(begin
            lam = lambda(s, i)
            d = 1.0 - m * lam
            d <= 0 ? Inf : m * s.prices[i] / (FF * d)
        end for i in 1:N)
        if total_cost > s.cash
            m *= s.cash / total_cost * 0.99
            m <= 1e-15 && break
        end
        actual_cost = 0.0
        for i in 1:N
            _, c = buy_exact!(s, i, m)
            actual_cost += c
        end
        s.cash -= actual_cost
        s.cash += m
        total_profit += m - actual_cost
    end
    return total_profit
end

function run_mint_sell_arb!(s::Sim)
    # Reverse arb: when psum > 1, mint complete sets and sell all outcomes
    total_profit = 0.0
    for _ in 1:10_000
        # Check marginal sell proceeds at current prices
        ms_hi = sum(s.prices[i] * FF for i in 1:N)
        ms_hi <= 1.0 && break  # psum*FF <= 1, no profit in mint-sell

        # Bisect: find m such that marginal sell proceeds = 1 (cost of mint)
        # After selling m of each, price_i drops: new_price_i = price_i / (1 + m*kappa_i)^2
        # Marginal sell proceeds = sum(price_i * FF / (1 + m*kappa_i)^2)
        lo, hi = 0.0, 1e6
        for _ in 1:64
            mid = (lo + hi) / 2
            ms = sum(begin
                k = kappa(s, i)
                d = 1.0 + mid * k
                s.prices[i] * FF / (d * d)
            end for i in 1:N)
            ms >= 1.0 ? (lo = mid) : (hi = mid)
        end
        m = lo
        m <= 1e-15 && break

        # Mint m sets, sell m of each
        mint!(s, m)
        actual_proceeds = 0.0
        for i in 1:N
            proceeds = sell_exact!(s, i, m)
            s.holdings[i] -= m  # sold
            s.cash += proceeds
            actual_proceeds += proceeds
        end
        profit = actual_proceeds - m
        total_profit += profit
        profit <= 1e-10 && break
    end
    return total_profit
end

function run_complete_set_arb!(s::Sim)
    total = 0.0
    for _ in 1:100  # outer loop to alternate directions
        p1 = run_buy_merge_arb!(s)
        p2 = run_mint_sell_arb!(s)
        total += p1 + p2
        (p1 + p2) <= 1e-10 && break
    end
    return total
end

function mint!(s::Sim, amount)
    s.cash -= amount
    for i in 1:N
        s.holdings[i] += amount
    end
end

function run_direct_only!(s::Sim)
    for _ in 1:200_000
        s.cash <= 1e-10 && break
        profs = [profitability(PREDICTIONS[i], s.prices[i]) for i in 1:N]
        best_i = argmax(profs)
        profs[best_i] <= 0 && break
        spend = min(s.cash, 0.01)
        tokens, cost = buy_spend!(s, best_i, spend)
        s.cash -= min(cost, s.cash)
        s.holdings[best_i] += tokens
    end
end

function main()
    init_prices, liq = build_fixture()

    println("Predictions: ", [round(p, digits=6) for p in PREDICTIONS])
    println("Sum predictions: ", sum(PREDICTIONS))

    # Baseline
    s_base = Sim(copy(init_prices), zeros(N), 6.5, copy(liq))
    arb_profit = run_complete_set_arb!(s_base)
    println("\nAfter arb: profit=$(round(arb_profit, digits=4)), cash=$(round(s_base.cash, digits=4)), psum=$(round(sum(s_base.prices), digits=8))")
    run_direct_only!(s_base)
    baseline_ev = compute_ev(s_base)
    println("Baseline (arb + greedy deploy): EV=$(round(baseline_ev, digits=4))")

    # ============================================================
    # Replicate Rust: arb → large deploy → mint+sell → arb recycle → final deploy
    # ============================================================
    println("\n=== Rust strategy replication ===")
    s = Sim(copy(init_prices), zeros(N), 6.5, copy(liq))
    arb1 = run_complete_set_arb!(s)
    println("Phase 0 (arb): profit=$(round(arb1, digits=4)), cash=$(round(s.cash, digits=4))")

    # Phase 1: Large direct deploy into outcome_0 (idx 1)
    deploy_tokens = 1100.08
    _, deploy_cost = buy_exact!(s, 1, deploy_tokens)
    s.cash -= deploy_cost
    s.holdings[1] += deploy_tokens
    println("Phase 1 (deploy 1100 tokens into outcome_0): cost=$(round(deploy_cost, digits=4)), cash=$(round(s.cash, digits=4)), psum=$(round(sum(s.prices), digits=6))")

    # Phase 2: MINT+SELL for outcome_1 (idx 2)
    for (round_num, M) in enumerate([10.378, 9.949])
        M = min(M, s.cash - 0.001)  # leave tiny buffer
        M <= 0.01 && break
        mint!(s, M)
        round_proceeds = 0.0
        for i in 1:N
            i == 2 && continue  # keep outcome_1
            proceeds = sell_exact!(s, i, M)
            s.holdings[i] -= M
            s.cash += proceeds
            round_proceeds += proceeds
        end
        println("  MINT+SELL round $round_num: M=$(round(M, digits=3)), proceeds=$(round(round_proceeds, digits=4)), net=$(round(M - round_proceeds, digits=4))")
    end
    println("Phase 2: cash=$(round(s.cash, digits=4)), psum=$(round(sum(s.prices), digits=6))")

    # Phase 3: Arb recycling
    psum_before_arb = sum(s.prices)
    mc_before = sum(s.prices[i] / FF for i in 1:N)
    ms_before = sum(s.prices[i] * FF for i in 1:N)
    println("  Pre-arb: psum=$(round(psum_before_arb, digits=6)), mc(buy)=$(round(mc_before, digits=6)), ms(sell)=$(round(ms_before, digits=6))")
    arb2 = run_complete_set_arb!(s)
    println("Phase 3 (arb recycle): profit=$(round(arb2, digits=4)), cash=$(round(s.cash, digits=4)), psum=$(round(sum(s.prices), digits=8))")

    # Phase 4: Final deploy
    run_direct_only!(s)
    final_ev = compute_ev(s)
    println("Phase 4 (final deploy): EV=$(round(final_ev, digits=4)), cash=$(round(s.cash, digits=4))")
    println("Final holdings:")
    for i in 1:N
        s.holdings[i] > 0.01 && println("  outcome $i: $(round(s.holdings[i], digits=2)) tokens, ev=$(round(PREDICTIONS[i]*s.holdings[i], digits=4))")
    end

    # ============================================================
    # Sweep: deploy fraction into outcome_0, then mint+sell + arb recycle
    # ============================================================
    println("\n=== Sweep: deploy fraction → arb → mint+sell → arb → deploy ===")
    s_arbed = Sim(copy(init_prices), zeros(N), 6.5, copy(liq))
    run_complete_set_arb!(s_arbed)
    post_arb_cash = s_arbed.cash

    for deploy_frac in [0.5, 0.6, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95]
        for mint_rounds in [0, 1, 2, 3, 5]
            s2 = Sim(copy(s_arbed.prices), zeros(N), s_arbed.cash, copy(s_arbed.Ls))
            # Deploy into outcome_0
            spend = s2.cash * deploy_frac
            tokens, cost = buy_spend!(s2, 1, spend)
            s2.cash -= min(cost, s2.cash)
            s2.holdings[1] += tokens

            # Arb after deploy
            run_complete_set_arb!(s2)

            # MINT+SELL rounds for outcome_1
            for _ in 1:mint_rounds
                M = min(10.0, s2.cash * 0.5)
                M <= 0.1 && break
                mint!(s2, M)
                for i in 1:N
                    i == 2 && continue
                    proceeds = sell_exact!(s2, i, M)
                    s2.holdings[i] -= M
                    s2.cash += proceeds
                end
                run_complete_set_arb!(s2)
            end

            run_direct_only!(s2)
            ev2 = compute_ev(s2)
            println("  frac=$(lpad(deploy_frac, 4)), mint_rounds=$(lpad(mint_rounds, 2)): EV=$(round(ev2, digits=4)), h0=$(round(s2.holdings[1], digits=1)), h1=$(round(s2.holdings[2], digits=1)), cash=$(round(s2.cash, digits=4))")
        end
    end

    # ============================================================
    # KEY TEST: Iterative deploy → arb loop (Rust's polish pattern)
    # Each deploy creates price distortion; arb captures it as cash; repeat.
    # ============================================================
    println("\n=== Iterative deploy → arb loop ===")
    for deploy_step in [0.5, 1.0, 2.0, 3.0, 5.0, 10.0, 20.0]
        s2 = Sim(copy(s_arbed.prices), zeros(N), s_arbed.cash, copy(s_arbed.Ls))
        total_arb = 0.0
        n_rounds = 0
        for _ in 1:1000
            s2.cash <= 1e-10 && break
            profs = [profitability(PREDICTIONS[i], s2.prices[i]) for i in 1:N]
            best_i = argmax(profs)
            profs[best_i] <= 0 && break
            spend = min(deploy_step, s2.cash)
            tokens, cost = buy_spend!(s2, best_i, spend)
            s2.cash -= min(cost, s2.cash)
            s2.holdings[best_i] += tokens
            arb_p = run_complete_set_arb!(s2)
            total_arb += arb_p
            n_rounds += 1
        end
        ev2 = compute_ev(s2)
        println("  step=$(lpad(deploy_step, 5)): rounds=$n_rounds, arb=$(round(total_arb, digits=4)), EV=$(round(ev2, digits=4)), cash=$(round(s2.cash, digits=4)), h0=$(round(s2.holdings[1], digits=1)), h1=$(round(s2.holdings[2], digits=1))")
    end

    # ============================================================
    # Rust-exact: arb → deploy 1100 into outcome_0 → mint+sell → iterative deploy+arb
    # ============================================================
    println("\n=== Rust-exact with iterative recycling ===")
    for recycle_step in [0.5, 1.0, 2.0, 5.0, 10.0]
        s3 = Sim(copy(init_prices), zeros(N), 6.5, copy(liq))
        run_complete_set_arb!(s3)

        # Phase 1: Large deploy into outcome_0
        deploy_tokens = 1100.08
        _, deploy_cost = buy_exact!(s3, 1, deploy_tokens)
        s3.cash -= deploy_cost
        s3.holdings[1] += deploy_tokens

        # Phase 2: MINT+SELL for outcome_1
        for M in [10.378, 9.949]
            M = min(M, s3.cash - 0.001)
            M <= 0.01 && break
            mint!(s3, M)
            for i in 1:N
                i == 2 && continue
                proceeds = sell_exact!(s3, i, M)
                s3.holdings[i] -= M
                s3.cash += proceeds
            end
        end

        # Phase 3: Iterative deploy+arb recycling
        total_arb = 0.0
        n_rounds = 0
        for _ in 1:1000
            s3.cash <= 1e-10 && break
            profs = [profitability(PREDICTIONS[i], s3.prices[i]) for i in 1:N]
            best_i = argmax(profs)
            profs[best_i] <= 0 && break
            spend = min(recycle_step, s3.cash)
            tokens, cost = buy_spend!(s3, best_i, spend)
            s3.cash -= min(cost, s3.cash)
            s3.holdings[best_i] += tokens
            arb_p = run_complete_set_arb!(s3)
            total_arb += arb_p
            n_rounds += 1
        end
        ev3 = compute_ev(s3)
        println("  recycle_step=$(lpad(recycle_step, 5)): rounds=$n_rounds, arb=$(round(total_arb, digits=4)), EV=$(round(ev3, digits=4)), cash=$(round(s3.cash, digits=4)), h0=$(round(s3.holdings[1], digits=1)), h1=$(round(s3.holdings[2], digits=1))")
    end

    println("\nRust benchmark: 132.14")
end

main()
