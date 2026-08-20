local t = require 'harness'
local u = require 'util'

t.describe("util maths", function()
    t.it("map re-ranges", function()
        t.assert_eq(u.map(5, 0, 10, 100, 200), 150)
        t.assert_eq(u.map(0, 0, 10, 100, 200), 100)
        t.assert_eq(u.map(10, 0, 10, 100, 200), 200)
    end)

    t.it("map extrapolates outside the source range", function()
        t.assert_eq(u.map(20, 0, 10, 0, 100), 200)
        t.assert_eq(u.map(-5, 0, 10, 0, 100), -50)
    end)

    t.it("map survives a zero-width source range", function()
        t.assert_eq(u.map(5, 3, 3, 10, 20), 10)
    end)

    t.it("map handles a reversed target range", function()
        t.assert_eq(u.map(0.25, 0, 1, 100, 0), 75)
    end)

    t.it("lerp and norm are inverses", function()
        t.assert_eq(u.lerp(10, 20, 0.5), 15)
        t.assert_eq(u.norm(15, 10, 20), 0.5)
        t.assert_near(u.norm(u.lerp(3, 9, 0.37), 3, 9), 0.37, 1e-12)
    end)

    t.it("constrain clamps both ends", function()
        t.assert_eq(u.constrain(15, 0, 10), 10)
        t.assert_eq(u.constrain(-5, 0, 10), 0)
        t.assert_eq(u.constrain(5, 0, 10), 5)
    end)

    t.it("wrap is correct for negatives", function()
        t.assert_eq(u.wrap(11, 0, 10), 1)
        t.assert_eq(u.wrap(-1, 0, 10), 9)
        t.assert_eq(u.wrap(-31, 0, 10), 9)
        t.assert_eq(u.wrap(0, 0, 10), 0)
    end)

    t.it("wrap handles a range that does not start at zero", function()
        t.assert_eq(u.wrap(25, 10, 20), 15)
        t.assert_eq(u.wrap(5, 10, 20), 15)
    end)

    t.it("smoothstep is clamped with flat ends", function()
        t.assert_eq(u.smoothstep(0, 1, -1), 0)
        t.assert_eq(u.smoothstep(0, 1, 2), 1)
        t.assert_eq(u.smoothstep(0, 1, 0.5), 0.5)
        -- flat at the ends: a small step in produces a much smaller step up
        t.assert_true(u.smoothstep(0, 1, 0.01) < 0.01)
    end)

    t.it("smootherstep is flatter still at the ends", function()
        t.assert_true(u.smootherstep(0, 1, 0.01) < u.smoothstep(0, 1, 0.01))
        t.assert_eq(u.smootherstep(0, 1, 0.5), 0.5)
    end)

    t.it("round, sign and dist", function()
        t.assert_eq(u.round(2.4), 2); t.assert_eq(u.round(2.5), 3)
        t.assert_eq(u.round(-2.4), -2)
        t.assert_eq(u.sign(-3), -1); t.assert_eq(u.sign(3), 1); t.assert_eq(u.sign(0), 0)
        t.assert_eq(u.dist(0, 0, 3, 4), 5)
    end)
end)

t.describe("util random", function()
    t.it("is reproducible under math.randomseed", function()
        math.randomseed(31)
        local a = {u.random_range(5), u.random_gaussian(), u.random_range(1, 2)}
        math.randomseed(31)
        local b = {u.random_range(5), u.random_gaussian(), u.random_range(1, 2)}
        for i = 1, 3 do t.assert_eq(a[i], b[i]) end
    end)

    t.it("random_range respects its bounds", function()
        math.randomseed(4)
        for _ = 1, 500 do
            local v = u.random_range(10, 20)
            t.assert_true(v >= 10 and v < 20, "out of range: " .. v)
            local w = u.random_range(5)
            t.assert_true(w >= 0 and w < 5, "out of range: " .. w)
        end
    end)

    t.it("random_gaussian has the right mean and spread", function()
        math.randomseed(11)
        local n, sum, sumsq = 40000, 0, 0
        for _ = 1, n do
            local g = u.random_gaussian()
            sum = sum + g; sumsq = sumsq + g * g
        end
        local mean = sum / n
        t.assert_near(mean, 0, 0.03)
        t.assert_near(math.sqrt(sumsq / n - mean * mean), 1, 0.03)
    end)

    t.it("random_gaussian honours mean and sd", function()
        math.randomseed(12)
        local n, sum = 20000, 0
        for _ = 1, n do sum = sum + u.random_gaussian(100, 5) end
        t.assert_near(sum / n, 100, 0.3)
    end)

    t.it("random_choice only returns members", function()
        math.randomseed(13)
        local list = {"a", "b", "c"}
        for _ = 1, 200 do
            local v = u.random_choice(list)
            t.assert_true(v == "a" or v == "b" or v == "c")
        end
        t.assert_nil(u.random_choice({}))
    end)

    t.it("random_weighted follows the weights", function()
        math.randomseed(17)
        local counts = {a = 0, b = 0, c = 0}
        local n = 30000
        for _ = 1, n do
            local pick = u.random_weighted({"a", "b", "c"}, {5, 2, 1})
            counts[pick] = counts[pick] + 1
        end
        t.assert_near(counts.a / n, 5 / 8, 0.02)
        t.assert_near(counts.b / n, 2 / 8, 0.02)
        t.assert_near(counts.c / n, 1 / 8, 0.02)
    end)

    t.it("random_weighted never picks a zero weight", function()
        math.randomseed(19)
        for _ = 1, 500 do
            t.assert_eq(u.random_weighted({"never", "always"}, {0, 1}), "always")
        end
    end)

    t.it("random_weighted rejects bad input", function()
        t.assert_error(function() u.random_weighted({"a", "b"}, {1}) end,
                       "one weight per element")
        t.assert_error(function() u.random_weighted({"a"}, {-1}) end,
                       "non%-negative")
        t.assert_nil(u.random_weighted({}, {}))
    end)

    t.it("shuffle produces a permutation", function()
        math.randomseed(23)
        local list = {}
        for i = 1, 50 do list[i] = i end
        u.shuffle(list)

        t.assert_eq(#list, 50)
        local seen = {}
        for _, v in ipairs(list) do seen[v] = true end
        for i = 1, 50 do t.assert_true(seen[i], "lost element " .. i) end
    end)

    t.it("shuffle actually reorders", function()
        math.randomseed(29)
        local list = {}
        for i = 1, 50 do list[i] = i end
        u.shuffle(list)
        local moved = 0
        for i = 1, 50 do if list[i] ~= i then moved = moved + 1 end end
        t.assert_true(moved > 25, "only " .. moved .. " of 50 moved")
    end)
end)

t.describe("poisson_disk", function()
    t.it("never places two points closer than r", function()
        math.randomseed(41)
        local r = 6
        local pts = u.poisson_disk(120, 90, r)
        t.assert_true(#pts > 50, "suspiciously few points: " .. #pts)

        local worst = math.huge
        for i = 1, #pts do
            for j = i + 1, #pts do
                local dx = pts[i][1] - pts[j][1]
                local dy = pts[i][2] - pts[j][2]
                local d = math.sqrt(dx * dx + dy * dy)
                if d < worst then worst = d end
            end
        end
        t.assert_true(worst >= r - 1e-9,
            string.format("closest pair was %.6f, minimum is %g", worst, r))
    end)

    t.it("stays inside the region", function()
        math.randomseed(43)
        for _, p in ipairs(u.poisson_disk(50, 30, 4)) do
            t.assert_true(p[1] >= 0 and p[1] < 50, "x out of bounds: " .. p[1])
            t.assert_true(p[2] >= 0 and p[2] < 30, "y out of bounds: " .. p[2])
        end
    end)

    t.it("fills the region rather than clustering in one corner", function()
        math.randomseed(47)
        local pts = u.poisson_disk(100, 100, 5)
        local q = {0, 0, 0, 0}
        for _, p in ipairs(pts) do
            local i = (p[1] < 50 and 0 or 1) + (p[2] < 50 and 0 or 2) + 1
            q[i] = q[i] + 1
        end
        for i = 1, 4 do
            t.assert_true(q[i] > #pts * 0.15,
                string.format("quadrant %d has only %d of %d points", i, q[i], #pts))
        end
    end)

    t.it("a larger radius yields fewer points", function()
        math.randomseed(53)
        local few  = #u.poisson_disk(100, 100, 12)
        math.randomseed(53)
        local many = #u.poisson_disk(100, 100, 4)
        t.assert_true(many > few, string.format("r=4 gave %d, r=12 gave %d", many, few))
    end)

    t.it("rejects a non-positive radius", function()
        t.assert_error(function() u.poisson_disk(10, 10, 0) end, "positive")
    end)

    t.it("returns nothing for an empty region", function()
        t.assert_eq(#u.poisson_disk(0, 10, 1), 0)
    end)
end)

t.describe("grid", function()
    t.it("spans the full area, edges included", function()
        local g = u.grid(140, 200, 3, 3)
        t.assert_eq(#g, 9)
        t.assert_point(g[1], 0, 0,     nil, "first")
        t.assert_point(g[9], 140, 200, nil, "last")
        t.assert_point(g[5], 70, 100,  nil, "centre")
    end)

    t.it("is row-major along x", function()
        local g = u.grid(100, 100, 3, 3)
        -- Index 2 must be the next point across, not the next one up
        t.assert_point(g[2], 50, 0)
        t.assert_point(g[4], 0, 50)
    end)

    t.it("supports a non-square grid", function()
        local g = u.grid(100, 50, 4, 2)
        t.assert_eq(#g, 8)
        t.assert_point(g[4], 100, 0)
        t.assert_point(g[8], 100, 50)
    end)

    t.it("spaces the points evenly", function()
        local g = u.grid(90, 90, 4, 4)
        for r = 0, 3 do
            for c = 1, 3 do
                local i = r * 4 + c
                t.assert_near(g[i + 1][1] - g[i][1], 30, 1e-9)
            end
        end
    end)

    t.it("pins a single-column or single-row axis at zero", function()
        local g = u.grid(10, 10, 1, 4)
        t.assert_eq(#g, 4)
        for _, p in ipairs(g) do t.assert_eq(p[1], 0) end
        t.assert_eq(g[4][2], 10)
        t.assert_eq(#u.grid(10, 10, 3, 1), 3)
    end)

    t.it("never divides by zero on a degenerate count", function()
        for _, p in ipairs(u.grid(10, 10, 0, 0)) do
            t.assert_eq(p[1], p[1], "coordinate is NaN")
            t.assert_eq(p[2], p[2], "coordinate is NaN")
        end
    end)

    t.it("is what pen-setup lays over the paper", function()
        -- 180x240 paper whose near-left corner sits at machine (10, 15),
        -- inset 20 mm: the tool offsets u.grid by origin + margin
        local paper, origin, margin = {180, 240}, {10, 15}, 20
        local g = u.grid(paper[1] - 2*margin, paper[2] - 2*margin, 3, 3)

        local first = {origin[1] + margin + g[1][1], origin[2] + margin + g[1][2]}
        local last  = {origin[1] + margin + g[9][1], origin[2] + margin + g[9][2]}

        t.assert_point(first, 30, 35,   nil, "near-left grid point")
        t.assert_point(last,  170, 235, nil, "far-right grid point")
    end)
end)

t.describe("halton", function()
    t.it("matches the known base-2 sequence", function()
        t.assert_near(u.halton(1, 2), 0.5, 1e-12)
        t.assert_near(u.halton(2, 2), 0.25, 1e-12)
        t.assert_near(u.halton(3, 2), 0.75, 1e-12)
        t.assert_near(u.halton(4, 2), 0.125, 1e-12)
    end)

    t.it("matches the known base-3 sequence", function()
        t.assert_near(u.halton(1, 3), 1 / 3, 1e-12)
        t.assert_near(u.halton(2, 3), 2 / 3, 1e-12)
        t.assert_near(u.halton(3, 3), 1 / 9, 1e-12)
    end)

    t.it("stays in [0, 1)", function()
        for i = 1, 500 do
            local v = u.halton(i, 2)
            t.assert_true(v >= 0 and v < 1, "out of range at i=" .. i)
        end
    end)

    t.it("halton2d covers the quadrants evenly", function()
        local pts = u.halton2d(400)
        local q = {0, 0, 0, 0}
        for _, p in ipairs(pts) do
            local i = (p[1] < 0.5 and 0 or 1) + (p[2] < 0.5 and 0 or 2) + 1
            q[i] = q[i] + 1
        end
        for i = 1, 4 do
            t.assert_near(q[i], 100, 10, "quadrant " .. i)
        end
    end)

    t.it("halton2d scales to the given area", function()
        for _, p in ipairs(u.halton2d(100, 50, 20)) do
            t.assert_true(p[1] >= 0 and p[1] < 50)
            t.assert_true(p[2] >= 0 and p[2] < 20)
        end
    end)

    t.it("is deterministic — no RNG involved", function()
        math.randomseed(os.time())
        t.assert_eq(u.halton(37, 2), u.halton(37, 2))
    end)
end)

t.describe("util aliases", function()
    t.it("Processing camelCase names are present", function()
        t.assert_eq(u.randomGaussian, u.random_gaussian)
        t.assert_eq(u.poissonDisk, u.poisson_disk)
        t.assert_eq(u.smoothStep, u.smoothstep)
    end)
end)
