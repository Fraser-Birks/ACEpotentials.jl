# This script is to explore the differences between the ACE1 models and the new 
# models. This is to help bring the two to feature parity so that ACE1 
# can be retired. 

using Random
using ACEpotentials, AtomsBase, AtomsBuilder, Lux, StaticArrays, LinearAlgebra, 
      Unitful, Zygote, Optimisers, Folds, Plots
rng = Random.GLOBAL_RNG

# we will try this for a simple dataset, Zuo et al 
# replace element with any of those available in that dataset 

Z0 = :Si 
z1 = AtomicNumber(Z0)
z2 = Int(z1)

train, test, _ = ACEpotentials.example_dataset("Zuo20_$Z0")
train = train[1:3:end]

# because the new implementation is experimental, it is not exported, 
# so I create a little shortcut to have easy access. 

M = ACEpotentials.Models

# First we create an ACE1 style potential with some standard parameters 

elements = [Z0,]
order = 3 
totaldegree = 10
rcut = 5.5 

model1 = acemodel(elements = elements, 
                  order = order, 
                  transform = (:agnesi, 2, 2),
                  totaldegree = totaldegree, 
                  pure = false, 
                  pure2b = false, 
                  pair_envelope = (:r, 1), 
                  rcut = rcut,  )

# now we create an ACE2 style model that should behave similarly                   

# this essentially reproduces the rcut = 5.5, we may want a nicer way to 
# achieve this. 

rin0cuts = M._default_rin0cuts(elements) #; rcutfactor = 2.29167)
rin0cuts = SMatrix{1,1}((;rin0cuts[1]..., :rcut => 5.5))

model2 = M.ace_model(; elements = elements, 
                       order = order,               # correlation order 
                       Ytype = :solid,              # solid vs spherical harmonics
                       level = M.TotalDegree(),     # how to calculate the weights to give to a basis function
                       max_level = totaldegree,     # maximum level of the basis functions
                       pair_maxn = totaldegree,     # maximum number of basis functions for the pair potential 
                       init_WB = :zeros,            # how to initialize the ACE basis parmeters
                       init_Wpair = "linear",         # how to initialize the pair potential parameters
                       init_Wradial = :linear, 
                       pair_transform = (:agnesi, 1, 3), 
                       pair_learnable = true, 
                       rin0cuts = rin0cuts, 
                     )

ps, st = Lux.setup(rng, model2)                     
ps_r = ps.rbasis
st_r = st.rbasis

# extract the radial basis 
rbasis1 = model1.basis.BB[2].pibasis.basis1p.J
rbasis2 = model2.rbasis
k = length(rbasis1.J.A)

# transform old coefficients to new coefficients to make them match 

rbasis1.J.A[:] .= rbasis2.polys.A[1:k]
rbasis1.J.B[:] .= rbasis2.polys.B[1:k]
rbasis1.J.C[:] .= rbasis2.polys.C[1:k]
rbasis1.J.A[2] /= rbasis1.J.A[1] 
rbasis1.J.B[2] /= rbasis1.J.A[1]

# wrap the model into a calculator, which turns it into a potential...

calc_model2 = M.ACEPotential(model2)


##

# look at the specifications 
_spec1 = ACE1.get_nl(model1.basis.BB[2])
spec1 = [ [ (n = b.n, l = b.l) for b in bb ] for bb in _spec1 ]
spec2 = M.get_nnll_spec(model2.tensor)
spec1 = sort.(spec1)
spec2 = sort.(spec2)

Nb = length(spec2)

##

@info("Set differences of spec suggest the bases are consistent")
spec_1diff2 = setdiff(spec1, spec2)
spec_2diff1 = setdiff(spec2, spec1)
@show length(spec_2diff1)
@show length(spec_1diff2)
@show length(spec1) - length(spec2)

##

idx2in1 = [ findfirst( Ref(bb) .== spec1 ) for bb in spec2 ]
@show length(idx2in1) == Nb

# now we can check the span 

Nenv = 1000
XX2 = [ M.rand_atenv(model2, rand(6:10)) for _=1:Nenv ]
XX1 = [ (x[1], AtomicNumber.(x[2]), AtomicNumber(x[3])) for x in XX2 ]

B1 = [ ACE1.evaluate(model1.basis.BB[2], x...)[idx2in1] for x in XX1 ]

I2mb = M.get_basis_inds(model2, z2)
B2 = [ M.evaluate_basis(model2, x..., ps, st)[I2mb] for x in XX2 ]

A1 = reduce(hcat, B1)
A2 = reduce(hcat, B2)

# see whether they span the same space 
# for the full basis this is not even close to true. ... 
C = A1' \ A2'
norm(A2' - A1' * C)

# we can make a list of all basis functions that fail ... 
@info("make a list of failed basis functions")
err = sum(abs, A2' - A1' * C, dims = (1,))[:]
idx_fail = findall(err .> 1e-8)

spec_fail = spec2[I2mb[idx_fail]]
@info("List of failed basis functions: ")
display(spec_fail)

@info("Compare with list of basis functions that have l > 0")
maxll = [ maximum(b.l for b in bb) for bb in spec2[I2mb] ]
idx_hasl = findall(maxll .> 0)
@show sort(idx_fail) == sort(idx_hasl)

## ------------------------------------------------------------------
## try for the 1-correlations: 

@info("Checking consistencyy of 1-correlations")
idx1 = 1:10 
C1 = A2[idx1, :] / A1[idx1,:]
@show norm(C1 * A2[idx1,:] - A1[idx1,:])

## try for 1- and 2-correlations 

idx21 = findall(length.(spec1[idx2in1]) .<= 2)
idx22 = findall(length.(spec2) .<= 2)
C2 = A2[idx22, :]' \ A1[idx21, :]'
@show norm(A1[idx21, :]' - A2[idx22,:]' * C2)
err = sum(abs, A1[idx21, :]' - A2[idx22,:]' * C2, dims = (1,))
idx_err = findall(err[:] .> 1e-10)


