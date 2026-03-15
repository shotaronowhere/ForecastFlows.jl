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
    return sort!(unique(String[m.captures[1] for m in eachmatch(r"""version:\s*["']([^"']+)["']""", content)]))
end

function changelog_version(path::AbstractString)
    content = read(path, String)
    match_obj = match(r"^## v(\d+\.\d+\.\d+)\b"m, content)
    isnothing(match_obj) && error("expected a semver changelog heading in $(relpath(path, REPO_ROOT))")
    return match_obj.captures[1]
end

function main()
    project = TOML.parsefile(joinpath(REPO_ROOT, "Project.toml"))
    version = get(project, "version", nothing)
    version isa AbstractString || error("expected Project.toml version to be a string")
    occursin(r"^\d+\.\d+\.\d+$", version) || error("expected Project.toml version to be semver, got $(repr(version))")
    version == changelog_version(joinpath(REPO_ROOT, "CHANGELOG.md")) ||
        error("expected CHANGELOG.md top release to match Project.toml version $(repr(version))")
    release_tag = "v$(version)"
    compat_julia = get(get(project, "compat", Dict{String,Any}()), "julia", nothing)
    compat_julia == "1.12" || error("expected Project.toml julia compat 1.12, got $(repr(compat_julia))")

    ci_path = joinpath(REPO_ROOT, ".github", "workflows", "CI.yml")
    ci_content = read(ci_path, String)
    workflow_versions(ci_path) == ["1.12"] ||
        error("expected CI workflow to use only Julia 1.12")
    !occursin("arch: x86", ci_content) || error("CI workflow should not include x86 rows for v2")

    assert_contains(joinpath(REPO_ROOT, "README.md"), "## Install $(release_tag)")
    assert_contains(joinpath(REPO_ROOT, "README.md"), "rev=\"$(release_tag)\"")
    assert_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "Once `$(release_tag)` is tagged")
    assert_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "rev=\"$(release_tag)\"")
    assert_contains(joinpath(REPO_ROOT, "CHANGELOG.md"), "PredictionMarketWorkspace")

    assert_not_contains(joinpath(REPO_ROOT, "docs", "src", "guide.md"), "solve_with_fixed_gas!")
    assert_not_contains(joinpath(REPO_ROOT, "docs", "src", "prediction_market_router.md"), "solve_with_fixed_gas!")
    assert_not_contains(joinpath(REPO_ROOT, "README.md"), "1.10")
    assert_not_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "1.10")
    assert_not_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "PredictionMarketExecutionGasModel")
    assert_not_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "\"kind\": \"execution_additive\"")

    assert_contains(joinpath(REPO_ROOT, "README.md"), "Rust or another driver still owns supervision, timeouts, gas, tx building, and chain I/O")
    assert_contains(joinpath(REPO_ROOT, "README.md"), "- locally release-verified: macOS `arm64`, Julia `1.12`")
    assert_contains(joinpath(REPO_ROOT, "README.md"), "- one in-flight request per worker")
    assert_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "- gas and native-token pricing")
    assert_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "It does not include gas pricing, tx grouping, calldata packing, or chain I/O.")
    assert_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "- locally release-verified: macOS `arm64`, Julia `1.12`")
    assert_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "one request at a time per worker process")
    assert_contains(joinpath(REPO_ROOT, "docs", "src", "integration.md"), "- driver-owned timeout, restart, and schema-validation policy")

    println("release boundary checks passed")
end

main()
