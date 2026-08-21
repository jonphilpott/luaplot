--[[
    tools/jog.lua — drive the head around by hand and read off where it is

    An etch-a-sketch for the plotter. Move the head with the arrow keys, raise
    and lower the pen, and watch the coordinates. It exists to answer the
    questions you cannot answer from a drawing script:

      * where is the paper, in machine coordinates?
      * how far is its corner from machine zero?
      * does the pen actually reach that corner?
      * what width and height should I pass to plotter.init?

    ── The workflow it is built around ──────────────────────────────────────────

    Jog to the near-left corner of your paper and press 0. That sets the work
    origin there, and from then on the WORK column reads distances from that
    corner while the MACHINE column keeps reading distances from machine zero.

    Now jog to the far corner: the work reading is your paper size, and the
    machine reading of the near corner is the --origin that pen-setup.lua
    wants. Both numbers, measured rather than guessed, in about a minute.

    ── Usage ────────────────────────────────────────────────────────────────────

        ./luaplot tools/jog.lua --pen-up 0 --pen-down 150 [port]

    Home first if your machine has limit switches: machine coordinates only
    mean anything once GRBL knows where it is. The tool offers to.

    ── Keys ─────────────────────────────────────────────────────────────────────

        arrows or WASD   move by the current step
        [ and ]          smaller / larger step
        1 2 3 4          step 0.1, 1, 10, 50 mm
        space            pen up / down
        0                set the work origin here (G92)
        m                go to machine zero
        o                go to the work origin
        h                home ($H)
        p                reprint the position
        q or Ctrl-C      quit, lifting the pen
--]]

local serial = require 'serial'
local grbl   = require 'grbl'

-- ── Arguments ─────────────────────────────────────────────────────────────────

local function usage(msg)
    if msg then io.stderr:write("jog: " .. msg .. "\n\n") end
    io.stderr:write([[
Usage: luaplot tools/jog.lua --pen-up N --pen-down N [port]

  --pen-up N     servo value for pen up    (required)
  --pen-down N   servo value for pen down  (required)
  --port PORT    serial port (else $LUAPLOT_PORT, else /dev/ttyUSB0)
  --baud N       baud rate (default 115200)
  --feed N       jog feed rate, mm/min (default 2000)
  --step MM      starting step size (default 1)
]])
    os.exit(msg and 1 or 0)
end

local o = {
    port = os.getenv("LUAPLOT_PORT") or "/dev/ttyUSB0",
    baud = 115200,
    feed = 2000,
    step = 1.0,
}

do
    local i = 1
    local function value(what)
        i = i + 1
        return arg[i] or usage(what .. " needs a value")
    end
    while arg[i] do
        local a = arg[i]
        if     a == "--port"     then o.port = value(a)
        elseif a == "--baud"     then o.baud = tonumber(value(a)) or usage("--baud")
        elseif a == "--pen-up"   then o.pen_up = tonumber(value(a)) or usage("--pen-up")
        elseif a == "--pen-down" then o.pen_down = tonumber(value(a)) or usage("--pen-down")
        elseif a == "--feed"     then o.feed = tonumber(value(a)) or usage("--feed")
        elseif a == "--step"     then o.step = tonumber(value(a)) or usage("--step")
        elseif a == "-h" or a == "--help" then usage()
        elseif a:match("^%-")    then usage("unknown option " .. a)
        else o.port = a
        end
        i = i + 1
    end
end

if not o.pen_up or not o.pen_down then
    io.stderr:write(
        "jog: --pen-up and --pen-down are required.\n" ..
        "  Find them with tools/servo-sweep.lua if you do not know them yet.\n")
    os.exit(1)
end

-- ── Terminal ──────────────────────────────────────────────────────────────────

--[[
    Raw mode, so a keypress arrives immediately instead of waiting for Enter.

    Done with stty rather than in C because it is two lines here and a terminal
    module there. The important part is that it is ALWAYS put back: a terminal
    left raw is an unusable shell, so every exit path from here on goes through
    restore(), including the error handler.
--]]
local function raw_mode(on)
    os.execute(on and "stty raw -echo 2>/dev/null"
                  or  "stty sane 2>/dev/null")
end

-- In raw mode the terminal no longer translates \n, so lines need \r too.
-- The parentheses matter: gsub returns the string AND a replacement count, and
-- io.write happily prints both, so an unparenthesised call litters the display
-- with stray digits.
local function say(fmt, ...)
    io.write((string.format(fmt, ...):gsub("\n", "\r\n")))
    io.flush()
end

local function key()
    local c = io.read(1)
    if c == nil then return "q" end

    -- Arrow keys arrive as ESC [ A..D
    if c == "\27" then
        local a = io.read(1)
        if a ~= "[" then return "" end
        local b = io.read(1)
        if b == "A" then return "up"    end
        if b == "B" then return "down"  end
        if b == "C" then return "right" end
        if b == "D" then return "left"  end
        return ""
    end

    if c == "\3" then return "q" end        -- Ctrl-C, which raw mode swallows
    return c:lower()
end

-- ── Machine ───────────────────────────────────────────────────────────────────

local pen_is_down = false

local function pen(down)
    serial.writeline(string.format("M3 S%d", down and o.pen_down or o.pen_up))
    serial.writeline("G4 P0.15")
    pen_is_down = down
end

--[[
    Wait for the machine to stop moving, so the position we print is the
    position it actually reached rather than one it is still on the way to.

    Capped, because a jog rejected for hitting a soft limit leaves the state
    machine somewhere unexpected and there is no sense hanging on it.
--]]
local function settle()
    for _ = 1, 200 do
        local st = grbl.status()
        if st.state == "Idle" or st.state:match("^Alarm") then return st end
    end
    return grbl.status()
end

--[[
    Jog by a relative amount.

    $J= rather than G0: jog commands are designed for exactly this, and they
    leave the modal state alone, so nothing here can change how a later plot is
    interpreted. GRBL also refuses a jog that would leave the work area when
    soft limits are on, rather than driving into the frame.
--]]
local function jog(dx, dy)
    local ok, err = pcall(serial.writeline,
        string.format("$J=G91 G21 X%.3f Y%.3f F%d", dx, dy, o.feed))
    if not ok then
        say("\n  jog refused: %s\n", tostring(err))
        return false
    end
    return true
end

local function show(st)
    st = st or grbl.status()
    say("\r\27[K  %-6s  machine %8.2f %8.2f   work %8.2f %8.2f   step %-5g  pen %s",
        st.state,
        st.mpos and st.mpos.x or 0/0, st.mpos and st.mpos.y or 0/0,
        st.wpos and st.wpos.x or 0/0, st.wpos and st.wpos.y or 0/0,
        o.step, pen_is_down and "DOWN" or "up")
end

-- ── Main ──────────────────────────────────────────────────────────────────────

say("Connecting to %s at %d baud...\n", o.port, o.baud)
serial.open(o.port, o.baud)

if not grbl.ensure_ready { moves = true } then
    io.stderr:write("\nGRBL is still locked; nothing can be moved.\n")
    serial.close()
    os.exit(1)
end

serial.writeline("G21")
serial.writeline("G90")
pen(false)

say([[

  arrows / WASD  move        [ ]  step size      1 2 3 4  0.1 / 1 / 10 / 50 mm
  space          pen up-down    0  set work origin here
  m              machine zero   o  work origin      h  home
  q              quit

]])

local STEPS = {0.1, 1, 10, 50}

--[[
    Everything from here runs inside a pcall so the terminal is restored no
    matter how the loop ends -- a serial error, a Ctrl-C, a bug. Leaving a
    shell in raw mode is a worse failure than whatever caused it.
--]]
raw_mode(true)

local ok, err = pcall(function()
    show()

    while true do
        local k = key()
        local moved = false

        if     k == "up"    or k == "w" then moved = jog(0, o.step)
        elseif k == "down"  or k == "s" then moved = jog(0, -o.step)
        elseif k == "left"  or k == "a" then moved = jog(-o.step, 0)
        elseif k == "right" or k == "d" then moved = jog(o.step, 0)

        elseif k == "[" then o.step = math.max(0.05, o.step / 2)
        elseif k == "]" then o.step = math.min(200, o.step * 2)
        elseif k:match("^[1-4]$") then o.step = STEPS[tonumber(k)]

        elseif k == " " then
            pen(not pen_is_down)

        elseif k == "0" then
            -- G92 sets the work origin here. Everything luaplot draws is in
            -- work coordinates, so this is the corner a plot will start from.
            serial.writeline("G92 X0 Y0")
            grbl.reset_wco()
            say("\n  work origin set here\n")

        elseif k == "m" then
            local was_down = pen_is_down
            if was_down then pen(false) end
            serial.writeline("G53 G0 X0 Y0")   -- G53: machine coordinates
            moved = true
            if was_down then pen(true) end

        elseif k == "o" then
            local was_down = pen_is_down
            if was_down then pen(false) end
            serial.writeline("G0 X0 Y0")
            moved = true
            if was_down then pen(true) end

        elseif k == "h" then
            say("\n  homing...\n")
            local prev = serial.set_timeout(120)
            local homed, herr = pcall(serial.writeline, "$H")
            serial.set_timeout(prev)
            if not homed then say("  homing failed: %s\n", tostring(herr)) end
            grbl.reset_wco()

        elseif k == "q" then
            break
        end

        show(moved and settle() or nil)
    end
end)

raw_mode(false)

-- Leave the machine in a sane state whatever happened
pcall(function()
    serial.writeline(string.format("M3 S%d", o.pen_up))
    serial.writeline("M5")
end)

local final = nil
pcall(function() final = grbl.status() end)

pcall(serial.close)

io.write("\n")
if final and final.mpos then
    io.write(string.format(
        "Final position:\n" ..
        "  machine  X %.2f  Y %.2f\n" ..
        "  work     X %.2f  Y %.2f\n\n" ..
        "If you set the work origin at your paper's near-left corner, the\n" ..
        "machine reading there is the --origin for pen-setup.lua, and the work\n" ..
        "reading at the far corner is your paper size.\n",
        final.mpos.x, final.mpos.y, final.wpos.x, final.wpos.y))
end

if not ok then
    io.stderr:write("jog: " .. tostring(err) .. "\n")
    os.exit(1)
end
