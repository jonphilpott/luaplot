local t = require 'harness'

t.describe("vec2 construction", function()
    t.it("vec2(x, y) builds from the callable module", function()
        local v = vec2(3, 4)
        t.assert_eq(v.x, 3); t.assert_eq(v.y, 4)
    end)

    t.it("vec2.new is equivalent", function()
        t.assert_true(vec2.new(3, 4) == vec2(3, 4))
    end)

    t.it("defaults to the origin", function()
        t.assert_point(vec2(), 0, 0)
        t.assert_point(vec2(5), 5, 0)
    end)

    t.it("from_angle and from_angle_deg agree", function()
        t.assert_point(vec2.from_angle(math.pi / 2), 0, 1, 1e-12)
        t.assert_point(vec2.from_angle_deg(90), 0, 1, 1e-12)
        t.assert_point(vec2.from_angle_deg(0, 5), 5, 0, 1e-12)
    end)

    t.it("is_vec2 tells vectors from tables", function()
        t.assert_true(vec2.is_vec2(vec2(1, 2)))
        t.assert_false(vec2.is_vec2({1, 2}))
        t.assert_false(vec2.is_vec2(nil))
    end)

    t.it("random2d is reproducible under math.randomseed", function()
        math.randomseed(99); local a = vec2.random2d()
        math.randomseed(99); local b = vec2.random2d()
        t.assert_true(a == b, "same seed should give the same direction")
        t.assert_near(a:mag(), 1, 1e-12)
        t.assert_near(vec2.random2d(4):mag(), 4, 1e-12)
    end)
end)

t.describe("vec2 indexing", function()
    t.it("exposes .x/.y and [1]/[2] as the same storage", function()
        local v = vec2(3, 4)
        t.assert_eq(v[1], 3); t.assert_eq(v[2], 4)
        v[1] = 7
        t.assert_eq(v.x, 7)
        v.y = 9
        t.assert_eq(v[2], 9)
    end)

    t.it("returns nil for out-of-range numeric keys", function()
        t.assert_nil(vec2(1, 2)[3])
    end)

    t.it("rejects unknown fields on write", function()
        t.assert_error(function() vec2(1, 2).z = 5 end, "no field 'z'")
        t.assert_error(function() vec2(1, 2)[3] = 5 end, "out of range")
    end)

    t.it("drops into a plotter point list unchanged", function()
        -- The whole reason [1]/[2] exist: plotter reads points this way
        local pts = { vec2(0, 0), {5, 5}, vec2(10, 0) }
        local sum = 0
        for _, p in ipairs(pts) do sum = sum + p[1] + p[2] end
        t.assert_eq(sum, 20)
    end)
end)

t.describe("vec2 operators", function()
    local v, w = vec2(3, 4), vec2(1, 2)

    t.it("adds and subtracts", function()
        t.assert_point(v + w, 4, 6)
        t.assert_point(v - w, 2, 2)
    end)

    t.it("multiplies by a scalar from either side", function()
        t.assert_point(v * 2, 6, 8)
        t.assert_point(2 * v, 6, 8)
    end)

    t.it("multiplies and divides component-wise", function()
        t.assert_point(v * w, 3, 8)
        t.assert_point(v / w, 3, 2)
        t.assert_point(v / 2, 1.5, 2)
    end)

    t.it("negates", function() t.assert_point(-v, -3, -4) end)

    t.it("compares by value", function()
        t.assert_true(vec2(3, 4) == vec2(3, 4))
        t.assert_false(vec2(3, 4) == vec2(3, 5))
    end)

    t.it("# gives the magnitude", function() t.assert_eq(#v, 5) end)

    t.it("tostring is readable", function()
        t.assert_eq(tostring(vec2(3, 4)), "vec2(3.000, 4.000)")
    end)

    t.it("accepts point-shaped tables as the other operand", function()
        t.assert_point(v + {1, 1}, 4, 5)
        t.assert_point(v + {x = 1, y = 1}, 4, 5)
    end)

    t.it("rejects operands that are not point-shaped", function()
        t.assert_error(function() return v + "nope" end, "expected vec2")
        t.assert_error(function() return v + {1} end, "expected vec2")
    end)

    t.it("leaves its operands alone", function()
        local a = vec2(3, 4)
        local _ = a + vec2(1, 1)
        t.assert_point(a, 3, 4)
    end)
end)

t.describe("vec2 mutating methods", function()
    t.it("mutate the receiver and return it for chaining", function()
        local v = vec2(3, 4)
        local r = v:add(vec2(1, 1))
        t.assert_true(rawequal(r, v), "should return the same object")
        t.assert_point(v, 4, 5)
    end)

    t.it("add/sub accept two numbers as well as a vector", function()
        t.assert_point(vec2(1, 1):add(2, 3), 3, 4)
        t.assert_point(vec2(5, 5):sub(2, 3), 3, 2)
    end)

    t.it("normalize scales to unit length", function()
        t.assert_near(vec2(3, 4):normalize():mag(), 1, 1e-12)
    end)

    t.it("normalize leaves a zero vector alone rather than making NaN", function()
        t.assert_point(vec2(0, 0):normalize(), 0, 0)
    end)

    t.it("limit only shortens", function()
        t.assert_near(vec2(3, 4):limit(2):mag(), 2, 1e-12)
        t.assert_near(vec2(3, 4):limit(10):mag(), 5, 1e-12)
    end)

    t.it("set_mag rescales", function()
        t.assert_near(vec2(3, 4):set_mag(10):mag(), 10, 1e-12)
    end)

    t.it("rotate uses radians, rotate_deg degrees", function()
        t.assert_point(vec2(1, 0):rotate(math.pi / 2), 0, 1, 1e-12)
        t.assert_point(vec2(1, 0):rotate_deg(90), 0, 1, 1e-12)
    end)

    t.it("a full turn comes back to where it started", function()
        t.assert_point(vec2(2, 3):rotate_deg(360), 2, 3, 1e-9)
    end)

    t.it("lerp moves toward the target", function()
        t.assert_point(vec2(0, 0):lerp(vec2(10, 20), 0.5), 5, 10)
    end)

    t.it("set replaces both components", function()
        t.assert_point(vec2(1, 1):set(7, 8), 7, 8)
        t.assert_point(vec2(1, 1):set(vec2(7, 8)), 7, 8)
    end)
end)

t.describe("vec2 queries", function()
    local v = vec2(3, 4)

    t.it("mag and mag_sq", function()
        t.assert_eq(v:mag(), 5); t.assert_eq(v:mag_sq(), 25)
    end)

    t.it("dot and cross", function()
        t.assert_eq(vec2(1, 0):dot(vec2(0, 1)), 0)
        t.assert_eq(vec2(1, 0):cross(vec2(0, 1)), 1)
        t.assert_eq(vec2(0, 1):cross(vec2(1, 0)), -1)
    end)

    t.it("dist and dist_sq", function()
        t.assert_eq(vec2(0, 0):dist(vec2(3, 4)), 5)
        t.assert_eq(vec2(0, 0):dist_sq(vec2(3, 4)), 25)
    end)

    t.it("heading in both units", function()
        t.assert_near(vec2(0, 1):heading(), math.pi / 2, 1e-12)
        t.assert_near(vec2(0, 1):heading_deg(), 90, 1e-12)
    end)

    t.it("angle_between is unsigned and clamped", function()
        t.assert_near(vec2(1, 0):angle_between_deg(vec2(0, 1)), 90, 1e-9)
        t.assert_near(vec2(1, 0):angle_between_deg(vec2(-1, 0)), 180, 1e-9)
        -- Identical vectors must not produce NaN from acos(1 + epsilon)
        t.assert_near(vec2(1, 1):angle_between(vec2(1, 1)), 0, 1e-9)
        t.assert_eq(vec2(0, 0):angle_between(vec2(1, 0)), 0)
    end)

    t.it("copy is independent", function()
        local a = vec2(1, 2)
        local b = a:copy()
        b:add(vec2(5, 5))
        t.assert_point(a, 1, 2)
    end)

    t.it("normalized and perp do not mutate", function()
        local a = vec2(3, 4)
        t.assert_near(a:normalized():mag(), 1, 1e-12)
        t.assert_point(a:perp(), -4, 3)
        t.assert_point(a, 3, 4)
    end)

    t.it("unpack and array", function()
        local x, y = v:unpack()
        t.assert_eq(x, 3); t.assert_eq(y, 4)
        t.assert_point(v:array(), 3, 4)
    end)
end)

t.describe("vec2 statics", function()
    t.it("return new vectors and leave arguments alone", function()
        local a, b = vec2(3, 4), vec2(1, 1)
        t.assert_point(vec2.add(a, b), 4, 5)
        t.assert_point(a, 3, 4, nil, "argument")
        t.assert_point(vec2.sub(a, b), 2, 3)
        t.assert_point(vec2.mult(a, 2), 6, 8)
        t.assert_point(vec2.div(a, 2), 1.5, 2)
        t.assert_point(vec2.lerp(vec2(0, 0), vec2(10, 10), 0.25), 2.5, 2.5)
    end)

    t.it("scalar statics", function()
        t.assert_eq(vec2.dist(vec2(0, 0), vec2(3, 4)), 5)
        t.assert_eq(vec2.dot(vec2(1, 2), vec2(3, 4)), 11)
        t.assert_eq(vec2.cross(vec2(1, 0), vec2(0, 1)), 1)
    end)
end)

t.describe("vec2 PVector aliases", function()
    t.it("camelCase methods match their snake_case originals", function()
        local v = vec2(3, 4)
        t.assert_eq(v:magSq(), v:mag_sq())
        t.assert_eq(v:distSq(vec2(0, 0)), v:dist_sq(vec2(0, 0)))
        t.assert_near(v:copy():setMag(2):mag(), 2, 1e-12)
        t.assert_eq(v:angleBetween(vec2(0, 1)), v:angle_between(vec2(0, 1)))
    end)

    t.it("camelCase module functions exist", function()
        t.assert_true(vec2.fromAngle(0) == vec2.from_angle(0))
        t.assert_true(vec2.isVec2(vec2(1, 1)))
        t.assert_eq(type(vec2.random2D), "function")
    end)
end)

t.describe("vec2 module access", function()
    t.it("is available as a global and through require", function()
        t.assert_eq(require 'vec2', vec2, "require should give the same table")
    end)
end)
