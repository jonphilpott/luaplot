local t = require 'harness'

-- Sample a function over a grid and return min, max and mean
local function sweep(fn, n, step)
    n, step = n or 60, step or 0.13
    local lo, hi, sum, count = math.huge, -math.huge, 0, 0
    for i = 0, n do
        for j = 0, n do
            local v = fn(i * step, j * step * 1.31)
            if v < lo then lo = v end
            if v > hi then hi = v end
            sum = sum + v
            count = count + 1
        end
    end
    return lo, hi, sum / count
end

t.describe("noise seeding", function()
    t.it("the same seed gives the same field", function()
        noise.seed(1234); local a = noise.perlin(0.3, 0.7)
        noise.seed(1234); local b = noise.perlin(0.3, 0.7)
        t.assert_eq(a, b)
    end)

    t.it("different seeds give different fields", function()
        noise.seed(1); local a = noise.perlin(0.3, 0.7)
        noise.seed(2); local b = noise.perlin(0.3, 0.7)
        t.assert_ne(a, b)
    end)

    t.it("is independent of math.randomseed", function()
        noise.seed(7)
        math.randomseed(1); local a = noise.perlin(0.4, 0.6)
        math.randomseed(2); local b = noise.perlin(0.4, 0.6)
        t.assert_eq(a, b, "Lua's RNG must not perturb the noise field")
    end)
end)

t.describe("perlin", function()
    noise.seed(42)

    t.it("stays within [-1, 1] in 1D, 2D and 3D", function()
        local lo, hi = sweep(function(x, y) return noise.perlin(x, y) end)
        t.assert_true(lo >= -1 and hi <= 1, "2D out of range: " .. lo .. ".." .. hi)

        local lo3, hi3 = sweep(function(x, y) return noise.perlin(x, y, x * 0.5) end)
        t.assert_true(lo3 >= -1 and hi3 <= 1, "3D out of range")

        local lo1, hi1 = math.huge, -math.huge
        for i = 0, 3000 do
            local v = noise.perlin(i * 0.037)
            lo1 = math.min(lo1, v); hi1 = math.max(hi1, v)
        end
        t.assert_true(lo1 >= -1 and hi1 <= 1, "1D out of range")
    end)

    t.it("uses a decent share of its range", function()
        local lo, hi = sweep(function(x, y) return noise.perlin(x, y) end)
        t.assert_true(hi - lo > 1.2,
            "field looks degenerate, spread was only " .. (hi - lo))
    end)

    t.it("is centred near zero", function()
        local _, _, mean = sweep(function(x, y) return noise.perlin(x, y) end)
        t.assert_near(mean, 0, 0.05)
    end)

    t.it("is zero at integer lattice points", function()
        for i = 1, 6 do
            t.assert_near(noise.perlin(i, i * 2), 0, 1e-12)
        end
    end)

    t.it("is continuous: nearby inputs give nearby outputs", function()
        local a = noise.perlin(3.2, 4.8)
        local b = noise.perlin(3.2 + 1e-6, 4.8)
        t.assert_near(b, a, 1e-3)
    end)

    t.it("has no flat spot at half-integer 1D coordinates", function()
        -- True 1D Perlin has only two unit gradients, so whenever two adjacent
        -- lattice points draw the same one their midpoint is exactly zero --
        -- about half of all x.5 coordinates, a visible periodic artifact.
        -- Slicing 2D noise removes the pattern; the odd exact zero still turns
        -- up by coincidence, which is fine.
        local zeros, n = 0, 2000
        for i = 0, n do
            if math.abs(noise.perlin(i + 0.5)) < 1e-12 then zeros = zeros + 1 end
        end
        t.assert_true(zeros / n < 0.05,
            string.format("%d/%d half-integer points were exactly zero", zeros, n))
    end)

    t.it("is callable as noise(x, y)", function()
        t.assert_eq(noise(0.3, 0.4), noise.perlin(0.3, 0.4))
    end)

    t.it("rejects a call with no coordinates", function()
        t.assert_error(function() return noise.perlin() end, "coordinate")
    end)
end)

t.describe("fractal variants", function()
    noise.seed(7)

    t.it("fbm stays in [-1, 1] whatever the octave count", function()
        for _, oct in ipairs({1, 4, 8, 16}) do
            local lo, hi = sweep(function(x, y)
                return noise.fbm(x, y, {octaves = oct})
            end, 40)
            t.assert_true(lo >= -1 and hi <= 1,
                "octaves=" .. oct .. " gave " .. lo .. ".." .. hi)
        end
    end)

    t.it("fbm with one octave is plain perlin", function()
        t.assert_near(noise.fbm(0.3, 0.4, {octaves = 1}), noise.perlin(0.3, 0.4), 1e-12)
    end)

    t.it("lower gain means the later octaves matter less", function()
        -- With a small gain the result should track single-octave perlin
        -- closely; with a large one it should not.
        local base = noise.perlin(1.3, 2.7)
        local tight = math.abs(noise.fbm(1.3, 2.7, {octaves = 6, gain = 0.05}) - base)
        local loose = math.abs(noise.fbm(1.3, 2.7, {octaves = 6, gain = 0.9}) - base)
        t.assert_true(tight < loose,
            string.format("gain 0.05 deviated %.4f, gain 0.9 deviated %.4f", tight, loose))
    end)

    t.it("ridged and turbulence stay in [0, 1]", function()
        local lo, hi = sweep(function(x, y) return noise.ridged(x, y) end, 40)
        t.assert_true(lo >= 0 and hi <= 1, "ridged: " .. lo .. ".." .. hi)

        local lo2, hi2 = sweep(function(x, y) return noise.turbulence(x, y) end, 40)
        t.assert_true(lo2 >= 0 and hi2 <= 1, "turbulence: " .. lo2 .. ".." .. hi2)
    end)

    t.it("clamps a silly octave count instead of hanging", function()
        t.assert_true(noise.fbm(1, 1, {octaves = 10000}) <= 1)
        t.assert_true(noise.fbm(1, 1, {octaves = -5}) >= -1)
    end)
end)

t.describe("Processing-compatible layer", function()
    t.it("noise() returns 0..1", function()
        noise.noise_seed(3)
        local lo, hi = sweep(function(x, y) return noise.noise(x, y) end, 50)
        t.assert_true(lo >= 0 and hi <= 1, "range was " .. lo .. ".." .. hi)
        t.assert_true(hi - lo > 0.4, "range looks degenerate")
    end)

    t.it("noise_detail changes the result", function()
        noise.noise_seed(3)
        noise.noise_detail(1)
        local one = noise.noise(1.7, 2.3)
        noise.noise_detail(8)
        local eight = noise.noise(1.7, 2.3)
        t.assert_ne(one, eight)
        noise.noise_detail(4, 0.5)      -- back to Processing's defaults
    end)

    t.it("camelCase aliases exist", function()
        t.assert_eq(noise.noiseDetail, noise.noise_detail)
        t.assert_eq(noise.noiseSeed, noise.noise_seed)
    end)
end)

t.describe("worley", function()
    noise.seed(5)

    t.it("f1 is never greater than f2", function()
        for i = 0, 80 do
            for j = 0, 80 do
                local f1, f2 = noise.worley(i * 0.17, j * 0.13)
                t.assert_true(f1 <= f2 + 1e-12,
                    string.format("f1 %.6f > f2 %.6f", f1, f2))
            end
        end
    end)

    t.it("distances are non-negative and bounded", function()
        local lo, hi = sweep(function(x, y) return (noise.worley(x, y)) end, 50)
        t.assert_true(lo >= 0, "negative distance")
        t.assert_true(hi < 2.0, "f1 unexpectedly large: " .. hi)
    end)

    t.it("with jitter 0 the feature point sits at the cell centre", function()
        t.assert_near(select(1, noise.worley(1.5, 2.5, {jitter = 0})), 0, 1e-12)
        t.assert_near(select(1, noise.worley(3.5, 7.5, {jitter = 0})), 0, 1e-12)
    end)

    t.it("cell_id is stable inside a cell and differs between cells", function()
        local _, _, a = noise.worley(1.2, 1.2, {jitter = 0})
        local _, _, b = noise.worley(1.4, 1.3, {jitter = 0})
        local _, _, c = noise.worley(9.5, 4.5, {jitter = 0})
        t.assert_eq(a, b, "same cell should give the same id")
        t.assert_ne(a, c)
    end)

    t.it("supports the alternative metrics", function()
        local e = noise.worley(1.2, 3.4, {metric = "euclidean"})
        local m = noise.worley(1.2, 3.4, {metric = "manhattan"})
        local c = noise.worley(1.2, 3.4, {metric = "chebyshev"})
        -- For the same offset: chebyshev <= euclidean <= manhattan
        t.assert_true(c <= e + 1e-9 and e <= m + 1e-9,
            string.format("expected cheb %.4f <= eucl %.4f <= manh %.4f", c, e, m))
    end)

    t.it("rejects an unknown metric", function()
        t.assert_error(function() return noise.worley(1, 1, {metric = "taxi"}) end,
                       "unknown distance metric")
    end)
end)
