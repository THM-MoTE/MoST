# This module contains basic utility functions and utility functions to
# simulate modelica models using OMJulia

"""
    MoSTError

Error class for OMJulia-related errors that contains the OMC error message.
"""
struct MoSTError <: Exception
    msg:: String
    omc:: String
end

Base.showerror(io::IO, e::MoSTError) = print(io, e.msg, "\n---\nOMC error string:\n", e.omc)

"""
    MoSTError(omc:: OMCSession, msg:: String)

Creates MoSTError with message `msg` and current result of `getErrorString()`
as OMC error message.
"""
MoSTError(omc:: OMCSession, msg:: String) = MoSTError(msg, getErrorString(omc))

"""
    loadModel(omc:: OMCSession, name:: String; check=true, instantiate=true)

Loads the model with fully qualified name `name` from a source file available
from the model directory.
Note that this refers to the model *name*, not the model *file*.

Example:

    loadModel(omc, "Modelica.SIunits.Voltage")

This function will actually call several OM scripting functions to
ensure that as many errors in the model are caught and thrown as
[`MoSTError`](@ref)s as possible:

* First, `loadModel(name)` is called to load the model if it exists. This
    call does only fail if the toplevel model does not exist. E.g.,
    `loadModel(Modelica.FooBar)` would still return true, because `Modelica`
    could be loaded, although `FooBar` does not exist.
* We then check with `getClassRestriction(name)` if the model actually exists
    (which is the case when the return value is nonempty).
* With `checkModel(name)` we find errors such as missing or mistyped variables.
* Finally, we use `instantiateModel(name)` which can sometimes find additional
    errors in the model structure (e.g. since Modelica 1.16, unit consistency
    checks are performed here).

If `check`, or `instantiate` are false, the loading process is stopped at the
respective steps.
""" # TODO: which errors are found by instantiateModel that checkModel does not find?
function loadModel(omc:: OMCSession, name:: String; ismodel=true, check=true, instantiate=true)
    # only load model if it was not created by sending a class definition
    # string directly to the OMC
    if filename(omc, name) != "<interactive>"
        success = sendExpression(omc, "loadModel($name)")
        es = getErrorString(omc)
        if isnothing(success)
            # i have seen this happen, but do not know why it does occur
            throw(MoSTError("Unexpected error: loadModel($name) returned nothing", es))
        end
        if !success || length(es) > 0
            throw(MoSTError("Could not load $name", es))
        end
    end
    # loadModel will only fail if the *toplevel* class does not exist
    # => check that the full class name could actually be loaded
    if !isloaded(omc, name)
        throw(MoSTError("Model $name not found in MODELICAPATH", ""))
    end
    if !ismodel
        @warn(string(
            "The keyword parameter ismodel is deprecated since the existance",
            " of a model/class is now checked with new isloaded() function",
            " which does not fail like isModel() did.",
            " You can simply replace `ismodel=false` with `check=false`,",
            " which will now have the same effect."
        ))
        return
    end
    if !check
        return
    end
    check = sendExpression(omc, "checkModel($name)")
    es = getErrorString(omc)
    if !startswith(check, "Check of $name completed successfully")
        throw(MoSTError("Model check of $name failed", join([check, es], "\n")))
    end
    if !instantiate
        return
    end
    inst = sendExpression(omc, "instantiateModel($name)")
    es = getErrorString(omc)
    if length(es) > 0
        throw(MoSTError("Model $name could not be instantiated", es))
    end
end

"""
    isloaded(omc:: OMCSession, name:: String)

Checks that the model/class/package/... `name` was correctly loaded and can
be queried by other functions.
"""
function isloaded(omc:: OMCSession, name:: String)
    # One of the few functions that we can use here is getClassRestriction,
    # because it gives an empty string for nonexistent models and "model",
    # "class", "connector", ... for other class types
    classrest = sendExpression(omc, "getClassRestriction($name)")
    return !isempty(classrest)
end

"""
    filename(omc:: OMCSession, name:: String)

Returns the file name where the model/class/package/... `name` is stored.
If `name` was defined by directly sending a class definition to the OMC the
return value will be `"<interactive>"`. If the model could not be found,
the return value will be an empty string.
"""
function filename(omc:: OMCSession, name:: String)
    res = sendExpression(omc, "getClassInformation($name)")
    return res[6]
end

"""
    moescape(s:: String)

Escapes string according to Modelica specification for string literals.

Escaped characters are: `['\\\\', '"', '?', '\\a', '\\b', '\\f', '\\n', '\\r', '\\t', '\\v',]`
"""
function moescape(s:: String)
    rep = Dict(
        '\\' => "\\\\",
        '"' => "\\\"",
        '?' => "\\?",
        '\a' => "\\a",
        '\b' => "\\b",
        '\f' => "\\f",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        '\v' => "\\v",
    )
    return join([(x in keys(rep) ? rep[x] : x) for x in s])
end

"""
    moescape(s:: String)
    moescape(io:: IO, s:: String)

Unescapes string that was escaped by [`moescape(s:: String)`](@ref) or that
was returned from the OMC compiler. If `io` is given the string is printed to
the `IO` object, otherwise it is returned directly.
"""
function mounescape(io:: IO, s:: String)
    rev = Dict(
        "\\\\" => '\\',
        "\\\"" => '"',
        "\\?" => '?',
        "\\a" => '\a',
        "\\b" => '\b',
        "\\f" => '\f',
        "\\n" => '\n',
        "\\r" => '\r',
        "\\t" => '\t',
        "\\v" => '\v'
    )
    i = Iterators.Stateful(s)
    while !isempty(i)
        c = popfirst!(i)
        if c != '\\' || isempty(i)
            print(io, c)
        else
            nxt = popfirst!(i)
            print(io, rev[join([c, nxt])])
        end
    end
end
mounescape(s::String) = sprint(mounescape, s; sizehint=lastindex(s))

function getErrorString(omc:: OMCSession)
    es = sendExpressionRaw(omc, "getErrorString()")
    parsed = strip(strip(mounescape(es)),'"')
    # FIXME this should be removed if there is a way to fix the model or if OpenModelica 1.16 is updated
    # we ignore a specific cryptic error message from OpenModelica 1.16.0
    ignore = "Warning: function Unit.unitString failed for \"MASTER()\".\n"
    return parsed == ignore ? "" : parsed
end

function sendExpressionRaw(omc:: OMCSession, expr)
    # FIXME this function should be replaced by sendExpression(omc, parsed=false)
    send(omc.socket, expr)
    message=recv(omc.socket)
    return unsafe_string(message)
end

"""
    getSimulationSettings(omc:: OMCSession, name:: String; override=Dict())

Reads simulation settings from the model `name`.
Any content in `override` will override the setting with the respective key.

Returns a Dict with the keys `"startTime"`, `"stopTime"`, `"tolerance"`,
`"numberOfIntervals"`, `"outputFormat"` and `"variableFilter"`.
If any of these settings are not defined in the model file, they will be
filled with default values.

In `override`, an additional key `"interval"` is allowed to recalculate the
`"numberOfIntervals"` based on the step size given as value to this key.

Throws a [`MoSTError`](@ref) if the model `name` was not loaded beforehand using
[`loadModel(omc:: OMCSession, name:: String)`](@ref).
"""
function getSimulationSettings(omc:: OMCSession, name:: String; override=Dict())
    values = sendExpression(omc, "getSimulationOptions($name)")
    settings = Dict(
        "startTime"=>values[1], "stopTime"=>values[2],
        "tolerance"=>values[3], "numberOfIntervals"=>values[4],
        "outputFormat"=>"csv", "variableFilter"=>".*"
    )
    interval = values[5]
    settings["variableFilter"] = getVariableFilter(omc, name)
    for x in keys(settings)
        if x in keys(override)
            settings[x] = override[x]
        end
    end
    # the overriding of simulation time or interval size may require additional
    # changes to the numberOfIntervals setting
    hasinterval = haskey(override, "interval")
    onlytime = (haskey(override, "startTime") || haskey(override, "stopTime")
        && !haskey(override, "interval")
        && !haskey(override, "numberOfIntervals")
    )
    if hasinterval || onlytime
        timespan = settings["stopTime"] - settings["startTime"]
        interval = get(override, "interval", interval)
        settings["numberOfIntervals"]  = trunc(Int, timespan / interval)
    end
    return settings
end

"""
    getVariableFilter(omc:: OMCSession, name:: String)

Reads the value for the `variableFilter` simulation setting from the model
file if it has been defined.
MoST assumes that this value will be given in a vendor-specific annotation
of the form `__MoST_experiment(variableFilter=".*")`.
If such an annotation is not found, the default filter `".*"` is returned.

Throws a [`MoSTError`](@ref) if the model `name` does not exist.
"""
function getVariableFilter(omc:: OMCSession, name:: String)
    mostann = sendExpression(omc, "getAnnotationNamedModifiers($name, \"__MoST_experiment\")")
    if isnothing(mostann)
        throw(MoSTError("Model $name not found", ""))
    end
    varfilter = ".*"
    if "variableFilter" in mostann
        varfilter = sendExpression(omc, "getAnnotationModifierValue($name, \"__MoST_experiment\", \"variableFilter\")")
    end
    return varfilter
end

"""
    getVersion(omc:: OMCSession)

Returns the version of the OMCompiler as a triple (major, minor, patch).
"""
function getVersion(omc:: OMCSession)
    versionstring = sendExpression(omc, "getVersion()")
    # example: OMCompiler v1.17.0-dev.94+g4da66238ab
    # example: OpenModelica 1.14.2
    vmatch = match(r"^(?:OMCompiler v|OpenModelica )(\d+)\.(\d+).(\d+)", versionstring)
    if isnothing(vmatch)
        throw(MoSTError(omc, "Got unexpected version string: $versionstring"))
    end
    cap = map(x -> parse(Int, x), vmatch.captures)
    major, minor, patch = cap
    return Tuple([major, minor, patch])
end

"""
    simulate(omc:: OMCSession, name::String)
    simulate(omc:: OMCSession, name::String, settings:: Dict{String, Any})

Simulates the model `name` which must have been loaded before with
[`loadModel(omc:: OMCSession, name:: String)`](@ref).
The keyword-parameters in `settings` are directly passed to the OpenModelica
scripting function `simulate()`.
If the parameter is not given, it is obtained using
[`getSimulationSettings(omc:: OMCSession, name:: String; override=Dict())`](@ref).

The simulation output will be written to the current working directory of the
OMC that has been set by
[`setupOMCSession(outdir, modeldir; quiet=false, checkunits=true)`](@ref).

The simulation result is checked for errors with the following methods:

* The messages returned by the OM scripting call are checked for
    the string `Simulation execution failed`. This will, e.g., be the case
    if there is an arithmetic error during simulation.
* The abovementioned messages are checked for the string `| warning |` which
    hints at missing initial values and other non-critical errors.
* The error string returned by the OM scripting function `getErrorString()`
    should be empty if the simulation was successful.

If any of the abovementioned methods reveals errors, a [`MoSTError`](@ref)
is thrown.
""" # TODO which class of errors can be found using the error string?
function simulate(omc:: OMCSession, name::String, settings:: Dict{String, Any})
    prepare(s:: String) = "\"$(moescape(s))\""
    prepare(x:: Number) = x
    setstring = join(("$k=$(prepare(v))" for (k,v) in settings), ", ")
    r = sendExpression(omc, "simulate($name, $setstring)")
    if startswith(r["messages"], "Simulation execution failed")
        throw(MoSTError("Simulation of $name failed", r["messages"]))
    end
    if occursin("| warning |", r["messages"])
        throw(MoSTError("Simulation of $name produced warning", r["messages"]))
    end
    es = getErrorString(omc)
    if length(es) > 0
        throw(MoSTError("Simulation of $name failed", es))
    end
end
simulate(omc:: OMCSession, name::String) = simulate(omc, name, getSimulationSettings(omc, name))

"""
    avoidStartupFreeze(omc:: OMCSession)

Helper function to avoid freezes that can occur when the first message is sent
to a newly created OMCSession.

The current strategy for this is to detect the freeze, discard the frozen
session and create a new session, repeating this process until a non-frozen
connection is obtained.
"""
function avoidStartupFreeze(omc:: OMCSession)
    # TODO if this does not work, we can try this instead:
    #      https://github.com/JuliaInterop/ZMQ.jl/issues/198#issuecomment-576689600
    # sleep(0.5)
    function reconnect(omc:: OMCSession)
        @warn(string(
            "Discarding frozen connection to OMC with file descriptor $(omc.socket.fd)",
            " and starting new OMC instance. This may leave the old OMC",
            " instance still running on your machine."
        ))
        try
            closeOMCSession(omc)
        catch e
            @warn(string(
                "Closing old OMC instance failed with the following error:\n",
                e
            ))
        end
        return safeOMCSession()
    end
    status = :started
    timeout = 0.1
    while status != :received
        # send a simple command to OMC
        send(omc.socket, "getVersion()")
        # use julia task to allow recv to run into a timeout
        # idea from https://github.com/JuliaInterop/ZMQ.jl/issues/87#issuecomment-131153884
        c = Channel()
        @async put!(c, (recv(omc.socket), :received));
        @async (sleep(timeout); put!(c, (nothing, :timedout));)
        data, status = take!(c)
        if status == :timedout
            omc = reconnect(omc)
        end
    end
    return omc
end

"""
    safeOMCSession()

Helper function to avoid ZMQ.StateError that can occur when calling
`OMCSession()`.

The current strategy is to simply retry the connector call up to 10 times.
"""
function safeOMCSession()
    created = false
    tries = 0
    omc = nothing
    while !created && tries <= 10
        tries += 1
        try
            omc = OMCSession()
            created = true
        catch e
            if !isa(e, ZMQ.StateError)
                rethrow(e)
            end
            @warn(string(
                "OMCSession() constructor errored, attempting retry no $tries/10:\n",
                e
            ))
        end
    end
    if !created
        throw(MoSTError("OMCSession could not be created after $tries retries", ""))
    end
    return omc
end


"""
    setupOMCSession(outdir, modeldir; quiet=false, checkunits=true)

Creates an `OMCSession` and prepares it by preforming the following steps:

* create the directory `outdir` if it does not already exist
* change the working directory of the OMC to `outdir`
* add `modeldir` to the MODELICAPATH
* enable unit checking with the OMC command line option
    `--unitChecking` (unless `checkunits` is false)

If `quiet` is false, the resulting MODELICAPATH is printed to stdout.

Returns the newly created OMCSession.
"""
function setupOMCSession(outdir, modeldir; quiet=false, checkunits=true)
    # create output directory
    if !isdir(outdir)
        mkpath(outdir)
    end
    # create sessions
    omc = safeOMCSession()
    # sleep for a short while, because otherwise first ZMQ call may freeze
    omc = avoidStartupFreeze(omc)
    # move to output directory
    sendExpression(omc, "cd(\"$(moescape(outdir))\")")
    # set modelica path
    mopath = sendExpression(omc, "getModelicaPath()")
    mopath = "$mopath:$(moescape(abspath(modeldir)))"
    if !quiet
        println("Setting MODELICAPATH to ", mopath)
    end
    sendExpression(omc, "setModelicaPath(\"$mopath\")")
    # enable unit checking
    if checkunits
        flag = if getVersion(omc) >= Tuple([1, 16, 0])
            "--unitChecking"
        else
            "--preOptModules+=unitChecking"
        end
        sendExpression(omc, "setCommandLineOptions(\"$flag\")")
    end
    if !quiet
        opts = sendExpression(omc, "getCommandLineOptions()")
        println("Using command line options: $opts")
    end
    return omc
end

"""
    installAndLoad(omc:: OMCSession, lib:: AbstractString; version="latest")

Loads the Modelica library `lib` in version `version` and also installs it
if necessary.
"""
function installAndLoad(omc:: OMCSession, lib:: AbstractString; version="latest")
    lmver = version
    instver = version
    if getVersion(omc) < Tuple([1,16,0]) && version != "latest"
        # OpenModelica 1.14.2 does not have installPackage
        # => try to load default version and fail on error
        @warn(string(
            "Cannot install specific version $version of library $lib on OpenModelica < 1.16.0",
            " Attempting to load default version if it is installed."
        ))
        version = "latest"
    end
    if version == "latest"
        lmver = "default"
        instver = ""
    end
    sendExpression(omc, "loadModel($lib, {\"$lmver\"})")
    es = getErrorString(omc)
    if length(es) > 0 # can happen on OpenModelica 1.16 if MSL is not installed by default
        if getVersion(omc) < Tuple([1,16,0])
            throw(MoSTError("Cannot load library $lib with version $version on OpenModelica < 1.16.0", es))
        end
        sendExpression(omc, "installPackage($lib, \"$instver\")")
        # expected content: "Notification: Package installed successfully" for Modelica, ModelicaServices and Complex
        es = getErrorString(omc)
        if !occursin("Package installed successfully", es)
            throw(MoSTError("Failed to install library $lib with version $version", es))
        end
        sendExpression(omc, "loadModel($lib, {\"$lmver\"})")
        es = getErrorString(omc)
        if length(es) > 0
            throw(MoSTError("Failed to load library $lib with version $version after successful installation", es))
        end
    end
end

"""
    closeOMCSession(omc:: OMCSession; quiet=false)

Closes the OMCSession given by `omc`, shutting down the OMC instance.

Due to a [bug in the current release version of OMJulia](https://github.com/OpenModelica/jl/issues/32)
the function may occasionally freeze.
If this happens, you have to stop the execution with CTRL-C.
You can tell that this is the case if the output `Closing OMC session` is
printed to stdout, but it is not followed by `Done`.
If desired, these outputs can be disabled by setting `quiet=true`.

If you want to use a MoST.jl script for continuous integration, you can use
the following shell command to add a timeout to your script and treat the
timeout as a successful test run (which is, of course, unsafe).

```bash
(timeout 2m julia myTestScript.jl; rc=\$?; if [ \${rc} -eq 124 ]; then exit 0; else exit \${rc}; fi;)
```
"""
function closeOMCSession(omc:: OMCSession; quiet=false)
    if !quiet
        println("Closing OMC session")
    end
    # only send, do not wait for response since this may lead to freeze
    send(omc.socket, "quit()")
    # curently disabled due to error
    #close(omc.socket) # also close ZMQ socket
    if !quiet
        println("Done")
    end
end

"""
    withOMC(f:: Function, outdir, modeldir; quiet=false, checkunits=true)

Allows to use OMCSession with do-block syntax, automatically closing the
session after the block has been executed.
For the parameter definition see [`setupOMCSession(outdir, modeldir; quiet=false, checkunits=true)`](@ref).

Example:

```julia
withOMC("test/out", "test/res") do omc
    loadModel(omc, "Example")
end
```
"""
function withOMC(f:: Function, outdir, modeldir; quiet=false, checkunits=true)
    omc = setupOMCSession(outdir, modeldir; quiet=quiet, checkunits=checkunits)
    try
        f(omc)
    finally
        closeOMCSession(omc)
    end
end
