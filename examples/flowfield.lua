--[[
    flowfield.lua — streamlines through a Perlin noise field

    The canonical generative plotter piece, and a tour of most of what luaplot
    added alongside vec2: noise for the field, streamline() to trace it, and
    the travel optimiser to make the result actually plottable.

    ── How it works ─────────────────────────────────────────────────────────────

    A "flow field" is just a function from position to direction. Here the
    direction at a point comes from fBm noise sampled at that point, mapped
    from its -1..1 range onto a full turn:

        angle = fbm(x * scale, y * scale) * 2*pi

    Because noise is continuous, neighbouring points get near-identical
    directions, so paths traced through the field run alongside each other
    without crossing — which is what gives these images their combed, contour-
    map look. Turn SCALE up and the field becomes turbulent; turn it down and
    the lines go nearly straight.

    Seeds are set explicitly so a plot you like can be reproduced exactly:
    noise.seed picks the field, math.randomseed picks where the lines start.

    ── Running it ───────────────────────────────────────────────────────────────

        ./luaplot examples/flowfield.lua
        ./luaplot examples/flowfield.lua gcode
        ./luaplot examples/flowfield.lua serial /dev/cu.usbmodem1101
--]]

local plotter = require 'plotter'
local util    = require 'util'

local W, H = 200, 260

-- Mode and port come from the command line so this file works on any machine.
local mode = arg[1] or "svg"
local port = arg[2] or os.getenv("LUAPLOT_PORT") or "/dev/ttyUSB0"
local pen_up   = tonumber(os.getenv("LUAPLOT_PEN_UP"))   or 0
local pen_down = tonumber(os.getenv("LUAPLOT_PEN_DOWN")) or 150

-- ── Parameters ────────────────────────────────────────────────────────────────

local FIELD_SEED  = 20260820   -- which field
local SCATTER_SEED = 4         -- where the lines start

local SCALE     = 0.006        -- noise frequency; higher = more turbulent
local OCTAVES   = 3            -- detail in the field
local STEP      = 1.2          -- mm per integration step
local MAX_STEPS = 600          -- longest a line may run
local MIN_STEPS = 20           -- discard lines that die almost immediately
local SEPARATION = 1.6         -- minimum mm between any two lines
local MARGIN    = 8            -- keep the drawing off the page edge

-- ── Setup ─────────────────────────────────────────────────────────────────────

plotter.init {
    mode     = mode,
    width    = W,
    height   = H,
    port     = port,
    baud     = 115200,
    feed     = 2000,
    pen_up   = pen_up,
    pen_down = pen_down,
    svg_file = "flowfield.svg",

    -- Streamlines are generated in scatter order, so consecutive paths can
    -- start at opposite corners. Reordering them is a large saving here.
    optimize = true,

    -- The stop predicate below already keeps lines on the page; clip is the
    -- backstop for the one step that carries a line past the edge before the
    -- predicate sees it.
    clip     = "clip",
}

noise.seed(FIELD_SEED)
math.randomseed(SCATTER_SEED)

-- ── The field ─────────────────────────────────────────────────────────────────

--[[
    Direction at a point.

    fbm returns -1..1; multiplying by 2*pi turns the whole noise range into a
    full rotation, so the field sweeps through every direction rather than
    wobbling around one. vec2.from_angle turns that back into a direction.
--]]
local function field(p)
    local angle = noise.fbm(p.x * SCALE, p.y * SCALE, {octaves = OCTAVES}) * math.pi * 2
    return vec2.from_angle(angle)
end

-- ── Keeping the lines apart ───────────────────────────────────────────────────

--[[
    A flow field attracts. Trace enough lines through one and they converge,
    pile into the same channels, and the page turns into a solid black blot --
    which wastes an hour of plotting time and a lot of ink to draw something
    you cannot see.

    The fix is Jobard and Lefer's evenly-spaced streamline placement: as each
    line is traced, stop it the moment it comes within SEPARATION of any line
    already drawn. Lines then crowd right up to their neighbours and no
    further, so density is even everywhere and the field's structure stays
    legible.

    Occupancy is tracked in a hash of grid cells sized to SEPARATION, so the
    proximity test looks at nine cells rather than every point drawn so far --
    the same trick poisson_disk uses, and the reason this stays fast at tens of
    thousands of points.
--]]
local occupied = {}
local CELL = SEPARATION

local function cell_key(cx, cy)
    return cx * 100003 + cy      -- a large prime keeps the two axes distinct
end

local function too_close(x, y)
    local cx, cy = math.floor(x / CELL), math.floor(y / CELL)
    for j = cy - 1, cy + 1 do
        for i = cx - 1, cx + 1 do
            local bucket = occupied[cell_key(i, j)]
            if bucket then
                for _, q in ipairs(bucket) do
                    local dx, dy = q[1] - x, q[2] - y
                    if dx * dx + dy * dy < SEPARATION * SEPARATION then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function occupy(pts)
    for _, p in ipairs(pts) do
        local key = cell_key(math.floor(p[1] / CELL), math.floor(p[2] / CELL))
        local bucket = occupied[key]
        if not bucket then bucket = {}; occupied[key] = bucket end
        bucket[#bucket + 1] = p
    end
end

-- Stop a streamline at the page edge, or where it meets an existing line
local function should_stop(p)
    if p.x < MARGIN or p.y < MARGIN or p.x > W - MARGIN or p.y > H - MARGIN then
        return true
    end
    return too_close(p.x, p.y)
end

-- ── Draw ──────────────────────────────────────────────────────────────────────

--[[
    Candidate starting points come from a Poisson-disk scatter, shuffled.

    Poisson disk gives an even spread with no clumping, and shuffling means the
    page fills in randomly rather than sweeping across, so no region gets
    priority over another. Most candidates will be rejected outright for
    landing on a line already drawn -- that is the placement working.
--]]
local starts = util.poisson_disk(W - MARGIN * 2, H - MARGIN * 2, SEPARATION * 0.8)
util.shuffle(starts)

local drawn = 0

for i = 1, #starts do
    local sx = starts[i][1] + MARGIN
    local sy = starts[i][2] + MARGIN

    -- Skip a start that already sits on top of an existing line
    if not too_close(sx, sy) then
        local pts = plotter.streamline(vec2(sx, sy), field, MAX_STEPS, STEP,
                                       { stop = should_stop })

        -- Short lines read as specks rather than strokes, and each still costs
        -- a full pen lift, so they are not worth drawing.
        if #pts >= MIN_STEPS then
            plotter.polyline(pts)
            occupy(pts)
            drawn = drawn + 1
        end
    end
end

io.write(string.format("%d streamlines placed from %d candidate starts\n",
                       drawn, #starts))

plotter.done()
