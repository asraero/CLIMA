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
using LinearAlgebra
using StaticArrays
using Logging, Printf, Dates
using CLIMA.Vtk

using CLIMA.SubgridScaleTurbulence
using CLIMA.MoistThermodynamics
using CLIMA.PlanetParameters: R_d, cp_d, grav, cv_d, MSLP, T_0

if haspkg("CuArrays")
    using CUDAdrv
    using CUDAnative
    using CuArrays
    CuArrays.allowscalar(false)
    const ArrayType = CuArray
else
    const ArrayType = Array
end

"""
State labels
"""
const _nstate = 6
const _ρ, _U, _V, _W, _E, _QT = 1:_nstate
const stateid = (ρid = _ρ, Uid = _U, Vid = _V, Wid = _W, Eid = _E, QTid = _QT)
const statenames = ("RHO", "U", "V", "W", "E", "QT")


"""
Viscous state labels
"""
const _nviscstates = 16
const _τ11, _τ22, _τ33, _τ12, _τ13, _τ23, _qx, _qy, _qz, _Tx, _Ty, _Tz, _ρx, _ρy, _ρz, _SijSij = 1:_nviscstates

"""
Number of variables of which gradients are required 
"""
const _ngradstates = 7

"""
Number of states being loaded for gradient computation
"""
const _states_for_gradient_transform = (_ρ, _U, _V, _W, _E, _QT)


if !@isdefined integration_testing
    const integration_testing =
        parse(Bool, lowercase(get(ENV,"JULIA_CLIMA_INTEGRATION_TESTING","false")))
    using Random
end

"""
Problem constants 
"""
const Prandtl   = 71 // 100
const k_μ       = cp_d / Prandtl
const (xmin, xmax) = (0, 25600)
const (ymin, ymax) = (0,  6000)
const  Δx    = 125 
const  Δy    = 125
const  Δz    = 200

"""
Problem Description
-------------------
2 Dimensional falling thermal bubble (cold perturbation in a warm neutral atmosphere)
"""

# Equivalent grid-scale
# -------------------------------------------------------------------------
#md ### Auxiliary Function (Not required)
#md # In this example the auxiliary function is used to store the spatial
#md # coordinates and the equivalent grid lengthscale coefficient. 
# -------------------------------------------------------------------------
const _nauxstate = 6
const _a_x, _a_y, _a_z, _a_dx, _a_dy, _a_Δsqr = 1:_nauxstate
@inline function auxiliary_state_initialization!(aux, x, y, z, dx, dy, dz)
    @inbounds begin
        aux[_a_x] = x
        aux[_a_y] = y
        aux[_a_z] = z
        aux[_a_dx] = dx
        aux[_a_dy] = dy
        aux[_a_Δsqr] = SubgridScaleTurbulence.anisotropic_lengthscale_2D(aux[_a_dx],aux[_a_dy]) 
    end
end

# -------------------------------------------------------------------------
# Preflux calculation: Obsolete in future builds
# The preflux function interacts with the following  
# Modules: NumericalFluxes.jl 
# functions: wavespeed, cns_flux!, bcstate!
# -------------------------------------------------------------------------
@inline function preflux(Q,VF, aux, _...)
    gravity::eltype(Q) = grav
    @inbounds ρ, U, V, W, E, QT = Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E], Q[_QT]
    ρinv = 1 / ρ
    x,y,z = aux[_a_x], aux[_a_y], aux[_a_z]
    u, v, w = ρinv * U, ρinv * V, ρinv * W
    e_int = (E - (U^2 + V^2+ W^2)/(2*ρ) - ρ * gravity * y) / ρ
    q_tot = QT / ρ
    # Establish the current thermodynamic state using the prognostic variables
    TS = PhaseEquil(e_int, q_tot, ρ)
    T = air_temperature(TS)
    P = air_pressure(TS) # Test with dry atmosphere
    q_liq = PhasePartition(TS).liq
    θ = virtual_pottemp(TS)
    (P, u, v, w, ρinv, q_liq,T,θ)
end

#-------------------------------------------------------------------------
#md # Soundspeed computed using the thermodynamic state TS
# max eigenvalue
@inline function wavespeed(n, Q, aux, t, P, u, v, w, ρinv, q_liq, T, θ)
  gravity::eltype(Q) = grav
  @inbounds begin 
    ρ, U, V, W, E, QT = Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E], Q[_QT]
    x,y,z = aux[_a_x], aux[_a_y], aux[_a_z]
    u, v, w = ρinv * U, ρinv * V, ρinv * W
    e_int = (E - (U^2 + V^2+ W^2)/(2*ρ) - ρ * gravity * y) / ρ
    q_tot = QT / ρ
    TS = PhaseEquil(e_int, q_tot, ρ)
    abs(n[1] * u + n[2] * v + n[3] * w) + soundspeed_air(TS)
  end
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
@inline function cns_flux!(F, Q, VF, aux, t, P, u, v, w, ρinv, q_liq, T, θ)
  gravity::eltype(Q) = grav
  @inbounds begin
    ρ, U, V, W, E, QT = Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E], Q[_QT]
    # Inviscid contributions
    F[1, _ρ], F[2, _ρ], F[3, _ρ] = U          , V          , W
    F[1, _U], F[2, _U], F[3, _U] = u * U  + P , v * U      , w * U
    F[1, _V], F[2, _V], F[3, _V] = u * V      , v * V + P  , w * V
    F[1, _W], F[2, _W], F[3, _W] = u * W      , v * W      , w * W + P
    F[1, _E], F[2, _E], F[3, _E] = u * (E + P), v * (E + P), w * (E + P)
    F[1, _QT], F[2, _QT], F[3, _QT] = u * QT  , v * QT     , w * QT 

    #Derivative of T and Q:
    vqx, vqy, vqz = VF[_qx], VF[_qy], VF[_qz]        
    vTx, vTy, vTz = VF[_Tx], VF[_Ty], VF[_Tz]
    vρy = VF[_ρy]
    SijSij = VF[_SijSij]
    
    #Dynamic eddy viscosity from Smagorinsky:
    dx, dy= aux[_a_dx], aux[_a_dy]
    Δsqr = aux[_a_Δsqr]
    (ν_e, D_e) = SubgridScaleTurbulence.standard_smagorinsky(SijSij, Δsqr)
    
    #Richardson contribution:
    f_R = SubgridScaleTurbulence.buoyancy_correction(SijSij, ρ, vρy)
    
    # Multiply stress tensor by viscosity coefficient:
    τ11, τ22, τ33 = VF[_τ11] * ν_e, VF[_τ22]* ν_e, VF[_τ33] * ν_e
    τ12 = τ21 = VF[_τ12] * ν_e 
    τ13 = τ31 = VF[_τ13] * ν_e               
    τ23 = τ32 = VF[_τ23] * ν_e
    
    # Viscous velocity flux (i.e. F^visc_u in Giraldo Restelli 2008)
    F[1, _U] -= τ11 * f_R ; F[2, _U] -= τ12 * f_R ; F[3, _U] -= τ13 * f_R
    F[1, _V] -= τ21 * f_R ; F[2, _V] -= τ22 * f_R ; F[3, _V] -= τ23 * f_R
    F[1, _W] -= τ31 * f_R ; F[2, _W] -= τ32 * f_R ; F[3, _W] -= τ33 * f_R

    # Viscous Energy flux (i.e. F^visc_e in Giraldo Restelli 2008)
    F[1, _E] -= u * τ11 + v * τ12 + w * τ13 + ν_e * k_μ * vTx 
    F[2, _E] -= u * τ21 + v * τ22 + w * τ23 + ν_e * k_μ * vTy
    F[3, _E] -= u * τ31 + v * τ32 + w * τ33 + ν_e * k_μ * vTz 
  end
end

# -------------------------------------------------------------------------
#md # Here we define a function to extract the velocity components from the 
#md # prognostic equations (i.e. the momentum and density variables). Required
#md # for viscous flows. 
# -------------------------------------------------------------------------
# Compute the velocity from the state
gradient_vars!(gradient_list, Q, aux, t, _...) = gradient_vars!(gradient_list, Q, aux, t, preflux(Q,~,aux)...)
@inline function gradient_vars!(gradient_list, Q, aux, t, P, u, v, w, ρinv, q_liq, T, θ)
    @inbounds begin
        # ordering should match states_for_gradient_transform
        ρ, U, V, W, E, QT = Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E], Q[_QT]
        gradient_list[1], gradient_list[2], gradient_list[3] = u, v, w
        gradient_list[4], gradient_list[5], gradient_list[6] = E, QT, T
        gradient_list[7] = ρ
    end
end

# -------------------------------------------------------------------------
#md ### Viscous fluxes. 
#md # The viscous flux function compute_stresses computes the components of 
#md # the velocity gradient tensor, and the corresponding strain rates to
#md # populate the viscous flux array VF. SijSij is calculated in addition
#md # to facilitate implementation of the constant coefficient Smagorinsky model
# -------------------------------------------------------------------------
@inline function compute_stresses!(VF, grad_vars, _...)
    gravity::eltype(VF) = grav
    @inbounds begin
        dudx, dudy, dudz = grad_vars[1, 1], grad_vars[2, 1], grad_vars[3, 1]
        dvdx, dvdy, dvdz = grad_vars[1, 2], grad_vars[2, 2], grad_vars[3, 2]
        dwdx, dwdy, dwdz = grad_vars[1, 3], grad_vars[2, 3], grad_vars[3, 3]
        # compute gradients of moist vars and temperature
        dqdx, dqdy, dqdz = grad_vars[1, 5], grad_vars[2, 5], grad_vars[3, 5]
        dTdx, dTdy, dTdz = grad_vars[1, 6], grad_vars[2, 6], grad_vars[3, 6]
        dρdx, dρdy, dρdz = grad_vars[1, 7], grad_vars[2, 7], grad_vars[3, 7]
        # virtual potential temperature gradient: for richardson calculation
        # strains
        # --------------------------------------------
        (S11,S22,S33,S12,S13,S23,SijSij) = SubgridScaleTurbulence.strainrate_tensor_components(dudx, dudy, dudz,
                                                                                                dvdx, dvdy, dvdz,
                                                                                                dwdx, dwdy, dwdz)
        #--------------------------------------------
        # deviatoric stresses
        VF[_τ11] = 2 * (S11 - (S11 + S22 + S33) / 3)
        VF[_τ22] = 2 * (S22 - (S11 + S22 + S33) / 3)
        VF[_τ33] = 2 * (S33 - (S11 + S22 + S33) / 3)
        VF[_τ12] = 2 * S12
        VF[_τ13] = 2 * S13
        VF[_τ23] = 2 * S23
        
        VF[_Tx], VF[_Ty], VF[_Tz] = dTdx, dTdy, dTdz
        VF[_ρx], VF[_ρy], VF[_ρz] = dρdx, dρdy, dρdz
        VF[_SijSij] = SijSij
    end
end

# -------------------------------------------------------------------------
# generic bc for 2d , 3d
@inline function bcstate!(QP, VFP, auxP, nM, QM, VFM, auxM, bctype, t, PM, uM, vM, wM, ρinvM, q_liqM, TM, θM)
    @inbounds begin
        x, y, z = auxM[_a_x], auxM[_a_y], auxM[_a_z]
        ρM, UM, VM, WM, EM, QTM = QM[_ρ], QM[_U], QM[_V], QM[_W], QM[_E], QM[_QT]
        # No flux boundary conditions
        # No shear on walls (free-slip condition)
        UnM = nM[1] * UM + nM[2] * VM + nM[3] * WM
        QP[_U] = UM - 2 * nM[1] * UnM
        QP[_V] = VM - 2 * nM[2] * UnM
        QP[_W] = WM - 2 * nM[3] * UnM
        QP[_ρ] = ρM
        QP[_QT] = QTM
        nothing
    end
end

"""
Boundary correction for Neumann boundaries
"""
@inline function stresses_boundary_penalty!(VF,nM, gradient_listM, QM, aM, gradient_listP, QP, aP, bctype, t)
  QP .= 0 
  stresses_penalty!(VF, nM, gradient_listM, QM, aM, gradient_listP, QP, aP, t)
end

"""
Gradient term flux correction 
"""
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
    end
end

@inline function source_geopot!(S,Q,aux,t)
    gravity::eltype(Q) = grav
    @inbounds begin
        ρ, U, V, W, E  = Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E]
        S[_V] += - ρ * gravity
    end
end


# ------------------------------------------------------------------
# -------------END DEF SOURCES-------------------------------------# 

# initial condition
function density_current!(dim, Q, t, x, y, z, _...)
    DFloat                = eltype(Q)
    R_gas::DFloat         = R_d
    c_p::DFloat           = cp_d
    c_v::DFloat           = cv_d
    p0::DFloat            = MSLP
    gravity::DFloat       = grav
    # initialise with dry domain 
    q_tot::DFloat         = 0
    q_liq::DFloat         = 0
    q_ice::DFloat         = 0 
    # perturbation parameters for rising bubble
    rx                    = 4000
    ry                    = 2000
    xc                    = 0
    yc                    = 3000
    r                     = sqrt( (x - xc)^2/rx^2 + (y - yc)^2/ry^2)
    θ_ref::DFloat         = 300
    θ_c::DFloat           = -15.0
    Δθ::DFloat            = 0.0
    if r <= 1
        Δθ = θ_c * (1 + cospi(r))/2
    end
    qvar                  = PhasePartition(q_tot)
    θ                     = θ_ref + Δθ # potential temperature
    π_exner               = 1.0 - gravity / (c_p * θ) * y # exner pressure
    ρ                     = p0 / (R_gas * θ) * (π_exner)^ (c_v / R_gas) # density

    P                     = p0 * (R_gas * (ρ * θ) / p0) ^(c_p/c_v) # pressure (absolute)
    T                     = P / (ρ * R_gas) # temperature
    U, V, W               = 0.0 , 0.0 , 0.0  # momentum components
    # energy definitions
    e_kin                 = (U^2 + V^2 + W^2) / (2*ρ)/ ρ
    e_pot                 = gravity * y
    e_int                 = internal_energy(T, qvar)
    E                     = ρ * (e_int + e_kin + e_pot)  #* total_energy(e_kin, e_pot, T, q_tot, q_liq, q_ice)
    @inbounds Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E], Q[_QT]= ρ, U, V, W, E, ρ * q_tot
end


function run(mpicomm, dim, Ne, N, timeend, DFloat, dt)

    brickrange = (range(DFloat(xmin), length=Ne[1]+1, DFloat(xmax)),
                  range(DFloat(ymin), length=Ne[2]+1, DFloat(ymax)))
    
    # User defined periodicity in the topl assignment
    # brickrange defines the domain extents
    topl = StackedBrickTopology(mpicomm, brickrange, periodicity=(false,false))

    grid = DiscontinuousSpectralElementGrid(topl,
                                            FloatType = DFloat,
                                            DeviceArray = ArrayType,
                                            polynomialorder = N)
    
    numflux!(x...) = NumericalFluxes.rusanov!(x..., cns_flux!, wavespeed, preflux)
    numbcflux!(x...) = NumericalFluxes.rusanov_boundary_flux!(x..., cns_flux!, bcstate!, wavespeed, preflux)

    # spacedisc = data needed for evaluating the right-hand side function
    spacedisc = DGBalanceLaw(grid = grid,
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
                             auxiliary_state_initialization! =
                             auxiliary_state_initialization!,
                             source! = source!)

    # This is a actual state/function that lives on the grid
    initialcondition(Q, x...) = density_current!(Val(dim), Q, DFloat(0), x...)
    Q = MPIStateArray(spacedisc, initialcondition)

    lsrk = LSRK54CarpenterKennedy(spacedisc, Q; dt = dt, t0 = 0)

    eng0 = norm(Q)
    @info @sprintf """Starting
      norm(Q₀) = %.16e""" eng0

    # Set up the information callback
    starttime = Ref(now())
    cbinfo = GenericCallbacks.EveryXWallTimeSeconds(10, mpicomm) do (s=false)
        if s
            starttime[] = now()
        else
            energy = norm(Q)
            @info @sprintf("""Update
                         simtime = %.16e
                         runtime = %s
                         norm(Q) = %.16e""", 
                           ODESolvers.gettime(lsrk),
                           Dates.format(convert(Dates.DateTime,
                                                Dates.now()-starttime[]),
                                        Dates.dateformat"HH:MM:SS"),
                           energy )
        end
    end

    npoststates = 8
    _P, _u, _v, _w, _ρinv, _q_liq, _T, _θ = 1:npoststates
    postnames = ("P", "u", "v", "w", "rhoinv", "_q_liq", "T", "THETA")
    postprocessarray = MPIStateArray(spacedisc; nstate=npoststates)

    step = [0]
    mkpath("vtk-DC")
    cbvtk = GenericCallbacks.EveryXSimulationSteps(2500) do (init=false)
        DGBalanceLawDiscretizations.dof_iteration!(postprocessarray, spacedisc,
                                                   Q) do R, Q, QV, aux
                                                       @inbounds let
                                                           (R[_P], R[_u], R[_v], R[_w], R[_ρinv], R[_q_liq], R[_T], R[_θ]) = (preflux(Q, QV, aux))
                                                       end
                                                   end

        outprefix = @sprintf("vtk-DC/cns_%dD_mpirank%04d_step%04d", dim,
                             MPI.Comm_rank(mpicomm), step[1])
        @debug "doing VTK output" outprefix
        writevtk(outprefix, Q, spacedisc, statenames,
                 postprocessarray, postnames)
        #= 
        pvtuprefix = @sprintf("vtk/cns_%dD_step%04d", dim, step[1])
        prefixes = ntuple(i->
        @sprintf("vtk/cns_%dD_mpirank%04d_step%04d",
        dim, i-1, step[1]),
        MPI.Comm_size(mpicomm))
        writepvtu(pvtuprefix, prefixes, postnames)
        =# 
        step[1] += 1
        nothing
    end
    
    solve!(Q, lsrk; timeend=timeend, callbacks=(cbinfo, cbvtk))


    # Print some end of the simulation information
    engf = norm(Q)
    if integration_testing
        Qe = MPIStateArray(spacedisc,
                           (Q, x...) -> initialcondition!(Val(dim), Q,
                                                          DFloat(timeend), x...))
        engfe = norm(Qe)
        errf = euclidean_distance(Q, Qe)
        @info @sprintf """Finished
        norm(Q)                 = %.16e
        norm(Q) / norm(Q₀)      = %.16e
        norm(Q) - norm(Q₀)      = %.16e
        norm(Q - Qe)            = %.16e
        norm(Q - Qe) / norm(Qe) = %.16e
        """ engf engf/eng0 engf-eng0 errf errf / engfe
    else
        @info @sprintf """Finished
        norm(Q)            = %.16e
        norm(Q) / norm(Q₀) = %.16e
        norm(Q) - norm(Q₀) = %.16e""" engf engf/eng0 engf-eng0
    end
integration_testing ? errf : (engf / eng0)
end

using Test
let
    MPI.Initialized() || MPI.Init()
    Sys.iswindows() || (isinteractive() && MPI.finalize_atexit())
    mpicomm = MPI.COMM_WORLD
    if MPI.Comm_rank(mpicomm) == 0
      ll=uppercase(get(ENV, "JULIA_LOG_LEVEL", "INFO"))
      loglevel = ll == "DEBUG" ? Logging.Debug :
      ll == "WARN"  ? Logging.Warn  :
      ll == "ERROR" ? Logging.Error : Logging.Info
      logger_stream = MPI.Comm_rank(mpicomm) == 0 ? stderr : devnull
      global_logger(ConsoleLogger(logger_stream, loglevel))
      @static if haspkg("CUDAnative")
        device!(MPI.Comm_rank(mpicomm) % length(devices()))
      end
    end
    
    @testset for numdims = 2:2
      # Resolution for test-set set to 150m
      Npoly = 4
      # Physical domain extents 
      # This is a 2D benchmark 

      #Get Nex, Ney from resolution
      Lx = xmax - xmin
      Ly = ymax - ymin

      ratiox = (Lx/Δx - 1)/Npoly
      ratioy = (Ly/Δy - 1)/Npoly
      Nex = ceil(Int64, ratiox)
      Ney = ceil(Int64, ratioy)

      numelem = (Nex,Ney)
      dt = 0.01
      timeend = 900
      polynomialorder = Npoly
      DFloat = Float64
      dim = numdims

      @info @sprintf """ ----------------------------------------------------"""
      @info @sprintf """   ______ _      _____ __  ________                  """     
      @info @sprintf """  |  ____| |    |_   _|  ...  |  __  |               """  
      @info @sprintf """  | |    | |      | | | |   | | |__| |               """
      @info @sprintf """  | |____| |____ _| |_| |   | | |  | |               """
      @info @sprintf """  | _____|______|_____|_|   |_|_|  |_|               """
      @info @sprintf """                                                     """
      @info @sprintf """ ----------------------------------------------------"""
      @info @sprintf """ Rising Bubble                                       """
      @info @sprintf """   Resolution:                                       """ 
      @info @sprintf """     (Δx, Δy)   = (%.2e, %.2e)                       """ Δx Δy
      @info @sprintf """     (Nex, Ney) = (%d, %d)                           """ Nex Ney
      @info @sprintf """ ----------------------------------------------------"""

      engf_eng0 = run(mpicomm, dim, numelem[1:dim], polynomialorder, timeend,
                      DFloat, dt)
      @test engf_eng0 ≈ DFloat(1.0003722665470953e+00)
    end
end

isinteractive() || MPI.Finalize()

nothing