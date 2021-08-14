#

module MInterfaceGeneration

using ..DataStructures
using ..Unitful
using ..YAML
using ..MScripting
using ..MLogging
using ..MModel

export generateinterface

# globals
_type_defaults = Dict{String, Any}(
    "char"    => ' ',
    "Int8"    => 0,
    "Int16"   => 0,
    "Int32"   => 0,
    "Int64"   => 0,
    "UInt8"   => 0,
    "UInt16"  => 0,
    "UInt32"  => 0,
    "UInt64"  => 0,
    "Bool"    => false,
    "Float32" => 0,
    "Float64" => 0,
    "Complex{Float32}" => 0+0im,
    "Complex{Float64}" => 0+0im
)

"""
Helper function for generateinterface
Used to create model files from relevant information
"""
function pushtexttofile(directory::String, model::String, words::Dict{String,String}, templates::Vector{Tuple{String, String}})
    key = r"({{(.*)}})"
    for template in templates
        path = joinpath(directory, model * template[1])
        f_file = open(path, "w")

        # read template
        temp = open(template[2], "r")
        for line in readlines(temp)
            # word substitution
            if occursin(key, line)
                copy = line
                matched = match(key, copy)
                copy = replace(copy, Regex(matched.captures[1]) => words[matched.captures[2]])
                write(f_file, copy)
            else
                write(f_file, line)
            end
            write(f_file, "\n")
        end

        close(temp)
        close(f_file)

        println("Generated: $path")
    end
end

function grabClassDefinitions(data::OrderedDict{String,Any},
                              modelname::String,
                              order::Vector{String},
                              definitions::Dict{String, Vector{Tuple{String, Port}} }) :: String
    if !haskey(definitions, modelname)
        definitions[modelname] = Vector{Tuple{String,Port}}()
    end
    if !(modelname in keys(data))
        throw(ErrorException("Class definition: $(model) not found!"))
    end
    model = data[modelname]
    for field in model
        if !isa(field.second, OrderedDict)
            throw(ErrorException("Non dictionary detected"))
        end
        _keys = keys(field.second)
        if "class" in _keys
            dims = []
            if "dims" in _keys
                dims = field.second["dims"]
            end
            if !isa(dims, Vector)
                throw(ErrorException("Dimension specified for composite $(field.first) is not a list"))
            end
            desc = ""
            if "desc" in _keys
                desc = field.second["desc"]
            end
            composite = Port(field.second["class"], Tuple(dims); note=desc, porttype=PORT)
            push!(definitions[modelname], (field.first, composite))
            newmodelname = grabClassDefinitions(data, field.second["class"], order, definitions)
            push!(order, newmodelname)
        elseif "type" in _keys
            # this is a regular port
            dims = []
            if "dims" in _keys
                dims = field.second["dims"]
            end
            if !isa(dims, Vector)
                throw(ErrorException("Dimension specified for field $(field.first) is not a list"))
            end
            unit=nothing
            if "unit" in _keys
                u = field.second["unit"]
                try
                    unit = uparse(u)
                catch e
                    if isa(e, ArgumentError)
                        throw(ErrorException("Unit: $(u) for field $(field.first) is not defined"))
                    else
                        throw(e) # rethrow error
                    end
                end
            end
            initial = _type_defaults[field.second["type"]]
            if "value" in _keys
                initial = field.second["value"]
            end
            desc = ""
            if "desc" in _keys
                desc = field.second["desc"]
            end

            port = Port(field.second["type"], Tuple(dims), initial; units=unit, note=desc, porttype=PORT)
            push!(definitions[modelname], (field.first, port))
        else
            throw(ErrorException("Invalid model interface"))
        end
    end
    return modelname
end

"""
    generateinterface(interface::String; language::String = "cpp")
Generate a model interface from the specified interface file. Both
C++ and Rust model interfaces can be generated. The generated files
are put in the same location as the interface file.
```jldoctest
julia> generateinterface("mymodel.yml")
Generated: mymodel_interface.hxx
Generated: mymodel_interface.cxx
Generation complete
julia> generateinterface("mymodel.yml"; interface = "rust")
Generated: mymodel_interface.rs
Generation complete
```
"""
function generateinterface(interface::String; language::String = "cpp")
    templates = Vector{Tuple{String, String}}()
    if language == "cpp"
        push!(templates, ("_interface.hxx", joinpath(@__DIR__, "templates", "header_cpp.template")))
        push!(templates, ("_interface.cxx", joinpath(@__DIR__, "templates", "source_cpp.template")))
    elseif language == "rust"
        push!(templates, ("_interface.rs", joinpath(@__DIR__, "templates", "rust.template")))
    else
        error(ArgumentError("[\"cpp\",\"rust\"] are the only valid language options"))
    end
    words = Dict{String, String}()

    path_interface = search(interface)
    if length(path_interface) == 0
        throw(IOError("Unable to find interface file: $interface"))
    end

    data = YAML.load_file(path_interface[1], dicttype=OrderedDict{String,Any})
    if !("model" in keys(data))
        throw(ErrorException("The `model` element was not found. Aborting"))
    end

    # iterate through expected members, and grab data
    # recurse through each member
    class_order = Vector{String}()
    class_defs  = Dict{String, Vector{Tuple{String, Port}}}()
    grabClassDefinitions(data, data["model"], class_order, class_defs)
    push!(class_order, data["model"])

    base_dir   = dirname(path_interface[1])
    model_name = splitext(interface)[1]

    # create text
    if language == "cpp"
        words["HEADER_GUARD"] = uppercase(model_name)
        words["HEADER_FILE"]  = "$(model_name)_interface.hxx"
        hxx_text = ""
        cxx_text = ""
        for name in class_order
            fields = class_defs[name]
            htext = "class $(name) {\n" *
                    "public:\n" *
                    "    $name();\n" *
                    "    virtual ~$name();\n";
            ctext = "$name::$name()"
            if length(fields) != 0
                ctext = ctext * " : "
            end
            first = true;
            for (n,f) in fields
                htext = htext * "    $(convert_julia_type(f.type, language)) $n"
                if length(f.dimension) != 0
                    htext = htext * "[$(join(f.dimension, "]["))]"
                end
                htext = htext * "; // $(f.note) \n"
                if first
                    first = false;
                else
                    ctext = ctext * ", "
                end
                if f.iscomposite
                    ctext = ctext * "$n()"
                else
                    if length(f.dimension) == 0
                        ctext = ctext * "$n($(f.defaultvalue))"
                    else
                        ctext = ctext * "$n{" * join([d for d in f.defaultvalue], ", ") *"}"
                    end
                end
            end
            htext = htext * "};\n"
            ctext = ctext * "{ }\n$name::~$name() { }\n"
            hxx_text = hxx_text * htext;
            cxx_text = cxx_text * ctext;
        end
        words["CLASS_DEFINES"]     = hxx_text
        words["CLASS_DEFINITIONS"] = cxx_text
        words["REFLECT_DEFINE"] = "void ReflectModels(RSIS::Model::DefineClass_t _class, RSIS::Model::DefineMember_t _member);"

        # Add reflection generation
        rtext = ""
        for name in class_order
            fields = class_defs[name]
            rtext = rtext * "void Reflect_$(name)(DefineClass_t _class, DefineMember_t _member) {\n"
            rtext = rtext * "_class(\"$(name)\");\n"
            txt = ""
            for (fieldname, f) in fields
                txt = txt * "_member(\"$(name)\", \"$(fieldname)\", \"int\", _offsetof(&$(name)::$(fieldname)));\n"
            end
            rtext = rtext * txt * "}\n\n"
        end
        words["REFLECT_DEFINITIONS"] = rtext

        words["REFLECT_CALLS"] = join(["Reflect_$(name)(_class, _member);" for name in class_order], "\n")
    else
        rs_text = ""
        for name in class_order
            fields = class_defs[name]
            txt = "#[repr(C, packed)]\npub struct $(name) {\n"
            for (n,f) in fields
                txt = txt * "    $n : $(convert_julia_type(f.type, language)),\n"
            end
            txt = txt * "}\n"
            rs_text = rs_text * txt
        end
        words["STRUCT_DEFINITIONS"] = rs_text
    end
    pushtexttofile(base_dir, model_name, words, templates)

    println("Generation complete")
    return
end

end