using ConvexFlows
using Test

using LinearAlgebra, Random, SparseArrays
using StatsBase
using LogExpFunctions
using ForwardDiff

@testset "objective" begin
    include("objective.jl")
end

@testset "edges" begin
    include("edges.jl")
end

@testset "(L)BFGS" begin
    include("bfgs.jl")
end

@testset "solver" begin
    include("solver_bfgs.jl")
    include("solver.jl")
end
