using MPI
using CLIMA
using CLIMA.Mesh.Topologies
using CLIMA.Mesh.Grids
using CLIMA.DGBalanceLawDiscretizations
using CLIMA.DGBalanceLawDiscretizations.NumericalFluxes
using CLIMA.MPIStateArrays
using CLIMA.LowStorageRungeKuttaMethod
using CLIMA.ODESolvers
using CLIMA.GenericCallbacks
using CLIMA.ParametersType
using LinearAlgebra
using StaticArrays
using Logging, Printf, Dates
using CLIMA.Vtk
using DelimitedFiles
using Dierckx
using Random

using TimerOutputs

const to = TimerOutput()

if haspkg("CuArrays")
    using CUDAdrv
    using CUDAnative
    using CuArrays
    CuArrays.allowscalar(false)
    const ArrayType = CuArray
else
    const ArrayType = Array
end

# Prognostic equations: ρ, (ρu), (ρv), (ρw), (ρe_tot), (ρq_tot)
# For the dry example shown here, we load the moist thermodynamics module 
# and consider the dry equation set to be the same as the moist equations but
# with total specific humidity = 0. 
using CLIMA.MoistThermodynamics
using CLIMA.PlanetParameters: R_d, cp_d, grav, cv_d, MSLP, T_0, Omega

# State labels 
const _nstate = 6
const _ρ, _U, _V, _W, _E, _QT = 1:_nstate
const stateid = (ρid = _ρ, Uid = _U, Vid = _V, Wid = _W, Eid = _E, QTid = _QT)
const statenames = ("RHO", "U", "V", "W", "E", "QT")

# Viscous state labels
const _nviscstates = 16
const _τ11, _τ22, _τ33, _τ12, _τ13, _τ23, _qx, _qy, _qz, _Tx, _Ty, _Tz, _θx, _θy, _θz, _SijSij = 1:_nviscstates

# Gradient state labels
# Gradient state labels
const _states_for_gradient_transform = (_ρ, _U, _V, _W, _E, _QT)

const _nauxstate = 15
const _a_x, _a_y, _a_z, _a_sponge, _a_02z, _a_z2inf, _a_rad, _a_ν_e, _a_LWP_02z, _a_LWP_z2inf,_a_q_liq,_a_θ, _a_P, _a_T, _a_soundspeed_air = 1:_nauxstate

if !@isdefined integration_testing
  const integration_testing =
    parse(Bool, lowercase(get(ENV,"JULIA_CLIMA_INTEGRATION_TESTING","false")))
end

# Problem constants (TODO: parameters module (?))
@parameter Prandtl 71 // 100 "Prandtl (molecular)"
@parameter  μ_sgs 100.0 "Constant dynamic viscosity"
@parameter Prandtl_t 1//3 "Prandtl_t"
@parameter cp_over_prandtl cp_d / Prandtl_t "cp_over_prandtl"

# Random number seed
const seed = MersenneTwister(0)



function global_max(A::MPIStateArray, states=1:size(A, 2))
  host_array = Array ∈ typeof(A).parameters
  h_A = host_array ? A : Array(A)
  locmax = maximum(view(h_A, :, states, A.realelems)) 
  MPI.Allreduce([locmax], MPI.MAX, A.mpicomm)[1]
end

function global_mean(A::MPIStateArray, states=1:size(A,2))
  host_array = Array ∈ typeof(A).parameters
  h_A = host_array ? A : Array(A) 
  (Np, nstate, nelem) = size(A) 
  numpts = (nelem * Np) + 1
  localsum = sum(view(h_A, :, states, A.realelems)) 
  MPI.Allreduce([localsum], MPI.SUM, A.mpicomm)[1] / numpts 
end

# User Input
const numdims = 2
const Npoly = 4

# Define grid size 
Δx    = 200
Δy    = 200
Δz    = 200

#
# OR:
#
# Set Δx < 0 and define  Nex, Ney, Nez:
#
(Nex, Ney, Nez) = (5, 5, 5)

# Physical domain extents 
const (xmin, xmax) = (0, 20000)
const (ymin, ymax) = (0, 10000)
const (zmin, zmax) = (0, 10000)

#Get Nex, Ney from resolution
const Lx = xmax - xmin
const Ly = ymax - ymin
const Lz = zmax - ymin

if ( Δx > 0)
    #
    # User defines the grid size:
    #
    Nex = ceil(Int64, Lx / (Δx * Npoly))
    Ney = ceil(Int64, Ly / (Δy * Npoly))
    Nez = ceil(Int64, Lz / (Δz * Npoly))
else
    #
    # User defines the number of elements:
    #
    Δx = Lx / (Nex * Npoly)
    Δy = Ly / (Ney * Npoly)
    Δz = Lz / (Nez * Npoly)
end


DoF = (Nex*Ney*Nez)*(Npoly+1)^numdims*(_nstate)
DoFstorage = (Nex*Ney*Nez)*(Npoly+1)^numdims*(_nstate + _nviscstates + _nauxstate + CLIMA.Mesh.Grids._nvgeo) +
             (Nex*Ney*Nez)*(Npoly+1)^(numdims-1)*2^numdims*(CLIMA.Mesh.Grids._nsgeo)


# Smagorinsky model requirements : TODO move to SubgridScaleTurbulence module 
@parameter C_smag 0.15 "C_smag"
# Equivalent grid-scale
#Δ = (Δx * Δy * Δz)^(1/3)
Δ = max(Δx, Δy)
const Δsqr = Δ * Δ

# -------------------------------------------------------------------------
# Preflux calculation: This function computes parameters required for the 
# DG RHS (but not explicitly solved for as a prognostic variable)
# In the case of the rising_thermal_bubble example: the saturation
# adjusted temperature and pressure are such examples. Since we define
# the equation and its arguments here the user is afforded a lot of freedom
# around its behaviour. 
# The preflux function interacts with the following  
# Modules: NumericalFluxes.jl 
# functions: wavespeed, cns_flux!, bcstate!
# -------------------------------------------------------------------------
@inline function preflux(Q, VF, aux, _...)
  @inbounds begin
    ρ, U, V, W = Q[_ρ], Q[_U], Q[_V], Q[_W]
    ρinv = 1 / ρ
    u, v, w = ρinv * U, ρinv * V, ρinv * W
  end
end

#-------------------------------------------------------------------------
#md # Soundspeed computed using the thermodynamic state TS
# max eigenvalue
@inline function wavespeed(n, Q, aux, t, u, v, w)
  @inbounds begin
    abs(n[1] * u + n[2] * v + n[3] * w) + aux[_a_soundspeed_air]
  end
end


# -------------------------------------------------------------------------
# ### read sounding
#md # 
#md # The sounding file contains the following quantities along a 1D column.
#md # It needs to have the following structure:
#md #
#md # z[m]   theta[K]  q[g/kg]   u[m/s]   v[m/s]   p[Pa]
#md # ...      ...       ...      ...      ...      ...
#md #
#md #
# -------------------------------------------------------------------------
function read_sounding()
  #read in the original squal sounding
  fsounding  = open(joinpath(@__DIR__, "../soundings/SOUNDING_PYCLES_Z_T_P.dat"))
  sounding = readdlm(fsounding)
  close(fsounding)
  (nzmax, ncols) = size(sounding)
  if nzmax == 0
    error("SOUNDING ERROR: The Sounding file is empty!")
  end
  return (sounding, nzmax, ncols)
end

# -------------------------------------------------------------------------
# ### Physical Flux (Required)
#md # Here, we define the physical flux function, i.e. the conservative form
#md # of the equations of motion for the prognostic variables ρ, U, V, W, E, QT
#md # $\frac{\partial Q}{\partial t} + \nabla \cdot \boldsymbol{F} = \boldsymbol {S}$
#md # $\boldsymbol{F}$ contains both the viscous and inviscid flux components
#md # and $\boldsymbol{S}$ contains source terms.
#md # Note that the preflux calculation is splatted at the end of the function call
#md # to cns_flux!
# -------------------------------------------------------------------------
cns_flux!(F, Q, VF, aux, t) = cns_flux!(F, Q, VF, aux, t, preflux(Q,VF, aux)...)
@inline function cns_flux!(F, Q, VF, aux, t, u, v, w)
  @inbounds begin
    DFloat = eltype(F)
    D_subsidence = 3.75e-6
    ρ, U, V, W, E, QT = Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E], Q[_QT]
    P = aux[_a_P]
    xvert = aux[_a_y]
    v -= D_subsidence * xvert
    V = v*ρ
    # Inviscid contributions
    F[1, _ρ],  F[2, _ρ],  F[3, _ρ]  = U          , V          , W
    F[1, _U],  F[2, _U],  F[3, _U]  = u * U  + P , v * U      , w * U
    F[1, _V],  F[2, _V],  F[3, _V]  = u * V      , v * V + P  , w * V
    F[1, _W],  F[2, _W],  F[3, _W]  = u * W      , v * W      , w * W + P
    F[1, _E],  F[2, _E],  F[3, _E]  = u * (E + P), v * (E + P), w * (E + P)
    F[1, _QT], F[2, _QT], F[3, _QT] = u * QT     , v * QT     , w * QT

    #Derivative of T and Q:
    vqx, vqy, vqz = VF[_qx], VF[_qy], VF[_qz]
    vTx, vTy, vTz = VF[_Tx], VF[_Ty], VF[_Tz]

    # Radiation contribution
    F_rad = ρ * radiation(aux)

    SijSij = VF[_SijSij]

    #Dynamic eddy viscosity from Smagorinsky:
    ν_e = ρ*sqrt(2SijSij) * C_smag^2 * Δsqr
    D_e = ν_e / Prandtl_t

    # Multiply stress tensor by viscosity coefficient:
    τ11, τ22, τ33 = VF[_τ11] * ν_e, VF[_τ22]* ν_e, VF[_τ33] * ν_e
    τ12 = τ21 = VF[_τ12] * ν_e
    τ13 = τ31 = VF[_τ13] * ν_e
    τ23 = τ32 = VF[_τ23] * ν_e

    # Viscous velocity flux (i.e. F^visc_u in Giraldo Restelli 2008)
    F[1, _U] -= τ11; F[2, _U] -= τ12; F[3, _U] -= τ13
    F[1, _V] -= τ21; F[2, _V] -= τ22; F[3, _V] -= τ23
    F[1, _W] -= τ31; F[2, _W] -= τ32; F[3, _W] -= τ33

    # Viscous Energy flux (i.e. F^visc_e in Giraldo Restelli 2008)
    F[1, _E] -= u * τ11 + v * τ12 + w * τ13 + cp_over_prandtl * vTx * ν_e
    F[2, _E] -= u * τ21 + v * τ22 + w * τ23 + cp_over_prandtl * vTy * ν_e
    F[3, _E] -= u * τ31 + v * τ32 + w * τ33 + cp_over_prandtl * vTz * ν_e

    F[3, _E] += F_rad
    # Viscous contributions to mass flux terms
    F[1, _ρ]  -=  vqx * D_e
    F[2, _ρ]  -=  vqy * D_e
    F[3, _ρ]  -=  vqz * D_e
    F[1, _QT] -=  vqx * D_e
    F[2, _QT] -=  vqy * D_e
    F[3, _QT] -=  vqz * D_e
  end
end

# -------------------------------------------------------------------------
#md # Here we define a function to extract the velocity components from the 
#md # prognostic equations (i.e. the momentum and density variables). This 
#md # function is not required in general, but provides useful functionality 
#md # in some cases. 
# -------------------------------------------------------------------------
# Compute the velocity from the state
const _ngradstates = 6
gradient_vars!(gradient_list, Q, aux, t, _...) = gradient_vars!(gradient_list, Q, aux, t, preflux(Q,~,aux)...)
@inline function gradient_vars!(gradient_list, Q, aux, t, u, v, w)
  @inbounds begin
    T = aux[_a_T]
    θ = aux[_a_θ]
    ρ, QT =Q[_ρ], Q[_QT]
    # ordering should match states_for_gradient_transform
    gradient_list[1], gradient_list[2], gradient_list[3] = u, v, w
    gradient_list[4], gradient_list[5], gradient_list[6] = θ, QT, T
  end
end

# -------------------------------------------------------------------------
#md ### Viscous fluxes. 
#md # The viscous flux function compute_stresses computes the components of 
#md # the velocity gradient tensor, and the corresponding strain rates to
#md # populate the viscous flux array VF. SijSij is calculated in addition
#md # to facilitate implementation of the constant coefficient Smagorinsky model
#md # (pending)
@inline function compute_stresses!(VF, grad_mat, _...)
  @inbounds begin
    dudx, dudy, dudz = grad_mat[1, 1], grad_mat[2, 1], grad_mat[3, 1]
    dvdx, dvdy, dvdz = grad_mat[1, 2], grad_mat[2, 2], grad_mat[3, 2]
    dwdx, dwdy, dwdz = grad_mat[1, 3], grad_mat[2, 3], grad_mat[3, 3]
    # compute gradients of moist vars and temperature
    dθdx, dθdy, dθdz = grad_mat[1, 4], grad_mat[2, 4], grad_mat[3, 4]
    dqdx, dqdy, dqdz = grad_mat[1, 5], grad_mat[2, 5], grad_mat[3, 5]
    dTdx, dTdy, dTdz = grad_mat[1, 6], grad_mat[2, 6], grad_mat[3, 6]
    # virtual potential temperature gradient: for richardson calculation
    # strains
    # --------------------------------------------
    # SMAGORINSKY COEFFICIENT COMPONENTS
    # --------------------------------------------
    S11 = dudx
    S22 = dvdy
    S33 = dwdz
    S12 = (dudy + dvdx) / 2
    S13 = (dudz + dwdx) / 2
    S23 = (dvdz + dwdy) / 2
    # --------------------------------------------
    # SMAGORINSKY COEFFICIENT COMPONENTS
    # --------------------------------------------
    # FIXME: Grab functions from module SubgridScaleTurbulence 
    SijSij = S11^2 + S22^2 + S33^2 + 2S12^2 + 2S13^2 + 2S23^2

    #--------------------------------------------
    # deviatoric stresses
    # Fix up index magic numbers
    VF[_τ11] = 2 * (S11 - (S11 + S22 + S33) / 3)
    VF[_τ22] = 2 * (S22 - (S11 + S22 + S33) / 3)
    VF[_τ33] = 2 * (S33 - (S11 + S22 + S33) / 3)
    VF[_τ12] = 2 * S12
    VF[_τ13] = 2 * S13
    VF[_τ23] = 2 * S23

    # TODO: Viscous stresse come from SubgridScaleTurbulence module
    VF[_qx], VF[_qy], VF[_qz] = dqdx, dqdy, dqdz
    VF[_Tx], VF[_Ty], VF[_Tz] = dTdx, dTdy, dTdz
    VF[_θx], VF[_θy], VF[_θz] = dθdx, dθdy, dθdz
    VF[_SijSij] = SijSij
  end
end
# -------------------------------------------------------------------------
@inline function radiation(aux)
    @inbounds begin
        
    DFloat = eltype(aux)
    xvert = aux[_a_y]     
    zero_to_z = aux[_a_02z]
    z_to_inf = aux[_a_z2inf]
    z = xvert
    z_i = 840  # Start with constant inversion height of 840 meters then build in check based on q_tot
    Δz_i = max(z - z_i, zero(DFloat))
    # Constants
    F_0 = 70
    F_1 = 22
    α_z = 1
    ρ_i = DFloat(1.22)
    D_subsidence = DFloat(3.75e-6)
    term1 = F_0 * exp(-z_to_inf) 
    term2 = F_1 * exp(-zero_to_z)
    term3 = ρ_i * cp_d * D_subsidence * α_z * (DFloat(0.25) * (cbrt(Δz_i))^4 + z_i * cbrt(Δz_i))
    F_rad = term1 + term2 + term3  
  end
end

# -------------------------------------------------------------------------
#md ### Auxiliary Function (Not required)
#md # In this example the auxiliary function is used to store the spatial
#md # coordinates. This may also be used to store variables for which gradients
#md # are needed, but are not available through teh prognostic variable 
#md # calculations. (An example of this will follow - in the Smagorinsky model, 
#md # where a local Richardson number via potential temperature gradient is required)
# -------------------------------------------------------------------------
@inline function auxiliary_state_initialization!(aux, x, y, z)
  @inbounds begin
    DFloat = eltype(aux)
    xvert = y
    aux[_a_y] = xvert

    #Sponge 
    ctop    = zero(DFloat)

    cs_left_right = zero(DFloat)
    cs_front_back = zero(DFloat)
    ct            = DFloat(0.75)
  
    domain_bott  = 0
    domain_top   = ymax

    #END User modification on domain parameters.

   
      #Vertical sponge:
      sponge_type = 3
      if sponge_type == 1
          
          top_sponge  = DFloat(0.85) * domain_top          
          if xvert >= top_sponge
              ctop = ct * (sinpi((z - top_sponge)/2/(domain_top - top_sponge)))^4
          end
          
      elseif sponge_type == 2
          
          bc_zscale = 300.0
          zd        = domain_top - bc_zscale
          
          #
          # top damping
          # first layer: damp lee waves
          #
          ctop = 0.0
          ct   = 0.2
          if xvert >= zd
              zid = (xvert - zd)/(domain_top - zd) # normalized coordinate
              if zid >= 0.0 && zid <= 0.5
                  ctop = ct*(1.0 - cos(zid*pi))

              else
                  ctop = ct*( 1.0 + ((zid - 0.5)*pi) )
              end
          end

      elseif sponge_type == 3
          
          bc_zscale = 500.0
          zd        = domain_top - bc_zscale
          
          #
          # top damping
          # first layer: damp lee waves
          #
          ctop = 0.0
          ct   = 0.02
          if xvert >= zd
              ctop = ct * sinpi(0.5 * (1.0 - (domain_top - xvert) / bc_zscale))^2.0
          end
      end
      
      beta  = 1 - (1 - ctop) #*(1.0 - csleft)*(1.0 - csright)*(1.0 - csfront)*(1.0 - csback)
      beta  = min(beta, 1)
      aux[_a_sponge] = beta
  end
end

# -------------------------------------------------------------------------
# generic bc for 2d , 3d

@inline function bcstate!(QP, VFP, auxP, nM, QM, VFM, auxM, bctype, t, uM, vM, wM)
    @inbounds begin

        
        x, y, z = auxM[_a_x], auxM[_a_y], auxM[_a_z]
        xvert = y
        ρM, UM, VM, WM, EM, QTM = QM[_ρ], QM[_U], QM[_V], QM[_W], QM[_E], QM[_QT]
        # No flux boundary conditions
        # No shear on walls (free-slip condition)
        UnM = nM[1] * UM + nM[2] * VM + nM[3] * WM
        QP[_U] = UM - 2 * nM[1] * UnM
        QP[_V] = VM - 2 * nM[2] * UnM
        QP[_W] = WM - 2 * nM[3] * UnM
        QP[_ρ] = ρM
        QP[_QT] = QTM
        VFP .= VFM
        nothing
    end
end

# -------------------------------------------------------------------------
@inline function stresses_boundary_penalty!(VF, _...) 
  VF .= 0
end

@inline function stresses_penalty!(VF, nM, gradient_listM, QM, aM, gradient_listP, QP, aP, t)
  @inbounds begin
    n_Δgradient_list = similar(VF, Size(3, _ngradstates))
    for j = 1:_ngradstates, i = 1:3
      n_Δgradient_list[i, j] = nM[i] * (gradient_listP[j] - gradient_listM[j]) / 2
    end
    compute_stresses!(VF, n_Δgradient_list)
  end
end
# -------------------------------------------------------------------------

@inline function source!(S,Q,aux,t)
  # Initialise the final block source term 
  S .= 0

  # Typically these sources are imported from modules
  @inbounds begin
    source_geopot!(S, Q, aux, t)
    source_sponge!(S, Q, aux, t)
    #source_geostrophic!(S, Q, aux, t)
  end
end

"""
    Geostrophic wind forcing
"""
const f_coriolis = 7.62e-5
const u_geostrophic = 7.0
const v_geostrophic = -5.5 
const Ω = Omega
@inline function source_geostrophic!(S,Q,aux,t)
    @inbounds begin
        ρ = Q[_ρ]
        U = Q[_U]
        V = Q[_V]        
        W = Q[_W]
        
        S[_U] -= f_coriolis * (U - ρ*u_geostrophic)
        S[_V] -= f_coriolis * (V - ρ*v_geostrophic)
    end
end

@inline function source_sponge!(S,Q,aux,t)
  @inbounds begin
    U, V, W  = Q[_U], Q[_V], Q[_W]
    beta     = aux[_a_sponge]
    #S[_U] -= beta * U
    S[_V] -= beta * V
    S[_W] -= beta * W
  end
end

@inline function source_geopot!(S,Q,aux,t)
  @inbounds S[_V] += - Q[_ρ] * grav
end

# Test integral exactly according to the isentropic vortex example
@inline function integrand(val, Q, aux)
  κ = 85.0
  @inbounds begin
    @inbounds ρ, QT = Q[_ρ], Q[_QT]
    ρinv = 1 / ρ
    q_tot = QT * ρinv
    # Establish the current thermodynamic state using the prognostic variables
    q_liq = aux[_a_q_liq]
    val[1] = ρ * κ * (q_liq / (1.0 - q_tot)) 
    val[2] = ρ * (q_liq / (1.0 - q_tot)) # Liquid Water Path Integrand
  end
end

function preodefun!(disc, Q, t)
  DGBalanceLawDiscretizations.dof_iteration!(disc.auxstate, disc, Q) do R, Q, QV, aux
    @inbounds let
      ρ, U, V, W, E, QT = Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E], Q[_QT]
      xvert = aux[_a_y]
      e_int = (E - (U^2 + V^2+ W^2)/(2*ρ) - ρ * grav * xvert) / ρ
      q_tot = QT / ρ
        
      TS = PhaseEquil(e_int, q_tot, ρ)
      T = air_temperature(TS)
      P = air_pressure(TS) # Test with dry atmosphere
      q_liq = PhasePartition(TS).liq

      R[_a_T] = T
      R[_a_P] = P
      R[_a_q_liq] = q_liq
      R[_a_soundspeed_air] = soundspeed_air(TS)
      R[_a_θ] = virtual_pottemp(TS)
    end
  end

end

# initial condition
"""
    User-specified. Required.
    This function specifies the initial conditions
    for the dycoms driver.
"""
# NEW FUNCTION 
function moist_bubble!(dim, Q, t, x, y, z, _...)
      
    DFloat                = eltype(Q)
    
    q_tot::DFloat         = 0.0196
    q_liq::DFloat         = 0.0
    q_ice::DFloat         = 0.0
    
    # PhasePartition Object Creation ( No thermo equations here) 
    q_partition           = PhasePartition(q_tot, q_liq, q_ice)
    
    R_gas::DFloat         = gas_constant_air(q_partition)
    c_p::DFloat           = cp_m(q_partition)
    c_v::DFloat           = cv_m(q_partition)
    p0::DFloat            = MSLP
    gravity::DFloat       = grav
    # initialise with dry domain 

    xvert = y
    
    # perturbation parameters for rising bubble
    rx                    =  2000.0
    ry                    =  2000.0
    xc                    = 0.5*(xmin + xmax)
    yc                    =  2000.0
    r                     = sqrt( (x - xc)^2/rx^2 + (y - yc)^2/ry^2)
    θ_ref::DFloat         = 300.0
    θ_c::DFloat           =   2.0

    Δθ::DFloat            =   0.0

    if r <= 1
      Δθ = θ_c * cos(0.5 * π * r)*cos(0.5 * π * r)
    end

    θ                     = θ_ref + Δθ # potential temperature
    π_exner               = 1.0 - gravity / (c_p * θ) * xvert # exner pressure
    ρ                     = p0 / (R_gas * θ) * (π_exner)^ (c_v / R_gas) # density
    P                     = p0 * (R_gas * (ρ * θ) / p0) ^(c_p/c_v) # pressure (absolute)
    T                     = P / (ρ * R_gas) # temperature
    U, V, W               = 0.0 , 0.0 , 0.0  # momentum components
    u, v, w               = U/ρ, V/ρ, W/ρ

    # energy definitions
    e_kin                 = 0.5*(u^2 + v^2 + w^2)
    e_pot                 = gravity * xvert
    e_int                 = internal_energy(T, q_partition)
    
    E                     = ρ * (e_int + e_kin + e_pot)  #* total_energy(e_kin, e_pot, T, q_tot, q_liq, q_ice)
    @inbounds Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E], Q[_QT]= ρ, U, V, W, E, ρ * q_tot
    
end

function run(mpicomm, dim, Ne, N, timeend, DFloat, dt)

    brickrange = (range(DFloat(xmin), length=Ne[1]+1, DFloat(xmax)),
                  range(DFloat(ymin), length=Ne[2]+1, DFloat(ymax)))
    
  # User defined periodicity in the topl assignment
  # brickrange defines the domain extents
  @timeit to "Topo init" topl = StackedBrickTopology(mpicomm, brickrange, periodicity=(true,false))

  @timeit to "Grid init" grid = DiscontinuousSpectralElementGrid(topl,
                                                                 FloatType = DFloat,
                                                                 DeviceArray = ArrayType,
                                                                 polynomialorder = N)

  numflux!(x...) = NumericalFluxes.rusanov!(x..., cns_flux!, wavespeed, preflux)
  numbcflux!(x...) = NumericalFluxes.rusanov_boundary_flux!(x..., cns_flux!, bcstate!, wavespeed, preflux)

  # spacedisc = data needed for evaluating the right-hand side function
  @timeit to "Space Disc init" spacedisc = DGBalanceLaw(grid = grid,
                                                        length_state_vector = _nstate,
                                                        flux! = cns_flux!,
                                                        numerical_flux! = numflux!,
                                                        numerical_boundary_flux! = numbcflux!, 
                                                        number_gradient_states = _ngradstates,
                                                        states_for_gradient_transform =
                                                        _states_for_gradient_transform,
                                                        number_viscous_states = _nviscstates,
                                                        gradient_transform! = gradient_vars!,
                                                        viscous_transform! = compute_stresses!,
                                                        viscous_penalty! = stresses_penalty!,
                                                        viscous_boundary_penalty! = stresses_boundary_penalty!,
                                                        auxiliary_state_length = _nauxstate,
                                                        auxiliary_state_initialization! = (x...) ->
                                                        auxiliary_state_initialization!(x...),
                                                        source! = source!,
                                                        preodefun! = preodefun!)

  # This is a actual state/function that lives on the grid 
  initialcondition(Q, x...) = moist_bubble!(Val(dim), Q, DFloat(0), x...)
  Q = MPIStateArray(spacedisc, initialcondition)
    
  @timeit to "Time stepping init" begin
    lsrk = LSRK54CarpenterKennedy(spacedisc, Q; dt = dt, t0 = 0)
      
    #=eng0 = norm(Q)
    @info @sprintf """Starting
    norm(Q₀) = %.16e""" eng0
    =#
    # Set up the information callback
    starttime = Ref(now())
    cbinfo = GenericCallbacks.EveryXWallTimeSeconds(10, mpicomm) do (s=false)
      if s
        starttime[] = now()
      else
          ####          ql_max = global_max(aux, _a_q_liq)
          @info @sprintf("""Update
                           simtime = %.16e
                           runtime = %s""",
                         ODESolvers.gettime(lsrk),
                         Dates.format(convert(Dates.DateTime,
                                              Dates.now()-starttime[]),
                                      Dates.dateformat"HH:MM:SS"))#, globmean)
      end
    end
      
    npoststates = 7
    _o_u, _o_v, _o_w, _o_q_liq, _o_T, _o_P, _o_θ = 1:npoststates
    postnames = ("u", "v", "w", "_q_liq", "T", "P", "TH")
    postprocessarray = MPIStateArray(spacedisc; nstate=npoststates)
      
    step = [0]
    cbvtk = GenericCallbacks.EveryXSimulationSteps(20000) do (init=false)
      DGBalanceLawDiscretizations.dof_iteration!(postprocessarray, spacedisc, Q) do R, Q, QV, aux
        @inbounds let
          u, v, w = preflux(Q, QV, aux)
          R[_o_u] = u
          R[_o_v] = v
          R[_o_w] = w
          R[_o_q_liq] = aux[_a_q_liq]
          R[_o_T] = aux[_a_T]
          R[_o_P] = aux[_a_P]
          R[_o_θ] = aux[_a_θ]
        end
      end

      mkpath("/central/scratch/asridhar/moist-bubble")
      outprefix = @sprintf("/central/scratch/asridhar/moist-bubble/mtb_%dD_mpirank%04d_step%04d", dim,
                           MPI.Comm_rank(mpicomm), step[1])
      @debug "doing VTK output" outprefix
      writevtk(outprefix, Q, spacedisc, statenames,
               postprocessarray, postnames)
      
      step[1] += 1
      nothing
    end
  end

  @info @sprintf """Starting...
    norm(Q) = %25.16e""" norm(Q)

  # Initialise the integration computation. Kernels calculate this at every timestep?? 
  @timeit to "solve" solve!(Q, lsrk; timeend=timeend, callbacks=(cbinfo, cbvtk))
    
  @info @sprintf """Finished...
    norm(Q) = %25.16e""" norm(Q)

end

using Test
let
  MPI.Initialized() || MPI.Init()
  Sys.iswindows() || (isinteractive() && MPI.finalize_atexit())
  mpicomm = MPI.COMM_WORLD
  ll = uppercase(get(ENV, "JULIA_LOG_LEVEL", "INFO"))
  loglevel = ll == "DEBUG" ? Logging.Debug :
      ll == "WARN"  ? Logging.Warn  :
      ll == "ERROR" ? Logging.Error : Logging.Info
  logger_stream = MPI.Comm_rank(mpicomm) == 0 ? stderr : devnull
  global_logger(ConsoleLogger(logger_stream, loglevel))
  @static if haspkg("CUDAnative")
      device!(MPI.Comm_rank(mpicomm) % length(devices()))
  end
  # User defined number of elements
  # User defined timestep estimate
  # User defined simulation end time
  # User defined polynomial order 
  numelem = (Nex, Ney)
  dt = 0.01
  timeend = 2*dt  #1000
  polynomialorder = Npoly
  DFloat = Float64
  dim = numdims

  if MPI.Comm_rank(mpicomm) == 0
    @info @sprintf """ ------------------------------------------------------"""
    @info @sprintf """   ______ _      _____ __  ________                    """     
    @info @sprintf """  |  ____| |    |_   _|  ...  |  __  |                 """  
    @info @sprintf """  | |    | |      | | |   .   | |  | |                 """ 
    @info @sprintf """  | |    | |      | | | |   | | |__| |                 """
    @info @sprintf """  | |____| |____ _| |_| |   | | |  | |                 """
    @info @sprintf """  | _____|______|_____|_|   |_|_|  |_|                 """
    @info @sprintf """                                                       """
    @info @sprintf """ ------------------------------------------------------"""
    @info @sprintf """ Moist bublle                                          """
    @info @sprintf """   Resolution:                                         """ 
    @info @sprintf """     (Δx, Δy)   = (%.2e, %.2e)                         """ Δx Δy
    @info @sprintf """     (Nex, Ney) = (%d, %d)                             """ Nex Ney
    @info @sprintf """     DoF = %d                                          """ DoF
    @info @sprintf """     Minimum necessary memory to run this test: %g GBs """ (DoFstorage * sizeof(DFloat))/1000^3
    @info @sprintf """     Time step dt: %.2e                                """ dt
    @info @sprintf """     End time  t : %.2e                                """ timeend
    @info @sprintf """ ------------------------------------------------------"""
  end

  engf_eng0 = run(mpicomm, dim, numelem[1:dim], polynomialorder, timeend,
                  DFloat, dt)

  show(to)
end

isinteractive() || MPI.Finalize()

nothing