--[[
    brush.lua — painting with a brush instead of a pen

    Brush work is not pen work with a wider line. The differences that matter:

      * A brush holds a finite amount of paint, so the plot is a sequence of
        strokes punctuated by trips back to the pot. Here dip_every handles
        that automatically -- roughly one sweep per load.

      * Fewer, longer, more confident strokes. A pen plot can afford ten
        thousand hairline segments; a brush cannot, and a stroke that outlives
        its load of paint fades out halfway. The composition below is 60-odd
        strokes, not thousands.

      * Two colours means two brushes, not one brush and two pots -- you cannot
        clean a brush mid-plot. Each colour is a layer, so the plot pauses and
        asks you to swap brushes between them, and each layer dips its own pot.

      * pen_dip is deeper than pen_down. The paint surface is well below the
        paper, and a brush that only descends to drawing height comes back up
        dry.

    ── Running it ───────────────────────────────────────────────────────────────

        ./luaplot examples/brush.lua
        ./luaplot examples/brush.lua serial /dev/cu.usbmodem1101

    Preview it as SVG first: the two layers come out in different colours so
    you can see the split, and the summary tells you how many reloads and how
    much of the run is spent waiting for paint to drip.
--]]

local plotter = require 'plotter'
local util    = require 'util'

local W, H = 200, 260

local mode = arg[1] or "svg"
local port = arg[2] or os.getenv("LUAPLOT_PORT") or "/dev/ttyUSB0"
local pen_up   = tonumber(os.getenv("LUAPLOT_PEN_UP"))   or 0
local pen_down = tonumber(os.getenv("LUAPLOT_PEN_DOWN")) or 150

-- ── Parameters ────────────────────────────────────────────────────────────────

local SEED   = 20260820
local MARGIN = 18

local SWEEP_TOP    = 40                 -- the band of horizontal sweeps
local SWEEP_BOTTOM = 150
local SWEEPS       = 22

local REED_TOP    = 155                 -- the cluster of vertical marks
local REED_BOTTOM = H - MARGIN
local REEDS       = 34

-- ── Setup ─────────────────────────────────────────────────────────────────────

plotter.init {
    mode     = mode,
    width    = W,
    height   = H,
    port     = port,
    baud     = 115200,
    feed     = 1200,                    -- slower than a pen; paint needs time to lay down
    pen_up   = pen_up,
    pen_down = pen_down,
    svg_file = "brush.svg",

    -- Two pots bolted to the bed, clear of the paper. These positions are
    -- absolute and the transform stack never touches them.
    paint_pots = {
        ink   = vec2(8, 20),
        ochre = vec2(8, 55),
    },

    -- Down into the paint is deeper than down onto the paper.
    pen_dip   = math.min(pen_down + 25, 180),
    dip_time  = 1.5,                    -- soak
    drip_time = 2.0,                    -- then hang over the pot so it does not drip on the page

    -- One brush load is about one sweep. Slightly above the longest stroke, so
    -- each sweep starts fully loaded rather than reloading part-way.
    dip_every = 180,

    optimize  = true,
    clip      = "clip",
}

noise.seed(SEED)
math.randomseed(SEED)

-- ── The wash: long horizontal sweeps ──────────────────────────────────────────

--[[
    Each sweep is one loaded stroke, drawn left to right with a gentle noise
    wobble so it reads as a brush rather than a ruler.

    Kept a little under dip_every so a stroke never runs dry halfway. The
    optimiser cannot reorder these past their dips, so every sweep gets the
    load of paint that was fetched for it.
--]]
plotter.layer("ink")
plotter.dip("ink")

for i = 0, SWEEPS - 1 do
    local y = util.map(i, 0, SWEEPS - 1, SWEEP_TOP, SWEEP_BOTTOM)

    -- Vary the length so the block of sweeps has a soft, uneven edge
    local x0 = MARGIN + util.random_gaussian(0, 4)
    local x1 = W - MARGIN - math.abs(util.random_gaussian(0, 10))

    local pts = {}
    local steps = 40
    for k = 0, steps do
        local x = util.lerp(x0, x1, k / steps)
        -- A slow vertical drift, plus a faster small wobble
        local drift  = noise.perlin(x * 0.012, i * 0.6) * 2.2
        local wobble = noise.perlin(x * 0.09,  i * 3.1) * 0.5
        pts[#pts + 1] = vec2(x, y + drift + wobble)
    end

    plotter.polyline(pts)
end

-- ── The marks: a cluster of vertical reeds ────────────────────────────────────

--[[
    A second brush, so a second layer. On hardware the plot parks and asks you
    to swap before this starts; in SVG the layer simply comes out in a
    different colour.

    Starting points come from a Poisson-disk scatter so the cluster is dense
    without any two reeds landing on top of each other.
--]]
plotter.layer("ochre")
plotter.dip("ochre")

local roots = util.poisson_disk(W - MARGIN * 2, 26, 4.5)
util.shuffle(roots)

for i = 1, math.min(REEDS, #roots) do
    local base = vec2(roots[i][1] + MARGIN, REED_BOTTOM - roots[i][2] * 0.4)

    -- Each reed leans a little, and taller ones lean further
    local height = util.random_range(18, REED_BOTTOM - REED_TOP)
    local lean   = util.random_gaussian(0, 0.22)

    local pts = {}
    local steps = 14
    for k = 0, steps do
        local t = k / steps
        -- Quadratic ease on the lean, so the reed curves rather than tilting
        local x = base.x + lean * height * t * t
        local y = base.y - height * t
        pts[#pts + 1] = vec2(x, y)
    end

    plotter.polyline(pts)
end

-- ── Finish ────────────────────────────────────────────────────────────────────

plotter.done()

local s = plotter.stats()
io.write(string.format(
    "%d strokes, %d reloads -- %.0f%% of the run is waiting for paint\n",
    s.paths, s.dips, s.dwell_min / s.minutes * 100))
