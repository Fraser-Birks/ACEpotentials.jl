# # Smoothness Priors

using ACE1pack, LinearAlgebra, Plots

# ACE1pack models make heavy use of smoothness priors, i.e., prior parameter distributions that impose smoothness on the fitted potential. This tutorial demonstrates how to use the smoothness priors implemented in ACE1pack.
# We start by reading in a tiny testing dataset, and bring the data into a format
# that ACEfit likes. Note that using a very limited dataset makes the use of priors particularlty important. In general, the larger and more diverse the dataset, the less important the prior becomes.

rawdata, _, _ = ACE1pack.example_dataset("Si_tiny")
datakeys = (energy_key = "dft_energy", force_key = "dft_force", virial_key = "dft_virial")

rcut = 6.0     # cut off distance 
r_nn = 2.3     # typical nearest neighbour distance

model = ACE1x.acemodel(elements = [:Si],
                       order = 3, totaldegree = 10,
                       rcut = rcut, r0 = r_nn, 
                       Eref = Dict("Si" => -158.54496821))

data = [ AtomsData(at; datakeys..., v_ref = model.Vref) for at in rawdata ]
A, Y, W = ACEfit.assemble(data, model.basis)

# A positive definite matrix P specifies a normal prior distribution in the Bayesian framework, but for the purpose of this tutorial it is maybe more intuitive to simply think of it as a regularisation operator. The regularised linear least squares problem is 
# ```math
#   \| A c - y \|^2 + \lambda \| P c \|^2
# ```
# where `A` is the design matrix, ``y`` is the vector of observations, ``c`` is the vector of parameters, and ``\lambda`` is a regularisation parameter. The prior matrix ``P`` is specified by the user. At present we support diagonal operators ``P``. The diagonal elements of ``P`` are the prior variances. The larger the prior variance, the smoother the fitted potential.
# Although not *strictly* true, we can think of each basis function as specified by a the parameters ``(n_t, l_t)_{t = 1}^N``, where ``N``` is the correlation-order. 
# The corresponding prior matrix element must be a function of those ``n_t, l_t`` values. We currently support three classes: algebraic, exponential and gaussian. 

# TODO: write down the precise definitions.

# In the following we demonstrate the usage of algebraic and gaussian priors.

Pa2 = algebraic_smoothness_prior(model.basis; p=2)
Pa4 = algebraic_smoothness_prior(model.basis; p=4)
Pg = gaussian_smoothness_prior(model.basis, σl = (2/rcut)^2, σn = 0.2*(2/r_nn)^2)

# For each prior constructed above we now solve the regularised least squares problem. Note how design matrix need only be assembled once if we want to play with many different priors. Most of the time we would just use defaults however and then these steps are all taken care of behind the scenes. 

priors = Dict("Id" => I, "Algebraic(2)" => Pa2, "Algebraic(4)" => Pa4,"Gaussian" => Pg)
rmse = Dict() 
pots = Dict() 

for (prior_name, P) in priors
    println("Solving with ", prior_name, " prior")
    
    # solve the regularized least squares problem 
    Ã = Diagonal(W) * (A / P)
    ỹ = Diagonal(W) * Y
    c̃ = ACEfit.solve(ACEfit.BLR(; verbose=false), Ã, ỹ)["C"]
    ACE1x._set_params!(model, P \ c̃)

    # 
    errs = ACE1pack.linear_errors(rawdata, model; verbose=false, datakeys...)
    rmse[prior_name] = errs["rmse"]["set"]["F"]
    pots[prior_name] = model.potential
end

# The force RMSE errors are comparable for the three priors, though slightly better for the weaker smoothness priors `Algebraic(2)` and `Id`. This is unsurprising, since those priors are less restrictive. 

@info("Force RMSE")
display(rmse)

# On the other hand, we expect the stronger priors to generalize better. A typical intuition is that smooth potentials with similar accuracy will be more transferable than rougher potentials. 

