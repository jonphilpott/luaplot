local t = require 'harness'
local plotter = require 'plotter'

-- A throwaway SVG target: these tests only inspect plotter.paths(), but init
-- needs somewhere to point. auto_flush is off so nothing is written at all.
local SINK = os.tmpname()

local function fresh(opts)
    opts = opts or {}
    plotter.init {
        mode = "svg", width = opts.width or 1000, height = opts.height or 1000,
        svg_file = SINK, auto_flush = false, quiet = true,
        clip = opts.clip or "off",
    }
end

-- The single point produced by drawing a two-point line from the origin
local function probe(x, y)
    plotter.line(0, 0, x, y)
    local p = plotter.paths()
    return p[#p].pts[2]
end

t.describe("transform stack", function()
    t.it("starts as the identity", function()
        fresh()
        t.assert_point(probe(10, 20), 10, 20)
    end)

    t.it("translate offsets", function()
        fresh()
        plotter.translate(5, 7)
        t.assert_point(probe(10, 20), 15, 27)
    end)

    t.it("translate accepts a vec2", function()
        fresh()
        plotter.translate(vec2(5, 7))
        t.assert_point(probe(10, 20), 15, 27)
    end)

    t.it("rotate takes degrees", function()
        fresh()
        plotter.rotate(90)
        t.assert_point(probe(10, 0), 0, 10, 1e-9)
    end)

    t.it("scale takes one or two factors", function()
        fresh()
        plotter.scale(2)
        t.assert_point(probe(10, 20), 20, 40)

        fresh()
        plotter.scale(2, 3)
        t.assert_point(probe(10, 20), 20, 60)
    end)

    t.it("composes in written order, like Processing", function()
        -- translate then rotate: rotation happens about the new origin
        fresh()
        plotter.translate(100, 100)
        plotter.rotate(90)
        t.assert_point(probe(10, 0), 100, 110, 1e-9)

        -- the other order gives a different answer
        fresh()
        plotter.rotate(90)
        plotter.translate(100, 100)
        t.assert_point(probe(10, 0), -100, 110, 1e-9)
    end)

    t.it("push/pop restores the previous transform", function()
        fresh()
        plotter.translate(10, 10)
        plotter.push()
            plotter.translate(100, 100)
            t.assert_point(probe(0, 0), 110, 110)
        plotter.pop()
        t.assert_point(probe(0, 0), 10, 10)
    end)

    t.it("nests", function()
        fresh()
        plotter.push()
            plotter.translate(10, 0)
            plotter.push()
                plotter.translate(0, 10)
                plotter.push()
                    plotter.scale(2)
                    t.assert_point(probe(5, 5), 20, 20)
                plotter.pop()
                t.assert_point(probe(5, 5), 15, 15)
            plotter.pop()
            t.assert_point(probe(5, 5), 15, 5)
        plotter.pop()
        t.assert_point(probe(5, 5), 5, 5)
    end)

    t.it("never pops the last matrix", function()
        fresh()
        plotter.translate(10, 10)
        for _ = 1, 10 do plotter.pop() end
        -- Still usable, and still holding the one remaining matrix
        t.assert_point(probe(0, 0), 10, 10)
    end)

    t.it("reset_matrix clears without unwinding", function()
        fresh()
        plotter.push()
            plotter.translate(50, 50)
            plotter.reset_matrix()
            t.assert_point(probe(1, 1), 1, 1)
        plotter.pop()
        t.assert_point(probe(1, 1), 1, 1)
    end)

    t.it("a rotation and its inverse cancel", function()
        fresh()
        plotter.rotate(37)
        plotter.rotate(-37)
        t.assert_point(probe(10, 20), 10, 20, 1e-9)
    end)

    t.it("init resets the stack", function()
        fresh()
        plotter.translate(100, 100)
        fresh()
        t.assert_point(probe(1, 1), 1, 1)
    end)
end)
