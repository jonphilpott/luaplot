--[[
    tools/grbl-config.lua — back up, compare and restore GRBL settings

    GRBL's configuration lives in EEPROM. There is no undo, and a wrong value
    can drive the machine into its own frame, so the safe habit is to take a
    dump before changing anything and keep it.

    Usage:
        ./luaplot tools/grbl-config.lua dump    [file]  [--port P]
        ./luaplot tools/grbl-config.lua diff    <file>  [--port P]
        ./luaplot tools/grbl-config.lua restore <file>  [--port P]

    The port comes from --port, else $LUAPLOT_PORT, else the default below.

        ./luaplot tools/grbl-config.lua dump grbl-backup.txt
        ./luaplot tools/grbl-config.lua diff grbl-backup.txt
        ./luaplot tools/grbl-config.lua restore grbl-backup.txt

    dump     reads every setting with $$ and writes an annotated file, with
             $I build info and $N startup blocks alongside
    diff     compares a file against the machine and prints what differs
    restore  the same comparison, then writes only the settings that actually
             changed, after you confirm. Never blind-writes the whole file.
--]]

local serial = require 'serial'
local grbl   = require 'grbl'
local plotter = require 'plotter'

local DEFAULT_PORT = "/dev/ttyUSB0"
local BAUD = 115200

-- ── Argument parsing ──────────────────────────────────────────────────────────

local function usage(msg)
    if msg then io.stderr:write("grbl-config: " .. msg .. "\n\n") end
    io.stderr:write([[
Usage:
  luaplot tools/grbl-config.lua dump    [file]  [--port PORT] [--baud N]
  luaplot tools/grbl-config.lua diff    <file>  [--port PORT] [--baud N]
  luaplot tools/grbl-config.lua restore <file>  [--port PORT] [--baud N]

Port defaults to $LUAPLOT_PORT, then ]] .. DEFAULT_PORT .. ".\n")
    os.exit(msg and 1 or 0)
end

local function parse_args()
    local o = {
        port = os.getenv("LUAPLOT_PORT") or DEFAULT_PORT,
        baud = BAUD,
        positional = {},
    }

    local i = 1
    while arg[i] do
        local a = arg[i]
        if a == "--port" then
            i = i + 1; o.port = arg[i] or usage("--port needs a value")
        elseif a == "--baud" then
            i = i + 1; o.baud = tonumber(arg[i]) or usage("--baud needs a number")
        elseif a == "-h" or a == "--help" then
            usage()
        elseif a:match("^%-") then
            usage("unknown option " .. a)
        else
            o.positional[#o.positional + 1] = a
        end
        i = i + 1
    end

    o.command = o.positional[1]
    o.file    = o.positional[2]
    return o
end

-- ── Machine access ────────────────────────────────────────────────────────────

local function connect(o)
    io.write(string.format("Connecting to %s at %d baud...\n", o.port, o.baud))
    serial.open(o.port, o.baud)
end

--[[
    Read the full machine state.

    $$ is the settings list; $I reports firmware version and build options;
    $N reports the startup blocks. $I and $N are best-effort — some builds
    answer with an error, and that should not stop a backup of the settings
    that did come back.
--]]
local function read_machine()
    local settings, order = plotter.parse_grbl_settings(serial.query("$$"))

    local function try(cmd)
        local ok, res = pcall(serial.query, cmd)
        return ok and res or {}
    end

    return settings, order, { build = try("$I"), startup = try("$N") }
end

-- ── Commands ──────────────────────────────────────────────────────────────────

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function cmd_dump(o)
    local path = o.file or grbl.backup_filename()

    connect(o)
    local settings, order, info = read_machine()
    serial.close()

    if count(settings) == 0 then
        io.stderr:write("No settings came back from $$ — is this GRBL?\n")
        os.exit(1)
    end

    local f = assert(io.open(path, "w"))
    f:write(grbl.format_dump(settings, order, info))
    f:close()

    io.write(string.format("  read %d settings -> %s\n", count(settings), path))
end

-- Shared by diff and restore: read the file, read the machine, compare
local function compare(o)
    if not o.file then usage(o.command .. " needs a file") end

    local f = io.open(o.file, "r")
    if not f then
        io.stderr:write("Cannot read " .. o.file .. "\n")
        os.exit(1)
    end
    local wanted, _, startup = grbl.parse_dump(f:read("a"))
    f:close()

    if count(wanted) == 0 then
        io.stderr:write(o.file .. " contains no settings\n")
        os.exit(1)
    end

    connect(o)
    local current = read_machine()

    local changes, missing = grbl.diff(current, wanted)
    return current, wanted, changes, missing, startup
end

local function report(changes, missing, wanted)
    if #changes == 0 then
        io.write(string.format("  no differences (%d settings checked)\n",
                               count(wanted)))
    else
        io.write(grbl.format_changes(changes) .. "\n")
        io.write(string.format("  %d of %d settings differ\n",
                               #changes, count(wanted)))
    end

    if #missing > 0 then
        local names = {}
        for _, n in ipairs(missing) do names[#names + 1] = "$" .. n end
        io.write("  not present on this machine, skipping: " ..
                 table.concat(names, " ") .. "\n")
    end
end

local function cmd_diff(o)
    local _, wanted, changes, missing = compare(o)
    serial.close()
    report(changes, missing, wanted)
end

local function cmd_restore(o)
    local _, wanted, changes, missing, startup = compare(o)
    report(changes, missing, wanted)

    if #changes == 0 then
        serial.close()
        return
    end

    if not grbl.confirm(string.format("\nApply %d change(s)?", #changes)) then
        io.write("  cancelled, nothing written\n")
        serial.close()
        return
    end

    for _, c in ipairs(changes) do
        plotter.grbl_set(c.n, grbl.format_value(c.to))
        io.write(string.format("  -> $%d=%s  ok\n", c.n, grbl.format_value(c.to)))
    end

    for _, s in ipairs(startup) do
        serial.writeline(string.format("$N%d=%s", s.index, s.code))
        io.write(string.format("  -> $N%d=%s  ok\n", s.index, s.code))
    end

    serial.close()
    io.write("  done\n")
end

-- ── Entry point ───────────────────────────────────────────────────────────────

local o = parse_args()

if     o.command == "dump"    then cmd_dump(o)
elseif o.command == "diff"    then cmd_diff(o)
elseif o.command == "restore" then cmd_restore(o)
elseif o.command == nil       then usage("no command given")
else                               usage("unknown command " .. o.command)
end
