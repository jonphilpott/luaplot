local t = require 'harness'
local plotter = require 'plotter'

local SINK = os.tmpname()

local function fresh()
    plotter.init { mode = "svg", width = 1000, height = 1000, svg_file = SINK,
                   auto_flush = false, quiet = true, clip = "off" }
end

-- Even-odd point-in-polygon, used to check the hatch landed inside the shape
local function inside(poly, x, y)
    local n, hit = #poly, false
    for i = 1, n do
        local a, b = poly[i], poly[i % n + 1]
        if (a[2] > y) ~= (b[2] > y) then
            local xi = a[1] + (y - a[2]) / (b[2] - a[2]) * (b[1] - a[1])
            if x < xi then hit = not hit end
        end
    end
    return hit
end

local SQUARE = {{0, 0}, {100, 0}, {100, 100}, {0, 100}}

t.describe("hatch coverage", function()
    t.it("fills a square", function()
        fresh()
        plotter.hatch(SQUARE, 0, 10)
        local p = plotter.paths()
        t.assert_true(#p >= 8, "expected roughly 10 scanlines, got " .. #p)
    end)

    t.it("keeps every segment inside the shape", function()
        fresh()
        plotter.hatch(SQUARE, 30, 7)
        for _, path in ipairs(plotter.paths()) do
            local a, b = path.pts[1], path.pts[2]
            local mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
            t.assert_true(inside(SQUARE, mx, my),
                string.format("segment midpoint (%.2f, %.2f) is outside", mx, my))
        end
    end)

    t.it("spaces the lines as asked", function()
        fresh()
        plotter.hatch(SQUARE, 0, 10)
        -- Horizontal hatch: consecutive lines should be 10 apart in y
        local ys = {}
        for _, path in ipairs(plotter.paths()) do ys[#ys + 1] = path.pts[1][2] end
        table.sort(ys)
        for i = 2, #ys do
            t.assert_near(ys[i] - ys[i - 1], 10, 1e-6)
        end
    end)

    t.it("a tighter spacing gives more lines", function()
        fresh(); plotter.hatch(SQUARE, 0, 20)
        local coarse = #plotter.paths()
        fresh(); plotter.hatch(SQUARE, 0, 5)
        local fine = #plotter.paths()
        t.assert_true(fine > coarse * 2,
            string.format("spacing 5 gave %d lines, spacing 20 gave %d", fine, coarse))
    end)

    t.it("the angle rotates the fill", function()
        fresh(); plotter.hatch(SQUARE, 0, 10)
        local horizontal = plotter.paths()[1]
        t.assert_near(horizontal.pts[1][2], horizontal.pts[2][2], 1e-9,
            "0 degrees should give horizontal lines")

        fresh(); plotter.hatch(SQUARE, 90, 10)
        local vertical = plotter.paths()[1]
        t.assert_near(vertical.pts[1][1], vertical.pts[2][1], 1e-9,
            "90 degrees should give vertical lines")
    end)
end)

t.describe("hatch on awkward shapes", function()
    -- A C-shape: a scanline through the notch must produce two separate runs
    local CSHAPE = {
        {0, 0}, {100, 0}, {100, 30}, {40, 30},
        {40, 70}, {100, 70}, {100, 100}, {0, 100},
    }

    t.it("splits a concave shape into separate runs", function()
        fresh()
        plotter.hatch(CSHAPE, 0, 10)

        local crossing = 0
        for _, path in ipairs(plotter.paths()) do
            local y = path.pts[1][2]
            if y > 30 and y < 70 then crossing = crossing + 1 end
        end
        t.assert_true(crossing >= 3,
            "scanlines through the notch should still be drawn")

        for _, path in ipairs(plotter.paths()) do
            local a, b = path.pts[1], path.pts[2]
            local mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
            t.assert_true(inside(CSHAPE, mx, my),
                string.format("segment (%.2f, %.2f) escaped the C", mx, my))
        end
    end)

    t.it("leaves a hole empty", function()
        fresh()
        local hole = {{40, 40}, {60, 40}, {60, 60}, {40, 60}}
        plotter.hatch({SQUARE, hole}, 0, 4)

        for _, path in ipairs(plotter.paths()) do
            local a, b = path.pts[1], path.pts[2]
            local mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
            t.assert_false(inside(hole, mx, my),
                string.format("hatch (%.2f, %.2f) landed in the hole", mx, my))
        end
    end)

    t.it("still fills either side of a hole", function()
        fresh()
        local hole = {{40, 40}, {60, 40}, {60, 60}, {40, 60}}
        plotter.hatch({SQUARE, hole}, 0, 4)

        local left, right = 0, 0
        for _, path in ipairs(plotter.paths()) do
            local y = path.pts[1][2]
            if y > 42 and y < 58 then
                local mx = (path.pts[1][1] + path.pts[2][1]) / 2
                if mx < 40 then left = left + 1 end
                if mx > 60 then right = right + 1 end
            end
        end
        t.assert_true(left > 0 and right > 0,
            string.format("expected runs on both sides, got %d / %d", left, right))
    end)

    t.it("handles a triangle", function()
        fresh()
        local tri = {{0, 100}, {50, 0}, {100, 100}}
        plotter.hatch(tri, 0, 8)
        t.assert_true(#plotter.paths() > 5)
        for _, path in ipairs(plotter.paths()) do
            local a, b = path.pts[1], path.pts[2]
            t.assert_true(inside(tri, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2))
        end
    end)
end)

t.describe("hatch options", function()
    t.it("outline adds the boundary", function()
        fresh(); plotter.hatch(SQUARE, 0, 10)
        local plain = #plotter.paths()
        fresh(); plotter.hatch(SQUARE, 0, 10, {outline = true})
        t.assert_eq(#plotter.paths(), plain + 1)
        t.assert_true(plotter.paths()[#plotter.paths()].close,
            "the outline should be a closed path")
    end)

    t.it("zigzag collapses the fill into one path", function()
        fresh()
        plotter.hatch(SQUARE, 0, 10, {zigzag = true})
        t.assert_eq(#plotter.paths(), 1,
            "zigzag exists to turn N pen lifts into one")
        t.assert_true(#plotter.paths()[1].pts > 10)
    end)

    t.it("zigzag alternates direction, so the path is connected", function()
        fresh()
        plotter.hatch(SQUARE, 0, 10, {zigzag = true})
        local pts = plotter.paths()[1].pts
        -- Consecutive scanlines are joined end to end: each odd->even step is
        -- a long horizontal run, each even->odd step a short vertical hop
        for i = 2, #pts - 1, 2 do
            local hop = math.abs(pts[i + 1][2] - pts[i][2])
            t.assert_near(hop, 10, 1e-6, "hop between scanlines")
        end
    end)

    t.it("zigzag still breaks where a scanline splits", function()
        fresh()
        local hole = {{40, 40}, {60, 40}, {60, 60}, {40, 60}}
        plotter.hatch({SQUARE, hole}, 0, 4, {zigzag = true})
        t.assert_true(#plotter.paths() > 1,
            "must not draw straight through the hole to stay connected")

        for _, path in ipairs(plotter.paths()) do
            for i = 1, #path.pts - 1 do
                local a, b = path.pts[i], path.pts[i + 1]
                local mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
                t.assert_false(inside(hole, mx, my),
                    "zigzag joined across the hole")
            end
        end
    end)

    t.it("inset pulls the fill in from the edge", function()
        fresh()
        plotter.hatch(SQUARE, 0, 10, {inset = 5})
        for _, path in ipairs(plotter.paths()) do
            for _, pt in ipairs(path.pts) do
                t.assert_true(pt[1] >= 5 - 1e-6 and pt[1] <= 95 + 1e-6,
                    "x not inset: " .. pt[1])
                t.assert_true(pt[2] >= 5 - 1e-6 and pt[2] <= 95 + 1e-6,
                    "y not inset: " .. pt[2])
            end
        end
    end)

    t.it("rejects a non-positive spacing", function()
        fresh()
        t.assert_error(function() plotter.hatch(SQUARE, 0, 0) end, "positive")
        t.assert_error(function() plotter.hatch(SQUARE, 0, -1) end, "positive")
    end)

    t.it("accepts vec2 rings", function()
        fresh()
        plotter.hatch({vec2(0, 0), vec2(50, 0), vec2(50, 50), vec2(0, 50)}, 0, 10)
        t.assert_true(#plotter.paths() > 2)
    end)
end)

t.describe("streamline", function()
    t.it("follows a constant field in a straight line", function()
        fresh()
        local pts = plotter.streamline(vec2(0, 0),
            function() return vec2(1, 0) end, 10, 2)
        t.assert_eq(#pts, 11, "start point plus one per step")
        t.assert_point(pts[1], 0, 0)
        t.assert_point(pts[11], 20, 0, 1e-9)
    end)

    t.it("normalises the field, so step_len is the actual step", function()
        fresh()
        local pts = plotter.streamline(vec2(0, 0),
            function() return vec2(1000, 0) end, 5, 3)
        t.assert_point(pts[6], 15, 0, 1e-9)
    end)

    t.it("accepts a field returning two numbers or a table", function()
        fresh()
        local a = plotter.streamline(vec2(0, 0), function() return 0, 1 end, 4, 1)
        t.assert_point(a[5], 0, 4, 1e-9)
        local b = plotter.streamline(vec2(0, 0), function() return {0, 1} end, 4, 1)
        t.assert_point(b[5], 0, 4, 1e-9)
    end)

    t.it("stops when the predicate says so", function()
        fresh()
        local pts = plotter.streamline(vec2(0, 0),
            function() return vec2(1, 0) end, 100, 1,
            { stop = function(p) return p.x >= 5 end })
        t.assert_true(#pts <= 7, "should have stopped early, got " .. #pts)
    end)

    t.it("stops where the field goes slack", function()
        fresh()
        local pts = plotter.streamline(vec2(0, 0), function(p)
            if p.x > 5 then return vec2(0, 0) end
            return vec2(1, 0)
        end, 100, 1)
        t.assert_true(#pts < 20, "should have given up, got " .. #pts)
    end)

    t.it("stops when the field returns nothing", function()
        fresh()
        local pts = plotter.streamline(vec2(0, 0), function() return nil end, 10, 1)
        t.assert_eq(#pts, 1)
    end)

    t.it("returns points rather than drawing them", function()
        fresh()
        plotter.streamline(vec2(0, 0), function() return vec2(1, 0) end, 5, 1)
        t.assert_eq(#plotter.paths(), 0, "streamline must not draw by itself")
    end)

    t.it("traces a circle on a rotational field", function()
        -- A field perpendicular to the radius should orbit the origin
        fresh()
        local r0 = 50
        local pts = plotter.streamline(vec2(r0, 0), function(p)
            return vec2(-p.y, p.x)
        end, 200, 1)
        for _, p in ipairs(pts) do
            local r = math.sqrt(p[1] ^ 2 + p[2] ^ 2)
            -- Midpoint integration drifts a little; Euler would drift far more
            t.assert_near(r, r0, 1.0, "radius drifted")
        end
    end)
end)
