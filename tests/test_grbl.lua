local t = require 'harness'
local grbl = require 'grbl'
local plotter = require 'plotter'

-- A realistic $$ response, as serial.query would hand it back
local SAMPLE = {
    "$0=10", "$1=25", "$2=0", "$3=0", "$4=0", "$5=0", "$6=0",
    "$10=1", "$11=0.010", "$12=0.002", "$13=0",
    "$20=0", "$21=0", "$22=1", "$23=3", "$24=25.000", "$25=500.000",
    "$26=250", "$27=1.000",
    "$30=1000", "$31=0", "$32=0",
    "$100=80.000", "$101=80.000", "$102=250.000",
    "$110=5000.000", "$111=5000.000", "$112=500.000",
    "$120=100.000", "$121=100.000", "$122=10.000",
    "$130=200.000", "$131=200.000", "$132=200.000",
}

t.describe("parsing $$ output", function()
    t.it("reads every setting", function()
        local s, order = plotter.parse_grbl_settings(SAMPLE)
        t.assert_eq(#order, #SAMPLE)
        t.assert_eq(s[100], 80.0)
        t.assert_eq(s[101], 80.0)
        t.assert_eq(s[130], 200.0)
        t.assert_eq(s[0], 10)
    end)

    t.it("preserves the machine's ordering", function()
        local _, order = plotter.parse_grbl_settings(SAMPLE)
        t.assert_eq(order[1], 0)
        t.assert_eq(order[#order], 132)
    end)

    t.it("keeps fractional values", function()
        local s = plotter.parse_grbl_settings(SAMPLE)
        t.assert_near(s[11], 0.010, 1e-12)
    end)

    t.it("ignores noise in the stream", function()
        local s = plotter.parse_grbl_settings({
            "Grbl 1.1h ['$' for help]",
            "$100=80.000",
            "<Idle|MPos:0.000,0.000,0.000>",
            "",
            "not a setting at all",
            "$101=81.5",
        })
        t.assert_eq(s[100], 80.0)
        t.assert_eq(s[101], 81.5)
    end)

    t.it("handles negative values", function()
        local s = plotter.parse_grbl_settings({"$27=-1.500"})
        t.assert_eq(s[27], -1.5)
    end)

    t.it("returns nothing for an empty response", function()
        local s, order = plotter.parse_grbl_settings({})
        t.assert_eq(#order, 0)
        t.assert_nil(s[100])
    end)
end)

t.describe("setting names", function()
    t.it("knows the ones calibration touches", function()
        t.assert_true(grbl.describe(100):find("X steps") ~= nil)
        t.assert_true(grbl.describe(101):find("Y steps") ~= nil)
        t.assert_eq(grbl.X_STEPS_PER_MM, 100)
        t.assert_eq(grbl.Y_STEPS_PER_MM, 101)
    end)

    t.it("degrades gracefully for an unknown number", function()
        t.assert_true(grbl.describe(9999):find("unknown") ~= nil)
    end)
end)

t.describe("value formatting", function()
    t.it("prints whole numbers without a decimal point", function()
        t.assert_eq(grbl.format_value(10), "10")
        t.assert_eq(grbl.format_value(80.0), "80")
    end)

    t.it("keeps three places for fractions", function()
        t.assert_eq(grbl.format_value(81.301), "81.301")
        t.assert_eq(grbl.format_value(0.01), "0.010")
    end)
end)

t.describe("dump and parse round-trip", function()
    t.it("survives a write and read back with no spurious diff", function()
        local settings, order = plotter.parse_grbl_settings(SAMPLE)
        local text = grbl.format_dump(settings, order,
            { build = {"[VER:1.1h.20190825:]"}, startup = {"$N0=G54", "$N1="} })

        local back = grbl.parse_dump(text)
        local changes, missing = grbl.diff(settings, back)
        t.assert_eq(#changes, 0, "round-trip changed a value")
        t.assert_eq(#missing, 0)
    end)

    t.it("annotates settings with their names", function()
        local settings, order = plotter.parse_grbl_settings(SAMPLE)
        local text = grbl.format_dump(settings, order)
        t.assert_true(text:find("X steps/mm", 1, true) ~= nil)
        t.assert_true(text:find("$100=80", 1, true) ~= nil)
    end)

    t.it("records the machine's build info as a comment", function()
        local text = grbl.format_dump({[100] = 80.0}, nil,
            { build = {"[VER:1.1h.20190825:]", "[OPT:V,15,128]"} })
        t.assert_true(text:find("# machine: %[VER") ~= nil)

        -- Comments and header lines must not come back as settings: the file
        -- is full of "$100=80" inside prose, and a sloppy parser would eat it
        local back, order = grbl.parse_dump(text)
        t.assert_eq(#order, 1, "parsed more than the one real setting")
        t.assert_eq(back[100], 80.0)
    end)

    t.it("round-trips startup blocks", function()
        local _, _, startup = grbl.parse_dump(grbl.format_dump({[100] = 80}, nil,
            { startup = {"$N0=G54 G90", "$N1="} }))
        t.assert_eq(#startup, 2)
        t.assert_eq(startup[1].index, 0)
        t.assert_eq(startup[1].code, "G54 G90")
        t.assert_eq(startup[2].code, "")
    end)

    t.it("tolerates a hand-edited file", function()
        local s = grbl.parse_dump([[
# a comment line
$100=81.5    # inline comment

   $101 = 79.25
]])
        t.assert_eq(s[100], 81.5)
        t.assert_eq(s[101], 79.25)
    end)

    t.it("sorts by setting number when no order is given", function()
        local text = grbl.format_dump({[101] = 1, [0] = 2, [100] = 3})
        local first = text:match("%$(%d+)=")
        t.assert_eq(first, "0")
    end)
end)

t.describe("diff", function()
    local current = {[100] = 80.0, [101] = 80.0, [110] = 5000.0}

    t.it("finds only what actually changed", function()
        local changes = grbl.diff(current, {[100] = 81.301, [101] = 80.0, [110] = 8000})
        t.assert_eq(#changes, 2)
        t.assert_eq(changes[1].n, 100)
        t.assert_eq(changes[1].from, 80.0)
        t.assert_near(changes[1].to, 81.301, 1e-12)
        t.assert_eq(changes[2].n, 110)
    end)

    t.it("finds nothing when they agree", function()
        t.assert_eq(#grbl.diff(current, current), 0)
    end)

    t.it("ignores differences below GRBL's own precision", function()
        -- GRBL reports three decimals; a value that round-tripped through the
        -- file must not show up as a pending change
        t.assert_eq(#grbl.diff(current, {[100] = 80.00001}), 0)
    end)

    t.it("reports settings the machine does not have rather than writing them", function()
        local changes, missing = grbl.diff(current, {[100] = 80.0, [999] = 1})
        t.assert_eq(#changes, 0)
        t.assert_eq(#missing, 1)
        t.assert_eq(missing[1], 999)
    end)

    t.it("is ordered by setting number", function()
        local changes = grbl.diff({[1] = 0, [100] = 0, [30] = 0},
                                  {[100] = 1, [1] = 1, [30] = 1})
        t.assert_eq(changes[1].n, 1)
        t.assert_eq(changes[2].n, 30)
        t.assert_eq(changes[3].n, 100)
    end)
end)

t.describe("change display", function()
    t.it("shows before, after and the setting's name", function()
        local text = grbl.format_changes({
            {n = 100, from = 80.0, to = 81.301},
        })
        t.assert_true(text:find("$100", 1, true) ~= nil)
        t.assert_true(text:find("80", 1, true) ~= nil)
        t.assert_true(text:find("81.301", 1, true) ~= nil)
        t.assert_true(text:find("X steps/mm", 1, true) ~= nil)
    end)
end)

t.describe("backup filenames", function()
    t.it("are timestamped so they never collide", function()
        local name = grbl.backup_filename("grbl-backup")
        t.assert_true(name:match("^grbl%-backup%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%.txt$") ~= nil,
            "unexpected filename: " .. name)
    end)
end)

t.describe("status reports", function()
    t.it("parses state and machine position", function()
        local st = grbl.parse_status("<Idle|MPos:1.500,2.250,0.000|FS:0,0|WCO:0.000,0.000,0.000>")
        t.assert_eq(st.state, "Idle")
        t.assert_near(st.mpos.x, 1.5, 1e-9)
        t.assert_near(st.mpos.y, 2.25, 1e-9)
    end)

    t.it("derives work position from the offset", function()
        local st = grbl.parse_status("<Idle|MPos:15.000,25.000,0.000|WCO:10.000,20.000,0.000>")
        t.assert_near(st.wpos.x, 5, 1e-9)
        t.assert_near(st.wpos.y, 5, 1e-9)
    end)

    t.it("remembers the offset across reports that omit it", function()
        -- GRBL sends WCO only about every tenth report; a reader that forgets
        -- it converts every report in between with a stale zero
        grbl.parse_status("<Idle|MPos:0.000,0.000,0.000|WCO:10.000,20.000,0.000>")
        local st = grbl.parse_status("<Run|MPos:45.500,60.250,0.000|FS:600,0>")
        t.assert_near(st.wpos.x, 35.5, 1e-9)
        t.assert_near(st.wpos.y, 40.25, 1e-9)
    end)

    t.it("handles the work-position flavour too", function()
        grbl.reset_wco()
        grbl.parse_status("<Idle|MPos:0.000,0.000,0.000|WCO:10.000,20.000,0.000>")
        local st = grbl.parse_status("<Idle|WPos:5.000,5.000,0.000>")
        t.assert_near(st.mpos.x, 15, 1e-9)
        t.assert_near(st.mpos.y, 25, 1e-9)
    end)

    t.it("reads sub-states like Hold:0", function()
        t.assert_eq(grbl.parse_status("<Hold:0|MPos:1.000,2.000,0.000>").state, "Hold:0")
        t.assert_eq(grbl.parse_status("<Alarm|MPos:1.000,2.000,0.000>").state, "Alarm")
    end)

    t.it("reads the feed rate when present", function()
        t.assert_eq(grbl.parse_status("<Run|MPos:0.000,0.000,0.000|FS:600,0>").feed, 600)
        t.assert_nil(grbl.parse_status("<Idle|MPos:0.000,0.000,0.000>").feed)
    end)

    t.it("reset_wco clears the cache", function()
        grbl.parse_status("<Idle|MPos:0.000,0.000,0.000|WCO:10.000,20.000,0.000>")
        grbl.reset_wco()
        local st = grbl.parse_status("<Idle|MPos:5.000,5.000,0.000>")
        t.assert_near(st.wpos.x, 5, 1e-9, "offset should have been forgotten")
    end)
end)

t.describe("guards against writing with no connection", function()
    t.it("grbl_settings and grbl_set refuse", function()
        t.assert_error(plotter.grbl_settings, "open serial connection")
        t.assert_error(function() plotter.grbl_set(100, 80) end, "open serial connection")
    end)

    t.it("home and unlock refuse", function()
        t.assert_error(plotter.home, "open serial connection")
        t.assert_error(plotter.unlock, "open serial connection")
    end)

    t.it("is_locked is false rather than an error when nothing is connected", function()
        -- It is a query, and a closed port is not an alarm state. Erroring
        -- here would make it useless as a guard in SVG-mode scripts.
        t.assert_false(plotter.is_locked())
    end)
end)
