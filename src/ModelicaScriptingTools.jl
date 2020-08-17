module ModelicaScriptingTools

using Base.Filesystem: isfile
using Test: @test
using CSV: CSV
using OMJulia: OMCSession, sendExpression, Parser
using ZMQ: send, recv # only needed for sendExpressionRaw which is a workaround for OMJulia bugs
using DataFrames: DataFrame
using PyCall: PyNULL, pyimport_conda, pyimport, @py_str
import Documenter

export moescape, mounescape, MoSTError, loadModel, getSimulationSettings,
    getVariableFilter, simulate, regressionTest, testmodel,
    setupOMCSession, closeOMCSession, withOMC, ModelicaBlocks, getDocAnnotation,
    getequations, getcode

include("Simulation.jl")
include("Testing.jl")
include("Documentation.jl")

function __init__()
    __init__doc()
end

end
