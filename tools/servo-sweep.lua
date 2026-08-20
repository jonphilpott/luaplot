--[[
    tools/servo-sweep.lua — find the servo values for pen up and pen down

    Everything else needs these two numbers. pen-setup.lua and calibrate.lua
    both refuse to run without them, and plotter.init warns if you plot in
    serial mode without setting them, because the built-in defaults suit some
    other machine's servo and a pen driven to the wrong position lands hard.

    This is the first thing to run on a new machine.

    ── Usage ────────────────────────────────────────────────────────────────────

        ./luaplot tools/servo-sweep.lua [port]

    Port comes from the argument, else $LUAPLOT_PORT, else the default below.

    ── Run it with no pen fitted ────────────────────────────────────────────────

    You are looking for two positions, and a pen in the holder while you sweep
    is the one thing in reach that can be damaged. Fit the pen afterwards, with
    pen-setup.lua, which lowers the holder first so you can set the height
    against the paper instead of guessing at it.

    ── What it sends ────────────────────────────────────────────────────────────

    Raw serial, deliberately: no G-code preamble, no G92, no motion of any
    kind. The only thing that ever goes down the wire is M3 S<value>. Nothing
    is written to EEPROM, so there is nothing to undo.

    The exception is the alarm state GRBL boots into when homing is enabled,
    where it refuses G-code outright. This offers to clear that with $X, which
    unlocks without homing -- safe here precisely because nothing moves.
--]]

local serial = require 'serial'
local grbl   = require 'grbl'

local port = arg[1] or os.getenv("LUAPLOT_PORT") or "/dev/ttyUSB0"
local baud = tonumber(arg[2]) or 115200

if port == "-h" or port == "--help" then
    io.write("Usage: luaplot tools/servo-sweep.lua [port] [baud]\n")
    os.exit(0)
end

io.write(string.format("Connecting to %s at %d baud...\n", port, baud))
serial.open(port, baud)

-- GRBL boots into an alarm when homing is enabled and refuses every G-code
-- word until told where it is. Nothing here moves, so unlocking is enough --
-- no need to make anyone home the machine just to waggle a servo.
if not grbl.ensure_ready { moves = false } then
    io.stderr:write("\nStill locked, so no servo command would be accepted. " ..
                    "Send $H or $X and try again.\n")
    serial.close()
    os.exit(1)
end

io.write([[
No pen in the holder for this.

Enter a servo value and watch the holder move. Blank line quits.
Typical hobby servos wired to GRBL take 0-180; start in the middle and work
outwards, so you find the travel limits before you find the ends.

You are after two numbers:
  pen_up    high enough to clear the paper on a fast move
  pen_down  where a fitted pen would just touch -- err on the high side,
            pen-setup.lua is where you fine-tune it against real paper

]])

local sent = {}

while true do
    io.write("S> ")
    io.flush()

    local line = io.read()
    if not line or line:match("^%s*$") then break end

    local v = tonumber(line)
    if not v then
        io.write("  not a number\n")
    elseif v < 0 or v > 255 then
        io.write("  outside the range a servo will accept, ignoring\n")
    else
        serial.writeline(string.format("M3 S%d", v))
        sent[#sent + 1] = v
        io.write(string.format("  sent M3 S%d\n", v))
    end
end

serial.close()

if #sent > 0 then
    io.write(string.format("\nTried: %s\n", table.concat(sent, " ")))
end

io.write([[
Nothing was moved and nothing was written to EEPROM.

Next, with those two values:
  ./luaplot tools/pen-setup.lua --pen-up N --pen-down N --paper W,H
]])
