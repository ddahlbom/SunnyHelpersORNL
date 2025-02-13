make_odd_up(num::Int64) = num - num%2 + 1
make_odd_down(num::Int64) = num + num%2 - 1

"""
    BinInfo(crystal, directions, bounds)

Construct a `BinInfo` using a Sunny `Crystal`, the local reference frame
(expressed in RLU), and the integration bounds along each axis of this reference
frame. The latter two pieces of information are what are given to Shiver when
produces a 1-D slice.
"""
struct BinSpec
    crystal    :: Sunny.Crystal
    directions :: Array{Float64, 2}
    bounds     :: Vector{Tuple{Float64, Float64}}
    ΔE         :: Float64

    function BinSpec(crystal, directions, ΔU, ΔV, ΔW, ΔE)
        bounds = [(-Δ/2, Δ/2) for Δ in [ΔU, ΔV, ΔW]]
        new(crystal, directions, bounds, ΔE)
    end
end



abstract type AbstractBinning end

struct UniformBinning <: AbstractBinning
    binspec    :: BinSpec
    bincenters :: Array{Vector{Float64}, 3}
    Ecenters   :: Vector{Float64}
    Δs         :: Vector{Float64}
end 

function UniformBinning(crystal, directions, Us, Vs, Ws, Es)

    # Ensure that spacing is uniform and make a BinSpec on these uniform values.
    Δs = map([Us, Vs, Ws, Es]) do vals
        Δs = vals[2:end] .- vals[1:end-1]
        @assert allequal(Δs) "Step sizes must all be equal for a UniformBinning"
        Δs[1]
    end
    binspec = BinSpec(crystal, directions, Δs...)

    # If only bounds are given (as opposed to a list) determine center point.
    Us, Vs, Ws, Es = map([Us, Vs, Ws, Es]) do vals
        if length(vals) == 2
            [(vals[2]+vals[1])/2]
        else
            vals
        end
    end

    # Assemble bincenters in RLU.
    bincenters = [directions*[U, V, W] for U in Us, V in Vs, W in Ws]

    return UniformBinning(binspec, bincenters, Es, Δs)
end

function Base.show(io::IO, binning::UniformBinning)
    (; bincenters, binspec) = binning
    println(io, "UniformBinning")
    nH, nK, nL = size(bincenters)

    print(io, "H: ")
    if nH == 1
        println(io, "$(bincenters[1,1,1][1]), ΔH=$(round(binspec.bounds[1][2]*2, digits=0.2))")
    else
        println(io, "$(bincenters[1,1,1][1])...$(bincenters[end,1,1][1]), ΔH=$(binspec.bounds[1][2]*2)")
    end
    print(io, "K: ")
    if nK == 1
        println(io, "$(bincenters[1,1,1][2]), ΔK=$(binspec.bounds[2][2]*2)")
    else
        println(io, "$(bincenters[1,1,1][2])...$(bincenters[1,end,1][2]), ΔH=$(binspec.bounds[1][2]*2)")
    end
    print(io, "L: ")
    if nL == 1
        println(io, "$(bincenters[1,1,1][3]), ΔL=$(binspec.bounds[3][2]*2)")
    else
        println(io, "$(bincenters[1,1,1][3])...$(bincenters[end,1,1][3]), ΔH=$(binspec.bounds[1][2]*2)")
    end

end


function corners_of_parallelepiped(directions, bounds; offset=[0., 0, 0])
    points = []
    b1, b2, b3 = bounds
    for k in 1:2, j in 1:2, i in 1:2 
        q_corner = offset + directions * [b1[i], b2[j], b3[k]]
        push!(points, q_corner)
    end
    return points
end
corners_of_parallelepiped(bi::BinSpec; offset=Sunny.Vec3(0, 0, 0)) = corners_of_parallelepiped(bi.directions, bi.bounds; offset)

function center_of_binning(binning::UniformBinning)
end

function base_and_edges_of_binning(binning::UniformBinning)
end

function suggest_extension(σ; sampdensity)
    vals, vecs = eigen(σ)
    bounds_σ = [(0, val) for val in vals]
    extrema_σ = [extrema([corner[i] for corner in corners_of_parallelepiped(vecs, bounds_σ)]) for i in 1:3]
    σs = [3extrema[2] for extrema in extrema_σ] 

    # Set the sampling density for points per some number of sigmas.
    stepsize = 3minimum(σs)/sampdensity
end

function binning_center(binning)
    (; bincenters) = binning
    return (bincenters[1] + bincenters[end])/2
end

function sample_binning_and_surrounds(binning::UniformBinning, stepsize; extension=1.0)
    (; binspec, Δs, bincenters) = binning
    (; directions, crystal) = binspec
    (; recipvecs) = crystal

    bincenter_abs = recipvecs*binning_center(binning)
    directions_abs = recipvecs*directions

    points = uniform_sampling_of_bin(bincenter_abs, directions_abs, Δs[1:3] .* size(bincenters) .+ extension*ones(3), stepsize)

    return map(p -> inv(recipvecs)*p, points)
end


function sample_bin_and_surrounds(q, bininfo::BinSpec, sigma; nsigmas=5, sampdensity=1)
    (; crystal, directions, bounds) = bininfo
    (; recipvecs) = crystal

    # Determine bounds of parallelpiped determined by scaled eigenvectors of σ
    # matrix. Use these values to determine how large a box to make.
    σ = if isa(sigma, Number)
        sigma*I(3)
    else
        sigma
    end
    vals, vecs = eigen(σ)
    bounds_σ = [(0, val) for val in vals]
    extrema_σ = [extrema([corner[i] for corner in corners_of_parallelepiped(vecs, bounds_σ)]) for i in 1:3]
    σs = [3extrema[2] for extrema in extrema_σ] 

    # Set the sampling density for points per some number of sigmas.
    stepsize = 3minimum(σs)/sampdensity

    # Make oversized set of points to fill integration region.
    corners_bin = map(point -> recipvecs*point, corners_of_parallelepiped(directions, bounds))
    extrema_bin = [extrema([corner[i] for corner in corners_bin]) for i in 1:3]
    extrema_bin = map(zip(extrema_bin, σs)) do (extrema, σ)
        (extrema[1] - nsigmas*σ, extrema[2] + nsigmas*σ)
    end
    na, nb, nc = [floor(Int64, make_odd_up(round(Int64, abs(hi - lo)/stepsize)) / 2) for (hi, lo) in extrema_bin]
    grid_abs = [stepsize * [a, b, c] for a in -na:na, b in -nb:nb, c in -nc:nc] 

    # Convert into coordinates with respect to direction vectors and filter out
    # points outside of integration region.
    points_local_frame = [inv(directions)*inv(recipvecs)*q for q in grid_abs]

    # Add back bin center and convert to RLU before returning.
    return [Sunny.Vec3(q) + directions*point for point in points_local_frame]
end



"""
    sample_bin_uniform_abs(q, bininfo; linear_distance=1.0)

Sample points inside the bin uniformly in absolute units. `linear_distance` is
given in Å⁻¹.
"""
function sample_bin_uniform_abs(q, bininfo::BinSpec, linear_distance=1.0)
    (; crystal, directions, bounds) = bininfo
    (; recipvecs) = crystal
    b1, b2, b3 = bounds

    # Make oversized set of points to fill integration region.
    corners_abs = map(point -> recipvecs*point, corners_of_parallelepiped(directions, bounds))
    extremas = [extrema([corner[i] for corner in corners_abs]) for i in 1:3]
    na, nb, nc = [floor(Int64, make_odd_up(round(Int64, abs(hi - lo)/linear_distance)) / 2) for (hi, lo) in extremas]
    grid_abs = [linear_distance * Sunny.Vec3(a, b, c) for a in -na:na, b in -nb:nb, c in -nc:nc] 

    # Convert into coordinates with respect to direction vectors and filter ou# 
# t
    # points outside of integration region.
    points_local_frame = [inv(directions)*inv(recipvecs)*q for q in grid_abs]
    # good_points_local_frame = filter(points_local_frame) do q
    #     x, y, z = q
    #     if b1[1] <= x <= b1[2] && b2[1] <= y <= b2[2] && b3[1] <= z <= b3[2]
    #         return true
    #     end
    #     false
    # end
    good_points_local_frame = points_local_frame

    # Add back bin center and convert to RLU before returning.
    return [Sunny.Vec3(q) + directions*point for point in good_points_local_frame]
end


"""
    sample_bin_uniform_rlu(q, bininfo; linear_distance=1.0)

Sample points inside the bin uniformly in RLU. `linear_distance` is
given in RLU.
"""
function uniform_sampling_of_bin(bincenter, directions, scales, spacing)
    q = Sunny.Vec3(bincenter)
    n1, n2, n3 = map(zip(scales, eachcol(directions))) do (scale, direction)
        distance = norm(scale*direction)
        floor(Int64, make_odd_down(round(Int64, distance / spacing)) / 2)
    end
    unit_directions = hcat([spacing * normalize(direction) for direction in eachcol(directions)]...)
    return [q + unit_directions * Sunny.Vec3(a, b, c) for a in -n1:n1, b in -n2:n2, c in -n3:n3]
end


"""
    sample_bin_mc(q, bininfo; nsamples=10)

Sample points in bin at random uniformly along each axis. The number of samples
is set with `nsamples` keyword. 
"""
function sample_bin_mc(q, bininfo::BinSpec; nsamples=10)
    (; directions, bounds) = bininfo
    sample_coef((min, max)) = min + (max-min)*rand()
    return [Sunny.Vec3(q) + directions * [sample_coef(bounds) for bounds in bounds] for _ in 1:nsamples] 
end


"""
    uniform_grid_from_bin(q, bininfo::BinInfo, spacing)


"""
function uniform_grid_from_bin(q, crystal, directions, bounds, spacing)
    (; recipvecs) = crystal

    # Make oversized set of points to fill integration region.
    corners_abs = map(point -> recipvecs*point, corners_of_parallelepiped(directions, bounds))
    extremas = [extrema([corner[i] for corner in corners_abs]) for i in 1:3]
    na, nb, nc = [floor(Int64, make_odd_up(round(Int64, abs(hi - lo)/spacing)) / 2) for (hi, lo) in extremas]
    grid_abs = [spacing * Sunny.Vec3(a, b, c) for a in -na:na, b in -nb:nb, c in -nc:nc] 

    # Convert to RLU and add back center 
    return [q + inv(recipvecs)*point for point in grid_abs]
end

"""
    find_points_in_bin(bincenter, bininfo, points)

Given a list of `points`, return the indices of points that lie within the
specified bin.
"""
function find_points_in_bin(bincenter, bininfo, points)
    (; directions, bounds) = bininfo
    b1, b2, b3 = bounds

    # Convert all information into local bin coordinates. 
    to_local_frame = inv(directions)
    bincenter = to_local_frame*bincenter 
    points = [to_local_frame*q for q in points] 

    return findall(points) do q
        x, y, z = q
        x_c, y_c, z_c = bincenter
        if b1[1] <= x - x_c <= b1[2] && b2[1] <= y - y_c <= b2[2] && b3[1] <= z - z_c <= b3[2]
            return true
        end
        false
    end
end
