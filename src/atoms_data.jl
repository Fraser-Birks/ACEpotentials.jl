import ACEfit
import JuLIP: Atoms, energy, forces, mat
using PrettyTables
using OrderedCollections
using StaticArrays: SVector
using StatsBase

export AtomsData, 
       print_rmse_table, print_mae_table, print_errors_tables

struct AtomsData <: ACEfit.AbstractData
    atoms::Atoms
    energy_key::Union{String, Nothing}
    force_key::Union{String, Nothing}
    virial_key::Union{String, Nothing}
    pae_key::Union{String, Nothing}
    mask_key::Union{String, Nothing}
    weights
    energy_ref
    function AtomsData(atoms::Atoms;
                       energy_key=nothing,
                       force_key=nothing,
                       virial_key=nothing,
                       pae_key=nothing,
                       mask_key=nothing,
                       weights=Dict("default"=>Dict("E"=>1.0, "F"=>1.0, "V"=>1.0)),
                       v_ref=nothing, 
                       weight_key="config_type")
        # set energy, force, and virial keys for this configuration
        # ("nothing" indicates data that are absent or ignored)
        ek, fk, vk, paek, mk = nothing, nothing, nothing, nothing, nothing
        if !isnothing(energy_key)
            for key in keys(atoms.data)
                (lowercase(energy_key)==lowercase(key)) && (ek=key)
            end
        end
        if !isnothing(force_key)
            for key in keys(atoms.data)
                (lowercase(force_key)==lowercase(key)) && (fk=key)
            end
        end
        if !isnothing(virial_key)
            for key in keys(atoms.data)
                (lowercase(virial_key)==lowercase(key)) && (vk=key)
            end
        end
        if !isnothing(pae_key)
            for key in keys(atoms.data)
                (lowercase(pae_key)==lowercase(key)) && (paek=key)
            end
        end
        if !isnothing(mask_key)
            for key in keys(atoms.data)
                (lowercase(mask_key)==lowercase(key)) && (mk=key)
            end
        end

        # set weights for this configuration
        if "default" in keys(weights)
            w = weights["default"]
        else
            w = Dict("E"=>1.0, "F"=>1.0, "V"=>1.0)
        end
        for (key, val) in atoms.data
            if lowercase(key)==weight_key && (lowercase(val.data) in lowercase.(keys(weights)))
                w = weights[val.data]
            end
        end

        if isnothing(v_ref)
            e_ref = 0.0
        else
            e_ref = energy(v_ref, atoms)
        end

        return new(atoms, ek, fk, vk, paek, mk, w, e_ref)
    end
end

function _get_mask(d::AtomsData;force_mask=false)
    if isnothing(d.mask_key)
        mask = !=(0).(ones(length(d.atoms)))
    else
        mask = !=(0).(d.atoms.data[d.mask_key].data)
    end
    if force_mask
        mask = inverse_rle(mask,3 .*ones(Int, length(mask)))
    end
    return mask
end

function ACEfit.count_observations(d::AtomsData)
    pae_mask = _get_mask(d)
    force_mask = _get_mask(d,force_mask=true)
    count = !isnothing(d.energy_key) +
        sum(force_mask)*!isnothing(d.force_key) +
        6*!isnothing(d.virial_key) + 
        sum(pae_mask)*!isnothing(d.pae_key)
    println(count)
    return count
end

function ACEfit.feature_matrix(d::AtomsData, basis; kwargs...)
    dm = Array{Float64}(undef, ACEfit.count_observations(d), length(basis))
    i = 1
    pae_mask = _get_mask(d)
    force_mask = _get_mask(d,force_mask=true)
    if !isnothing(d.energy_key)
        dm[i,:] .= energy(basis, d.atoms)
        i += 1
    end
    if !isnothing(d.force_key)
        f = mat.(forces(basis, d.atoms))
        for j in 1:length(basis)
            dm[i:i+sum(force_mask)-1,j] .= f[j][force_mask]
        end
        i += sum(force_mask)
    end
    if !isnothing(d.virial_key)
        v = virial(basis, d.atoms)
        for j in 1:length(basis)
            dm[i:i+5,j] .= v[j][SVector(1,5,9,6,3,2)]
        end
        i += 6
    end
    if !isnothing(d.pae_key)
        #E = energy(basis, d.atoms)
        pae = hcat([site_energy(basis, d.atoms, i) for i in 1:length(d.atoms)]...)
        #test = dropdims(sum(pae,dims=2),dims=2)
        #println(E-test)
        #exit()
        #println(size(pae))
        pae = [pae[iB, :] for iB = 1:length(basis)]
        #println(size(pae))
        #println(pae[1][:])
        for j in 1:length(basis)
            dm[i:i+sum(pae_mask)-1,j] .= pae[j][pae_mask]
        end
        i += sum(pae_mask)
    end
    return dm
end

function ACEfit.target_vector(d::AtomsData; kwargs...)
    y = Array{Float64}(undef, ACEfit.count_observations(d))
    i = 1
    pae_mask = _get_mask(d)
    force_mask = _get_mask(d,force_mask=true)
    if !isnothing(d.energy_key)
        e = d.atoms.data[d.energy_key].data
        y[i] = e - d.energy_ref
        i += 1
    end
    if !isnothing(d.force_key)
        f = mat(d.atoms.data[d.force_key].data)
        y[i:i+sum(force_mask)-1] .= f[force_mask]
        i += sum(force_mask)
    end
    if !isnothing(d.virial_key)
        # the following hack is necessary for 3-atom cells:
        #   https://github.com/JuliaMolSim/JuLIP.jl/issues/166
        #v = vec(d.atoms.data[d.virial_key].data)
        v = vec(hcat(d.atoms.data[d.virial_key].data...))
        y[i:i+5] .= v[SVector(1,5,9,6,3,2)]
        i += 6
    end
    if !isnothing(d.pae_key)
        #println(d.atoms.data[d.pae_key].data[pae_mask] .- (d.energy_ref/length(d.atoms)))
        #exit()
        y[i:i+sum(pae_mask)-1] .= d.atoms.data[d.pae_key].data[pae_mask] .- (d.energy_ref/length(d.atoms))
        i += sum(pae_mask)
    end
    return y
end

function ACEfit.weight_vector(d::AtomsData; kwargs...)
    w = Array{Float64}(undef, ACEfit.count_observations(d))
    i = 1
    pae_mask = _get_mask(d)
    force_mask = _get_mask(d,force_mask=true)
    if !isnothing(d.energy_key)
        w[i] = d.weights["E"] / sqrt(length(d.atoms))
        i += 1
    end
    if !isnothing(d.force_key)
        w[i:i+sum(force_mask)-1] .= d.weights["F"]
        i += sum(force_mask)
    end
    if !isnothing(d.virial_key)
        w[i:i+5] .= d.weights["V"] / sqrt(length(d.atoms))
        i += 6
    end
    if !isnothing(d.pae_key)
        w[i:i+sum(pae_mask)-1] .= 1.0
        i += sum(pae_mask)
    end
    return w
end

function recompute_weights(raw_data;
                           energy_key=nothing, force_key=nothing, virial_key=nothing,
                           weights=Dict("default"=>Dict("E"=>1.0, "F"=>1.0, "V"=>1.0)))
    data = [ AtomsData(at; energy_key = energy_key, force_key=force_key, pae_key=pae_key, mask_key=mask_key,
                   virial_key = virial_key, weights = weights) for at in raw_data ]
    return ACEfit.assemble_weights(data)
end

function group_type(d::AtomsData; group_key="config_type")
    group_type = "default"
    for (k,v) in d.atoms.data
        if (lowercase(k)==group_key)
            group_type = v.data
        end
    end
    return group_type
end

function linear_errors(data::AbstractArray{AtomsData}, model; group_key="config_type", verbose=true)

   mae = Dict("E"=>0.0, "F"=>0.0, "V"=>0.0, "PAE"=>0.0)
   rmse = Dict("E"=>0.0, "F"=>0.0, "V"=>0.0, "PAE"=>0.0)
   num = Dict("E"=>0, "F"=>0, "V"=>0, "PAE"=>0)

   config_types = []
   config_mae = Dict{String,Any}()
   config_rmse = Dict{String,Any}()
   config_num = Dict{String,Any}()

   for d in data

       c_t = group_type(d; group_key)
       if !(c_t in config_types)
          push!(config_types, c_t)
          merge!(config_rmse, Dict(c_t=>Dict("E"=>0.0, "F"=>0.0, "V"=>0.0, "PAE"=>0.0)))
          merge!(config_mae, Dict(c_t=>Dict("E"=>0.0, "F"=>0.0, "V"=>0.0, "PAE"=>0.0)))
          merge!(config_num, Dict(c_t=>Dict("E"=>0, "F"=>0, "V"=>0, "PAE"=>0)))
       end

       # energy errors
       if !isnothing(d.energy_key)
           estim = energy(model, d.atoms) / length(d.atoms)
           exact = d.atoms.data[d.energy_key].data / length(d.atoms)
           mae["E"] += abs(estim-exact)
           rmse["E"] += (estim-exact)^2
           num["E"] += 1
           config_mae[c_t]["E"] += abs(estim-exact)
           config_rmse[c_t]["E"] += (estim-exact)^2
           config_num[c_t]["E"] += 1
       end

       # force errors
       if !isnothing(d.force_key)
           estim = mat(forces(model, d.atoms))
           exact = mat(d.atoms.data[d.force_key].data)
           mae["F"] += sum(abs.(estim-exact))
           rmse["F"] += sum((estim-exact).^2)
           num["F"] += 3*length(d.atoms)
           config_mae[c_t]["F"] += sum(abs.(estim-exact))
           config_rmse[c_t]["F"] += sum((estim-exact).^2)
           config_num[c_t]["F"] += 3*length(d.atoms)
       end

       # virial errors
       if !isnothing(d.virial_key)
           estim = virial(model, d.atoms)[SVector(1,5,9,6,3,2)] ./ length(d.atoms)
           # the following hack is necessary for 3-atom cells:
           #   https://github.com/JuliaMolSim/JuLIP.jl/issues/166
           #exact = d.atoms.data[d.virial_key].data[SVector(1,5,9,6,3,2)] ./ length(d.atoms)
           exact = hcat(d.atoms.data[d.virial_key].data...)[SVector(1,5,9,6,3,2)] ./ length(d.atoms)
           mae["V"] += sum(abs.(estim-exact))
           rmse["V"] += sum((estim-exact).^2)
           num["V"] += 6
           config_mae[c_t]["V"] += sum(abs.(estim-exact))
           config_rmse[c_t]["V"] += sum((estim-exact).^2)
           config_num[c_t]["V"] += 6
       end

       # pae errors
       if !isnothing(d.pae_key)
           estim = [site_energy(model, d.atoms, i) for i in 1:length(d.atoms)]
           exact = d.atoms.data[d.pae_key].data
           mae["PAE"] += sum(abs.(estim-exact))
           rmse["PAE"] += sum((estim-exact).^2)
           num["PAE"] += length(d.atoms)
           config_mae[c_t]["PAE"] += sum(abs.(estim-exact))
           config_rmse[c_t]["PAE"] += sum((estim-exact).^2)
           config_num[c_t]["PAE"] += length(d.atoms)
       end
    end

    # finalize errors
    for (k,n) in num
        (n==0) && continue
        rmse[k] = sqrt(rmse[k] / n)
        mae[k] = mae[k] / n
    end
    errors = Dict("mae"=>mae, "rmse"=>rmse)

    # finalize config errors
    for c_t in config_types
        for (k,c_n) in config_num[c_t]
            (c_n==0) && continue
            config_rmse[c_t][k] = sqrt(config_rmse[c_t][k] / c_n)
            config_mae[c_t][k] = config_mae[c_t][k] / c_n
        end
    end
    config_errors = Dict("mae"=>config_mae, "rmse"=>config_rmse)

    # merge errors into config_errors and return
    push!(config_types, "set")
    merge!(config_errors["mae"], Dict("set"=>mae))
    merge!(config_errors["rmse"], Dict("set"=>rmse))

    if verbose
        print_errors_tables(config_errors)
    end 

    return config_errors
end


function print_errors_tables(config_errors::Dict)
    print_rmse_table(config_errors)
    print_mae_table(config_errors)
end

function _print_err_tbl(D::Dict)
    header = ["Type", "E [meV]", "F [eV/A]", "V [meV]", "PAE [meV]"]
    config_types = setdiff(collect(keys(D)), ["set",])
    push!(config_types, "set")
    table = hcat(
        config_types,
        [1000*D[c_t]["E"] for c_t in config_types],
        [D[c_t]["F"] for c_t in config_types],
        [1000*D[c_t]["V"] for c_t in config_types],
        [1000*D[c_t]["PAE"] for c_t in config_types]
    )
    pretty_table(
        table; header=header,
        body_hlines=[length(config_types)-1],
        formatters=ft_printf("%5.3f"),
        crop = :horizontal)

end

function print_rmse_table(config_errors::Dict; header=true)
    if header; (@info "RMSE Table"); end 
    _print_err_tbl(config_errors["rmse"])
end

function print_mae_table(config_errors::Dict; header=true)
    if header; (@info "MAE Table"); end 
    _print_err_tbl(config_errors["mae"])
end


function assess_dataset(data; kwargs...)
    config_types = []

    n_configs = OrderedDict{String,Integer}()
    n_environments = OrderedDict{String,Integer}()
    n_energies = OrderedDict{String,Integer}()
    n_forces = OrderedDict{String,Integer}()
    n_virials = OrderedDict{String,Integer}()

    for d in data
        if haskey(kwargs, :group_key)
            c_t = group_type(d; group_key=kwargs[:group_key])
        else
            c_t = group_type(d)
        end
        if !(c_t in config_types)
            push!(config_types, c_t)
            n_configs[c_t] = 0
            n_environments[c_t] = 0
            n_energies[c_t] = 0
            n_forces[c_t] = 0
            n_virials[c_t] = 0
        end
        n_configs[c_t] += 1
        n_environments[c_t] += length(d)
        _has_energy(d; kwargs...) && (n_energies[c_t] += 1)
        _has_forces(d; kwargs...) && (n_forces[c_t] += 3*length(d))
        _has_virial(d; kwargs...) && (n_virials[c_t] += 6)
    end

    n_configs = collect(values(n_configs))
    n_environments = collect(values(n_environments))
    n_energies = collect(values(n_energies))
    n_forces = collect(values(n_forces))
    n_virials = collect(values(n_virials))

    header = ["Type", "#Configs", "#Envs", "#E", "#F", "#V"]
    table = hcat(
        config_types, n_configs, n_environments,
        n_energies, n_forces, n_virials)
    tot = [
        "total", sum(n_configs), sum(n_environments),
         sum(n_energies), sum(n_forces), sum(n_virials)]
    miss = [
        "missing", 0, 0,
        tot[4]-tot[2], 3*tot[3]-tot[5], 6*tot[2]-tot[6]]
    table = vcat(table, permutedims(tot), permutedims(miss))
    pretty_table(table; header=header, body_hlines=[length(n_configs)], crop = :horizontal)

end

_has_energy(data::AtomsData; kwargs...) = !isnothing(data.energy_key)
_has_forces(data::AtomsData; kwargs...) = !isnothing(data.force_key)
_has_virial(data::AtomsData; kwargs...) = !isnothing(data.virial_key)


Base.length(a::AtomsData) = length(a.atoms)