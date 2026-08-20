-- luacheck configuration for luaplot
--
--   luacheck lua tests tools examples      (or: make lint)
--
-- luacheck is optional -- nothing in the build or the test suite needs it.

std = "lua54"

-- vec2 and noise are C modules that main.c installs as globals, so scripts can
-- treat them as language primitives. They are read-only from Lua.
read_globals = {
    "vec2",
    "noise",
}

-- Scripts run under the luaplot binary, which populates `arg` the same way the
-- standard interpreter does.
globals = {
    "arg",
}

-- Long lines are usually a table of coordinate data, where wrapping hurts
-- more than it helps.
max_line_length = 100

files["lua/hershey.lua"] = {
    -- The glyph table is machine-generated coordinate data on very long lines
    max_line_length = false,
}

files["tests/"] = {
    -- Tests deliberately shadow `t` and discard results
    ignore = {"212"},   -- unused argument
}
