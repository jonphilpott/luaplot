--[[
    plotter.lua — core drawing API for luaplot

    This module is the engine that scripts use.  It provides:

      1. Initialisation
           plotter.init(config)

      2. A Processing.org-style affine transform stack
           plotter.push(), plotter.pop()
           plotter.translate(dx, dy)
           plotter.rotate(angle)    -- angle in degrees
           plotter.scale(sx, sy)

      3. Drawing primitives (coordinate system: Y-down, origin top-left)
           plotter.line(x1,y1, x2,y2)
           plotter.rect(x,y, w,h)
           plotter.circle(cx,cy, r, steps)
           plotter.text(x,y, str, height)

      4. Pen control
           plotter.penup()
           plotter.pendown()

      5. Finalisation
           plotter.done()

    ── Coordinate systems ───────────────────────────────────────────────────────

    Lua API  : Y-down, origin top-left (Processing / screen convention)
               Makes scripts intuitive — positive Y goes toward the bottom.

    G-code   : Y-up, origin bottom-left (machine convention)
               GRBL homes to (0,0) at the bottom-left of the work area.

    Conversion when emitting G-code:
               gcode_y = config.height - lua_y

    SVG      : Y-down, origin top-left (same as screen)
               No flip needed for SVG.

    ── Transform stack ──────────────────────────────────────────────────────────

    We maintain a stack of 2D affine matrices.  Each matrix is stored as
    6 numbers {a, b, c, d, tx, ty} representing the 3×3 matrix:

        | a   b   tx |
        | c   d   ty |
        | 0   0    1 |

    To transform a point (px, py):
        x' = a*px + b*py + tx
        y' = c*px + d*py + ty

    push() duplicates the top of the stack; pop() discards it.
    translate/rotate/scale post-multiply the current matrix so transforms
    compose in the order you write them (same as Processing).

    ── Output modes ─────────────────────────────────────────────────────────────

    "serial"  — send G-code to the plotter over the serial port
    "svg"     — write an SVG file
    "gcode"   — write G-code to a file (for repeatable playback)
    "both"    — serial + svg simultaneously
--]]

local hershey = require 'hershey'

local M = {}  -- the module table we'll return

-- ── Internal state ────────────────────────────────────────────────────────────

-- Configuration (set by init())
local cfg = {}

-- Transform stack.  Each entry is {a,b,c,d,tx,ty}.  We start with the
-- identity matrix — no transform applied.
local stack = {}

-- Current pen state: true = down (drawing), false = up (moving)
local pen_down = false

-- SVG accumulator: collect path strings, emit all at done()
local svg_paths = {}

-- G-code accumulator: used in "gcode" mode — collect all commands, write at done()
local gcode_lines = {}

-- ── Maths helpers ─────────────────────────────────────────────────────────────

local rad = math.rad   -- degrees → radians shorthand

-- Return a fresh identity matrix {a,b,c,d,tx,ty}
local function identity()
    return {1, 0,  -- a, b
            0, 1,  -- c, d
            0, 0}  -- tx, ty
end

--[[
    Multiply two affine matrices M1 × M2.

    Full 3×3 affine multiply, dropping the bottom row (always 0,0,1):

        | a1 b1 tx1 |   | a2 b2 tx2 |
        | c1 d1 ty1 | × | c2 d2 ty2 |
        |  0  0   1 |   |  0  0   1 |

    Result:
        a  = a1*a2  + b1*c2
        b  = a1*b2  + b1*d2
        c  = c1*a2  + d1*c2
        d  = c1*b2  + d1*d2
        tx = a1*tx2 + b1*ty2 + tx1
        ty = c1*tx2 + d1*ty2 + ty1
--]]
local function mat_mul(m1, m2)
    local a1,b1,c1,d1,tx1,ty1 = m1[1],m1[2],m1[3],m1[4],m1[5],m1[6]
    local a2,b2,c2,d2,tx2,ty2 = m2[1],m2[2],m2[3],m2[4],m2[5],m2[6]
    return {
        a1*a2  + b1*c2,   a1*b2  + b1*d2,
        c1*a2  + d1*c2,   c1*b2  + d1*d2,
        a1*tx2 + b1*ty2 + tx1,
        c1*tx2 + d1*ty2 + ty1,
    }
end

-- Apply current transform to point (px,py), return (x,y)
local function xform(px, py)
    local m = stack[#stack]
    return m[1]*px + m[2]*py + m[5],
           m[3]*px + m[4]*py + m[6]
end

-- ── G-code / serial helpers ───────────────────────────────────────────────────

-- True when the current mode should produce G-code output (live or to file)
local function want_gcode()
    return cfg.mode == "serial" or cfg.mode == "gcode" or cfg.mode == "both"
end

--[[
    Emit a raw G-code command string.
    In "serial"/"both" mode: sent immediately via serial.writeline(), which
    blocks until GRBL replies 'ok' (flow control — see serial.c).
    In "gcode" mode: appended to gcode_lines and written to file in done().
--]]
local function gcode(cmd)
    if cfg.mode == "serial" or cfg.mode == "both" then
        local serial = require 'serial'
        serial.writeline(cmd)
    end
    if cfg.mode == "gcode" then
        table.insert(gcode_lines, cmd)
    end
end

--[[
    Convert Lua Y coordinate (Y-down, origin top-left) to G-code Y
    (Y-up, origin bottom-left).

    If the work area height is H:
        gcode_y = H - lua_y

    Example: lua_y=0  (top edge)    → gcode_y = H  (top of work area)
             lua_y=H  (bottom edge) → gcode_y = 0  (plotter home Y)
--]]
local function gy(lua_y)
    return cfg.height - lua_y
end

-- Format a number for G-code: 3 decimal places, no trailing minus zero
local function gfmt(n)
    return string.format("%.3f", n)
end

-- Move to (x, y) in G-code space — the caller is responsible for Y-flip
local function gmove(gx, gy_val, feed)
    if feed then
        gcode(string.format("G1 X%s Y%s F%s", gfmt(gx), gfmt(gy_val), gfmt(feed)))
    else
        gcode(string.format("G0 X%s Y%s", gfmt(gx), gfmt(gy_val)))
    end
end

-- ── SVG helpers ───────────────────────────────────────────────────────────────

--[[
    Emit a SVG <polyline> or <polygon> element from a list of {x,y} world-space
    points.  SVG is Y-down so no coordinate flip is needed here.

    Using <polyline>/<polygon> instead of individual <line> elements produces
    cleaner, smaller SVG and makes it easier to post-process in Inkscape etc.
--]]
local function svg_polyline(pts, close)
    local coords = {}
    for _, pt in ipairs(pts) do
        table.insert(coords, string.format("%.3f,%.3f", pt[1], pt[2]))
    end
    local tag = close and "polygon" or "polyline"
    table.insert(svg_paths, string.format(
        '  <%s points="%s" stroke="black" stroke-width="0.5" fill="none"/>',
        tag, table.concat(coords, " ")))
end

-- ── Pen control ───────────────────────────────────────────────────────────────

--[[
    Pen up/down via GRBL spindle commands.
    GRBL interprets M3 Sxx as "spindle on at speed xx".
    We repurpose this: servo position for pen up vs pen down.
    The actual values come from cfg.pen_up and cfg.pen_down.
--]]
function M.penup()
    if pen_down then
        gcode(string.format("M3 S%d", cfg.pen_up))
        -- small dwell so the servo reaches position before we move
        gcode("G4 P0.1")
        pen_down = false
    end
end

function M.pendown()
    if not pen_down then
        gcode(string.format("M3 S%d", cfg.pen_down))
        gcode("G4 P0.1")
        pen_down = true
    end
end

-- ── Transform stack API ───────────────────────────────────────────────────────

-- Duplicate the current matrix onto the stack
function M.push()
    local cur = stack[#stack]
    table.insert(stack, {cur[1],cur[2],cur[3],cur[4],cur[5],cur[6]})
end

-- Discard the top matrix (but never pop the last one)
function M.pop()
    if #stack > 1 then
        table.remove(stack)
    end
end

--[[
    Post-multiply the current transform by a translation matrix:
        | 1  0  dx |
        | 0  1  dy |
        | 0  0   1 |
--]]
function M.translate(dx, dy)
    stack[#stack] = mat_mul(stack[#stack], {1,0, 0,1, dx,dy})
end

--[[
    Post-multiply by a rotation matrix.
    angle is in degrees (converted to radians internally).
    Positive angle rotates clockwise in Y-down screen space.

        | cos θ  -sin θ  0 |
        | sin θ   cos θ  0 |
        |   0       0    1 |
--]]
function M.rotate(angle)
    local t = rad(angle)
    local c, s = math.cos(t), math.sin(t)
    stack[#stack] = mat_mul(stack[#stack], {c,-s, s,c, 0,0})
end

--[[
    Post-multiply by a scale matrix.
    sy defaults to sx if omitted (uniform scale).
--]]
function M.scale(sx, sy)
    sy = sy or sx
    stack[#stack] = mat_mul(stack[#stack], {sx,0, 0,sy, 0,0})
end

-- ── Drawing primitives ────────────────────────────────────────────────────────

--[[
    polyline(points, close)

    The core primitive that everything else builds on.

    points  — list of {x, y} tables in Lua drawing space
    close   — if true, a final segment is drawn back to the first point
              (use this for closed shapes like rect, circle, polygon)

    All points are transformed through the current matrix before output.

    G-code efficiency: the pen goes down once at the start and up once at the
    end, regardless of how many points are in the path.  Previously, line()
    lifted the pen between every segment — on a physical plotter each lift is
    a servo move + dwell, so this makes a significant difference for shapes
    with many segments (circles, text strokes, bezier curves).
--]]
function M.polyline(points, close)
    if #points < 2 then return end

    -- Step 1: transform all points into world space
    local wp = {}
    for _, pt in ipairs(points) do
        local wx, wy = xform(pt[1], pt[2])
        table.insert(wp, {wx, wy})
    end

    -- Step 2: G-code path — one pendown for the whole stroke
    if want_gcode() then
        M.penup()
        gmove(wp[1][1], gy(wp[1][2]), nil)     -- rapid to start (pen up)
        M.pendown()
        for i = 2, #wp do
            gmove(wp[i][1], gy(wp[i][2]), cfg.feed)
        end
        if close then
            gmove(wp[1][1], gy(wp[1][2]), cfg.feed)  -- close back to start
        end
        M.penup()
    end

    -- Step 3: SVG — one <polyline> or <polygon> element
    if cfg.mode == "svg" or cfg.mode == "both" then
        svg_polyline(wp, close)
    end
end

--[[
    line(x1, y1, x2, y2)

    Draw a straight line segment.  Thin wrapper around polyline() with two
    points — exists as a convenience so scripts don't have to wrap pairs in
    tables for simple cases.
--]]
function M.line(x1, y1, x2, y2)
    M.polyline({{x1,y1}, {x2,y2}}, false)
end

--[[
    polygon(points)

    Draw a closed shape through an arbitrary list of {x,y} points.
    The last point is automatically connected back to the first.

    Example — an equilateral triangle:
        plotter.polygon({{100,70}, {130,130}, {70,130}})
--]]
function M.polygon(points)
    M.polyline(points, true)
end

--[[
    rect(x, y, w, h)

    Draw a rectangle.  (x, y) is the top-left corner.
    Now a single closed polyline — one pen lift total instead of four.
--]]
function M.rect(x, y, w, h)
    M.polyline({{x,y}, {x+w,y}, {x+w,y+h}, {x,y+h}}, true)
end

--[[
    circle(cx, cy, r [, steps])

    Draw a circle approximated as a closed polygon.
    steps controls smoothness (default 36 → 10° per segment).
    One pen lift total regardless of steps.

    Applying scale() before circle() produces an ellipse; use ellipse()
    directly if you want explicit rx/ry control without transform side-effects.
--]]
function M.circle(cx, cy, r, steps)
    steps = steps or 36
    local pts = {}
    for i = 0, steps - 1 do
        local a = rad(i * 360 / steps)
        table.insert(pts, {cx + r * math.cos(a), cy + r * math.sin(a)})
    end
    M.polyline(pts, true)
end

--[[
    arc(cx, cy, r, start_angle, end_angle [, steps])

    Draw a portion of a circle — an open curve, not a closed shape.
    Angles are in degrees, measured clockwise from the positive X axis
    (consistent with Y-down screen space).

    steps defaults to a value proportional to the angular span so you get
    roughly the same curve smoothness as circle() regardless of arc size.

    Example — a semicircle opening downward:
        plotter.arc(100, 100, 40, 0, 180)
--]]
function M.arc(cx, cy, r, start_angle, end_angle, steps)
    local span = end_angle - start_angle
    -- Default: same angular resolution as circle()'s default 36 steps
    steps = steps or math.max(2, math.floor(math.abs(span) / 360 * 72))
    local pts = {}
    for i = 0, steps do
        local a = rad(start_angle + i * span / steps)
        table.insert(pts, {cx + r * math.cos(a), cy + r * math.sin(a)})
    end
    M.polyline(pts, false)   -- open — arc does not close back to start
end

--[[
    ellipse(cx, cy, rx, ry [, steps])

    Draw an ellipse with independent horizontal and vertical radii.
    rx is the half-width, ry is the half-height.
    steps defaults to 36.

    Unlike using scale()+circle(), this does not affect the current transform,
    so you can draw an ellipse without disturbing subsequent geometry.
--]]
function M.ellipse(cx, cy, rx, ry, steps)
    steps = steps or 36
    local pts = {}
    for i = 0, steps - 1 do
        local a = rad(i * 360 / steps)
        table.insert(pts, {cx + rx * math.cos(a), cy + ry * math.sin(a)})
    end
    M.polyline(pts, true)
end

--[[
    bezier(x1, y1, cx1, cy1, cx2, cy2, x2, y2 [, steps])

    Draw a cubic Bézier curve from (x1,y1) to (x2,y2).
    (cx1,cy1) and (cx2,cy2) are the two control points that pull the curve
    away from the straight line between the endpoints.

    The curve is approximated as 'steps' line segments (default 20), which
    is plenty for most plotter work — the pen width hides any faceting.

    The cubic Bézier formula:
        P(t) = (1-t)³·P0 + 3(1-t)²t·P1 + 3(1-t)t²·P2 + t³·P3
    where t goes from 0 to 1, P0/P3 are endpoints, P1/P2 are control points.

    Example — an S-curve:
        plotter.bezier(50, 150,   50, 50,   150, 150,   150, 50)
--]]
function M.bezier(x1, y1, cx1, cy1, cx2, cy2, x2, y2, steps)
    steps = steps or 20
    local pts = {}
    for i = 0, steps do
        local t  = i / steps
        local mt = 1 - t
        -- Expand the cubic formula — mt³, 3mt²t, 3mt·t², t³
        local bx = mt^3*x1 + 3*mt^2*t*cx1 + 3*mt*t^2*cx2 + t^3*x2
        local by = mt^3*y1 + 3*mt^2*t*cy1 + 3*mt*t^2*cy2 + t^3*y2
        table.insert(pts, {bx, by})
    end
    M.polyline(pts, false)
end

--[[
    text(x, y, str, height)

    Draw str using the Hershey Roman Simplex single-stroke font.
    (x, y) is the left end of the baseline; height is the cap height.

    Each Hershey character is made of one or more strokes (connected polylines).
    We draw each stroke as a single polyline() call — one pen lift per stroke
    rather than one per segment.  For a typical letter this is 1–3 lifts
    instead of 5–10.
--]]
function M.text(x, y, str, height)
    local strokes, advance = hershey.get_strokes(str, x, y, height)
    for _, stroke in ipairs(strokes) do
        if #stroke >= 2 then
            M.polyline(stroke, false)
        end
    end
    return advance
end

--[[
    plotter.text_width(str, height)

    Returns the advance width of str at the given cap height in drawing units,
    without drawing anything.  Use this to calculate x positions before calling
    text() — e.g. to centre a string:

        local w = plotter.text_width("HELLO", 20)
        plotter.text(100 - w/2, 80, "HELLO", 20)
--]]
function M.text_width(str, height)
    return hershey.measure(str, height)
end

-- ── Init & done ───────────────────────────────────────────────────────────────

--[[
    plotter.init(config)

    Required config fields:
        mode      "serial" | "svg" | "gcode" | "both"
        width     work area width  in mm (also SVG viewport width)
        height    work area height in mm (also SVG viewport height)

    Optional (serial/both mode):
        port      serial port path  (default "/dev/ttyUSB0")
        baud      baud rate         (default 115200)
        feed      feed rate mm/min  (default 1000)
        pen_up    spindle S value for pen up   (default 90)
        pen_down  spindle S value for pen down (default 30)

    Optional (svg/both mode):
        svg_file  output file path  (default "output.svg")

    Optional (gcode mode):
        gcode_file  output file path  (default "output.nc")
--]]
function M.init(config)
    cfg = {
        mode      = config.mode or "svg",
        width     = config.width or 200,
        height    = config.height or 200,
        port      = config.port      or "/dev/ttyUSB0",
        baud      = config.baud      or 115200,
        feed      = config.feed      or 1000,
        pen_up    = config.pen_up    or 90,
        pen_down  = config.pen_down  or 30,
        svg_file   = config.svg_file   or "output.svg",
        gcode_file = config.gcode_file or "output.nc",
    }

    -- Reset state
    stack       = { identity() }
    pen_down    = false
    svg_paths   = {}
    gcode_lines = {}

    -- Open serial port if needed
    if cfg.mode == "serial" or cfg.mode == "both" then
        local serial = require 'serial'
        serial.open(cfg.port, cfg.baud)
    end

    -- Emit G-code preamble (goes to serial, file, or both depending on mode)
    if want_gcode() then
        gcode("G21")          -- metric units
        gcode("G90")          -- absolute positioning
        gcode("G92 X0 Y0 Z0") -- zero the work coordinate system here
        gcode("M3 S0")        -- spindle on at 0 (servo initialise)
    end
end

--[[
    plotter.done()

    Finalise output:
      - Serial: lift pen, home the machine, close port
      - SVG: write the accumulated <line> elements to the SVG file
--]]
function M.done()
    if want_gcode() then
        M.penup()
        gcode("G0 X0 Y0")   -- return to home
        gcode("M5")          -- spindle off
    end

    if cfg.mode == "serial" or cfg.mode == "both" then
        local serial = require 'serial'
        serial.close()
    end

    if cfg.mode == "gcode" then
        local f = assert(io.open(cfg.gcode_file, "w"))
        for _, line in ipairs(gcode_lines) do
            f:write(line .. "\n")
        end
        f:close()
        print("G-code written to " .. cfg.gcode_file)
    end

    if cfg.mode == "svg" or cfg.mode == "both" then
        local f = assert(io.open(cfg.svg_file, "w"))

        -- SVG header with viewport matching the work area
        f:write(string.format(
            '<?xml version="1.0" encoding="UTF-8"?>\n' ..
            '<svg xmlns="http://www.w3.org/2000/svg" ' ..
            'width="%.3fmm" height="%.3fmm" ' ..
            'viewBox="0 0 %.3f %.3f">\n',
            cfg.width, cfg.height,
            cfg.width, cfg.height))

        -- White background
        f:write(string.format(
            '  <rect width="%.3f" height="%.3f" fill="white"/>\n',
            cfg.width, cfg.height))

        -- All accumulated strokes
        for _, path in ipairs(svg_paths) do
            f:write(path .. "\n")
        end

        f:write('</svg>\n')
        f:close()
        print("SVG written to " .. cfg.svg_file)
    end
end

return M
