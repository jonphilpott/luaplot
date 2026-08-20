--[[
    tools/pen-setup.lua — fit the pen, then check it reaches the paper everywhere

    Two jobs, in the order you actually need them.

    1. ATTACH.  The head moves to the middle of the paper and lowers to the
       pen-down position with nothing fitted.  You slide the pen into the
       holder until the nib just touches, and tighten it there.  Setting the
       height with the holder already up is guesswork; setting it with the
       holder down is not.

    2. SURVEY.  The head then visits a grid of points across the paper and
       lowers at each one, pausing so you can look.  This is bed levelling,
       borrowed from 3D printing and for the same reason: a plotter bed is
       never flat, and a pen set perfectly at the centre can be floating at one
       corner and gouging at another.  You are looking for the nib to just
       kiss the paper at every point.

       Shim the low corners, or split the difference and accept a slightly
       heavier line on one side.

    3. VERIFY.  Finally it revisits every point and puts a dot down without
       stopping.  Nine dots of even weight means you are level; a missing dot
       means the pen never reached, and a blot means it is pressing hard.  That
       sheet is the record -- keep it.

    ── Usage ────────────────────────────────────────────────────────────────────

        ./luaplot tools/pen-setup.lua [port] --pen-up 0 --pen-down 150

        --port PORT      serial port (else $LUAPLOT_PORT, else the default)
        --baud N         baud rate (default 115200)
        --pen-up N       servo value for pen up      (required)
        --pen-down N     servo value for pen down    (required)
        --paper W,H      paper size in mm            (default 200,200)
        --origin X,Y     machine coordinates of the paper's near-left corner
                         (default 0,0)
        --margin MM      inset of the grid from the paper edge (default 20)
        --grid N         N by N points               (default 3)
        --feed N         feed rate for the dot pass  (default 1000)
        --dwell S        seconds held down on the verify pass (default 0.4)
        --home           run a GRBL homing cycle first
        --skip-attach    go straight to the survey

    ── Coordinates ──────────────────────────────────────────────────────────────

    This tool works in MACHINE coordinates throughout: Y up, origin at machine
    zero, no page flip.  What it prints is exactly what the controller
    receives, so there is never a question of which end of the bed you are
    looking at.  That is different from a drawing script, where plotter.lua
    flips Y for you.

    Run with --home first if you want the numbers to mean the same thing
    tomorrow.
--]]

local serial = require 'serial'
local grbl   = require 'grbl'
local util   = require 'util'

local DEFAULTS = {
    port   = os.getenv("LUAPLOT_PORT") or "/dev/ttyUSB0",
    baud   = 115200,
    paper  = {200, 200},
    origin = {0, 0},
    margin = 20,
    grid   = 3,
    feed   = 1000,
    dwell  = 0.4,
}

-- ── Arguments ─────────────────────────────────────────────────────────────────

local function usage(msg)
    if msg then io.stderr:write("pen-setup: " .. msg .. "\n\n") end
    io.stderr:write([[
Usage: luaplot tools/pen-setup.lua [port] --pen-up N --pen-down N [options]

  --port PORT      serial port (else $LUAPLOT_PORT, else /dev/ttyUSB0)
  --baud N         baud rate (default 115200)
  --pen-up N       servo value for pen up    (required)
  --pen-down N     servo value for pen down  (required)
  --paper W,H      paper size in mm (default 200,200)
  --origin X,Y     machine coords of the paper's near-left corner (default 0,0)
  --margin MM      inset of the grid from the paper edge (default 20)
  --grid N         N by N points (default 3)
  --feed N         feed rate (default 1000)
  --dwell S        seconds held down on the verify pass (default 0.4)
  --home           run a GRBL homing cycle first
  --skip-attach    go straight to the survey
]])
    os.exit(msg and 1 or 0)
end

local function pair(text, what)
    local a, b = text:match("^%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*$")
    if not a then usage(what .. " wants two numbers, as W,H") end
    return {tonumber(a), tonumber(b)}
end

local function parse_args()
    local o = {
        port = DEFAULTS.port, baud = DEFAULTS.baud,
        paper = DEFAULTS.paper, origin = DEFAULTS.origin,
        margin = DEFAULTS.margin, grid = DEFAULTS.grid,
        feed = DEFAULTS.feed, dwell = DEFAULTS.dwell,
        home = false, attach = true,
    }

    local i = 1
    local function value(what)
        i = i + 1
        return arg[i] or usage(what .. " needs a value")
    end

    while arg[i] do
        local a = arg[i]
        if     a == "--port"     then o.port   = value(a)
        elseif a == "--baud"     then o.baud   = tonumber(value(a)) or usage("--baud")
        elseif a == "--pen-up"   then o.pen_up = tonumber(value(a)) or usage("--pen-up")
        elseif a == "--pen-down" then o.pen_down = tonumber(value(a)) or usage("--pen-down")
        elseif a == "--paper"    then o.paper  = pair(value(a), "--paper")
        elseif a == "--origin"   then o.origin = pair(value(a), "--origin")
        elseif a == "--margin"   then o.margin = tonumber(value(a)) or usage("--margin")
        elseif a == "--grid"     then o.grid   = tonumber(value(a)) or usage("--grid")
        elseif a == "--feed"     then o.feed   = tonumber(value(a)) or usage("--feed")
        elseif a == "--dwell"    then o.dwell  = tonumber(value(a)) or usage("--dwell")
        elseif a == "--home"     then o.home   = true
        elseif a == "--skip-attach" then o.attach = false
        elseif a == "-h" or a == "--help" then usage()
        elseif a:match("^%-")    then usage("unknown option " .. a)
        else o.port = a                       -- bare positional is the port
        end
        i = i + 1
    end

    if o.grid < 2 then usage("--grid needs to be at least 2") end
    if o.paper[1] <= 0 or o.paper[2] <= 0 then usage("--paper must be positive") end
    if o.margin * 2 >= math.min(o.paper[1], o.paper[2]) then
        usage("--margin is more than half the paper; the grid would collapse")
    end

    return o
end

-- ── Machine control ───────────────────────────────────────────────────────────

local o = parse_args()

local function g(cmd) serial.writeline(cmd) end

local function pen_up()
    g(string.format("M3 S%d", o.pen_up))
    g("G4 P0.3")
end

local function pen_down()
    g(string.format("M3 S%d", o.pen_down))
    g("G4 P0.3")
end

-- Rapid to a machine position with the pen clear
local function goto_point(p)
    pen_up()
    g(string.format("G0 X%.3f Y%.3f", p.x, p.y))
end

--[[
    The grid of points across the paper, inset by margin, in machine
    coordinates.

    util.grid is row-major starting at its own origin, which here means row by
    row from nearest the operator (lowest machine Y), left to right.
    Predictable beats efficient: a person is following along and pressing
    Enter, and nine points is not enough travel to be worth optimising.
--]]
local function grid_points()
    local n = o.grid
    local inset = util.grid(o.paper[1] - 2 * o.margin,
                            o.paper[2] - 2 * o.margin, n, n)

    local pts = {}
    for i, p in ipairs(inset) do
        pts[i] = {
            x   = o.origin[1] + o.margin + p[1],
            y   = o.origin[2] + o.margin + p[2],
            row = math.floor((i - 1) / n) + 1,
            col = ((i - 1) % n) + 1,
        }
    end
    return pts
end

--[[
    Prompt and interpret the reply.

    Returns "next", "repeat", "finish" or "abort". Anything unrecognised means
    next, because the common case is a bare Enter and nobody should have to
    read the key list to get through nine points.
--]]
local function ask(prompt)
    io.write(prompt)
    io.flush()

    local line = io.read()
    if line == nil then return "abort" end        -- stdin closed

    local key = line:lower():gsub("%s", "")
    if key == "r" then return "repeat" end
    if key == "q" then return "finish" end
    if key == "x" then return "abort" end
    return "next"
end

local function shutdown(message)
    pen_up()
    g("G0 X0 Y0")
    g("M5")
    serial.close()
    if message then io.write(message) end
end

-- ── Run ───────────────────────────────────────────────────────────────────────

if not o.pen_up or not o.pen_down then
    io.stderr:write(
        "pen-setup: --pen-up and --pen-down are required.\n" ..
        "  These are the M3 S values that lift and lower your pen holder.\n" ..
        "  If you do not know them yet, find them with plotter.servo() -- see\n" ..
        "  the Calibration section of docs/index.html.\n")
    os.exit(1)
end

local points = grid_points()

io.write(string.format("Connecting to %s at %d baud...\n", o.port, o.baud))
serial.open(o.port, o.baud)

if o.home then
    io.write("Homing ($H) -- this can take 30 seconds...\n")
    local prev = serial.set_timeout(120)
    serial.writeline("$H")
    serial.set_timeout(prev)
elseif not grbl.ensure_ready { moves = true } then
    -- This tool drives the head across the paper, so homing is offered first:
    -- $X clears the alarm but leaves GRBL with no idea where the machine is.
    io.stderr:write("\nGRBL is still locked; nothing can be moved.\n")
    serial.close()
    os.exit(1)
end

g("G21")            -- mm
g("G90")            -- absolute

io.write(string.format(
    "\nPaper %g x %g mm, near-left corner at machine (%g, %g).\n" ..
    "%d x %d grid, inset %g mm -- %d points from (%.1f, %.1f) to (%.1f, %.1f).\n",
    o.paper[1], o.paper[2], o.origin[1], o.origin[2],
    o.grid, o.grid, o.margin, #points,
    points[1].x, points[1].y, points[#points].x, points[#points].y))

-- ── 1. Attach ─────────────────────────────────────────────────────────────────

if o.attach then
    local centre = {
        x = o.origin[1] + o.paper[1] / 2,
        y = o.origin[2] + o.paper[2] / 2,
    }

    io.write(string.format(
        "\n-- Attach --------------------------------------------------------\n" ..
        "Moving to the middle of the paper (%.1f, %.1f) and lowering the\n" ..
        "holder. Fit the pen so the nib just touches, then tighten it.\n",
        centre.x, centre.y))

    goto_point(centre)
    pen_down()

    if ask("\nPen fitted? [Enter to continue, x to abort] ") == "abort" then
        shutdown("\nAborted. Pen up, head parked.\n")
        os.exit(0)
    end
end

-- ── 2. Survey ─────────────────────────────────────────────────────────────────

io.write(string.format(
    "\n-- Survey --------------------------------------------------------\n" ..
    "Visiting %d points with the pen down. At each one, check the nib just\n" ..
    "touches -- not floating, not pressing.\n" ..
    "  Enter  next point      r  lower again here\n" ..
    "  q      skip to the dot pass      x  abort\n", #points))

local aborted = false

for i, p in ipairs(points) do
    goto_point(p)
    pen_down()

    local done = false
    repeat
        local answer = ask(string.format(
            "  point %d/%d  (row %d, col %d)  X%.1f Y%.1f  > ",
            i, #points, p.row, p.col, p.x, p.y))

        if answer == "repeat" then
            -- Lift and lower again, so you can watch the nib land after
            -- adjusting a shim without moving off the point
            pen_up()
            pen_down()
        elseif answer == "finish" then
            done, aborted = true, false
            goto survey_done
        elseif answer == "abort" then
            aborted = true
            goto survey_done
        else
            done = true
        end
    until done
end

::survey_done::

if aborted then
    shutdown("\nAborted. Pen up, head parked.\n")
    os.exit(0)
end

-- ── 3. Verify ─────────────────────────────────────────────────────────────────

io.write(string.format(
    "\n-- Verify --------------------------------------------------------\n" ..
    "Putting a dot at all %d points, no stopping. Even weight everywhere\n" ..
    "means you are level: a missing dot is a point the pen never reached, a\n" ..
    "blot is one where it presses hard.\n", #points))

if ask("\nPaper in place? [Enter to draw, x to skip] ") == "abort" then
    shutdown("\nSkipped. Pen up, head parked.\n")
    os.exit(0)
end

g(string.format("F%d", o.feed))

for i, p in ipairs(points) do
    io.write(string.format("  dot %d/%d at X%.1f Y%.1f\n", i, #points, p.x, p.y))
    goto_point(p)
    pen_down()
    g(string.format("G4 P%.3f", o.dwell))
    pen_up()
end

shutdown(string.format(
    "\nDone -- %d dots. Hold the sheet up to the light: if any are faint or\n" ..
    "missing, shim that corner of the bed and run this again.\n", #points))
