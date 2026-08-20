--[[
    util.lua — the small functions every generative sketch ends up rewriting

    Three groups:

      1. Processing's maths vocabulary
           map, lerp, norm, constrain, wrap, smoothstep, round, sign, dist

      2. Seeded random helpers
           random_range, random_gaussian, random_choice, random_weighted, shuffle

      3. Point distributions — scattering points well is most of composition
           poisson_disk, halton, halton2d, grid

    Everything random here goes through math.random, so one math.randomseed(n)
    at the top of a sketch reproduces the whole thing.  Noise is deliberately
    NOT part of that: noise.seed() is separate, so you can re-roll a scatter
    while holding the noise field still, or the reverse.

    Names are snake_case to match the rest of luaplot, with Processing's
    camelCase spellings registered as aliases so sketches port over unchanged.

        local util = require 'util'
        local x = util.map(i, 0, n, 20, 180)
--]]

local M = {}

local floor, sqrt, log = math.floor, math.sqrt, math.log
local cos, sin, pi     = math.cos, math.sin, math.pi
local min, max, random = math.min, math.max, math.random

-- ── Processing maths ──────────────────────────────────────────────────────────

--[[
    map(value, lo1, hi1, lo2, hi2)

    Re-range a value from one interval to another.  The workhorse of
    generative code: turning a loop counter into a coordinate, a noise value
    into an angle, a distance into a spacing.

        util.map(i, 1, count, 20, 180)      -- spread i across the page

    Does not clamp — a value outside the source range maps outside the target
    range, which is usually what you want.  Wrap in constrain() if not.
--]]
function M.map(value, lo1, hi1, lo2, hi2)
    if hi1 == lo1 then return lo2 end
    return lo2 + (value - lo1) / (hi1 - lo1) * (hi2 - lo2)
end

-- Linear interpolation: t = 0 gives a, t = 1 gives b
function M.lerp(a, b, t)
    return a + (b - a) * t
end

-- Where value sits between lo and hi, as 0..1. The inverse of lerp.
function M.norm(value, lo, hi)
    if hi == lo then return 0 end
    return (value - lo) / (hi - lo)
end

-- Clamp to [lo, hi]
function M.constrain(value, lo, hi)
    if value < lo then return lo end
    if value > hi then return hi end
    return value
end

--[[
    wrap(value, lo, hi)

    Wrap into [lo, hi) — like modulo, but correct for negative values and for
    ranges that don't start at zero.  Use it to keep a particle on the page by
    letting it reappear on the opposite edge.
--]]
function M.wrap(value, lo, hi)
    local span = hi - lo
    if span <= 0 then return lo end
    return lo + (value - lo) % span
end

--[[
    smoothstep(edge0, edge1, x)

    A clamped 0..1 ramp with zero slope at both ends, so transitions ease in
    and out instead of starting and stopping abruptly.
--]]
function M.smoothstep(edge0, edge1, x)
    local t = M.constrain(M.norm(x, edge0, edge1), 0, 1)
    return t * t * (3 - 2 * t)
end

-- Like smoothstep but with zero second derivative at the ends too — visibly
-- smoother when the result drives a position rather than a colour.
function M.smootherstep(edge0, edge1, x)
    local t = M.constrain(M.norm(x, edge0, edge1), 0, 1)
    return t * t * t * (t * (t * 6 - 15) + 10)
end

function M.round(x)
    return floor(x + 0.5)
end

function M.sign(x)
    if x > 0 then return 1 end
    if x < 0 then return -1 end
    return 0
end

function M.dist(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return sqrt(dx * dx + dy * dy)
end

-- ── Random ────────────────────────────────────────────────────────────────────

--[[
    random_range([lo,] hi)

    A uniform float. With one argument the range is [0, hi); with two, [lo, hi).
    math.random already does integers — this is the float case.
--]]
function M.random_range(lo, hi)
    if hi == nil then lo, hi = 0, lo end
    return lo + random() * (hi - lo)
end

--[[
    random_gaussian(mean, sd)          -- both optional

    Normally distributed, mean 0 and standard deviation 1 by default.

    Gaussian jitter looks organic in a way uniform jitter does not: most values
    land near the mean with occasional outliers, which reads as hand-drawn
    rather than noisy.

    Box-Muller generates two independent samples at once, and the usual trick
    is to cache the second for the next call. This deliberately does not: a
    cached value survives math.randomseed(), so reseeding would not reproduce
    the same sequence, and the number of math.random() draws per call would
    depend on call parity -- which quietly desynchronises anything else drawing
    from the same stream. Stateless costs one extra log and cos per call and is
    always reproducible.
--]]
function M.random_gaussian(mean, sd)
    mean = mean or 0
    sd   = sd or 1

    -- u1 must be nonzero: log(0) is -inf
    local u1 = random()
    while u1 <= 1e-12 do u1 = random() end
    local u2 = random()

    return mean + sqrt(-2 * log(u1)) * cos(2 * pi * u2) * sd
end

-- Pick one element of a list uniformly. Returns nil for an empty list.
function M.random_choice(list)
    local n = #list
    if n == 0 then return nil end
    return list[random(n)]
end

--[[
    random_weighted(list, weights)

    Pick an element with probability proportional to its weight.  weights is a
    parallel list of non-negative numbers; they need not sum to 1.

        util.random_weighted({"line", "arc", "dot"}, {5, 2, 1})
--]]
function M.random_weighted(list, weights)
    local n = #list
    if n == 0 then return nil end
    if #weights < n then
        error("random_weighted: need one weight per element", 2)
    end

    local total = 0
    for i = 1, n do
        if weights[i] < 0 then
            error("random_weighted: weights must be non-negative", 2)
        end
        total = total + weights[i]
    end
    if total <= 0 then return nil end

    local r, acc = random() * total, 0
    for i = 1, n do
        acc = acc + weights[i]
        if r < acc then return list[i], i end
    end
    return list[n], n            -- only reachable through rounding
end

--[[
    shuffle(list) -> list

    Fisher-Yates, in place, returning the same list for chaining.
    Every permutation is equally likely, which the "sort by random comparator"
    trick people reach for is not.
--]]
function M.shuffle(list)
    for i = #list, 2, -1 do
        local j = random(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

-- ── Point distributions ───────────────────────────────────────────────────────

--[[
    poisson_disk(w, h, r, k) -> { {x, y}, ... }     -- k optional

    Blue-noise scatter: points spread randomly over a w x h area but never
    closer than r to each other.

    This is the right way to stipple.  Uniform random points clump — you get
    dense knots and bare patches, which on paper reads as a mistake.  Poisson
    disk sampling has the same randomness without the clumping, so the result
    looks deliberately even while still being irregular.

    k is how many placements to try around each active point before giving up
    on it (default 30; higher packs slightly tighter and costs more time).

    Bridson's algorithm.  The trick is the background grid: cells are sized
    r/sqrt(2) so each holds at most one point, which turns "is anything within
    r of here?" into a fixed 5x5 cell check instead of a scan over every point
    placed so far.  That is what makes it linear rather than quadratic.
--]]
function M.poisson_disk(w, h, r, k)
    k = k or 30
    if r <= 0 then error("poisson_disk: radius must be positive", 2) end
    if w <= 0 or h <= 0 then return {} end

    local cell = r / sqrt(2)
    local cols = max(1, math.ceil(w / cell))
    local rows = max(1, math.ceil(h / cell))

    local grid = {}                          -- flat cols*rows array of points
    local points, active = {}, {}

    local function grid_index(x, y)
        local cx = min(cols - 1, floor(x / cell))
        local cy = min(rows - 1, floor(y / cell))
        return cy * cols + cx + 1, cx, cy
    end

    local function fits(x, y)
        if x < 0 or y < 0 or x >= w or y >= h then return false end

        local _, cx, cy = grid_index(x, y)
        -- 2 cells out in each direction covers everything within r, since a
        -- cell's diagonal is exactly r
        for j = max(0, cy - 2), min(rows - 1, cy + 2) do
            for i = max(0, cx - 2), min(cols - 1, cx + 2) do
                local p = grid[j * cols + i + 1]
                if p then
                    local dx, dy = p[1] - x, p[2] - y
                    if dx * dx + dy * dy < r * r then return false end
                end
            end
        end
        return true
    end

    local function add(x, y)
        local idx = grid_index(x, y)
        local p = {x, y}
        grid[idx] = p
        points[#points + 1] = p
        active[#active + 1] = p
    end

    add(random() * w, random() * h)

    while #active > 0 do
        local ai = random(#active)
        local p  = active[ai]
        local placed = false

        for _ = 1, k do
            -- Uniform in the annulus r..2r. sqrt on the radius is what keeps
            -- it uniform by area rather than bunched toward the inner edge.
            local a  = random() * 2 * pi
            local rr = r * sqrt(1 + 3 * random())
            local nx, ny = p[1] + cos(a) * rr, p[2] + sin(a) * rr

            if fits(nx, ny) then
                add(nx, ny)
                placed = true
                break
            end
        end

        if not placed then
            -- Nothing more fits around this one; retire it
            active[ai] = active[#active]
            active[#active] = nil
        end
    end

    return points
end

--[[
    grid(w, h, cols, rows) -> { {x, y}, ... }

    An evenly spaced cols x rows lattice spanning a w x h area, with points ON
    the edges rather than at cell centres: the first is (0, 0), the last (w, h).

    Row-major, running along x first, so index i has
    row = floor((i-1) / cols) + 1 and col = ((i-1) % cols) + 1. Predictable
    ordering matters when something steps through the points one at a time --
    tools/pen-setup.lua walks this grid with a person watching each move.

    cols or rows of 1 pins that axis at 0 rather than dividing by zero.
--]]
function M.grid(w, h, cols, rows)
    cols = max(1, floor(cols or 1))
    rows = max(1, floor(rows or cols))

    local pts = {}
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            pts[#pts + 1] = {
                cols > 1 and w * c / (cols - 1) or 0,
                rows > 1 and h * r / (rows - 1) or 0,
            }
        end
    end
    return pts
end

--[[
    halton(i, base) -> 0..1

    The i-th term of the Halton low-discrepancy sequence (i starts at 1).

    Where random points clump and a grid is visibly regular, a Halton sequence
    fills space evenly at every prefix length — the first 10 points are spread
    out, and so are the first 1000.  Useful when you want even coverage but
    don't want a lattice, and unlike poisson_disk you can ask for one more
    point at any time without recomputing.

    Computed by reflecting i's digits in `base` about the decimal point:
    1, 2, 3 in base 2 become 0.1, 0.01, 0.11 binary = 0.5, 0.25, 0.75.
--]]
function M.halton(i, base)
    base = base or 2
    local result, f = 0, 1 / base
    while i > 0 do
        result = result + f * (i % base)
        i = floor(i / base)
        f = f / base
    end
    return result
end

--[[
    halton2d(n, w, h) -> { {x, y}, ... }            -- w, h optional

    n Halton points spread over a w x h area (default 1 x 1).
    Uses bases 2 and 3, the conventional coprime pair — two sequences sharing a
    base would produce points on a diagonal line.
--]]
function M.halton2d(n, w, h)
    w = w or 1
    h = h or 1
    local pts = {}
    for i = 1, n do
        pts[i] = {M.halton(i, 2) * w, M.halton(i, 3) * h}
    end
    return pts
end

-- ── Processing camelCase aliases ──────────────────────────────────────────────

M.randomGaussian = M.random_gaussian
M.randomRange    = M.random_range
M.randomChoice   = M.random_choice
M.randomWeighted = M.random_weighted
M.smoothStep     = M.smoothstep
M.poissonDisk    = M.poisson_disk

return M
