abstract type Objective end

@doc raw"""
    U(obj::Objective, y)

Evaluates the net flow utility function `objective` at `y`.
"""
function U end

@doc raw"""
    grad_U(obj::Objective, y)
Returns the gradient of the net flow utility function `objective` at `y`.
"""
function grad_U end

@doc raw"""
    Ubar(obj::Objective, ν)

Evaluates the 'conjugate' of the net flow utility function `objective` at `ν`.
Specifically,
```math
    \bar U(\nu) = \sup_y \left(U(y) - \nu^T y \right).
```
"""
function Ubar end

@doc raw"""
    grad!(g, obj::Objective, ν)

Computes the gradient of [`Ubar(obj, ν)`](@ref) at ν.
"""
function grad_Ubar! end
grad_Ubar!(g, obj::Objective, ν) = ∇Ubar!(g, obj, ν)

@doc raw"""
    lower_limit(obj)

Componentwise lower bound on argument `ν` for objective [`Ubar`](@ref).  
Returns a vector with length `length(ν)` (number of nodes).
"""
function lower_limit end

@doc raw"""
    upper_limit(obj)

Componentwise upper bound on argument `ν` for objective [`Ubar`](@ref).  
Returns a vector with length `length(ν)` (number of nodes).
"""
function upper_limit end

lower_limit(obj::Objective) = zeros(length(obj)) .+ sqrt(eps())
upper_limit(obj::Objective) = fill(Inf, length(obj))
primal_lower_bounds(obj::Objective) = fill(-Inf, length(obj))

function recovery_targets! end

function recovery_targets!(target, fixed, obj::Objective, ν)
    grad_Ubar!(target, obj, ν)
    target .*= -1
    fill!(fixed, true)
    return nothing
end

# quadratic cost: u(y) = -0.5*(-y + b)₊²
struct NonpositiveQuadratic{T} <: Objective
    n::Int
    a::Vector{T}
    b::Vector{T}
end
function NonpositiveQuadratic(b::Vector{T}; a=nothing) where T
    a = isnothing(a) ? ones(T, length(b)) : a
    NonpositiveQuadratic(length(b), a, b)
end

Base.length(obj::NonpositiveQuadratic) = obj.n

function U(obj::NonpositiveQuadratic{T}, y) where T
    acc = zero(T)
    for i in eachindex(y)
        acc += obj.a[i] * abs2(max(obj.b[i] - y[i], zero(T)))
    end
    return -convert(T, 0.5) * acc
end

# Ū(ν) = sup_y {U(y) - ν'y}
function Ubar(obj::NonpositiveQuadratic{T}, ν) where T
    return 0.5*sum(abs2, ν ./ sqrt.(obj.a)) - dot(obj.b, ν)
end

function ∇Ubar!(g, obj::NonpositiveQuadratic{T}, ν) where T
    @. g = ν / obj.a - obj.b
    return nothing
end

struct Markowitz{T} <: Objective
    μ::Vector{T}
    Σ
end

Base.length(obj::Markowitz) = length(obj.μ)

function U(obj::Markowitz{T}, y) where T
    return dot(obj.μ, y) - 0.5*dot(y, obj.Σ*y)
end

function Ubar(obj::Markowitz{T}, ν) where T
    tmp = obj.Σ \ (obj.μ - ν)
    return 0.5 * dot(obj.μ - ν, tmp)
end

function ∇Ubar!(g, obj::Markowitz{T}, ν) where T
    g .= obj.Σ \ (ν - obj.μ)
    return nothing
end

# TODO: A bit of a hack right now. Should add to solver
function Linear(c::Vector{T}) where T
    all(c .>= 0) || throw(ArgumentError("all elements must be strictly positive"))
    return Markowitz(c, sqrt(eps())*I)
end

struct LinearNonnegative{T} <: Objective
    c::Vector{T}
end

function LinearNonnegative(c::Vector{T}) where {T<:AbstractFloat}
    all(c .> 0) || throw(ArgumentError("all elements must be strictly positive"))
    return LinearNonnegative{T}(c)
end
LinearNonnegative(c::Vector{T}) where {T<:Real} = LinearNonnegative(Float64.(c))

Base.length(obj::LinearNonnegative) = length(obj.c)

function U(obj::LinearNonnegative{T}, y) where T
    atol = convert(T, 1000) * sqrt(eps(T)) * max(one(T), maximum(abs, y))
    any(y .< -atol) && return convert(T, -Inf)
    acc = zero(T)
    for i in eachindex(y)
        acc += obj.c[i] * max(y[i], zero(T))
    end
    return acc
end

function Ubar(obj::LinearNonnegative{T}, ν) where T
    all(obj.c .<= ν) && return zero(T)
    return convert(T, Inf)
end

function ∇Ubar!(g, obj::LinearNonnegative{T}, ν) where T
    if all(obj.c .<= ν)
        g .= zero(T)
    else
        g .= convert(T, Inf)
    end
    return nothing
end

@inline lower_limit(obj::LinearNonnegative{T}) where T = obj.c .+ sqrt(eps(T))
@inline upper_limit(obj::LinearNonnegative{T}) where T = fill(convert(T, Inf), length(obj))
primal_lower_bounds(obj::LinearNonnegative{T}) where T = zeros(T, length(obj))

function recovery_targets!(target, fixed, obj::LinearNonnegative{T}, ν) where T
    fill!(target, zero(T))
    fill!(fixed, false)
    return nothing
end

struct EndowmentLinear{T} <: Objective
    c::Vector{T}
    h0::Vector{T}

    function EndowmentLinear{T}(c::Vector{T}, h0::Vector{T}) where {T<:AbstractFloat}
        length(c) == length(h0) || throw(ArgumentError("value vector and endowment must have the same length"))
        all(isfinite, c) || throw(ArgumentError("value vector must be finite"))
        all(isfinite, h0) || throw(ArgumentError("endowment must be finite"))
        all(h0 .>= zero(T)) || throw(ArgumentError("endowment must be nonnegative"))
        return new{T}(c, h0)
    end
end

EndowmentLinear(c::Vector{T}, h0::Vector{T}) where {T<:AbstractFloat} = EndowmentLinear{T}(c, h0)
EndowmentLinear(c::Vector{T}, h0::Vector{T}) where {T<:Real} = EndowmentLinear(Float64.(c), Float64.(h0))

Base.length(obj::EndowmentLinear) = length(obj.c)

function U(obj::EndowmentLinear{T}, y) where T
    atol = convert(T, 1000) * sqrt(eps(T)) * max(one(T), maximum(abs, obj.h0), maximum(abs, y))
    any(y[i] < -obj.h0[i] - atol for i in eachindex(y)) && return convert(T, -Inf)
    return dot(obj.c, y)
end

function Ubar(obj::EndowmentLinear{T}, ν) where T
    all(obj.c .<= ν) || return convert(T, Inf)
    return dot(ν .- obj.c, obj.h0)
end

function ∇Ubar!(g, obj::EndowmentLinear{T}, ν) where T
    atol = convert(T, 1000) * sqrt(eps(T)) * max(one(T), maximum(abs, obj.c), maximum(abs, ν))
    for i in eachindex(ν)
        if ν[i] < obj.c[i] - atol
            g .= convert(T, Inf)
            return nothing
        else
            g[i] = obj.h0[i]
        end
    end
    return nothing
end

@inline lower_limit(obj::EndowmentLinear{T}) where T = copy(obj.c)
@inline upper_limit(obj::EndowmentLinear{T}) where T = fill(convert(T, Inf), length(obj))
primal_lower_bounds(obj::EndowmentLinear{T}) where T = .-obj.h0

function recovery_targets!(target, fixed, obj::EndowmentLinear{T}, ν) where T
    fill!(target, zero(T))
    fill!(fixed, false)
    return nothing
end

struct BasketLiquidation{T} <: Objective
    i::Int
    Δin::Vector{T}

    function BasketLiquidation{T}(i::Integer, Δin::Vector{T}) where {T<:AbstractFloat}
        1 <= i <= length(Δin) || throw(ArgumentError("invalid output index"))
        return new{T}(Int(i), Δin)
    end
end

BasketLiquidation(i::Integer, Δin::Vector{T}) where {T<:AbstractFloat} = BasketLiquidation{T}(i, Δin)
BasketLiquidation(i::Integer, Δin::Vector{T}) where {T<:Real} = BasketLiquidation(i, Float64.(Δin))

Base.length(obj::BasketLiquidation) = length(obj.Δin)

function U(obj::BasketLiquidation{T}, y) where T
    atol = convert(T, 100) * sqrt(eps(T)) * max(one(T), maximum(abs, obj.Δin), maximum(abs, y))
    any(!isapprox(y[j], -obj.Δin[j]; atol=atol, rtol=zero(T)) for j in eachindex(y) if j != obj.i) &&
        return convert(T, -Inf)
    y[obj.i] >= 0 || return convert(T, -Inf)
    return y[obj.i]
end

function Ubar(obj::BasketLiquidation{T}, ν) where T
    ν[obj.i] >= one(T) || return convert(T, Inf)
    acc = zero(T)
    for j in eachindex(ν)
        j == obj.i && continue
        acc += obj.Δin[j] * ν[j]
    end
    return acc
end

function ∇Ubar!(g, obj::BasketLiquidation{T}, ν) where T
    if ν[obj.i] >= one(T)
        g .= obj.Δin
        g[obj.i] = zero(T)
    else
        g .= convert(T, Inf)
    end
    return nothing
end

@inline function lower_limit(obj::BasketLiquidation{T}) where T
    ret = fill(sqrt(eps(T)), length(obj))
    ret[obj.i] = one(T) + sqrt(eps(T))
    return ret
end
@inline upper_limit(obj::BasketLiquidation{T}) where T = fill(convert(T, Inf), length(obj))

function recovery_targets!(target, fixed, obj::BasketLiquidation{T}, ν) where T
    target .= -obj.Δin
    target[obj.i] = zero(T)
    fill!(fixed, true)
    fixed[obj.i] = false
    return nothing
end

struct BasketAcquisition{T} <: Objective
    i::Int
    Λout::Vector{T}

    function BasketAcquisition{T}(i::Integer, Λout::Vector{T}) where {T<:AbstractFloat}
        1 <= i <= length(Λout) || throw(ArgumentError("invalid input index"))
        return new{T}(Int(i), Λout)
    end
end

BasketAcquisition(i::Integer, Λout::Vector{T}) where {T<:AbstractFloat} = BasketAcquisition{T}(i, Λout)
BasketAcquisition(i::Integer, Λout::Vector{T}) where {T<:Real} = BasketAcquisition(i, Float64.(Λout))

Base.length(obj::BasketAcquisition) = length(obj.Λout)

function U(obj::BasketAcquisition{T}, y) where T
    atol = convert(T, 100) * sqrt(eps(T)) * max(one(T), maximum(abs, obj.Λout), maximum(abs, y))
    any(!isapprox(y[j], obj.Λout[j]; atol=atol, rtol=zero(T)) for j in eachindex(y) if j != obj.i) &&
        return convert(T, -Inf)
    return y[obj.i]
end

function Ubar(obj::BasketAcquisition{T}, ν) where T
    atol = sqrt(eps(T))
    isapprox(ν[obj.i], one(T); atol=atol, rtol=zero(T)) || return convert(T, Inf)
    acc = zero(T)
    for j in eachindex(ν)
        j == obj.i && continue
        acc -= obj.Λout[j] * ν[j]
    end
    return acc
end

function ∇Ubar!(g, obj::BasketAcquisition{T}, ν) where T
    atol = sqrt(eps(T))
    if isapprox(ν[obj.i], one(T); atol=atol, rtol=zero(T))
        g .= -obj.Λout
        g[obj.i] = zero(T)
    else
        g .= convert(T, Inf)
    end
    return nothing
end

@inline function upper_limit(obj::BasketAcquisition{T}) where T
    ret = fill(convert(T, Inf), length(obj))
    ret[obj.i] = one(T)
    return ret
end

@inline function lower_limit(obj::BasketAcquisition{T}) where T
    ret = fill(sqrt(eps(T)), length(obj))
    ret[obj.i] = one(T)
    return ret
end

function recovery_targets!(target, fixed, obj::BasketAcquisition{T}, ν) where T
    target .= obj.Λout
    target[obj.i] = zero(T)
    fill!(fixed, true)
    fixed[obj.i] = false
    return nothing
end

function Swap(i::Int, j::Int, δ::T, n::Int) where {T<:AbstractFloat}
    Δin = zeros(T, n)
    Δin[j] = δ
    return BasketLiquidation(i, Δin)
end

function SwapExactOutput(i::Int, j::Int, λ::T, n::Int) where {T<:AbstractFloat}
    Λout = zeros(T, n)
    Λout[i] = λ
    return BasketAcquisition(j, Λout)
end
