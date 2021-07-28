

"""
Real-Time Simulation Scheduler Framework

Top level script that assembles all of the various underlying scripts
together into a single module.
"""
module RSIS

using Unitful
using Unitful.DefaultSymbols

include("Logging.jl")
using .MLogging
export setlogfile, logmsg

include("RSIS_Lib.jl")
using .MLibrary
export getscheduler
export newmodel!, deletemodel!, listmodels, listmodelsbytag

include("Scripting.jl")
using .MScripting
export addfilepath, removefilepath, printfilepaths, where, search
export script, logscripts, printscriptlog

include("SignalLogger.jl")

include("Model.jl")
using .MModel
export generateinterface
export load, unload

include("Scheduling.jl")
using .MScheduling

include("Configuration.jl")
using .MConfiguration

include("Project.jl")
using .MProject
export newproject, loadproject

# final global variables

# ===

function __init__()
    LoadLibrary()
    nothing
end


"""
Launch RSIS GUI Window
"""
function gui()
    println("Not implemented")
end

"""
RSIS

Perform initialization actions.
"""
function initsim()
    println("Not implemented")
end

function pausesim()
    println("Not implemented")
end

"""
RSIS

Run simulation.
"""
function runsim()
    println("Not implemented")
end

end # module
