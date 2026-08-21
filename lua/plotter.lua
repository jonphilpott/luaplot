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
           ... and hatch(), streamline(), curve(), and friends

      4. Pen control
           plotter.penup()
           plotter.pendown()

      5. Output
           plotter.flush()          -- emit what has been drawn, stay open
           plotter.done()           -- emit, park, close

    ── Coordinate systems ───────────────────────────────────────────────────────

    Lua API  : Y-down, origin top-left (Processing / screen convention)
               Makes scripts intuitive — positive Y goes toward the bottom.

    G-code   : Y-up, origin bottom-left (machine convention)
               GRBL homes to (0,0) at the bottom-left of the work area.

    Conversion when emitting G-code:
               gcode_y = config.height - lua_y

    SVG      : Y-down, origin top-left (same as screen)
               No flip needed for SVG.

    ── Points ───────────────────────────────────────────────────────────────────

    Anywhere a point is expected you may pass either two numbers or a single
    vec2 (or a plain {x, y} table):

        plotter.line(10, 10, 90, 90)
        plotter.line(vec2(10, 10), vec2(90, 90))
        plotter.polyline({ vec2(0,0), {10,10}, vec2(20,0) })

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

    ── The path buffer ──────────────────────────────────────────────────────────

    Primitives do not write G-code directly.  They transform their points into
    world space and append a path record to a buffer; flush() is what turns
    buffered paths into G-code and SVG.

    That indirection is what makes four otherwise-awkward features possible:
    reordering paths to cut pen-up travel, grouping them into layers, answering
    bounds() without re-deriving geometry, and — most importantly — emitting in
    batches so a plot can be built up over time rather than in one shot.

    By default auto_flush is true and every primitive flushes immediately, so
    output is byte-for-byte what it always was.  Real-time and optimised
    plotting turn it off:

        plotter.init { mode = "serial", port = ..., auto_flush = false }
        while running do
            plotter.polyline(read_sensor())
            plotter.flush()      -- this batch goes to the pen, session stays live
        end
        plotter.done()

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

-- Everything queued since init(), in world space and in the order it was
-- called for.  Two kinds of entry live here:
--
--   { kind = "path", pts = {{x,y}, ...}, close = boolean, layer = string }
--   { kind = "dip",  pot = name, x = , y = , dip_time = , drip_time = , ... }
--
-- Dips share the buffer rather than firing immediately because they are
-- ordered events: "these strokes get this load of paint" only means anything
-- if the dip stays put relative to the strokes around it.  See M.dip.
local paths = {}

-- How many entries of `paths` have already been emitted.  Everything after
-- this index is pending and goes out on the next flush().
local flushed = 0

-- Layer currently being drawn into (see M.layer)
local current_layer = nil

-- Last layer actually emitted, so flush() knows when to prompt for a pen swap
local emitted_layer = nil

-- SVG accumulator: rendered elements, grouped by layer, emitted at write time
local svg_paths = {}

-- G-code accumulator: used in "gcode" mode — collect all commands, write at done()
local gcode_lines = {}

-- Where the pen physically is, in world space.  Drives travel-distance
-- accounting and gives the optimiser a starting point.
local pen_x, pen_y = 0, 0

-- Running totals, reported by stats() and printed by done().
-- flushed_paths counts emitted drawing paths only, since `flushed` indexes the
-- buffer and that now holds dips as well.
local draw_len, travel_len = 0, 0
local flushed_paths = 0

-- Paint pots: name -> {x, y}, in absolute work-area coordinates
local pots = {}

-- Dip accounting: how many, how long they spent dwelling, and how far the
-- brush has drawn since the last one (for dip_every)
local dip_count, dwell_secs, drawn_since_dip = 0, 0, 0

-- The pot most recently dipped. Automatic reloads go back to the same one:
-- if you dipped "red" and are painting in red, a top-up is red.
local last_pot = nil

-- Set once done() has closed things down, so a second call is a no-op
local finished = false

-- One warning per primitive kind is plenty; this remembers which we've given
local warned = {}

-- ── Maths helpers ─────────────────────────────────────────────────────────────

local rad = math.rad   -- degrees → radians shorthand
local sqrt, floor, abs = math.sqrt, math.floor, math.abs
local min, max = math.min, math.max

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

--[[
    Read a point from either two numbers or one point-like value.

    vec2 userdata answers pt[1]/pt[2], so it and a plain {x, y} table take the
    same path; {x = ..., y = ...} tables fall through to the named fields.
    This is what lets every public function accept both calling styles without
    each one having to care.
--]]
local function xy(a, b)
    if type(a) == "number" then
        return a, b
    end
    if a == nil then
        error("expected a point (two numbers, or a vec2), got nil", 3)
    end
    local x, y = a[1], a[2]
    if x == nil then x, y = a.x, a.y end
    if type(x) ~= "number" or type(y) ~= "number" then
        error("expected a point (two numbers, or a vec2), got " .. type(a), 3)
    end
    return x, y
end

-- Distance between two points
local function dist(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return sqrt(dx*dx + dy*dy)
end

-- One warning per kind per run, and silence entirely under quiet = true
local function warn(key, msg)
    if warned[key] or cfg.quiet then return end
    warned[key] = true
    io.stderr:write("luaplot: " .. msg .. "\n")
end

-- ── G-code / serial helpers ───────────────────────────────────────────────────

-- True when the current mode should produce G-code output (live or to file)
local function want_gcode()
    return cfg.mode == "serial" or cfg.mode == "gcode" or cfg.mode == "both"
end

-- True when the current mode talks to hardware
local function want_serial()
    return cfg.mode == "serial" or cfg.mode == "both"
end

--[[
    Emit a raw G-code command string.
    In "serial"/"both" mode: sent immediately via serial.writeline(), which
    blocks until GRBL replies 'ok' (flow control — see serial.c).
    In "gcode" mode: appended to gcode_lines and written to file in done().
--]]
local function gcode(cmd)
    if want_serial() then
        local serial = require 'serial'
        serial.writeline(cmd)
    end
    if cfg.mode == "gcode" then
        gcode_lines[#gcode_lines + 1] = cmd
    end
end

--[[
    Convert a point from drawing space to the machine's coordinate space.

    Two things happen here, and they are the only place either happens:

    1. THE Y FLIP. Drawing space is Y-down with the origin at the top-left, the
       screen convention Processing uses. Machine space is Y-up with the origin
       at the bottom-left, because that is where a GRBL machine homes. For a
       work area of height H:

           machine_y = H - drawing_y

       so drawing y=0 (the top edge) is the far side of the bed, and y=H (the
       bottom edge) is nearest the operator.

    2. THE ORIGIN OFFSET. cfg.origin says where the near-left corner of the
       paper sits in machine coordinates, so the whole drawing is translated
       there. It defaults to (0, 0), which leaves the old behaviour untouched.

    Deliberately NOT the transform stack: this is the fixed relationship
    between the page and the bed, not something a script composes with.
--]]
local function to_machine(x, y)
    return x + cfg.origin.x,
           (cfg.height - y) + cfg.origin.y
end

-- Format a number for G-code: 3 decimal places
local function gfmt(n)
    return string.format("%.3f", n)
end

--[[
    Move to a point given in DRAWING coordinates.

    The conversion happens here rather than at the call sites, so no caller can
    forget the origin offset the way they previously had to remember the Y
    flip. feed nil means a rapid (G0), otherwise a feed move (G1).
--]]
local function gmove(x, y, feed)
    local mx, my = to_machine(x, y)
    if feed then
        gcode(string.format("G1 X%s Y%s F%s", gfmt(mx), gfmt(my), gfmt(feed)))
    else
        gcode(string.format("G0 X%s Y%s", gfmt(mx), gfmt(my)))
    end
end

-- ── SVG helpers ───────────────────────────────────────────────────────────────

-- Distinct stroke colours for layers, cycled.  Only ever seen in the SVG
-- preview — the plotter draws whatever pen you put in it.
local LAYER_COLOURS = {
    "black", "#c0392b", "#2980b9", "#27ae60",
    "#8e44ad", "#d35400", "#16a085", "#7f8c8d",
}

--[[
    Render one world-space path as an SVG <polyline> or <polygon> element.
    SVG is Y-down so no coordinate flip is needed here.

    Using <polyline>/<polygon> instead of individual <line> elements produces
    cleaner, smaller SVG and makes it easier to post-process in Inkscape etc.
--]]
local function svg_element(pts, close)
    local coords = {}
    for i = 1, #pts do
        coords[i] = string.format("%.3f,%.3f", pts[i][1], pts[i][2])
    end
    local tag = close and "polygon" or "polyline"
    return string.format(
        '  <%s points="%s" stroke="black" stroke-width="0.5" fill="none"/>',
        tag, table.concat(coords, " "))
end

-- ── Clipping ──────────────────────────────────────────────────────────────────

-- Cohen–Sutherland region codes
local INSIDE, LEFT, RIGHT, BOTTOM, TOP = 0, 1, 2, 4, 8

local function outcode(x, y)
    local code = INSIDE
    if     x < 0          then code = code | LEFT
    elseif x > cfg.width  then code = code | RIGHT end
    if     y < 0          then code = code | TOP
    elseif y > cfg.height then code = code | BOTTOM end
    return code
end

--[[
    Clip one segment to the work area (Cohen–Sutherland).

    Returns the clipped endpoints, or nil if the segment lies entirely outside.
    The algorithm repeatedly pushes whichever endpoint is outside onto the
    boundary it violates, until both are inside (accept) or both share a
    violated boundary (reject).
--]]
local function clip_segment(x1, y1, x2, y2)
    local c1, c2 = outcode(x1, y1), outcode(x2, y2)

    while true do
        if c1 | c2 == 0 then return x1, y1, x2, y2 end     -- both inside
        if c1 & c2 ~= 0 then return nil end                -- both beyond one edge

        local c = (c1 ~= 0) and c1 or c2
        local x, y

        if c & BOTTOM ~= 0 then
            x = x1 + (x2 - x1) * (cfg.height - y1) / (y2 - y1); y = cfg.height
        elseif c & TOP ~= 0 then
            x = x1 + (x2 - x1) * (0 - y1) / (y2 - y1);          y = 0
        elseif c & RIGHT ~= 0 then
            y = y1 + (y2 - y1) * (cfg.width - x1) / (x2 - x1);  x = cfg.width
        else
            y = y1 + (y2 - y1) * (0 - x1) / (x2 - x1);          x = 0
        end

        if c == c1 then x1, y1, c1 = x, y, outcode(x, y)
        else            x2, y2, c2 = x, y, outcode(x, y) end
    end
end

--[[
    Clip a whole polyline, returning a list of polylines.

    A path that wanders off the page and back comes home as several separate
    runs, so the result is always a list.  Closed paths come back open: once a
    shape has been cut by the page edge there is no closing segment left to
    draw.
--]]
local function clip_polyline(pts, close)
    local segs = {}
    local n = #pts
    local last = close and n or n - 1

    for i = 1, last do
        local a, b = pts[i], pts[i % n + 1]
        local cx1, cy1, cx2, cy2 = clip_segment(a[1], a[2], b[1], b[2])
        if cx1 then segs[#segs + 1] = {cx1, cy1, cx2, cy2} end
    end

    -- Stitch consecutive surviving segments back into runs
    local runs, run = {}, nil
    local EPS = 1e-9

    for _, s in ipairs(segs) do
        if run and abs(run[#run][1] - s[1]) < EPS and abs(run[#run][2] - s[2]) < EPS then
            run[#run + 1] = {s[3], s[4]}
        else
            if run and #run >= 2 then runs[#runs + 1] = run end
            run = {{s[1], s[2]}, {s[3], s[4]}}
        end
    end
    if run and #run >= 2 then runs[#runs + 1] = run end

    return runs
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
    stack[#stack + 1] = {cur[1],cur[2],cur[3],cur[4],cur[5],cur[6]}
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

    Accepts translate(dx, dy) or translate(vec2).
--]]
function M.translate(dx, dy)
    local x, y = xy(dx, dy)
    stack[#stack] = mat_mul(stack[#stack], {1,0, 0,1, x,y})
end

--[[
    Post-multiply by a rotation matrix.
    angle is in degrees (converted to radians internally).
    Positive angle rotates clockwise in Y-down screen space.

        | cos θ  -sin θ  0 |
        | sin θ   cos θ  0 |
        |   0       0    1 |

    Note the units: plotter.rotate() is DEGREES, while vec2:rotate() is
    radians (matching PVector).  vec2:rotate_deg() bridges the two.
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

-- Replace the current matrix with the identity, discarding any accumulated
-- transform without unwinding the stack.
function M.reset_matrix()
    stack[#stack] = identity()
end

-- ── Layers ────────────────────────────────────────────────────────────────────

--[[
    plotter.layer(name)

    Tag everything drawn from here on as belonging to a named layer.

    In SVG each layer becomes a <g> with its own stroke colour, so you can see
    the separation.  On hardware the pen is parked and you are prompted to swap
    pens when the plot crosses a layer boundary — which is how a single-pen
    plotter draws in more than one colour.

    Paths are never reordered across a layer boundary, so layers also act as
    barriers for the travel optimiser.

    plotter.layer(nil) returns to the unnamed default layer.
--]]
function M.layer(name)
    current_layer = name
end

-- ── Path recording ────────────────────────────────────────────────────────────

--[[
    The single choke point every primitive goes through.

    Takes a list of points already in world space, applies the clip policy, and
    appends the surviving runs to the path buffer.  Nothing here emits output;
    flush() does that.
--]]
--[[
    Which pot an automatic reload (dip_every) should go to.

    The pot you last dipped, because a top-up should be the same colour as the
    paint already on the brush. Failing that the default pot, and failing that
    the only pot there is -- a rig with one named pot and no "default" is a
    perfectly reasonable setup and should not need a redundant alias.
--]]
local function auto_dip_pot()
    if last_pot and pots[last_pot] then return last_pot end
    if pots.default then return "default" end

    local only = nil
    for name in pairs(pots) do
        if only then return nil end     -- ambiguous; let dip() report it
        only = name
    end
    return only
end

-- Total drawn length of a path, closing segment included
local function path_length(pts, close)
    local total = 0
    for i = 2, #pts do
        total = total + dist(pts[i-1][1], pts[i-1][2], pts[i][1], pts[i][2])
    end
    if close and #pts > 2 then
        total = total + dist(pts[#pts][1], pts[#pts][2], pts[1][1], pts[1][2])
    end
    return total
end

--[[
    Refuse to draw into a session that has been closed.

    Without this the failure surfaces four frames down as a bare "Serial port
    is not open" from serial.writeline, which says nothing about the actual
    mistake. Worse, it only happens in serial mode: in SVG mode the same script
    quietly appends to the finished drawing, so the bug hides until it reaches
    hardware. Failing the same way in every mode is the point.
--]]
local function check_open()
    if not finished then return end

    -- Level 0: no position prefix. The honest position is the caller's line,
    -- and it is several frames up through whichever primitive they used, so
    -- any fixed level would name a line inside plotter.lua instead. luaplot
    -- always installs a traceback handler, so the real call site still shows.
    error(
        "drawing after plotter.done(), which ended the session.\n" ..
        "  To keep drawing, either call flush() in a loop and done() once at " ..
        "the end,\n" ..
        "  or pass done { keep_open = true } to park and write output without " ..
        "closing the port.", 0)
end

local function record(pts, close, what)
    check_open()
    if #pts < 2 then return end

    local runs

    if cfg.clip == "clip" then
        runs = clip_polyline(pts, close)
        close = false               -- a clipped shape is no longer closed
        if #runs == 0 then return end
    else
        if cfg.clip == "warn" then
            for i = 1, #pts do
                local x, y = pts[i][1], pts[i][2]
                if x < 0 or y < 0 or x > cfg.width or y > cfg.height then
                    warn(what or "clip", string.format(
                        "%s extends outside the %gx%g mm work area " ..
                        "(point %.2f, %.2f). Set clip = \"clip\" to trim, " ..
                        "or clip = \"off\" to silence this.",
                        what or "path", cfg.width, cfg.height, x, y))
                    break
                end
            end
        end
        runs = {pts}
    end

    for _, run in ipairs(runs) do
        -- A brush holds a finite amount of paint. If dip_every is set, top it
        -- up before any stroke that would run past that budget. Decided here
        -- rather than at emit time so the dip lands in the right place in the
        -- sequence, and so the decision does not shift when paths are
        -- reordered -- drawn length is the same either way, travel is not.
        --
        -- The drawn_since_dip > 0 guard matters: without it, a single stroke
        -- longer than the whole budget triggers a reload even on a brush that
        -- was just loaded, dipping twice with nothing drawn in between. When
        -- one stroke exceeds a brush-load there is nothing a reload can do --
        -- splitting the path would change the drawing -- so draw it and say so.
        local run_len = path_length(run, close)

        if cfg.dip_every and drawn_since_dip > 0
           and drawn_since_dip + run_len > cfg.dip_every then
            local auto = auto_dip_pot()
            if not auto then
                error("dip_every is set but there is no pot to reload from. " ..
                      "Dip a named pot once first, or register a default with " ..
                      "plotter.pot(x, y) / paint_pot in init().", 2)
            end
            M.dip(auto)
        end

        if cfg.dip_every and run_len > cfg.dip_every then
            warn("long_stroke", string.format(
                "a single stroke is %.0f mm, longer than the dip_every budget " ..
                "of %.0f mm -- it cannot be reloaded part-way through and may " ..
                "run dry. Shorten the strokes or raise dip_every.",
                run_len, cfg.dip_every))
        end

        paths[#paths + 1] = { kind = "path", pts = run, close = close,
                              layer = current_layer }
        drawn_since_dip = drawn_since_dip + run_len
    end

    if cfg.auto_flush then M.flush() end
end

-- Transform a list of {x,y}/vec2 points into world space
local function to_world(points)
    local wp = {}
    for i = 1, #points do
        local px, py = xy(points[i])
        local wx, wy = xform(px, py)
        wp[i] = {wx, wy}
    end
    return wp
end

-- ── Emission ──────────────────────────────────────────────────────────────────

-- Total pen-up distance a given ordering would cost, from (sx, sy)
local function travel_cost(list, sx, sy)
    local total, cx, cy = 0, sx, sy
    for _, p in ipairs(list) do
        local first, last = p.pts[1], p.pts[#p.pts]
        total = total + dist(cx, cy, first[1], first[2])
        cx, cy = last[1], last[2]
    end
    return total
end

--[[
    Reorder a batch of paths to cut pen-up travel.

    Greedy nearest-neighbour: from where the pen is, repeatedly take whichever
    unvisited path has an endpoint closest to the current position, reversing
    it if its far end is the nearer one.

    Nearest-neighbour is not optimal, but it is O(n²) with a tiny constant and
    typically removes most of the waste — which matters because pen-up moves
    are pure overhead, and a plot with a few thousand short strokes can easily
    spend more time travelling than drawing.

    Closed paths are reversed but never rotated to a different start vertex:
    that would move the seam where the pen sets down and lifts, which is
    visible on paper.
--]]
local function optimize_order(list, sx, sy)
    local n = #list
    -- Note n == 0, not n < 2: a lone path still gets the reversal decision,
    -- which can be the difference between crossing the page and not.
    if n == 0 then return list end

    local remaining, out = {}, {}
    for i = 1, n do remaining[i] = list[i] end

    local cx, cy = sx, sy

    for _ = 1, n do
        local best, best_d, best_rev = nil, math.huge, false

        for i, p in ipairs(remaining) do
            local first, last = p.pts[1], p.pts[#p.pts]
            local d_fwd = dist(cx, cy, first[1], first[2])
            if d_fwd < best_d then best, best_d, best_rev = i, d_fwd, false end

            local d_rev = dist(cx, cy, last[1], last[2])
            if d_rev < best_d then best, best_d, best_rev = i, d_rev, true end
        end

        local p = table.remove(remaining, best)

        if best_rev then
            -- Copy rather than reverse in place: the caller's list and the
            -- path buffer may share this table. Carry every field across --
            -- dropping `kind` here would quietly turn a tagged entry into an
            -- untagged one.
            local r = {}
            for i = #p.pts, 1, -1 do r[#r + 1] = p.pts[i] end
            p = { kind = p.kind, pts = r, close = p.close, layer = p.layer }
        end

        out[#out + 1] = p
        local last = p.pts[#p.pts]
        cx, cy = last[1], last[2]
    end

    return out
end

--[[
    Optimise a pending batch, respecting layer and dip boundaries.

    Paths are grouped into maximal runs that share a layer and have no dip
    between them; each run is optimised on its own.  Both boundaries are hard:

      * reordering across a layer would turn one pen swap into many;
      * reordering across a dip would hand the paint to the wrong strokes,
        which is the entire point of having dipped where you did.
--]]
local function optimize_batch(list, sx, sy)
    local out = {}
    local i, cx, cy = 1, sx, sy

    while i <= #list do
        if list[i].kind == "dip" then
            -- A barrier. Pass it through untouched; the pen is at the pot
            -- afterwards, which is where the next group starts from.
            out[#out + 1] = list[i]
            cx, cy = list[i].x, list[i].y
            i = i + 1
        else
            local layer = list[i].layer
            local group = {}
            while i <= #list and list[i].kind ~= "dip" and list[i].layer == layer do
                group[#group + 1] = list[i]
                i = i + 1
            end

            local ordered = optimize_order(group, cx, cy)
            for _, p in ipairs(ordered) do out[#out + 1] = p end

            local last = ordered[#ordered].pts
            cx, cy = last[#last][1], last[#last][2]
        end
    end

    return out
end

-- Park the pen and wait for the operator to change it
local function pen_change_prompt(name)
    M.penup()
    gcode("G0 X0 Y0")
    pen_x, pen_y = 0, 0
    io.write(string.format(
        "\n--- Pen change: layer '%s'. Swap pens, then press Enter. ---\n",
        tostring(name)))
    io.flush()
    io.read()
end

-- Emit one path as G-code: rapid to the start, draw through, lift.
local function emit_gcode(p)
    local wp = p.pts

    M.penup()
    gmove(wp[1][1], wp[1][2], nil)         -- rapid to start (pen up)
    M.pendown()

    for i = 2, #wp do
        gmove(wp[i][1], wp[i][2], cfg.feed)
    end

    if p.close then
        gmove(wp[1][1], wp[1][2], cfg.feed)      -- close back to start
    end

    M.penup()
end

--[[
    Emit one dip: lift, travel to the pot, lower into the paint, dwell, lift
    out, dwell again over the pot.

    The second dwell is the one people forget. A brush comes out of the pot
    loaded and dripping; lifting and immediately traversing to the drawing
    flings paint across the page. Waiting over the pot lets the excess fall
    back where it belongs.

    pen_dip is a separate servo value from pen_down because the paint surface
    is not the paper surface -- usually a good deal lower.
--]]
local function emit_dip(d)
    M.penup()                                   -- no-op if already up

    gmove(d.x, d.y, nil)                        -- rapid to the pot, pen clear

    gcode(string.format("M3 S%d", d.pen_dip))   -- into the paint
    gcode(string.format("G4 P%.3f", d.dip_time))

    gcode(string.format("M3 S%d", cfg.pen_up))  -- out again
    gcode(string.format("G4 P%.3f", d.drip_time))

    pen_down = false
end

--[[
    Account for one path's cost and advance the notional pen position.

    Kept separate from emit_gcode() so the numbers are the same in every mode:
    knowing a plot involves 40 m of travel is most useful while you are still
    iterating in SVG, long before anything reaches the machine.
--]]
local function account(p)
    if p.kind == "dip" then
        travel_len = travel_len + dist(pen_x, pen_y, p.x, p.y)
        dwell_secs = dwell_secs + p.dip_time + p.drip_time
        dip_count  = dip_count + 1
        pen_x, pen_y = p.x, p.y
        return
    end

    flushed_paths = flushed_paths + 1

    local wp = p.pts

    travel_len = travel_len + dist(pen_x, pen_y, wp[1][1], wp[1][2])

    for i = 2, #wp do
        draw_len = draw_len + dist(wp[i-1][1], wp[i-1][2], wp[i][1], wp[i][2])
    end

    if p.close then
        draw_len = draw_len + dist(wp[#wp][1], wp[#wp][2], wp[1][1], wp[1][2])
        pen_x, pen_y = wp[1][1], wp[1][2]
    else
        pen_x, pen_y = wp[#wp][1], wp[#wp][2]
    end
end

--[[
    plotter.flush()

    Emit every path buffered since the last flush, and clear the pending set.
    The session stays open — the serial port is not closed and you can keep
    drawing.

    Safe to call any number of times, including when nothing is pending, which
    is what makes the real-time loop in the header comment work.
--]]
function M.flush()
    if flushed >= #paths then return end

    local start = flushed
    local pending = {}
    for i = start + 1, #paths do pending[#pending + 1] = paths[i] end
    flushed = #paths

    if cfg.optimize then
        pending = optimize_batch(pending, pen_x, pen_y)

        -- Write the reordered batch back over the slice it came from, so
        -- paths() reports the order the plot was actually drawn in rather than
        -- the order the calls were made. Anything post-processing the output
        -- wants the former, and so do reversed paths, which are new tables.
        for i = 1, #pending do paths[start + i] = pending[i] end
    end

    for _, p in ipairs(pending) do
        if p.kind ~= "dip" and p.layer ~= emitted_layer then
            -- Not on the very first batch: that is the pen already in the machine
            if emitted_layer ~= nil and want_gcode() then
                pen_change_prompt(p.layer)
            end
            emitted_layer = p.layer
        end

        account(p)

        if p.kind == "dip" then
            if want_gcode() then emit_dip(p) end
        else
            if want_gcode() then emit_gcode(p) end

            if cfg.mode == "svg" or cfg.mode == "both" then
                svg_paths[#svg_paths + 1] = { layer = p.layer,
                                              el = svg_element(p.pts, p.close) }
            end
        end
    end

    -- Rewrite the SVG so an incremental plot can be watched as it grows
    if cfg.mode == "svg" or cfg.mode == "both" then
        M.write_svg()
    end
end

-- ── Drawing primitives ────────────────────────────────────────────────────────

--[[
    polyline(points, close)

    The core primitive that everything else builds on.

    points  — list of points in Lua drawing space; each may be a vec2 or a
              plain {x, y} table
    close   — if true, a final segment is drawn back to the first point
              (use this for closed shapes like rect, circle, polygon)

    All points are transformed through the current matrix before being buffered.

    G-code efficiency: the pen goes down once at the start and up once at the
    end, regardless of how many points are in the path.  Previously, line()
    lifted the pen between every segment — on a physical plotter each lift is
    a servo move + dwell, so this makes a significant difference for shapes
    with many segments (circles, text strokes, bezier curves).
--]]
function M.polyline(points, close)
    if #points < 2 then return end
    record(to_world(points), close and true or false, "polyline")
end

--[[
    line(x1, y1, x2, y2)  or  line(p1, p2)

    Draw a straight line segment.  Thin wrapper around polyline() with two
    points — exists as a convenience so scripts don't have to wrap pairs in
    tables for simple cases.
--]]
function M.line(a, b, c, d)
    local x1, y1, x2, y2
    if type(a) == "number" then x1, y1, x2, y2 = a, b, c, d
    else x1, y1 = xy(a); x2, y2 = xy(b) end
    M.polyline({{x1,y1}, {x2,y2}}, false)
end

--[[
    point(x, y)  or  point(p)

    Mark a single position.  A plotter cannot draw a zero-length line — the pen
    would go down and straight back up, leaving at best a faint dot — so this
    draws a very short stroke instead, dot_size mm long (default 0.3).
--]]
function M.point(a, b)
    local x, y = xy(a, b)
    local r = (cfg.dot_size or 0.3) * 0.5
    M.polyline({{x - r, y}, {x + r, y}}, false)
end

--[[
    polygon(points)

    Draw a closed shape through an arbitrary list of points.
    The last point is automatically connected back to the first.

    Example — an equilateral triangle:
        plotter.polygon({{100,70}, {130,130}, {70,130}})
--]]
function M.polygon(points)
    M.polyline(points, true)
end

--[[
    rect(x, y, w, h)  or  rect(pos, size)

    Draw a rectangle.  (x, y) is the top-left corner.
    A single closed polyline — one pen lift total instead of four.
--]]
function M.rect(a, b, c, d)
    local x, y, w, h
    if type(a) == "number" then x, y, w, h = a, b, c, d
    else x, y = xy(a); w, h = xy(b) end
    M.polyline({{x,y}, {x+w,y}, {x+w,y+h}, {x,y+h}}, true)
end

--[[
    rounded_rect(x, y, w, h, r [, steps])

    A rectangle with quarter-circle corners of radius r.  steps is the number
    of segments per corner (default 6).  r is clamped to half the shorter side,
    so an over-large radius gives a stadium shape rather than a self-crossing
    mess.
--]]
function M.rounded_rect(x, y, w, h, r, steps)
    steps = max(1, floor(steps or 6))
    r = min(r, abs(w) * 0.5, abs(h) * 0.5)

    if r <= 0 then return M.rect(x, y, w, h) end

    local pts = {}
    -- centre of each corner arc, and the angle its arc starts at (Y-down,
    -- so angles run clockwise on the page)
    local corners = {
        {x + w - r, y + h - r,   0},    -- bottom-right
        {x + r,     y + h - r,  90},    -- bottom-left
        {x + r,     y + r,     180},    -- top-left
        {x + w - r, y + r,     270},    -- top-right
    }

    for _, c in ipairs(corners) do
        for i = 0, steps do
            local a = rad(c[3] + i * 90 / steps)
            pts[#pts + 1] = {c[1] + r * math.cos(a), c[2] + r * math.sin(a)}
        end
    end

    M.polyline(pts, true)
end

--[[
    circle(cx, cy, r [, steps])  or  circle(centre, r [, steps])

    Draw a circle approximated as a closed polygon.
    steps controls smoothness (default 36 → 10° per segment).
    One pen lift total regardless of steps.

    Applying scale() before circle() produces an ellipse; use ellipse()
    directly if you want explicit rx/ry control without transform side-effects.
--]]
function M.circle(a, b, c, d)
    local cx, cy, r, steps
    if type(a) == "number" then cx, cy, r, steps = a, b, c, d
    else cx, cy = xy(a); r, steps = b, c end

    steps = max(3, floor(steps or 36))
    local pts = {}
    for i = 0, steps - 1 do
        local ang = rad(i * 360 / steps)
        pts[#pts + 1] = {cx + r * math.cos(ang), cy + r * math.sin(ang)}
    end
    M.polyline(pts, true)
end

--[[
    regular_polygon(cx, cy, r, n [, rotation])

    An n-sided regular polygon inscribed in a circle of radius r.
    rotation is in degrees, applied to the first vertex — the default puts a
    vertex straight up, which is how a triangle, pentagon or star is normally
    drawn.

    This is circle() with a small n, named so the intent is readable.
--]]
function M.regular_polygon(a, b, c, d, e)
    local cx, cy, r, n, rotation
    if type(a) == "number" then cx, cy, r, n, rotation = a, b, c, d, e
    else cx, cy = xy(a); r, n, rotation = b, c, d end

    n = max(3, floor(n or 3))
    rotation = rotation or 0

    local pts = {}
    for i = 0, n - 1 do
        local ang = rad(rotation - 90 + i * 360 / n)
        pts[#pts + 1] = {cx + r * math.cos(ang), cy + r * math.sin(ang)}
    end
    M.polyline(pts, true)
end

--[[
    arc(cx, cy, r, start_angle, end_angle [, steps])

    Draw a portion of a circle — an open curve, not a closed shape.
    Angles are in degrees, measured clockwise from the positive X axis
    (consistent with Y-down screen space).

    steps defaults to roughly one segment per 5° of span.  Angles are
    interpolated linearly from start to end, so to go "the short way" round
    past 0° use a negative span (e.g. 270 → -90) rather than 270 → 0.

    Example — a semicircle opening downward:
        plotter.arc(100, 100, 40, 0, 180)
--]]
function M.arc(a, b, c, d, e, f)
    local cx, cy, r, start_angle, end_angle, steps
    if type(a) == "number" then cx, cy, r, start_angle, end_angle, steps = a, b, c, d, e, f
    else cx, cy = xy(a); r, start_angle, end_angle, steps = b, c, d, e end

    local span = end_angle - start_angle
    steps = max(1, floor(steps or max(2, floor(abs(span) / 5))))

    local pts = {}
    for i = 0, steps do
        local ang = rad(start_angle + i * span / steps)
        pts[#pts + 1] = {cx + r * math.cos(ang), cy + r * math.sin(ang)}
    end
    M.polyline(pts, false)   -- open — arc does not close back to start
end

--[[
    ellipse(cx, cy, rx, ry [, steps])  or  ellipse(centre, radii [, steps])

    Draw an ellipse with independent horizontal and vertical radii.
    rx is the half-width, ry is the half-height.
    steps defaults to 36.

    Unlike using scale()+circle(), this does not affect the current transform,
    so you can draw an ellipse without disturbing subsequent geometry.
--]]
function M.ellipse(a, b, c, d, e)
    local cx, cy, rx, ry, steps
    if type(a) == "number" then cx, cy, rx, ry, steps = a, b, c, d, e
    else cx, cy = xy(a); rx, ry = xy(b); steps = c end

    steps = max(3, floor(steps or 36))
    local pts = {}
    for i = 0, steps - 1 do
        local ang = rad(i * 360 / steps)
        pts[#pts + 1] = {cx + rx * math.cos(ang), cy + ry * math.sin(ang)}
    end
    M.polyline(pts, true)
end

--[[
    bezier(x1,y1, cx1,cy1, cx2,cy2, x2,y2 [, steps])
    bezier(p0, c1, c2, p1 [, steps])

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
function M.bezier(a, b, c, d, e, f, g, h, i)
    local x1, y1, cx1, cy1, cx2, cy2, x2, y2, steps
    if type(a) == "number" then
        x1, y1, cx1, cy1, cx2, cy2, x2, y2, steps = a, b, c, d, e, f, g, h, i
    else
        x1, y1 = xy(a); cx1, cy1 = xy(b); cx2, cy2 = xy(c); x2, y2 = xy(d)
        steps = e
    end

    steps = max(1, floor(steps or 20))
    local pts = {}
    for k = 0, steps do
        local t  = k / steps
        local mt = 1 - t
        -- Expand the cubic formula — mt³, 3mt²t, 3mt·t², t³
        local bx = mt^3*x1 + 3*mt^2*t*cx1 + 3*mt*t^2*cx2 + t^3*x2
        local by = mt^3*y1 + 3*mt^2*t*cy1 + 3*mt*t^2*cy2 + t^3*y2
        pts[#pts + 1] = {bx, by}
    end
    M.polyline(pts, false)
end

--[[
    quad_bezier(x1,y1, cx,cy, x2,y2 [, steps])
    quad_bezier(p0, c, p1 [, steps])

    Quadratic Bézier — a single control point instead of two.

        P(t) = (1-t)²·P0 + 2(1-t)t·C + t²·P1
--]]
function M.quad_bezier(a, b, c, d, e, f, g)
    local x1, y1, cx, cy, x2, y2, steps
    if type(a) == "number" then x1, y1, cx, cy, x2, y2, steps = a, b, c, d, e, f, g
    else x1, y1 = xy(a); cx, cy = xy(b); x2, y2 = xy(c); steps = d end

    steps = max(1, floor(steps or 20))
    local pts = {}
    for k = 0, steps do
        local t  = k / steps
        local mt = 1 - t
        pts[#pts + 1] = {
            mt*mt*x1 + 2*mt*t*cx + t*t*x2,
            mt*mt*y1 + 2*mt*t*cy + t*t*y2,
        }
    end
    M.polyline(pts, false)
end

--[[
    curve(points, close, steps, tension)

    All arguments after `points` are optional: close (false), steps (12),
    tension (0.5).

    A smooth curve that passes THROUGH every given point, unlike bezier()
    whose control points are only pulled toward.  This is Processing's
    curveVertex(), a Catmull-Rom spline.

    Each span between consecutive points is drawn as a cubic whose tangents
    come from the neighbouring points, which is what makes the joins smooth.
    tension (default 0.5) scales those tangents: 0 gives straight lines, higher
    values bulge more.

    For an open curve the first and last points are duplicated to give the end
    spans a neighbour to work with; for a closed one the list wraps around.
--]]
function M.curve(points, close, steps, tension)
    local pts = M.curve_points(points, close, steps, tension)
    if pts then M.polyline(pts, close) end
end

--[[
    curve_points(points, close, steps, tension) -> points

    The smoothed point list curve() would draw, RETURNED rather than drawn --
    the same split as streamline().

    This is what makes a smooth shape hatchable: hatch() wants a polygon, and
    a handful of control points is not one. Sketch the outline with a few
    points, run it through here, and fill the result.

        local outline = plotter.curve_points(control_pts, true)
        plotter.hatch(outline, 45, 2)
        plotter.polyline(outline, true)

    Points are in the caller's coordinate space, untransformed -- the transform
    stack is applied later, when the result is drawn.
--]]
function M.curve_points(points, close, steps, tension)
    local n = #points
    if n < 2 then return nil end

    -- Two points have no curvature to find; hand them back as they came
    if n == 2 then
        local a, b = {xy(points[1])}, {xy(points[2])}
        return {a, b}
    end

    steps   = max(1, floor(steps or 12))
    tension = tension or 0.5

    -- Normalise the input to plain {x,y} pairs so indexing is cheap below
    local p = {}
    for i = 1, n do local x, y = xy(points[i]); p[i] = {x, y} end

    local function at(i)
        if close then return p[(i - 1) % n + 1] end
        return p[min(max(i, 1), n)]
    end

    local out = {}
    local last_span = close and n or (n - 1)

    for i = 1, last_span do
        local p0, p1, p2, p3 = at(i - 1), at(i), at(i + 1), at(i + 2)

        for k = 0, steps - 1 do
            local t  = k / steps
            local t2 = t * t
            local t3 = t2 * t

            -- Catmull-Rom basis, with tension scaling the tangent terms
            local m1x = tension * (p2[1] - p0[1])
            local m1y = tension * (p2[2] - p0[2])
            local m2x = tension * (p3[1] - p1[1])
            local m2y = tension * (p3[2] - p1[2])

            local h00 =  2*t3 - 3*t2 + 1
            local h10 =    t3 - 2*t2 + t
            local h01 = -2*t3 + 3*t2
            local h11 =    t3 -   t2

            out[#out + 1] = {
                h00*p1[1] + h10*m1x + h01*p2[1] + h11*m2x,
                h00*p1[2] + h10*m1y + h01*p2[2] + h11*m2y,
            }
        end
    end

    if not close then out[#out + 1] = {p[n][1], p[n][2]} end

    return out
end

--[[
    grid(x, y, w, h, cols, rows)

    Draw a grid of cols × rows cells filling the rectangle (x, y, w, h),
    including its outer border.

    Emitted as full-length lines rather than per-cell rectangles: one pen lift
    per grid line instead of one per cell, which for a 20×20 grid is 42 lifts
    instead of 400.
--]]
function M.grid(x, y, w, h, cols, rows)
    cols = max(1, floor(cols or 1))
    rows = max(1, floor(rows or cols))

    for i = 0, cols do
        local gx = x + w * i / cols
        M.line(gx, y, gx, y + h)
    end
    for j = 0, rows do
        local gyy = y + h * j / rows
        M.line(x, gyy, x + w, gyy)
    end
end

-- ── Processing-style shape building ───────────────────────────────────────────

local shape_pts = nil

--[[
    begin_shape() / vertex(x, y) / end_shape(close)

    Accumulate points one at a time and draw them as a single path, for when
    the vertices come out of a loop and collecting them into a table first
    would just be noise.

        plotter.begin_shape()
        for a = 0, 350, 10 do
            plotter.vertex(100 + 40*math.cos(math.rad(a)),
                           100 + 40*math.sin(math.rad(a)))
        end
        plotter.end_shape(true)
--]]
function M.begin_shape()
    shape_pts = {}
end

function M.vertex(a, b)
    if not shape_pts then
        error("plotter.vertex() called outside begin_shape()/end_shape()", 2)
    end
    local x, y = xy(a, b)
    shape_pts[#shape_pts + 1] = {x, y}
end

function M.end_shape(close)
    if not shape_pts then
        error("plotter.end_shape() called without begin_shape()", 2)
    end
    local pts = shape_pts
    shape_pts = nil
    M.polyline(pts, close)
end

-- ── Hatching ──────────────────────────────────────────────────────────────────

--[[
    hatch(shape, angle, spacing [, opts])

    Fill a closed shape with parallel lines — how a plotter fakes a solid fill,
    since it can only draw strokes.

    shape    a list of points, or a list of such lists.  When several are
             given, the first is the outline and the rest are holes.

             Holes must lie INSIDE the outline. Crossings are paired by the
             even-odd rule, which cannot tell a hole from an outline -- so a
             hole poking outside the shape it is cut from gets FILLED rather
             than cleared, which looks like the fill has leaked. If two regions
             need to punch each other out, make them adjoin rather than
             overlap.
    angle    hatch direction in degrees
    spacing  distance between adjacent lines, in mm

    opts.inset    pull the hatch in from the outline by this much (default 0)
    opts.outline  also stroke the shape's boundary (default false)
    opts.zigzag   join alternate line ends into one continuous path
                  (default false)

    How it works: rotate the polygon so the hatch direction becomes horizontal,
    walk scanlines down the rotated bounding box, and intersect each against
    every edge.  Sorting the crossings and pairing them off (1-2, 3-4, ...)
    is the even-odd rule, which is what makes concave shapes and holes come out
    right — a point is inside when a ray to it has crossed an odd number of
    edges.  Finally rotate the resulting spans back.

    zigzag is worth knowing about: without it every scanline is its own path
    and costs a pen lift, so a densely hatched shape can spend most of its time
    lifting.  With it, alternate lines are joined end to end into a single
    boustrophedon path — one lift for the whole fill.  It only kicks in where a
    scanline has exactly one span, so a shape that splits into several runs
    still breaks the path there rather than drawing across the gap.
--]]
function M.hatch(shape, angle, spacing, opts)
    opts    = opts or {}
    spacing = spacing or 1.0
    angle   = angle or 45

    if spacing <= 0 then
        error("hatch spacing must be positive, got " .. tostring(spacing), 2)
    end

    -- Accept a bare point list as well as a list of rings
    local rings
    if type(shape[1]) == "table" and shape[1][1] and type(shape[1][1]) == "table" then
        rings = shape
    elseif type(shape[1]) == "table" or type(shape[1]) == "userdata" then
        rings = {shape}
    else
        error("hatch expects a list of points, or a list of point lists", 2)
    end

    local a = rad(angle)
    local ca, sa = math.cos(-a), math.sin(-a)

    -- Rotate every ring into hatch-aligned space, tracking the bounding box
    local rot = {}
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge

    for ri, ring in ipairs(rings) do
        local r = {}
        for i = 1, #ring do
            local px, py = xy(ring[i])
            local rx = px * ca - py * sa
            local ry = px * sa + py * ca
            r[i] = {rx, ry}
            if rx < minx then minx = rx end
            if rx > maxx then maxx = rx end
            if ry < miny then miny = ry end
            if ry > maxy then maxy = ry end
        end
        rot[ri] = r
    end

    if minx > maxx then return end

    local inset = opts.inset or 0
    miny = miny + inset
    maxy = maxy - inset

    -- Rotate a hatch-space point back to drawing space
    local cb, sb = math.cos(a), math.sin(a)
    local function unrotate(x, y)
        return x * cb - y * sb, x * sb + y * cb
    end

    -- Start half a step in so the first line isn't flush with the boundary
    local y = miny + spacing * 0.5
    local flip = false
    local zig = nil          -- the continuous path being built, in zigzag mode

    local function close_zig()
        if zig and #zig >= 2 then M.polyline(zig, false) end
        zig = nil
    end

    while y <= maxy do
        -- Collect every edge crossing at this height
        local xs = {}
        for _, r in ipairs(rot) do
            local n = #r
            for i = 1, n do
                local p1, p2 = r[i], r[i % n + 1]
                local y1, y2 = p1[2], p2[2]
                -- Half-open test: counting a vertex for exactly one of its two
                -- edges is what stops a scanline through a vertex producing a
                -- doubled crossing and inverting inside/outside from there on.
                if (y1 <= y and y2 > y) or (y2 <= y and y1 > y) then
                    xs[#xs + 1] = p1[1] + (y - y1) / (y2 - y1) * (p2[1] - p1[1])
                end
            end
        end

        table.sort(xs)

        local spans = {}
        for i = 1, #xs - 1, 2 do
            if xs[i + 1] - xs[i] > 1e-9 then
                spans[#spans + 1] = {xs[i] + inset, xs[i + 1] - inset}
            end
        end

        if opts.zigzag and #spans == 1 then
            local s = spans[1]
            local x1, x2 = s[1], s[2]
            if flip then x1, x2 = x2, x1 end
            if x2 - x1 ~= 0 or true then
                zig = zig or {}
                local ax, ay = unrotate(x1, y)
                local bx, by = unrotate(x2, y)
                zig[#zig + 1] = {ax, ay}
                zig[#zig + 1] = {bx, by}
            end
        else
            close_zig()
            for _, s in ipairs(spans) do
                if s[2] > s[1] then
                    local ax, ay = unrotate(s[1], y)
                    local bx, by = unrotate(s[2], y)
                    M.polyline({{ax, ay}, {bx, by}}, false)
                end
            end
        end

        flip = not flip
        y = y + spacing
    end

    close_zig()

    if opts.outline then
        for _, ring in ipairs(rings) do
            M.polyline(ring, true)
        end
    end
end

-- ── Streamlines ───────────────────────────────────────────────────────────────

--[[
    streamline(start, field_fn, steps, step_len [, opts]) -> points

    Trace a path through a vector field and RETURN the points — this does not
    draw anything, so you can filter, trim or simplify the result before
    handing it to polyline().

    field_fn(p)  is called with a vec2 and must return a direction: a vec2, a
                 {x, y} table, or two numbers.  Magnitude is ignored; only the
                 direction is used, so a field of wildly varying strength still
                 advances at a steady step_len.

    opts.stop(p)  optional predicate — return true to end the trace early
    opts.min_mag  give up where the field goes slack (default 1e-9)

    Integration is midpoint (RK2) rather than Euler: sample the field, take a
    half step, sample again, and move using that second reading.  Euler visibly
    spirals outward on curved fields, which on a plot looks like drift rather
    than a flow line.

        local function field(p)
            local a = noise.fbm(p.x * 0.01, p.y * 0.01) * math.pi * 2
            return vec2.from_angle(a)
        end
        plotter.polyline(plotter.streamline(vec2(10, 10), field, 200, 1.5))
--]]
function M.streamline(start, field_fn, steps, step_len, opts)
    opts = opts or {}
    steps    = max(1, floor(steps or 100))
    step_len = step_len or 1.0
    local min_mag = opts.min_mag or 1e-9

    local vec2mod = require 'vec2'

    -- Normalise whatever field_fn returns into a unit direction
    local function direction(px, py)
        local a, b = field_fn(vec2mod.new(px, py))
        if a == nil then return nil end

        local dx, dy
        if type(a) == "number" then dx, dy = a, b
        else dx, dy = xy(a) end

        local m = sqrt(dx*dx + dy*dy)
        if m < min_mag then return nil end
        return dx / m, dy / m
    end

    local px, py = xy(start)
    local pts = {{px, py}}

    for _ = 1, steps do
        local dx, dy = direction(px, py)
        if not dx then break end

        -- Midpoint: probe half a step ahead, then move on that reading
        local mx, my = px + dx * step_len * 0.5, py + dy * step_len * 0.5
        local ex, ey = direction(mx, my)
        if not ex then ex, ey = dx, dy end

        px, py = px + ex * step_len, py + ey * step_len
        pts[#pts + 1] = {px, py}

        if opts.stop and opts.stop(vec2mod.new(px, py)) then break end
    end

    return pts
end

-- ── Painting with a brush ─────────────────────────────────────────────────────

--[[
    plotter.pot(name, x, y)   or   plotter.pot(name, vec2)
    plotter.pot(x, y)         or   plotter.pot(vec2)

    Register a paint pot at an absolute position on the bed.  The two-argument
    forms register the default pot, used when dip() is called with no name.

    Positions are ABSOLUTE and are never touched by the transform stack.  The
    pot is a physical object bolted to the bed: it does not move because your
    drawing is translated, rotated or scaled, and a dip that went through the
    transform would be a dip into the wrong place -- usually the bare bed, at
    speed.  For the same reason dip() bypasses the stack too.

        plotter.pot(15, 15)                  -- the default pot
        plotter.pot("red",   vec2(15, 15))
        plotter.pot("black", vec2(15, 45))
--]]
function M.pot(a, b, c)
    local name, x, y

    if type(a) == "string" then
        name = a
        x, y = xy(b, c)
    else
        name = "default"
        x, y = xy(a, b)
    end

    if x < 0 or y < 0 or x > cfg.width or y > cfg.height then
        warn("pot_" .. name, string.format(
            "paint pot %q at (%.1f, %.1f) is outside the %gx%g mm work area -- " ..
            "the machine may refuse the move or hit its limits",
            name, x, y, cfg.width, cfg.height))
    end

    pots[name] = {x = x, y = y}
    return M
end

-- The registered pots, as name -> {x = , y = }. Read-only.
function M.pots()
    return pots
end

--[[
    plotter.dip(name, opts)

    Reload the brush.  Both arguments are optional; dip() with no arguments
    dips the default pot with the configured timings.  Sequence:

        pen up  ->  travel to the pot  ->  pen down into the paint
                ->  wait dip_time  ->  pen up  ->  wait drip_time

    The final wait is what stops a freshly loaded brush flinging paint across
    the page on its way back to the drawing.

    opts may override any of dip_time, drip_time and pen_dip for this one dip
    -- a thin wash wants a shorter soak than thick acrylic, and the first dip
    of a session often wants a longer one to prime dry bristles.

        plotter.dip()
        plotter.dip("red")
        plotter.dip("red", { dip_time = 3, drip_time = 2 })
        plotter.dip({ pen_dip = 175 })       -- deeper, default pot

    Nothing happens immediately: the dip is queued in the path buffer like a
    stroke, so it stays in sequence with the drawing and acts as a barrier the
    travel optimiser will not reorder across.  See plotter.flush.
--]]
function M.dip(name, opts)
    check_open()

    if type(name) == "table" then
        name, opts = nil, name
    end
    opts = opts or {}

    -- An explicit name wins; otherwise reuse the last pot, so dip() in a
    -- two-colour painting does not silently jump back to the default.
    name = name or (last_pot and pots[last_pot] and last_pot) or "default"

    local pot = pots[name]
    if not pot then
        local known = {}
        for k in pairs(pots) do known[#known + 1] = k end
        table.sort(known)
        error(string.format(
            "no paint pot named %q. Register one with plotter.pot(), or set " ..
            "paint_pot / paint_pots in init(). Known pots: %s",
            name, #known > 0 and table.concat(known, ", ") or "(none)"), 2)
    end

    paths[#paths + 1] = {
        kind      = "dip",
        pot       = name,
        x         = pot.x,
        y         = pot.y,
        dip_time  = opts.dip_time  or cfg.dip_time,
        drip_time = opts.drip_time or cfg.drip_time,
        pen_dip   = opts.pen_dip   or cfg.pen_dip,
        layer     = current_layer,
    }

    last_pot = name
    drawn_since_dip = 0

    if cfg.auto_flush then M.flush() end
    return M
end

-- ── Text ──────────────────────────────────────────────────────────────────────

--[[
    text(x, y, str, height)  or  text(pos, str, height)

    Draw str using the Hershey Roman Simplex single-stroke font.
    (x, y) is the left end of the baseline; height is the cap height.

    Each Hershey character is made of one or more strokes (connected polylines).
    We draw each stroke as a single polyline() call — one pen lift per stroke
    rather than one per segment.  For a typical letter this is 1–3 lifts
    instead of 5–10.
--]]
function M.text(a, b, c, d)
    local x, y, str, height
    if type(a) == "number" then x, y, str, height = a, b, c, d
    else x, y = xy(a); str, height = b, c end

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

-- ── Introspection ─────────────────────────────────────────────────────────────

--[[
    plotter.paths()

    Every path drawn since init(), in world space, as
        { {pts = {{x,y}, ...}, close = bool, layer = name}, ... }

    Returned as a fresh list, though the path records inside it are live —
    treat them as read-only.  Useful for post-processing your own geometry, and
    it is what lets the test suite make assertions about what a primitive
    produced without parsing G-code.

    Dips are not paths and do not appear here; use plotter.queue() if you need
    to see the drawing and the reloads interleaved in order.
--]]
function M.paths()
    local out = {}
    for _, p in ipairs(paths) do
        if p.kind ~= "dip" then out[#out + 1] = p end
    end
    return out
end

--[[
    plotter.queue()

    Everything queued since init(), drawing paths and brush dips together, in
    the order they will be emitted.  Entries are distinguished by their `kind`
    field, "path" or "dip".

    Live, not copied. This is the raw buffer that paths() filters.
--]]
function M.queue()
    return paths
end

--[[
    plotter.bounds() -> min, max

    Bounding box of everything drawn so far, as two vec2.
    Returns nil if nothing has been drawn.
--]]
function M.bounds()
    if #paths == 0 then return nil end

    local vec2mod = require 'vec2'
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge

    for _, p in ipairs(paths) do
        -- Pots are hardware, not drawing: a dip must not stretch the bounding
        -- box of the artwork.
        for _, pt in ipairs(p.kind == "dip" and {} or p.pts) do
            if pt[1] < x0 then x0 = pt[1] end
            if pt[1] > x1 then x1 = pt[1] end
            if pt[2] < y0 then y0 = pt[2] end
            if pt[2] > y1 then y1 = pt[2] end
        end
    end

    return vec2mod.new(x0, y0), vec2mod.new(x1, y1)
end

--[[
    plotter.stats() -> table

    What the plot costs:
        paths      number of separate strokes (= pen lifts)
        draw_mm    distance drawn with the pen down
        travel_mm  distance moved with the pen up — pure overhead
        dips       number of brush reloads
        dwell_min  time spent waiting in and over the paint pot
        minutes    rough total time estimate

    Only counts work that has actually been flushed, since travel is only
    known once the emission order is fixed.

    The time estimate is movement at the configured feed rate plus dwell. Dwell
    is worth having in there: at a second in the pot and a second dripping, a
    painting that reloads every 50 mm can spend longer waiting than drawing.
--]]
function M.stats()
    local move_min = (cfg.feed and cfg.feed > 0)
                     and ((draw_len + travel_len) / cfg.feed) or 0
    return {
        paths     = flushed_paths,
        draw_mm   = draw_len,
        travel_mm = travel_len,
        dips      = dip_count,
        dwell_min = dwell_secs / 60,
        minutes   = move_min + dwell_secs / 60,
    }
end

-- ── Calibration helpers ───────────────────────────────────────────────────────

--[[
    plotter.moveto(x, y)  or  plotter.moveto(p)

    Rapid-move (G0) to an absolute position in Lua drawing coordinates
    (Y-down, origin top-left). Does NOT touch the pen — call penup() or
    pendown() before/after as needed.

    Intentionally bypasses the transform stack — this is for physical
    calibration (checking alignment, parking the head, etc.) where you want
    to go to a known real-world position, not a drawing-relative one.

    Only meaningful in serial/both mode; silently does nothing otherwise
    so you can leave calibration calls in a script without breaking SVG/gcode runs.
--]]
function M.moveto(a, b)
    if not want_serial() then return end
    local x, y = xy(a, b)
    gmove(x, y, nil)
    pen_x, pen_y = x, y
end

--[[
    plotter.servo(s)

    Send a raw servo position command M3 Sxx, where s is any value in the
    range your servo accepts (typically 0–180 for hobby servos wired to GRBL).

    Use this during calibration to sweep the servo and find the right
    pen-down height before committing the value to pen_down in your config.

    Example:
        plotter.servo(60)   -- try this height
        plotter.servo(45)   -- too low? try here
        -- once happy: set pen_down = 45 in your plotter.init() config
--]]
function M.servo(s)
    if not want_serial() then return end
    gcode(string.format("M3 S%d", s))
end

-- ── Machine state ─────────────────────────────────────────────────────────────

--[[
    plotter.home()

    Run a GRBL homing cycle ($H), driving the axes into their limit switches to
    establish a known machine position. Also clears the alarm state, which is
    the usual reason to call it.

    Blocks until GRBL answers, which it does only once the cycle has finished
    -- routinely 10 to 30 seconds. The reply timeout is raised for the duration
    anyway: serial.writeline already tolerates a long wait as long as the
    controller keeps answering status queries, but homing is the one operation
    where a machine grinding against a mis-set limit switch is a real
    possibility, and a wider margin there costs nothing.

    Needs homing enabled ($22=1); GRBL answers error:5 if it is not.
--]]
function M.home()
    local serial = require 'serial'
    if not serial.is_open() then
        error("home() needs an open serial connection", 2)
    end

    local prev = serial.set_timeout(120)
    local ok, err = pcall(serial.writeline, "$H")
    serial.set_timeout(prev)

    if not ok then error(err, 2) end
    return M
end

--[[
    plotter.unlock()

    Clear GRBL's alarm state ($X) without homing.

    Nothing moves, which makes it safe to call blind -- but GRBL is left with no
    idea where the machine is. That is fine for luaplot's coordinate model,
    which zeroes the work origin wherever the head happens to be sitting
    (G92 in the init preamble), so you park the head where you want the drawing
    to start and unlock. It is not fine if you were relying on machine
    coordinates or soft limits.
--]]
function M.unlock()
    local serial = require 'serial'
    if not serial.is_open() then
        error("unlock() needs an open serial connection", 2)
    end
    serial.writeline("$X")
    return M
end

--[[
    plotter.status() -> table

    The machine's current state and position, as
        { state = "Idle", mpos = {x,y,z}, wpos = {x,y,z}, wco = {x,y,z} }

    Reads a GRBL status report. See grbl.parse_status for the details of the
    conversion between machine and work coordinates.
--]]
function M.status()
    local grbl = require 'grbl'
    return grbl.status()
end

--[[
    plotter.is_locked() -> boolean

    Whether GRBL is currently refusing G-code because of an alarm.

    Probed with G4 P0, a zero-length dwell: harmless if accepted, error:9 if
    not. The obvious probe -- the ? status query -- is a realtime command that
    never answers "ok", so it would just sit there until the timeout.
--]]
function M.is_locked()
    local serial = require 'serial'
    if not serial.is_open() then return false end

    local ok, err = pcall(serial.writeline, "G4 P0")
    if ok then return false end
    return tostring(err):match("error:9") ~= nil
end

-- ── GRBL settings ─────────────────────────────────────────────────────────────

--[[
    plotter.grbl_settings() -> { [100] = 80.0, ... }

    Read GRBL's persistent settings with $$ and parse them into a table keyed
    by setting number.  The ones this project cares about most:

        $100  X steps/mm      $101  Y steps/mm
        $110  X max rate      $111  Y max rate
        $130  X max travel    $131  Y max travel

    Requires an open serial connection.
--]]
function M.grbl_settings()
    local serial = require 'serial'
    if not serial.is_open() then
        error("grbl_settings() needs an open serial connection", 2)
    end
    return M.parse_grbl_settings(serial.query("$$"))
end

--[[
    plotter.parse_grbl_settings(lines) -> table, order

    Split out from grbl_settings() so the parsing can be tested against canned
    responses without hardware.  Returns the settings table plus the setting
    numbers in the order they were received.
--]]
function M.parse_grbl_settings(lines)
    local out, order = {}, {}
    for _, line in ipairs(lines) do
        local n, v = line:match("^%s*%$(%d+)%s*=%s*([%-%d%.]+)")
        if n then
            local key = tonumber(n)
            out[key] = tonumber(v)
            order[#order + 1] = key
        end
    end
    return out, order
end

--[[
    plotter.grbl_set(n, value)

    Write one GRBL setting ($n=value).  These are stored in EEPROM and persist
    across power cycles, so back up before changing anything —
    tools/grbl-config.lua does exactly that.
--]]
function M.grbl_set(n, value)
    local serial = require 'serial'
    if not serial.is_open() then
        error("grbl_set() needs an open serial connection", 2)
    end
    -- %s on a float gives Lua's %.14g, which keeps the precision GRBL wants
    -- without printing 80.000000 for 80.
    serial.writeline(string.format("$%d=%s", n, tostring(value)))
end

-- ── Init & done ───────────────────────────────────────────────────────────────

--[[
    plotter.init(config)

    Required config fields:
        mode      "serial" | "svg" | "gcode" | "both"
        width     work area width  in mm (also SVG viewport width)
        height    work area height in mm (also SVG viewport height)

    Optional (all modes):
        origin    machine coordinates of the paper's near-left corner, as a
                  vec2 or {x, y}. Omitted, the plot starts wherever the head
                  is parked; given, it lands at the same physical place every
                  time. See the note in init() -- it changes which coordinate
                  frame is emitted, and the absolute frame needs homing.

    Optional (serial/both mode):
        port      serial port path  (default "/dev/ttyUSB0")
        baud      baud rate         (default 115200)
        feed      feed rate mm/min  (default 1000)
        pen_up    spindle S value for pen up   (default 90)
        pen_down  spindle S value for pen down (default 30)
        home      if true, run $H homing cycle on connect (default false)
        unlock    if true, clear GRBL's alarm with $X on connect, without
                  homing (default false). One of these two is needed whenever
                  homing is enabled on the controller, since GRBL boots into an
                  alarm and refuses G-code until told where it is.

    Optional (svg/both mode):
        svg_file  output file path  (default "output.svg")

    Optional (gcode mode):
        gcode_file  output file path  (default "output.nc")

    Optional (all modes):
        auto_flush  emit each primitive as it is drawn (default true).
                    Turn off for real-time plotting, where you control the
                    batches with flush().  Implied off by optimize.
        optimize    reorder paths to cut pen-up travel (default false)
        clip        "warn" (default) | "clip" | "off" — what to do with
                    geometry outside the work area
        dot_size    length of the stroke point() draws, mm (default 0.3)
        quiet       suppress the summary printed by done() (default false)

    Optional (brush painting -- see plotter.dip):
        paint_pot   position of the default pot, as vec2 or {x, y}
        paint_pots  named pots, e.g. { red = vec2(15,15), black = vec2(15,45) }
        dip_time    seconds to hold the brush in the paint (default 1.0)
        drip_time   seconds to hold it above the pot afterwards (default 1.0)
        pen_dip     servo value for the brush in the pot (default: pen_down)
        dip_every   reload automatically after this many mm drawn (default off)
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
        home      = config.home      or false,
        unlock    = config.unlock    or false,
        svg_file   = config.svg_file   or "output.svg",
        gcode_file = config.gcode_file or "output.nc",
        optimize   = config.optimize   or false,
        clip       = config.clip       or "warn",
        dot_size   = config.dot_size   or 0.3,
        quiet      = config.quiet      or false,

        -- Brush painting
        dip_time   = config.dip_time   or 1.0,
        drip_time  = config.drip_time  or 1.0,
        dip_every  = config.dip_every,
    }

    -- The paint surface sits lower than the paper, so dipping usually wants
    -- its own servo position. Falls back to pen_down when unset.
    cfg.pen_dip = config.pen_dip or cfg.pen_down

    --[[
        Where the page sits on the bed.

        Given as machine coordinates of the paper's NEAR-LEFT corner -- the
        same corner and the same numbers tools/pen-setup.lua takes as
        --origin, and that tools/jog.lua reads out when you zero the work
        origin there.

        Supplying it changes which coordinate frame the plot is emitted in,
        which is the part worth understanding:

          origin omitted   the preamble sends G92 X0 Y0, making wherever the
                           head happens to be the corner of the page. Nothing
                           needs homing; you park the head and plot.

          origin given     coordinates are absolute machine positions, so the
                           plot lands in the same physical place every time.
                           This needs the machine homed, and any leftover G92
                           offset cleared -- which the preamble does.
    --]]
    if config.origin then
        local ox, oy = xy(config.origin)
        cfg.origin = { x = ox, y = oy }
        cfg.absolute = true
    else
        cfg.origin = { x = 0, y = 0 }
        cfg.absolute = false
    end

    -- Reordering means holding paths back until flush(), so it cannot coexist
    -- with emitting each primitive as it is drawn.
    if config.auto_flush ~= nil then
        cfg.auto_flush = config.auto_flush
    else
        cfg.auto_flush = not cfg.optimize
    end
    if cfg.optimize then cfg.auto_flush = false end

    if cfg.clip ~= "warn" and cfg.clip ~= "clip" and cfg.clip ~= "off" then
        error(string.format(
            "bad clip mode %q (expected \"warn\", \"clip\" or \"off\")", cfg.clip), 2)
    end

    -- Reset state
    stack         = { identity() }
    pen_down      = false
    paths         = {}
    flushed       = 0
    svg_paths     = {}
    gcode_lines   = {}
    current_layer = nil
    emitted_layer = nil
    pen_x, pen_y  = 0, 0
    draw_len, travel_len = 0, 0
    flushed_paths = 0
    finished      = false
    warned        = {}
    shape_pts     = nil
    pots          = {}
    last_pot      = nil
    dip_count, dwell_secs, drawn_since_dip = 0, 0, 0

    -- Register any pots given in the config. M.pot does the bounds check.
    if config.paint_pot then
        M.pot(config.paint_pot)
    end
    if config.paint_pots then
        for name, pos in pairs(config.paint_pots) do M.pot(name, pos) end
    end

    -- The stock defaults suit some other machine's servo, and a pen driven to
    -- the wrong position lands on the paper hard.  Say so rather than guess.
    if want_serial() and (config.pen_up == nil or config.pen_down == nil) then
        warn("pen_values",
            "serial mode without explicit pen_up/pen_down — falling back to " ..
            "S90/S30, which are unlikely to match your servo. Run " ..
            "tools/calibrate.lua or set them in init().")
    end

    -- Open serial port if needed
    if want_serial() then
        local serial = require 'serial'
        serial.open(cfg.port, cfg.baud)
    end

    --[[
        Get GRBL out of its alarm state before the preamble, which is G-code
        and would otherwise be refused with error:9.

        This is not an edge case: GRBL boots into an alarm whenever homing is
        enabled ($22=1), so a script hits it on the very first run after the
        controller powers up. It used to fail on G21 with a bare error code,
        which said nothing about what to do.
    --]]
    if want_serial() then
        if cfg.home then
            M.home()
        elseif cfg.unlock then
            M.unlock()
        elseif M.is_locked() then
            error(
                "GRBL is in an alarm state and will not accept G-code.\n" ..
                "  This is normal after the controller powers up when homing " ..
                "is enabled ($22=1).\n" ..
                "  Add one of these to plotter.init():\n" ..
                "    home   = true   -- run a homing cycle ($H), establishing " ..
                "a known position\n" ..
                "    unlock = true   -- clear the alarm ($X) without moving; " ..
                "the drawing then\n" ..
                "                       starts from wherever the head is " ..
                "parked\n" ..
                "  Or call plotter.home() / plotter.unlock() yourself.", 2)
        end
    end

    -- Emit G-code preamble (goes to serial, file, or both depending on mode)
    if want_gcode() then
        gcode("G21")          -- metric units
        gcode("G90")          -- absolute positioning

        if cfg.absolute then
            --[[
                An explicit origin means the coordinates below are machine
                positions, so any work offset in force has to go first --
                otherwise the plot lands wherever the last G92 happened to
                leave the frame.

                This is not hypothetical: tools/jog.lua sets exactly such an
                offset when you press 0 to mark the paper corner, which is
                the very workflow that produces the origin you are passing in
                here. G92.1 cancels it.
            --]]
            gcode("G92.1")
        else
            -- No origin given, so the page starts where the head is now
            gcode("G92 X0 Y0 Z0")
        end

        gcode("M3 S0")        -- spindle on at 0 (servo initialise)
    end

    -- A stale work offset would silently displace an absolute plot, and the
    -- machine can tell us. Cheap to check, and the failure is otherwise a
    -- ruined sheet of paper.
    if cfg.absolute and want_serial() then
        local ok, st = pcall(M.status)
        if ok and st.wco and (math.abs(st.wco.x) > 1e-6 or math.abs(st.wco.y) > 1e-6) then
            warn("wco", string.format(
                "a work coordinate offset of (%.2f, %.2f) is still in force, " ..
                "so this plot will land that far from the origin you asked " ..
                "for. Clear it with G10 L2 P1 X0 Y0, or drop the origin " ..
                "option to plot relative to the head's current position.",
                st.wco.x, st.wco.y))
        end
    end
end

--[[
    plotter.write_svg()

    Write the accumulated geometry to the SVG file.  Called automatically by
    flush() and done(); exposed because a long-running script may want to
    snapshot without flushing.

    Layers become <g> elements with distinct stroke colours so you can tell
    them apart on screen.
--]]
function M.write_svg()
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

    -- Walk the elements in order, opening a <g> whenever the layer changes.
    -- Unlayered output (the common case) produces exactly the flat element
    -- list this always emitted, with no wrapper.
    local open_layer, first = nil, true
    local colour_of, next_colour = {}, 1

    for _, e in ipairs(svg_paths) do
        if first or e.layer ~= open_layer then
            if not first and open_layer ~= nil then f:write('  </g>\n') end
            if e.layer ~= nil then
                if not colour_of[e.layer] then
                    colour_of[e.layer] = LAYER_COLOURS[
                        (next_colour - 1) % #LAYER_COLOURS + 1]
                    next_colour = next_colour + 1
                end
                f:write(string.format('  <g id="%s" stroke="%s">\n',
                    tostring(e.layer), colour_of[e.layer]))
            end
            open_layer, first = e.layer, false
        end
        f:write(e.el .. "\n")
    end
    if open_layer ~= nil then f:write('  </g>\n') end

    f:write('</svg>\n')
    f:close()
end

--[[
    plotter.done([opts])

    Finish the plot: flush anything pending, lift the pen, return to the
    origin, write the output files, and close the serial port.

    Idempotent — calling it more than once is safe.  If you want the park and
    the file write but intend to keep drawing, pass { keep_open = true }, or
    use flush(), which does neither.

    opts.keep_open  leave the serial port open (default false)
--]]
function M.done(opts)
    opts = opts or {}

    M.flush()

    if not finished and want_gcode() then
        M.penup()
        -- Park at the page's near-left corner. With an origin set that is a
        -- real place on the bed rather than machine zero, which could be a
        -- long unnecessary traverse away.
        gmove(0, cfg.height, nil)
        gcode("M5")          -- spindle off
        pen_x, pen_y = 0, cfg.height
    end

    if want_serial() and not opts.keep_open then
        local serial = require 'serial'
        if serial.is_open() then serial.close() end
    end

    if cfg.mode == "gcode" then
        local f = assert(io.open(cfg.gcode_file, "w"))
        for _, line in ipairs(gcode_lines) do
            f:write(line .. "\n")
        end
        f:close()
        if not cfg.quiet then print("G-code written to " .. cfg.gcode_file) end
    end

    if cfg.mode == "svg" or cfg.mode == "both" then
        M.write_svg()
        if not cfg.quiet then print("SVG written to " .. cfg.svg_file) end
    end

    if not cfg.quiet and not finished then
        local st = M.stats()
        local dips = st.dips > 0
            and string.format("  |  %d %s (%.1f min)", st.dips,
                              st.dips == 1 and "dip" or "dips", st.dwell_min)
            or ""
        print(string.format(
            "%d paths  |  %.0f mm drawn  |  %.0f mm travel%s  |  ~%.1f min",
            st.paths, st.draw_mm, st.travel_mm, dips, st.minutes))
    end

    if not opts.keep_open then finished = true end
end

return M
