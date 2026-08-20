--[[
    tools/calibrate.lua — set GRBL's steps-per-mm from a measured line

    If your plotter draws a 100 mm line that measures 98.4 mm, its idea of how
    many motor steps make a millimetre is wrong. GRBL stores that as $100 for
    X and $101 for Y, and the correction is a straight ratio:

        new_steps_per_mm = old_steps_per_mm * (commanded / measured)

    Draw shorter than asked, and the machine needs MORE steps per mm.

    Usage:
        ./luaplot tools/calibrate.lua [port] [options]

        --port PORT      serial port (else $LUAPLOT_PORT, else the default)
        --baud N         baud rate (default 115200)
        --pen-up N       servo value for pen up
        --pen-down N     servo value for pen down
        --length MM      reference line length (default 100)
        --feed N         drawing feed rate (default 1000)
        --origin X,Y     where to start drawing (default 20,20)
        --no-backup      skip the automatic settings backup (not advised)

    A timestamped backup of every setting is written before anything is
    changed, so a bad calibration is one `grbl-config.lua restore` away from
    being undone.

    Measure between the two tick marks, not the line's painted ends: a pen
    leaves a blob where it sets down and lifts, and the ticks mark the exact
    commanded endpoints.
--]]

local serial = require 'serial'
local grbl   = require 'grbl'
local plotter = require 'plotter'

local DEFAULTS = {
    port   = os.getenv("LUAPLOT_PORT") or "/dev/ttyUSB0",
    baud   = 115200,
    length = 100,
    feed   = 1000,
    ox     = 20,
    oy     = 20,
}

-- A measurement further out than this is a typo or a wrong ruler, not a
-- calibration — refuse it rather than write a wild value to EEPROM.
local MAX_ERROR = 0.20

-- ── Arguments ─────────────────────────────────────────────────────────────────

local function usage(msg)
    if msg then io.stderr:write("calibrate: " .. msg .. "\n\n") end
    io.stderr:write([[
Usage: luaplot tools/calibrate.lua [port] [options]

  --port PORT     serial port (else $LUAPLOT_PORT, else /dev/ttyUSB0)
  --baud N        baud rate (default 115200)
  --pen-up N      servo value for pen up
  --pen-down N    servo value for pen down
  --length MM     reference line length (default 100)
  --feed N        feed rate (default 1000)
  --origin X,Y    start corner (default 20,20)
  --no-backup     do not write a settings backup first
]])
    os.exit(msg and 1 or 0)
end

local function parse_args()
    local o = {
        port = DEFAULTS.port, baud = DEFAULTS.baud,
        length = DEFAULTS.length, feed = DEFAULTS.feed,
        ox = DEFAULTS.ox, oy = DEFAULTS.oy,
        backup = true,
    }

    local function value(i, what)
        return arg[i] or usage(what .. " needs a value")
    end

    local i = 1
    while arg[i] do
        local a = arg[i]
        if     a == "--port"     then i = i + 1; o.port = value(i, a)
        elseif a == "--baud"     then i = i + 1; o.baud = tonumber(value(i, a))
        elseif a == "--pen-up"   then i = i + 1; o.pen_up = tonumber(value(i, a))
        elseif a == "--pen-down" then i = i + 1; o.pen_down = tonumber(value(i, a))
        elseif a == "--length"   then i = i + 1; o.length = tonumber(value(i, a))
        elseif a == "--feed"     then i = i + 1; o.feed = tonumber(value(i, a))
        elseif a == "--origin"   then
            i = i + 1
            local x, y = value(i, a):match("^([%-%d%.]+),([%-%d%.]+)$")
            if not x then usage("--origin wants X,Y") end
            o.ox, o.oy = tonumber(x), tonumber(y)
        elseif a == "--no-backup" then o.backup = false
        elseif a == "-h" or a == "--help" then usage()
        elseif a:match("^%-") then usage("unknown option " .. a)
        else o.port = a          -- bare positional is the port
        end
        i = i + 1
    end

    if not o.length or o.length <= 0 then usage("--length must be positive") end
    return o
end

-- ── Drawing ───────────────────────────────────────────────────────────────────

--[[
    Draw one reference line with a tick at each end.

    Deliberately built from raw G-code rather than plotter primitives.
    Calibration has to command an exact physical distance, and going through
    the drawing API would put the transform stack and the Y-flip between the
    number typed here and the number the machine receives. Relative moves (G91)
    make the commanded length unambiguous.

    axis is "X" or "Y"; the ticks run perpendicular to it.
--]]
local function draw_reference(o, axis)
    local TICK = 5
    local cross = (axis == "X") and "Y" or "X"

    local function g(cmd) serial.writeline(cmd) end

    g("G21")                                     -- mm
    g("G90")                                     -- absolute
    g(string.format("M3 S%d", o.pen_up))
    g("G4 P0.3")

    -- Park at the start corner. Y is sent as-is: this tool works in machine
    -- coordinates, with no page-height flip.
    g(string.format("G0 X%.3f Y%.3f", o.ox, o.oy))

    g(string.format("M3 S%d", o.pen_down))
    g("G4 P0.3")

    g("G91")                                     -- relative from here

    -- Starting tick, centred on the origin
    g(string.format("G1 %s%.3f F%d", cross,  TICK * 0.5, o.feed))
    g(string.format("G1 %s%.3f F%d", cross, -TICK,       o.feed))
    g(string.format("G1 %s%.3f F%d", cross,  TICK * 0.5, o.feed))

    -- The measured span
    g(string.format("G1 %s%.3f F%d", axis, o.length, o.feed))

    -- Closing tick
    g(string.format("G1 %s%.3f F%d", cross,  TICK * 0.5, o.feed))
    g(string.format("G1 %s%.3f F%d", cross, -TICK,       o.feed))
    g(string.format("G1 %s%.3f F%d", cross,  TICK * 0.5, o.feed))

    g("G90")                                     -- back to absolute
    g(string.format("M3 S%d", o.pen_up))
    g("G4 P0.3")
    g("G0 X0 Y0")
end

-- ── Measurement ───────────────────────────────────────────────────────────────

--[[
    Ask for the measured length and turn it into a corrected steps/mm.

    Returns the new value, or nil if the user skipped this axis.
    A measurement more than MAX_ERROR off is rejected and re-asked: at that
    point something else is wrong (wrong axis measured, mm vs inches, a slipped
    belt) and scaling the setting would only bury the real fault.
--]]
local function ask_measurement(axis, commanded, old_steps)
    while true do
        io.write(string.format(
            "Measure the %s line tick-to-tick and enter the actual length in mm\n" ..
            "  (blank to skip this axis): ", axis))
        io.flush()

        local input = io.read()
        if input == nil then return nil end

        input = input:gsub("^%s+", ""):gsub("%s+$", "")
        if input == "" then
            io.write("  skipped\n\n")
            return nil
        end

        local measured = tonumber(input)

        if not measured then
            io.write("  not a number, try again\n")
        elseif measured <= 0 then
            io.write("  must be positive\n")
        elseif math.abs(measured - commanded) / commanded > MAX_ERROR then
            io.write(string.format(
                "  %.3f mm is more than %.0f%% off the commanded %.3f mm.\n" ..
                "  That is too far out to be a steps/mm error — check you are\n" ..
                "  measuring the right axis in mm, then try again.\n",
                measured, MAX_ERROR * 100, commanded))
        else
            local new_steps = old_steps * (commanded / measured)
            local pct = (new_steps / old_steps - 1) * 100
            io.write(string.format("  %s: %.3f -> %.3f  (%+.2f%%)\n\n",
                axis, old_steps, new_steps, pct))
            return new_steps
        end
    end
end

-- ── Main ──────────────────────────────────────────────────────────────────────

local o = parse_args()

if not o.pen_up or not o.pen_down then
    io.stderr:write(
        "calibrate: --pen-up and --pen-down are required.\n" ..
        "  These are the M3 S values that lift and lower your pen. If you do\n" ..
        "  not know them yet, find them first with plotter.servo() — see the\n" ..
        "  Calibration section of docs/index.html.\n")
    os.exit(1)
end

io.write(string.format("Connecting to %s at %d baud...\n", o.port, o.baud))
serial.open(o.port, o.baud)

-- Calibration draws reference lines, so the head moves: offer homing rather
-- than a bare unlock, which would leave GRBL guessing at its own position.
if not grbl.ensure_ready { moves = true } then
    io.stderr:write("\nGRBL is still locked; nothing can be moved.\n")
    serial.close()
    os.exit(1)
end

local settings, order, info
do
    local lines = serial.query("$$")
    settings, order = plotter.parse_grbl_settings(lines)

    local function try(cmd)
        local ok, res = pcall(serial.query, cmd)
        return ok and res or {}
    end
    info = { build = try("$I"), startup = try("$N") }
end

local x_old = settings[grbl.X_STEPS_PER_MM]
local y_old = settings[grbl.Y_STEPS_PER_MM]

if not x_old or not y_old then
    io.stderr:write("Could not read $100/$101 from the machine.\n")
    serial.close()
    os.exit(1)
end

io.write("Current GRBL settings:\n")
io.write(string.format("  $100 (%s) = %.3f\n", grbl.describe(100), x_old))
io.write(string.format("  $101 (%s) = %.3f\n\n", grbl.describe(101), y_old))

-- Back up before anything can be written
if o.backup then
    local path = grbl.backup_filename("grbl-backup")
    local f = assert(io.open(path, "w"))
    f:write(grbl.format_dump(settings, order, info))
    f:close()
    io.write(string.format("Backup written to %s\n" ..
        "  (restore with: luaplot tools/grbl-config.lua restore %s)\n\n",
        path, path))
end

io.write("Load a pen and paper, then press Enter to draw the reference lines. ")
io.flush()
io.read()

io.write(string.format("\nDrawing %.3f mm X reference line...\n", o.length))
draw_reference(o, "X")
local x_new = ask_measurement("X", o.length, x_old)

io.write(string.format("Drawing %.3f mm Y reference line...\n", o.length))
draw_reference(o, "Y")
local y_new = ask_measurement("Y", o.length, y_old)

-- ── Apply ─────────────────────────────────────────────────────────────────────

local changes = {}
if x_new then changes[#changes + 1] = { n = 100, from = x_old, to = x_new } end
if y_new then changes[#changes + 1] = { n = 101, from = y_old, to = y_new } end

if #changes == 0 then
    io.write("Nothing measured, leaving the machine alone.\n")
    serial.close()
    os.exit(0)
end

io.write("Pending changes:\n")
io.write(grbl.format_changes(changes) .. "\n\n")

if not grbl.confirm("Write these to GRBL?") then
    io.write("  cancelled, nothing written\n")
    serial.close()
    os.exit(0)
end

for _, c in ipairs(changes) do
    local v = string.format("%.3f", c.to)
    plotter.grbl_set(c.n, v)
    io.write(string.format("  -> $%d=%s  ok\n", c.n, v))
end

-- ── Verify ────────────────────────────────────────────────────────────────────

io.write("\n")
if grbl.confirm("Re-draw the reference lines to verify?") then
    io.write("\nLoad fresh paper, then press Enter. ")
    io.flush()
    io.read()

    io.write(string.format("Drawing %.3f mm X reference line...\n", o.length))
    draw_reference(o, "X")
    io.write(string.format("Drawing %.3f mm Y reference line...\n", o.length))
    draw_reference(o, "Y")

    io.write(string.format(
        "\nBoth lines should now measure %.3f mm tick to tick.\n" ..
        "If they still do not, run this again — the correction is a ratio, so\n" ..
        "a second pass converges quickly.\n", o.length))
end

serial.close()
io.write("\nDone.\n")
