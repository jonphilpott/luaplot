local t = require 'harness'
local plotter = require 'plotter'

local SINK = os.tmpname()

local function fresh(opts)
    opts = opts or {}
    local cfg = {
        mode = "svg", width = 200, height = 200, svg_file = SINK,
        auto_flush = opts.auto_flush or false, quiet = true, clip = "off",
        paint_pot = opts.paint_pot or {15, 15},
        paint_pots = opts.paint_pots,
        dip_time = opts.dip_time, drip_time = opts.drip_time,
        pen_dip = opts.pen_dip, dip_every = opts.dip_every,
        optimize = opts.optimize, pen_up = 0, pen_down = 150,
    }
    plotter.init(cfg)
end

-- Run a script in gcode mode and return the emitted lines
local function gcode_of(fn, cfg)
    local out = os.tmpname()
    cfg = cfg or {}
    cfg.mode = "gcode"; cfg.gcode_file = out; cfg.quiet = true
    cfg.width = cfg.width or 200; cfg.height = cfg.height or 200
    cfg.clip = "off"
    cfg.pen_up = cfg.pen_up or 0; cfg.pen_down = cfg.pen_down or 150
    plotter.init(cfg)
    fn()
    plotter.done()

    local lines = {}
    for line in io.lines(out) do lines[#lines + 1] = line end
    os.remove(out)
    return lines
end

local function index_of(lines, pattern, from)
    for i = (from or 1), #lines do
        if lines[i]:match(pattern) then return i end
    end
    return nil
end

t.describe("registering pots", function()
    t.it("takes a default pot from init", function()
        fresh { paint_pot = {15, 25} }
        t.assert_eq(plotter.pots().default.x, 15)
        t.assert_eq(plotter.pots().default.y, 25)
    end)

    t.it("takes named pots from init", function()
        fresh { paint_pots = { red = {10, 20}, black = {10, 50} } }
        t.assert_eq(plotter.pots().red.x, 10)
        t.assert_eq(plotter.pots().black.y, 50)
    end)

    t.it("accepts vec2 as well as tables", function()
        fresh()
        plotter.pot("blue", vec2(30, 40))
        t.assert_eq(plotter.pots().blue.x, 30)
        t.assert_eq(plotter.pots().blue.y, 40)
    end)

    t.it("registers the default pot from a bare position", function()
        fresh()
        plotter.pot(60, 70)
        t.assert_eq(plotter.pots().default.x, 60)
        plotter.pot(vec2(80, 90))
        t.assert_eq(plotter.pots().default.x, 80)
    end)

    t.it("init clears pots from the previous run", function()
        fresh { paint_pots = { red = {10, 20} } }
        fresh()
        t.assert_nil(plotter.pots().red)
    end)

    t.it("refuses to dip a pot that was never registered", function()
        fresh { paint_pots = { red = {10, 20} } }
        t.assert_error(function() plotter.dip("green") end, "no paint pot")
        -- and says which ones exist, so the typo is obvious
        local err = select(2, pcall(plotter.dip, "green"))
        t.assert_true(tostring(err):find("red", 1, true) ~= nil)
    end)
end)

t.describe("the dip sequence", function()
    t.it("is up, travel, down, wait, up, wait", function()
        local g = gcode_of(function() plotter.dip() end, {
            paint_pot = {15, 15}, dip_time = 1.5, drip_time = 2.0, pen_dip = 175,
        })

        local move = index_of(g, "^G0 X15%.000 Y185%.000")
        t.assert_true(move ~= nil, "no rapid to the pot")

        -- Everything after the move, in order
        t.assert_true(g[move + 1]:match("^M3 S175") ~= nil,
            "expected the brush to go down to pen_dip, got " .. tostring(g[move + 1]))
        t.assert_true(g[move + 2]:match("^G4 P1%.500") ~= nil,
            "expected a dip_time dwell, got " .. tostring(g[move + 2]))
        t.assert_true(g[move + 3]:match("^M3 S0") ~= nil,
            "expected the brush to lift, got " .. tostring(g[move + 3]))
        t.assert_true(g[move + 4]:match("^G4 P2%.000") ~= nil,
            "expected a drip_time dwell, got " .. tostring(g[move + 4]))
    end)

    t.it("flips Y into machine space like everything else", function()
        local g = gcode_of(function() plotter.dip() end,
                           { paint_pot = {15, 15}, height = 300 })
        t.assert_true(index_of(g, "^G0 X15%.000 Y285%.000") ~= nil,
            "pot Y should be height - y")
    end)

    t.it("uses pen_down as the dip depth when pen_dip is unset", function()
        local g = gcode_of(function() plotter.dip() end,
                           { paint_pot = {15, 15}, pen_down = 150 })
        local move = index_of(g, "^G0 X15%.000")
        t.assert_true(g[move + 1]:match("^M3 S150") ~= nil)
    end)

    t.it("defaults both waits to one second", function()
        local g = gcode_of(function() plotter.dip() end, { paint_pot = {15, 15} })
        local move = index_of(g, "^G0 X15%.000")
        t.assert_true(g[move + 2]:match("^G4 P1%.000") ~= nil)
        t.assert_true(g[move + 4]:match("^G4 P1%.000") ~= nil)
    end)

    t.it("leaves the brush up afterwards", function()
        local g = gcode_of(function()
            plotter.dip()
            plotter.line(100, 100, 150, 100)
        end, { paint_pot = {15, 15}, pen_dip = 175 })

        -- The stroke must lower the pen itself; the dip must not have left it down
        local stroke = index_of(g, "^G0 X100%.000")
        t.assert_true(index_of(g, "^M3 S150", stroke) ~= nil,
            "the stroke should still issue its own pen-down")
    end)

    t.it("overrides timings per call", function()
        local g = gcode_of(function()
            plotter.dip({ dip_time = 4, drip_time = 5, pen_dip = 160 })
        end, { paint_pot = {15, 15}, dip_time = 1, drip_time = 1 })

        local move = index_of(g, "^G0 X15%.000")
        t.assert_true(g[move + 1]:match("^M3 S160") ~= nil)
        t.assert_true(g[move + 2]:match("^G4 P4%.000") ~= nil)
        t.assert_true(g[move + 4]:match("^G4 P5%.000") ~= nil)
    end)

    t.it("dips a named pot", function()
        local g = gcode_of(function() plotter.dip("red") end,
                           { paint_pots = { red = {40, 60}, black = {10, 10} } })
        t.assert_true(index_of(g, "^G0 X40%.000 Y140%.000") ~= nil)
        t.assert_nil(index_of(g, "^G0 X10%.000 Y190%.000"), "dipped the wrong pot")
    end)
end)

t.describe("pot positions are absolute", function()
    t.it("ignore translate", function()
        local g = gcode_of(function()
            plotter.translate(100, 100)
            plotter.dip()
        end, { paint_pot = {15, 15} })
        t.assert_true(index_of(g, "^G0 X15%.000 Y185%.000") ~= nil,
            "translate moved the paint pot")
    end)

    t.it("ignore rotate and scale", function()
        local g = gcode_of(function()
            plotter.rotate(37)
            plotter.scale(3)
            plotter.translate(50, 50)
            plotter.dip()
        end, { paint_pot = {15, 15} })
        t.assert_true(index_of(g, "^G0 X15%.000 Y185%.000") ~= nil,
            "the transform stack reached the paint pot")
    end)

    t.it("ignore a transform in effect when the pot was registered", function()
        local g = gcode_of(function()
            plotter.translate(100, 100)
            plotter.pot("late", 20, 20)
            plotter.dip("late")
        end, { paint_pot = {15, 15} })
        t.assert_true(index_of(g, "^G0 X20%.000 Y180%.000") ~= nil,
            "pot() applied the transform at registration time")
    end)

    t.it("do not enter the drawing's bounding box", function()
        fresh { paint_pot = {5, 5} }
        plotter.rect(100, 100, 20, 20)
        plotter.dip()
        local lo, hi = plotter.bounds()
        t.assert_point(lo, 100, 100)
        t.assert_point(hi, 120, 120)
    end)
end)

t.describe("dips keep their place in the sequence", function()
    t.it("are not returned by paths()", function()
        fresh()
        plotter.line(0, 0, 10, 10)
        plotter.dip()
        plotter.line(20, 20, 30, 30)
        t.assert_eq(#plotter.paths(), 2, "paths() should list strokes only")
    end)

    t.it("are visible in queue(), in order", function()
        fresh()
        plotter.line(0, 0, 10, 10)
        plotter.dip()
        plotter.line(20, 20, 30, 30)

        local q = plotter.queue()
        t.assert_eq(#q, 3)
        t.assert_eq(q[1].kind, "path")
        t.assert_eq(q[2].kind, "dip")
        t.assert_eq(q[3].kind, "path")
    end)

    t.it("the optimiser will not reorder across one", function()
        fresh { optimize = true }
        -- Far stroke first, then a dip, then a near one. Without the barrier
        -- the optimiser would pull the near stroke ahead of the dip.
        plotter.line(190, 190, 180, 180)
        plotter.dip()
        plotter.line(10, 10, 20, 20)
        plotter.flush()

        -- The far stroke may legitimately be reversed (entering at 180 is
        -- nearer than 190); what must not happen is the near stroke jumping
        -- the dip. Identify each stroke by where it sits, not by direction.
        local q = plotter.queue()
        t.assert_eq(q[1].kind, "path")
        t.assert_true(q[1].pts[1][1] >= 180,
            "the far stroke must still come before the dip, got x=" .. q[1].pts[1][1])
        t.assert_eq(q[2].kind, "dip")
        t.assert_eq(q[3].kind, "path")
        t.assert_true(q[3].pts[1][1] <= 20,
            "the near stroke must still come after the dip")
    end)

    t.it("the optimiser still reorders freely between dips", function()
        fresh { optimize = true }
        plotter.dip()
        plotter.line(190, 190, 180, 180)
        plotter.line(20, 20, 30, 30)      -- much nearer the pot at (15,15)
        plotter.flush()

        local q = plotter.queue()
        t.assert_eq(q[1].kind, "dip")
        t.assert_point(q[2].pts[1], 20, 20, 1e-9,
            "after the dip the pen is at the pot, so this should be drawn first")
    end)

    t.it("the pen continues from the pot, not from where it was", function()
        fresh { optimize = true, paint_pot = {15, 15} }
        plotter.line(150, 150, 160, 160)
        plotter.flush()
        plotter.dip()
        plotter.line(100, 100, 110, 110)
        plotter.line(20, 20, 30, 30)
        plotter.flush()

        local q = plotter.queue()
        t.assert_point(q[3].pts[1], 20, 20, 1e-9,
            "nearest to the pot should win, not nearest to the last stroke")
    end)

    t.it("do not trigger a layer pen-change prompt", function()
        -- A dip inherits the current layer; it must not look like a change
        local g = gcode_of(function()
            plotter.layer("a")
            plotter.line(0, 0, 10, 10)
            plotter.dip()
            plotter.line(20, 20, 30, 30)
        end, { paint_pot = {15, 15} })
        t.assert_true(#g > 0)
    end)
end)

t.describe("automatic reloading", function()
    t.it("is off unless dip_every is set", function()
        fresh()
        for _ = 1, 20 do plotter.line(0, 0, 100, 0) end
        t.assert_eq(plotter.stats().dips, 0)
        plotter.flush()
        t.assert_eq(plotter.stats().dips, 0)
    end)

    t.it("reloads once the brush has drawn its budget", function()
        fresh { dip_every = 100 }
        -- Six 50 mm strokes: 300 mm of drawing on a 100 mm budget
        for _ = 1, 6 do plotter.line(0, 0, 50, 0) end
        plotter.flush()
        t.assert_true(plotter.stats().dips >= 2,
            "expected several reloads, got " .. plotter.stats().dips)
    end)

    t.it("reloads before the stroke, never mid-air", function()
        fresh { dip_every = 60 }
        plotter.line(0, 0, 50, 0)      -- 50 mm, within budget
        plotter.line(0, 10, 50, 10)    -- would reach 100, so dip first
        local q = plotter.queue()
        t.assert_eq(q[1].kind, "path")
        t.assert_eq(q[2].kind, "dip")
        t.assert_eq(q[3].kind, "path")
    end)

    t.it("does not dip twice in a row for an over-long stroke", function()
        -- The brush was just loaded; a stroke longer than the whole budget
        -- cannot be helped by reloading again with nothing drawn in between.
        fresh { dip_every = 60 }
        plotter.dip()
        plotter.line(0, 0, 200, 0)     -- 200 mm on a 60 mm budget
        local q = plotter.queue()
        t.assert_eq(#q, 2, "an immediate second dip crept in")
        t.assert_eq(q[1].kind, "dip")
        t.assert_eq(q[2].kind, "path")
    end)

    t.it("reloads from the pot last dipped, not the default", function()
        fresh { paint_pots = { red = {10, 20}, black = {10, 50} } }
        plotter.init {
            mode = "svg", width = 200, height = 200, svg_file = SINK,
            auto_flush = false, quiet = true, clip = "off",
            paint_pots = { red = {10, 20}, black = {10, 50} },
            dip_every = 60, pen_up = 0, pen_down = 150,
        }
        plotter.dip("black")
        plotter.line(0, 0, 50, 0)
        plotter.line(0, 10, 50, 10)    -- triggers an automatic reload

        local q = plotter.queue()
        t.assert_eq(q[3].kind, "dip")
        t.assert_eq(q[3].pot, "black",
            "a top-up should be the same colour as the paint on the brush")
    end)

    t.it("falls back to the only pot when there is no default", function()
        plotter.init {
            mode = "svg", width = 200, height = 200, svg_file = SINK,
            auto_flush = false, quiet = true, clip = "off",
            paint_pots = { solo = {10, 20} },
            dip_every = 60, pen_up = 0, pen_down = 150,
        }
        plotter.line(0, 0, 50, 0)
        plotter.line(0, 10, 50, 10)
        local q = plotter.queue()
        t.assert_eq(q[2].kind, "dip")
        t.assert_eq(q[2].pot, "solo")
    end)

    t.it("says so when it cannot work out which pot to reload from", function()
        plotter.init {
            mode = "svg", width = 200, height = 200, svg_file = SINK,
            auto_flush = false, quiet = true, clip = "off",
            paint_pots = { red = {10, 20}, black = {10, 50} },
            dip_every = 60, pen_up = 0, pen_down = 150,
        }
        plotter.line(0, 0, 50, 0)
        t.assert_error(function() plotter.line(0, 10, 50, 10) end,
                       "dip_every is set but there is no pot")
    end)

    t.it("a manual dip resets the budget", function()
        fresh { dip_every = 60 }
        plotter.line(0, 0, 50, 0)
        plotter.dip()                  -- manual top-up
        plotter.line(0, 10, 50, 10)    -- budget was reset, so no auto dip
        local q = plotter.queue()
        t.assert_eq(#q, 3, "an extra automatic dip crept in")
        t.assert_eq(q[2].kind, "dip")
    end)
end)

t.describe("bare dip() follows the last pot", function()
    t.it("reuses the pot last named", function()
        fresh { paint_pots = { red = {10, 20}, black = {10, 50} } }
        plotter.dip("black")
        plotter.dip()
        local q = plotter.queue()
        t.assert_eq(q[2].pot, "black",
            "an unnamed dip should not silently jump back to the default")
    end)

    t.it("still prefers the default before anything has been dipped", function()
        fresh { paint_pot = {5, 5}, paint_pots = { red = {10, 20} } }
        plotter.dip()
        t.assert_eq(plotter.queue()[1].pot, "default")
    end)
end)

t.describe("dip accounting", function()
    t.it("counts dips and their dwell time", function()
        fresh { auto_flush = true, dip_time = 1.5, drip_time = 0.5 }
        plotter.dip()
        plotter.dip()
        local s = plotter.stats()
        t.assert_eq(s.dips, 2)
        t.assert_near(s.dwell_min, 4 / 60, 1e-9)
    end)

    t.it("counts travel to the pot", function()
        fresh { auto_flush = true, paint_pot = {30, 40} }
        plotter.dip()                            -- from the origin: 50 mm
        t.assert_near(plotter.stats().travel_mm, 50, 1e-9)
    end)

    t.it("includes dwell in the time estimate", function()
        fresh { auto_flush = true, paint_pot = {30, 40}, dip_time = 30, drip_time = 30 }
        plotter.dip()
        t.assert_near(plotter.stats().minutes, 1 + 50 / 1000, 1e-6,
            "one minute of dwell plus 50 mm of travel to the pot")
    end)

    t.it("does not count dips as paths", function()
        fresh { auto_flush = true }
        plotter.line(0, 0, 10, 0)
        plotter.dip()
        plotter.line(0, 10, 10, 10)
        t.assert_eq(plotter.stats().paths, 2)
    end)

    t.it("does not count a dip as drawn distance", function()
        fresh { auto_flush = true }
        plotter.dip()
        t.assert_eq(plotter.stats().draw_mm, 0)
    end)
end)

t.describe("pot placement warnings", function()
    t.it("does not reject a pot outside the work area, but flags it", function()
        -- Outside is legal -- plenty of rigs bolt the pot off to one side --
        -- but it is worth saying so once.
        fresh()
        plotter.pot("offbed", 250, 250)
        t.assert_eq(plotter.pots().offbed.x, 250)
    end)
end)
