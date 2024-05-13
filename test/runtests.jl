using ConvexFlows
using Test

using LinearAlgebra, Random
using LogExpFunctions

@testset "edges" begin
    include("edges.jl")

end

@testset "(L)BFGS" begin
    include("bfgs.jl")
end
