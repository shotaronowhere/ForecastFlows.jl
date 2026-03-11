module ForecastFlows

using LinearAlgebra, SparseArrays, StaticArrays
using ForwardDiff
using LBFGSB
using Printf

include("utils.jl")

include("bfgs/types.jl")
include("bfgs/bfgs.jl")

include("edges.jl")
include("prediction_markets.jl")
include("objectives.jl")


include("solver.jl")
include("solver_bfgs.jl")

export Objective, Ubar, grad_Ubar!, lower_limit, upper_limit
export Edge, find_arb!, is_nonsmooth
export Solver, SolveCertificate, solve!, dual_objective, primal_objective, certify_solution, recover_primal!, FixedGasModel, solve_with_fixed_gas!, solve_with_gas_pruning!, GasPruningResult, edge_execution_value

export BFGSSolver, BFGSOptions

export problem

# Objectives
export NonpositiveQuadratic, Linear, LinearNonnegative, EndowmentLinear, BasketLiquidation, BasketAcquisition, Markowitz, Swap, SwapExactOutput
export U, ∇U, Ubar, ∇Ubar

# Edges
export Edge, EdgeGain, EdgeClosedForm, ProductTwoCoin, SplitMergeEdge, UniV3

end
