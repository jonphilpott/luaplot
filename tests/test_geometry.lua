local t = require 'harness'
local plotter = require 'plotter'

local SINK = os.tmpname()

local function fresh(opts)
    opts = opts or {}
    plotter.init {
        mode = "svg", width = opts.width or 100, height = opts.height or 100,
        svg_file = SINK, auto_flush = opts.auto_flush or false,
        quiet = true, clip = opts.clip or "off", feed = opts.feed or 1000,
    }
end

t.describe("bounds", function()
    t.it("is nil before anything is drawn", function()
        fresh()
        t.assert_nil(plotter.bounds())
    end)

    t.it("covers everything drawn", function()
        fresh()
        plotter.line(10, 20, 30, 40)
        plotter.line(-5, 60, 5, 70)
        local lo, hi = plotter.bounds()
        t.assert_point(lo, -5, 20)
        t.assert_point(hi, 30, 70)
    end)

    t.it("returns vec2 values", function()
        fresh()
        plotter.rect(10, 10, 20, 20)
        local lo, hi = plotter.bounds()
        t.assert_true(vec2.is_vec2(lo) and vec2.is_vec2(hi))
        t.assert_near(hi:dist(lo), math.sqrt(800), 1e-9)
    end)

    t.it("accounts for the transform", function()
        fresh()
        plotter.translate(50, 50)
        plotter.rect(0, 0, 10, 10)
        local lo, hi = plotter.bounds()
        t.assert_point(lo, 50, 50)
        t.assert_point(hi, 60, 60)
    end)
end)

t.describe("clipping", function()
    t.it("off keeps geometry outside the page", function()
        fresh { clip = "off" }
        plotter.line(-50, 50, 150, 50)
        t.assert_point(plotter.paths()[1].pts[1], -50, 50)
    end)

    t.it("clip trims a crossing segment to the boundary", function()
        fresh { clip = "clip" }
        plotter.line(-50, 50, 150, 50)
        local p = plotter.paths()
        t.assert_eq(#p, 1)
        t.assert_point(p[1].pts[1], 0, 50, 1e-9)
        t.assert_point(p[1].pts[2], 100, 50, 1e-9)
    end)

    t.it("clip drops geometry entirely outside", function()
        fresh { clip = "clip" }
        plotter.line(200, 200, 300, 300)
        plotter.line(-10, -10, -20, -20)
        t.assert_eq(#plotter.paths(), 0)
    end)

    t.it("clip leaves interior geometry untouched", function()
        fresh { clip = "clip" }
        plotter.line(10, 10, 90, 90)
        local p = plotter.paths()[1]
        t.assert_point(p.pts[1], 10, 10)
        t.assert_point(p.pts[2], 90, 90)
    end)

    t.it("clip splits a path that leaves and re-enters", function()
        fresh { clip = "clip" }
        -- out to the right and back in again
        plotter.polyline({{10, 50}, {150, 50}, {150, 80}, {10, 80}})
        local p = plotter.paths()
        t.assert_eq(#p, 2, "expected two surviving runs")
        for _, run in ipairs(p) do
            for _, pt in ipairs(run.pts) do
                t.assert_true(pt[1] >= -1e-9 and pt[1] <= 100 + 1e-9,
                    "x escaped the page: " .. pt[1])
            end
        end
    end)

    t.it("clip keeps every point inside the work area", function()
        fresh { clip = "clip" }
        plotter.circle(50, 50, 90, 60)
        for _, run in ipairs(plotter.paths()) do
            for _, pt in ipairs(run.pts) do
                t.assert_true(pt[1] >= -1e-9 and pt[1] <= 100 + 1e-9)
                t.assert_true(pt[2] >= -1e-9 and pt[2] <= 100 + 1e-9)
            end
        end
    end)

    t.it("a clipped shape is no longer marked closed", function()
        fresh { clip = "clip" }
        plotter.rect(-20, -20, 60, 60)
        for _, run in ipairs(plotter.paths()) do
            t.assert_false(run.close)
        end
    end)

    t.it("warn keeps the geometry", function()
        fresh { clip = "warn" }
        plotter.line(-50, 50, 150, 50)
        t.assert_eq(#plotter.paths(), 1)
        t.assert_point(plotter.paths()[1].pts[1], -50, 50)
    end)

    t.it("rejects an unknown clip mode", function()
        t.assert_error(function()
            plotter.init { mode = "svg", width = 10, height = 10,
                           svg_file = SINK, clip = "sometimes" }
        end, "bad clip mode")
    end)
end)

t.describe("stats", function()
    t.it("measures drawn length", function()
        fresh { auto_flush = true }
        plotter.line(0, 0, 30, 40)          -- 50 mm
        local s = plotter.stats()
        t.assert_near(s.draw_mm, 50, 1e-9)
    end)

    t.it("counts the closing segment of a closed path", function()
        fresh { auto_flush = true }
        plotter.rect(0, 0, 10, 20)          -- perimeter 60 mm
        t.assert_near(plotter.stats().draw_mm, 60, 1e-9)
    end)

    t.it("measures pen-up travel from the origin", function()
        fresh { auto_flush = true }
        plotter.line(30, 40, 30, 50)        -- travel 50 mm to the start
        t.assert_near(plotter.stats().travel_mm, 50, 1e-9)
    end)

    t.it("estimates time from the feed rate", function()
        fresh { auto_flush = true, feed = 1000 }
        plotter.line(0, 0, 0, 100)          -- 100 mm drawn, 0 travel
        t.assert_near(plotter.stats().minutes, 0.1, 1e-9)
    end)

    t.it("counts flushed paths only", function()
        fresh { auto_flush = false }
        plotter.line(0, 0, 1, 1)
        plotter.line(2, 2, 3, 3)
        t.assert_eq(plotter.stats().paths, 0, "nothing flushed yet")
        plotter.flush()
        t.assert_eq(plotter.stats().paths, 2)
    end)
end)

t.describe("flush and done", function()
    t.it("flush emits pending paths and is then a no-op", function()
        fresh { auto_flush = false }
        plotter.line(0, 0, 10, 0)
        plotter.flush()
        local after = plotter.stats().draw_mm
        plotter.flush()
        plotter.flush()
        t.assert_near(plotter.stats().draw_mm, after, 1e-12,
            "re-flushing must not double-count")
    end)

    t.it("flush is safe with nothing pending", function()
        fresh()
        plotter.flush()
        t.assert_eq(plotter.stats().paths, 0)
    end)

    t.it("drawing can continue after a flush", function()
        fresh { auto_flush = false }
        plotter.line(0, 0, 10, 0)
        plotter.flush()
        plotter.line(0, 10, 10, 10)
        plotter.flush()
        t.assert_eq(plotter.stats().paths, 2)
        t.assert_near(plotter.stats().draw_mm, 20, 1e-9)
    end)

    t.it("done can be called repeatedly", function()
        fresh { auto_flush = false }
        plotter.line(0, 0, 10, 0)
        plotter.done()
        local after = plotter.stats().draw_mm
        plotter.done()
        plotter.done()
        t.assert_near(plotter.stats().draw_mm, after, 1e-12)
    end)

    t.it("done can be called repeatedly in gcode mode too", function()
        -- The svg case above never exercises the port-closing branch
        local out = os.tmpname()
        plotter.init { mode = "gcode", width = 100, height = 100,
                       gcode_file = out, quiet = true, clip = "off" }
        plotter.line(10, 10, 20, 20)
        plotter.done()
        plotter.done()
        plotter.done()
        os.remove(out)
        t.assert_eq(plotter.stats().paths, 1)
    end)

    t.it("drawing after done() is refused, and says why", function()
        -- Previously this surfaced as a bare "Serial port is not open" from
        -- deep inside serial.writeline, and only in serial mode -- so the same
        -- script appeared to work in svg and failed on hardware
        fresh { auto_flush = false }
        plotter.line(0, 0, 10, 10)
        plotter.done()

        local err = t.assert_error(function() plotter.line(20, 20, 30, 30) end,
                                   "after plotter%.done")
        t.assert_true(tostring(err):find("keep_open", 1, true) ~= nil,
            "the message should name the alternatives")
    end)

    t.it("every primitive is refused, not just line", function()
        fresh()
        plotter.done()
        t.assert_error(function() plotter.rect(0, 0, 10, 10) end, "after plotter%.done")
        t.assert_error(function() plotter.circle(50, 50, 10) end, "after plotter%.done")
        t.assert_error(function() plotter.text(0, 0, "A", 10) end, "after plotter%.done")
        t.assert_error(function() plotter.polyline({{0,0},{1,1}}) end, "after plotter%.done")
    end)

    t.it("dip is refused too", function()
        plotter.init { mode = "svg", width = 100, height = 100, svg_file = SINK,
                       quiet = true, clip = "off", paint_pot = {5, 5},
                       pen_up = 0, pen_down = 150 }
        plotter.done()
        t.assert_error(plotter.dip, "after plotter%.done")
    end)

    t.it("keep_open leaves the session usable", function()
        fresh { auto_flush = false }
        plotter.line(0, 0, 10, 10)
        plotter.done { keep_open = true }
        plotter.line(20, 20, 30, 30)      -- must not raise
        plotter.done()
        t.assert_eq(plotter.stats().paths, 2)
    end)

    t.it("init reopens a finished session", function()
        fresh()
        plotter.done()
        fresh()
        plotter.line(0, 0, 10, 10)        -- must not raise
        t.assert_eq(#plotter.paths(), 1)
    end)

    t.it("auto_flush emits as it goes", function()
        fresh { auto_flush = true }
        plotter.line(0, 0, 10, 0)
        t.assert_eq(plotter.stats().paths, 1, "should already be out")
    end)

    t.it("optimize implies auto_flush off", function()
        plotter.init { mode = "svg", width = 100, height = 100, svg_file = SINK,
                       optimize = true, auto_flush = true, quiet = true }
        plotter.line(0, 0, 10, 0)
        t.assert_eq(plotter.stats().paths, 0,
            "optimize has to hold paths back to reorder them")
        plotter.flush()
        t.assert_eq(plotter.stats().paths, 1)
    end)
end)

t.describe("layers", function()
    t.it("tag the paths drawn after them", function()
        fresh()
        plotter.line(0, 0, 1, 1)
        plotter.layer("ink")
        plotter.line(1, 1, 2, 2)
        plotter.layer(nil)
        plotter.line(2, 2, 3, 3)

        local p = plotter.paths()
        t.assert_nil(p[1].layer)
        t.assert_eq(p[2].layer, "ink")
        t.assert_nil(p[3].layer)
    end)

    t.it("appear as <g> groups in the SVG", function()
        local out = os.tmpname()
        plotter.init { mode = "svg", width = 100, height = 100,
                       svg_file = out, quiet = true, clip = "off" }
        plotter.layer("a"); plotter.rect(10, 10, 20, 20)
        plotter.layer("b"); plotter.rect(40, 40, 20, 20)
        plotter.done()

        local f = assert(io.open(out))
        local svg = f:read("a")
        f:close()
        os.remove(out)

        t.assert_eq(select(2, svg:gsub("<g ", "")), 2, "expected two groups")
        t.assert_eq(select(2, svg:gsub("</g>", "")), 2, "groups must be closed")
        t.assert_true(svg:find('id="a"', 1, true) ~= nil)
        t.assert_true(svg:find('id="b"', 1, true) ~= nil)
    end)

    t.it("unlayered output has no groups at all", function()
        local out = os.tmpname()
        plotter.init { mode = "svg", width = 100, height = 100,
                       svg_file = out, quiet = true, clip = "off" }
        plotter.rect(10, 10, 20, 20)
        plotter.done()

        local f = assert(io.open(out))
        local svg = f:read("a")
        f:close()
        os.remove(out)

        t.assert_eq(select(2, svg:gsub("<g ", "")), 0)
    end)
end)

t.describe("origin", function()
    local function gcode_lines(cfg)
        local out = os.tmpname()
        cfg.mode = "gcode"; cfg.gcode_file = out; cfg.quiet = true
        cfg.width = cfg.width or 100; cfg.height = cfg.height or 200
        cfg.clip = "off"
        plotter.init(cfg)
        plotter.line(10, 20, 30, 40)
        plotter.done()
        local lines = {}
        for line in io.lines(out) do lines[#lines + 1] = line end
        os.remove(out)
        return table.concat(lines, "\n")
    end

    t.it("defaults to no offset, and zeroes the frame at the head", function()
        local g = gcode_lines {}
        t.assert_true(g:find("G92 X0 Y0 Z0", 1, true) ~= nil,
            "without an origin the page should start where the head is")
        -- drawing (10,20) on a 200-tall page is machine (10, 180)
        t.assert_true(g:find("X10.000 Y180.000", 1, true) ~= nil)
    end)

    t.it("shifts every coordinate by the origin", function()
        local g = gcode_lines { origin = {43, 127} }
        t.assert_true(g:find("X53.000 Y307.000", 1, true) ~= nil,
            "expected (10,20) to land at (10+43, 200-20+127)")
        t.assert_true(g:find("X73.000 Y287.000", 1, true) ~= nil,
            "expected (30,40) to land at (30+43, 200-40+127)")
    end)

    t.it("clears stale work offsets instead of zeroing the frame", function()
        local g = gcode_lines { origin = {43, 127} }
        t.assert_true(g:find("G92.1", 1, true) ~= nil,
            "an absolute plot has to cancel any G92 offset in force")
        t.assert_nil(g:match("G92 X0 Y0 Z0"),
            "and must not re-zero the frame at the head")
    end)

    t.it("accepts a vec2", function()
        local g = gcode_lines { origin = vec2(43, 127) }
        t.assert_true(g:find("X53.000 Y307.000", 1, true) ~= nil)
    end)

    t.it("parks at the page corner rather than machine zero", function()
        local g = gcode_lines { origin = {43, 127} }
        t.assert_true(g:find("G0 X43.000 Y127.000", 1, true) ~= nil,
            "parking at machine zero could be a long traverse away")
    end)

    t.it("an origin of 0,0 still means absolute", function()
        -- Explicitly asking for the machine frame is different from not asking
        local g = gcode_lines { origin = {0, 0} }
        t.assert_true(g:find("G92.1", 1, true) ~= nil)
        t.assert_nil(g:match("G92 X0 Y0 Z0"))
    end)

    t.it("does not disturb drawing-space geometry", function()
        -- The origin is a machine-space offset, so paths() is unaffected
        plotter.init { mode = "svg", width = 100, height = 200, svg_file = SINK,
                       origin = {43, 127}, quiet = true, clip = "off",
                       auto_flush = false }
        plotter.line(10, 20, 30, 40)
        t.assert_point(plotter.paths()[1].pts[1], 10, 20)
    end)

    t.it("does not move the clip window", function()
        -- Clipping is against the paper, not the bed
        plotter.init { mode = "svg", width = 100, height = 200, svg_file = SINK,
                       origin = {43, 127}, quiet = true, clip = "clip",
                       auto_flush = false }
        plotter.line(-50, 100, 150, 100)
        local p = plotter.paths()[1]
        t.assert_point(p.pts[1], 0, 100, 1e-9)
        t.assert_point(p.pts[2], 100, 100, 1e-9)
    end)
end)

t.describe("gcode output", function()
    t.it("writes a file with the expected preamble and postamble", function()
        local out = os.tmpname()
        plotter.init { mode = "gcode", width = 100, height = 100,
                       gcode_file = out, quiet = true, clip = "off" }
        plotter.line(10, 10, 20, 20)
        plotter.done()

        local f = assert(io.open(out))
        local nc = f:read("a")
        f:close()
        os.remove(out)

        t.assert_true(nc:find("G21", 1, true) ~= nil, "missing metric units")
        t.assert_true(nc:find("G90", 1, true) ~= nil, "missing absolute mode")
        t.assert_true(nc:find("M5", 1, true) ~= nil, "missing spindle off")
        -- Y is flipped for the machine: page y=10 on a 100 mm page is Y90
        t.assert_true(nc:find("Y90.000", 1, true) ~= nil,
                      "Y should be flipped into machine space")
    end)

    t.it("lifts the pen once per path, not per segment", function()
        local out = os.tmpname()
        plotter.init { mode = "gcode", width = 100, height = 100,
                       gcode_file = out, quiet = true, clip = "off",
                       pen_up = 90, pen_down = 30 }
        plotter.circle(50, 50, 20, 36)      -- 36 segments, one stroke
        plotter.done()

        local f = assert(io.open(out))
        local nc = f:read("a")
        f:close()
        os.remove(out)

        t.assert_eq(select(2, nc:gsub("M3 S30", "")), 1,
            "the pen should go down exactly once for one closed path")
    end)
end)
