if deep_trading_compat_opted_in()
    @testset "deep trading net-ev benchmark sweep" begin
        benchmark_pgtol = 1e-6
        benchmark_max_iter = 10_000
        benchmark_max_fun = 20_000
        summary_rows = NamedTuple[]

        for case_id in dt_case_ids
            benchmark = build_case_from_deep_trading(case_id)
            raw_expected = deep_trading_raw_expected(case_id)
            net_expected = deep_trading_net_expected(case_id)
            result = solve_benchmark_case(
                benchmark;
                method=:auto,
                pgtol=benchmark_pgtol,
                max_iter=benchmark_max_iter,
                max_fun=benchmark_max_fun,
            )

            @test result.direct_certified
            @test result.mixed_certified
            @test result.direct_replay.final_cash >= -1e-8
            @test result.mixed_replay.final_cash >= -1e-8
            @test all(result.direct_replay.final_holdings .>= -1e-8)
            @test all(result.mixed_replay.final_holdings .>= -1e-8)
            @test isfinite(result.direct_replay.final_raw_ev)
            @test isfinite(result.mixed_replay.final_raw_ev)
            @test 0.0 <= result.direct_replay.fill_fraction <= 1.0
            @test 0.0 <= result.mixed_replay.fill_fraction <= 1.0
            @test result.direct_replay.final_raw_ev <= result.direct_raw_upper_ev + 1e-6
            @test result.mixed_replay.final_raw_ev <= result.mixed_raw_upper_ev + 1e-6

            @test result.direct_replay.final_raw_ev ≥ raw_expected.direct_ev - raw_fixture_atol(case_id, :direct)
            @test result.mixed_replay.final_raw_ev ≥ raw_expected.mixed_ev - raw_fixture_atol(case_id, :mixed)
            @test result.direct_net_ev ≈ net_expected.direct_net_ev atol=1e-9
            @test result.mixed_net_ev ≈ net_expected.mixed_net_ev atol=1e-9
            @test result.best_family == net_expected.best_family
            @test result.best_net_ev ≈ net_expected.best_net_ev atol=1e-9

            push!(summary_rows, (
                case_id=case_id,
                ev_before=benchmark.initial_ev,
                direct_raw_upper_ev=result.direct_raw_upper_ev,
                direct_replayed_raw_ev=result.direct_replay.final_raw_ev,
                direct_net_ev=result.direct_net_ev,
                mixed_raw_upper_ev=result.mixed_raw_upper_ev,
                mixed_replayed_raw_ev=result.mixed_replay.final_raw_ev,
                mixed_net_ev=result.mixed_net_ev,
                best_family=result.best_family,
                best_net_ev=result.best_net_ev,
                gap_to_dt_direct=result.direct_replay.final_raw_ev - raw_expected.direct_ev,
                gap_to_dt_mixed=result.mixed_replay.final_raw_ev - raw_expected.mixed_ev,
                direct_action_count=active_edge_count(result.direct.solver),
                mixed_action_count=active_edge_count(result.mixed.solver),
                direct_group_count=result.direct_fees.group_count,
                mixed_group_count=result.mixed_fees.group_count,
                direct_tx_count=result.direct_fees.tx_count,
                mixed_tx_count=result.mixed_fees.tx_count,
                direct_fee=result.direct_fees.total_fee,
                mixed_fee=result.mixed_fees.total_fee,
                direct_calldata_bytes=result.direct_fees.total_calldata_bytes,
                mixed_calldata_bytes=result.mixed_fees.total_calldata_bytes,
                split_flow=result.mixed.split_flow,
                split_bound=result.mixed.split_bound,
            ))
        end

        @test any(row -> row.case_id == dt_focus_case_id && row.best_family == "mixed", summary_rows)
        @info "deep-trading net-ev benchmark sweep" rows=summary_rows
    end

    @testset "public deep-trading facade benchmark parity" begin
        benchmark_pgtol = 1e-6
        benchmark_max_iter = 10_000
        benchmark_max_fun = 20_000
        summary_rows = NamedTuple[]

        for case_id in dt_case_ids
            benchmark = build_case_from_deep_trading(case_id)
            raw_expected = deep_trading_raw_expected(case_id)
            net_expected = deep_trading_net_expected(case_id)
            problem = public_problem_from_benchmark(benchmark)

            direct_result = solve_prediction_market(
                problem;
                mode=:direct_only,
                certify=true,
                throw_on_fail=false,
                solver_options=(; pgtol=benchmark_pgtol, max_iter=benchmark_max_iter, max_fun=benchmark_max_fun),
            )
            mixed_result = solve_prediction_market(
                problem;
                mode=:mixed_enabled,
                certify=true,
                throw_on_fail=false,
                max_doublings=6,
                solver_options=(; pgtol=benchmark_pgtol, max_iter=benchmark_max_iter, max_fun=benchmark_max_fun),
            )
            comparison = compare_prediction_market_families(
                problem;
                certify=true,
                throw_on_fail=false,
                max_doublings=6,
                solver_options=(; pgtol=benchmark_pgtol, max_iter=benchmark_max_iter, max_fun=benchmark_max_fun),
            )

            direct_public = replay_public_result(benchmark, direct_result)
            mixed_public = replay_public_result(benchmark, mixed_result)
            comparison_direct = replay_public_result(benchmark, comparison.direct_only)
            comparison_mixed = replay_public_result(benchmark, comparison.mixed_enabled)
            best_family = benchmark_best_family(comparison_direct.net_ev, comparison_mixed.net_ev)
            best_net_ev = best_family == "mixed" ? comparison_mixed.net_ev : comparison_direct.net_ev

            @test direct_result.status == "certified"
            @test mixed_result.status == "certified"
            @test comparison.direct_only.status == "certified"
            @test comparison.mixed_enabled.status == "certified"

            @test direct_public.replay.final_cash >= -1e-8
            @test mixed_public.replay.final_cash >= -1e-8
            @test all(direct_public.replay.final_holdings .>= -1e-8)
            @test all(mixed_public.replay.final_holdings .>= -1e-8)

            @test direct_public.replay.final_raw_ev <= direct_result.final_ev + 1e-6
            @test mixed_public.replay.final_raw_ev <= mixed_result.final_ev + 1e-6
            @test comparison_direct.replay.final_raw_ev <= comparison.direct_only.final_ev + 1e-6
            @test comparison_mixed.replay.final_raw_ev <= comparison.mixed_enabled.final_ev + 1e-6

            @test direct_public.replay.final_raw_ev ≥ raw_expected.direct_ev - raw_fixture_atol(case_id, :direct)
            @test mixed_public.replay.final_raw_ev ≥ raw_expected.mixed_ev - raw_fixture_atol(case_id, :mixed)
            @test comparison_direct.net_ev ≈ net_expected.direct_net_ev atol=1e-9
            @test comparison_mixed.net_ev ≈ net_expected.mixed_net_ev atol=1e-9
            @test best_family == net_expected.best_family
            @test best_net_ev ≈ net_expected.best_net_ev atol=1e-9

            push!(summary_rows, (
                case_id=case_id,
                direct_final_ev=direct_result.final_ev,
                direct_replayed_raw_ev=direct_public.replay.final_raw_ev,
                direct_net_ev=direct_public.net_ev,
                mixed_final_ev=mixed_result.final_ev,
                mixed_replayed_raw_ev=mixed_public.replay.final_raw_ev,
                mixed_net_ev=mixed_public.net_ev,
                comparison_direct_net_ev=comparison_direct.net_ev,
                comparison_mixed_net_ev=comparison_mixed.net_ev,
                best_family=best_family,
                best_net_ev=best_net_ev,
            ))
        end

        @test any(row -> row.case_id == dt_focus_case_id && row.best_family == "mixed", summary_rows)
        @info "public deep-trading facade benchmark parity" rows=summary_rows
    end

    @testset "optional deep-trading consumer competitiveness" begin
        benchmark_pgtol = 1e-6
        benchmark_max_iter = 10_000
        benchmark_max_fun = 20_000
        summary_rows = NamedTuple[]

        for case_id in dt_case_ids
            benchmark = build_case_from_deep_trading(case_id)
            target_net_ev = deep_trading_compatibility_target_net_ev(case_id)
            problem = public_problem_from_benchmark(benchmark)
            gas_model = deep_trading_compatibility_gas_model(problem)

            comparison = compare_prediction_market_families(
                problem;
                gas_model=gas_model,
                certify=true,
                throw_on_fail=false,
                max_doublings=6,
                solver_options=(; pgtol=benchmark_pgtol, max_iter=benchmark_max_iter, max_fun=benchmark_max_fun),
            )

            direct_public = replay_public_result(benchmark, comparison.direct_only)
            mixed_public = replay_public_result(benchmark, comparison.mixed_enabled)
            best_family = benchmark_best_family(direct_public.net_ev, mixed_public.net_ev)
            best_net_ev = best_family == "mixed" ? mixed_public.net_ev : direct_public.net_ev

            @test comparison.direct_only.status == "certified"
            @test comparison.mixed_enabled.status == "certified"
            @test !isnothing(comparison.direct_only.estimated_execution_cost)
            @test !isnothing(comparison.direct_only.net_ev)
            @test !isnothing(comparison.mixed_enabled.estimated_execution_cost)
            @test !isnothing(comparison.mixed_enabled.net_ev)
            @test best_net_ev ≥ target_net_ev - 1e-6

            push!(summary_rows, (
                case_id=case_id,
                direct_net_ev=direct_public.net_ev,
                mixed_net_ev=mixed_public.net_ev,
                best_family=best_family,
                best_net_ev=best_net_ev,
                consumer_target_net_ev=target_net_ev,
            ))
        end

        @test any(row -> row.case_id == dt_focus_case_id && row.best_family == "mixed", summary_rows)
        @info "optional deep-trading consumer competitiveness" rows=summary_rows
    end
end
