module Gnuplot

using AbbrvKW

export gp_getStartup, gp_getCmd, gp_getVerbose, gp_setOption,
       gp_IDs, gp_current, gp_setCurrent, gp_new, gp_exit, gp_exitAll,
       gp_send, @gp_str, gp_reset, gp_cmd, gp_data, gp_plot, gp_multi, gp_next, gp_dump,
       @gp_, @gp, gp_load, gp_terminals, gp_terminal


######################################################################
# Structure definitions
######################################################################

"""
Structure containing the `Pipe` and `Process` objects associated to a
Gnuplot process.
"""
mutable struct GnuplotProc
    pin::Base.Pipe
    pout::Base.Pipe
    perr::Base.Pipe
    proc::Base.Process
    channel::Channel{String}

"""
Start a new gnuplot process using the command given in the `cmd` argument.
"""
    function GnuplotProc(cmd::String)
        this = new()
        this.pin  = Base.Pipe()
        this.pout = Base.Pipe()
        this.perr = Base.Pipe()
        this.channel = Channel{String}(32)

        # Start gnuplot process
        this.proc = spawn(`$cmd`, (this.pin, this.pout, this.perr))

        # Close unused sides of the pipes
        Base.close_pipe_sync(this.pout.in)
        Base.close_pipe_sync(this.perr.in)
        Base.close_pipe_sync(this.pin.out)
        Base.start_reading(this.pout.out)
        Base.start_reading(this.perr.out)

        return this
	end
end


#---------------------------------------------------------------------
"""
Structure containing a single command and the associated multiplot index
"""
mutable struct MultiCmd
  cmd::String    # command
  id::Int        # multiplot index
end

"""
Structure containing the state of a single gnuplot session.
"""
mutable struct GnuplotState
  blockCnt::Int           # data blocks counter
  cmds::Vector{MultiCmd}  # gnuplot commands
  data::Vector{String}    # data blocks
  plot::Vector{MultiCmd}  # plot specifications associated to each data block
  splot::Bool             # plot / splot session
  lastDataName::String    # name of the last data block
  multiID::Int            # current multiplot index (0 if no multiplot)

  GnuplotState() = new(1, Vector{MultiCmd}(), Vector{String}(), Vector{MultiCmd}(), false, "", 0)
end


#---------------------------------------------------------------------
"""
Structure containing the global package state.
"""
mutable struct MainState
  colorOut::Symbol              # gnuplot STDOUT is printed with this color
  colorIn::Symbol               # gnuplot STDIN is printed with this color
  verboseLev::Int               # verbosity level (0 - 3), default: 3
  gnuplotCmd::String            # command used to start the gnuplot process
  startup::String               # commands automatically sent to each new gnuplot process
  procs::Vector{GnuplotProc}    # array of currently active gnuplot process and pipes
  states::Vector{GnuplotState}  # array of gnuplot sessions
  IDs::Vector{Int}              # IDs of gnuplot sessions
  curPos::Int                   # index in the procs, states and IDs array of current session

  MainState() = new(:cyan, :yellow, 3,
                    "", "",
                    Vector{GnuplotProc}(), Vector{GnuplotState}(), Vector{Int}(),
                    0)
end


######################################################################
# Private functions
######################################################################

"""
Check gnuplot is runnable with the command given in `main.gnuplotCmd`.
Also check that gnuplot version is >= 4.7 (required to use data
blocks).
"""
function checkGnuplotVersion()
    cmd = `$(main.gnuplotCmd) --version`
    out, procs = open(`$cmd`, "r")
    s = String(read(out))
    if !success(procs)
        error("An error occurred while running: " * string(cmd))
    end

    s = split(s, " ")
    ver = ""
    for token in s
        try
            ver = VersionNumber("$token")
            break
        catch
        end
    end

    if ver < v"4.7"
        error("gnuplot ver. >= 4.7 is required, but " * string(ver) * " was found.")
    end
    gp_log(1, "Found gnuplot version: " * string(ver))
end


#---------------------------------------------------------------------
"""
Logging facility (each line is prefixed with the session ID.)

Printing occur only if the logging level is >= current verbosity
level.
"""
function gp_log(level::Int, s::String; id=nothing, color=nothing)
    if (main.verboseLev < level)
        return
    end

    color == nothing  &&  (color = main.colorOut)

    prefix = ""
    if (id == nothing)  &&  (main.curPos > 0)
        id = main.IDs[main.curPos]
    end
    prefix = string("GP(", id, ")")

    a = split(s, "\n")
    for v in a
        print_with_color(color, "$prefix $v\n")
    end
end


#---------------------------------------------------------------------
"""
Read gnuplot outputs, and optionally redirect to a `Channel`.

This fuction is supposed to be run in a `Task`.
"""
function gp_readTask(sIN, channel; kw...)
    saveOutput::Bool = false
    while isopen(sIN)
        line = convert(String, readline(sIN))

        if line == "GNUPLOT_JL_SAVE_OUTPUT"
            saveOutput = true
            gp_log(4, "|start of captured data =========================")
        else
            if saveOutput
                put!(channel, line)
            end

            if line == "GNUPLOT_JL_SAVE_OUTPUT_END"
                saveOutput = false
                gp_log(4, "|end of captured data ===========================")
            elseif line != ""
                if saveOutput
                    gp_log(3, "|  " * line; kw...)
                else
                    gp_log(2, "   " * line; kw...)
                end
            end
        end
    end

    gp_log(1, "pipe closed"; kw...)
end


#---------------------------------------------------------------------
"""
Return a unique data block name
"""
function gp_mkBlockName(prefix="")
    if prefix == ""
        prefix = string("d", gp_current())
    end

    cur = main.states[main.curPos]
    name = string(prefix, "_", cur.blockCnt)
    cur.blockCnt += 1

    return name
end


#---------------------------------------------------------------------
"""
Return the GnuplotProc structure of current session, or start a new
gnuplot process if none is running.
"""
function gp_getProcOrStartIt()
    if main.curPos == 0
        gp_log(1, "Starting a new gnuplot process...")
        id = gp_new()
    end

    p = main.procs[main.curPos]

    if !Base.process_running(p.proc)
        error("The current gnuplot process is no longer running.")
    end

    return p
end


######################################################################
# Get/set package options
######################################################################

"""
Get package options.
"""
gp_getStartup() = main.startup
gp_getCmd() = main.gnuplotCmd
gp_getVerbose() = main.verboseLev


#---------------------------------------------------------------------
"""
Set package options.

Example:
```
gp_setOption(cmd="/path/to/gnuplot", verb=2, startup="set term wxt")
```
"""
function gp_setOption(;kw...)
    @AbbrvKW_check(kw,
                   cmd::Nullable{String}=nothing,
                   startup::Nullable{String}=nothing,
                   verbose::Nullable{Int}=nothing)

    if !isnull(startup)
        main.startup = get(startup)
    end

    if !isnull(cmd)
        main.gnuplotCmd = get(cmd)
        checkGnuplotVersion()
    end

    if !isnull(verbose)
        @assert (0 <= get(verbose) <= 4)
        main.verboseLev = get(verbose)
    end

    return nothing
end


######################################################################
# Handle multiple gnuplot instances
######################################################################

"""
Return an `Array{Int}` with available session IDs.
"""
function gp_IDs()
    return deepcopy(main.IDs)
end


#---------------------------------------------------------------------
"""
Return the ID of the current session.
"""
function gp_current()
    return main.IDs[main.curPos]
end


#---------------------------------------------------------------------
"""
Change the current session ID.

The list of available IDs can be retrieved with `gp_IDs`.  The ID of
the current session can be retrieved with `gp_current`.
"""
function gp_setCurrent(id)
    i = find(main.IDs .== id)
    @assert length(i) == 1
    i = i[1]
    @assert Base.process_running(main.procs[i].proc)

    main.curPos = i
end


#---------------------------------------------------------------------
"""
Create a new session (by starting a new gnuplot process), make it the
current one, and return the new ID.

Example (compare output on two terminals)
```
id1 = gp_new()
gp"set term qt"
gp"plot sin(x)"

id2 = gp_new()
gp"set term wxt"
gp"plot sin(x)"

gp_exitAll()
```
"""
function gp_new()
    if length(main.IDs) > 0
        newID = max(main.IDs...) + 1
    else
        newID = 1
    end

    if main.gnuplotCmd == ""
        gp_setOption(cmd="gnuplot")
    end

    push!(main.procs,  GnuplotProc(main.gnuplotCmd))
    push!(main.states, GnuplotState())
    push!(main.IDs, newID)
    main.curPos = length(main.IDs)

    # Start reading tasks for STDOUT and STDERR
    @async gp_readTask(main.procs[end].pout, main.procs[end].channel, id=newID)
    @async gp_readTask(main.procs[end].perr, main.procs[end].channel, id=newID)

    if main.startup != ""
        gp_cmd(main.startup)
    end

    gp_log(1, "New session started with ID $newID")
    return newID
end


#---------------------------------------------------------------------
"""
Close current session and quit the corresponding gnuplot process.
"""
function gp_exit()
    if main.curPos == 0
        return
    end

    p = main.procs[main.curPos]
    close(p.pin)
    close(p.pout)
    close(p.perr)
    wait(p.proc)
    @assert !Base.process_running(p.proc)

    gp_log(1, string("Process exited with status ", p.proc.exitcode))

    deleteat!(main.procs , main.curPos)
    deleteat!(main.states, main.curPos)
    deleteat!(main.IDs   , main.curPos)

    if length(main.IDs) > 0
        gp_setCurrent(max(main.IDs...))
    else
        main.curPos = 0
    end

    return p.proc.exitcode
end


#---------------------------------------------------------------------
"""
Repeatedly call `gp_exit` until all sessions are closed.
"""
function gp_exitAll()
    while length(main.IDs) > 0
        gp_exit()
    end
end


######################################################################
# Send data and commands to Gnuplot
######################################################################

"""
Send a command to the gnuplot process and return immediately.

If `capture = true` waits until gnuplot provide a complete reply and
return it as a `Vector{String}`.

The commands are not stored in the current session.

Example:
```
println("Current terminal: ", gp_send("print GPVAL_TERM", capture=true))
```
"""
function gp_send(cmd::String; capture=false)
    p = gp_getProcOrStartIt()

    if capture
        write(p.pin, "print 'GNUPLOT_JL_SAVE_OUTPUT'\n")
        gp_log(4, "-> Start capture", color=main.colorIn)
    end

    for s in split(cmd, "\n")
        w = write(p.pin, strip(s) * "\n")
        gp_log(2, "-> $s" , color=main.colorIn)
        w <= 0  &&  error("Writing on gnuplot STDIN pipe returned $w")
    end

    if capture
        write(p.pin, "print 'GNUPLOT_JL_SAVE_OUTPUT_END'\n")
        gp_log(4, "-> End capture", color=main.colorIn)
    end
    flush(p.pin)

    if capture
        out = Vector{String}()
        while true
            l = take!(p.channel)
            l == "GNUPLOT_JL_SAVE_OUTPUT_END"  &&  break
            push!(out, l)
        end

        length(out) == 1  &&  (out = out[1])
        return out
    end

    return nothing
end


#---------------------------------------------------------------------
"""
Call `gp_send` through a non-standard string literal.

Example:
```
println("Current terminal: ", gp"print GPVAL_TERM")
gp"plot sin(x)"

gp"
set title \\"3D surface from a grid (matrix) of Z values\\"
set xrange [-0.5:4.5]
set yrange [-0.5:4.5]

set grid
set hidden3d
\$grid << EOD
5 4 3 1 0
2 2 0 0 1
0 0 0 1 0
0 0 0 2 3
0 1 2 4 3
EOD
splot '\$grid' matrix with lines notitle
"
```
"""
macro gp_str(s::String)
    gp_send(s)
end


#---------------------------------------------------------------------
"""
Send a 'reset session' command to gnuplot and delete all commands,
data, and plots stored in the current session.
"""
function gp_reset()
    gp_send("reset session", capture=true)
    main.states[main.curPos] = GnuplotState()
    if main.startup != ""
        gp_cmd(main.startup)
    end
end


#---------------------------------------------------------------------
"""
Send a command to the gnuplot process and return immediately.  A few,
commonly used, commands may be specified through keywords.

The commands are stored in the current session and can be saved
in a file using `gp_dump`.

Example:
```
gp_cmd("set grid")
gp_cmd("set key left", xrange=(1,3))
gp_cmd(title="My title", xlab="X label", xla="Y label")
```
"""
function gp_cmd(v::String=""; kw...)
    #@show kw
    @AbbrvKW_check(kw,
                   multiID::Nullable{Int}=nothing,
                   xrange::Nullable{NTuple{2, Float64}}=nothing,
                   yrange::Nullable{NTuple{2, Float64}}=nothing,
                   zrange::Nullable{NTuple{2, Float64}}=nothing,
                   title::Nullable{String}=nothing,
                   xlabel::Nullable{String}=nothing,
                   ylabel::Nullable{String}=nothing,
                   zlabel::Nullable{String}=nothing,
                   xlog::Nullable{Bool}=nothing,
                   ylog::Nullable{Bool}=nothing,
                   zlog::Nullable{Bool}=nothing)

    gp_getProcOrStartIt()
    cur = main.states[main.curPos]
    mID = isnull(multiID)  ?  cur.multiID  :  get(multiID)

    if v != ""
        push!(cur.cmds, MultiCmd(v, mID))
        if mID == 0
            gp_send(v)
        end
    end

    isnull(xrange) ||  gp_cmd(multiID=mID, "set xrange [" * join(get(xrange), ":") * "]")
    isnull(yrange) ||  gp_cmd(multiID=mID, "set yrange [" * join(get(yrange), ":") * "]")
    isnull(zrange) ||  gp_cmd(multiID=mID, "set zrange [" * join(get(zrange), ":") * "]")

    isnull(title)  ||  gp_cmd(multiID=mID, "set title  '" * get(title ) * "'")
    isnull(xlabel) ||  gp_cmd(multiID=mID, "set xlabel '" * get(xlabel) * "'")
    isnull(ylabel) ||  gp_cmd(multiID=mID, "set ylabel '" * get(ylabel) * "'")
    isnull(zlabel) ||  gp_cmd(multiID=mID, "set zlabel '" * get(zlabel) * "'")

    isnull(xlog)   ||  gp_cmd(multiID=mID, (get(xlog)  ?  ""  :  "un") * "set logscale x")
    isnull(ylog)   ||  gp_cmd(multiID=mID, (get(ylog)  ?  ""  :  "un") * "set logscale y")
    isnull(zlog)   ||  gp_cmd(multiID=mID, (get(zlog)  ?  ""  :  "un") * "set logscale z")
end


#function gp_cmd(vec::Vector{String}; kw...)
#    for s in vec
#        gp_cmd(s)
#    end
#    if length(kw) > 0
#        gp_cmd(;kw...)
#    end
#end


#---------------------------------------------------------------------
"""
Send data to the gnuplot process using a data block, and return the
name of a data block (to be used with `gp_plot`).

The data are stored in the current session and can be saved in a file
using `gp_dump`.

Example:
```
x = collect(1.:10)
y = x.^2
name = gp_data(x, y)

# Specify a prefix for the data block name, a sequential counter will
# be appended to ensure the black names are unique
name = gp_data(x, y, pref="MyPrefix")

# Specify the whole data block name.  NOTE: avoid using the same name
# multiple times!
name = gp_data(x, y, name="MyChosenName")
```

The returned name can be used as input to `gp_plot`.
"""
function gp_data(data::Vararg{AbstractArray{T,1},N}; kw...) where {T,N}
    @AbbrvKW_check(kw, name::String="", prefix::String="")

    gp_getProcOrStartIt()
    cur = main.states[main.curPos]

    if name == ""
        name = gp_mkBlockName(prefix)
    end
    name = "\$$name"

    for i in 2:length(data)
        @assert length(data[1]) == length(data[i])
    end

    v = "$name << EOD"
    push!(cur.data, v)
    gp_send(v)
    for i in 1:length(data[1])
        v = ""
        for j in 1:length(data)
            v *= " " * string(data[j][i])
        end
        push!(cur.data, v)
        gp_send(v)
    end
    v = "EOD"
    push!(cur.data, v)
    gp_send(v)

    cur.lastDataName = name

    return name
end


#---------------------------------------------------------------------
function gp_next()
    gp_getProcOrStartIt()
    cur = main.states[main.curPos]
    cur.multiID += 1
end


#---------------------------------------------------------------------
function gp_multi(s::String="")
    gp_getProcOrStartIt()
    cur = main.states[main.curPos]
    if cur.multiID != 0
        error("Current multiplot ID is $cur.multiID, while it should be 0")
    end

    gp_next()
    gp_cmd("set multiplot $s")
end


#---------------------------------------------------------------------
"""
Add a new line to the plot/splot comand using the specifications provided
as `spec` argument.

The plot/splot commands are stored in the current session and can be
saved in a file using `gp_dump`.

Example:
```
x = collect(1.:10)

gp_data(x, x.^2)
gp_plot(last=true, "w l tit 'Pow 2'") # "" means use the last inserted data block

src = gp_data(x, x.^2.2)
gp_plot("\$src w l tit 'Pow 2.2'")

# Re use the same data block
gp_plot("\$src u 1:(\\\$2+10) w l tit 'Pow 2.2, offset=10'")

gp_dump() # Do the plot
```
"""
function gp_plot(spec::String; kw...)
    @AbbrvKW_check(kw,
                   lastData::Bool=false,
                   file::Nullable{String}=nothing,
                   multiID::Nullable{Int}=nothing,
                   splot::Nullable{Bool}=nothing)

    gp_getProcOrStartIt()
    cur = main.states[main.curPos]
    mID = isnull(multiID)  ?  cur.multiID  :  get(multiID)
    isnull(splot)  ||  (cur.splot = splot)

    src = ""
    if lastData
        src = cur.lastDataName
    elseif !isnull(file)
        src = "'" * get(file) * "'"
    end
    push!(cur.plot, MultiCmd("$src $spec", mID))
end


#---------------------------------------------------------------------
"""
Similar to `@gp`, but do not adds the calls to `gp_reset()` at the
beginning and `gp_dump()` at the end.
"""
macro gp_(args...)
    if length(args) == 0
        return :()
    end

    exprBlock = Expr(:block)

    exprData = Expr(:call)
    push!(exprData.args, :gp_data)

    pendingPlot = false
    pendingMulti = false
    for arg in args
        #println(typeof(arg), " ", arg)

        if isa(arg, Expr)  &&  (arg.head == :quote)  &&  (arg.args[1] == :next)
            push!(exprBlock.args, :(gp_next()))
        elseif isa(arg, Expr)  &&  (arg.head == :quote)  &&  (arg.args[1] == :plot)
            pendingPlot = true
        elseif isa(arg, Expr)  &&  (arg.head == :quote)  &&  (arg.args[1] == :multi)
            pendingMulti = true
        elseif (isa(arg, Expr)  &&  (arg.head == :string))  ||  isa(arg, String)
            # Either a plot or cmd string
            if pendingPlot
                if length(exprData.args) > 1
                    push!(exprBlock.args, exprData)
                    exprData = Expr(:call)
                    push!(exprData.args, :gp_data)
                end

                push!(exprBlock.args, :(gp_plot(last=true, $arg)))
                pendingPlot = false
            elseif pendingMulti
                push!(exprBlock.args, :(gp_multi($arg)))
                pendingMulti = false
            else
                push!(exprBlock.args, :(gp_cmd($arg)))
            end
        elseif (isa(arg, Expr)  &&  (arg.head == :(=)))
            # A cmd keyword
            sym = arg.args[1]
            val = arg.args[2]
            push!(exprBlock.args, :(gp_cmd($sym=$val)))
        else
            # A data set
            push!(exprData.args, arg)
            pendingPlot = true
        end
    end
    #dump(exprBlock)

    if pendingPlot  &&  length(exprData.args) >= 2
        push!(exprBlock.args, exprData)
        push!(exprBlock.args, :(gp_plot(last=true, "")))
    end

    return esc(exprBlock)
end


#---------------------------------------------------------------------
"""
Main driver for the Gnuplot.jl package

This macro expands into proper calls to `gp_reset`, `gp_cmd`,
`gp_data`, `gp_plot` and `gp_dump` in a single call, hence it is a very
simple and quick way to produce (even very complex) plots.

The syntax is as follows:
```
@gp( ["a command"],            # passed to gp_cmd
     [Symbol=(Value | Expr)]   # passed to gp_cmd as a keyword
     [one or more (Expression | Array) "plot spec"],  # passed to gp_data and gp_plot
     etc...
)
```

Note that each entry is optional.  The only mandatory sequence is the
plot specification string (to be passed to `gp_plot`) which must
follow one (or more) data block(s).  If the data block is the last
argument in the call an empty plot specification string is used.

The following example:
```
@gp "set key left" title="My title" xr=(1,5) collect(1.:10) "with lines tit 'Data'"
```
- sets the legend on the left;
- sets the title of the plot
- sets the X axis range
- pass the 1:10 range as data block
- tells gnuplot to draw the data with lines
- sets the title of the data block
...all of this is done in one line!

The above example epands as follows:
```
gp_reset()
begin
    gp_cmd("set key left")
    gp_cmd(title="My title")
    gp_cmd(xr=(1, 5))
    gp_data(collect(1.0:10))
    gp_plot(last=true, "with lines tit 'Data'")
end
gp_dump()
```


Further Example:
```
x = collect(1.:10)
@gp x
@gp x x
@gp x -x
@gp x x.^2
@gp x x.^2 "w l"

lw = 3
@gp x x.^2 "w l lw \$lw"

@gp("set grid", "set key left", xlog=true, ylog=true,
    title="My title", xlab="X label", ylab="Y label",
    x, x.^0.5, "w l tit 'Pow 0.5' dt 2 lw 2 lc rgb 'red'",
    x, x     , "w l tit 'Pow 1'   dt 1 lw 3 lc rgb 'blue'",
    x, x.^2  , "w l tit 'Pow 2'   dt 3 lw 2 lc rgb 'purple'")
```
"""
macro gp(args...)
    esc_args = Vector{Any}()
    for arg in args
        push!(esc_args, esc(arg))
    end
    e = :(@gp_($(esc_args...)))

    f = Expr(:block)
    push!(f.args, esc(:( gp_reset())))
    push!(f.args, e)
    push!(f.args, esc(:( gp_dump())))

    return f
end


"""
Print all data and commands stored in the current session on STDOUT or
on a file.
"""
function gp_dump(;kw...)
    @AbbrvKW_check(kw,
                   all::Bool=false,
                   dry::Bool=false,
                   data::Bool=false,
                   file::Nullable{String}=nothing)

    if main.curPos == 0
        return ""
    end

    if !isnull(file)
        all = true
        dry = true
    end

    cur = main.states[main.curPos]
    out = Vector{String}()

    all  &&  (push!(out, "reset session"))

    if data || all
        for s in cur.data
            push!(out, s)
        end
    end

    for id in 0:cur.multiID
        for m in cur.cmds
            if (m.id == id)  &&  ((id > 0)  ||  all)
                push!(out, m.cmd)
            end
        end

        tmp = Vector{String}()
        for m in cur.plot
            if m.id == id
                push!(tmp, m.cmd)
            end
        end

        if length(tmp) > 0
            s = cur.splot  ?  "splot "  :  "plot "
            s *= "\\\n  "
            s *= join(tmp, ", \\\n  ")
            push!(out, s)
        end
    end

    if cur.multiID > 0
        push!(out, "unset multiplot")
    end
        
    if !isnull(file)
        sOut = open(get(file), "w")
        for s in out; println(sOut, s); end
        close(sOut)
    end

    if !dry
        for s in out; gp_send(s); end
        gp_send("", capture=true)
    end

    return join(out, "\n")
end


######################################################################
# Facilities
######################################################################

gp_load(file::String) = gp_send("load '$file'", capture=true)
gp_terminals() = gp_send("print GPVAL_TERMINALS", capture=true)
gp_terminal()  = gp_send("print GPVAL_TERM", capture=true)


######################################################################
# Module initialization
######################################################################
const main = MainState()

end #module
