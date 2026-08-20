local t = require 'harness'
local hershey = require 'hershey'
local plotter = require 'plotter'

t.describe("hershey metrics", function()
    t.it("measure agrees with the advance from get_strokes", function()
        for _, s in ipairs({"A", "HELLO", "hello world", "0123456789", "!?.,"}) do
            local _, advance = hershey.get_strokes(s, 0, 0, 20)
            t.assert_near(hershey.measure(s, 20), advance, 1e-9,
                "mismatch for " .. string.format("%q", s))
        end
    end)

    t.it("scales linearly with height", function()
        t.assert_near(hershey.measure("HELLO", 30),
                      hershey.measure("HELLO", 10) * 3, 1e-9)
    end)

    t.it("an empty string has zero width and no strokes", function()
        local strokes, advance = hershey.get_strokes("", 0, 0, 20)
        t.assert_eq(#strokes, 0)
        t.assert_eq(advance, 0)
        t.assert_eq(hershey.measure("", 20), 0)
    end)

    t.it("width accumulates across characters", function()
        local a  = hershey.measure("A", 20)
        local aa = hershey.measure("AA", 20)
        t.assert_near(aa, a * 2, 1e-9)
    end)

    t.it("a space advances but draws nothing", function()
        t.assert_true(hershey.measure(" ", 20) > 0)
        local strokes = hershey.get_strokes(" ", 0, 0, 20)
        t.assert_eq(#strokes, 0)
    end)

    t.it("plotter.text_width is the same measurement", function()
        t.assert_eq(plotter.text_width("PLOTTER", 12),
                    hershey.measure("PLOTTER", 12))
    end)
end)

t.describe("hershey strokes", function()
    t.it("places glyphs at the requested origin", function()
        local strokes = hershey.get_strokes("H", 100, 200, 20)
        t.assert_true(#strokes > 0)

        local minx, maxy = math.huge, -math.huge
        for _, stroke in ipairs(strokes) do
            for _, p in ipairs(stroke) do
                if p[1] < minx then minx = p[1] end
                if p[2] > maxy then maxy = p[2] end
            end
        end
        -- (x, y) is the left end of the baseline
        t.assert_true(minx >= 99, "glyph starts left of the origin: " .. minx)
        t.assert_near(maxy, 200, 2, "baseline should sit at y")
    end)

    t.it("cap height matches the requested height", function()
        local strokes = hershey.get_strokes("H", 0, 0, 20)
        local miny = math.huge
        for _, stroke in ipairs(strokes) do
            for _, p in ipairs(stroke) do
                if p[2] < miny then miny = p[2] end
            end
        end
        t.assert_near(-miny, 20, 1.5, "H should be about one cap height tall")
    end)

    t.it("every stroke is drawable", function()
        local strokes = hershey.get_strokes("Wg@#", 0, 0, 20)
        for _, stroke in ipairs(strokes) do
            t.assert_true(#stroke >= 2, "a one-point stroke draws nothing")
        end
    end)

    t.it("skips unknown characters without failing", function()
        local ok = pcall(hershey.get_strokes, "A\1\2B", 0, 0, 20)
        t.assert_true(ok)
    end)
end)
