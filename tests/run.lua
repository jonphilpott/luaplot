--[[
    tests/run.lua — entry point for the test suite

        make test
        ./luaplot tests/run.lua
        ./luaplot tests/run.lua vec2 noise      -- only matching files

    Exits non-zero if anything failed, so CI and `make test` notice.
--]]

-- Find our own directory from arg[0] so the suite runs from any working
-- directory, not just the repo root.
local dir = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
package.path = dir .. "/?.lua;" .. package.path

local t = require 'harness'

local SUITES = {
    "test_vec2",
    "test_noise",
    "test_util",
    "test_transform",
    "test_primitives",
    "test_geometry",
    "test_hatch",
    "test_optimize",
    "test_paint",
    "test_hershey",
    "test_grbl",
}

-- Optional filters: any suite whose name contains one of the given words
local filters = {}
for i = 1, #arg do filters[#filters + 1] = arg[i]:lower() end

local function wanted(name)
    if #filters == 0 then return true end
    for _, f in ipairs(filters) do
        if name:lower():find(f, 1, true) then return true end
    end
    return false
end

local ran = 0
for _, suite in ipairs(SUITES) do
    if wanted(suite) then
        require(suite)
        ran = ran + 1
    end
end

if ran == 0 then
    io.write("no suites matched\n")
    os.exit(1)
end

os.exit(t.report())
