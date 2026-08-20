local t = require 'harness'
local plotter = require 'plotter'

local SINK = os.tmpname()

local function fresh(opts)
    opts = opts or {}
    plotter.init {
        mode = "svg", width = opts.width or 1000, height = opts.height or 1000,
        svg_file = SINK, auto_flush = false, quiet = true, clip = "off",
    }
end

local function only_path()
    local p = plotter.paths()
    t.assert_eq(#p, 1, "expected exactly one path")
    return p[1]
end

t.describe("polyline", function()
    t.it("records the points it was given", function()
        fresh()
        plotter.polyline({{1, 2}, {3, 4}, {5, 6}})
        local p = only_path()
        t.assert_eq(#p.pts, 3)
        t.assert_point(p.pts[1], 1, 2)
        t.assert_point(p.pts[3], 5, 6)
        t.assert_false(p.close)
    end)

    t.it("accepts vec2 points, and a mix", function()
        fresh()
        plotter.polyline({vec2(1, 2), {3, 4}, vec2(5, 6)})
        local p = only_path()
        t.assert_point(p.pts[1], 1, 2)
        t.assert_point(p.pts[2], 3, 4)
        t.assert_point(p.pts[3], 5, 6)
    end)

    t.it("ignores paths with fewer than two points", function()
        fresh()
        plotter.polyline({{1, 2}})
        plotter.polyline({})
        t.assert_eq(#plotter.paths(), 0)
    end)

    t.it("marks closed paths", function()
        fresh()
        plotter.polygon({{0, 0}, {10, 0}, {10, 10}})
        t.assert_true(only_path().close)
    end)

    t.it("goes through the current transform", function()
        fresh()
        plotter.translate(100, 0)
        plotter.polyline({{1, 2}, {3, 4}})
        t.assert_point(only_path().pts[1], 101, 2)
    end)
end)

t.describe("line", function()
    t.it("takes four numbers", function()
        fresh()
        plotter.line(1, 2, 3, 4)
        local p = only_path()
        t.assert_point(p.pts[1], 1, 2); t.assert_point(p.pts[2], 3, 4)
    end)

    t.it("takes two points", function()
        fresh()
        plotter.line(vec2(1, 2), vec2(3, 4))
        local p = only_path()
        t.assert_point(p.pts[1], 1, 2); t.assert_point(p.pts[2], 3, 4)
    end)
end)

t.describe("rect", function()
    t.it("puts the origin at the top-left and closes", function()
        fresh()
        plotter.rect(10, 20, 30, 40)
        local p = only_path()
        t.assert_eq(#p.pts, 4)
        t.assert_true(p.close)
        t.assert_point(p.pts[1], 10, 20)
        t.assert_point(p.pts[2], 40, 20)
        t.assert_point(p.pts[3], 40, 60)
        t.assert_point(p.pts[4], 10, 60)
    end)

    t.it("takes position and size as vectors", function()
        fresh()
        plotter.rect(vec2(10, 20), vec2(30, 40))
        t.assert_point(only_path().pts[3], 40, 60)
    end)
end)

t.describe("circle", function()
    t.it("puts every point on the radius", function()
        fresh()
        plotter.circle(100, 100, 25)
        local p = only_path()
        t.assert_eq(#p.pts, 36, "default step count")
        t.assert_true(p.close)
        for _, pt in ipairs(p.pts) do
            local d = math.sqrt((pt[1] - 100) ^ 2 + (pt[2] - 100) ^ 2)
            t.assert_near(d, 25, 1e-9)
        end
    end)

    t.it("honours an explicit step count", function()
        fresh()
        plotter.circle(0, 0, 10, 8)
        t.assert_eq(#only_path().pts, 8)
    end)

    t.it("refuses to divide by zero on a degenerate step count", function()
        fresh()
        plotter.circle(0, 0, 10, 0)
        for _, pt in ipairs(only_path().pts) do
            t.assert_eq(pt[1], pt[1], "coordinate is NaN")
        end
    end)

    t.it("takes a vec2 centre", function()
        fresh()
        plotter.circle(vec2(50, 50), 10, 4)
        t.assert_point(only_path().pts[1], 60, 50, 1e-9)
    end)
end)

t.describe("ellipse and regular_polygon", function()
    t.it("ellipse uses independent radii", function()
        fresh()
        plotter.ellipse(0, 0, 20, 10, 4)
        local p = only_path()
        t.assert_point(p.pts[1], 20, 0, 1e-9)
        t.assert_point(p.pts[2], 0, 10, 1e-9)
    end)

    t.it("regular_polygon has n vertices, all on the radius", function()
        fresh()
        plotter.regular_polygon(50, 50, 20, 5)
        local p = only_path()
        t.assert_eq(#p.pts, 5)
        t.assert_true(p.close)
        for _, pt in ipairs(p.pts) do
            t.assert_near(math.sqrt((pt[1] - 50) ^ 2 + (pt[2] - 50) ^ 2), 20, 1e-9)
        end
    end)

    t.it("regular_polygon starts with a vertex pointing up", function()
        fresh()
        plotter.regular_polygon(0, 0, 10, 3)
        t.assert_point(plotter.paths()[1].pts[1], 0, -10, 1e-9)
    end)
end)

t.describe("arc", function()
    t.it("stays open and spans the requested angles", function()
        fresh()
        plotter.arc(0, 0, 10, 0, 90, 4)
        local p = only_path()
        t.assert_false(p.close)
        t.assert_eq(#p.pts, 5, "steps + 1 points")
        t.assert_point(p.pts[1], 10, 0, 1e-9)
        t.assert_point(p.pts[5], 0, 10, 1e-9)
    end)

    t.it("survives a zero span", function()
        fresh()
        plotter.arc(0, 0, 10, 45, 45)
        for _, pt in ipairs(only_path().pts) do
            t.assert_eq(pt[1], pt[1], "coordinate is NaN")
        end
    end)
end)

t.describe("bezier and quad_bezier", function()
    t.it("bezier passes through its endpoints", function()
        fresh()
        plotter.bezier(0, 0, 10, 50, 90, 50, 100, 0)
        local p = only_path()
        t.assert_point(p.pts[1], 0, 0, 1e-9)
        t.assert_point(p.pts[#p.pts], 100, 0, 1e-9)
    end)

    t.it("bezier takes four points", function()
        fresh()
        plotter.bezier(vec2(0, 0), vec2(10, 50), vec2(90, 50), vec2(100, 0), 10)
        local p = only_path()
        t.assert_eq(#p.pts, 11)
        t.assert_point(p.pts[#p.pts], 100, 0, 1e-9)
    end)

    t.it("a bezier with collinear controls is a straight line", function()
        fresh()
        plotter.bezier(0, 0, 25, 0, 75, 0, 100, 0, 8)
        for _, pt in ipairs(only_path().pts) do
            t.assert_near(pt[2], 0, 1e-9)
        end
    end)

    t.it("quad_bezier passes through its endpoints", function()
        fresh()
        plotter.quad_bezier(0, 0, 50, 100, 100, 0, 10)
        local p = only_path()
        t.assert_point(p.pts[1], 0, 0, 1e-9)
        t.assert_point(p.pts[#p.pts], 100, 0, 1e-9)
    end)
end)

t.describe("curve", function()
    t.it("passes through every control point", function()
        fresh()
        local given = {{0, 0}, {30, 40}, {60, 10}, {90, 50}}
        plotter.curve(given, false, 8)
        local pts = only_path().pts

        for _, g in ipairs(given) do
            local best = math.huge
            for _, p in ipairs(pts) do
                local d = math.sqrt((p[1] - g[1]) ^ 2 + (p[2] - g[2]) ^ 2)
                if d < best then best = d end
            end
            t.assert_near(best, 0, 1e-9,
                string.format("curve misses (%g, %g)", g[1], g[2]))
        end
    end)

    t.it("ends on the last point when open", function()
        fresh()
        plotter.curve({{0, 0}, {10, 10}, {20, 0}}, false, 4)
        local pts = only_path().pts
        t.assert_point(pts[#pts], 20, 0, 1e-9)
    end)

    t.it("closes when asked", function()
        fresh()
        plotter.curve({{0, 0}, {10, 10}, {20, 0}}, true, 4)
        t.assert_true(only_path().close)
    end)

    t.it("degrades to a polyline for two points", function()
        fresh()
        plotter.curve({{0, 0}, {10, 10}})
        t.assert_eq(#only_path().pts, 2)
    end)
end)

t.describe("curve_points", function()
    t.it("returns the points curve() would draw, without drawing them", function()
        fresh()
        local pts = plotter.curve_points({{0,0}, {10,10}, {20,0}}, false, 4)
        t.assert_eq(#plotter.paths(), 0, "curve_points must not draw")
        t.assert_true(#pts > 3)
    end)

    t.it("agrees with curve()", function()
        fresh()
        plotter.curve({{0,0}, {30,40}, {60,10}, {90,50}}, false, 6)
        local drawn = plotter.paths()[1].pts
        local returned = plotter.curve_points({{0,0}, {30,40}, {60,10}, {90,50}}, false, 6)

        t.assert_eq(#returned, #drawn)
        for i = 1, #drawn do
            t.assert_point(returned[i], drawn[i][1], drawn[i][2], 1e-12)
        end
    end)

    t.it("passes through every control point", function()
        local given = {{0,0}, {30,40}, {60,10}, {90,50}}
        local pts = plotter.curve_points(given, false, 8)
        for _, g in ipairs(given) do
            local best = math.huge
            for _, p in ipairs(pts) do
                best = math.min(best, math.sqrt((p[1]-g[1])^2 + (p[2]-g[2])^2))
            end
            t.assert_near(best, 0, 1e-9,
                string.format("curve misses (%g, %g)", g[1], g[2]))
        end
    end)

    t.it("closes when asked, and wraps the ends", function()
        local open  = plotter.curve_points({{0,0}, {10,10}, {20,0}}, false, 4)
        local shut  = plotter.curve_points({{0,0}, {10,10}, {20,0}}, true, 4)
        t.assert_true(#shut > #open, "a closed curve has one more span")
    end)

    t.it("tension controls how tightly it hugs the control polygon", function()
        local ctrl = {{0,0}, {50,0}, {50,50}, {0,50}}
        local loose = plotter.curve_points(ctrl, true, 8, 0.9)
        local tight = plotter.curve_points(ctrl, true, 8, 0.05)

        -- Low tension stays inside the polygon; high tension overshoots it
        local function max_x(p) local m = -math.huge
            for _, q in ipairs(p) do m = math.max(m, q[1]) end; return m end
        t.assert_true(max_x(loose) > max_x(tight),
            "higher tension should bulge further out")
    end)

    t.it("hands back two points unchanged, and nil below that", function()
        local two = plotter.curve_points({{0,0}, {5,5}})
        t.assert_eq(#two, 2)
        t.assert_point(two[2], 5, 5)
        t.assert_nil(plotter.curve_points({{0,0}}))
        t.assert_nil(plotter.curve_points({}))
    end)

    t.it("accepts vec2 control points", function()
        local pts = plotter.curve_points({vec2(0,0), vec2(10,10), vec2(20,0)}, false, 4)
        t.assert_point(pts[1], 0, 0)
    end)

    t.it("produces a polygon hatch() can fill", function()
        fresh()
        local blob = plotter.curve_points({{20,50},{50,20},{80,50},{50,80}}, true, 8)
        plotter.hatch(blob, 0, 5)
        t.assert_true(#plotter.paths() > 3, "the smooth shape should hatch")
    end)
end)

t.describe("grid and point", function()
    t.it("grid draws cols+1 verticals and rows+1 horizontals", function()
        fresh()
        plotter.grid(0, 0, 100, 50, 4, 2)
        t.assert_eq(#plotter.paths(), 5 + 3)
    end)

    t.it("point draws a short stroke rather than nothing", function()
        fresh()
        plotter.point(50, 50)
        local p = only_path()
        t.assert_eq(#p.pts, 2)
        local len = math.abs(p.pts[2][1] - p.pts[1][1])
        t.assert_true(len > 0, "a zero-length stroke would leave no mark")
        t.assert_near((p.pts[1][1] + p.pts[2][1]) / 2, 50, 1e-9)
    end)
end)

t.describe("begin_shape / vertex / end_shape", function()
    t.it("collects vertices into one path", function()
        fresh()
        plotter.begin_shape()
        plotter.vertex(0, 0)
        plotter.vertex(vec2(10, 10))
        plotter.vertex(20, 0)
        plotter.end_shape(true)

        local p = only_path()
        t.assert_eq(#p.pts, 3)
        t.assert_true(p.close)
        t.assert_point(p.pts[2], 10, 10)
    end)

    t.it("complains if used out of order", function()
        fresh()
        t.assert_error(function() plotter.vertex(0, 0) end, "begin_shape")
        t.assert_error(function() plotter.end_shape() end, "begin_shape")
    end)
end)

t.describe("text", function()
    t.it("draws strokes and returns the advance", function()
        fresh()
        local advance = plotter.text(10, 10, "AB", 20)
        t.assert_true(#plotter.paths() > 0, "no strokes emitted")
        t.assert_true(advance > 0)
        t.assert_near(advance, plotter.text_width("AB", 20), 1e-9)
    end)

    t.it("accepts a vec2 position", function()
        fresh()
        local a = plotter.text(vec2(10, 10), "A", 20)
        t.assert_true(a > 0)
    end)

    t.it("scales with the requested height", function()
        t.assert_near(plotter.text_width("HELLO", 20),
                      plotter.text_width("HELLO", 10) * 2, 1e-9)
    end)
end)

t.describe("bad point arguments", function()
    t.it("are reported rather than producing nil arithmetic", function()
        fresh()
        t.assert_error(function() plotter.polyline({nil, {1, 1}}) end)
        t.assert_error(function() plotter.line("a", "b") end, "expected a point")
    end)
end)
