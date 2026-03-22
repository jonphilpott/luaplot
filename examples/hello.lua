--[[
    examples/hello.lua — luaplot primitives showcase

    One example of every drawing primitive, laid out as a reference sheet.
    Run it, open the SVG, and you can see exactly what each primitive produces.

    Layout (200 × 200 mm page):
      - Outer border
      - Title: "LUAPLOT" centred at top using text_width()
      - Six cells arranged in a 3×2 grid, one primitive per cell:
          line, polyline, polygon
          rect, circle, ellipse
      - Arc and bezier drawn across the full width below the grid
      - Rotated label at bottom-right using push/pop/rotate

    Usage:
        ./luaplot examples/hello.lua           -- SVG (default)
        ./luaplot examples/hello.lua gcode     -- write output.nc
        ./luaplot examples/hello.lua serial    -- send to plotter
--]]

local plotter = require 'plotter'

-- ── Init ──────────────────────────────────────────────────────────────────────

local mode = arg[1] or "svg"

plotter.init {
    mode     = mode,
    width    = 200,
    height   = 200,
    port     = "/dev/tty.usbmodem1101",
    baud     = 115200,
    feed     = 1500,
    pen_up   = 90,
    pen_down = 35,
    svg_file = "hello.svg",
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Draw a small label centred below a point
local function label(cx, y, str)
    local w = plotter.text_width(str, 4)
    plotter.text(cx - w/2, y, str, 4)
end

-- ── Border & title ────────────────────────────────────────────────────────────

plotter.rect(4, 4, 192, 192)

-- text_width() centres the title without guesswork
local title    = "LUAPLOT PRIMITIVES"
local title_h  = 8
local title_x  = 100 - plotter.text_width(title, title_h) / 2
plotter.text(title_x, 14, title, title_h)

-- Horizontal rule under the title
plotter.line(4, 20, 196, 20)

-- ── Cell grid ─────────────────────────────────────────────────────────────────
--
-- Six cells: 3 columns × 2 rows, each 60 mm wide × 55 mm tall.
-- Cells start at y=22 with a 4 mm gutter between rows.
-- Column centres: 33, 100, 167
--
--   [  line  ] [ polyline ] [ polygon ]
--   [  rect  ] [  circle  ] [ ellipse ]

local col = {33, 100, 167}   -- cell centre x values
local row = {50, 120}        -- cell centre y values (shape centre, not cell top)

-- Vertical dividers
plotter.line(66,  20, 66,  136)
plotter.line(133, 20, 133, 136)

-- Horizontal divider between rows
plotter.line(4, 84, 196, 84)

-- ── line ──────────────────────────────────────────────────────────────────────

--[[
    The simplest primitive: a single straight segment from A to B.
    Everything else ultimately bottoms out here (or in polyline).
--]]
plotter.line(col[1]-20, row[1]-10, col[1]+20, row[1]+10)
label(col[1], row[1]+18, "line")

-- ── polyline ──────────────────────────────────────────────────────────────────

--[[
    A connected open path through multiple points.
    One pen lift at the start and one at the end — far more efficient than
    calling line() for each segment individually.
--]]
plotter.polyline({
    {col[2]-22, row[1]+10},
    {col[2]-11, row[1]-10},
    {col[2],    row[1]+10},
    {col[2]+11, row[1]-10},
    {col[2]+22, row[1]+10},
}, false)
label(col[2], row[1]+18, "polyline")

-- ── polygon ───────────────────────────────────────────────────────────────────

--[[
    A closed shape through arbitrary points.
    Like polyline() with the last point connected back to the first.
    Here: a hexagon computed by stepping around a circle in 60° increments.
--]]
do
    local pts = {}
    for i = 0, 5 do
        local a = math.rad(i * 60 - 90)   -- -90° so flat edge is at top
        table.insert(pts, {
            col[3] + 18 * math.cos(a),
            row[1] + 18 * math.sin(a),
        })
    end
    plotter.polygon(pts)
end
label(col[3], row[1]+18, "polygon")

-- ── rect ──────────────────────────────────────────────────────────────────────

--[[
    An axis-aligned rectangle specified as top-left corner + width + height.
    Internally a closed polyline — one pen lift total.
--]]
plotter.rect(col[1]-20, row[2]-14, 40, 28)
label(col[1], row[2]+20, "rect")

-- ── circle ────────────────────────────────────────────────────────────────────

--[[
    A circle approximated as a closed polygon.
    steps=48 gives smooth output at this size; for small circles steps=24 is
    fine and saves pen travel time.
--]]
plotter.circle(col[2], row[2], 20, 48)
label(col[2], row[2]+26, "circle")

-- ── ellipse ───────────────────────────────────────────────────────────────────

--[[
    An ellipse with independent horizontal (rx) and vertical (ry) radii.
    Unlike scale()+circle(), ellipse() does not affect the current transform.
--]]
plotter.ellipse(col[3], row[2], 26, 14)
label(col[3], row[2]+20, "ellipse")

-- ── arc ───────────────────────────────────────────────────────────────────────

--[[
    An open arc: a portion of a circle between two angles.
    Angles are in degrees, clockwise from the positive X axis.
    Here: two arcs that form a pair of brackets around the centre of the page.
--]]
plotter.line(4, 136, 196, 136)   -- divider above arc/bezier band

-- Left bracket arc — opens right (270° → 90° the short way via 0°)
plotter.arc(72, 158, 24, 270, 90, 24)

-- Right bracket arc — opens left (90° → 270° the short way via 180°)
plotter.arc(128, 158, 24, 90, 270, 24)

-- Small label between the brackets
local arc_label = "arc"
local aw = plotter.text_width(arc_label, 4)
plotter.text(100 - aw/2, 161, arc_label, 4)

-- ── bezier ────────────────────────────────────────────────────────────────────

--[[
    Cubic Bézier curve: two endpoints and two control points.
    The control points act like magnets pulling the curve off the straight
    line between the endpoints.  Here an S-curve runs across the lower band.
--]]
plotter.line(4, 178, 196, 178)   -- divider above bezier

-- S-curve: start bottom-left, end top-right, control points create the S
plotter.bezier(
    20,  188,    -- start point    (left, lower)
    80,  168,    -- control point 1 (pulls start upward-right)
    120, 188,    -- control point 2 (pulls end downward-left)
    180, 168,    -- end point      (right, upper)
    32           -- steps: more segments = smoother curve
)

label(100, 192, "bezier")

-- ── Rotated text via push/pop ─────────────────────────────────────────────────

--[[
    push() and pop() let you apply a temporary transform without affecting
    anything drawn before or after.  Here we rotate a small label 90°
    and tuck it into the right margin.
--]]
plotter.push()
    plotter.translate(193, 100)  -- right-margin position
    plotter.rotate(-90)          -- rotate 90° counter-clockwise
    local ml = "REFERENCE SHEET"
    plotter.text(-plotter.text_width(ml, 3.5)/2, 0, ml, 3.5)
plotter.pop()

-- ── Done ──────────────────────────────────────────────────────────────────────

plotter.done()
