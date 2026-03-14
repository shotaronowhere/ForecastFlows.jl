abstract type AbstractPredictionMarketSpec{T <: AbstractFloat} end

"""
    PREDICTION_MARKET_PROTOCOL_VERSION

Current stable NDJSON protocol version for foreign-language callers.
"""
const PREDICTION_MARKET_PROTOCOL_VERSION = 2
const PREDICTION_MARKET_WORKER_SAFE_INTEGER_LIMIT = 9_007_199_254_740_991.0

"""
    OutcomeSpec(outcome_id, fair_value, initial_holding)

Pure-data description of one prediction-market outcome under the stable v2
facade. `outcome_id` is the stable external identifier used throughout the
prediction-market API and worker protocol.
"""
struct OutcomeSpec{T <: AbstractFloat}
    outcome_id::String
    fair_value::T
    initial_holding::T

    function OutcomeSpec{T}(
        outcome_id::AbstractString,
        fair_value::T,
        initial_holding::T,
    ) where {T <: AbstractFloat}
        isempty(outcome_id) && throw(ArgumentError("outcome_id must be nonempty"))
        isfinite(fair_value) || throw(ArgumentError("fair_value must be finite"))
        isfinite(initial_holding) && initial_holding >= zero(T) ||
            throw(ArgumentError("initial_holding must be finite and nonnegative"))
        return new{T}(String(outcome_id), fair_value, initial_holding)
    end
end

function OutcomeSpec(outcome_id::AbstractString, fair_value::Real, initial_holding::Real)
    T = promote_type(Float64, typeof(float(fair_value)), typeof(float(initial_holding)))
    return OutcomeSpec{T}(
        _prediction_market_outcome_id(outcome_id, "outcome_id"),
        convert(T, fair_value),
        convert(T, initial_holding),
    )
end

"""
    UniV3LiquidityBand(lower_price, liquidity_L)

User-facing liquidity band for the `UniV3MarketSpec` facade. `lower_price` is
the outcome price at the top of the band, and `liquidity_L` is the standard
Uniswap-style liquidity parameter `L`, not the internal reserve-product `L^2`
used by the low-level `UniV3` edge. `liquidity_L = 0` is allowed only for one
optional final band that marks a hard exhausted-liquidity boundary.
"""
struct UniV3LiquidityBand{T <: AbstractFloat}
    lower_price::T
    liquidity_L::T

    function UniV3LiquidityBand{T}(lower_price::T, liquidity_L::T) where {T <: AbstractFloat}
        isfinite(lower_price) && lower_price > zero(T) || throw(ArgumentError("lower_price must be finite and positive"))
        isfinite(liquidity_L) && liquidity_L >= zero(T) || throw(ArgumentError("liquidity_L must be finite and nonnegative"))
        return new{T}(lower_price, liquidity_L)
    end
end

function UniV3LiquidityBand(lower_price::Real, liquidity_L::Real)
    T = promote_type(Float64, typeof(float(lower_price)), typeof(float(liquidity_L)))
    return UniV3LiquidityBand{T}(convert(T, lower_price), convert(T, liquidity_L))
end

"""
    ConstantProductMarketSpec(market_id, outcome_id, collateral_reserve, outcome_reserve, fee_multiplier)

Pure-data description of a constant-product collateral/outcome market. The
`outcome_id` must match a declared outcome in the enclosing
[`PredictionMarketProblem`](@ref).
"""
struct ConstantProductMarketSpec{T <: AbstractFloat} <: AbstractPredictionMarketSpec{T}
    market_id::String
    outcome_id::String
    collateral_reserve::T
    outcome_reserve::T
    fee_multiplier::T

    function ConstantProductMarketSpec{T}(
        market_id::AbstractString,
        outcome_id::AbstractString,
        collateral_reserve::T,
        outcome_reserve::T,
        fee_multiplier::T,
    ) where {T <: AbstractFloat}
        isempty(market_id) && throw(ArgumentError("market_id must be nonempty"))
        isempty(outcome_id) && throw(ArgumentError("outcome_id must be nonempty"))
        isfinite(collateral_reserve) && collateral_reserve > zero(T) ||
            throw(ArgumentError("collateral_reserve must be finite and positive"))
        isfinite(outcome_reserve) && outcome_reserve > zero(T) ||
            throw(ArgumentError("outcome_reserve must be finite and positive"))
        isfinite(fee_multiplier) && zero(T) < fee_multiplier <= one(T) ||
            throw(ArgumentError("fee_multiplier must lie in (0, 1]"))
        return new{T}(String(market_id), String(outcome_id), collateral_reserve, outcome_reserve, fee_multiplier)
    end
end

function ConstantProductMarketSpec(
    market_id::AbstractString,
    outcome_id::AbstractString,
    collateral_reserve::Real,
    outcome_reserve::Real,
    fee_multiplier::Real,
)
    T = promote_type(Float64, typeof(float(collateral_reserve)), typeof(float(outcome_reserve)), typeof(float(fee_multiplier)))
    return ConstantProductMarketSpec{T}(
        market_id,
        _prediction_market_outcome_id(outcome_id, "outcome_id"),
        convert(T, collateral_reserve),
        convert(T, outcome_reserve),
        convert(T, fee_multiplier),
    )
end

"""
    UniV3MarketSpec(market_id, outcome_id, current_price, bands, fee_multiplier)

Pure-data description of a multi-band collateral/outcome market under the
package `UniV3` edge model.

The stable user-facing constructor accepts `bands::Vector{UniV3LiquidityBand}`
in any order. At least one band must have positive liquidity; a terminal
zero-liquidity band may be used to encode a hard price boundary. `bands` is the
stable public shape; the normalized `lower_ticks` / `liquidity_k` storage is an
internal implementation detail.
"""
struct UniV3MarketSpec{T <: AbstractFloat} <: AbstractPredictionMarketSpec{T}
    market_id::String
    outcome_id::String
    current_price::T
    lower_ticks::Vector{T}
    liquidity_k::Vector{T}
    fee_multiplier::T

    function UniV3MarketSpec{T}(
        market_id::AbstractString,
        outcome_id::AbstractString,
        current_price::T,
        lower_ticks::Vector{T},
        liquidity_k::Vector{T},
        fee_multiplier::T,
    ) where {T <: AbstractFloat}
        isempty(market_id) && throw(ArgumentError("market_id must be nonempty"))
        isempty(outcome_id) && throw(ArgumentError("outcome_id must be nonempty"))
        _prediction_market_validate_public_univ3(current_price, lower_ticks, liquidity_k, fee_multiplier)
        return new{T}(
            String(market_id),
            String(outcome_id),
            current_price,
            lower_ticks,
            liquidity_k,
            fee_multiplier,
        )
    end
end

function _prediction_market_univ3_internal_current_price(current_price::T) where T
    return inv(current_price)
end

function _prediction_market_univ3_internal_lower_ticks(lower_ticks::Vector{T}) where T
    return T[inv(price) for price in Iterators.reverse(lower_ticks)]
end

function _prediction_market_univ3_internal_liquidity_k(liquidity_k::Vector{T}) where T
    isempty(liquidity_k) && return T[]
    if iszero(last(liquidity_k))
        return vcat(T[liquidity_k[i] for i in length(liquidity_k)-1:-1:1], T[last(liquidity_k)])
    end
    return T[liquidity_k[i] for i in length(liquidity_k):-1:1]
end

function _prediction_market_validate_public_univ3(
    current_price::T,
    lower_ticks::Vector{T},
    liquidity_k::Vector{T},
    fee_multiplier::T,
) where T
    internal_current_price = _prediction_market_univ3_internal_current_price(current_price)
    internal_lower_ticks = _prediction_market_univ3_internal_lower_ticks(lower_ticks)
    internal_liquidity_k = _prediction_market_univ3_internal_liquidity_k(liquidity_k)
    UniV3(internal_current_price, internal_lower_ticks, internal_liquidity_k, fee_multiplier, [1, 2])
    return nothing
end

function UniV3MarketSpec(
    market_id::AbstractString,
    outcome_id::AbstractString,
    current_price::Real,
    bands::AbstractVector{<:UniV3LiquidityBand},
    fee_multiplier::Real,
)
    isempty(bands) && throw(ArgumentError("bands must be nonempty"))
    any(band -> band.liquidity_L > 0, bands) || throw(ArgumentError("bands must contain at least one positive-liquidity band"))
    sorted_bands = sort(collect(bands); by=band -> band.lower_price, rev=true)
    zero_band_inds = findall(band -> iszero(band.liquidity_L), sorted_bands)
    length(zero_band_inds) <= 1 || throw(ArgumentError("bands may contain at most one zero-liquidity terminal band"))
    !isempty(zero_band_inds) && only(zero_band_inds) != length(sorted_bands) &&
        throw(ArgumentError("zero-liquidity band must be the final band"))
    lower_prices = [band.lower_price for band in sorted_bands]
    liquidity_k = [band.liquidity_L^2 for band in sorted_bands]
    T = Float64
    T = promote_type(T, typeof(float(current_price)), typeof(float(fee_multiplier)))
    for band in sorted_bands
        T = promote_type(T, typeof(float(band.lower_price)), typeof(float(band.liquidity_L)))
    end
    return UniV3MarketSpec{T}(
        market_id,
        _prediction_market_outcome_id(outcome_id, "outcome_id"),
        convert(T, current_price),
        convert.(T, lower_prices),
        convert.(T, liquidity_k),
        convert(T, fee_multiplier),
    )
end

const _prediction_market_univ3_public_properties = (
    :market_id,
    :outcome_id,
    :current_price,
    :bands,
    :fee_multiplier,
)

function _prediction_market_univ3_bands(spec::UniV3MarketSpec{T}) where T
    return UniV3LiquidityBand{T}[
        UniV3LiquidityBand{T}(price, sqrt(k))
        for (price, k) in zip(getfield(spec, :lower_ticks), getfield(spec, :liquidity_k))
    ]
end

Base.propertynames(::UniV3MarketSpec, private::Bool=false) = private ?
    (_prediction_market_univ3_public_properties..., :lower_ticks, :liquidity_k) :
    _prediction_market_univ3_public_properties

function Base.getproperty(spec::UniV3MarketSpec, name::Symbol)
    name === :bands && return _prediction_market_univ3_bands(spec)
    return getfield(spec, name)
end

function Base.show(io::IO, spec::UniV3MarketSpec)
    print(io, "UniV3MarketSpec(")
    print(io, "market_id=")
    show(io, getfield(spec, :market_id))
    print(io, ", outcome_id=")
    show(io, getfield(spec, :outcome_id))
    print(io, ", current_price=")
    show(io, getfield(spec, :current_price))
    print(io, ", bands=")
    show(io, _prediction_market_univ3_bands(spec))
    print(io, ", fee_multiplier=")
    show(io, getfield(spec, :fee_multiplier))
    print(io, ")")
end

Base.show(io::IO, ::MIME"text/plain", spec::UniV3MarketSpec) = show(io, spec)

"""
    PredictionMarketProblem(outcomes, collateral_balance, markets; split_bound=nothing)

Pure-data description of the one-collateral prediction-market routing problem.
`markets` may omit outcomes entirely or include multiple direct venues for the
same outcome. If `split_bound` is omitted, mixed solves start from
`collateral_balance + sum(initial_holding)` and auto-double until the split/merge
bound is no longer near-active.
"""
struct PredictionMarketProblem{T <: AbstractFloat, O <: AbstractVector, M <: AbstractVector}
    outcomes::O
    collateral_balance::T
    markets::M
    split_bound::Union{Nothing,T}
end

"""
    PredictionMarketFixedGasModel(market_action_costs, split_merge_action_cost)

Optional request-level activation-cost model for public prediction-market solves.
`market_action_costs` is aligned 1:1 with `problem.markets`; `split_merge_action_cost`
is charged when the mixed split/merge edge remains active.

This is a coarse edge-activation surrogate, not an exact transaction compiler. It is
useful when callers want the public facade to discourage marginal churn, but downstream
drivers should still keep chain-specific tx grouping, calldata packing, and final net-EV
accounting outside the package.
"""
struct PredictionMarketFixedGasModel{T <: AbstractFloat}
    market_action_costs::Vector{T}
    split_merge_action_cost::T

    function PredictionMarketFixedGasModel{T}(
        market_action_costs::Vector{T},
        split_merge_action_cost::T,
    ) where {T <: AbstractFloat}
        all(cost -> isfinite(cost) && cost >= zero(T), market_action_costs) ||
            throw(ArgumentError("market_action_costs must be finite and nonnegative"))
        isfinite(split_merge_action_cost) && split_merge_action_cost >= zero(T) ||
            throw(ArgumentError("split_merge_action_cost must be finite and nonnegative"))
        return new{T}(market_action_costs, split_merge_action_cost)
    end
end

function PredictionMarketFixedGasModel(
    market_action_costs::AbstractVector{<:Real},
    split_merge_action_cost::Real,
)
    T = promote_type(Float64, typeof(float(split_merge_action_cost)))
    for cost in market_action_costs
        T = promote_type(T, typeof(float(cost)))
    end
    return PredictionMarketFixedGasModel{T}(convert.(T, collect(market_action_costs)), convert(T, split_merge_action_cost))
end

"""
    PredictionMarketTrade

Signed direct AMM trade recovered from a solved prediction-market instance.
Positive `collateral_delta` / `outcome_delta` means the portfolio receives that
asset; negative means it spends that asset.
"""
struct PredictionMarketTrade{T <: AbstractFloat}
    market_id::String
    outcome_id::String
    collateral_delta::T
    outcome_delta::T
end

"""
    SplitMergePlan

Aggregate fee-free mint and merge flow recovered from the prediction-market
split/merge hyperedge.
"""
struct SplitMergePlan{T <: AbstractFloat}
    mint::T
    merge::T
end

"""
    SolveCertificateSummary

Pure-data copy of the solver certification summary.
"""
struct SolveCertificateSummary{T <: AbstractFloat}
    passed::Bool
    message::String
    primal_value::T
    dual_value::T
    duality_gap::T
    target_residual::T
    bound_residual::T
end

"""
    PredictionMarketSolveResult

Serializable solve output for a prediction-market instance. This contains only
recovered data and certification metadata; it does not expose the internal
`Solver` object.
"""
struct PredictionMarketSolveResult{T <: AbstractFloat}
    status::String
    mode::String
    certificate::Union{Nothing,SolveCertificateSummary{T}}
    solver_time_sec::Float64
    initial_ev::T
    final_ev::T
    ev_gain::T
    estimated_execution_cost::Union{Nothing,T}
    net_ev::Union{Nothing,T}
    outcome_ids::Vector{String}
    initial_collateral::T
    final_collateral::T
    initial_holdings::Vector{T}
    final_holdings::Vector{T}
    trades::Vector{PredictionMarketTrade{T}}
    split_merge::SplitMergePlan{T}
end

struct _PredictionMarketLayout
    outcome_ids::Vector{String}
    outcome_index_by_id::Dict{String,Int}
    market_ids::Vector{String}
    market_outcome_ids::Vector{String}
    market_kinds::Vector{Symbol}
    market_band_counts::Vector{Int}
end

"""
    PredictionMarketWorkspace(problem_template)

Reusable Julia-only workspace for repeated solves over a fixed prediction-market
topology. The stable stateless API remains [`solve_prediction_market`](@ref);
this workspace is the advanced entrypoint when callers want to reuse
normalization, solver buffers, and dual seeds across solves. The stored fields
are implementation details; normal public introspection exposes only the fixed
topology summary.
"""
mutable struct PredictionMarketWorkspace{T <: AbstractFloat}
    layout::_PredictionMarketLayout
    direct_solver::Union{Nothing,Solver{T,Vector{T},EndowmentLinear{T}}}
    mixed_solver::Union{Nothing,Solver{T,Vector{T},EndowmentLinear{T}}}
    direct_seed::Union{Nothing,Vector{T}}
    mixed_seed::Union{Nothing,Vector{T}}
end

const _prediction_market_workspace_public_properties = (:outcome_ids, :market_ids)

Base.propertynames(::PredictionMarketWorkspace, private::Bool=false) = private ?
    (_prediction_market_workspace_public_properties..., :layout, :direct_solver, :mixed_solver, :direct_seed, :mixed_seed) :
    _prediction_market_workspace_public_properties

function Base.getproperty(workspace::PredictionMarketWorkspace, name::Symbol)
    if name === :outcome_ids
        return copy(getfield(getfield(workspace, :layout), :outcome_ids))
    elseif name === :market_ids
        return copy(getfield(getfield(workspace, :layout), :market_ids))
    end
    return getfield(workspace, name)
end

function Base.show(io::IO, workspace::PredictionMarketWorkspace)
    layout = getfield(workspace, :layout)
    print(
        io,
        "PredictionMarketWorkspace(",
        length(getfield(layout, :outcome_ids)),
        " outcomes, ",
        length(getfield(layout, :market_ids)),
        " markets; direct_cached=",
        !isnothing(getfield(workspace, :direct_solver)),
        ", mixed_cached=",
        !isnothing(getfield(workspace, :mixed_solver)),
        ")",
    )
end

Base.show(io::IO, ::MIME"text/plain", workspace::PredictionMarketWorkspace) = show(io, workspace)

abstract type AbstractProtocolRequest end
abstract type AbstractProtocolResponse end

"""
    HealthRequest(; request_id=nothing, protocol_version=PREDICTION_MARKET_PROTOCOL_VERSION)

Typed protocol request for worker health and capability introspection.
"""
struct HealthRequest <: AbstractProtocolRequest
    protocol_version::Int
    request_id::Union{Nothing,String}
end

"""
    SolveRequest(problem; request_id=nothing, protocol_version=PREDICTION_MARKET_PROTOCOL_VERSION, mode=:direct_only, certify=true, throw_on_fail=true, max_doublings=6, solver_options=(;))

Typed protocol request for one prediction-market solve.
"""
struct SolveRequest{T <: AbstractFloat} <: AbstractProtocolRequest
    protocol_version::Int
    request_id::Union{Nothing,String}
    mode::Symbol
    problem::PredictionMarketProblem{T}
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}
    certify::Bool
    throw_on_fail::Bool
    max_doublings::Int
    solver_options::NamedTuple
end

"""
    CompareRequest(problem; request_id=nothing, protocol_version=PREDICTION_MARKET_PROTOCOL_VERSION, certify=true, throw_on_fail=true, max_doublings=6, solver_options=(;))

Typed protocol request that runs both supported prediction-market route
families under one shared option set.
"""
struct CompareRequest{T <: AbstractFloat} <: AbstractProtocolRequest
    protocol_version::Int
    request_id::Union{Nothing,String}
    problem::PredictionMarketProblem{T}
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}
    certify::Bool
    throw_on_fail::Bool
    max_doublings::Int
    solver_options::NamedTuple
end

"""
    HealthResponse

Typed protocol response carrying package version and worker capabilities.
"""
struct HealthResponse <: AbstractProtocolResponse
    protocol_version::Int
    request_id::Union{Nothing,String}
    package::String
    package_version::String
    supported_commands::Vector{String}
    supported_modes::Vector{String}
    supported_market_types::Vector{String}
    stable_interfaces::Vector{String}
    public_interfaces::Vector{String}
    numeric_units::String
    execution_model::String
end

"""
    SolveResponse

Typed protocol response for one prediction-market solve result.
"""
struct SolveResponse{T <: AbstractFloat} <: AbstractProtocolResponse
    protocol_version::Int
    request_id::Union{Nothing,String}
    result::PredictionMarketSolveResult{T}
end

"""
    CompareResponse

Typed protocol response containing both `direct_only` and `mixed_enabled`
prediction-market solve results.
"""
struct CompareResponse{T <: AbstractFloat} <: AbstractProtocolResponse
    protocol_version::Int
    request_id::Union{Nothing,String}
    direct_only::PredictionMarketSolveResult{T}
    mixed_enabled::PredictionMarketSolveResult{T}
end

"""
    ErrorResponse

Typed protocol error response with a stable machine-readable code and message.
"""
struct ErrorResponse <: AbstractProtocolResponse
    protocol_version::Int
    request_id::Union{Nothing,String}
    code::String
    message::String
end

struct _PredictionMarketSolveFailed <: Exception
    message::String
end

Base.showerror(io::IO, err::_PredictionMarketSolveFailed) = print(io, err.message)

StructTypes.StructType(::Type{<:OutcomeSpec}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:PredictionMarketProblem}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:PredictionMarketFixedGasModel}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:UniV3LiquidityBand}) = StructTypes.Struct()
StructTypes.StructType(::Type{<:PredictionMarketTrade}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:SplitMergePlan}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:SolveCertificateSummary}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:PredictionMarketSolveResult}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:ConstantProductMarketSpec}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:UniV3MarketSpec}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:HealthResponse}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:SolveResponse}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:CompareResponse}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:ErrorResponse}) = StructTypes.CustomStruct()

_prediction_market_json_number(x::Real) = isfinite(x) ? x : nothing
_prediction_market_json_vector(xs::AbstractVector{<:Real}) = [_prediction_market_json_number(x) for x in xs]

StructTypes.lower(outcome::OutcomeSpec) = (
    outcome_id=outcome.outcome_id,
    fair_value=_prediction_market_json_number(outcome.fair_value),
    initial_holding=_prediction_market_json_number(outcome.initial_holding),
)

StructTypes.lower(problem::PredictionMarketProblem) = (
    outcomes=[StructTypes.lower(outcome) for outcome in problem.outcomes],
    collateral_balance=_prediction_market_json_number(problem.collateral_balance),
    markets=[StructTypes.lower(spec) for spec in problem.markets],
    split_bound=isnothing(problem.split_bound) ? nothing : _prediction_market_json_number(problem.split_bound),
)

StructTypes.lower(gas_model::PredictionMarketFixedGasModel) = (
    market_action_costs=_prediction_market_json_vector(gas_model.market_action_costs),
    split_merge_action_cost=_prediction_market_json_number(gas_model.split_merge_action_cost),
)

StructTypes.lower(spec::ConstantProductMarketSpec) = (
    type="constant_product",
    market_id=spec.market_id,
    outcome_id=spec.outcome_id,
    collateral_reserve=_prediction_market_json_number(spec.collateral_reserve),
    outcome_reserve=_prediction_market_json_number(spec.outcome_reserve),
    fee_multiplier=_prediction_market_json_number(spec.fee_multiplier),
)

StructTypes.lower(spec::UniV3MarketSpec) = (
    type="univ3",
    market_id=spec.market_id,
    outcome_id=spec.outcome_id,
    current_price=_prediction_market_json_number(spec.current_price),
    bands=[
        (
            lower_price=_prediction_market_json_number(price),
            liquidity_L=_prediction_market_json_number(sqrt(k)),
        )
        for (price, k) in zip(getfield(spec, :lower_ticks), getfield(spec, :liquidity_k))
    ],
    fee_multiplier=_prediction_market_json_number(spec.fee_multiplier),
)

StructTypes.lower(trade::PredictionMarketTrade) = (
    market_id=trade.market_id,
    outcome_id=trade.outcome_id,
    collateral_delta=_prediction_market_json_number(trade.collateral_delta),
    outcome_delta=_prediction_market_json_number(trade.outcome_delta),
)

StructTypes.lower(plan::SplitMergePlan) = (
    mint=_prediction_market_json_number(plan.mint),
    merge=_prediction_market_json_number(plan.merge),
)

StructTypes.lower(cert::SolveCertificateSummary) = (
    passed=cert.passed,
    message=cert.message,
    primal_value=_prediction_market_json_number(cert.primal_value),
    dual_value=_prediction_market_json_number(cert.dual_value),
    duality_gap=_prediction_market_json_number(cert.duality_gap),
    target_residual=_prediction_market_json_number(cert.target_residual),
    bound_residual=_prediction_market_json_number(cert.bound_residual),
)

StructTypes.lower(result::PredictionMarketSolveResult) = (
    status=result.status,
    mode=result.mode,
    certificate=isnothing(result.certificate) ? nothing : StructTypes.lower(result.certificate),
    solver_time_sec=_prediction_market_json_number(result.solver_time_sec),
    initial_ev=_prediction_market_json_number(result.initial_ev),
    final_ev=_prediction_market_json_number(result.final_ev),
    ev_gain=_prediction_market_json_number(result.ev_gain),
    estimated_execution_cost=isnothing(result.estimated_execution_cost) ? nothing : _prediction_market_json_number(result.estimated_execution_cost),
    net_ev=isnothing(result.net_ev) ? nothing : _prediction_market_json_number(result.net_ev),
    outcome_ids=copy(result.outcome_ids),
    initial_collateral=_prediction_market_json_number(result.initial_collateral),
    final_collateral=_prediction_market_json_number(result.final_collateral),
    initial_holdings=_prediction_market_json_vector(result.initial_holdings),
    final_holdings=_prediction_market_json_vector(result.final_holdings),
    trades=[StructTypes.lower(trade) for trade in result.trades],
    split_merge=StructTypes.lower(result.split_merge),
)

StructTypes.lower(resp::HealthResponse) = (
    protocol_version=resp.protocol_version,
    request_id=resp.request_id,
    ok=true,
    command="health",
    result=(
        status="ok",
        package=resp.package,
        package_version=resp.package_version,
        supported_commands=copy(resp.supported_commands),
        supported_modes=copy(resp.supported_modes),
        supported_market_types=copy(resp.supported_market_types),
        stable_interfaces=copy(resp.stable_interfaces),
        public_interfaces=copy(resp.public_interfaces),
        numeric_units=resp.numeric_units,
        execution_model=resp.execution_model,
    ),
)

StructTypes.lower(resp::SolveResponse) = (
    protocol_version=resp.protocol_version,
    request_id=resp.request_id,
    ok=true,
    command="solve_prediction_market",
    result=StructTypes.lower(resp.result),
)

StructTypes.lower(resp::CompareResponse) = (
    protocol_version=resp.protocol_version,
    request_id=resp.request_id,
    ok=true,
    command="compare_prediction_market_families",
    result=(
        direct_only=StructTypes.lower(resp.direct_only),
        mixed_enabled=StructTypes.lower(resp.mixed_enabled),
    ),
)

StructTypes.lower(resp::ErrorResponse) = (
    protocol_version=resp.protocol_version,
    request_id=resp.request_id,
    ok=false,
    error=(
        code=resp.code,
        message=resp.message,
    ),
)

function _prediction_market_outcome_id(value::AbstractString, field::AbstractString)
    isempty(value) && throw(ArgumentError("$field must be nonempty"))
    return String(value)
end

function _prediction_market_eltype(spec::ConstantProductMarketSpec{T}) where T
    return T
end

function _prediction_market_eltype(spec::UniV3MarketSpec{T}) where T
    return T
end

function _prediction_market_eltype(outcome::OutcomeSpec{T}) where T
    return T
end

function _prediction_market_eltype(spec)
    throw(ArgumentError("unsupported prediction-market spec type: $(typeof(spec))"))
end

function _convert_outcome_spec(::Type{T}, outcome::OutcomeSpec) where T
    return OutcomeSpec{T}(outcome.outcome_id, convert(T, outcome.fair_value), convert(T, outcome.initial_holding))
end

function _convert_prediction_market_spec(::Type{T}, spec::ConstantProductMarketSpec) where T
    return ConstantProductMarketSpec{T}(
        spec.market_id,
        spec.outcome_id,
        convert(T, spec.collateral_reserve),
        convert(T, spec.outcome_reserve),
        convert(T, spec.fee_multiplier),
    )
end

function _convert_prediction_market_spec(::Type{T}, spec::UniV3MarketSpec) where T
    return UniV3MarketSpec{T}(
        spec.market_id,
        spec.outcome_id,
        convert(T, spec.current_price),
        convert.(T, getfield(spec, :lower_ticks)),
        convert.(T, getfield(spec, :liquidity_k)),
        convert(T, spec.fee_multiplier),
    )
end

function _convert_prediction_market_gas_model(::Type{T}, gas_model::PredictionMarketFixedGasModel) where T
    return PredictionMarketFixedGasModel{T}(
        convert.(T, gas_model.market_action_costs),
        convert(T, gas_model.split_merge_action_cost),
    )
end

function PredictionMarketProblem(
    outcomes,
    collateral_balance::Real,
    markets;
    split_bound=nothing,
)
    outcome_vals = collect(outcomes)
    market_vals = collect(markets)

    isempty(outcome_vals) && throw(ArgumentError("outcomes must be nonempty"))

    T = Float64
    T = promote_type(T, typeof(float(collateral_balance)))
    for outcome in outcome_vals
        T = promote_type(T, _prediction_market_eltype(outcome))
    end
    for spec in market_vals
        T = promote_type(T, _prediction_market_eltype(spec))
    end
    if !isnothing(split_bound)
        T = promote_type(T, typeof(float(split_bound)))
    end

    converted_outcomes = [_convert_outcome_spec(T, outcome) for outcome in outcome_vals]
    converted_markets = isempty(market_vals) ?
        AbstractPredictionMarketSpec{T}[] :
        [_convert_prediction_market_spec(T, spec) for spec in market_vals]
    balance = convert(T, collateral_balance)
    bound = isnothing(split_bound) ? nothing : convert(T, split_bound)

    isfinite(balance) && balance >= zero(T) || throw(ArgumentError("collateral_balance must be finite and nonnegative"))
    isnothing(bound) || (isfinite(bound) && bound > zero(T)) || throw(ArgumentError("split_bound must be finite and positive"))

    outcome_ids = getfield.(converted_outcomes, :outcome_id)
    length(unique(outcome_ids)) == length(converted_outcomes) ||
        throw(ArgumentError("outcome_id values must be unique"))
    market_ids = getfield.(converted_markets, :market_id)
    length(unique(market_ids)) == length(converted_markets) ||
        throw(ArgumentError("market_id values must be unique"))
    declared_outcomes = Set(outcome_ids)
    for outcome_id in getfield.(converted_markets, :outcome_id)
        outcome_id in declared_outcomes ||
            throw(ArgumentError("market outcome_id \"$outcome_id\" must reference a declared outcome"))
    end

    return PredictionMarketProblem{T,typeof(converted_outcomes),typeof(converted_markets)}(
        converted_outcomes,
        balance,
        converted_markets,
        bound,
)
end

function _market_kind(::ConstantProductMarketSpec)
    return :constant_product
end

function _market_kind(::UniV3MarketSpec)
    return :univ3
end

_market_band_count(::ConstantProductMarketSpec) = 0
_market_band_count(spec::UniV3MarketSpec) = length(getfield(spec, :lower_ticks))

function _prediction_market_layout(problem::PredictionMarketProblem)
    outcome_ids = copy(getfield.(problem.outcomes, :outcome_id))
    outcome_index_by_id = Dict{String,Int}(outcome_id => i for (i, outcome_id) in enumerate(outcome_ids))
    return _PredictionMarketLayout(
        outcome_ids,
        outcome_index_by_id,
        copy(getfield.(problem.markets, :market_id)),
        copy(getfield.(problem.markets, :outcome_id)),
        [_market_kind(spec) for spec in problem.markets],
        [_market_band_count(spec) for spec in problem.markets],
    )
end

function _prediction_market_compatible_layout(layout::_PredictionMarketLayout, problem::PredictionMarketProblem)
    other = _prediction_market_layout(problem)
    return layout.outcome_ids == other.outcome_ids &&
        layout.market_ids == other.market_ids &&
        layout.market_outcome_ids == other.market_outcome_ids &&
        layout.market_kinds == other.market_kinds &&
        layout.market_band_counts == other.market_band_counts
end

function _default_split_bound(problem::PredictionMarketProblem{T}) where T
    holdings = zero(T)
    for outcome in problem.outcomes
        holdings += outcome.initial_holding
    end
    return max(problem.collateral_balance + holdings, eps(T))
end

function _prediction_market_objective(problem::PredictionMarketProblem{T}) where T
    n = length(problem.outcomes)
    c = Vector{T}(undef, n + 1)
    h0 = Vector{T}(undef, n + 1)
    c[1] = one(T)
    h0[1] = problem.collateral_balance
    for (i, outcome) in enumerate(problem.outcomes)
        c[i + 1] = outcome.fair_value
        h0[i + 1] = outcome.initial_holding
    end
    return EndowmentLinear(c, h0)
end

function _build_prediction_market_edge(spec::ConstantProductMarketSpec{T}, outcome_index::Int) where T
    return ProductTwoCoin([spec.collateral_reserve, spec.outcome_reserve], spec.fee_multiplier, [1, outcome_index + 1])
end

function _build_prediction_market_edge(spec::UniV3MarketSpec{T}, outcome_index::Int) where T
    return UniV3(
        _prediction_market_univ3_internal_current_price(spec.current_price),
        _prediction_market_univ3_internal_lower_ticks(getfield(spec, :lower_ticks)),
        _prediction_market_univ3_internal_liquidity_k(getfield(spec, :liquidity_k)),
        spec.fee_multiplier,
        [1, outcome_index + 1],
    )
end

function _prediction_market_edges(
    problem::PredictionMarketProblem{T},
    layout::_PredictionMarketLayout,
    mode::Symbol,
    split_bound::Union{Nothing,T}=nothing,
) where T
    edges = Edge[]
    for spec in problem.markets
        push!(edges, _build_prediction_market_edge(spec, layout.outcome_index_by_id[spec.outcome_id]))
    end
    if mode == :mixed_enabled
        bound = isnothing(split_bound) ? _default_split_bound(problem) : split_bound
        push!(edges, SplitMergeEdge(collect(1:(length(problem.outcomes) + 1)), bound))
    end
    return edges
end

function _prediction_market_solver(
    problem::PredictionMarketProblem{T},
    layout::_PredictionMarketLayout,
    mode::Symbol,
    split_bound::Union{Nothing,T}=nothing,
) where T
    return Solver(
        flow_objective=_prediction_market_objective(problem),
        edges=_prediction_market_edges(problem, layout, mode, split_bound),
        n=length(problem.outcomes) + 1,
    )
end

function _reset_prediction_market_solver!(solver::Solver{T}) where T
    fill!(solver.y, zero(T))
    fill!(solver.ν, zero(T))
    fill!(solver.μ0, zero(T))
    solver.certificate = nothing
    for xs in solver.xs
        fill!(xs, zero(T))
    end
    for η in solver.ηts
        fill!(η, zero(T))
    end
    for prices in solver.arb_prices
        fill!(prices, zero(T))
    end
    return solver
end

function _update_prediction_market_objective!(solver::Solver{T}, problem::PredictionMarketProblem{T}) where T
    obj = solver.flow_objective
    obj isa EndowmentLinear{T} || error("prediction-market workspace expects EndowmentLinear flow objective")
    obj.c[1] = one(T)
    obj.h0[1] = problem.collateral_balance
    for (i, outcome) in enumerate(problem.outcomes)
        obj.c[i + 1] = outcome.fair_value
        obj.h0[i + 1] = outcome.initial_holding
    end
    return solver
end

function _update_prediction_market_solver!(
    solver::Solver{T},
    problem::PredictionMarketProblem{T},
    layout::_PredictionMarketLayout,
    mode::Symbol,
    split_bound::Union{Nothing,T}=nothing,
) where T
    _update_prediction_market_objective!(solver, problem)
    for (i, spec) in enumerate(problem.markets)
        solver.edges[i] = _build_prediction_market_edge(spec, layout.outcome_index_by_id[spec.outcome_id])
    end
    if mode == :mixed_enabled
        bound = isnothing(split_bound) ? _default_split_bound(problem) : split_bound
        solver.edges[end] = SplitMergeEdge(collect(1:(length(problem.outcomes) + 1)), bound)
    end
    return _reset_prediction_market_solver!(solver)
end

function PredictionMarketWorkspace(problem_template::PredictionMarketProblem{T}) where T
    return PredictionMarketWorkspace{T}(_prediction_market_layout(problem_template), nothing, nothing, nothing, nothing)
end

function _workspace_solver!(
    workspace::PredictionMarketWorkspace{T},
    problem::PredictionMarketProblem{T},
    mode::Symbol,
    split_bound::Union{Nothing,T}=nothing,
) where T
    _prediction_market_compatible_layout(workspace.layout, problem) ||
        throw(ArgumentError("problem topology does not match workspace template"))
    if mode == :direct_only
        if isnothing(workspace.direct_solver)
            workspace.direct_solver = _prediction_market_solver(problem, workspace.layout, mode, split_bound)
        else
            _update_prediction_market_solver!(workspace.direct_solver::Solver{T}, problem, workspace.layout, mode, split_bound)
        end
        return workspace.direct_solver::Solver{T}
    end

    if isnothing(workspace.mixed_solver)
        workspace.mixed_solver = _prediction_market_solver(problem, workspace.layout, mode, split_bound)
    else
        _update_prediction_market_solver!(workspace.mixed_solver::Solver{T}, problem, workspace.layout, mode, split_bound)
    end
    return workspace.mixed_solver::Solver{T}
end

function _workspace_seed(workspace::PredictionMarketWorkspace, mode::Symbol)
    return mode == :direct_only ? workspace.direct_seed : workspace.mixed_seed
end

function _store_workspace_seed!(workspace::PredictionMarketWorkspace{T}, mode::Symbol, seed::AbstractVector{T}) where T
    copied = copy(seed)
    if mode == :direct_only
        workspace.direct_seed = copied
    else
        workspace.mixed_seed = copied
    end
    return nothing
end

function _prediction_market_validate_gas_model(
    problem::PredictionMarketProblem{T},
    gas_model::PredictionMarketFixedGasModel{T},
) where T
    length(gas_model.market_action_costs) == length(problem.markets) ||
        throw(ArgumentError("gas_model.market_action_costs must have one cost per problem market"))
    return nothing
end

function _prediction_market_internal_gas_model(
    problem::PredictionMarketProblem{T},
    gas_model::PredictionMarketFixedGasModel{T},
    mode::Symbol,
) where T
    _prediction_market_validate_gas_model(problem, gas_model)
    action_costs = copy(gas_model.market_action_costs)
    if mode == :mixed_enabled
        push!(action_costs, gas_model.split_merge_action_cost)
    end
    return FixedGasModel(action_costs)
end

function _prediction_market_estimated_execution_cost(
    solver::Solver{T},
    gas_model::PredictionMarketFixedGasModel{T},
    mode::Symbol;
    atol::T=max(convert(T, 1e-12), sqrt(eps(T))),
) where T
    cost = zero(T)
    for (edge_idx, edge_cost) in enumerate(gas_model.market_action_costs)
        edge_is_active(solver.xs[edge_idx]; atol=atol) || continue
        cost += edge_cost
    end
    if mode == :mixed_enabled && length(solver.xs) > length(gas_model.market_action_costs)
        edge_is_active(solver.xs[length(gas_model.market_action_costs) + 1]; atol=atol) && (cost += gas_model.split_merge_action_cost)
    end
    return cost
end

function _extract_split_merge_plan(x::AbstractVector{T}; atol::T=max(convert(T, 1e-12), sqrt(eps(T)))) where T
    length(x) <= 1 && return SplitMergePlan(zero(T), zero(T))
    w = sum(@view x[2:end]) / convert(T, length(x) - 1)
    if w > atol
        return SplitMergePlan(w, zero(T))
    elseif w < -atol
        return SplitMergePlan(zero(T), -w)
    end
    return SplitMergePlan(zero(T), zero(T))
end

function _extract_prediction_market_trades(problem::PredictionMarketProblem{T}, s::Solver{T}; atol::T=max(convert(T, 1e-12), sqrt(eps(T)))) where T
    trades = PredictionMarketTrade{T}[]
    for (spec, x) in zip(problem.markets, s.xs[1:length(problem.markets)])
        abs(x[1]) <= atol && abs(x[2]) <= atol && continue
        push!(trades, PredictionMarketTrade{T}(spec.market_id, spec.outcome_id, x[1], x[2]))
    end
    split_merge = length(s.xs) > length(problem.markets) ?
        _extract_split_merge_plan(s.xs[end]; atol=atol) :
        SplitMergePlan(zero(T), zero(T))
    return trades, split_merge
end

function _certificate_summary(cert::SolveCertificate{T}) where T
    return SolveCertificateSummary{T}(
        cert.passed,
        cert.message,
        cert.primal_value,
        cert.dual_value,
        cert.duality_gap,
        cert.target_residual,
        cert.bound_residual,
    )
end

function _append_prediction_market_message(existing::AbstractString, extra::AbstractString)
    isempty(existing) && return String(extra)
    occursin(extra, existing) && return String(existing)
    return String(existing) * "; " * String(extra)
end

function _mark_prediction_market_uncertified(
    result::PredictionMarketSolveResult{T},
    message::AbstractString,
) where T
    cert = result.certificate
    new_cert = if isnothing(cert)
        nothing
    else
        SolveCertificateSummary{T}(
            false,
            _append_prediction_market_message(cert.message, message),
            cert.primal_value,
            cert.dual_value,
            cert.duality_gap,
            cert.target_residual,
            cert.bound_residual,
        )
    end
    return PredictionMarketSolveResult{T}(
        "uncertified",
        result.mode,
        new_cert,
        result.solver_time_sec,
        result.initial_ev,
        result.final_ev,
        result.ev_gain,
        result.estimated_execution_cost,
        result.net_ev,
        copy(result.outcome_ids),
        result.initial_collateral,
        result.final_collateral,
        copy(result.initial_holdings),
        copy(result.final_holdings),
        copy(result.trades),
        result.split_merge,
    )
end

function _prediction_market_result(
    problem::PredictionMarketProblem{T},
    s::Solver{T},
    mode::Symbol,
    solve_time::Real;
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}=nothing,
    gas_atol::T=max(convert(T, 1e-12), sqrt(eps(T))),
) where T
    outcome_ids = copy(getfield.(problem.outcomes, :outcome_id))
    initial_holdings = [outcome.initial_holding for outcome in problem.outcomes]
    outcome_values = [outcome.fair_value for outcome in problem.outcomes]
    initial_ev = problem.collateral_balance + dot(outcome_values, initial_holdings)
    final_collateral = problem.collateral_balance + s.y[1]
    final_holdings = initial_holdings .+ s.y[2:end]
    final_ev = final_collateral + dot(outcome_values, final_holdings)
    trades, split_merge = _extract_prediction_market_trades(problem, s)
    estimated_execution_cost = isnothing(gas_model) ? nothing : _prediction_market_estimated_execution_cost(s, gas_model, mode; atol=gas_atol)
    net_ev = isnothing(estimated_execution_cost) ? nothing : final_ev - estimated_execution_cost
    cert_summary = isnothing(s.certificate) ? nothing : _certificate_summary(s.certificate)
    status = isnothing(cert_summary) ? "solved" : (cert_summary.passed ? "certified" : "uncertified")
    return PredictionMarketSolveResult{T}(
        status,
        String(mode),
        cert_summary,
        Float64(solve_time),
        initial_ev,
        final_ev,
        final_ev - initial_ev,
        estimated_execution_cost,
        net_ev,
        outcome_ids,
        problem.collateral_balance,
        final_collateral,
        initial_holdings,
        final_holdings,
        trades,
        split_merge,
    )
end

function _prediction_market_trivial_result(
    problem::PredictionMarketProblem{T},
    mode::Symbol;
    certify::Bool=true,
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}=nothing,
) where T
    outcome_ids = copy(getfield.(problem.outcomes, :outcome_id))
    initial_holdings = T[outcome.initial_holding for outcome in problem.outcomes]
    outcome_values = T[outcome.fair_value for outcome in problem.outcomes]
    initial_ev = problem.collateral_balance + dot(outcome_values, initial_holdings)
    estimated_execution_cost = isnothing(gas_model) ? nothing : zero(T)
    net_ev = isnothing(estimated_execution_cost) ? nothing : initial_ev
    certificate = certify ? SolveCertificateSummary{T}(
        true,
        "certified",
        zero(T),
        zero(T),
        zero(T),
        zero(T),
        zero(T),
    ) : nothing
    status = certify ? "certified" : "solved"
    return PredictionMarketSolveResult{T}(
        status,
        String(mode),
        certificate,
        0.0,
        initial_ev,
        initial_ev,
        zero(T),
        estimated_execution_cost,
        net_ev,
        outcome_ids,
        problem.collateral_balance,
        problem.collateral_balance,
        initial_holdings,
        copy(initial_holdings),
        PredictionMarketTrade{T}[],
        SplitMergePlan(zero(T), zero(T)),
    )
end

function _prediction_market_solver_options(solver_options)
    solver_options isa NamedTuple || throw(ArgumentError("solver_options must be a NamedTuple"))
    return solver_options
end

function _solve_prediction_market_once(
    problem::PredictionMarketProblem{T};
    mode::Symbol,
    split_bound::Union{Nothing,T}=nothing,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    solver_options::NamedTuple=(;),
    workspace::Union{Nothing,PredictionMarketWorkspace{T}}=nothing,
    ν0::Union{Nothing,AbstractVector{T}}=nothing,
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}=nothing,
) where T
    if mode == :direct_only && isempty(problem.markets)
        !isnothing(gas_model) && _prediction_market_validate_gas_model(problem, gas_model)
        if !isnothing(workspace)
            _prediction_market_compatible_layout(workspace.layout, problem) ||
                throw(ArgumentError("problem topology does not match workspace template"))
        end
        return _prediction_market_trivial_result(problem, mode; certify=certify, gas_model=gas_model), zeros(T, length(problem.outcomes) + 1)
    end

    layout = isnothing(workspace) ? _prediction_market_layout(problem) : workspace.layout::_PredictionMarketLayout
    solver = isnothing(workspace) ?
        _prediction_market_solver(problem, layout, mode, split_bound) :
        _workspace_solver!(workspace, problem, mode, split_bound)
    seed = isnothing(ν0) && !isnothing(workspace) ? _workspace_seed(workspace, mode) : ν0
    internal_gas_model = isnothing(gas_model) ? nothing : _prediction_market_internal_gas_model(problem, gas_model, mode)

    solve_time = try
        if isnothing(internal_gas_model)
            solve!(solver; certify=certify, throw_on_fail=throw_on_fail, ν0=seed, solver_options...)
        else
            gas_pruning = solve_with_fixed_gas!(solver, internal_gas_model; certify=certify, ν0=seed, solver_options...)
            if throw_on_fail && certify && (isnothing(solver.certificate) || !solver.certificate.passed)
                cert_message = isnothing(solver.certificate) ? "missing certificate after gas-aware solve" : solver.certificate.message
                throw(_PredictionMarketSolveFailed("solve_with_fixed_gas! failed certification: $(cert_message)"))
            end
            gas_pruning.solve_time
        end
    catch err
        if throw_on_fail && err isa ErrorException
            message = sprint(showerror, err)
            startswith(message, "solve! failed certification:") && throw(_PredictionMarketSolveFailed(message))
        end
        rethrow(err)
    end

    !isnothing(workspace) && _store_workspace_seed!(workspace, mode, solver.ν)
    return _prediction_market_result(problem, solver, mode, solve_time; gas_model=gas_model), copy(solver.ν)
end

function _solve_prediction_market_mixed(
    problem::PredictionMarketProblem{T};
    max_doublings::Int=6,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    solver_options::NamedTuple=(;),
    workspace::Union{Nothing,PredictionMarketWorkspace{T}}=nothing,
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}=nothing,
) where T
    max_doublings >= 0 || throw(ArgumentError("max_doublings must be nonnegative"))

    split_bound = isnothing(problem.split_bound) ? _default_split_bound(problem) : problem.split_bound
    best_result = nothing
    ν_seed = nothing
    for doubling in 0:max_doublings
        result, ν_seed = _solve_prediction_market_once(
            problem;
            mode=:mixed_enabled,
            split_bound=split_bound,
            certify=certify,
            throw_on_fail=throw_on_fail,
            solver_options=solver_options,
            workspace=workspace,
            ν0=ν_seed,
            gas_model=gas_model,
        )
        best_result = result
        if max(result.split_merge.mint, result.split_merge.merge) < convert(T, 0.8) * split_bound
            return result
        end
        if doubling == max_doublings
            message = "split/merge bound remained near-active after $(max_doublings) doublings (bound=$(split_bound))"
            if throw_on_fail
                throw(_PredictionMarketSolveFailed(message))
            end
            return _mark_prediction_market_uncertified(result, message)
        end
        split_bound *= convert(T, 2)
    end
    return best_result
end

"""
    solve_prediction_market(problem; mode=:direct_only, gas_model=nothing, certify=true, throw_on_fail=true, max_doublings=6, solver_options=(;))

Solve a one-collateral prediction-market routing problem and return a pure-data
[`PredictionMarketSolveResult`](@ref). `mode=:mixed_enabled` adds a single
fee-free `SplitMergeEdge`; when the split bound is near-active, the solver
rebuilds the mixed problem with a doubled bound up to `max_doublings` times.
With `mode=:direct_only` and no direct markets, the facade returns the trivial
no-trade route.
"""
function solve_prediction_market(
    problem::PredictionMarketProblem{T};
    mode::Symbol=:direct_only,
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}=nothing,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    max_doublings::Int=6,
    solver_options::NamedTuple=(;),
) where T
    mode in (:direct_only, :mixed_enabled) || throw(ArgumentError("mode must be :direct_only or :mixed_enabled"))
    mode == :mixed_enabled && length(problem.outcomes) < 2 &&
        throw(ArgumentError("mixed_enabled routing requires at least two outcomes"))
    checked_solver_options = _prediction_market_solver_options(solver_options)
    if mode == :direct_only
        result, _ = _solve_prediction_market_once(
            problem;
            mode=mode,
            certify=certify,
            throw_on_fail=throw_on_fail,
            solver_options=checked_solver_options,
            gas_model=gas_model,
        )
        return result
    end
    return _solve_prediction_market_mixed(
        problem;
        max_doublings=max_doublings,
        certify=certify,
        throw_on_fail=throw_on_fail,
        solver_options=checked_solver_options,
        gas_model=gas_model,
    )
end

"""
    solve_prediction_market!(workspace, problem; mode=:direct_only, gas_model=nothing, certify=true, throw_on_fail=true, max_doublings=6, solver_options=(;))

Advanced repeated-solve entrypoint that reuses workspace normalization and, when
possible, solver buffers and dual seeds across calls. The input `problem` must
match the workspace topology exactly: the same outcome IDs in the same order,
the same market IDs in the same order, the same market types, and the same
`UniV3` band counts. With `mode=:direct_only` and no direct markets, this
returns the trivial no-trade route without invoking the generic solver.
"""
function solve_prediction_market!(
    workspace::PredictionMarketWorkspace{T},
    problem::PredictionMarketProblem{T};
    mode::Symbol=:direct_only,
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}=nothing,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    max_doublings::Int=6,
    solver_options::NamedTuple=(;),
) where T
    mode in (:direct_only, :mixed_enabled) || throw(ArgumentError("mode must be :direct_only or :mixed_enabled"))
    mode == :mixed_enabled && length(problem.outcomes) < 2 &&
        throw(ArgumentError("mixed_enabled routing requires at least two outcomes"))
    checked_solver_options = _prediction_market_solver_options(solver_options)
    if mode == :direct_only
        result, _ = _solve_prediction_market_once(
            problem;
            mode=mode,
            certify=certify,
            throw_on_fail=throw_on_fail,
            solver_options=checked_solver_options,
            workspace=workspace,
            gas_model=gas_model,
        )
        return result
    end
    return _solve_prediction_market_mixed(
        problem;
        max_doublings=max_doublings,
        certify=certify,
        throw_on_fail=throw_on_fail,
        solver_options=checked_solver_options,
        workspace=workspace,
        gas_model=gas_model,
    )
end

"""
    compare_prediction_market_families(problem; gas_model=nothing, certify=true, throw_on_fail=true, max_doublings=6, solver_options=(;))

Run both `:direct_only` and `:mixed_enabled` prediction-market solves under the
same settings and return `(direct_only=..., mixed_enabled=...)`.
"""
function compare_prediction_market_families(
    problem::PredictionMarketProblem{T};
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}=nothing,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    max_doublings::Int=6,
    solver_options::NamedTuple=(;),
) where T
    checked_solver_options = _prediction_market_solver_options(solver_options)
    workspace = PredictionMarketWorkspace(problem)
    return (
        direct_only=solve_prediction_market!(workspace, problem; mode=:direct_only, gas_model=gas_model, certify=certify, throw_on_fail=throw_on_fail, solver_options=checked_solver_options),
        mixed_enabled=solve_prediction_market!(workspace, problem; mode=:mixed_enabled, gas_model=gas_model, certify=certify, throw_on_fail=throw_on_fail, max_doublings=max_doublings, solver_options=checked_solver_options),
    )
end

HealthRequest(; request_id=nothing, protocol_version::Integer=PREDICTION_MARKET_PROTOCOL_VERSION) =
    HealthRequest(Int(protocol_version), isnothing(request_id) ? nothing : String(request_id))

function SolveRequest(
    problem::PredictionMarketProblem{T};
    request_id=nothing,
    protocol_version::Integer=PREDICTION_MARKET_PROTOCOL_VERSION,
    mode::Symbol=:direct_only,
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}=nothing,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    max_doublings::Int=6,
    solver_options::NamedTuple=(;),
) where T
    return SolveRequest{T}(Int(protocol_version), isnothing(request_id) ? nothing : String(request_id), mode, problem, gas_model, certify, throw_on_fail, max_doublings, solver_options)
end

function CompareRequest(
    problem::PredictionMarketProblem{T};
    request_id=nothing,
    protocol_version::Integer=PREDICTION_MARKET_PROTOCOL_VERSION,
    gas_model::Union{Nothing,PredictionMarketFixedGasModel{T}}=nothing,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    max_doublings::Int=6,
    solver_options::NamedTuple=(;),
) where T
    return CompareRequest{T}(Int(protocol_version), isnothing(request_id) ? nothing : String(request_id), problem, gas_model, certify, throw_on_fail, max_doublings, solver_options)
end

function _prediction_market_protocol_require(obj, field::Symbol, path::AbstractString)
    hasproperty(obj, field) || throw(ArgumentError("$path is required"))
    return getproperty(obj, field)
end

function _prediction_market_protocol_object(value, field::AbstractString)
    (value isa NamedTuple || value isa JSON3.Object) || throw(ArgumentError("$field must be an object"))
    return value
end

function _prediction_market_protocol_array(value, field::AbstractString)
    value isa AbstractVector || throw(ArgumentError("$field must be an array"))
    return value
end

function _prediction_market_protocol_string(value, field::AbstractString)
    if value isa AbstractString
        return String(value)
    elseif value isa Symbol
        return String(value)
    end
    throw(ArgumentError("$field must be a string"))
end

function _prediction_market_protocol_bool(value, field::AbstractString)
    value isa Bool || throw(ArgumentError("$field must be boolean"))
    return value
end

function _prediction_market_protocol_number(value, field::AbstractString)
    parsed = if value isa AbstractString
        parsed_value = tryparse(Float64, String(value))
        isnothing(parsed_value) && throw(ArgumentError("$field must be parseable as Float64"))
        parsed_value
    elseif value isa Bool
        throw(ArgumentError("$field must be numeric, not boolean"))
    elseif value isa Real
        Float64(value)
    else
        throw(ArgumentError("$field must be numeric"))
    end
    isfinite(parsed) || throw(ArgumentError("$field must be finite"))
    return parsed
end

function _prediction_market_protocol_float(value, field::AbstractString; quantity::Bool=false)
    parsed = _prediction_market_protocol_number(value, field)
    quantity && abs(parsed) > PREDICTION_MARKET_WORKER_SAFE_INTEGER_LIMIT && isinteger(parsed) &&
        throw(ArgumentError("$field exceeds Float64's exact integer range; send decimal-scaled token units instead of raw base-unit integers"))
    return parsed
end

function _prediction_market_protocol_int(value, field::AbstractString)
    parsed = _prediction_market_protocol_number(value, field)
    isinteger(parsed) || throw(ArgumentError("$field must be an integer"))
    abs(parsed) <= float(typemax(Int)) || throw(ArgumentError("$field is outside Int range"))
    return Int(parsed)
end

function _prediction_market_protocol_optional_request_id(payload)
    hasproperty(payload, :request_id) || return nothing
    return _prediction_market_protocol_string(getproperty(payload, :request_id), "request_id")
end

function _prediction_market_protocol_band_from_json(obj, path::AbstractString)
    band = _prediction_market_protocol_object(obj, path)
    return UniV3LiquidityBand(
        _prediction_market_protocol_float(_prediction_market_protocol_require(band, :lower_price, "$path.lower_price"), "$path.lower_price"),
        _prediction_market_protocol_float(_prediction_market_protocol_require(band, Symbol("liquidity_L"), "$path.liquidity_L"), "$path.liquidity_L"),
    )
end

function _prediction_market_protocol_market_spec_from_json(obj, path::AbstractString)
    spec = _prediction_market_protocol_object(obj, path)
    if hasproperty(spec, :outcome_index)
        throw(ArgumentError("$path.outcome_index is not supported in protocol v2; send outcome_id and problem.outcomes instead"))
    end
    kind = _prediction_market_protocol_string(_prediction_market_protocol_require(spec, :type, "$path.type"), "$path.type")
    market_id = _prediction_market_protocol_string(_prediction_market_protocol_require(spec, :market_id, "$path.market_id"), "$path.market_id")
    outcome_id = _prediction_market_protocol_string(_prediction_market_protocol_require(spec, :outcome_id, "$path.outcome_id"), "$path.outcome_id")

    if kind == "constant_product"
        return ConstantProductMarketSpec(
            market_id,
            outcome_id,
            _prediction_market_protocol_float(_prediction_market_protocol_require(spec, :collateral_reserve, "$path.collateral_reserve"), "$path.collateral_reserve"; quantity=true),
            _prediction_market_protocol_float(_prediction_market_protocol_require(spec, :outcome_reserve, "$path.outcome_reserve"), "$path.outcome_reserve"; quantity=true),
            _prediction_market_protocol_float(_prediction_market_protocol_require(spec, :fee_multiplier, "$path.fee_multiplier"), "$path.fee_multiplier"),
        )
    elseif kind == "univ3"
        current_price = _prediction_market_protocol_float(_prediction_market_protocol_require(spec, :current_price, "$path.current_price"), "$path.current_price")
        fee_multiplier = _prediction_market_protocol_float(_prediction_market_protocol_require(spec, :fee_multiplier, "$path.fee_multiplier"), "$path.fee_multiplier")
        bands_json = _prediction_market_protocol_array(_prediction_market_protocol_require(spec, :bands, "$path.bands"), "$path.bands")
        bands = UniV3LiquidityBand[
            _prediction_market_protocol_band_from_json(band, "$path.bands[$i]")
            for (i, band) in enumerate(bands_json)
        ]
        return UniV3MarketSpec(market_id, outcome_id, current_price, bands, fee_multiplier)
    end

    throw(ArgumentError("$path.type has unsupported value: $kind"))
end

function _prediction_market_protocol_problem_from_json(obj)
    problem = _prediction_market_protocol_object(obj, "problem")
    if hasproperty(problem, :outcome_values) || hasproperty(problem, :initial_cash) || hasproperty(problem, :initial_holdings)
        throw(ArgumentError("protocol v2 requires problem.outcomes and problem.collateral_balance; v1 outcome_values/initial_cash payloads are not supported"))
    end

    outcomes_json = _prediction_market_protocol_array(
        _prediction_market_protocol_require(problem, :outcomes, "problem.outcomes"),
        "problem.outcomes",
    )
    markets_json = _prediction_market_protocol_array(
        _prediction_market_protocol_require(problem, :markets, "problem.markets"),
        "problem.markets",
    )
    split_bound = hasproperty(problem, :split_bound) && !isnothing(problem.split_bound) ?
        _prediction_market_protocol_float(problem.split_bound, "problem.split_bound"; quantity=true) :
        nothing

    outcomes = OutcomeSpec[]
    for (i, entry) in enumerate(outcomes_json)
        outcome = _prediction_market_protocol_object(entry, "problem.outcomes[$i]")
        push!(outcomes, OutcomeSpec(
            _prediction_market_protocol_string(_prediction_market_protocol_require(outcome, :outcome_id, "problem.outcomes[$i].outcome_id"), "problem.outcomes[$i].outcome_id"),
            _prediction_market_protocol_float(_prediction_market_protocol_require(outcome, :fair_value, "problem.outcomes[$i].fair_value"), "problem.outcomes[$i].fair_value"),
            _prediction_market_protocol_float(_prediction_market_protocol_require(outcome, :initial_holding, "problem.outcomes[$i].initial_holding"), "problem.outcomes[$i].initial_holding"; quantity=true),
        ))
    end

    markets = Any[
        _prediction_market_protocol_market_spec_from_json(spec, "problem.markets[$i]")
        for (i, spec) in enumerate(markets_json)
    ]

    return PredictionMarketProblem(
        outcomes,
        _prediction_market_protocol_float(
            _prediction_market_protocol_require(problem, :collateral_balance, "problem.collateral_balance"),
            "problem.collateral_balance";
            quantity=true,
        ),
        markets;
        split_bound=split_bound,
    )
end

function _prediction_market_protocol_gas_model_from_json(obj, problem::PredictionMarketProblem)
    gas_obj = _prediction_market_protocol_object(obj, "gas_model")
    costs_json = _prediction_market_protocol_array(
        _prediction_market_protocol_require(gas_obj, :market_action_costs, "gas_model.market_action_costs"),
        "gas_model.market_action_costs",
    )
    market_action_costs = Float64[
        _prediction_market_protocol_float(cost, "gas_model.market_action_costs[$i]"; quantity=true)
        for (i, cost) in enumerate(costs_json)
    ]
    split_merge_action_cost = _prediction_market_protocol_float(
        _prediction_market_protocol_require(gas_obj, :split_merge_action_cost, "gas_model.split_merge_action_cost"),
        "gas_model.split_merge_action_cost";
        quantity=true,
    )
    return _convert_prediction_market_gas_model(
        typeof(problem.collateral_balance),
        PredictionMarketFixedGasModel(market_action_costs, split_merge_action_cost),
    )
end

function _prediction_market_protocol_options(payload)
    hasproperty(payload, :solve_options) || return (certify=true, throw_on_fail=true, max_doublings=6, solver_options=(;))
    opts = _prediction_market_protocol_object(getproperty(payload, :solve_options), "solve_options")
    kwargs = Pair{Symbol,Any}[]
    for field in (:method, :memory, :factr, :pgtol, :max_fun, :max_iter, :max_restarts)
        hasproperty(opts, field) || continue
        if field == :method
            push!(kwargs, field => Symbol(_prediction_market_protocol_string(getproperty(opts, field), "solve_options.$field")))
        elseif field in (:memory, :max_fun, :max_iter, :max_restarts)
            push!(kwargs, field => _prediction_market_protocol_int(getproperty(opts, field), "solve_options.$field"))
        else
            push!(kwargs, field => _prediction_market_protocol_float(getproperty(opts, field), "solve_options.$field"))
        end
    end

    certify = hasproperty(opts, :certify) ?
        _prediction_market_protocol_bool(getproperty(opts, :certify), "solve_options.certify") :
        true
    throw_on_fail = hasproperty(opts, :throw_on_fail) ?
        _prediction_market_protocol_bool(getproperty(opts, :throw_on_fail), "solve_options.throw_on_fail") :
        true
    max_doublings = hasproperty(opts, :max_doublings) ?
        _prediction_market_protocol_int(getproperty(opts, :max_doublings), "solve_options.max_doublings") :
        6
    return (certify=certify, throw_on_fail=throw_on_fail, max_doublings=max_doublings, solver_options=(; kwargs...))
end

function _parse_protocol_request(payload)
    request_id = _prediction_market_protocol_optional_request_id(payload)
    protocol_version = _prediction_market_protocol_int(
        _prediction_market_protocol_require(payload, :protocol_version, "protocol_version"),
        "protocol_version",
    )
    protocol_version == PREDICTION_MARKET_PROTOCOL_VERSION ||
        throw(ArgumentError("unsupported protocol_version $protocol_version"))
    command = _prediction_market_protocol_string(
        _prediction_market_protocol_require(payload, :command, "command"),
        "command",
    )

    if command == "health"
        return HealthRequest(protocol_version, request_id)
    elseif command == "solve_prediction_market"
        options = _prediction_market_protocol_options(payload)
        mode = hasproperty(payload, :mode) ?
            Symbol(_prediction_market_protocol_string(getproperty(payload, :mode), "mode")) :
            :direct_only
        problem = _prediction_market_protocol_problem_from_json(_prediction_market_protocol_require(payload, :problem, "problem"))
        gas_model = hasproperty(payload, :gas_model) && !isnothing(payload.gas_model) ?
            _prediction_market_protocol_gas_model_from_json(getproperty(payload, :gas_model), problem) :
            nothing
        return SolveRequest(
            problem;
            request_id=request_id,
            protocol_version=protocol_version,
            mode=mode,
            gas_model=gas_model,
            certify=options.certify,
            throw_on_fail=options.throw_on_fail,
            max_doublings=options.max_doublings,
            solver_options=options.solver_options,
        )
    elseif command == "compare_prediction_market_families"
        options = _prediction_market_protocol_options(payload)
        problem = _prediction_market_protocol_problem_from_json(_prediction_market_protocol_require(payload, :problem, "problem"))
        gas_model = hasproperty(payload, :gas_model) && !isnothing(payload.gas_model) ?
            _prediction_market_protocol_gas_model_from_json(getproperty(payload, :gas_model), problem) :
            nothing
        return CompareRequest(
            problem;
            request_id=request_id,
            protocol_version=protocol_version,
            gas_model=gas_model,
            certify=options.certify,
            throw_on_fail=options.throw_on_fail,
            max_doublings=options.max_doublings,
            solver_options=options.solver_options,
        )
    end

    throw(ArgumentError("unsupported command: $command"))
end

"""
    parse_protocol_request(request)

Parse one protocol request line into a typed v2 request object.
"""
function parse_protocol_request(request::AbstractString)
    payload = JSON3.read(request)
    return _parse_protocol_request(payload)
end

"""
    handle_protocol_request(req)

Execute one typed protocol request and return the corresponding typed protocol
response.
"""
function handle_protocol_request(req::HealthRequest)
    return HealthResponse(
        req.protocol_version,
        req.request_id,
        "ForecastFlows",
        string(Base.pkgversion(@__MODULE__)),
        ["health", "solve_prediction_market", "compare_prediction_market_families"],
        ["direct_only", "mixed_enabled"],
        ["constant_product", "univ3"],
        ["prediction_market_facade", "ndjson_protocol"],
        [
            "PredictionMarketWorkspace",
            "PredictionMarketFixedGasModel",
            "solve_prediction_market!",
            "PREDICTION_MARKET_PROTOCOL_VERSION",
            "HealthRequest",
            "SolveRequest",
            "CompareRequest",
            "HealthResponse",
            "SolveResponse",
            "CompareResponse",
            "ErrorResponse",
            "parse_protocol_request",
            "handle_protocol_request",
            "render_protocol_response",
            "handle_protocol_json",
            "serve_protocol",
        ],
        "decimal collateral and outcome token units",
        "stateless NDJSON; one request at a time per worker process",
    )
end

function handle_protocol_request(req::SolveRequest{T}) where T
    result = solve_prediction_market(
        req.problem;
        mode=req.mode,
        gas_model=req.gas_model,
        certify=req.certify,
        throw_on_fail=req.throw_on_fail,
        max_doublings=req.max_doublings,
        solver_options=req.solver_options,
    )
    return SolveResponse{T}(req.protocol_version, req.request_id, result)
end

function handle_protocol_request(req::CompareRequest{T}) where T
    result = compare_prediction_market_families(
        req.problem;
        gas_model=req.gas_model,
        certify=req.certify,
        throw_on_fail=req.throw_on_fail,
        max_doublings=req.max_doublings,
        solver_options=req.solver_options,
    )
    return CompareResponse{T}(req.protocol_version, req.request_id, result.direct_only, result.mixed_enabled)
end

"""
    render_protocol_response(response)

Render one typed protocol response as a JSON string.
"""
render_protocol_response(response::AbstractProtocolResponse) = JSON3.write(response)

_prediction_market_protocol_error_code(err::ArgumentError) = "invalid_request"
_prediction_market_protocol_error_code(err::_PredictionMarketSolveFailed) = "solve_failed"
_prediction_market_protocol_error_code(err::Exception) = "internal_error"

"""
    handle_protocol_json(request)

Parse one protocol request line, execute it, and return the rendered JSON
response string.
"""
function handle_protocol_json(request::AbstractString)
    request_id = nothing
    try
        payload = try
            JSON3.read(request)
        catch err
            throw(ArgumentError("invalid JSON: $(sprint(showerror, err))"))
        end
        request_id = _prediction_market_protocol_optional_request_id(payload)
        return render_protocol_response(handle_protocol_request(_parse_protocol_request(payload)))
    catch err
        err isa Union{InterruptException, OutOfMemoryError, StackOverflowError} && rethrow(err)
        return render_protocol_response(ErrorResponse(
            PREDICTION_MARKET_PROTOCOL_VERSION,
            request_id,
            _prediction_market_protocol_error_code(err),
            sprint(showerror, err),
        ))
    end
end

"""
    serve_protocol(input, output)

Serve the stateless NDJSON worker protocol on `input`/`output`.
"""
function serve_protocol(input::IO, output::IO)
    for line in eachline(input)
        isempty(strip(line)) && continue
        println(output, handle_protocol_json(line))
        flush(output)
    end
    return nothing
end
