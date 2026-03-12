#!/usr/bin/env julia

using Libdl

function forecastflows_default_worker_sysimage_path(root::AbstractString=dirname(@__DIR__))
    return joinpath(root, "build", "forecastflows-worker.$(Libdl.dlext)")
end

function build_worker_sysimage(sysimage_path::AbstractString=forecastflows_default_worker_sysimage_path())
    try
        @eval using PackageCompiler
    catch err
        error("PackageCompiler is required for this helper. Install it in the active environment before running this script. Original error: $(sprint(showerror, err))")
    end

    mkpath(dirname(sysimage_path))
    precompile_file = joinpath(@__DIR__, "worker-precompile.jl")
    PackageCompiler.create_sysimage(
        [:ForecastFlows, :JSON3, :StructTypes];
        sysimage_path=sysimage_path,
        precompile_execution_file=precompile_file,
    )
    return sysimage_path
end

function main()
    sysimage_path = isempty(ARGS) ? forecastflows_default_worker_sysimage_path() : abspath(ARGS[1])
    println(build_worker_sysimage(sysimage_path))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
