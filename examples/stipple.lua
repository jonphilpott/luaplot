--[[
    stipple.lua — variable-density stippling from Worley noise, plus hatching

    Two ways a plotter makes tone out of nothing but strokes:

      1. STIPPLING — thousands of tiny marks, denser where the image is darker.
      2. HATCHING  — parallel lines filling a shape.

    This draws both so you can compare them on the same page.

    ── Getting variable density out of blue noise ───────────────────────────────

    poisson_disk gives an EVEN scatter, which is the opposite of what tone
    needs. The standard trick is rejection sampling: generate the scatter at
    the finest spacing you want anywhere, then keep each point with probability
    equal to the darkness at that position. Dark areas keep nearly every point,
    light areas keep almost none, and the survivors inherit blue noise's lack
    of clumping — so the gradient reads as tone rather than as texture.

    Here the darkness comes from Worley noise. f2 - f1 (the gap between the
    nearest and second-nearest feature points) is near zero exactly on the
    boundary between two cells, so inverting it draws a dark web along the
    cell edges: a cracked, organic, dried-mud structure.

    ── Running it ───────────────────────────────────────────────────────────────

        ./luaplot examples/stipple.lua
        ./luaplot examples/stipple.lua gcode
        ./luaplot examples/stipple.lua serial /dev/cu.usbmodem1101
--]]

local plotter = require 'plotter'
local util    = require 'util'

local W, H = 200, 260

local mode = arg[1] or "svg"
local port = arg[2] or os.getenv("LUAPLOT_PORT") or "/dev/ttyUSB0"
local pen_up   = tonumber(os.getenv("LUAPLOT_PEN_UP"))   or 0
local pen_down = tonumber(os.getenv("LUAPLOT_PEN_DOWN")) or 150

-- ── Parameters ────────────────────────────────────────────────────────────────

local SEED       = 20260820
local MARGIN     = 15
local CELL_SCALE = 0.035      -- Worley frequency; lower = bigger cells
local MIN_SPACING = 1.1       -- closest two dots may ever be, mm
local DOT         = 0.45      -- length of each stipple mark, mm

plotter.init {
    mode     = mode,
    width    = W,
    height   = H,
    port     = port,
    baud     = 115200,
    feed     = 2000,
    pen_up   = pen_up,
    pen_down = pen_down,
    svg_file = "stipple.svg",
    dot_size = DOT,

    -- Thousands of independent dots in scatter order: without reordering, the
    -- pen spends nearly all its time in the air.
    optimize = true,
    clip     = "clip",
}

noise.seed(SEED)
math.randomseed(SEED)

-- ── Regions ───────────────────────────────────────────────────────────────────

local FRAME_TOP    = MARGIN + 12
local FRAME_BOTTOM = H - MARGIN - 55
local HATCH_TOP    = FRAME_BOTTOM + 12

-- ── Tone ──────────────────────────────────────────────────────────────────────

--[[
    Darkness at a point, 0 (blank paper) to 1 (as dense as the spacing allows).

    f2 - f1 is small near a cell boundary and large at a cell's centre, so
    1 - (f2 - f1) is a dark web tracing the boundaries. smoothstep sharpens
    that into distinct veins instead of a soft blur, and a gentle vertical
    gradient keeps the panel from reading as a flat field.
--]]
local function darkness(x, y)
    local f1, f2 = noise.worley(x * CELL_SCALE, y * CELL_SCALE)
    local edge = util.smoothstep(0.55, 0.05, f2 - f1)

    local gradient = util.map(y, FRAME_TOP, FRAME_BOTTOM, 1.0, 0.35)
    return util.constrain(edge * gradient, 0, 1)
end

-- ── Stipple ───────────────────────────────────────────────────────────────────

local panel_w = W - MARGIN * 2
local panel_h = FRAME_BOTTOM - FRAME_TOP

local candidates = util.poisson_disk(panel_w, panel_h, MIN_SPACING)
local dots = 0

for _, p in ipairs(candidates) do
    local x, y = p[1] + MARGIN, p[2] + FRAME_TOP

    -- Rejection sampling: keep a point with probability equal to the darkness
    -- there. This is what turns an even scatter into a tonal image.
    if math.random() < darkness(x, y) then
        plotter.point(x, y)
        dots = dots + 1
    end
end

plotter.rect(MARGIN, FRAME_TOP, panel_w, panel_h)

-- ── Hatch ─────────────────────────────────────────────────────────────────────

--[[
    The same cellular structure rendered as hatching instead.

    Each band is filled at an angle taken from Worley's cell_id, so adjacent
    bands hatch in different directions and read as separate facets. zigzag
    joins each band's scanlines into a single continuous path -- one pen lift
    per band rather than one per line, which on real hardware is the
    difference between a minute and ten.
--]]
local BANDS = 7
local band_w = panel_w / BANDS
local band_h = H - MARGIN - HATCH_TOP

for i = 0, BANDS - 1 do
    local x = MARGIN + i * band_w

    -- A stable per-band angle, so the pattern is reproducible with the seed
    local _, _, id = noise.worley((i + 0.5) * 0.7, 0.5)
    local angle = (id % 6) * 30

    local band = {
        {x,          HATCH_TOP},
        {x + band_w, HATCH_TOP},
        {x + band_w, HATCH_TOP + band_h},
        {x,          HATCH_TOP + band_h},
    }

    plotter.hatch(band, angle, 1.2 + (id % 4) * 0.5,
                  { zigzag = true, inset = 0.6 })
    plotter.polyline(band, true)
end

-- ── Caption ───────────────────────────────────────────────────────────────────

local caption = "WORLEY STIPPLE + HATCH"
local cap_h = 5
plotter.text((W - plotter.text_width(caption, cap_h)) / 2, MARGIN + 4, caption, cap_h)

io.write(string.format("%d dots kept from %d candidates\n", dots, #candidates))

plotter.done()
