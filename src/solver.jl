struct SolveCertificate{T <: AbstractFloat}
    passed::Bool
    message::String
    primal_value::T
    dual_value::T
    duality_gap::T
    target_residual::T
    bound_residual::T
end

struct FixedGasModel{T <: AbstractFloat}
    action_costs::Vector{T}
    threaded_threshold::Int

    function FixedGasModel(action_costs::AbstractVector{T}; threaded_threshold::Integer=8) where {T<:AbstractFloat}
        threaded_threshold >= 1 || throw(ArgumentError("threaded_threshold must be positive"))
        return new{T}(collect(action_costs), Int(threaded_threshold))
    end
end

FixedGasModel(action_costs::AbstractVector{T}; threaded_threshold::Integer=8) where {T<:Real} =
    FixedGasModel(Float64.(action_costs); threaded_threshold=threaded_threshold)

mutable struct Solver{
    T <: AbstractFloat,
    V <: Vector{T},
    OV <: Objective,
}
    flow_objective::OV
    edge_objectives::Union{Vector{<: Objective}, Nothing}
    Vis_zero::Bool
    edges::Vector{<: Edge}
    y::V
    xs::Vector{V}
    ν::V
    ηts::Vector{V}
    arb_prices::Vector{V}
    μ0::V
    certificate::Union{Nothing, SolveCertificate{T}}
    n::Int
    m::Int
end

function validate_edges(edges::Vector{<:Edge}, n::Int)
    for (i, e) in pairs(edges)
        isempty(e.Ai) && throw(ArgumentError("edge $i must be incident to at least one node"))
        all(j -> 1 <= j <= n, e.Ai) || throw(ArgumentError("edge $i has node indices outside 1:$n"))
        length(unique(e.Ai)) == length(e.Ai) || throw(ArgumentError("edge $i contains duplicate node indices"))
    end
    return nothing
end

function objective_netflows!(y::AbstractVector{T}, s::Solver{T}) where T
    grad_Ubar!(y, s.flow_objective, s.ν)
    y .*= -one(T)
    return nothing
end

function edge_execution_value(s::Solver{T}, i::Integer) where T
    prices = s.Vis_zero ? view(s.ν, s.edges[i].Ai) : s.arb_prices[i]
    return dot(s.xs[i], prices)
end

edge_is_active(x::AbstractVector; atol::Real=1e-8) = any(abs.(x) .> atol)

_default_dual_seed_offset(obj::Objective, ::Type{T}) where T = one(T)
_default_dual_seed_offset(obj::EndowmentLinear{T}, ::Type{T}) where T = convert(T, 100) * sqrt(eps(T))

struct GasPruningResult{T}
    kept_edges::BitVector
    edge_values::Vector{T}
    rounds::Int
    solve_time::Float64
end

function copy_solver_state!(dest::Solver{T}, src::Solver{T}, active_inds::Vector{Int}) where T
    dest.ν .= src.ν
    dest.y .= src.y
    dest.certificate = src.certificate

    for xs in dest.xs
        fill!(xs, zero(T))
    end
    for η in dest.ηts
        fill!(η, zero(T))
    end
    for prices in dest.arb_prices
        fill!(prices, zero(T))
    end

    for (local_idx, edge_idx) in pairs(active_inds)
        dest.xs[edge_idx] .= src.xs[local_idx]
        if !dest.Vis_zero
            dest.ηts[edge_idx] .= src.ηts[local_idx]
            dest.arb_prices[edge_idx] .= src.arb_prices[local_idx]
        end
    end

    return nothing
end

function cleanup_near_zero_flows!(s::Solver{T}; atol::T) where T
    flow_tol = max(sqrt(atol), convert(T, 10) * sqrt(eps(T)))
    for i in eachindex(s.xs)
        if norm(s.xs[i]) <= flow_tol && abs(edge_execution_value(s, i)) <= atol
            fill!(s.xs[i], zero(T))
        end
    end
    netflows!(s)
    return nothing
end

function recover_primal!(s::Solver{T}; tol::T=sqrt(eps(T))) where T
    split_inds = findall(i -> s.edges[i] isa SplitMergeEdge, eachindex(s.edges))
    isempty(split_inds) && return false

    target = similar(s.y)
    fixed = falses(s.n)
    lower_bounds = primal_lower_bounds(s.flow_objective)
    recovery_targets!(target, fixed, s.flow_objective, s.ν)

    s.y .= zero(T)
    for i in eachindex(s.edges)
        s.edges[i] isa SplitMergeEdge && continue
        @views s.y[s.edges[i].Ai] .+= s.xs[i]
    end

    for i in split_inds
        edge = s.edges[i]::SplitMergeEdge{T}
        η = s.Vis_zero ? view(s.ν, edge.Ai) : s.arb_prices[i]
        residual = @views target[edge.Ai] .- s.y[edge.Ai]
        local_fixed = @view fixed[edge.Ai]
        local_flow = @view s.y[edge.Ai]
        local_lower_bounds = @view lower_bounds[edge.Ai]
        recover_splitmerge_flow!(
            s.xs[i],
            edge,
            η,
            residual,
            local_fixed;
            current_flow=local_flow,
            lower_bounds=local_lower_bounds,
            tol=tol,
        )
        @views s.y[edge.Ai] .+= s.xs[i]
    end

    return true
end

_solver_objective_eltype(::Objective) = Float64
_solver_objective_eltype(::NonpositiveQuadratic{T}) where T = T
_solver_objective_eltype(::Markowitz{T}) where T = T
_solver_objective_eltype(::LinearNonnegative{T}) where T = T
_solver_objective_eltype(::EndowmentLinear{T}) where T = T
_solver_objective_eltype(::BasketLiquidation{T}) where T = T
_solver_objective_eltype(::BasketAcquisition{T}) where T = T

_solver_edge_eltype(::Edge{T}) where T = T

function _infer_solver_eltype(
    flow_objective::Objective,
    edge_objectives::Union{Vector{<:Objective}, Nothing},
    edges::Vector{<:Edge},
)
    T = _solver_objective_eltype(flow_objective)
    if !isnothing(edge_objectives)
        for obj in edge_objectives
            T = promote_type(T, _solver_objective_eltype(obj))
        end
    end
    for edge in edges
        T = promote_type(T, _solver_edge_eltype(edge))
    end
    return T
end

function Solver(;
    flow_objective::Objective,
    edge_objectives::Union{Vector{<:Objective}, Nothing}=nothing,
    edges::Vector{<: Edge},
    n::Int,
)
    T = _infer_solver_eltype(flow_objective, edge_objectives, edges)
    m = length(edges)
    validate_edges(edges, n)
    !isnothing(edge_objectives) && length(edge_objectives) != m &&
        throw(ArgumentError("edge_objectives must be of length m"))

    y = zeros(T, n)
    xs = convert(Vector{Vector{T}}, [zeros(T, length(e.Ai)) for e in edges])
    ν = zeros(T, n)
    ηs = convert(Vector{Vector{T}}, [zeros(T, length(e.Ai)) for e in edges])
    arb_prices = convert(Vector{Vector{T}}, [zeros(T, length(e.Ai)) for e in edges])
    Vis_zero = isnothing(edge_objectives)
    μ0 = zeros(T, Vis_zero ? n : n + sum(length(e.Ai) for e in edges))

    return Solver(
        flow_objective,
        edge_objectives,
        Vis_zero,
        edges,
        y,
        xs,
        ν,
        ηs,
        arb_prices,
        μ0,
        nothing,
        n,
        m,
    )
end

function find_arb!(s::Solver{T}) where T
    Threads.@threads for i in eachindex(s.xs)
        if s.Vis_zero
            find_arb!(s.xs[i], s.edges[i], view(s.ν, s.edges[i].Ai))
        else
            @views s.arb_prices[i] .= s.ηts[i] .+ s.ν[s.edges[i].Ai]
            find_arb!(s.xs[i], s.edges[i], s.arb_prices[i])
        end
    end
    return nothing
end

function _netflow_from_edges!(y::AbstractVector{T}, s::Solver{T}) where T
    y .= zero(T)
    for (x, e) in zip(s.xs, s.edges)
        @views y[e.Ai] .+= x
    end
    return nothing
end

function netflows!(s::Solver{T}) where T
    _netflow_from_edges!(s.y, s)
    return nothing
end

function dual_objective(s::Solver{T}) where T
    acc = Ubar(s.flow_objective, s.ν)
    for i in eachindex(s.edges)
        if s.Vis_zero
            acc += dot(s.xs[i], view(s.ν, s.edges[i].Ai))
        else
            acc += Ubar(s.edge_objectives[i], s.ηts[i])
            acc += dot(s.xs[i], s.arb_prices[i])
        end
    end
    return acc
end

function primal_objective(s::Solver{T}) where T
    return primal_objective(s, s.y)
end

function primal_objective(s::Solver{T}, y::AbstractVector{T}) where T
    acc = U(s.flow_objective, y)
    isfinite(acc) || return acc

    if !s.Vis_zero
        for i in eachindex(s.edges)
            term = U(s.edge_objectives[i], s.xs[i])
            isfinite(term) || return term
            acc += term
        end
    end

    return acc
end

function _dual_bound_residual(s::Solver{T}) where T
    resid = zero(T)

    lbs = max.(zero(T), lower_limit(s.flow_objective))
    ubs = upper_limit(s.flow_objective)
    for i in eachindex(s.ν)
        resid = max(resid, max(lbs[i] - s.ν[i], zero(T)))
        isfinite(ubs[i]) && (resid = max(resid, max(s.ν[i] - ubs[i], zero(T))))
    end

    if !s.Vis_zero
        for i in eachindex(s.ηts)
            lbη = max.(zero(T), lower_limit(s.edge_objectives[i]))
            ubη = upper_limit(s.edge_objectives[i])
            for j in eachindex(s.ηts[i])
                resid = max(resid, max(lbη[j] - s.ηts[i][j], zero(T)))
                isfinite(ubη[j]) && (resid = max(resid, max(s.ηts[i][j] - ubη[j], zero(T))))
            end
        end
    end

    return resid
end

function _splitmerge_bound_residual(s::Solver{T}) where T
    resid = zero(T)
    for (x, edge) in zip(s.xs, s.edges)
        edge isa SplitMergeEdge || continue
        split = edge::SplitMergeEdge{T}
        w = if length(x) == 1
            -x[1]
        else
            sum(@view x[2:end]) / convert(T, length(x) - 1)
        end
        resid = max(resid, max(abs(w) - split.B, zero(T)))
        resid = max(resid, abs(x[1] + w))
        for j in 2:length(x)
            resid = max(resid, abs(x[j] - w))
        end
    end
    return resid
end

function certify_solution(
    s::Solver{T};
    gap_tol::T=max(sqrt(eps(T)), convert(T, 1e-6)),
    target_tol::T=max(sqrt(eps(T)), convert(T, 1e-6)),
    bound_tol::T=max(sqrt(eps(T)), convert(T, 1e-8)),
) where T
    yhat = similar(s.y)
    _netflow_from_edges!(yhat, s)

    flow_residual = zero(T)
    for i in eachindex(yhat)
        flow_residual = max(flow_residual, abs(yhat[i] - s.y[i]))
    end

    target = similar(yhat)
    fixed = falses(s.n)
    recovery_targets!(target, fixed, s.flow_objective, s.ν)

    target_residual = flow_residual
    for i in eachindex(yhat)
        fixed[i] || continue
        target_residual = max(target_residual, abs(yhat[i] - target[i]))
    end

    bound_residual = max(_dual_bound_residual(s), _splitmerge_bound_residual(s))
    primal_val = primal_objective(s, yhat)
    dual_val = dual_objective(s)
    dual_gap = dual_val - primal_val

    passed = isfinite(primal_val) &&
        isfinite(dual_val) &&
        target_residual <= target_tol &&
        bound_residual <= bound_tol &&
        abs(dual_gap) <= gap_tol

    reasons = String[]
    !isfinite(primal_val) && push!(reasons, "primal objective is not finite")
    !isfinite(dual_val) && push!(reasons, "dual objective is not finite")
    target_residual > target_tol && push!(reasons, "target residual $(target_residual) exceeds tolerance $(target_tol)")
    bound_residual > bound_tol && push!(reasons, "bound residual $(bound_residual) exceeds tolerance $(bound_tol)")
    abs(dual_gap) > gap_tol && push!(reasons, "duality gap $(dual_gap) exceeds tolerance $(gap_tol)")
    isempty(reasons) && push!(reasons, "certified")

    cert = SolveCertificate(
        passed,
        join(reasons, "; "),
        primal_val,
        dual_val,
        dual_gap,
        target_residual,
        bound_residual,
    )
    s.certificate = cert
    return cert
end

function _finalize_solution!(
    s::Solver{T};
    final_netflows::Bool,
    recovery_tol::T,
    force_netflows::Bool=false,
) where T
    recovered = recover_primal!(s; tol=recovery_tol)
    if !recovered
        if final_netflows || force_netflows
            netflows!(s)
        else
            objective_netflows!(s.y, s)
        end
    end
    return recovered
end

function _supports_bfgs_exact(s::Solver{T}) where T
    s.Vis_zero || return false

    lbs = max.(zero(T), lower_limit(s.flow_objective))
    ubs = upper_limit(s.flow_objective)
    tol = sqrt(eps(T))
    for i in eachindex(lbs)
        if isfinite(ubs[i]) && ubs[i] > lbs[i] + tol
            return false
        end
    end
    return true
end

function _select_method(s::Solver, method::Symbol)
    if method == :auto
        return any(is_nonsmooth, s.edges) && _supports_bfgs_exact(s) ? :bfgs_exact : :lbfgsb
    elseif method == :bfgs_exact
        _supports_bfgs_exact(s) ||
            throw(ArgumentError("method=:bfgs_exact only supports zero-edge-utility problems with lower bounds and fixed coordinates"))
        return :bfgs_exact
    elseif method == :lbfgsb
        return :lbfgsb
    end
    throw(ArgumentError("unknown solve method: $method"))
end

function _solve_certificate_tolerances(::Type{T}, pgtol::Real) where T
    gap_tol = max(convert(T, 500) * sqrt(eps(T)), convert(T, 500) * convert(T, pgtol))
    target_tol = max(convert(T, 100) * sqrt(eps(T)), convert(T, 500) * convert(T, pgtol))
    bound_tol = max(convert(T, 100) * sqrt(eps(T)), convert(T, 100) * convert(T, pgtol))
    return gap_tol, target_tol, bound_tol
end

function _lbfgsb_bounds(s::Solver{T}, nis::Vector{Int}) where T
    len_μ = s.Vis_zero ? s.n : s.n + sum(nis)
    bounds = zeros(T, 3, len_μ)
    bounds[2, 1:s.n] .= max.(zero(T), lower_limit(s.flow_objective))
    bounds[3, 1:s.n] .= upper_limit(s.flow_objective)

    if !s.Vis_zero
        ind = s.n + 1
        for i in 1:s.m
            bounds[2, ind:ind+nis[i]-1] .= max.(zero(T), lower_limit(s.edge_objectives[i]))
            bounds[3, ind:ind+nis[i]-1] .= upper_limit(s.edge_objectives[i])
            ind += nis[i]
        end
    end

    for i in axes(bounds, 2)
        lb = bounds[2, i]
        ub = bounds[3, i]
        if isinf(lb) && isinf(ub)
            bounds[1, i] = 0
        elseif !isinf(lb) && isinf(ub)
            bounds[1, i] = 1
        elseif !isinf(lb) && !isinf(ub)
            bounds[1, i] = 2
        else
            bounds[1, i] = 3
        end
    end

    return bounds
end

function _initialize_lbfgsb_state!(
    s::Solver{T},
    bounds::AbstractMatrix{T},
    nis::Vector{Int},
    ν0,
) where T
    if isnothing(ν0)
        offset = _default_dual_seed_offset(s.flow_objective, T)
        s.μ0[1:s.n] .= max.(bounds[2, 1:s.n] .+ offset, bounds[2, 1:s.n])
    else
        s.μ0[1:s.n] .= ν0
    end
    @views s.μ0[1:s.n] .= clamp.(s.μ0[1:s.n], bounds[2, 1:s.n], bounds[3, 1:s.n])

    if !s.Vis_zero
        ind = s.n + 1
        for i in 1:s.m
            s.μ0[ind:ind+nis[i]-1] .= s.μ0[1:s.n][s.edges[i].Ai]
            @views s.μ0[ind:ind+nis[i]-1] .= clamp.(s.μ0[ind:ind+nis[i]-1], bounds[2, ind:ind+nis[i]-1], bounds[3, ind:ind+nis[i]-1])
            ind += nis[i]
        end
    end

    return nothing
end

function _solve_lbfgsb_once!(
    s::Solver{T};
    ν0=nothing,
    η0=nothing,
    verbose::Bool=false,
    memory::Int=5,
    factr::Real=1e1,
    pgtol::Real=1e-5,
    max_fun::Int=15_000,
    max_iter::Int=10_000,
    final_netflows::Bool=true,
    certify::Bool=true,
    gap_tol::T=max(sqrt(eps(T)), convert(T, 10) * convert(T, pgtol)),
    target_tol::T=max(sqrt(eps(T)), convert(T, 10) * convert(T, pgtol)),
    bound_tol::T=max(sqrt(eps(T)), convert(T, 10) * sqrt(eps(T))),
) where T
    if !isnothing(η0) && length(η0) != length(s.edges)
        throw(ArgumentError("η0 must be of length m"))
    elseif !isnothing(η0) && isnothing(s.edge_objectives)
        throw(ArgumentError("solver does not have edge objectives"))
    end

    nis = [length(e.Ai) for e in s.edges]
    bounds = _lbfgsb_bounds(s, nis)
    _initialize_lbfgsb_state!(s, bounds, nis, ν0)

    function fn(μ::Vector{T})
        s.ν .= μ[1:s.n]
        if !s.Vis_zero
            ind = s.n + 1
            for i in 1:s.m
                s.ηts[i] .= μ[ind:ind+nis[i]-1]
                ind += nis[i]
            end
        end
        find_arb!(s)
        return dual_objective(s)
    end

    function grad!(g, μ::Vector{T})
        g .= zero(T)
        gν = @view g[1:s.n]
        grad_Ubar!(gν, s.flow_objective, s.ν)

        ind = s.n + 1
        for i in 1:s.m
            @views g[s.edges[i].Ai] .+= s.xs[i]

            if !s.Vis_zero
                ni = length(s.edges[i])
                inds = ind:ind+ni-1
                gηi = @view g[inds]
                grad_Ubar!(gηi, s.edge_objectives[i], s.ηts[i])
                gηi .+= s.xs[i]
                ind += ni
            end
        end

        return nothing
    end

    find_arb!(s)
    optimizer = L_BFGS_B(size(bounds, 2), max(17, memory))
    tt = @timed optimizer(
        fn,
        grad!,
        s.μ0,
        bounds,
        m=memory,
        factr=factr,
        pgtol=pgtol,
        iprint=verbose ? 1 : -1,
        maxfun=max_fun,
        maxiter=max_iter,
    )
    _, μ = tt.value
    solver_time = tt.time

    s.ν .= μ[1:s.n]
    if !s.Vis_zero
        ind = s.n + 1
        for i in 1:s.m
            s.ηts[i] .= μ[ind:ind+nis[i]-1]
            ind += nis[i]
        end
    end

    find_arb!(s)
    recovery_tol = max(sqrt(eps(T)), convert(T, 10) * convert(T, pgtol))
    _finalize_solution!(s; final_netflows=final_netflows, recovery_tol=recovery_tol, force_netflows=certify)
    certify && certify_solution(s; gap_tol=gap_tol, target_tol=target_tol, bound_tol=bound_tol)

    return solver_time
end

function _bfgs_exact_layout(s::Solver{T}) where T
    lbs = max.(zero(T), lower_limit(s.flow_objective))
    ubs = upper_limit(s.flow_objective)
    tol = sqrt(eps(T))

    free_inds = Int[]
    fixed_inds = Int[]
    fixed_vals = copy(lbs)

    for i in eachindex(lbs)
        if isfinite(ubs[i])
            ubs[i] < lbs[i] - tol && throw(ArgumentError("upper bound below lower bound at coordinate $i"))
            if abs(ubs[i] - lbs[i]) <= tol
                push!(fixed_inds, i)
                fixed_vals[i] = (lbs[i] + ubs[i]) / convert(T, 2)
            else
                throw(ArgumentError("method=:bfgs_exact only supports lower bounds and fixed coordinates"))
            end
        else
            push!(free_inds, i)
        end
    end

    return lbs, free_inds, fixed_inds, fixed_vals
end

function _apply_bfgs_exact_dual!(
    s::Solver{T},
    μ::AbstractVector{T},
    lbs::AbstractVector{T},
    free_inds::Vector{Int},
    fixed_inds::Vector{Int},
    fixed_vals::AbstractVector{T},
) where T
    s.ν .= lbs
    for idx in fixed_inds
        s.ν[idx] = fixed_vals[idx]
    end
    for (local_idx, global_idx) in pairs(free_inds)
        s.ν[global_idx] = lbs[global_idx] + μ[local_idx]
    end
    return nothing
end

function _dual_gradient_nu!(g::AbstractVector{T}, s::Solver{T}) where T
    grad_Ubar!(g, s.flow_objective, s.ν)
    for i in eachindex(s.edges)
        edge = s.edges[i]
        for (local_idx, global_idx) in pairs(edge.Ai)
            g[global_idx] += s.xs[i][local_idx]
        end
    end
    return nothing
end

function _initial_bfgs_seed(
    lbs::AbstractVector{T},
    free_inds::Vector{Int},
    ν0,
    seed::Symbol,
    obj::Objective,
) where T
    isempty(free_inds) && return zeros(T, 0)

    μ0 = zeros(T, length(free_inds))
    if !isnothing(ν0)
        for (local_idx, global_idx) in pairs(free_inds)
            μ0[local_idx] = max(ν0[global_idx] - lbs[global_idx], sqrt(eps(T)))
        end
        return μ0
    end

    offset = _default_dual_seed_offset(obj, T)
    if seed == :uniform
        fill!(μ0, offset)
    else
        for (local_idx, global_idx) in pairs(free_inds)
            μ0[local_idx] = max(offset, abs(offset * lbs[global_idx]))
        end
    end
    return μ0
end

function _solve_bfgs_exact_once!(
    s::Solver{T};
    ν0=nothing,
    seed::Symbol=:standard,
    verbose::Bool=false,
    pgtol::Real=1e-5,
    max_iter::Int=10_000,
    final_netflows::Bool=true,
    certify::Bool=true,
    gap_tol::T=max(sqrt(eps(T)), convert(T, 10) * convert(T, pgtol)),
    target_tol::T=max(sqrt(eps(T)), convert(T, 10) * convert(T, pgtol)),
    bound_tol::T=max(sqrt(eps(T)), convert(T, 10) * sqrt(eps(T))),
) where T
    lbs, free_inds, fixed_inds, fixed_vals = _bfgs_exact_layout(s)

    if isempty(free_inds)
        _apply_bfgs_exact_dual!(s, zeros(T, 0), lbs, free_inds, fixed_inds, fixed_vals)
        find_arb!(s)
        recovery_tol = max(sqrt(eps(T)), convert(T, 10) * convert(T, pgtol))
        _finalize_solution!(s; final_netflows=final_netflows, recovery_tol=recovery_tol, force_netflows=certify)
        certify && certify_solution(s; gap_tol=gap_tol, target_tol=target_tol, bound_tol=bound_tol)
        return 0.0
    end

    fullg = zeros(T, s.n)

    function f∇f!(gμ::Vector{T}, μ::Vector{T}, _)
        _apply_bfgs_exact_dual!(s, μ, lbs, free_inds, fixed_inds, fixed_vals)
        find_arb!(s)
        _dual_gradient_nu!(fullg, s)
        for (local_idx, global_idx) in pairs(free_inds)
            gμ[local_idx] = fullg[global_idx]
        end
        return dual_objective(s)
    end

    options = BFGSOptions(
        max_iters=max_iter,
        max_time_sec=60.0,
        print_iter=10,
        verbose=verbose,
        logging=false,
        eps_g_norm=pgtol,
        num_threads=Sys.CPU_THREADS,
        final_print=false,
    )

    solver = BFGSSolver(length(free_inds); method=:bfgs, T=T)
    μ0 = _initial_bfgs_seed(lbs, free_inds, ν0, seed, s.flow_objective)
    result = solve!(solver, f∇f!, nothing; options=options, x0=μ0)

    _apply_bfgs_exact_dual!(s, result.x, lbs, free_inds, fixed_inds, fixed_vals)
    find_arb!(s)
    recovery_tol = max(sqrt(eps(T)), convert(T, 10) * convert(T, pgtol))
    _finalize_solution!(s; final_netflows=final_netflows, recovery_tol=recovery_tol, force_netflows=certify)
    certify && certify_solution(s; gap_tol=gap_tol, target_tol=target_tol, bound_tol=bound_tol)

    return result.log.solve_time
end

function solve!(
    s::Solver{T};
    ν0=nothing,
    η0=nothing,
    verbose::Bool=false,
    memory::Int=5,
    factr::Real=1e1,
    pgtol::Real=1e-5,
    max_fun::Int=15_000,
    max_iter::Int=10_000,
    final_netflows::Bool=true,
    method::Symbol=:auto,
    certify::Bool=true,
    throw_on_fail::Bool=true,
    max_restarts::Int=2,
) where T
    chosen_method = _select_method(s, method)
    has_nonsmooth_edges = any(is_nonsmooth, s.edges)
    gap_tol, target_tol, bound_tol = _solve_certificate_tolerances(T, pgtol)

    s.certificate = nothing
    total_time = 0.0

    if chosen_method == :lbfgsb
        total_time += _solve_lbfgsb_once!(
            s;
            ν0=ν0,
            η0=η0,
            verbose=verbose,
            memory=memory,
            factr=factr,
            pgtol=pgtol,
            max_fun=max_fun,
            max_iter=max_iter,
            final_netflows=final_netflows,
            certify=certify,
            gap_tol=gap_tol,
            target_tol=target_tol,
            bound_tol=bound_tol,
        )
    else
        total_time += _solve_bfgs_exact_once!(
            s;
            ν0=ν0,
            seed=:standard,
            verbose=verbose,
            pgtol=pgtol,
            max_iter=max_iter,
            final_netflows=final_netflows,
            certify=certify,
            gap_tol=gap_tol,
            target_tol=target_tol,
            bound_tol=bound_tol,
        )

        if certify && !s.certificate.passed && max_restarts >= 1
            total_time += _solve_bfgs_exact_once!(
                s;
                ν0=nothing,
                seed=:uniform,
                verbose=verbose,
                pgtol=pgtol,
                max_iter=max_iter,
                final_netflows=final_netflows,
                certify=true,
                gap_tol=gap_tol,
                target_tol=target_tol,
                bound_tol=bound_tol,
            )
        end

        if certify && !s.certificate.passed && max_restarts >= 2
            total_time += _solve_lbfgsb_once!(
                s;
                ν0=ν0,
                η0=η0,
                verbose=verbose,
                memory=memory,
                factr=factr,
                pgtol=pgtol,
                max_fun=max_fun,
                max_iter=max_iter,
                final_netflows=true,
                certify=certify,
                gap_tol=gap_tol,
                target_tol=target_tol,
                bound_tol=bound_tol,
            )
            if !has_nonsmooth_edges && s.certificate.passed
                return total_time
            end
            warm_start = copy(s.ν)
            total_time += _solve_bfgs_exact_once!(
                s;
                ν0=warm_start,
                seed=:standard,
                verbose=verbose,
                pgtol=pgtol,
                max_iter=max_iter,
                final_netflows=final_netflows,
                certify=true,
                gap_tol=gap_tol,
                target_tol=target_tol,
                bound_tol=bound_tol,
            )
        end
    end

    if certify
        cert = isnothing(s.certificate) ?
            certify_solution(s; gap_tol=gap_tol, target_tol=target_tol, bound_tol=bound_tol) :
            s.certificate
        if !cert.passed && throw_on_fail
            error("solve! failed certification: $(cert.message)")
        end
    end

    return total_time
end

function _finalize_gas_pruning_state!(
    s::Solver{T},
    subsolver::Solver{T},
    active_inds::Vector{Int},
    solve_kwargs::NamedTuple;
    atol::T,
) where T
    copy_solver_state!(s, subsolver, active_inds)
    cleanup_near_zero_flows!(s; atol=atol)

    certify = hasproperty(solve_kwargs, :certify) ? getproperty(solve_kwargs, :certify) : true
    if certify
        pgtol = hasproperty(solve_kwargs, :pgtol) ? getproperty(solve_kwargs, :pgtol) : 1e-5
        gap_tol, target_tol, bound_tol = _solve_certificate_tolerances(T, pgtol)
        certify_solution(s; gap_tol=gap_tol, target_tol=target_tol, bound_tol=bound_tol)
    end

    return nothing
end

function _subset_solver(s::Solver, active_inds::Vector{Int})
    edge_objectives = isnothing(s.edge_objectives) ? nothing : s.edge_objectives[active_inds]
    return Solver(
        flow_objective=s.flow_objective,
        edge_objectives=edge_objectives,
        edges=s.edges[active_inds],
        n=s.n,
    )
end

function _active_gas_cost(
    subsolver::Solver{T},
    active_inds::Vector{Int},
    gas_model::FixedGasModel{T};
    atol::T,
) where T
    gas = zero(T)
    for (local_idx, edge_idx) in pairs(active_inds)
        edge_is_active(subsolver.xs[local_idx]; atol=atol) || continue
        gas += gas_model.action_costs[edge_idx]
    end
    return gas
end

function _evaluate_candidate_removal!(
    losses::Vector{T},
    net_values::Vector{T},
    current_raw::T,
    s::Solver{T},
    active_inds::Vector{Int},
    candidate_edges::Vector{Int},
    gas_model::FixedGasModel{T},
    ν_seed::AbstractVector{T},
    solve_kwargs::NamedTuple,
    atol::T,
) where T
    use_threads = length(candidate_edges) >= gas_model.threaded_threshold && Threads.nthreads() > 1

    function eval_candidate!(slot::Int)
        edge_idx = candidate_edges[slot]
        reduced_inds = filter(!=(edge_idx), active_inds)
        subsolver = _subset_solver(s, reduced_inds)
        solve!(subsolver; ν0=ν_seed, throw_on_fail=false, solve_kwargs...)

        if isnothing(subsolver.certificate) || !subsolver.certificate.passed
            losses[slot] = typemax(T)
            net_values[slot] = -typemax(T)
            return nothing
        end

        raw_val = primal_objective(subsolver)
        losses[slot] = current_raw - raw_val
        gas_val = _active_gas_cost(subsolver, reduced_inds, gas_model; atol=atol)
        net_values[slot] = raw_val - gas_val
        return nothing
    end

    if use_threads
        Threads.@threads for slot in eachindex(candidate_edges)
            eval_candidate!(slot)
        end
    else
        for slot in eachindex(candidate_edges)
            eval_candidate!(slot)
        end
    end

    return nothing
end

function solve_with_fixed_gas!(
    s::Solver{T},
    gas_model::FixedGasModel{T};
    atol::T=convert(T, 1e-8),
    max_rounds::Int=5,
    solve_kwargs...,
) where T
    length(gas_model.action_costs) == s.m || throw(ArgumentError("gas model must have one cost per edge"))

    solve_kw_nt = (; solve_kwargs...,)
    active = trues(s.m)
    edge_values = zeros(T, s.m)
    ν_seed = nothing
    total_time = 0.0
    rounds = 0

    for round in 1:max_rounds
        rounds = round
        active_inds = findall(active)
        subsolver = _subset_solver(s, active_inds)
        total_time += solve!(subsolver; ν0=ν_seed, throw_on_fail=false, solve_kw_nt...)

        if isnothing(subsolver.certificate) || !subsolver.certificate.passed
            copy_solver_state!(s, subsolver, active_inds)
            return GasPruningResult(active, edge_values, round, total_time)
        end

        raw_val = primal_objective(subsolver)
        current_gas = _active_gas_cost(subsolver, active_inds, gas_model; atol=atol)
        current_net = raw_val - current_gas

        fill!(edge_values, zero(T))
        candidate_edges = Int[]
        for (local_idx, edge_idx) in pairs(active_inds)
            if edge_is_active(subsolver.xs[local_idx]; atol=atol) && gas_model.action_costs[edge_idx] > atol
                push!(candidate_edges, edge_idx)
            end
        end

        if isempty(candidate_edges)
            _finalize_gas_pruning_state!(s, subsolver, active_inds, solve_kw_nt; atol=atol)
            return GasPruningResult(active, edge_values, round, total_time)
        end

        losses = zeros(T, length(candidate_edges))
        net_values = fill(-typemax(T), length(candidate_edges))
        _evaluate_candidate_removal!(
            losses,
            net_values,
            raw_val,
            s,
            active_inds,
            candidate_edges,
            gas_model,
            subsolver.ν,
            solve_kw_nt,
            atol,
        )

        best_improvement = zero(T)
        best_edge = 0
        for slot in eachindex(candidate_edges)
            edge_idx = candidate_edges[slot]
            edge_values[edge_idx] = losses[slot]
            improvement = net_values[slot] - current_net
            if improvement > best_improvement + atol
                best_improvement = improvement
                best_edge = edge_idx
            end
        end

        if best_edge == 0
            _finalize_gas_pruning_state!(s, subsolver, active_inds, solve_kw_nt; atol=atol)
            return GasPruningResult(active, edge_values, round, total_time)
        end

        active[best_edge] = false
        ν_seed = subsolver.ν
    end

    active_inds = findall(active)
    subsolver = _subset_solver(s, active_inds)
    total_time += solve!(subsolver; ν0=ν_seed, throw_on_fail=false, solve_kw_nt...)
    _finalize_gas_pruning_state!(s, subsolver, active_inds, solve_kw_nt; atol=atol)

    return GasPruningResult(active, edge_values, rounds, total_time)
end

function solve_with_gas_pruning!(
    s::Solver{T};
    gas_costs::AbstractVector{T},
    atol::T=convert(T, 1e-8),
    max_rounds::Int=5,
    solve_kwargs...,
) where T
    return solve_with_fixed_gas!(
        s,
        FixedGasModel(gas_costs);
        atol=atol,
        max_rounds=max_rounds,
        solve_kwargs...,
    )
end
