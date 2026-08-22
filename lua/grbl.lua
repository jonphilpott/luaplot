--[[
    grbl.lua — GRBL 1.1 settings: naming, dumping, parsing, diffing

    GRBL keeps its configuration in EEPROM as a flat list of numbered settings
    ($0, $1, $100, ...).  They survive power cycles, there is no undo, and a
    wrong $100 will happily drive the machine into its own frame.  So the rule
    this module exists to enforce is: read and back up before you write.

    Reading and writing the machine is plotter.grbl_settings() and
    plotter.grbl_set(); everything here is pure data handling, which means it
    can be tested against canned responses without hardware.

    Used by tools/grbl-config.lua (dump / diff / restore) and by
    tools/calibrate.lua, which takes an automatic backup before touching
    $100/$101.
--]]

local M = {}

--[[
    Human-readable names for GRBL 1.1's settings.

    Dumps are annotated with these so a backup file is readable a year later,
    when "$27=1.000" on its own means nothing.
--]]
M.SETTING_NAMES = {
    [0]   = "Step pulse time (microseconds)",
    [1]   = "Step idle delay (ms)",
    [2]   = "Step pulse invert (mask)",
    [3]   = "Step direction invert (mask)",
    [4]   = "Invert step enable pin (bool)",
    [5]   = "Invert limit pins (bool)",
    [6]   = "Invert probe pin (bool)",
    [10]  = "Status report options (mask)",
    [11]  = "Junction deviation (mm)",
    [12]  = "Arc tolerance (mm)",
    [13]  = "Report in inches (bool)",
    [20]  = "Soft limits enable (bool)",
    [21]  = "Hard limits enable (bool)",
    [22]  = "Homing cycle enable (bool)",
    [23]  = "Homing direction invert (mask)",
    [24]  = "Homing locate feed rate (mm/min)",
    [25]  = "Homing search seek rate (mm/min)",
    [26]  = "Homing switch debounce delay (ms)",
    [27]  = "Homing switch pull-off distance (mm)",
    [30]  = "Maximum spindle speed (RPM)",
    [31]  = "Minimum spindle speed (RPM)",
    [32]  = "Laser-mode enable (bool)",
    [100] = "X steps/mm",
    [101] = "Y steps/mm",
    [102] = "Z steps/mm",
    [110] = "X max rate (mm/min)",
    [111] = "Y max rate (mm/min)",
    [112] = "Z max rate (mm/min)",
    [120] = "X acceleration (mm/sec^2)",
    [121] = "Y acceleration (mm/sec^2)",
    [122] = "Z acceleration (mm/sec^2)",
    [130] = "X max travel (mm)",
    [131] = "Y max travel (mm)",
    [132] = "Z max travel (mm)",
}

-- The two settings the calibration tool adjusts
M.X_STEPS_PER_MM = 100
M.Y_STEPS_PER_MM = 101

function M.describe(n)
    return M.SETTING_NAMES[n] or "(unknown setting)"
end

--[[
    Format a value the way GRBL itself does.

    Integers print without a decimal point, everything else to three places.
    Matters because the dump is meant to round-trip: reading back a value we
    wrote should produce no spurious diff.
--]]
function M.format_value(v)
    if v == math.floor(v) and math.abs(v) < 1e15 then
        return string.format("%d", v)
    end
    return string.format("%.3f", v)
end

--[[
    format_dump(settings, order, info) -> string

    Render an annotated, re-loadable backup file.

    settings  { [100] = 80.0, ... }
    order     setting numbers in the order the machine reported them (optional;
              sorted numerically if absent)
    info      optional table:
                build    list of $I response lines
                startup  list of $N response lines
--]]
function M.format_dump(settings, order, info)
    info = info or {}

    local keys = {}
    if order and #order > 0 then
        for _, k in ipairs(order) do keys[#keys + 1] = k end
    else
        for k in pairs(settings) do keys[#keys + 1] = k end
        table.sort(keys)
    end

    local out = {}
    local function w(s) out[#out + 1] = s end

    w("# luaplot GRBL configuration backup")
    w("# written: " .. os.date("%Y-%m-%d %H:%M:%S"))

    if info.build and #info.build > 0 then
        for _, line in ipairs(info.build) do
            w("# machine: " .. line)
        end
    end

    w("#")
    w("# Restore with:")
    w("#   ./luaplot tools/grbl-config.lua restore <this file>")
    w("")

    for _, k in ipairs(keys) do
        local v = settings[k]
        if v then
            w(string.format("%-16s # %s",
                string.format("$%d=%s", k, M.format_value(v)), M.describe(k)))
        end
    end

    -- Startup blocks are G-code lines GRBL runs on reset. They are restorable,
    -- unlike $I build info, which is a property of the firmware.
    if info.startup and #info.startup > 0 then
        w("")
        w("# Startup blocks")
        for _, line in ipairs(info.startup) do
            local n, code = line:match("^%s*%$N(%d)%s*=%s*(.*)$")
            if n then w(string.format("$N%s=%s", n, code)) end
        end
    end

    w("")
    return table.concat(out, "\n")
end

--[[
    parse_dump(text) -> settings, order, startup

    Read back a file produced by format_dump.  Comments (everything from '#')
    and blank lines are ignored, so a hand-edited file works too.
--]]
function M.parse_dump(text)
    local settings, order, startup = {}, {}, {}

    for line in text:gmatch("[^\r\n]+") do
        local body = line:gsub("#.*$", "")

        local sn, scode = body:match("^%s*%$N(%d)%s*=%s*(.-)%s*$")
        if sn then
            startup[#startup + 1] = { index = tonumber(sn), code = scode }
        else
            local n, v = body:match("^%s*%$(%d+)%s*=%s*([%-%d%.]+)%s*$")
            if n then
                local key = tonumber(n)
                if settings[key] == nil then order[#order + 1] = key end
                settings[key] = tonumber(v)
            end
        end
    end

    return settings, order, startup
end

--[[
    diff(current, wanted) -> changes, missing

    changes  list of { n = number, from = value, to = value } for settings that
             exist in both and disagree
    missing  setting numbers present in `wanted` that the machine did not
             report — a different GRBL build, most likely, so they are listed
             rather than silently written

    Values are compared with a small tolerance: GRBL reports three decimals, so
    a value that round-tripped through the file can differ in the last bit
    without meaning anything.
--]]
function M.diff(current, wanted)
    local changes, missing = {}, {}

    local keys = {}
    for k in pairs(wanted) do keys[#keys + 1] = k end
    table.sort(keys)

    for _, k in ipairs(keys) do
        if current[k] == nil then
            missing[#missing + 1] = k
        elseif math.abs(current[k] - wanted[k]) > 1e-4 then
            changes[#changes + 1] = { n = k, from = current[k], to = wanted[k] }
        end
    end

    return changes, missing
end

--[[
    format_changes(changes) -> string

    The shared before/after display, so dump, diff, restore and calibrate all
    present a pending change the same way.
--]]
function M.format_changes(changes)
    local out = {}
    for _, c in ipairs(changes) do
        out[#out + 1] = string.format("  $%-4d %-10s -> %-10s (%s)",
            c.n, M.format_value(c.from), M.format_value(c.to), M.describe(c.n))
    end
    return table.concat(out, "\n")
end

--[[
    backup_filename(prefix) -> string

    A timestamped name, so an automatic backup never overwrites an earlier one.
--]]
function M.backup_filename(prefix)
    return string.format("%s-%s.txt", prefix or "grbl-backup",
                         os.date("%Y%m%d-%H%M%S"))
end

--[[
    is_locked() -> boolean

    Whether GRBL is refusing G-code because it is in an alarm state.

    Probed by sending G4 P0 -- a zero-length dwell, which does nothing at all
    if it is accepted and fails with error:9 if it is not. The obvious probe,
    the ? status query, is a realtime command that never answers "ok", so
    writeline would sit there until it timed out.
--]]
function M.is_locked()
    local serial = require 'serial'
    local ok, err = pcall(serial.writeline, "G4 P0")
    if ok then return false end
    return tostring(err):match("error:9") ~= nil, err
end

--[[
    ensure_ready(opts) -> boolean

    Clear the alarm GRBL boots into when homing is enabled, so the caller can
    get on with sending G-code. Returns false if it is still locked.

    opts.moves    true if the caller is about to move the machine. Homing is
                  then offered first, because $X leaves GRBL with no idea where
                  it is -- fine for waggling a servo, not for driving the head
                  somewhere.
    opts.assume_yes  skip the prompts and unlock.
--]]
function M.ensure_ready(opts)
    opts = opts or {}

    local locked = M.is_locked()
    if not locked then return true end

    local serial = require 'serial'

    io.write([[

GRBL is in an alarm state and is refusing G-code.

That is normal right after power-on when homing is enabled ($22=1): the
controller does not know where the machine is, so it will not move until you
tell it.
]])

    if opts.moves then
        io.write([[
  $H  home the machine, establishing a known position   (recommended)
  $X  unlock without homing -- position stays unknown

]])
        if opts.assume_yes or M.confirm("Home the machine now ($H)?") then
            local prev = serial.set_timeout(120)
            local ok, err = pcall(serial.writeline, "$H")
            serial.set_timeout(prev)
            if ok then
                io.write("  homed\n")
                return true
            end
            io.write("  homing failed: " .. tostring(err) .. "\n")
        end
    end

    if opts.assume_yes or M.confirm("Unlock without homing ($X)?") then
        local ok, err = pcall(serial.writeline, "$X")
        if ok then
            io.write("  unlocked\n")
            return true
        end
        io.write("  unlock failed: " .. tostring(err) .. "\n")
    end

    return false
end

-- ── Status reports ────────────────────────────────────────────────────────────

--[[
    GRBL sends the work coordinate offset only occasionally -- roughly every
    tenth report -- because it rarely changes and the serial line is precious.
    Every report in between omits it, so a reader has to remember the last one
    or it cannot convert between machine and work coordinates.

    nil means NOT YET KNOWN, which is different from zero and must stay
    different. Treating an unseen offset as zero silently reports work
    coordinates as machine coordinates whenever GRBL is configured to send
    WPos ($10 bit 0 clear) -- the two columns agree, both look plausible, and
    both are wrong by however much the offset happens to be.
--]]
local last_wco = nil

local function triple(text)
    local x, y, z = text:match("^([%-%d%.]+),([%-%d%.]+),([%-%d%.]*)")
    if not x then return nil end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z) or 0 }
end

--[[
    parse_status(line) -> table

    Turn a status report into
        { state = "Idle", mpos = {x,y,z}, wpos = {x,y,z}, wco = {x,y,z} }

    GRBL reports EITHER machine position or work position, depending on $10,
    and the other is derived from the work coordinate offset:

        wpos = mpos - wco

    Both are always filled in, so callers never have to care which the
    controller happened to send.
--]]
function M.parse_status(line)
    local out = { raw = line }

    out.state = line:match("^<([%a:%d]+)") or "?"

    local wco = line:match("|WCO:([%-%d%.,]+)")
    if wco then
        local t = triple(wco)
        if t then last_wco = t end
    end

    -- Callers that care can check wco_known before trusting a derived figure
    out.wco_known = last_wco ~= nil
    out.wco = last_wco or { x = 0, y = 0, z = 0 }

    local mpos = line:match("|MPos:([%-%d%.,]+)")
    local wpos = line:match("|WPos:([%-%d%.,]+)")

    local w = out.wco

    if mpos then
        -- MPos is authoritative; only the derived work position needs the offset
        out.mpos = triple(mpos)
        out.wpos = {
            x = out.mpos.x - w.x,
            y = out.mpos.y - w.y,
            z = out.mpos.z - w.z,
        }
        out.derived = "wpos"
    elseif wpos then
        -- WPos is authoritative and the MACHINE position is the derived one,
        -- so an unknown offset corrupts the more important of the two
        out.wpos = triple(wpos)
        out.mpos = {
            x = out.wpos.x + w.x,
            y = out.wpos.y + w.y,
            z = out.wpos.z + w.z,
        }
        out.derived = "mpos"
    end

    local fs = line:match("|FS:([%d%.]+)")
    out.feed = fs and tonumber(fs) or nil

    return out
end

--[[
    Forget the cached offset, after a G92 or a work-coordinate change.

    Sets it to UNKNOWN, not to zero. Zero is a claim about the machine; unknown
    is the truth, and status() will go and find out.
--]]
function M.reset_wco()
    last_wco = nil
end

--[[
    status() -> table

    The machine's current state and position.

    Polls until GRBL has sent a work coordinate offset at least once, because
    until then any position derived from it is a guess. GRBL includes WCO in
    roughly every tenth report, so this normally costs one extra query and
    never more than a handful.
--]]
function M.status()
    local serial = require 'serial'

    local st = M.parse_status(serial.status())
    for _ = 1, 15 do
        if st.wco_known then break end
        st = M.parse_status(serial.status())
    end

    return st
end

--[[
    confirm(prompt) -> boolean

    Read a yes/no answer from stdin, defaulting to no.  Anything that is not
    an explicit yes leaves the machine alone.
--]]
function M.confirm(prompt)
    io.write(prompt .. " [y/N] ")
    io.flush()
    local answer = io.read()
    if not answer then return false end
    answer = answer:lower():gsub("^%s+", ""):gsub("%s+$", "")
    return answer == "y" or answer == "yes"
end

return M
