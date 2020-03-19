__precompile__()

module SkyCoords
using StaticArrays

export AbstractSkyCoords, 
       ICRSCoords,
       GalCoords,
       FK5Coords,
       separation,
       position_angle

include("types.jl")

"""
    SkyCoords.str2rad(::AbstractString, force_ha=false)

Parses strings that specify common astronomical coordinates into radians. A simplified version of the regex allowed for both

* hour angle - `"xx [h] xx ['′m:] xx [\\\"″s]?"`
* degree - `"xx [°d:] xx ['′m:] xx [\\\"″s]?"`

So, you can see that this will parse an hour angle if the leading unit contains an `h` otherwise it will parse a degree if the leading unit contains a `°`, `d` or `:`. Also, you can forego the final unit, since it will be parsed automatically. The values (`xx`) will be parsed as `Float64`.

If `force_ha` is `true` then the input will be parsed as an hour angle using a looser regex that allows the leading unit to be a `:`

* loose hour angle - `"xx [h:] xx ['′m:] xx [\\\"″s]?"`

# Examples
```jldoctest
julia> import SkyCoords: str2rad

julia> str2rad("12h52m64.300s")
3.3731614843033575

julia> str2rad("0°12'5\\\"") # Note that you have to escape the "
0.003514899188044136

julia> str2rad("-  10° 02 ′  10.885 ″") # Whitespace does not matter
-0.17389837681291273

julia> str2rad("12:0:0", true)
3.141592653589793
```
"""
function str2rad(input::AbstractString, force_ha = false)
    input = replace(strip(input), r"\s" => "")
    ha_r = r"([+-]?\d+\.?\d*)h(\d+\.?\d*)['′m:](\d+\.?\d*)[\"″s]?"
    ha_r_loose = r"([+-]?\d+\.?\d*)[h:](\d+\.?\d*)['′m:](\d+\.?\d*)[\"″s]?"
    deg_r = r"([+-]?\d+\.?\d*)[°d:](\d+\.?\d*)['′m:](\d+\.?\d*)[\"″s]?"
    if force_ha
        m = match(ha_r_loose, input)
        m === nothing && error("Could not parse $input as hour angle")
        h, m, s = parse.(Float64, m.captures)
        rad = hr2rad(h)
        rad += hr2rad(m / 60)
        rad += hr2rad(s / 3600)
        return rad
    elseif occursin(ha_r, input)
        m = match(ha_r, input)
        h, m, s = parse.(Float64, m.captures)
        rad = hr2rad(h)
        rad += hr2rad(m / 60)
        rad += hr2rad(s / 3600)
        return rad
    elseif occursin(deg_r, input)
        m = match(deg_r, input)
        d, m, s = parse.(Float64, m.captures)
        rad = deg2rad(d)
        rad += deg2rad(m / 60)
        rad += deg2rad(s / 3600)
        return rad
    else
        error("Could not parse $input to sky coordinates")
    end
end

@inline hr2rad(h::Number) = π * h / 12

# -----------------------------------------------------------------------------
# Helper functions: Create rotation matrix about a given axis (x, y, z)

function xrotmat(angle)
    s, c = sincos(angle)
    SMatrix{3,3}(1, 0, 0, 0, c, -s, 0, s, c)
end

function yrotmat(angle)
    s, c = sincos(angle)
    SMatrix{3,3}(c, 0, s, 0, 1, 0, -s, 0, c)
end

function zrotmat(angle)
    s, c = sincos(angle)
    SMatrix{3,3}(c, -s, 0, s, c, 0, 0, 0, 1)
end

# (lon, lat) -> [x, y, z] unit vector
function coords2cart(lon, lat)
    sinlon, coslon = sincos(lon)
    sinlat, coslat = sincos(lat)
    SVector{3}(coslat * coslon, coslat * sinlon, sinlat)
end

# [x, y, z] unit vector -> (lon, lat)
cart2coords(v) = atan(v[2], v[1]), atan(v[3], sqrt(v[1] * v[1] + v[2] * v[2]))

# -----------------------------------------------------------------------------
# Constant rotation matricies and precession matrix function

# ICRS --> FK5 at J2000 (See USNO Circular 179, section 3.5)
eta0 = deg2rad(-19.9 / 3600000.0)
xi0 = deg2rad(9.1 / 3600000.0)
da0 = deg2rad(-22.9 / 3600000.0)
const ICRS_TO_FK5J2000 = xrotmat(-eta0) * yrotmat(xi0) * zrotmat(da0)
const FK5J2000_TO_ICRS = ICRS_TO_FK5J2000'

# FK5J2000 --> Gal
# Note that galactic pole and zeropoint of l are somewhat arbitrary
# and not officially defined (as far as I know). The values below are
# from astropy.coordinates, which includes the following comment:
# | "This gives better consistency with other codes than using the values
# |  from Reid & Brunthaler 2004 and the best self-consistency between FK5
# |  -> Galactic and FK5 -> FK4 -> Galactic. The lon0 angle was found by
# |  optimizing the self-consistency."
ngp_fk5j2000_ra = deg2rad(192.8594812065348)
ngp_fk5j2000_dec = deg2rad(27.12825118085622)
lon0_fk5j2000 = deg2rad(122.9319185680026)
const FK5J2000_TO_GAL = (zrotmat(pi - lon0_fk5j2000) *
                         yrotmat(pi / 2.0 - ngp_fk5j2000_dec) * zrotmat(ngp_fk5j2000_ra))
const GAL_TO_FK5J2000 = FK5J2000_TO_GAL'

# Gal --> ICRS: simply chain through FK5J2000
const GAL_TO_ICRS = FK5J2000_TO_ICRS * GAL_TO_FK5J2000
const ICRS_TO_GAL = GAL_TO_ICRS'

# FK5J2000 --> FK5{epoch}
# Computes the precession matrix from J2000 to the given Julian equinox.
# Expression from from Capitaine et al. 2003 as expressed in the USNO
# Circular 179.  This should match the IAU 2006 standard from SOFA.
const pzeta = [2.650545, 2306.083227, 0.2988499, 0.01801828, -0.000005971, -0.0000003173]
const pz = [-2.650545, 2306.077181, 1.0927348, 0.01826837, -0.000028596, -0.0000002904]
const ptheta = [0.0, 2004.191903, -0.4294934, -0.04182264, -0.000007089, -0.0000001274]
function precess_from_j2000(equinox)
    t = (equinox - 2000.0) / 100.0
    tn = 1.0
    zeta = pzeta[1]
    z = pz[1]
    theta = ptheta[1]
    for i = 2:6
        tn *= t
        zeta += pzeta[i] * tn
        z += pz[i] * tn
        theta += ptheta[i] * tn
    end
    zeta = deg2rad(zeta / 3600.0)
    z = deg2rad(z / 3600.0)
    theta = deg2rad(theta / 3600.0)
    zrotmat(-z) * yrotmat(theta) * zrotmat(-zeta)
end

# -----------------------------------------------------------------------------
# Type-dependent methods

lon(c::GalCoords) = c.l
lat(c::GalCoords) = c.b
lon(c::AbstractSkyCoords) = c.ra
lat(c::AbstractSkyCoords) = c.dec

# Abstract away specific field names (ra, dec vs l, b)
coords2cart(c::AbstractSkyCoords) = coords2cart(lon(c), lat(c))

# Rotation matrix between coordinate systems: `rotmat(to, from)`
# Note that all of these return SMatrix{3,3}{Float64}, regardless of
# element type of input coordinates.
rotmat(::Type{T1}, ::Type{T2}) where {T1<:GalCoords,T2<:ICRSCoords} = ICRS_TO_GAL
rotmat(::Type{T1}, ::Type{T2}) where {T1<:ICRSCoords,T2<:GalCoords} = GAL_TO_ICRS

# Define both these so that `convert(FK5Coords{e}, ...)` and
# `convert(FK5Coords{e,T}, ...)` both work. Similar with other
# FK5Coords rotmat methods below.
@generated rotmat(::Type{FK5Coords{e1}}, ::Type{T2}) where {e1,T2<:ICRSCoords} =
    precess_from_j2000(e1) * ICRS_TO_FK5J2000
@generated rotmat(::Type{FK5Coords{e1,T1}}, ::Type{T2}) where {e1,T1,T2<:ICRSCoords} =
    precess_from_j2000(e1) * ICRS_TO_FK5J2000

@generated rotmat(::Type{FK5Coords{e1}}, ::Type{T2}) where {e1,T2<:GalCoords} =
    precess_from_j2000(e1) * GAL_TO_FK5J2000
@generated rotmat(::Type{FK5Coords{e1,T1}}, ::Type{T2}) where {e1,T1,T2<:GalCoords} =
    precess_from_j2000(e1) * GAL_TO_FK5J2000

@generated rotmat(::Type{T1}, ::Type{FK5Coords{e2,T2}}) where {T1<:ICRSCoords,e2,T2} =
    FK5J2000_TO_ICRS * precess_from_j2000(e2)'

@generated rotmat(::Type{T1}, ::Type{FK5Coords{e2,T2}}) where {T1<:GalCoords,e2,T2} =
    FK5J2000_TO_GAL * precess_from_j2000(e2)'

@generated rotmat(::Type{FK5Coords{e1}}, ::Type{FK5Coords{e2,T2}}) where {e1,e2,T2} =
    precess_from_j2000(e1) * precess_from_j2000(e2)'
@generated rotmat(::Type{FK5Coords{e1,T1}}, ::Type{FK5Coords{e2,T2}}) where {e1,T1,e2,T2} =
    precess_from_j2000(e1) * precess_from_j2000(e2)'

# ------------------------------------------------------------------------------
# Distance between coordinates

function _separation(λ_1, ϕ_1, λ_2, ϕ_2)
    Δλ = λ_2 - λ_1
    sin_Δλ, cos_Δλ = sincos(Δλ)
    sin_ϕ1, cos_ϕ1 = sincos(ϕ_1)
    sin_ϕ2, cos_ϕ2 = sincos(ϕ_2)
    return atan(
        hypot(cos_ϕ2 * sin_Δλ, cos_ϕ1 * sin_ϕ2 - sin_ϕ1 * cos_ϕ2 * cos_Δλ),
        sin_ϕ1 * sin_ϕ2 + cos_ϕ1 * cos_ϕ2 * cos_Δλ,
    )
end

"""
    separation(c1::AbstractSkyCoords, c2::AbstractSkyCoords) -> distance

Return angular separation between two sky coordinates, in radians.

The angular separation is calculated using the [Vincenty formula](http://en.wikipedia.org/wiki/Great-circle_distance), which is slightly more
complex and computationally expensive than some alternatives, but is stable at
at all distances, including the poles and antipodes.
"""
separation(c1::T, c2::T) where {T<:AbstractSkyCoords} =
    _separation(lon(c1), lat(c1), lon(c2), lat(c2))

separation(c1::T1, c2::T2) where {T1<:AbstractSkyCoords,T2<:AbstractSkyCoords} =
    separation(c1, convert(T1, c2))


"""
    position_angle(c1::AbstractSkyCoords, c2::AbstractSkyCoords) -> angle

Return position angle between two sky coordinates, in positive radians.

# Examples
```jldoctest
julia> c1 = ICRSCoords(0, 0); c2 = ICRSCoords(deg2rad(1), 0);

julia> position_angle(c1, c2) |> rad2deg
90.0
```
"""
position_angle(c1::T, c2::T) where {T <: AbstractSkyCoords} = _position_angle(lon(c1), lat(c1), lon(c2), lat(c2))
position_angle(c1::T1, c2::T2) where {T1 <: AbstractSkyCoords,T2 <: AbstractSkyCoords} = position_angle(c1, convert(T1, c2))


function _position_angle(λ1, ϕ1, λ2, ϕ2)
    sin_Δλ, cos_Δλ = sincos(λ2 - λ1)
    sin_ϕ1, cos_ϕ1 = sincos(ϕ1)
    sin_ϕ2, cos_ϕ2 = sincos(ϕ2)

    x = sin_ϕ2 * cos_ϕ1 - cos_ϕ2 * sin_ϕ1 * cos_Δλ
    y = sin_Δλ * cos_ϕ2

    return mod2pi(atan(y, x))
end

end # module
