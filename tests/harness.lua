--[[
    harness.lua — a very small test runner

    luaplot has no package manager, so tests run under the luaplot binary
    itself with no dependencies:

        make test          (or: ./luaplot tests/run.lua)

    Write tests as:

        local t = require 'harness'

        t.describe("thing", function()
            t.it("does something", function()
                t.assert_eq(2 + 2, 4)
            end)
        end)

    Every assertion failure is caught and reported with its group and case
    name; the run continues so one broken thing does not hide the rest.
    report() prints a summary and returns a process exit code.
--]]

local H = {}

local passes, failures = 0, 0
local current_group = "?"
local failed = {}

-- ── Structure ─────────────────────────────────────────────────────────────────

function H.describe(name, fn)
    local prev = current_group
    current_group = name
    fn()
    current_group = prev
end

function H.it(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passes = passes + 1
    else
        failures = failures + 1
        failed[#failed + 1] = {
            group = current_group,
            name  = name,
            err   = tostring(err),
        }
        io.write("F")
        io.flush()
        return
    end
    io.write(".")
    io.flush()
end

-- ── Assertions ────────────────────────────────────────────────────────────────

local function fail(msg)
    error(msg, 3)
end

local function show(v)
    if type(v) == "table" then
        local parts = {}
        for i, x in ipairs(v) do parts[i] = tostring(x) end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

function H.assert_eq(actual, expected, msg)
    if actual ~= expected then
        fail(string.format("%sexpected %s, got %s",
            msg and (msg .. ": ") or "", show(expected), show(actual)))
    end
end

function H.assert_ne(actual, unexpected, msg)
    if actual == unexpected then
        fail(string.format("%sexpected something other than %s",
            msg and (msg .. ": ") or "", show(unexpected)))
    end
end

--[[
    Floating-point comparison with an absolute tolerance (default 1e-9).

    Most of what this suite checks is geometry, where exact equality is the
    wrong question — 0.1 + 0.2 is not 0.3, and a rotated coordinate is never
    going to land on a round number.
--]]
function H.assert_near(actual, expected, tol, msg)
    tol = tol or 1e-9
    if type(actual) ~= "number" then
        fail(string.format("%sexpected a number, got %s (%s)",
            msg and (msg .. ": ") or "", type(actual), tostring(actual)))
    end
    if math.abs(actual - expected) > tol then
        fail(string.format("%sexpected %.10g +/- %g, got %.10g",
            msg and (msg .. ": ") or "", expected, tol, actual))
    end
end

function H.assert_true(v, msg)
    if not v then
        fail((msg and (msg .. ": ") or "") .. "expected truthy, got " .. tostring(v))
    end
end

function H.assert_false(v, msg)
    if v then
        fail((msg and (msg .. ": ") or "") .. "expected falsy, got " .. tostring(v))
    end
end

function H.assert_nil(v, msg)
    if v ~= nil then
        fail((msg and (msg .. ": ") or "") .. "expected nil, got " .. tostring(v))
    end
end

--[[
    assert_error(fn, pattern)

    Assert that fn raises, and optionally that the message matches a Lua
    pattern. Checking the message matters: a test that only asserts "it threw"
    passes just as happily on a typo in the test itself.
--]]
function H.assert_error(fn, pattern)
    local ok, err = pcall(fn)
    if ok then
        fail("expected an error, but the call succeeded")
    end
    if pattern and not tostring(err):match(pattern) then
        fail(string.format("expected error matching %q, got %q",
                           pattern, tostring(err)))
    end
    return err
end

-- Assert two points are equal within tolerance. Accepts vec2 or {x, y}.
function H.assert_point(actual, ex, ey, tol, msg)
    tol = tol or 1e-9
    local ax = actual[1] or actual.x
    local ay = actual[2] or actual.y
    H.assert_near(ax, ex, tol, (msg or "point") .. " x")
    H.assert_near(ay, ey, tol, (msg or "point") .. " y")
end

-- ── Reporting ─────────────────────────────────────────────────────────────────

function H.report()
    io.write("\n\n")

    for _, f in ipairs(failed) do
        io.write(string.format("FAIL  %s / %s\n      %s\n\n",
                               f.group, f.name, f.err))
    end

    io.write(string.format("%d passed, %d failed\n", passes, failures))
    return failures == 0 and 0 or 1
end

return H
