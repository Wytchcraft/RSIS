
module MLibrary
using Base: Int32, _getmeta
using ..MLogging

export LoadLibrary, UnloadLibrary, InitLibrary, ShutdownLibrary
export newmodel, deletemodel!, listmodels, listmodelsbytag, listlibraries
export getscheduler, initscheduler, stepscheduler, endscheduler, addthread, schedulemodel
export LoadModelLib, UnloadModelLib, _libraryprefix, _libraryextension
export GetModelData, _getmodelinstance
export ModelInstance, ModelReference
export simstatus, SchedulerState
export get_utf8_string, set_utf8_string

using Libdl
using TOML

# this enum is supposed to match the SchedulerState enum in rust
@enum SchedulerState begin
    CONFIG=0
    INITIALIZING=1
    INITIALIZED=2
    RUNNING=3
    PAUSED=4
    ENDING=5
    ENDED=6
    ERRORED=7
end

# globals
_lib = nothing # library pointer
_sym = nothing # symbol loading
_namespaces = Dict{String, Vector{String}}()

@enum RSISCmdStat::Int32 begin
    OK  = 0
    ERR = 1
end

mutable struct LibFuncs
    s_init
    s_shutdown
    s_newthread
    s_addmodel
    s_initscheduler
    s_stepscheduler
    s_pausescheduler
    s_runscheduler
    s_endscheduler
    s_getmessage
    s_getstate
    s_getschedulername
    s_getutf8
    s_setutf8
    function LibFuncs(lib)
        new(Libdl.dlsym(lib, :library_initialize),
            Libdl.dlsym(lib, :library_shutdown),
            Libdl.dlsym(lib, :new_thread),
            Libdl.dlsym(lib, :add_model),
            Libdl.dlsym(lib, :init_scheduler),
            Libdl.dlsym(lib, :step_scheduler),
            Libdl.dlsym(lib, :pause_scheduler),
            Libdl.dlsym(lib, :run_scheduler),
            Libdl.dlsym(lib, :end_scheduler),
            Libdl.dlsym(lib, :get_message),
            Libdl.dlsym(lib, :get_scheduler_state),
            Libdl.dlsym(lib, :get_scheduler_name),
            Libdl.dlsym(lib, :get_utf8_string),
            Libdl.dlsym(lib, :set_utf8_string))
    end
end

mutable struct LibModel
    s_lib
    s_createmodel
    s_reflect
    s_metadata
    metadata::Dict{String,Any}
    function LibModel(libfile::String)
        lib = Libdl.dlopen(libfile)
        new(lib,
            Libdl.dlsym(lib, :create_model),
            Libdl.dlsym(lib, :reflect),
            Libdl.dlsym(lib, :metadata))
    end
end

mutable struct ModelInstance
    modulename::String
    name::String
    tags::Vector{String}
    obj::Ptr{Cvoid}
end

struct ModelReference
    name::String
end

function Base.show(io::IO, obj::ModelReference)
    try
        _model = _getmodelinstance(obj)
        println(io, "RSIS model: $(obj.name), from library $(_model.modulename)")
    catch
        println(io, "RSIS model: $(obj.name), does not exist")
    end
end

# globals
_modellibs     = Dict{String, LibModel}()
_loaded_models = Dict{String, ModelInstance}()
_model_tags    = Set{String}()

function _getmodelinstance(model::ModelReference) :: ModelInstance
    if model.name in keys(_loaded_models)
        return _loaded_models[model.name]
    else
        throw(ErrorException("$(model.name) does not exist"))
    end
end

function _libraryprefix() :: String
    if Sys.isunix() || Sys.isapple()
        return "lib"
    elseif Sys.iswindows()
        return ""
    else
        throw(ErrorExceptionn("Unknown operating system"))
    end
end

function _libraryextension() :: String
    if Sys.isunix()
        if Sys.islinux()
            return ".so"
        elseif Sys.isapple()
            return ".dylib"
        end
    elseif Sys.iswindows()
        return ".dll"
    else
        throw(ErrorException("Unknown operating system"))
    end
end

function _loadlibmetadata(modellib::LibModel) :: Nothing
    strdata = ccall(modellib.s_metadata, Ptr{UInt8}, ())
    if strdata == 0
        println("Warning: Library does not have metadata. Null pointer returned")
        return
    end
    text = unsafe_string(strdata)
    data = TOML.tryparse(text)
    if isa(data, TOML.ParserError)
        println("Warning: Library has invalid metadata. Error: $(data)")
    else
        modellib.metadata = data
    end
    return
end

"""
    LoadLibrary()
Load the RSIS shared library
"""
function LoadLibrary()
    global _lib
    global _sym

    # detect operating system
    libpath = joinpath(@__DIR__, "core", "target", "debug");
    libfile = ""
    try
        libfile = _libraryprefix() * "rsis" * _libraryextension()
    catch e
        throw(InitError(:RSIS, String(e)))
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
    LoadModelLib(name::String, filename::String, namespace::String="")
Attempts to load a shared model library by filename, storing it with a name
if it does so. Returns whether the library was loaded for the first time.
The namespace of this library defaults to the global namespace.
This function can throw.
"""
function LoadModelLib(name::String, filename::String, namespace::String="") :: Bool
    if !(name in keys(_modellibs))
        _modellibs[name] = LibModel(filename)
        if namespace in keys(_namespaces)
            push!(_namespaces[namespace], name)
        else
            _namespaces[namespace] = [name]
        end
        _loadlibmetadata(_modellibs[name])
        return true
    end
    return false
end

"""
    UnloadModelLib(name::String)
Attempts to unload a shared model library by name.
Returns whether the library was unloaded.
This function can throw.
"""
function UnloadModelLib(name::String) :: Bool
    global _loaded_models
    if name in keys(_modellibs)
        # unload all model instances
        for model in keys(_loaded_models)
            delete!(_loaded_models, model)
        end
        _loaded_models = Dict{String, ModelInstance}()

        # unload the library
        Libdl.dlclose(_modellibs[name].s_lib)
        delete!(_modellibs, name)
        return true
    end
    return false
end

"""
    GetModelData(name::String, namespace::String, classfunc::Ptr{Cvoid}, membfunc::Ptr{Cvoid})
Call into model library to access metadata. Pass in provided callback functions
for registration of model data.
"""
function GetModelData(name::String, namespace::String, classfunc::Ptr{Cvoid}, membfunc::Ptr{Cvoid}) :: Nothing
    if name in keys(_modellibs)
        ccall(_modellibs[name].s_reflect, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), classfunc, membfunc);
    else
        throw(ErrorException("No model loaded with name: $(name)"))
    end
end

function InitLibrary(symbols::LibFuncs)
    #
    stat = ccall(symbols.s_init, UInt8, ())
    if stat ≠ 0
        error("Failed to initialize library");
    end
end

function ShutdownLibrary(symbols::LibFuncs)
    #
    stat = ccall(symbols.s_shutdown, UInt8, ())
    if stat ≠ 0
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
    newmodel(library::String, newname::String; tags::Vector{String}
Create a new model. A unique name must be given for the model. An optional list
of tags can be given, allowing the user to search loaded models by tag.
```jldoctest
julia> load("testM")
julia> newmodel("testM", "testInterface")

```
"""
function newmodel(library::String, newname::String; tags::Vector{String}=Vector{String}()) :: ModelReference
    if !(library in keys(_modellibs))
        throw(ArgumentError("Module: $(library) is not loaded"))
    end
    if newname in keys(_loaded_models)
        throw(ArgumentError("Model: $newname already exists."))
    end
    
    # call `create_model` function to get a pointer to the object
    obj = ccall(_modellibs[library].s_createmodel, Ptr{Cvoid}, ())
    if obj == 0
        throw(ErrorException("Call to `create_model` return NULL"))
    end

    # store in a new model instance
    _loaded_models[newname] = ModelInstance(library, newname, tags, obj)

    for tag in tags
        push!(_model_tags, tag)
    end

    # return reference
    ModelReference(newname)
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
Returns the names of all models loaded into the environment.
"""
function listmodels() :: Vector{String}
    return collect(keys(_loaded_models))
end

"""
    listlibraries()
Returns a vector of all loaded model libraries
"""
function listlibraries() :: Vector{String}
    return collect(keys(_modellibs))
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

function addthread(frequency::Float64)
    stat = ccall(_sym.s_newthread, UInt32, (Float64,), frequency)
    if stat != 0
        throw(ErrorException("Call to `new_thread` in library failed"))
    end
end

function schedulemodel(model::ModelReference, thread::Int64, divisor::Int64, offset::Int64)
    _model = _getmodelinstance(model)
    # the framework moves the object around, get the new pointer
    newptr = ccall(_sym.s_addmodel, Ptr{Cvoid}, (Int64, Ptr{Cvoid}, Int64, Int64), thread, _model.obj, divisor, offset)
    if newptr == 0
        throw(ErrorException("Call to `add_model` in library failed"))
    end
    _model.obj = newptr
end

function initscheduler() :: Nothing
    stat = ccall(_sym.s_initscheduler, UInt32, ());
    if stat != 0
        throw(ErrorException("Call to `init_scheduler` in library failed"))
    end
end

function stepscheduler(steps::UInt64) :: Nothing
    stat = ccall(_sym.s_stepscheduler, UInt32, (UInt64,), steps);
    if stat != 0
        throw(ErrorException("Call to step_scheduler in library failed"))
    end
end

function endscheduler() :: Nothing
    stat = ccall(_sym.s_endscheduler, UInt32, ());
    if stat != 0
        throw(ErrorException("Call to `end_scheduler` in library failed"))
    end
end

function simstatus() :: SchedulerState
    stat = ccall(_sym.s_getstate, Int32, ());
    return SchedulerState(stat);
end

struct utf8_data
    pointer::Ptr{UInt8}
    size::UInt64
end

function get_utf8_string(obj::Ptr{Cvoid}) :: String
    # TODO update for multiple languages. this is rust only for now
    data::utf8_data = ccall(_sym.s_getutf8, utf8_data, (Ptr{Cvoid},), obj)
    return unsafe_string(data.pointer, data.size)
end

function set_utf8_string(obj::Ptr{Cvoid}, str::String) :: Nothing
    data = utf8_data(pointer(str), ncodeunits(str))
    stat = ccall(_sym.s_setutf8, UInt32, (Ptr{Cvoid}, utf8_data), obj, data)
    if stat != 0
        throw(ErrorException("Failed to set string value"))
    end
end

end
