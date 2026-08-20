local t = require 'harness'
local plotter = require 'plotter'

local SINK = os.tmpname()

local function fresh(optimize)
    plotter.init { mode = "svg", width = 1000, height = 1000, svg_file = SINK,
                   optimize = optimize, quiet = true, clip = "off" }
end

-- Draw the same set of scattered strokes, return the resulting travel distance
local function scatter_travel(optimize, seed, n)
    fresh(optimize)
    math.randomseed(seed)
    for _ = 1, n do
        local x, y = math.random() * 900 + 10, math.random() * 900 + 10
        plotter.line(x, y, x + 5, y + 5)
    end
    plotter.flush()
    return plotter.stats().travel_mm
end

t.describe("pen-travel optimization", function()
    t.it("cuts travel dramatically on scattered strokes", function()
        local plain     = scatter_travel(false, 7, 150)
        local optimized = scatter_travel(true,  7, 150)
        t.assert_true(optimized < plain * 0.5, string.format(
            "expected a big saving; plain %.0f mm, optimized %.0f mm",
            plain, optimized))
    end)

    t.it("never makes travel worse", function()
        for _, seed in ipairs({1, 2, 3, 11}) do
            local plain     = scatter_travel(false, seed, 40)
            local optimized = scatter_travel(true,  seed, 40)
            t.assert_true(optimized <= plain + 1e-6, string.format(
                "seed %d: optimized %.3f > plain %.3f", seed, optimized, plain))
        end
    end)

    t.it("draws exactly the same geometry, only in a different order", function()
        local function fingerprint(optimize)
            fresh(optimize)
            math.randomseed(5)
            for _ = 1, 30 do
                local x, y = math.random() * 900, math.random() * 900
                plotter.line(x, y, x + 10, y + 10)
            end
            plotter.flush()

            -- Order- and direction-independent: sort the endpoint pairs
            local keys = {}
            for _, p in ipairs(plotter.paths()) do
                local a, b = p.pts[1], p.pts[#p.pts]
                local ka = string.format("%.4f,%.4f", a[1], a[2])
                local kb = string.format("%.4f,%.4f", b[1], b[2])
                keys[#keys + 1] = (ka < kb) and (ka .. "|" .. kb) or (kb .. "|" .. ka)
            end
            table.sort(keys)
            return table.concat(keys, ";")
        end

        t.assert_eq(fingerprint(true), fingerprint(false))
    end)

    t.it("takes the nearest path first", function()
        fresh(true)
        -- Deliberately drawn far-to-near; the pen starts at the origin
        plotter.line(900, 900, 910, 900)
        plotter.line(500, 500, 510, 500)
        plotter.line(10, 10, 20, 10)
        plotter.flush()

        local first = plotter.paths()[1].pts[1]
        t.assert_point(first, 10, 10, 1e-9, "nearest stroke should be drawn first")
    end)

    t.it("reverses a path when its far end is closer", function()
        fresh(true)
        -- The pen starts at (0,0); this path's LAST point is the nearer one
        plotter.polyline({{100, 0}, {50, 0}, {10, 0}})
        plotter.flush()

        local pts = plotter.paths()[1].pts
        t.assert_point(pts[1], 10, 0, 1e-9, "should enter from the near end")
        t.assert_point(pts[3], 100, 0, 1e-9)
    end)

    t.it("does not reverse when the path is already the right way round", function()
        fresh(true)
        plotter.polyline({{10, 0}, {50, 0}, {100, 0}})
        plotter.flush()
        t.assert_point(plotter.paths()[1].pts[1], 10, 0, 1e-9)
    end)

    t.it("carries the pen position between flushes", function()
        fresh(true)
        plotter.line(500, 500, 510, 500)
        plotter.flush()
        -- Pen is now near (510, 500); the closer of these should go first
        plotter.line(900, 900, 910, 910)
        plotter.line(520, 500, 530, 500)
        plotter.flush()

        local p = plotter.paths()
        t.assert_point(p[2].pts[1], 520, 500, 1e-9,
            "the second batch should start from where the pen actually is")
    end)

    t.it("respects layer boundaries", function()
        fresh(true)
        plotter.layer("first")
        plotter.line(900, 900, 910, 900)
        plotter.line(800, 800, 810, 800)
        plotter.layer("second")
        plotter.line(10, 10, 20, 10)
        plotter.line(20, 20, 30, 20)
        plotter.flush()

        local p = plotter.paths()
        t.assert_eq(#p, 4)
        -- Reordering must not interleave the layers, however tempting the
        -- nearby 'second' strokes look from the origin
        t.assert_eq(p[1].layer, "first")
        t.assert_eq(p[2].layer, "first")
        t.assert_eq(p[3].layer, "second")
        t.assert_eq(p[4].layer, "second")
    end)

    t.it("keeps closed paths closed", function()
        fresh(true)
        plotter.rect(100, 100, 50, 50)
        plotter.flush()
        t.assert_true(plotter.paths()[1].close)
        t.assert_eq(#plotter.paths()[1].pts, 4)
    end)

    t.it("copes with a single path and with none", function()
        fresh(true)
        plotter.flush()
        t.assert_eq(#plotter.paths(), 0)

        fresh(true)
        plotter.line(5, 5, 6, 6)
        plotter.flush()
        t.assert_eq(#plotter.paths(), 1)
    end)
end)
