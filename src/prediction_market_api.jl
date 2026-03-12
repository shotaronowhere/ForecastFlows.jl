abstract type AbstractPredictionMarketSpec{T <: AbstractFloat} end

"""
    UniV3LiquidityBand(lower_price, liquidity_L)

User-facing liquidity band for the `UniV3MarketSpec` facade. `lower_price` is
the outcome price at the top of the band, and `liquidity_L` is the standard
Uniswap-style liquidity parameter `L`, not the internal reserve-product `L^2`
used by the low-level `UniV3` edge.
"""
struct UniV3LiquidityBand{T <: AbstractFloat}
    lower_price::T
    liquidity_L::T

    function UniV3LiquidityBand{T}(lower_price::T, liquidity_L::T) where {T <: AbstractFloat}
        isfinite(lower_price) && lower_price > zero(T) || throw(ArgumentError("lower_price must be finite and positive"))
        isfinite(liquidity_L) && liquidity_L > zero(T) || throw(ArgumentError("liquidity_L must be finite and positive"))
        return new{T}(lower_price, liquidity_L)
    end
end

function UniV3LiquidityBand(lower_price::Real, liquidity_L::Real)
    T = promote_type(Float64, typeof(float(lower_price)), typeof(float(liquidity_L)))
    return UniV3LiquidityBand{T}(convert(T, lower_price), convert(T, liquidity_L))
end

"""
    ConstantProductMarketSpec(market_id, outcome_index, collateral_reserve, outcome_reserve, fee_multiplier)

Pure-data description of a constant-product collateral/outcome market. The
`outcome_index` is 1-based and must match exactly one outcome in the enclosing
[`PredictionMarketProblem`](@ref).
"""
struct ConstantProductMarketSpec{T <: AbstractFloat} <: AbstractPredictionMarketSpec{T}
    market_id::String
    outcome_index::Int
    collateral_reserve::T
    outcome_reserve::T
    fee_multiplier::T

    function ConstantProductMarketSpec{T}(
        market_id::AbstractString,
        outcome_index::Integer,
        collateral_reserve::T,
        outcome_reserve::T,
        fee_multiplier::T,
    ) where {T <: AbstractFloat}
        isempty(market_id) && throw(ArgumentError("market_id must be nonempty"))
        outcome_index >= 1 || throw(ArgumentError("outcome_index must be at least 1"))
        isfinite(collateral_reserve) && collateral_reserve > zero(T) ||
            throw(ArgumentError("collateral_reserve must be finite and positive"))
        isfinite(outcome_reserve) && outcome_reserve > zero(T) ||
            throw(ArgumentError("outcome_reserve must be finite and positive"))
        isfinite(fee_multiplier) && zero(T) < fee_multiplier <= one(T) ||
            throw(ArgumentError("fee_multiplier must lie in (0, 1]"))
        return new{T}(String(market_id), Int(outcome_index), collateral_reserve, outcome_reserve, fee_multiplier)
    end
end

function ConstantProductMarketSpec(
    market_id::AbstractString,
    outcome_index::Integer,
    collateral_reserve::Real,
    outcome_reserve::Real,
    fee_multiplier::Real,
)
    T = promote_type(Float64, typeof(float(collateral_reserve)), typeof(float(outcome_reserve)), typeof(float(fee_multiplier)))
    return ConstantProductMarketSpec{T}(
        market_id,
        outcome_index,
        convert(T, collateral_reserve),
        convert(T, outcome_reserve),
        convert(T, fee_multiplier),
    )
end

"""
    UniV3MarketSpec(market_id, outcome_index, current_price, lower_ticks, liquidity, fee_multiplier)
    UniV3MarketSpec(market_id, outcome_index, current_price, bands, fee_multiplier)

Pure-data description of a multi-band collateral/outcome market under the
package `UniV3` edge model.

The preferred user-facing constructor accepts `bands::Vector{UniV3LiquidityBand}`
in any order. The legacy parallel-array constructor remains available, but its
`lower_ticks` are actually descending outcome prices and its `liquidity` values
are the low-level reserve-product weights `L^2`.
"""
struct UniV3MarketSpec{T <: AbstractFloat} <: AbstractPredictionMarketSpec{T}
    market_id::String
    outcome_index::Int
    current_price::T
    lower_ticks::Vector{T}
    liquidity::Vector{T}
    fee_multiplier::T

    function UniV3MarketSpec{T}(
        market_id::AbstractString,
        outcome_index::Integer,
        current_price::T,
        lower_ticks::Vector{T},
        liquidity::Vector{T},
        fee_multiplier::T,
    ) where {T <: AbstractFloat}
        isempty(market_id) && throw(ArgumentError("market_id must be nonempty"))
        outcome_index >= 1 || throw(ArgumentError("outcome_index must be at least 1"))
        UniV3(current_price, lower_ticks, liquidity, fee_multiplier, [1, 2])
        return new{T}(
            String(market_id),
            Int(outcome_index),
            current_price,
            lower_ticks,
            liquidity,
            fee_multiplier,
        )
    end
end

function UniV3MarketSpec(
    market_id::AbstractString,
    outcome_index::Integer,
    current_price::Real,
    lower_ticks,
    liquidity,
    fee_multiplier::Real,
)
    tick_vals = collect(lower_ticks)
    liq_vals = collect(liquidity)
    T = Float64
    T = promote_type(T, typeof(float(current_price)), typeof(float(fee_multiplier)))
    for tick in tick_vals
        T = promote_type(T, typeof(float(tick)))
    end
    for amount in liq_vals
        T = promote_type(T, typeof(float(amount)))
    end
    return UniV3MarketSpec{T}(
        market_id,
        outcome_index,
        convert(T, current_price),
        convert.(T, tick_vals),
        convert.(T, liq_vals),
        convert(T, fee_multiplier),
    )
end

function UniV3MarketSpec(
    market_id::AbstractString,
    outcome_index::Integer,
    current_price::Real,
    bands::AbstractVector{<:UniV3LiquidityBand},
    fee_multiplier::Real,
)
    isempty(bands) && throw(ArgumentError("bands must be nonempty"))
    sorted_bands = sort(collect(bands); by=band -> band.lower_price, rev=true)
    lower_prices = [band.lower_price for band in sorted_bands]
    liquidity_k = [band.liquidity_L^2 for band in sorted_bands]
    return UniV3MarketSpec(
        market_id,
        outcome_index,
        current_price,
        lower_prices,
        liquidity_k,
        fee_multiplier,
    )
end

"""
    PredictionMarketProblem(outcome_values, initial_cash, initial_holdings, markets; split_bound=nothing)

Pure-data description of the one-collateral prediction-market routing problem.
`markets` must contain exactly one market spec for each 1-based outcome index.
If `split_bound` is omitted, mixed solves start from `initial_cash + sum(initial_holdings)`
and auto-double until the split/merge bound is no longer near-active.
"""
struct PredictionMarketProblem{T <: AbstractFloat, M <: AbstractVector}
    outcome_values::Vector{T}
    initial_cash::T
    initial_holdings::Vector{T}
    markets::M
    split_bound::Union{Nothing,T}
end

"""
    PredictionMarketTrade

Signed direct AMM trade recovered from a solved prediction-market instance.
Positive `collateral_delta` / `outcome_delta` means the portfolio receives that
asset; negative means it spends that asset.
"""
struct PredictionMarketTrade{T <: AbstractFloat}
    market_id::String
    outcome_index::Int
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
    initial_cash::T
    final_cash::T
    initial_holdings::Vector{T}
    final_holdings::Vector{T}
    trades::Vector{PredictionMarketTrade{T}}
    split_merge::SplitMergePlan{T}
end

StructTypes.StructType(::Type{<:PredictionMarketProblem}) = StructTypes.Struct()
StructTypes.StructType(::Type{<:UniV3LiquidityBand}) = StructTypes.Struct()
StructTypes.StructType(::Type{<:PredictionMarketTrade}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:SplitMergePlan}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:SolveCertificateSummary}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:PredictionMarketSolveResult}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:ConstantProductMarketSpec}) = StructTypes.CustomStruct()
StructTypes.StructType(::Type{<:UniV3MarketSpec}) = StructTypes.CustomStruct()

_prediction_market_json_number(x::Real) = isfinite(x) ? x : nothing
_prediction_market_json_vector(xs::AbstractVector{<:Real}) = [_prediction_market_json_number(x) for x in xs]

StructTypes.lower(spec::ConstantProductMarketSpec) = (
    type="constant_product",
    market_id=spec.market_id,
    outcome_index=spec.outcome_index,
    collateral_reserve=spec.collateral_reserve,
    outcome_reserve=spec.outcome_reserve,
    fee_multiplier=spec.fee_multiplier,
)

StructTypes.lower(spec::UniV3MarketSpec) = (
    type="univ3",
    market_id=spec.market_id,
    outcome_index=spec.outcome_index,
    current_price=spec.current_price,
    bands=[(lower_price=price, liquidity_L=sqrt(k)) for (price, k) in zip(spec.lower_ticks, spec.liquidity)],
    fee_multiplier=spec.fee_multiplier,
)

StructTypes.lower(trade::PredictionMarketTrade) = (
    market_id=trade.market_id,
    outcome_index=trade.outcome_index,
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
    initial_cash=_prediction_market_json_number(result.initial_cash),
    final_cash=_prediction_market_json_number(result.final_cash),
    initial_holdings=_prediction_market_json_vector(result.initial_holdings),
    final_holdings=_prediction_market_json_vector(result.final_holdings),
    trades=[StructTypes.lower(trade) for trade in result.trades],
    split_merge=StructTypes.lower(result.split_merge),
)

function PredictionMarketProblem(
    outcome_values,
    initial_cash::Real,
    initial_holdings,
    markets;
    split_bound=nothing,
)
    outcome_vals = collect(outcome_values)
    holding_vals = collect(initial_holdings)
    market_vals = collect(markets)

    isempty(outcome_vals) && throw(ArgumentError("outcome_values must be nonempty"))
    length(outcome_vals) == length(holding_vals) || throw(ArgumentError("initial_holdings must match outcome_values length"))
    length(outcome_vals) == length(market_vals) || throw(ArgumentError("markets must match outcome_values length"))

    T = Float64
    T = promote_type(T, typeof(float(initial_cash)))
    for value in outcome_vals
        T = promote_type(T, typeof(float(value)))
    end
    for holding in holding_vals
        T = promote_type(T, typeof(float(holding)))
    end
    for spec in market_vals
        T = promote_type(T, _prediction_market_eltype(spec))
    end
    if !isnothing(split_bound)
        T = promote_type(T, typeof(float(split_bound)))
    end

    values = convert.(T, outcome_vals)
    holdings = convert.(T, holding_vals)
    cash = convert(T, initial_cash)
    bound = isnothing(split_bound) ? nothing : convert(T, split_bound)
    converted_markets = [_convert_prediction_market_spec(T, spec) for spec in market_vals]

    all(isfinite, values) || throw(ArgumentError("outcome_values must be finite"))
    isfinite(cash) && cash >= zero(T) || throw(ArgumentError("initial_cash must be finite and nonnegative"))
    all(isfinite, holdings) || throw(ArgumentError("initial_holdings must be finite"))
    all(>=(zero(T)), holdings) || throw(ArgumentError("initial_holdings must be nonnegative"))
    isnothing(bound) || (isfinite(bound) && bound > zero(T)) || throw(ArgumentError("split_bound must be finite and positive"))

    covered = sort([spec.outcome_index for spec in converted_markets])
    covered == collect(1:length(values)) || throw(ArgumentError("markets must cover each 1-based outcome index exactly once"))
    length(unique(getfield.(converted_markets, :market_id))) == length(converted_markets) ||
        throw(ArgumentError("market_id values must be unique"))

    return PredictionMarketProblem{T,typeof(converted_markets)}(values, cash, holdings, converted_markets, bound)
end

"""
    solve_prediction_market(problem; mode=:direct_only, certify=true, throw_on_fail=true, max_doublings=6, kwargs...)

Solve a one-collateral prediction-market routing problem and return a pure-data
[`PredictionMarketSolveResult`](@ref). `mode=:mixed_enabled` adds a single
fee-free `SplitMergeEdge`; when the split bound is near-active, the solver
rebuilds the mixed problem with a doubled bound up to `max_doublings` times.
"""
function solve_prediction_market(
    problem::PredictionMarketProblem{T};
    mode::Symbol=:direct_only,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    max_doublings::Int=6,
    kwargs...,
) where T
    mode in (:direct_only, :mixed_enabled) || throw(ArgumentError("mode must be :direct_only or :mixed_enabled"))
    mode == :mixed_enabled && length(problem.outcome_values) < 2 &&
        throw(ArgumentError("mixed_enabled routing requires at least two outcomes"))

    return mode == :direct_only ?
        _solve_prediction_market_once(problem; mode=mode, certify=certify, throw_on_fail=throw_on_fail, kwargs...) :
        _solve_prediction_market_mixed(problem; max_doublings=max_doublings, certify=certify, throw_on_fail=throw_on_fail, kwargs...)
end

"""
    compare_prediction_market_families(problem; certify=true, throw_on_fail=true, max_doublings=6, kwargs...)

Run both `:direct_only` and `:mixed_enabled` prediction-market solves under the
same settings and return `(direct_only=..., mixed_enabled=...)`.
"""
function compare_prediction_market_families(
    problem::PredictionMarketProblem;
    certify::Bool=true,
    throw_on_fail::Bool=true,
    max_doublings::Int=6,
    kwargs...,
)
    return (
        direct_only=solve_prediction_market(problem; mode=:direct_only, certify=certify, throw_on_fail=throw_on_fail, kwargs...),
        mixed_enabled=solve_prediction_market(problem; mode=:mixed_enabled, certify=certify, throw_on_fail=throw_on_fail, max_doublings=max_doublings, kwargs...),
    )
end

const PREDICTION_MARKET_WORKER_PROTOCOL_VERSION = 1
const PREDICTION_MARKET_WORKER_SAFE_INTEGER_LIMIT = 9_007_199_254_740_991.0

struct _PredictionMarketSolveFailed <: Exception
    message::String
end

const _PredictionMarketWorkerSolveFailed = _PredictionMarketSolveFailed

Base.showerror(io::IO, err::_PredictionMarketSolveFailed) = print(io, err.message)

function _prediction_market_eltype(spec::ConstantProductMarketSpec{T}) where T
    return T
end

function _prediction_market_eltype(spec::UniV3MarketSpec{T}) where T
    return T
end

function _prediction_market_eltype(spec)
    throw(ArgumentError("unsupported market spec type: $(typeof(spec))"))
end

function _convert_prediction_market_spec(::Type{T}, spec::ConstantProductMarketSpec) where T
    return ConstantProductMarketSpec{T}(
        spec.market_id,
        spec.outcome_index,
        convert(T, spec.collateral_reserve),
        convert(T, spec.outcome_reserve),
        convert(T, spec.fee_multiplier),
    )
end

function _convert_prediction_market_spec(::Type{T}, spec::UniV3MarketSpec) where T
    return UniV3MarketSpec{T}(
        spec.market_id,
        spec.outcome_index,
        convert(T, spec.current_price),
        convert.(T, spec.lower_ticks),
        convert.(T, spec.liquidity),
        convert(T, spec.fee_multiplier),
    )
end

function _build_prediction_market_edge(spec::ConstantProductMarketSpec{T}) where T
    return ProductTwoCoin([spec.collateral_reserve, spec.outcome_reserve], spec.fee_multiplier, [1, spec.outcome_index + 1])
end

function _build_prediction_market_edge(spec::UniV3MarketSpec{T}) where T
    return UniV3(spec.current_price, spec.lower_ticks, spec.liquidity, spec.fee_multiplier, [1, spec.outcome_index + 1])
end

function _prediction_market_edges(problem::PredictionMarketProblem{T}, mode::Symbol, split_bound::Union{Nothing,T}=nothing) where T
    edges = Edge[_build_prediction_market_edge(spec) for spec in problem.markets]
    if mode == :mixed_enabled
        bound = isnothing(split_bound) ? _default_split_bound(problem) : split_bound
        push!(edges, SplitMergeEdge(collect(1:(length(problem.outcome_values) + 1)), bound))
    end
    return edges
end

function _prediction_market_objective(problem::PredictionMarketProblem{T}) where T
    return EndowmentLinear(vcat(one(T), problem.outcome_values), vcat(problem.initial_cash, problem.initial_holdings))
end

function _default_split_bound(problem::PredictionMarketProblem{T}) where T
    return max(problem.initial_cash + sum(problem.initial_holdings), eps(T))
end

function _split_flow_amount(x::AbstractVector{T}) where T
    isempty(x) && return zero(T)
    length(x) == 1 && return abs(x[1])
    return maximum(abs, @view x[2:end])
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
        push!(trades, PredictionMarketTrade{T}(spec.market_id, spec.outcome_index, x[1], x[2]))
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
        result.initial_cash,
        result.final_cash,
        copy(result.initial_holdings),
        copy(result.final_holdings),
        copy(result.trades),
        result.split_merge,
    )
end

function _prediction_market_result(problem::PredictionMarketProblem{T}, s::Solver{T}, mode::Symbol, solve_time::Real) where T
    initial_ev = problem.initial_cash + dot(problem.outcome_values, problem.initial_holdings)
    final_cash = problem.initial_cash + s.y[1]
    final_holdings = problem.initial_holdings .+ s.y[2:end]
    final_ev = final_cash + dot(problem.outcome_values, final_holdings)
    trades, split_merge = _extract_prediction_market_trades(problem, s)
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
        problem.initial_cash,
        final_cash,
        copy(problem.initial_holdings),
        final_holdings,
        trades,
        split_merge,
    )
end

function _solve_prediction_market_once(
    problem::PredictionMarketProblem{T};
    mode::Symbol,
    split_bound::Union{Nothing,T}=nothing,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    kwargs...,
) where T
    edges = _prediction_market_edges(problem, mode, split_bound)
    solver = Solver(
        flow_objective=_prediction_market_objective(problem),
        edges=edges,
        n=length(problem.outcome_values) + 1,
    )
    solve_time = try
        solve!(solver; certify=certify, throw_on_fail=throw_on_fail, kwargs...)
    catch err
        if throw_on_fail && err isa ErrorException
            message = sprint(showerror, err)
            startswith(message, "solve! failed certification:") && throw(_PredictionMarketSolveFailed(message))
        end
        rethrow(err)
    end
    return _prediction_market_result(problem, solver, mode, solve_time)
end

function _solve_prediction_market_mixed(
    problem::PredictionMarketProblem{T};
    max_doublings::Int=6,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    kwargs...,
) where T
    max_doublings >= 0 || throw(ArgumentError("max_doublings must be nonnegative"))

    split_bound = isnothing(problem.split_bound) ? _default_split_bound(problem) : problem.split_bound
    best_result = nothing
    for doubling in 0:max_doublings
        result = _solve_prediction_market_once(
            problem;
            mode=:mixed_enabled,
            split_bound=split_bound,
            certify=certify,
            throw_on_fail=throw_on_fail,
            kwargs...,
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

function _prediction_market_worker_require(obj, field::Symbol, path::AbstractString)
    hasproperty(obj, field) || throw(ArgumentError("$path is required"))
    return getproperty(obj, field)
end

function _prediction_market_worker_object(value, field::AbstractString)
    (value isa NamedTuple || value isa JSON3.Object) || throw(ArgumentError("$field must be an object"))
    return value
end

function _prediction_market_worker_array(value, field::AbstractString)
    value isa AbstractVector || throw(ArgumentError("$field must be an array"))
    return value
end

function _prediction_market_worker_string(value, field::AbstractString)
    if value isa AbstractString
        return String(value)
    elseif value isa Symbol
        return String(value)
    end
    throw(ArgumentError("$field must be a string"))
end

function _prediction_market_worker_bool(value, field::AbstractString)
    value isa Bool || throw(ArgumentError("$field must be boolean"))
    return value
end

function _prediction_market_worker_number(value, field::AbstractString)
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

function _prediction_market_worker_float(value, field::AbstractString; quantity::Bool=false)
    parsed = _prediction_market_worker_number(value, field)
    quantity && abs(parsed) > PREDICTION_MARKET_WORKER_SAFE_INTEGER_LIMIT && isinteger(parsed) &&
        throw(ArgumentError("$field exceeds Float64's exact integer range; send decimal-scaled token units instead of raw base-unit integers"))
    return parsed
end

function _prediction_market_worker_int(value, field::AbstractString)
    parsed = _prediction_market_worker_number(value, field)
    isinteger(parsed) || throw(ArgumentError("$field must be an integer"))
    abs(parsed) <= float(typemax(Int)) || throw(ArgumentError("$field is outside Int range"))
    return Int(parsed)
end

function _prediction_market_band_from_json(obj, path::AbstractString)
    band = _prediction_market_worker_object(obj, path)
    return UniV3LiquidityBand(
        _prediction_market_worker_float(_prediction_market_worker_require(band, :lower_price, "$path.lower_price"), "$path.lower_price"),
        _prediction_market_worker_float(_prediction_market_worker_require(band, Symbol("liquidity_L"), "$path.liquidity_L"), "$path.liquidity_L"),
    )
end

function _prediction_market_market_spec_from_json(obj, path::AbstractString)
    spec = _prediction_market_worker_object(obj, path)
    kind = _prediction_market_worker_string(_prediction_market_worker_require(spec, :type, "$path.type"), "$path.type")
    market_id = _prediction_market_worker_string(_prediction_market_worker_require(spec, :market_id, "$path.market_id"), "$path.market_id")
    outcome_index = _prediction_market_worker_int(_prediction_market_worker_require(spec, :outcome_index, "$path.outcome_index"), "$path.outcome_index")

    if kind == "constant_product"
        return ConstantProductMarketSpec(
            market_id,
            outcome_index,
            _prediction_market_worker_float(_prediction_market_worker_require(spec, :collateral_reserve, "$path.collateral_reserve"), "$path.collateral_reserve"; quantity=true),
            _prediction_market_worker_float(_prediction_market_worker_require(spec, :outcome_reserve, "$path.outcome_reserve"), "$path.outcome_reserve"; quantity=true),
            _prediction_market_worker_float(_prediction_market_worker_require(spec, :fee_multiplier, "$path.fee_multiplier"), "$path.fee_multiplier"),
        )
    elseif kind == "univ3"
        current_price = _prediction_market_worker_float(_prediction_market_worker_require(spec, :current_price, "$path.current_price"), "$path.current_price")
        fee_multiplier = _prediction_market_worker_float(_prediction_market_worker_require(spec, :fee_multiplier, "$path.fee_multiplier"), "$path.fee_multiplier")
        if hasproperty(spec, :bands)
            bands_json = _prediction_market_worker_array(getproperty(spec, :bands), "$path.bands")
            bands = UniV3LiquidityBand[
                _prediction_market_band_from_json(band, "$path.bands[$i]")
                for (i, band) in enumerate(bands_json)
            ]
            return UniV3MarketSpec(market_id, outcome_index, current_price, bands, fee_multiplier)
        end

        lower_ticks_json = _prediction_market_worker_array(_prediction_market_worker_require(spec, :lower_ticks, "$path.lower_ticks"), "$path.lower_ticks")
        liquidity_json = _prediction_market_worker_array(_prediction_market_worker_require(spec, :liquidity, "$path.liquidity"), "$path.liquidity")
        return UniV3MarketSpec(
            market_id,
            outcome_index,
            current_price,
            [
                _prediction_market_worker_float(value, "$path.lower_ticks[$i]")
                for (i, value) in enumerate(lower_ticks_json)
            ],
            [
                _prediction_market_worker_float(value, "$path.liquidity[$i]")
                for (i, value) in enumerate(liquidity_json)
            ],
            fee_multiplier,
        )
    end

    throw(ArgumentError("$path.type has unsupported value: $kind"))
end

function _prediction_market_problem_from_json(obj)
    problem = _prediction_market_worker_object(obj, "problem")
    outcome_values_json = _prediction_market_worker_array(
        _prediction_market_worker_require(problem, :outcome_values, "problem.outcome_values"),
        "problem.outcome_values",
    )
    initial_holdings_json = _prediction_market_worker_array(
        _prediction_market_worker_require(problem, :initial_holdings, "problem.initial_holdings"),
        "problem.initial_holdings",
    )
    markets_json = _prediction_market_worker_array(
        _prediction_market_worker_require(problem, :markets, "problem.markets"),
        "problem.markets",
    )
    split_bound = hasproperty(problem, :split_bound) && !isnothing(problem.split_bound) ?
        _prediction_market_worker_float(problem.split_bound, "problem.split_bound"; quantity=true) :
        nothing

    markets = Any[
        _prediction_market_market_spec_from_json(spec, "problem.markets[$i]")
        for (i, spec) in enumerate(markets_json)
    ]

    return PredictionMarketProblem(
        [
            _prediction_market_worker_float(value, "problem.outcome_values[$i]")
            for (i, value) in enumerate(outcome_values_json)
        ],
        _prediction_market_worker_float(
            _prediction_market_worker_require(problem, :initial_cash, "problem.initial_cash"),
            "problem.initial_cash";
            quantity=true,
        ),
        [
            _prediction_market_worker_float(value, "problem.initial_holdings[$i]"; quantity=true)
            for (i, value) in enumerate(initial_holdings_json)
        ],
        markets;
        split_bound=split_bound,
    )
end

function _prediction_market_worker_kwargs(options)
    isnothing(options) && return (throw_on_fail=true, solve_kwargs=(;))

    opts = _prediction_market_worker_object(options, "solve_options")
    kwargs = Pair{Symbol,Any}[]
    hasproperty(opts, :method) &&
        push!(kwargs, :method => Symbol(_prediction_market_worker_string(getproperty(opts, :method), "solve_options.method")))
    hasproperty(opts, :certify) &&
        push!(kwargs, :certify => _prediction_market_worker_bool(getproperty(opts, :certify), "solve_options.certify"))
    hasproperty(opts, :memory) &&
        push!(kwargs, :memory => _prediction_market_worker_int(getproperty(opts, :memory), "solve_options.memory"))
    hasproperty(opts, :factr) &&
        push!(kwargs, :factr => _prediction_market_worker_float(getproperty(opts, :factr), "solve_options.factr"))
    hasproperty(opts, :pgtol) &&
        push!(kwargs, :pgtol => _prediction_market_worker_float(getproperty(opts, :pgtol), "solve_options.pgtol"))
    hasproperty(opts, :max_fun) &&
        push!(kwargs, :max_fun => _prediction_market_worker_int(getproperty(opts, :max_fun), "solve_options.max_fun"))
    hasproperty(opts, :max_iter) &&
        push!(kwargs, :max_iter => _prediction_market_worker_int(getproperty(opts, :max_iter), "solve_options.max_iter"))
    hasproperty(opts, :max_restarts) &&
        push!(kwargs, :max_restarts => _prediction_market_worker_int(getproperty(opts, :max_restarts), "solve_options.max_restarts"))
    hasproperty(opts, :max_doublings) &&
        push!(kwargs, :max_doublings => _prediction_market_worker_int(getproperty(opts, :max_doublings), "solve_options.max_doublings"))

    throw_on_fail = hasproperty(opts, :throw_on_fail) ?
        _prediction_market_worker_bool(getproperty(opts, :throw_on_fail), "solve_options.throw_on_fail") :
        true
    return (throw_on_fail=throw_on_fail, solve_kwargs=(; kwargs...))
end

function _prediction_market_worker_maybe_throw_on_fail(result::PredictionMarketSolveResult, command::AbstractString, throw_on_fail::Bool)
    !throw_on_fail && return result
    result.status == "uncertified" || return result
    message = isnothing(result.certificate) ? "solver returned uncertified result" : result.certificate.message
    throw(_PredictionMarketSolveFailed("$command failed certification: $message"))
end

function _prediction_market_worker_maybe_throw_on_fail(result::NamedTuple, command::AbstractString, throw_on_fail::Bool)
    !throw_on_fail && return result
    failures = String[]
    for label in (:direct_only, :mixed_enabled)
        child = getproperty(result, label)
        child.status == "uncertified" || continue
        message = isnothing(child.certificate) ? "solver returned uncertified result" : child.certificate.message
        push!(failures, "$(label): $message")
    end
    isempty(failures) || throw(_PredictionMarketSolveFailed("$command failed certification: $(join(failures, "; "))"))
    return result
end

_prediction_market_worker_error_code(err::ArgumentError) = "invalid_request"
_prediction_market_worker_error_code(err::_PredictionMarketSolveFailed) = "solve_failed"
_prediction_market_worker_error_code(err::Exception) = "internal_error"

"""
    prediction_market_worker_response(request)

Parse one worker request line and return the JSON-serializable response payload
for the prediction-market worker protocol.
"""
function prediction_market_worker_response(request::AbstractString)
    request_id = nothing
    try
        payload = JSON3.read(request)
        request_id = hasproperty(payload, :request_id) ? payload.request_id : nothing
        protocol_version = _prediction_market_worker_int(
            _prediction_market_worker_require(payload, :protocol_version, "protocol_version"),
            "protocol_version",
        )
        protocol_version == PREDICTION_MARKET_WORKER_PROTOCOL_VERSION ||
            throw(ArgumentError("unsupported protocol_version $protocol_version"))

        command = _prediction_market_worker_string(
            _prediction_market_worker_require(payload, :command, "command"),
            "command",
        )
        result = if command == "health"
            (
                status="ok",
                package="ForecastFlows",
                supported_commands=["health", "solve_prediction_market", "compare_prediction_market_families"],
                supported_interfaces=["julia_facade", "json_worker"],
                outcome_indexing="1-based",
                numeric_units="decimal token units",
                execution_model="serial",
                univ3_liquidity_shape="bands[{lower_price, liquidity_L}] preferred; legacy lower_ticks/liquidity uses descending prices and L^2",
            )
        elseif command == "solve_prediction_market"
            mode = hasproperty(payload, :mode) ?
                Symbol(_prediction_market_worker_string(getproperty(payload, :mode), "mode")) :
                :direct_only
            options = _prediction_market_worker_kwargs(hasproperty(payload, :solve_options) ? getproperty(payload, :solve_options) : nothing)
            _prediction_market_worker_maybe_throw_on_fail(
                solve_prediction_market(
                    _prediction_market_problem_from_json(_prediction_market_worker_require(payload, :problem, "problem"));
                    mode=mode,
                    throw_on_fail=false,
                    options.solve_kwargs...,
                ),
                command,
                options.throw_on_fail,
            )
        elseif command == "compare_prediction_market_families"
            options = _prediction_market_worker_kwargs(hasproperty(payload, :solve_options) ? getproperty(payload, :solve_options) : nothing)
            _prediction_market_worker_maybe_throw_on_fail(
                compare_prediction_market_families(
                    _prediction_market_problem_from_json(_prediction_market_worker_require(payload, :problem, "problem"));
                    throw_on_fail=false,
                    options.solve_kwargs...,
                ),
                command,
                options.throw_on_fail,
            )
        else
            throw(ArgumentError("unsupported command: $command"))
        end

        return (
            protocol_version=PREDICTION_MARKET_WORKER_PROTOCOL_VERSION,
            request_id=request_id,
            ok=true,
            command=command,
            result=result,
        )
    catch err
        err isa Union{InterruptException, OutOfMemoryError, StackOverflowError} && rethrow(err)
        return (
            protocol_version=PREDICTION_MARKET_WORKER_PROTOCOL_VERSION,
            request_id=request_id,
            ok=false,
            error=(
                code=_prediction_market_worker_error_code(err),
                message=sprint(showerror, err),
            ),
        )
    end
end
