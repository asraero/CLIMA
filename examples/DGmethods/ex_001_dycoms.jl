# Load modules used here
using MPI
using CLIMA
using CLIMA.Mesh.Topologies
using CLIMA.Mesh.Grids
using CLIMA.DGmethods
using CLIMA.DGmethods.NumericalFluxes
using CLIMA.MPIStateArrays
using CLIMA.LowStorageRungeKuttaMethod
using CLIMA.ODESolvers
using CLIMA.GenericCallbacks
using CLIMA.Atmos
using CLIMA.VariableTemplates
using CLIMA.MoistThermodynamics
using CLIMA.PlanetParameters
using LinearAlgebra
using StaticArrays
using Logging, Printf, Dates
using CLIMA.VTK
using CLIMA.Atmos: vars_state, vars_aux

@static if haspkg("CuArrays")
  using CUDAdrv
  using CUDAnative
  using CuArrays
  CuArrays.allowscalar(false)
  const ArrayTypes = (CuArray,) 
else
  const ArrayTypes = (Array,)
end

if !@isdefined integration_testing
  const integration_testing =
    parse(Bool, lowercase(get(ENV,"JULIA_CLIMA_INTEGRATION_TESTING","false")))
end

"""
  Initial Condition for DYCOMS_RF01 LES
"""
function Initialise_DYCOMS!(state::Vars, aux::Vars, (x,y,z), t)
  DT            = eltype(state)
  xvert::DT     = z
  #These constants are those used by Stevens et al. (2005)
  qref::DT      = 7.75e-3
  q_tot_sfc::DT = qref
  q_pt_sfc      = PhasePartition(q_tot_sfc)
  Rm_sfc        = gas_constant_air(q_pt_sfc)
  T_sfc::DT     = 292.5
  P_sfc::DT     = MSLP
  ρ_sfc::DT     = P_sfc / Rm_sfc / T_sfc
  # Specify moisture profiles 
  q_liq::DT      = 0
  q_ice::DT      = 0
  zb::DT         = 600    # initial cloud bottom
  zi::DT         = 840    # initial cloud top
  dz_cloud       = zi - zb
  q_liq_peak::DT = 0.00045 #cloud mixing ratio at z_i    
  if xvert > zb && xvert <= zi        
    q_liq = (xvert - zb)*q_liq_peak/dz_cloud
  end
  if xvert <= zi
    θ_liq = DT(289)
    q_tot = qref
  else
    θ_liq = DT(297.5) + (xvert - zi)^(DT(1/3))
    q_tot = DT(1.5e-3)
  end
  # Calculate PhasePartition object for vertical domain extent
  q_pt  = PhasePartition(q_tot, q_liq, q_ice) 
  #Pressure
  H     = Rm_sfc * T_sfc / grav;
  p     = P_sfc * exp(-xvert/H);
  #Density, Temperature
  TS    = LiquidIcePotTempSHumEquil_no_ρ(θ_liq, q_pt, p)
  ρ     = air_density(TS)
  T     = air_temperature(TS)
  #Assign State Variables
  u, v, w     = DT(7), DT(-5.5), DT(0)
  e_kin       = DT(1/2) * (u^2 + v^2 + w^2)
  e_pot       = grav * xvert
  E           = ρ * total_energy(e_kin, e_pot, T, q_pt)
  state.ρ     = ρ
  state.ρu    = SVector(ρ*u, ρ*v, ρ*w) 
  state.ρe    = E
  state.moisture.ρq_tot = ρ * q_tot
end

function run(mpicomm, ArrayType, dim, topl, N, timeend, DT, dt, C_smag, LHF, SHF, C_drag, zmax, zsponge)
  # Grid setup (topl contains brickrange information)
  grid = DiscontinuousSpectralElementGrid(topl,
                                          FloatType = DT,
                                          DeviceArray = ArrayType,
                                          polynomialorder = N,
                                         )
  # Problem constants
  # Radiation model
  κ             = DT(85)
  α_z           = DT(1) 
  z_i           = DT(840) 
  D_subsidence  = DT(3.75e-6)
  ρ_i           = DT(1.13)
  F_0           = DT(70)
  F_1           = DT(22)
  # Geostrophic forcing
  f_coriolis    = DT(7.62e-5)
  u_geostrophic = DT(7)
  v_geostrophic = DT(-5.5)
  
  # Model definition
  model = AtmosModel(FlatOrientation(),
                     NoReferenceState(),
                     SmagorinskyLilly{DT}(C_smag),
                     EquilMoist(),
                     StevensRadiation{DT}(κ, α_z, z_i, ρ_i, D_subsidence, F_0, F_1),
                     (Gravity(), 
                      RayleighSponge{DT}(zmax, zsponge, 1), 
                      Subsidence(), 
                      GeostrophicForcing{DT}(f_coriolis, u_geostrophic, v_geostrophic)), 
                     DYCOMS_BC{DT}(C_drag, LHF, SHF),
                     Initialise_DYCOMS!)
  # Balancelaw description
  dg = DGModel(model,
               grid,
               Rusanov(),
               CentralNumericalFluxDiffusive(),
               CentralGradPenalty())
  # Initialise ODE, param contains param.diff and param.aux (diffusive, auxiliary variables)
  param = init_ode_param(dg)
  # State variables, initialisation
  Q = init_ode_state(dg, param, DT(0))
  # Define timestepping method 
  lsrk = LSRK54CarpenterKennedy(dg, Q; dt = dt, t0 = 0)
  # Calculating initial condition norm 
  eng0 = norm(Q)
  @info @sprintf """Starting
  norm(Q₀) = %.16e""" eng0
  # Set up the information callback
  starttime = Ref(now())
  cbinfo = GenericCallbacks.EveryXWallTimeSeconds(600, mpicomm) do (s=false)
    if s
      starttime[] = now()
    else
      energy = norm(Q)
      @info @sprintf("""Update
                     simtime = %.16e
                     runtime = %s
                     norm(Q) = %.16e""", ODESolvers.gettime(lsrk),
                     Dates.format(convert(Dates.DateTime,
                                          Dates.now()-starttime[]),
                                  Dates.dateformat"HH:MM:SS"),
                     energy)
    end
  end
  
  # Setup VTK output callbacks
  step = [0]
    cbvtk = GenericCallbacks.EveryXSimulationSteps(10000) do (init=false)
    VTKPATH = "dyc-1gpu"
    mkpath(VTKPATH)
    outprefix = @sprintf("./%s/dycoms_%dD_mpirank%04d_step%04d", VTKPATH, dim,
                           MPI.Comm_rank(mpicomm), step[1])
    @debug "doing VTK output" outprefix
    writevtk(outprefix, Q, dg, flattenednames(vars_state(model,DT)), 
             param[1], flattenednames(vars_aux(model,DT)))
    step[1] += 1
    nothing
  end

  # Solver function
  solve!(Q, lsrk, param; timeend=timeend, callbacks=(cbinfo, cbvtk))
  # Print some end of the simulation information
  engf = norm(Q)
  Qe = init_ode_state(dg, param, DT(timeend))
  engfe = norm(Qe)
  errf = euclidean_distance(Q, Qe)
  @info @sprintf """Finished
  norm(Q)                 = %.16e
  norm(Q) / norm(Q₀)      = %.16e
  norm(Q) - norm(Q₀)      = %.16e
  norm(Q - Qe)            = %.16e
  norm(Q - Qe) / norm(Qe) = %.16e
  """ engf engf/eng0 engf-eng0 errf errf / engfe
  engf/eng0
end

using Test
let
  MPI.Initialized() || MPI.Init()
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
  @testset "$(@__FILE__)" for ArrayType in ArrayTypes
    # Problem type
    DT = Float32
    # DG polynomial order 
    polynomialorder = 4
    # User specified grid spacing
    Δx    = DT(10)
    Δy    = DT(10)
    Δz    = DT(10)
    # SGS Filter constants
    C_smag = DT(0.15)
    LHF    = DT(115)
    SHF    = DT(15)
    C_drag = DT(0.0011)
    # Physical domain extents 
    (xmin, xmax) = (0, 1000)
    (ymin, ymax) = (0, 1000)
    (zmin, zmax) = (0, 1500)
    zsponge = DT(0.75 * zmax)
    #Get Nex, Ney from resolution
    Lx = xmax - xmin
    Ly = ymax - ymin
    Lz = zmax - ymin
    # User defines the grid size:
    Nex = ceil(Int64, (Lx/Δx - 1)/polynomialorder)
    Ney = ceil(Int64, (Ly/Δy - 1)/polynomialorder)
    Nez = ceil(Int64, (Lz/Δz - 1)/polynomialorder)
    Ne = (Nex, Ney, Nez)
    # User defined domain parameters
    brickrange = (range(DT(xmin), length=Ne[1]+1, DT(xmax)),
                  range(DT(ymin), length=Ne[2]+1, DT(ymax)),
                  range(DT(zmin), length=Ne[3]+1, DT(zmax)))
    topl = StackedBrickTopology(mpicomm, brickrange,periodicity = (true, true, false), boundary=((0,0),(0,0),(1,2)))
    dt = 0.001
    timeend = DT(14400)
    dim = 3
    @info (ArrayType, DT, dim)
    @info ((Nex,Ney,Nez), (Δx, Δy, Δz), (xmax,ymax,zmax), dt, timeend)
    result = run(mpicomm, ArrayType, dim, topl, 
                 polynomialorder, timeend, DT, dt, C_smag, LHF, SHF, C_drag, zmax, zsponge)
    @test result ≈ DT(0.9999735345500744)
  end
end

#nothing
