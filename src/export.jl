using ACE1
using ACE1: PIBasis, PIBasisFcn, PIPotential
using ACE1: rand_radial, cutoff, numz, ZList
import Interpolations
using JuLIP: energy, bulk, i2z, z2i, chemical_symbol, SMatrix
using OrderedCollections
using YAML
export _basis_groups

function export2lammps(fname, IP; only_mb_basis = false, exclude_ranks = [])

    if !(fname[end-4:end] == ".yace")
        throw(ArgumentError("Potential name must be supplied with .yace extension"))
    end

    # decomposing into V1, V2, V3 (One body, two body and ACE bases)
    # they could be in a different order
    if only_mb_basis
        if length(IP.components) != 2
            throw("IP must have two components which are OneBody and ace")
        end
        ordered_components = []

        for target_type in [OneBody, PIPotential]
            did_not_find = true
            for i = 1:2
                if typeof(IP.components[i]) <: target_type
                    push!(ordered_components, IP.components[i])
                    did_not_find = false
                end
            end
    
            if did_not_find
                throw("IP must have three components which are OneBody, pair potential, and ace")
            end
        end
    
        V1 = ordered_components[1]
        V3 = ordered_components[2]
    else
        if length(IP.components) != 3
            throw("IP must have three components which are OneBody, pair potential, and ace")
        end

        ordered_components = []

        for target_type in [OneBody, PolyPairPot, PIPotential]
            did_not_find = true
            for i = 1:3
                if typeof(IP.components[i]) <: target_type
                    push!(ordered_components, IP.components[i])
                    did_not_find = false
                end
            end
    
            if did_not_find
                throw("IP must have three components which are OneBody, pair potential, and ace")
            end
        end
    
        V1 = ordered_components[1]
        V2 = ordered_components[2]
        V3 = ordered_components[3]
    end



    species = collect(string.(chemical_symbol.(V3.pibasis.zlist.list)))
    species_dict = Dict(zip(collect(0:length(species)-1), species))
    reversed_species_dict = Dict(zip(species, collect(0:length(species)-1)))


    elements = Vector(undef, length(species))
    E0 = zeros(length(elements))
    
    for (index, element) in species_dict
        E0[index+1] = V1(Symbol(element))
        elements[index+1] = element
    end

    # V1 and V3  (V2 handled below)

    # Begin assembling data structure for YAML
    data = OrderedDict()
    data["elements"] = elements
    data["E0"] = E0

    # embeddings
    data["embeddings"] = Dict()
    for species_ind1 in sort(collect(keys(species_dict)))
        data["embeddings"][species_ind1] = Dict(
            "ndensity" => 1,
            "FS_parameters" => [1.0, 1.0],
            "npoti" => "FinnisSinclairShiftedScaled",
            "drho_core_cutoff" => 1.000000000000000000,
            "rho_core_cutoff" => 100000.000000000000000000)
    end

    # bonds
    data["bonds"] = OrderedDict()
    radialsplines = ACE1.Splines.RadialSplines(V3.pibasis.basis1p.J; nnodes = 10000)
    ranges, nodalvals, zlist = ACE1.Splines.export_splines(radialsplines)
    # compute spline derivatives
    # TODO: move this elsewhere
    nodalderivs = similar(nodalvals)
    for iz1 in 1:size(nodalvals,2), iz2 in 1:size(nodalvals,3)
        for i in 1:size(nodalvals,1)
            range = ranges[i,iz1,iz2]
            spl = radialsplines.splines[i,iz1,iz2]
            deriv(r) = Interpolations.gradient(spl,r)[1]
            nodalderivs[i,iz1,iz2] = deriv.(range)
        end
    end
    # ----- end section to move
    for iz1 in 1:size(nodalvals,2), iz2 in 1:size(nodalvals,3)
        data["bonds"][[iz1-1,iz2-1]] = OrderedDict{Any,Any}(
            "radbasename" => "ACE.jl",
            "rcut" => ranges[1,iz1,iz2][end],         # note hardcoded 1
            "nradial" => length(V3.pibasis.basis1p.J.J.A),
            "nbins" => length(ranges[1,iz1,iz2])-1)   # note hardcoded 1
        nodalvals_map = OrderedDict([i-1 => nodalvals[i,iz1,iz2] for i in 1:size(nodalvals,1)])
        data["bonds"][[iz1-1,iz2-1]]["splinenodalvals"] = nodalvals_map
        nodalderivs_map = OrderedDict([i-1 => nodalderivs[i,iz1,iz2] for i in 1:size(nodalvals,1)])
        data["bonds"][[iz1-1,iz2-1]]["splinenodalderivs"] = nodalderivs_map
    end

    functions, lmax = export_ACE_functions(V3, species, reversed_species_dict, exclude_ranks=exclude_ranks)
    data["functions"] = functions
    data["lmax"] = lmax

    YAML.write_file(fname, data)
    if !only_mb_basis
        # ----- 2body handled separately -----
        # writes a .table file, so for simplicity require that export fname is passed with
        # .yace extension, and we remove this and add the .table extension instead
        fname_stem = fname[1:end-5]
        write_pairpot_table(fname_stem, V2, species_dict)
    end
    
end

function export_reppot(Vrep, reversed_species_dict)
    reppot = Dict("coefficients" => Dict())

    zlist_dict = Dict(zip(1:length(Vrep.Vout.basis.zlist.list), [string(chemical_symbol(z)) for z in Vrep.Vout.basis.zlist.list]))

    for (index1, element1) in zlist_dict
        for (index2, element2) in zlist_dict
            pair = [reversed_species_dict[element1], reversed_species_dict[element2]]
            coefficients = Dict( "A" => Vrep.Vin[index1, index2].A,
                                "B" => Vrep.Vin[index1, index2].B,
                                "e0" => Vrep.Vin[index1, index2].e0,
                                "ri" => Vrep.Vin[index1, index2].ri) 
            reppot["coefficients"][pair] = coefficients
        end
    end

    return reppot
end


make_dimer(s1, s2, rr) = Atoms(
    [[0.0,0.0,0.0],[rr,0.0,0.0]], 
    [[0.0,0.0,0.0],[0.0,0.0,0.0]],
    [JuLIP.atomic_mass(s1), JuLIP.atomic_mass(s2)],
    [AtomicNumber(s1), AtomicNumber(s2)],
    [100.0,100.0,100.0],
    [false, false, false])

function write_pairpot_table(fname, V2, species_dict)
    # fname is JUST THE STEM
    # write a pair_style table file for LAMMPS
    # the file has a seperate section for each species pair interaction
    # format of table pair_style is described at https://docs.lammps.org/pair_table.html

    # Create filename. Only the stem is specified
    fname = fname * "_pairpot.table"

    # enumerate sections
    species_pairs = []
    for i in 0:length(species_dict) - 1
        for j in i:length(species_dict) - 1
            push!(species_pairs, (species_dict[i], species_dict[j]))
        end
    end

    lines = Vector{String}()

    # make header. date is none since ACE1 current doesnt depend on time/dates package
    push!(lines, "# DATE: none UNITS: metal CONTRIBUTOR: ACE1.jl - https://github.com/ACEsuit/ACE1.jl")
    push!(lines, "# ACE1 pair potential")
    push!(lines, "")

    for spec_pair in species_pairs
        # make dimer
        dimer = make_dimer(Symbol(spec_pair[1]), Symbol(spec_pair[2]), 1.0)

        # get inner and outer cutoffs

        if typeof(V2.basis.J) <: SMatrix
            get_ru(jj) = jj.ru
            rus = get_ru.(V2.basis.J)
            rout = maximum(rus)    
        else
            rout = V2.basis.J.ru
        end

        rin = 0.001
        spacing = 0.001
        rs = rin:spacing:rout

        # section header
        push!(lines, string(spec_pair[1], "_", spec_pair[2]))
        push!(lines, string("N ", length(rs)))
        push!(lines, "")
        
        # values
        for (index, R) in enumerate(rs)
            set_positions!(dimer, AbstractVector{JVec{Float64}}([[R,0.0,0.0], [0.0,0.0,0.0]]))
            E = energy(V2, dimer)
            F = forces(V2, dimer)[1][1]
            push!(lines, string(index, " ", R, " ", E, " ", F))
        end
        push!(lines, "")
    end

    # write
    open(fname, "w+") do io
        for line in lines
            write(io, line * "\n")
        end
    end

    return nothing
end

function export_ACE_functions(V3, species, reversed_species_dict;exclude_ranks=[])
    functions = Dict()
    lmax = 0

    for i in 1:length(V3.pibasis.inner)
        sel_bgroups = []
        inner = V3.pibasis.inner[i]
        z0 = V3.pibasis.inner[i].z0
        coeffs = V3.coeffs[i]
        groups = _basis_groups(inner, coeffs)
        for group in groups
            for (m, c) in zip(group["M"], group["C"])
                c_ace = c / (4*π)^(group["ord"]/2)
                ind_arr = findall(x -> x == group["ord"], exclude_ranks)
                if length(ind_arr)>0
                    c_ace = 0.0*c_ace
                end
                #@show length(c_ace)
                ndensity = 1
                push!(sel_bgroups, Dict("rank" => group["ord"],
                            "mu0" => reversed_species_dict[string(chemical_symbol(group["z0"]))],
                            "ndensity" => ndensity,
                            "ns" => group["n"],
                            "ls" => group["l"],
                            "mus" => [reversed_species_dict[i] for i in string.(chemical_symbol.(group["zs"]))],
                            "ctildes" => [c_ace],
                            "ms_combs" => m,
                            "num_ms_combs" => length([c_ace])))
                if maximum(group["l"]) > lmax
                    lmax = maximum(group["l"])
                end
            end
        end
        functions[reversed_species_dict[string(chemical_symbol(z0))]] = sel_bgroups
    end

    return functions, lmax
end

function _basis_groups(inner, coeffs)
    ## grouping the basis functions
    NLZZ = []
    M = []
    C = []
    for b in keys(inner.b2iAA)
       if coeffs[ inner.b2iAA[b] ] != 0
          push!(NLZZ, ( [b1.n for b1 in b.oneps], [b1.l for b1 in b.oneps], [b1.z for b1 in b.oneps], b.z0))
          push!(M, [b1.m for b1 in b.oneps])
          push!(C, coeffs[ inner.b2iAA[b] ])
       end
    end
    ords = length.(M)
    perm = sortperm(ords)
    NLZZ = NLZZ[perm]
    M = M[perm]
    C = C[perm]
    @assert issorted(length.(M))
    bgrps = []
    alldone = fill(false, length(NLZZ))
    for i = 1:length(NLZZ)
       if alldone[i]; continue; end
       nlzz = NLZZ[i]
       Inl = findall(NLZZ .== Ref(nlzz))
       alldone[Inl] .= true
       Mnl = M[Inl]
       Cnl = C[Inl]
       pnl = sortperm(Mnl)
       Mnl = Mnl[pnl]
       Cnl = Cnl[pnl]
       order = length(nlzz[1])
       push!(bgrps, Dict("n" => nlzz[1], "l" => nlzz[2], "z0" => nlzz[4], "zs" => nlzz[3],
                         "M" => Mnl, "C" => Cnl, "ord" => order)) #correct?
    end
    return bgrps
end
