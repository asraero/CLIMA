using Test, Pkg

ENV["JULIA_LOG_LEVEL"] = "WARN"

for submodule in ["Utilities/VariableTemplates",
                  "Utilities/ParametersType",
                  "Utilities/RootSolvers",
                  "Common/PlanetParameters",
                  "Common/MoistThermodynamics",
                  "Atmos/Parameterizations/SurfaceFluxes",
                  "Atmos/Parameterizations/TurbulenceConvection",
                  "Atmos/Parameterizations/Microphysics",
                  "Mesh",
                  "DGmethods",
                  "ODESolvers",
                  "Arrays",
                  "LinearSolvers",
                 ]

  println("Starting tests for $submodule")
  t = @elapsed include(joinpath(submodule,"runtests.jl"))
  println("Completed tests for $submodule, $(round(Int, t)) seconds elapsed")
end
