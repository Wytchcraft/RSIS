# Model Interface
# Used for exposing models

module MModel

using Base: julia_cmd, julia_exename
using DataStructures: first
export Model, Port, Callback
export PORT, PORTPTR, PORTPTRI
export listcallbacks, triggercallback
export load, unload, listavailable
export convert_julia_type

using ..MScripting
using ..MLibrary
using ..MLogging
using ..MProject
using ..Unitful

## globals
# DataType => [Rust datatype, C++ datatype]
_type_conversions = Dict{DataType, Vector{String}}(
    Char    => ["char", "char"],
    Int8    => ["i8",   "int8_t"],
    Int16   => ["i16",  "int16_t"],
    Int32   => ["i32",  "int32_t"],
    Int64   => ["i64",  "int64_t"],
    UInt8   => ["u8",   "uint8_t"],
    UInt16  => ["u16",  "uint16_t"],
    UInt32  => ["u32",  "uint32_t"],
    UInt64  => ["u64",  "uint64_t"],
    Bool    => ["bool", "bool"],
    Float32 => ["f32",  "float"],
    Float64 => ["f64",  "double"],
    # Requires lines: ["use num_complex::Complex;", "#include <complex>"]
    Complex{Float32} => ["Complex<f32>", "std::complex<float>"],
    Complex{Float64} => ["Complex<f64>", "std::complex<double>"]
)

# Create a string -> DataType mapping for all supported datatypes
_type_map = Dict([Pair("$(_type)", _type) for _type in keys(_type_conversions)])

# Additional library paths to search
_additional_lib_paths = Vector{String}()

@enum PortType PORT=1 PORTPTR=2 PORTPTRI=3

"""
Defines a Port in a Model Interface file
"""
struct Port
    type::String
    dimension::Tuple
    defaultvalue::Any
    units::Any
    note::String
    porttype::PortType
    iscomposite::Bool

    # primitive type definition
    function Port(type::String, dimension::Tuple, defaultvalue::Any; units::Any=nothing, note::String="", porttype::PortType=PORT)
        if !(type in keys(_type_map))
            throw(ArgumentError("Provided type: $type is not supported"))
        end
        if !(eltype(defaultvalue) <: _type_map[type])
            throw(ArgumentError("Provided type: $type is not the same or a supertype of default value: $(eltype(defaultvalue))"))
        end
        _size = size(defaultvalue)
        if length(dimension) != length(_size)
            error("Provided dimension, [$dimension], does not match: $defaultvalue")
        end
        for i = 1:length(dimension)
            if dimension[i] != _size[i]
                error("Provided dimension, [$dimension], does not match: $defaultvalue")
            end
        end
        new(type, dimension, defaultvalue, units, note, porttype, false)
    end

    # composite definition
    function Port(type::String, dimension::Tuple; note::String="", porttype::PortType=PORT)
        # don't check type, must be done elsewhere
        new(type, dimension, nothing, nothing, note, porttype, true)
    end
end

mutable struct ClassData
    fields::Vector{Port}
end
ClassData() = ClassData(Vector{Port}())

_class_definitions = Dict{String, ClassData}()

function _CreateClass(name::Ptr{UInt8}) :: Nothing
    cl = unsafe_string(name)
    if cl in keys(_class_definitions)
        logmsg("Class: $(cl) redefined.", WARNING)
    end
    _class_definitions[cl] = ClassData()
    return
end

function _CreateMember(cl::Ptr{UInt8}, memb::Ptr{UInt8}, def::Ptr{UInt8}, offset::Int32) :: Nothing
    classname = unsafe_string(cl)
    member    = unsafe_string(memb)
    definition = unsafe_string(def)
    if !(classname in keys(_class_definitions))
        logmsg("Class: $(classname) for member: $(member) does not exist. Creating default.", WARNING)
        _class_definitions[classname] = ClassData()
    end
    return
end

function GetClassData(name::String, namespace::String = "") :: Nothing
    GetModelData(name, namespace,
        @cfunction(_CreateClass, Cvoid, (Ptr{UInt8},)),
        @cfunction(_CreateMember, Cvoid, (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Int32)))
    return
end

"""
"""
struct Callback
    name::String
end

"""
References instantiated model in the simulation framework
"""
mutable struct Model
    name::String
    in::Vector{Any}
    out::Vector{Any}
    data::Vector{Any}
    params::Vector{Any}

    callbacks::Vector{Callback}
end

"""
    listcallbacks(model::Model)
List all callbacks provided by model instance
```jldoctest
julia> mymodel = createmodel("MyModel", "mymodel", group="test")
julia> listcallbacks(mymodel)
mymodel (MyModel) callbacks:
    > stepModel
    > step_1Hz
```
"""
function listcallbacks(model::Model)
    name = model.name
    println("$name callbacks:")
    for i in eachindex(model.callbacks)
        cb = model.callbacks[i].name
        println("    > $cb")
    end
end

"""
    triggercallback(model::Model, callback::String)
Trigger a specified callback in a model instance.
```jldoctest
julia> triggercallback(mymodel, "step_1Hz")
[mymodel.step_1Hz] executed successfully.
```
"""
function triggercallback(model::Model, callback::String)
    println("Not implemented")
end

"""
    listavailable()
Returns a list of model libraries that can be loaded with
`load`. The project build directory is recursively searched
for shared libraries; file extension set by OS. Additional
library search paths can be set with `addlibpath`.
```
julia> listavailable()
3-element Vector{String}:
 fsw_hr_model
 fsw_lr_model
 gravity_model
```
"""
function listavailable() :: Vector{String}
    all = Vector{String}()
    if !isprojectloaded()
        logmsg("Load a project to see available libraries.", LOG)
    else
        bdir = getprojectbuilddirectory()
        file_ext = _libraryextension()
        if isdir(bdir)
            for (root, dirs, files) in walkdir(bdir)
                for file in files
                    fe = splitext(file)
                    if fe[2] == file_ext && startswith(fe[1], "lib")
                        push!(all, fe[1][4:end])
                    end
                end
            end
            # check additional paths
            for path in _additional_lib_paths
                #
            end
        else
            logmsg("Project build directory does not exist", ERROR)
        end
    end
    return all
end

"""
    load(library::String; namespace::String="")
Load a shared library containing a model implementation.
If a namespace is defined, any reflection data defined during
the load process is defined within that namespace, allowing
for multiple models to define classes with the same name.
```jldoctest
julia> load("mymodel")
julia> load("anothermodel"; namespace="TEST")
```
"""
function load(library::String; namespace::String="") :: Nothing
    # Find library in search path, then pass absolute filepath
    # to core functionality
    filename = "lib$(library)$(_libraryextension())"
    if !isprojectloaded()
        logmsg("Load a project to see available libraries.", ERROR)
        return
    end
    bdir = getprojectbuilddirectory()
    if isdir(bdir)
        for (root, dirs, files) in walkdir(bdir)
            for file in files
                if file == filename
                    # load library
                    if !LoadModelLib(library, joinpath(root, file), namespace)
                        logmsg("Model library alread loaded.", LOG)
                    end
                    GetClassData(library, namespace);
                    return
                end
            end
        end
    else
        logmsg("Project build directory does not exist", ERROR)
    end
    throw(ErrorException("File not found: $(library) [$(filename)]"))
end

"""
    unload(library::String)
Unload a shared library containing a model implementation
```jldoctest
julia> load("mymodel")
julia> unload("mymodel")
julia> unload("mymodel")
Model library not previously loaded.
```
"""
function unload(library::String) :: Nothing
    if !UnloadModelLib(library)
        logmsg("Model library not previously loaded.", WARNING)
    end
end

function connect(output::String, input::String)
    println("Not implemented")
end

function convert_julia_type(juliatype::String, language::String = "rust") :: String
    if !(juliatype in keys(_type_map))
        return juliatype
    end
    if language == "rust"
        return _type_conversions[_type_map[juliatype]][1]
    elseif language == "cpp"
        return _type_conversions[_type_map[juliatype]][2]
    else
        throw(ArgumentError("language must be [\"rust\",\"cpp\"]"))
    end
end

end