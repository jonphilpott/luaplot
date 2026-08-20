-- mandelbrot.lua
--
-- Renders the Mandelbrot set as escape-time contour lines using the
-- Marching Squares algorithm.
--
-- ── What is the Mandelbrot set? ──────────────────────────────────────────────
-- Each point c in the complex plane is tested by iterating:
--   z_{n+1} = z_n² + c,  starting from z_0 = 0
-- If |z| never exceeds 2 the point is "inside" the set.
-- If it escapes, we record *how many iterations* it took — the "escape time".
--
-- ── Why contours instead of pixels? ─────────────────────────────────────────
-- A plotter can't fill regions — it only draws lines. So instead of colouring
-- each pixel, we draw the *boundary* between iteration bands:
--   "escaped in < 2 iterations"  vs  ">= 2 iterations"
--   "escaped in < 4 iterations"  vs  ">= 4 iterations"
--   ... and so on up to MAX_ITER.
-- The result looks like a topographic map of the set. Deeper = more rings.
--
-- ── What is Marching Squares? ────────────────────────────────────────────────
-- For each square cell in our grid, classify each of the 4 corners as
-- "above" or "below" the current threshold. With 4 binary corners there are
-- 2⁴ = 16 possible patterns. Each pattern tells us which edges the contour
-- line crosses, and we draw a short segment through those crossing points.
-- String enough segments together across the grid and you get smooth contours.
--
-- Reference: the algorithm is the 2D analogue of Marching Cubes
-- (Lorensen & Cline, SIGGRAPH 1987). The 2D version is described on Wikipedia
-- under "Marching squares".
--
-- Run as SVG first — this script does a lot of computation:
--   ./luaplot examples/mandelbrot.lua

local plotter = require 'plotter'

local W, H = 250, 320

-- Mode and port come from the command line so this file works on any machine:
--   ./luaplot examples/mandelbrot.lua              -- SVG (default)
--   ./luaplot examples/mandelbrot.lua gcode        -- write a .nc file
--   ./luaplot examples/mandelbrot.lua serial       -- plot it, port from $LUAPLOT_PORT
--   ./luaplot examples/mandelbrot.lua serial /dev/cu.usbmodem1101
--
-- pen_up/pen_down are servo positions specific to your machine -- set
-- $LUAPLOT_PEN_UP and $LUAPLOT_PEN_DOWN, or edit the fallbacks here.
local mode = arg[1] or "svg"
local port = arg[2] or os.getenv("LUAPLOT_PORT") or "/dev/ttyUSB0"
local pen_up   = tonumber(os.getenv("LUAPLOT_PEN_UP"))   or 0
local pen_down = tonumber(os.getenv("LUAPLOT_PEN_DOWN")) or 150

plotter.init {
    mode     = mode,
    width    = W,
    height   = H,
    port     = port,
    baud     = 115200,
    feed     = 5000,
    pen_up   = pen_up,
    pen_down = pen_down,
    svg_file = "mandelbrot.svg",

    -- Marching squares emits thousands of short disconnected segments in scan
    -- order, close to the worst case for pen-up travel. Reordering them is the
    -- difference between a plot that finishes and one that does not.
    optimize = true,
}

-- ── Parameters ───────────────────────────────────────────────────────────────

-- The region of the complex plane to sample.
-- Re (real axis) runs left–right, Im (imaginary) runs bottom–top in maths,
-- but we'll flip Im to match our Y-down screen convention below.
local RE_MIN, RE_MAX = -2.5,  1.0
local IM_MIN, IM_MAX = -2.3,  2.3

-- Cell size in mm. Each cell becomes one marching-squares evaluation.
-- 1 mm gives good detail; 0.5 mm gives finer contours but 4× the work.
local CELL = 1.0

-- Maximum iterations. Points that survive this long are considered "inside".
-- Higher values sharpen the boundary at the cost of computation time.
local MAX_ITER = 128

-- Iso-levels: the iteration thresholds at which we draw a contour ring.
-- Powers of 2 mirror the self-similar structure of the set naturally —
-- each doubling captures one more layer of the fractal boundary detail.
local LEVELS = { 2, 4, 8, 16, 32, 64, MAX_ITER }

-- ── Grid dimensions ──────────────────────────────────────────────────────────

local COLS = math.floor((W - 10) / CELL)
local ROWS = math.floor((H - 10) / CELL)
local OX   = (W - COLS * CELL) * 0.5   -- left margin so grid is centred
local OY   = (H - ROWS * CELL) * 0.5   -- top margin

-- ── Coordinate helpers ───────────────────────────────────────────────────────

-- Grid index (col, row) → screen mm (x, y).
-- col=0 is the left column; row=0 is the top row (Y-down).
local function to_screen(col, row)
    return OX + col * CELL,
           OY + row * CELL
end

-- Grid index (col, row) → complex number (re, im).
-- Row 0 maps to IM_MAX (top of screen = most positive imaginary value)
-- because our screen Y is flipped relative to the mathematical Im axis.
local function to_complex(col, row)
    local re =  RE_MIN + (col / COLS) * (RE_MAX - RE_MIN)
    local im =  IM_MAX - (row / ROWS) * (IM_MAX - IM_MIN)
    return re, im
end

-- ── Mandelbrot iteration ──────────────────────────────────────────────────────

-- Returns the escape time for complex point (re + i·im): the number of
-- iterations before |z| > 2, or MAX_ITER if it never escapes.
--
-- We work in components (x = Re(z), y = Im(z)) to avoid building complex
-- number objects on every iteration.  The recurrence z² + c expands as:
--   Re(z²) = x² - y²        Im(z²) = 2xy
-- so the update is: x' = x²-y² + re,  y' = 2xy + im
--
-- The escape condition |z| > 2 is equivalent to x²+y² > 4, which avoids
-- a square-root call on every step.
local function mandelbrot(re, im)
    local x, y = 0.0, 0.0
    for i = 1, MAX_ITER do
        local x2, y2 = x * x, y * y
        if x2 + y2 > 4.0 then return i end
        x, y = x2 - y2 + re, 2.0 * x * y + im
    end
    return MAX_ITER
end

-- ── Precompute escape-time grid ───────────────────────────────────────────────

-- We compute the escape time for every grid point *once*, then reuse it for
-- all iso-levels. Without this cache, each level would recompute the same
-- values — 7× wasted work.
--
-- grid[row][col] is 0-indexed to match our loop variables cleanly.

io.write(string.format("Computing %d × %d grid...\n", COLS + 1, ROWS + 1))
io.flush()

local grid = {}
for row = 0, ROWS do
    local grow = {}
    for col = 0, COLS do
        local re, im = to_complex(col, row)
        grow[col] = mandelbrot(re, im)
    end
    grid[row] = grow
end

io.write(string.format("Done. Drawing %d contour levels...\n", #LEVELS))
io.flush()

-- ── Marching Squares lookup table ────────────────────────────────────────────

-- Corner labels and their bit weights in the case index:
--   tl (top-left)  = bit 3 (weight 8)
--   tr (top-right) = bit 2 (weight 4)
--   br (bot-right) = bit 1 (weight 2)
--   bl (bot-left)  = bit 0 (weight 1)
-- case = tl*8 + tr*4 + br*2 + bl*1
--
-- A corner is 1 ("above") if its escape time >= the current threshold.
--
-- Edges — named by position, defined by which corner pair they connect:
--   T (top)    : tl(1) — tr(2)
--   R (right)  : tr(2) — br(3)
--   B (bottom) : br(3) — bl(4)
--   L (left)   : bl(4) — tl(1)
-- (corner indices match the corners[] array built per cell below)
--
-- Each case maps to zero, one, or two line segments.
-- Each segment is a pair of edge indices {e1, e2}.
-- Cases 5 and 10 are "saddle points" — the contour splits into two segments.

local T, R, B, L = 1, 2, 3, 4

--                case: corners above    segment(s)
local CASES = {
    [0]  = {},                            -- none above
    [1]  = {{L, B}},                      -- bl
    [2]  = {{R, B}},                      -- br
    [3]  = {{L, R}},                      -- bl, br
    [4]  = {{T, R}},                      -- tr
    [5]  = {{T, R}, {L, B}},             -- tr, bl  (saddle)
    [6]  = {{T, B}},                      -- tr, br
    [7]  = {{T, L}},                      -- tr, br, bl  (= tl below)
    [8]  = {{T, L}},                      -- tl
    [9]  = {{T, B}},                      -- tl, bl
    [10] = {{T, L}, {R, B}},             -- tl, br  (saddle)
    [11] = {{T, R}},                      -- tl, bl, br  (= tr below)
    [12] = {{L, R}},                      -- tl, tr
    [13] = {{R, B}},                      -- tl, tr, bl  (= br below)
    [14] = {{L, B}},                      -- tl, tr, br  (= bl below)
    [15] = {},                            -- all above
}

-- ── Linear interpolation along an edge ───────────────────────────────────────

-- Given the screen positions and escape-time values of two corners, find
-- where the escape time equals 'threshold' by linear interpolation.
--
-- If v1 and v2 are on opposite sides of the threshold:
--   t = (threshold - v1) / (v2 - v1)    (0 < t < 1)
--   crossing = p1 + t * (p2 - p1)
--
-- This gives smooth-looking contours compared to using the edge midpoint.
-- It's equivalent to what a graphics renderer does when anti-aliasing edges.
local function interp_edge(x1, y1, v1, x2, y2, v2, threshold)
    local dv = v2 - v1
    if math.abs(dv) < 1e-9 then
        -- Degenerate: both corners have same value — use midpoint
        return (x1 + x2) * 0.5, (y1 + y2) * 0.5
    end
    local t = (threshold - v1) / dv
    return x1 + t * (x2 - x1),
           y1 + t * (y2 - y1)
end

-- ── Render contours ───────────────────────────────────────────────────────────

-- Edge connectivity: each edge connects two specific corners.
-- Corner indices in the per-cell corners[] array (1-indexed):
--   1=tl  2=tr  3=br  4=bl
local EDGE_CORNERS = {
    {1, 2},  -- T: tl → tr
    {2, 3},  -- R: tr → br
    {3, 4},  -- B: br → bl
    {4, 1},  -- L: bl → tl
}

for level_idx, level in ipairs(LEVELS) do
    io.write(string.format("  Level %d/%d (threshold = %d)...\n",
        level_idx, #LEVELS, level))
    io.flush()

    for row = 0, ROWS - 1 do
        for col = 0, COLS - 1 do

            -- Step 1: read the four corner escape times
            local vtl = grid[row    ][col    ]
            local vtr = grid[row    ][col + 1]
            local vbr = grid[row + 1][col + 1]
            local vbl = grid[row + 1][col    ]

            -- Step 2: classify each corner (1 = above threshold, 0 = below)
            local atl = vtl >= level and 1 or 0
            local atr = vtr >= level and 1 or 0
            local abr = vbr >= level and 1 or 0
            local abl = vbl >= level and 1 or 0

            -- Step 3: build the 4-bit case index
            local case = atl * 8 + atr * 4 + abr * 2 + abl * 1

            local segs = CASES[case]
            if segs and #segs > 0 then

                -- Step 4: compute the screen positions of all four corners
                local xtl, ytl = to_screen(col,     row    )
                local xtr, ytr = to_screen(col + 1, row    )
                local xbr, ybr = to_screen(col + 1, row + 1)
                local xbl, ybl = to_screen(col,     row + 1)

                -- Pack corners into an array for indexed access
                local corners = {
                    {xtl, ytl, vtl},   -- 1 = tl
                    {xtr, ytr, vtr},   -- 2 = tr
                    {xbr, ybr, vbr},   -- 3 = br
                    {xbl, ybl, vbl},   -- 4 = bl
                }

                -- Step 5: for each line segment in this case, compute the
                -- two edge-crossing points and draw the segment
                for _, epair in ipairs(segs) do
                    local function crossing(edge_idx)
                        local ci = EDGE_CORNERS[edge_idx]
                        local c1 = corners[ci[1]]
                        local c2 = corners[ci[2]]
                        return interp_edge(
                            c1[1], c1[2], c1[3],
                            c2[1], c2[2], c2[3],
                            level)
                    end

                    local x1, y1 = crossing(epair[1])
                    local x2, y2 = crossing(epair[2])
                    plotter.line(x1, y1, x2, y2)
                end
            end

        end
    end
end

io.write("Finalising...\n")
io.flush()

plotter.done()

io.write("Done.\n")
