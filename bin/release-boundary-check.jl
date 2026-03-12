#!/usr/bin/env julia

using TOML

const REPO_ROOT = dirname(@__DIR__)

function assert_contains(path::AbstractString, needle::AbstractString)
    content = read(path, String)
    occursin(needle, content) || error("expected $(repr(needle)) in $(relpath(path, REPO_ROOT))")
    return nothing
end

function assert_not_contains(path::AbstractString, needle::AbstractString)
    content = read(path, String)
    !occursin(needle, content) || error("did not expect $(repr(needle)) in $(relpath(path, REPO_ROOT))")
    return nothing
end

function workflow_versions(path::AbstractString)
    content = read(path, String)
    return sort!(unique(String[m.captures[1] for m in eachmatch(r"version:\s*'([^']+)'", content)]))
end

function main()
    project = TOML.parsefile(joinpath(REPO_ROOT, "Project.toml"))
    version = get(project, "version", nothing)
    version == "2.0.0" || error("expected Project.toml version 2.0.0, got $(repr(version))")
    compat_julia = get(get(project, "compat", Dict{String,Any}()), "julia", nothing)
    compat_julia == "1.12" || error("expected Project.toml julia compat 1.12, got $(repr(compat_julia))")

    ci_path = joinpath(REPO_ROOT, ".github", "workflows", "CI.yml")
    ci_content = read(ci_path, String)
    workflow_versions(ci_path) == ["1.12"] ||
        error("expected CI workflow to use only Julia 1.12")
    !occursin("arch: x86", ci_content) || error("CI workflow should not include x86 rows for v2")

    assert_contains(joinpath(REPO_ROOT, "CHANGELOG.md"), "## v2.0.0")
    assert_contains(joinpath(REPO_ROOT, "CHANGELOG.md"), "PredictionMarketWorkspace")

    assert_not_contains(joinpath(REPO_ROOT, "docs", "src", "guide.md"), "solve_with_fixed_gas!")
    assert_not_contains(joinpath(REPO_ROOT, "docs", "src", "prediction_market_router.md"), "solve_with_fixed_gas!")
    assert_not_contains(joinpath(REPO_ROOT, "README.md"), "1.10")
    assert_not_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "1.10")

    assert_contains(joinpath(REPO_ROOT, "README.md"), "Rust or another driver still owns supervision, timeouts, gas, tx building, and chain I/O")
    assert_contains(joinpath(REPO_ROOT, "README.md"), "- locally release-verified: macOS `arm64`, Julia `1.12`")
    assert_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "- gas and native-token pricing")
    assert_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "It does not include gas pricing, tx grouping, calldata packing, or chain I/O.")
    assert_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "- locally release-verified: macOS `arm64`, Julia `1.12`")

    println("release boundary checks passed")
end

main()
