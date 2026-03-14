using ForecastFlows
using Test
import ForecastFlows: Objective, grad_Ubar!, lower_limit, upper_limit
import ForecastFlows: find_arb!, is_nonsmooth
import ForecastFlows: Solver, SolveCertificate, solve!, dual_objective, primal_objective, certify_solution, recover_primal!
import ForecastFlows: FixedGasModel, solve_with_fixed_gas!, solve_with_gas_pruning!, GasPruningResult, edge_execution_value
import ForecastFlows: BFGSSolver, BFGSOptions
import ForecastFlows: problem
import ForecastFlows: NonpositiveQuadratic, Linear, LinearNonnegative, EndowmentLinear, BasketLiquidation, BasketAcquisition, Markowitz, Swap, SwapExactOutput
import ForecastFlows: U, Ubar, ∇Ubar!
import ForecastFlows: Edge, EdgeGain, EdgeClosedForm, ProductTwoCoin, SplitMergeEdge, UniV3

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

@testset "prediction markets" begin
    include("prediction_markets.jl")
end

@testset "deep_trading compatibility" begin
    include("deep_trading_compat.jl")
end

@testset "api boundary" begin
    include("api_boundary.jl")
end

@testset "protocol fixtures" begin
    include("protocol_fixtures.jl")
end
