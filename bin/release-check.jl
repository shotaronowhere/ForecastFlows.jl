#!/usr/bin/env julia

const REPO_ROOT = dirname(@__DIR__)

function run_step(label::AbstractString, cmd::Cmd; env::Vector{Pair{String,String}}=Pair{String,String}[])
    println("\n==> $label")
    prepared = Cmd(cmd; dir=REPO_ROOT)
    run(isempty(env) ? prepared : addenv(prepared, env...))
end

function main()
    julia_cmd = Base.julia_cmd()

    run_step(
        "release boundary",
        `$(julia_cmd) --project=$(REPO_ROOT) $(joinpath(REPO_ROOT, "bin", "release-boundary-check.jl"))`,
    )
    run_step(
        "default test suite",
        `$(julia_cmd) --project=$(REPO_ROOT) -e $("using Pkg; Pkg.test()")`,
    )
    run_step(
        "worker smoke",
        `$(julia_cmd) --project=$(REPO_ROOT) $(joinpath(REPO_ROOT, "bin", "worker-smoke.jl"))`,
    )
    run_step(
        "latency smoke",
        `$(julia_cmd) --project=$(REPO_ROOT) $(joinpath(REPO_ROOT, "bin", "latency-smoke.jl"))`,
    )
    run_step(
        "docs instantiate",
        `$(julia_cmd) --project=$(joinpath(REPO_ROOT, "docs")) -e $("using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.resolve(); Pkg.instantiate()")`,
    )
    run_step(
        "docs build",
        `$(julia_cmd) --project=$(joinpath(REPO_ROOT, "docs")) $(joinpath(REPO_ROOT, "docs", "make.jl"))`,
    )
    run_step(
        "deep-trading benchmark sweep",
        `$(julia_cmd) --project=$(REPO_ROOT) -e $("using Pkg; Pkg.test()")`;
        env=["FORECASTFLOWS_RUN_DEEPTRADING_BENCHMARK" => "1"],
    )

    println("\nrelease checks passed")
end

main()
