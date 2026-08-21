--[[
    monalisa.lua — a portrait assembled from luaplot primitives

    There is no image here to trace: luaplot cannot load one. So the picture
    has to be CONSTRUCTED, and the interesting question is what to construct it
    out of.

    ── Shape from geometry, tone from light ─────────────────────────────────────

    Two things have to be right for a face to read, and they want different
    tools.

    SHAPE is geometry. The oval of the face, the fall of the hair, the slope of
    the shoulders -- these are curves, and they are drawn as curves. Every
    region below is a handful of control points run through curve_points(),
    which is what makes them editable: nudge one number and the jaw moves.

    TONE is light. Where a region is dark and where it catches the light is a
    separate question from its outline, so it comes from a separate function.
    shade(x, y) models one light source up and to the left, plus a few soft
    shadows. It returns 0 for paper and 1 for full ink, and every renderer
    below reads it.

    Keeping the two apart is what stops the picture looking like a colouring
    book -- an outline with a fill -- and lets the tone run across a boundary
    where the real thing has no edge, which is most of a face.

    ── A different mark for each material ───────────────────────────────────────

    An engraver does not fill everything with the same lines, and neither does
    this. Each region is rendered with the primitive that suits what it is:

        background   bare paper, with curves for the distant landscape
        hair         streamlines combed along its fall
        face         stippling, the softest mark there is
        eyes, lips   explicit circles and curves -- the only real edges here
        dress        cross-hatching, the only way to reach near-black
        sleeves      nothing but fold curves over the dress
        hands        light stippling inside a drawn outline

    They hold together because every one of them takes its density from the
    same shade() function. Same light, different marks.

    ── Running it ───────────────────────────────────────────────────────────────

        ./luaplot examples/monalisa.lua
        ./luaplot examples/monalisa.lua serial /dev/cu.usbmodem1101
--]]

local plotter = require 'plotter'
local util    = require 'util'

local W, H = 270, 340

local mode = arg[1] or "svg"
local port = arg[2] or os.getenv("LUAPLOT_PORT") or "/dev/ttyUSB0"
local pen_up   = tonumber(os.getenv("LUAPLOT_PEN_UP"))   or 0
local pen_down = tonumber(os.getenv("LUAPLOT_PEN_DOWN")) or 150

local SEED = 20260820

plotter.init {
    mode     = mode,
    width    = W,
    height   = H,
    port     = port,
    baud     = 115200,
    feed     = 2000,
    pen_up   = pen_up,
    pen_down = pen_down,
    svg_file = "monalisa.svg",
    origin   = vec2(10, 10),
    home     = true,

    -- Thousands of marks generated region by region: without reordering, the
    -- pen spends most of the plot travelling between them.
    optimize = true,
    clip     = "clip",
}

noise.seed(SEED)
math.randomseed(SEED)

-- ── Geometry helpers ──────────────────────────────────────────────────────────

-- A few control points into a smooth closed outline.
-- tension pulls the curve toward the control polygon: 0.5 is a soft flowing
-- curve, 0.25 keeps corners crisp enough to survive as detail.
local function shape(ctrl, steps, tension)
    return plotter.curve_points(ctrl, true, steps or 10, tension)
end

-- ...and an open one
local function stroke(ctrl, steps)
    return plotter.curve_points(ctrl, false, steps or 10)
end

--[[
    Even-odd point-in-polygon.

    Needed because two of the renderers have to stay inside a shape that
    hatch() is not doing the work for: stippling rejects points outside the
    region, and hair streamlines stop when they leave it.
--]]
local function inside(poly, x, y)
    local n, hit = #poly, false
    for i = 1, n do
        local a, b = poly[i], poly[i % n + 1]
        if (a[2] > y) ~= (b[2] > y) then
            if x < a[1] + (y - a[2]) / (b[2] - a[2]) * (b[1] - a[1]) then
                hit = not hit
            end
        end
    end
    return hit
end

local function bbox(poly)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(poly) do
        x0 = math.min(x0, p[1]); x1 = math.max(x1, p[1])
        y0 = math.min(y0, p[2]); y1 = math.max(y1, p[2])
    end
    return x0, y0, x1, y1
end

-- ── The light model ───────────────────────────────────────────────────────────

--[[
    Soft shadows, as {x, y, rx, ry, rotation, weight}.

    These are the only blurry things in the picture, and they are deliberately
    blurry: sfumato is smooth tonal transition, so a soft falloff is the
    faithful primitive rather than a convenient one.
--]]
local SHADOWS = {
    { 88,  79, 11,  6, -5,  0.30},   -- eye sockets
    {112,  79, 11,  6,  5,  0.30},
    {105,  97,  4, 12,  4,  0.26},   -- alongside the nose
    {100, 101,  8,  3,  0,  0.34},   -- beneath it
    {100, 112, 11,  3,  0,  0.24},   -- under the lower lip
    { 89, 107,  4,  3,  0,  0.22},   -- mouth corners, where the smile goes
    {111, 107,  4,  3,  0,  0.22},
    {115,  97, 12, 23,  5,  0.46},   -- the shadow side of the face
    { 92, 100, 10, 12,  0, -0.10},   -- and the lit cheek opposite it
    {100, 120, 20,  7,  0,  0.60},   -- under the jaw, sitting the head on the neck
    {100, 132, 16,  8,  0,  0.30},   -- the neck's own shadow
    {119, 138, 14, 14,  0,  0.30},   -- neck, far side
}

--[[
    shade(x, y) -> 0 (bare paper) .. 1 (full ink)

    One light, up and to the left, as a linear ramp across the page -- the
    simplest thing that gives a face a lit side and a shadow side. The soft
    shadows above are added on top, and a gentle vignette darkens the corners,
    which is most of why a picture reads as a painting rather than a diagram.
--]]
local function shade(x, y)
    local v = util.map(x * 0.62 + y * 0.38, 30, 215, 0.02, 0.62)

    for _, s in ipairs(SHADOWS) do
        local a = math.rad(s[5])
        local dx, dy = x - s[1], y - s[2]
        local u =  dx * math.cos(a) + dy * math.sin(a)
        local w = -dx * math.sin(a) + dy * math.cos(a)
        v = v + s[6] * math.exp(-((u / s[3])^2 + (w / s[4])^2))
    end

    local vx, vy = (x - W * 0.5) / W, (y - H * 0.45) / H
    v = v + 0.55 * (vx * vx + vy * vy)

    return util.constrain(v, 0, 1)
end

-- ── The regions ───────────────────────────────────────────────────────────────

--[[
    Proportions first, because everything else hangs off them.

    The composition is a pyramid: the head at the apex, the shoulders sloping
    down and out, the base filling the bottom edge. That triangle is what makes
    the picture feel settled, and it is the reason the torso below is ONE shape
    rather than a bodice with two sleeves stuck on -- a figure assembled from
    separate islands reads as separate islands.

    With the background left as bare paper, that silhouette is the only thing
    holding the picture together, so it carries more weight here than it would
    against a filled ground.
--]]
local HEAD  = { x = 100, y = 86, rx = 27, ry = 34 }   -- face oval
local BROW  = 71
local EYE_Y = 80

local FACE = shape({
    {100,  52}, {117,  58}, {127,  78}, {126,  97},
    {117, 110}, {108, 115}, {100, 116}, { 92, 115},
    { 83, 110}, { 74,  97}, { 73,  78}, { 83,  58},
}, 12)

--[[
    The hair: two curtains that start narrow at the crown and flare as they
    fall, ending behind the shoulders rather than stopping at the jaw. The
    inner edge follows the face, the outer edge does not -- that gap is what
    gives the head its bulk.
--]]
local HAIR_L = shape({
    {100,  47}, { 78,  64}, { 68,  96}, { 70, 124}, { 64, 142},
    { 62, 150}, { 75, 148}, { 80, 128}, { 78, 104}, { 84,  72},
    { 92,  55},
}, 12)

local HAIR_R = shape({
    {100,  47}, {122,  64}, {132,  96}, {130, 124}, {136, 144},
    {138, 150}, {125, 148}, {120, 128}, {122, 104}, {116,  72},
    {108,  55},
}, 12)

-- The veil over the crown: one of the few light passages in the hair
local VEIL = shape({
    { 77,  70}, { 87,  51}, {113,  51}, {123,  70},
    {119,  73}, {110,  56}, { 90,  56}, { 81,  73},
}, 10)

--[[
    The torso, in one piece from shoulder to bottom edge.

    The last two control points sit just inside the frame, so the shape closes
    along the bottom and reads as a figure running off the page rather than a
    cut-out floating on it.
--]]
local TORSO = shape({
    { 26, 246}, { 34, 210}, { 46, 178}, { 60, 154}, { 74, 141},
    { 88, 136}, {100, 134}, {114, 137}, {128, 144}, {148, 162},
    {164, 194}, {178, 246},
}, 14)

-- The lit chest: a hole in the torso, so the dark stops at the neckline
local CHEST = shape({
    { 80, 144}, {100, 138}, {120, 145}, {116, 174},
    {100, 185}, { 84, 172},
}, 12)

--[[
    The hands.

    A hand is recognised by its OUTLINE -- specifically the scallop the
    fingertips make along one edge. So this is two silhouettes with the
    fingertips built in, not a stack of per-finger shapes, which only produces
    a tangle of overlapping outlines at this size.

    The two shapes ADJOIN rather than overlap, and that is deliberate: they are
    punched out of the dress as holes, and hatch pairs crossings by the
    even-odd rule, so two overlapping holes would fill their intersection back
    in. Sharing an edge instead of crossing it keeps both clear.

    The exact same polygons are used for the holes and for the drawn outlines,
    which is the only way to guarantee the dark stops precisely where the hand
    is drawn -- a hole even slightly out of step leaves a visible halo.
--]]

--[[
    The far hand, resting over the near wrist, fingers pointing away to the
    left.

    The fingertips alternate with the webs between them, and the curve is run
    at a low tension: at the default the smoothing rounds a 5 mm scallop
    straight back into an oval, and an oval is the difference between a hand
    and a bread roll.
--]]
local HAND_UPPER = shape({
    {148, 208}, {136, 196}, {116, 193}, {104, 195},
    { 88, 200}, { 84, 204},  -- index, two points so the tip is round not spiked
    { 96, 208},              -- web
    { 82, 210}, { 79, 214},  -- middle, the longest
    { 94, 218},              -- web
    { 82, 220}, { 80, 224},  -- ring
    { 95, 227},              -- web
    { 88, 229}, { 87, 233},  -- little
    {110, 236}, {132, 232}, {148, 220},
}, 10, 0.30)

-- The near forearm below it, running off toward the left edge
local HAND_LOWER = shape({
    { 52, 242}, { 58, 229}, { 78, 226}, { 96, 234},
    {116, 239}, {124, 242}, {104, 244}, { 72, 244},
}, 14, 0.35)

-- Where one finger meets the next, drawn inside the silhouette
local FINGER_LINES = {
    {{106, 197}, {100, 202}, { 96, 207}},
    {{108, 205}, {100, 211}, { 95, 217}},
    {{110, 213}, {102, 220}, { 96, 226}},
}

-- ── Renderers ─────────────────────────────────────────────────────────────────

--[[
    Stipple a region.

    Poisson-disk gives an even scatter; rejecting each point with a probability
    read from shade() turns that evenness into tone. Blue noise is what makes
    the gradient read as light rather than as texture -- uniform random points
    clump, and a clump looks like a mistake rather than a shadow.

    lo and hi map the region's own tonal range onto the field, so the face can
    stay pale everywhere while still being modelled.
--]]
local function stipple(region, spacing, lo, hi)
    local x0, y0, x1, y1 = bbox(region)
    local pts = util.poisson_disk(x1 - x0, y1 - y0, spacing)

    for _, p in ipairs(pts) do
        local x, y = x0 + p[1], y0 + p[2]
        if inside(region, x, y) then
            local t = util.map(shade(x, y), 0, 1, lo, hi)
            if math.random() < t then plotter.point(x, y) end
        end
    end
end

--[[
    Fill a region with hatching, in passes.

    hatch() takes one spacing per call, so tone comes from calling it more than
    once at slightly different angles. Every pass covers the whole region and
    they accumulate, which is how an engraver builds a dark too -- more passes,
    not finer lines.

    zigzag is off by default here. It saves a great many pen lifts, but the
    joins trace the region boundary, and on an edge running near-parallel to
    the hatch that shows up as a sawtooth fringe. Worth it on small shapes,
    not on the big ones where the edge is the silhouette.
--]]
local function hatch_tone(region, angle, spacing, passes, zigzag)
    for i = 1, (passes or 1) do
        plotter.hatch(region, angle + (i - 1) * 26, spacing * (1 + (i - 1) * 0.16),
                      { zigzag = zigzag or false })
    end
end

--[[
    Comb a region with streamlines.

    Hair is the one material here that is genuinely directional, and hatch()
    only draws straight lines. Tracing a field instead gives strands that curve
    with the head, and the separation test keeps them from converging into a
    solid mass the way flow lines otherwise do.
--]]
local function comb(region, field_fn, separation, step_len, max_steps)
    local x0, y0, x1, y1 = bbox(region)

    local occupied = {}
    local function key(cx, cy) return cx * 100003 + cy end

    local function too_close(x, y)
        local cx, cy = math.floor(x / separation), math.floor(y / separation)
        for j = cy - 1, cy + 1 do
            for i = cx - 1, cx + 1 do
                local bucket = occupied[key(i, j)]
                if bucket then
                    for _, q in ipairs(bucket) do
                        local dx, dy = q[1] - x, q[2] - y
                        if dx * dx + dy * dy < separation * separation then
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
            local k = key(math.floor(p[1] / separation), math.floor(p[2] / separation))
            occupied[k] = occupied[k] or {}
            table.insert(occupied[k], p)
        end
    end

    local seeds = util.poisson_disk(x1 - x0, y1 - y0, separation * 0.7)
    util.shuffle(seeds)

    for _, s in ipairs(seeds) do
        local sx, sy = x0 + s[1], y0 + s[2]
        if inside(region, sx, sy) and not too_close(sx, sy) then
            local pts = plotter.streamline(vec2(sx, sy), field_fn,
                max_steps, step_len, {
                    stop = function(p)
                        return not inside(region, p.x, p.y) or too_close(p.x, p.y)
                    end,
                })
            if #pts >= 5 then
                plotter.polyline(pts)
                occupy(pts)
            end
        end
    end
end

-- ── Background ────────────────────────────────────────────────────────────────

--[[
    The background is bare paper.

    An earlier version hatched it flat and horizontal, with the figure punched
    out as a hole -- the engraver's answer, and defensible on its own terms.
    But at a spacing a pen can actually manage it read as corduroy, and it
    competed with the figure instead of sitting behind it. White paper is the
    quieter and the better background, and it is also the one that makes the
    dress look as dark as it needs to.

    What is left is the landscape: ridges and the winding road, drawn as open
    curves.
--]]
--[[
    The landscape: ridges and the winding road, drawn OVER the haze rather than
    filled. That is how an engraving handles distance too -- the hatch is the
    air, and one darker line is a ridge standing out of it.

    Curves for the ridges, an arc for the far hill, a bezier for the road.
--]]
plotter.curve({{13, 116}, {30, 110}, {46, 117}, {62, 112}})
plotter.curve({{13, 133}, {28, 126}, {44, 132}, {60, 128}})
plotter.arc(34, 150, 22, 202, 338)

plotter.curve({{138, 108}, {154, 100}, {170, 106}, {187, 99}})
plotter.curve({{140, 125}, {158, 117}, {174, 123}, {187, 118}})
plotter.arc(164, 144, 20, 202, 338)

plotter.bezier(13, 164, 28, 148, 40, 138, 60, 128)

-- ── Hair ──────────────────────────────────────────────────────────────────────

--[[
    The field the strands follow.

    Mostly straight down, with a sideways lean that is strongest at the crown
    and fades away as the hair falls -- which is what hair does under gravity.
    A little noise so no two strands are exactly parallel.
--]]
local function hair_field(p)
    local splay = util.constrain(util.map(p.y, 50, 130, 1.0, 0.12), 0, 1)
    local lean  = (p.x - HEAD.x) / 30 * splay

    local wobble = noise.perlin(p.x * 0.06, p.y * 0.06) * 0.20
    return vec2(lean, 1):normalize():rotate(wobble)
end

comb(HAIR_L, hair_field, 0.8, 1.2, 130)
comb(HAIR_R, hair_field, 0.8, 1.2, 130)

-- The veil, hatched across the strands so it separates from them
plotter.hatch(VEIL, 0, 3.4, { zigzag = true })

-- ── Face ──────────────────────────────────────────────────────────────────────

--[[
    Stippled, and kept pale: the lit side of a face has to be nearly bare paper
    or it stops looking lit. Only the shadow side, the sockets and the jaw pick
    up real density, and all of it comes from shade().
--]]
stipple(FACE, 0.9, 0.02, 0.60)

-- ── Features ──────────────────────────────────────────────────────────────────

--[[
    The eyes.

    A face is recognised from very little, but that little has to be right: a
    heavy upper lid, a light lower one, and an iris sitting up under the lid
    rather than floating in the middle. The lower lid is barely drawn, which is
    what stops the eye reading as a drawn circle.
--]]
local function eye(cx, cy, w, h, lean)
    local hw, hh = w / 2, h / 2

    -- upper lid: the heaviest line on the face, drawn twice for weight
    for _, dy in ipairs({0, 0.3}) do
        plotter.curve({
            {cx - hw,     cy + lean + dy},
            {cx - hw / 3, cy - hh + dy},
            {cx + hw / 3, cy - hh + 0.4 + dy},
            {cx + hw,     cy - lean * 0.4 + dy},
        }, false, 8)
    end

    -- lower lid, flatter and lighter
    plotter.curve({
        {cx - hw, cy + lean}, {cx, cy + hh}, {cx + hw, cy - lean * 0.4},
    }, false, 8)

    -- iris and pupil
    plotter.circle(cx, cy - 0.25, hh * 0.82, 18)
    plotter.circle(cx, cy - 0.25, hh * 0.34, 12)
    plotter.hatch(shape({
        {cx - hh * 0.78, cy - 0.25}, {cx, cy - hh * 0.78 - 0.25},
        {cx + hh * 0.78, cy - 0.25}, {cx, cy + hh * 0.78 - 0.25},
    }, 8), 45, 0.5, { zigzag = true })
end

eye( 88, EYE_Y, 13, 5.2,  1.1)
eye(112, EYE_Y, 13, 5.2, -1.1)

-- Brows: soft in the painting, almost absent. One faint curve each.
plotter.curve({{80, BROW + 2}, {88, BROW - 1}, {96, BROW + 1}}, false, 8)
plotter.curve({{104, BROW + 1}, {112, BROW - 1}, {120, BROW + 2}}, false, 8)

-- The nose: no outline at all. One curve down the shadow side and the nostril
-- shadow beneath. An outlined nose is the fastest route to a cartoon.
plotter.curve({{100, 76}, {104, 88}, {105, 95}, {101, 99}}, false, 10)
plotter.hatch(shape({
    { 93, 101}, {100,  99}, {107, 101}, {101, 105}, { 94, 104},
}, 8), 0, 0.85, { zigzag = true })

--[[
    The mouth.

    The whole painting turns on this. The line between the lips is the only
    hard edge; the corners lift a fraction and then sink into the soft shadows
    listed in SHADOWS, which is the trick that makes the expression shift
    depending on where you look.
--]]
plotter.curve({
    { 88, 107.5}, { 94, 106}, {100, 106.4}, {106, 105.8}, {112, 107},
}, false, 12)

plotter.curve({{90, 110}, {100, 112}, {110, 109.5}}, false, 10)

-- ── Torso ─────────────────────────────────────────────────────────────────────

--[[
    The dark that makes everything else look light. Three passes at slightly
    different angles: no single pass at a spacing a pen can manage reads as
    anything but grey.

    CHEST goes in as a hole, so the dark stops cleanly at the neckline.
--]]
stipple(CHEST, 1.5, 0.02, 0.40)

-- The hands are punched out alongside the chest, so the dark never runs over
-- them. Two passes rather than three: the dress has to be the darkest thing in
-- the picture, not a black hole that swallows everything at the base.
hatch_tone({TORSO, CHEST, HAND_UPPER, HAND_LOWER}, 62, 1.9, 2)

-- The neckline is a real edge and gets a real line
plotter.curve({{80, 144}, {100, 138}, {120, 145}}, false, 10)

--[[
    The sleeves get no fill of their own -- the folds do that work.

    An earlier version hatched them a second time to separate them from the
    bodice, which needed the hands punched out of that pass too, and a hole
    that is not INSIDE its outer ring gets filled rather than cleared: the
    even-odd rule has no way to tell the two apart. Three curves per sleeve say
    the same thing with none of that.
--]]
for _, f in ipairs({
    {{32, 194}, {48, 188}, {66, 184}},
    {{29, 212}, {46, 206}, {66, 202}},
    {{34, 230}, {50, 224}, {68, 219}},
}) do
    plotter.curve(f, false, 8)
end

for _, f in ipairs({
    {{134, 194}, {152, 190}, {170, 196}},
    {{131, 212}, {150, 208}, {172, 214}},
    {{136, 230}, {154, 226}, {170, 232}},
}) do
    plotter.curve(f, false, 8)
end

-- ── Hands ─────────────────────────────────────────────────────────────────────

--[[
    The hands close the base of the pyramid and are the second place the eye
    goes after the face, so they stay light: outlined, barely shaded. A heavy
    pair of hands drags the whole picture down, which is why the shading here
    is stippling at its sparsest rather than any kind of hatching.
--]]
plotter.polyline(HAND_LOWER, true)
stipple(HAND_LOWER, 2.1, 0.02, 0.30)

plotter.polyline(HAND_UPPER, true)
stipple(HAND_UPPER, 2.1, 0.02, 0.22)

for _, f in ipairs(FINGER_LINES) do
    plotter.curve(f, false, 8)
end

-- ── Frame and caption ─────────────────────────────────────────────────────────

plotter.rect(12, 12, 176, 234)
plotter.rect(9, 9, 182, 240)

-- Centred with text_width, the same way hello.lua does it
local caption = "LA GIOCONDA"
local cap_h = 4.5
plotter.text((W - plotter.text_width(caption, cap_h)) / 2, 254, caption, cap_h)

-- A signature up the right edge, using the transform stack
plotter.push()
    plotter.translate(196, 246)
    plotter.rotate(-90)
    plotter.text(0, 0, "LUAPLOT", 3.2)
plotter.pop()

plotter.done()
