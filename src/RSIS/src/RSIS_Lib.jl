
module MLibrary
using Base: Int32
using ..MLogging

export LoadLibrary, UnloadLibrary, InitLibrary, ShutdownLibrary
export newmodel!, deletemodel!, listmodels, listmodelsbytag
export getscheduler
export LoadModelLib, UnloadModelLib

using Libdl

# globals
_lib = nothing # library pointer
_sym = nothing # symbol loading
_models = Dict{String, Any}()

@enum RSISCmdStat::Int32 begin
    OK  = 0
    ERR = 1
end

mutable struct LibFuncs
    s_init
    s_shutdown
    s_setthread
    s_initscheduler
    s_pausescheduler
    s_runscheduler
    s_getmessage
    s_getschedulername
    function LibFuncs(lib)
        new(Libdl.dlsym(lib, :RSISFramework_Initialize),
            Libdl.dlsym(lib, :RSISFramework_Shutdown),
            Libdl.dlsym(lib, :RSISFramework_SetThread),
            Libdl.dlsym(lib, :RSISFramework_InitScheduler),
            Libdl.dlsym(lib, :RSISFramework_PauseScheduler),
            Libdl.dlsym(lib, :RSISFramework_RunScheduler),
            Libdl.dlsym(lib, :RSISFramework_GetMessage),
            Libdl.dlsym(lib, :RSISFramework_GetSchedulerName))
    end
end

mutable struct LibModel
    s_lib
    s_createmodel
    function LibModel(libfile::String)
        lib = Libdl.dlopen(libfile)
        new(lib,
            Libdl.dlsym(lib, :CreateModel))
    end
end

mutable struct ModelInstance
    modulename::String
    name::String
    tags::Vector{String}
end

# globals
_loaded_models = Dict{String, ModelInstance}()
_model_tags    = Set{String}()

"""
    LoadLibrary()
Load the RSIS shared library
"""
function LoadLibrary()
    global _lib
    global _sym

    # detect operating system
    libpath = joinpath(@__DIR__, "..", "install", "lib");
    libfile = ""
    if Sys.isunix()
        if Sys.islinux()
            libfile = "librsis.so"
        elseif Sys.isapple()
            libfile = "librsis.dylib"
        end
    elseif Sys.iswindows()
        libfile = "librsis.dll"
    else
        throw(InitError(:RSIS, "could not identify operating system"))
    end

    libpath = joinpath(libpath, libfile)
    _lib = Libdl.dlopen(libpath)
    _sym = LibFuncs(_lib)
    InitLibrary(_sym)
    return
end

"""
    UnloadLibrary()
Unload the RSIS shared library
"""
function UnloadLibrary()
    global _lib
    if _lib !== nothing
        Libdl.dlclose(_lib)
        _lib = nothing
        _sym = nothing
    end
    return
end

"""
    LoadModelLib(name::String, filename::String)
Attempts to load a shared model library by filename, storing it with a name
if it does so. Returns whether the library was loaded for the first time.
This function can throw.
"""
function LoadModelLib(name::String, filename::String) :: Bool
    if !(name in keys(_models))
        _models[name] = LibModel(filename)
        return true
    end
    return false
end

"""
    UnloadModelLib(name::String)
Attempts to unload a shared model library by name.
Returns whether the model was unloaded.
This function can throw.
"""
function UnloadModelLib(name::String) :: Bool
    if name in keys(_models)
        Libdl.dlclose(_models[name].s_lib)
        delete!(_models, name)
        return true
    end
    return false
end

function InitLibrary(symbols::LibFuncs)
    #
    stat = ccall(symbols.s_init, UInt8, ())
    if stat ≠ 1
        error("Failed to initialize library");
    end
end

function ShutdownLibrary(symbols::LibFuncs)
    #
    stat = ccall(symbols.s_shutdown, UInt8, ())
    if stat ≠ 1
        error("Failed to shutdown library");
    end
end

function getscheduler()
    global _sym
    stat = ccall(_sym.s_getschedulername, RSISCmdStat, ())
    if stat ≠ OK
        error("Failed to grab scheduler name")
    end
    msgptr = ccall(_sym.s_getmessage, Cstring, ())
    println(unsafe_string(msgptr))
end

"""
    newmodel(library::String, newname::String, tags::Vector{String} = [])
Create a new model. A unique name must be given for the model. An optional list
of tags can be given, allowing the user to search loaded models by tag.
"""
function newmodel!(library::String, newname::String, tags::Vector{String}=Vector{String}())::Nothing
    if newname in keys(_loaded_models)
        logmsg("Model with name: $newname already exists.", ERROR)
    else
        newmodel = ModelInstance(library, newname, tags)
        _loaded_models[newname] = newmodel

        for tag in tags
            push!(_model_tags, tag)
        end

        logmsg("More TODO", LOG)
    end
    return
end

"""
    deletemodel(name::String)
Delete a model by name.
"""
function deletemodel!(name::String)::Nothing
    if name in keys(_loaded_models)
        delete!(_loaded_models, name)
    else
        logmsg("No model with name: $name, exists", LOG)
    end
    return
end

"""
    listmodels()
Returns the names of models loaded into the environment.
"""
function listmodels()
    return collect(keys(_loaded_models))
end

function listmodelsbytag(tag::String)::Nothing
    message = "Models listed with tag: $tag\n"
    for (name, model) in _loaded_models
        if tag in model.tags
            message = message * name * "\n"
        end
    end
    logmsg(message, LOG)
end

end
