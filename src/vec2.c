/*
 * vec2.c — 2D vector primitive for luaplot, modelled on Processing's PVector
 *
 * A vec2 is a full userdata holding two doubles, with a metatable that gives
 * it operator overloading and method dispatch.  Making it a real userdata
 * rather than a Lua table is what lets it behave like a primitive: fixed size,
 * no rehashing, and arithmetic that reads like maths.
 *
 *     local v = vec2(3, 4)
 *     local w = v + vec2(1, 0) * 2
 *     v:mag()            --> 5.0
 *     tostring(w)        --> "vec2(5.000, 4.000)"
 *
 * ── Indexing ─────────────────────────────────────────────────────────────────
 *
 * __index resolves .x/.y AND [1]/[2] before falling back to the method table.
 * The [1]/[2] path is deliberate: plotter.lua's xform() reads points as
 * pt[1], pt[2], so vec2 values drop straight into polyline() point lists
 * alongside plain {x, y} tables, with no changes on the Lua side.
 *
 *     plotter.polyline({ vec2(0, 0), vec2(10, 10), {20, 0} })
 *
 * ── Mutability ───────────────────────────────────────────────────────────────
 *
 * Follows PVector exactly, because the surprise otherwise is worse than the
 * inconsistency:
 *
 *   instance methods   mutate the receiver and return self, for chaining
 *                        v:add(w):limit(10)      -- v is modified
 *   module functions   return a new vector, leaving the arguments alone
 *                        local u = vec2.add(v, w) -- v is untouched
 *   operators          always return a new vector
 *                        local u = v + w
 *
 * ── Angles ───────────────────────────────────────────────────────────────────
 *
 * Base methods use RADIANS, matching PVector and math.sin/math.cos.
 * Every angular function has a _deg twin (rotate_deg, heading_deg,
 * angle_between_deg, from_angle_deg) for the degree case — which is what
 * plotter.rotate() takes, so the two APIs do disagree here.  When in doubt:
 * plotter.* is degrees, vec2:* is radians unless it says _deg.
 *
 * ── Naming ───────────────────────────────────────────────────────────────────
 *
 * Primary names are snake_case to match the rest of this codebase
 * (text_width, get_strokes).  Where PVector uses camelCase, that name is
 * registered as an alias too (magSq, setMag, fromAngle, angleBetween,
 * random2D), so Processing snippets port over verbatim.
 */

#include "vec2.h"

#include <lauxlib.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define DEG2RAD (M_PI / 180.0)
#define RAD2DEG (180.0 / M_PI)

typedef struct {
    double x, y;
} Vec2;

/* ── Stack helpers ────────────────────────────────────────────────────────── */

void luaplot_vec2_push(lua_State *L, double x, double y) {
    Vec2 *v = (Vec2 *)lua_newuserdatauv(L, sizeof(Vec2), 0);
    v->x = x;
    v->y = y;
    luaL_getmetatable(L, LUAPLOT_VEC2_MT);
    lua_setmetatable(L, -2);
}

static Vec2 *check_vec2(lua_State *L, int idx) {
    return (Vec2 *)luaL_checkudata(L, idx, LUAPLOT_VEC2_MT);
}

static Vec2 *test_vec2(lua_State *L, int idx) {
    return (Vec2 *)luaL_testudata(L, idx, LUAPLOT_VEC2_MT);
}

/*
 * Read a vector-shaped value at idx into *out.
 *
 * Accepts a vec2, or a plain table in either of the two shapes this codebase
 * already uses for points: {x = 1, y = 2} and {1, 2}.  Tables are accepted
 * because plotter.lua's own point lists are {x, y} pairs, and requiring a
 * conversion at every boundary would make vec2 more annoying than useful.
 *
 * Returns 1 on success, 0 if the value is not vector-shaped.
 */
static int to_vec2(lua_State *L, int idx, Vec2 *out) {
    Vec2 *v = test_vec2(L, idx);
    if (v) {
        *out = *v;
        return 1;
    }

    if (lua_type(L, idx) != LUA_TTABLE)
        return 0;

    idx = lua_absindex(L, idx);

    /* {x = ..., y = ...} */
    lua_getfield(L, idx, "x");
    lua_getfield(L, idx, "y");
    if (lua_type(L, -2) == LUA_TNUMBER && lua_type(L, -1) == LUA_TNUMBER) {
        out->x = lua_tonumber(L, -2);
        out->y = lua_tonumber(L, -1);
        lua_pop(L, 2);
        return 1;
    }
    lua_pop(L, 2);

    /* {x, y} */
    lua_rawgeti(L, idx, 1);
    lua_rawgeti(L, idx, 2);
    if (lua_type(L, -2) == LUA_TNUMBER && lua_type(L, -1) == LUA_TNUMBER) {
        out->x = lua_tonumber(L, -2);
        out->y = lua_tonumber(L, -1);
        lua_pop(L, 2);
        return 1;
    }
    lua_pop(L, 2);

    return 0;
}

/* Like to_vec2 but raises a clear argument error rather than returning 0 */
static Vec2 arg_vec2(lua_State *L, int idx) {
    Vec2 v;
    if (!to_vec2(L, idx, &v))
        luaL_argerror(L, idx, lua_pushfstring(L,
            "expected vec2 or {x, y} table, got %s", luaL_typename(L, idx)));
    return v;
}

static int is_num(lua_State *L, int idx) {
    return lua_type(L, idx) == LUA_TNUMBER;
}

/* ── Constructors ─────────────────────────────────────────────────────────── */

/* vec2.new(x, y) — both default to 0, so vec2() is the origin */
static int vec2_new(lua_State *L) {
    luaplot_vec2_push(L, luaL_optnumber(L, 1, 0.0), luaL_optnumber(L, 2, 0.0));
    return 1;
}

/* Lets the module table itself be called: vec2(3, 4) */
static int vec2_call(lua_State *L) {
    /* arg 1 is the module table; shift it off and reuse new() */
    lua_remove(L, 1);
    return vec2_new(L);
}

/* vec2.from_angle(radians [, length]) */
static int vec2_from_angle(lua_State *L) {
    double a = luaL_checknumber(L, 1);
    double m = luaL_optnumber(L, 2, 1.0);
    luaplot_vec2_push(L, cos(a) * m, sin(a) * m);
    return 1;
}

/* vec2.from_angle_deg(degrees [, length]) */
static int vec2_from_angle_deg(lua_State *L) {
    double a = luaL_checknumber(L, 1) * DEG2RAD;
    double m = luaL_optnumber(L, 2, 1.0);
    luaplot_vec2_push(L, cos(a) * m, sin(a) * m);
    return 1;
}

/*
 * Draw from Lua's math.random rather than C rand().
 *
 * This is the whole point: a sketch seeded with math.randomseed(42) has to
 * reproduce exactly, and a private C PRNG would silently break that.
 */
static double lua_unit_random(lua_State *L) {
    lua_getglobal(L, "math");
    lua_getfield(L, -1, "random");
    lua_call(L, 0, 1);
    double r = lua_tonumber(L, -1);
    lua_pop(L, 2);              /* result, math */
    return r;
}

/* vec2.random2d([length]) — uniformly distributed direction */
static int vec2_random2d(lua_State *L) {
    double m = luaL_optnumber(L, 1, 1.0);
    double a = lua_unit_random(L) * 2.0 * M_PI;
    luaplot_vec2_push(L, cos(a) * m, sin(a) * m);
    return 1;
}

static int vec2_zero(lua_State *L) {
    luaplot_vec2_push(L, 0.0, 0.0);
    return 1;
}

static int vec2_is_vec2(lua_State *L) {
    lua_pushboolean(L, test_vec2(L, 1) != NULL);
    return 1;
}

/* ── Metamethods ──────────────────────────────────────────────────────────── */

static int vec2_index(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);

    if (lua_type(L, 2) == LUA_TNUMBER) {
        lua_Integer i = lua_tointeger(L, 2);
        if (i == 1) { lua_pushnumber(L, v->x); return 1; }
        if (i == 2) { lua_pushnumber(L, v->y); return 1; }
        lua_pushnil(L);
        return 1;
    }

    if (lua_type(L, 2) == LUA_TSTRING) {
        const char *k = lua_tostring(L, 2);
        if (strcmp(k, "x") == 0) { lua_pushnumber(L, v->x); return 1; }
        if (strcmp(k, "y") == 0) { lua_pushnumber(L, v->y); return 1; }
    }

    /* Not a component — look the key up in the method table, which lives in
     * the metatable under __methods (kept off __index so component access
     * stays a single C call rather than a table miss followed by a lookup). */
    luaL_getmetatable(L, LUAPLOT_VEC2_MT);
    lua_getfield(L, -1, "__methods");
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    return 1;
}

static int vec2_newindex(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);

    if (lua_type(L, 2) == LUA_TNUMBER) {
        lua_Integer i = lua_tointeger(L, 2);
        double val = luaL_checknumber(L, 3);
        if (i == 1) { v->x = val; return 0; }
        if (i == 2) { v->y = val; return 0; }
        return luaL_error(L, "vec2 index out of range: %I", (lua_Integer)i);
    }

    if (lua_type(L, 2) == LUA_TSTRING) {
        const char *k = lua_tostring(L, 2);
        double val = luaL_checknumber(L, 3);
        if (strcmp(k, "x") == 0) { v->x = val; return 0; }
        if (strcmp(k, "y") == 0) { v->y = val; return 0; }
        return luaL_error(L, "vec2 has no field '%s'", k);
    }

    return luaL_error(L, "invalid vec2 index (expected 'x', 'y', 1 or 2)");
}

static int vec2_add_op(lua_State *L) {
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    luaplot_vec2_push(L, a.x + b.x, a.y + b.y);
    return 1;
}

static int vec2_sub_op(lua_State *L) {
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    luaplot_vec2_push(L, a.x - b.x, a.y - b.y);
    return 1;
}

/*
 * v * s, s * v, and v * w (component-wise, as in p5.js).
 * Component-wise rather than dot product: a `*` that silently collapses two
 * vectors to a scalar is a nasty thing to debug. Use v:dot(w) for that.
 */
static int vec2_mul_op(lua_State *L) {
    if (is_num(L, 2)) {
        Vec2 a = arg_vec2(L, 1);
        double s = lua_tonumber(L, 2);
        luaplot_vec2_push(L, a.x * s, a.y * s);
        return 1;
    }
    if (is_num(L, 1)) {
        double s = lua_tonumber(L, 1);
        Vec2 b = arg_vec2(L, 2);
        luaplot_vec2_push(L, b.x * s, b.y * s);
        return 1;
    }
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    luaplot_vec2_push(L, a.x * b.x, a.y * b.y);
    return 1;
}

static int vec2_div_op(lua_State *L) {
    if (is_num(L, 2)) {
        Vec2 a = arg_vec2(L, 1);
        double s = lua_tonumber(L, 2);
        luaplot_vec2_push(L, a.x / s, a.y / s);
        return 1;
    }
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    luaplot_vec2_push(L, a.x / b.x, a.y / b.y);
    return 1;
}

static int vec2_unm_op(lua_State *L) {
    Vec2 *a = check_vec2(L, 1);
    luaplot_vec2_push(L, -a->x, -a->y);
    return 1;
}

static int vec2_eq_op(lua_State *L) {
    Vec2 *a = test_vec2(L, 1), *b = test_vec2(L, 2);
    lua_pushboolean(L, a && b && a->x == b->x && a->y == b->y);
    return 1;
}

/* #v — magnitude. Unusual for __len, but it reads well and there is no
 * meaningful "length in elements" for a fixed 2-component vector. */
static int vec2_len_op(lua_State *L) {
    Vec2 *a = check_vec2(L, 1);
    lua_pushnumber(L, sqrt(a->x * a->x + a->y * a->y));
    return 1;
}

static int vec2_tostring_op(lua_State *L) {
    Vec2 *a = check_vec2(L, 1);
    /* snprintf rather than lua_pushfstring: %f there means Lua's %.14g, which
     * would print "vec2(3, 4)". Three decimals matches how plotter.lua formats
     * coordinates everywhere else. */
    char buf[64];
    snprintf(buf, sizeof(buf), "vec2(%.3f, %.3f)", a->x, a->y);
    lua_pushstring(L, buf);
    return 1;
}

/* ── Mutating methods (return self, for chaining) ─────────────────────────── */

static int m_set(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    if (is_num(L, 2)) {
        v->x = lua_tonumber(L, 2);
        v->y = luaL_optnumber(L, 3, v->y);
    } else {
        Vec2 o = arg_vec2(L, 2);
        *v = o;
    }
    lua_pushvalue(L, 1);
    return 1;
}

static int m_add(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    /* v:add(w) or v:add(dx, dy) */
    if (is_num(L, 2)) {
        v->x += lua_tonumber(L, 2);
        v->y += luaL_checknumber(L, 3);
    } else {
        Vec2 o = arg_vec2(L, 2);
        v->x += o.x; v->y += o.y;
    }
    lua_pushvalue(L, 1);
    return 1;
}

static int m_sub(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    if (is_num(L, 2)) {
        v->x -= lua_tonumber(L, 2);
        v->y -= luaL_checknumber(L, 3);
    } else {
        Vec2 o = arg_vec2(L, 2);
        v->x -= o.x; v->y -= o.y;
    }
    lua_pushvalue(L, 1);
    return 1;
}

static int m_mult(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    if (is_num(L, 2)) {
        double s = lua_tonumber(L, 2);
        v->x *= s; v->y *= s;
    } else {
        Vec2 o = arg_vec2(L, 2);
        v->x *= o.x; v->y *= o.y;
    }
    lua_pushvalue(L, 1);
    return 1;
}

static int m_div(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    if (is_num(L, 2)) {
        double s = lua_tonumber(L, 2);
        v->x /= s; v->y /= s;
    } else {
        Vec2 o = arg_vec2(L, 2);
        v->x /= o.x; v->y /= o.y;
    }
    lua_pushvalue(L, 1);
    return 1;
}

/* Scale to unit length. A zero vector has no direction, so it is left alone
 * rather than turned into NaN. */
static int m_normalize(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    double m = sqrt(v->x * v->x + v->y * v->y);
    if (m > 0.0) { v->x /= m; v->y /= m; }
    lua_pushvalue(L, 1);
    return 1;
}

static int m_limit(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    double max = luaL_checknumber(L, 2);
    double m2  = v->x * v->x + v->y * v->y;
    if (m2 > max * max && m2 > 0.0) {
        double s = max / sqrt(m2);
        v->x *= s; v->y *= s;
    }
    lua_pushvalue(L, 1);
    return 1;
}

static int m_set_mag(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    double want = luaL_checknumber(L, 2);
    double m    = sqrt(v->x * v->x + v->y * v->y);
    if (m > 0.0) { v->x = v->x / m * want; v->y = v->y / m * want; }
    lua_pushvalue(L, 1);
    return 1;
}

/*
 * Rotate by an angle in radians.
 *
 * Positive angles turn counter-clockwise in standard maths orientation, which
 * on a Y-down plotter page reads as clockwise — the same handedness as
 * plotter.rotate().
 */
static int m_rotate(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    double a = luaL_checknumber(L, 2);
    double c = cos(a), s = sin(a);
    double nx = v->x * c - v->y * s;
    v->y = v->x * s + v->y * c;
    v->x = nx;
    lua_pushvalue(L, 1);
    return 1;
}

static int m_rotate_deg(lua_State *L) {
    lua_pushnumber(L, luaL_checknumber(L, 2) * DEG2RAD);
    lua_replace(L, 2);
    return m_rotate(L);
}

static int m_lerp(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    Vec2 o = arg_vec2(L, 2);
    double t = luaL_checknumber(L, 3);
    v->x += (o.x - v->x) * t;
    v->y += (o.y - v->y) * t;
    lua_pushvalue(L, 1);
    return 1;
}

/* ── Queries (never mutate) ───────────────────────────────────────────────── */

static int m_copy(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    luaplot_vec2_push(L, v->x, v->y);
    return 1;
}

static int m_mag(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    lua_pushnumber(L, sqrt(v->x * v->x + v->y * v->y));
    return 1;
}

static int m_mag_sq(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    lua_pushnumber(L, v->x * v->x + v->y * v->y);
    return 1;
}

static int m_dot(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    Vec2 o = arg_vec2(L, 2);
    lua_pushnumber(L, v->x * o.x + v->y * o.y);
    return 1;
}

/* 2D cross product — the z component of the 3D cross, a scalar.
 * Sign tells you which side of v the other vector is on. */
static int m_cross(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    Vec2 o = arg_vec2(L, 2);
    lua_pushnumber(L, v->x * o.y - v->y * o.x);
    return 1;
}

static int m_dist(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    Vec2 o = arg_vec2(L, 2);
    double dx = v->x - o.x, dy = v->y - o.y;
    lua_pushnumber(L, sqrt(dx * dx + dy * dy));
    return 1;
}

static int m_dist_sq(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    Vec2 o = arg_vec2(L, 2);
    double dx = v->x - o.x, dy = v->y - o.y;
    lua_pushnumber(L, dx * dx + dy * dy);
    return 1;
}

static int m_heading(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    lua_pushnumber(L, atan2(v->y, v->x));
    return 1;
}

static int m_heading_deg(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    lua_pushnumber(L, atan2(v->y, v->x) * RAD2DEG);
    return 1;
}

/*
 * Unsigned angle between two vectors, 0..pi.
 *
 * atan2(|cross|, dot) rather than the textbook acos(dot / (|a| |b|)).
 * acos is badly conditioned near its endpoints: for two nearly parallel
 * vectors the cosine rounds to something like 1 - 1e-16 and acos turns that
 * into an angle of ~1e-8 instead of ~0, an error eight orders of magnitude
 * larger than the input's. It can also round past 1 outright and return NaN.
 * The atan2 form has neither problem and needs no clamping.
 */
static double angle_between(Vec2 a, Vec2 b) {
    double cross = a.x * b.y - a.y * b.x;
    double dot   = a.x * b.x + a.y * b.y;

    if (cross == 0.0 && dot == 0.0) return 0.0;   /* one of them is zero */

    return atan2(fabs(cross), dot);
}

static int m_angle_between(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    Vec2 o = arg_vec2(L, 2);
    lua_pushnumber(L, angle_between(*v, o));
    return 1;
}

static int m_angle_between_deg(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    Vec2 o = arg_vec2(L, 2);
    lua_pushnumber(L, angle_between(*v, o) * RAD2DEG);
    return 1;
}

/* Non-mutating normalize — v:normalize() changes v, v:normalized() does not */
static int m_normalized(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    double m = sqrt(v->x * v->x + v->y * v->y);
    if (m > 0.0) luaplot_vec2_push(L, v->x / m, v->y / m);
    else         luaplot_vec2_push(L, 0.0, 0.0);
    return 1;
}

/* Rotated 90 degrees. Handy for offsetting a path sideways. */
static int m_perp(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    luaplot_vec2_push(L, -v->y, v->x);
    return 1;
}

static int m_unpack(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    lua_pushnumber(L, v->x);
    lua_pushnumber(L, v->y);
    return 2;
}

/* PVector.array() — a plain {x, y} table, for code that wants one */
static int m_array(lua_State *L) {
    Vec2 *v = check_vec2(L, 1);
    lua_createtable(L, 2, 0);
    lua_pushnumber(L, v->x); lua_rawseti(L, -2, 1);
    lua_pushnumber(L, v->y); lua_rawseti(L, -2, 2);
    return 1;
}

/* ── Module-level statics (return new vectors) ────────────────────────────── */

static int s_add(lua_State *L) {
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    luaplot_vec2_push(L, a.x + b.x, a.y + b.y);
    return 1;
}

static int s_sub(lua_State *L) {
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    luaplot_vec2_push(L, a.x - b.x, a.y - b.y);
    return 1;
}

static int s_mult(lua_State *L) {
    Vec2 a = arg_vec2(L, 1);
    if (is_num(L, 2)) {
        double s = lua_tonumber(L, 2);
        luaplot_vec2_push(L, a.x * s, a.y * s);
    } else {
        Vec2 b = arg_vec2(L, 2);
        luaplot_vec2_push(L, a.x * b.x, a.y * b.y);
    }
    return 1;
}

static int s_div(lua_State *L) {
    Vec2 a = arg_vec2(L, 1);
    if (is_num(L, 2)) {
        double s = lua_tonumber(L, 2);
        luaplot_vec2_push(L, a.x / s, a.y / s);
    } else {
        Vec2 b = arg_vec2(L, 2);
        luaplot_vec2_push(L, a.x / b.x, a.y / b.y);
    }
    return 1;
}

static int s_dist(lua_State *L) {
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    double dx = a.x - b.x, dy = a.y - b.y;
    lua_pushnumber(L, sqrt(dx * dx + dy * dy));
    return 1;
}

static int s_dot(lua_State *L) {
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    lua_pushnumber(L, a.x * b.x + a.y * b.y);
    return 1;
}

static int s_cross(lua_State *L) {
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    lua_pushnumber(L, a.x * b.y - a.y * b.x);
    return 1;
}

static int s_lerp(lua_State *L) {
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    double t = luaL_checknumber(L, 3);
    luaplot_vec2_push(L, a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
    return 1;
}

static int s_angle_between(lua_State *L) {
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    lua_pushnumber(L, angle_between(a, b));
    return 1;
}

static int s_angle_between_deg(lua_State *L) {
    Vec2 a = arg_vec2(L, 1), b = arg_vec2(L, 2);
    lua_pushnumber(L, angle_between(a, b) * RAD2DEG);
    return 1;
}

/* ── Registration ─────────────────────────────────────────────────────────── */

static const luaL_Reg vec2_methods[] = {
    /* mutating */
    {"set",         m_set},
    {"add",         m_add},
    {"sub",         m_sub},
    {"mult",        m_mult},
    {"div",         m_div},
    {"normalize",   m_normalize},
    {"limit",       m_limit},
    {"set_mag",     m_set_mag},
    {"rotate",      m_rotate},
    {"rotate_deg",  m_rotate_deg},
    {"lerp",        m_lerp},

    /* queries */
    {"copy",              m_copy},
    {"mag",               m_mag},
    {"mag_sq",            m_mag_sq},
    {"dot",               m_dot},
    {"cross",             m_cross},
    {"dist",              m_dist},
    {"dist_sq",           m_dist_sq},
    {"heading",           m_heading},
    {"heading_deg",       m_heading_deg},
    {"angle_between",     m_angle_between},
    {"angle_between_deg", m_angle_between_deg},
    {"normalized",        m_normalized},
    {"perp",              m_perp},
    {"unpack",            m_unpack},
    {"array",             m_array},

    /* PVector camelCase aliases, so Processing code ports unchanged */
    {"setMag",            m_set_mag},
    {"magSq",             m_mag_sq},
    {"distSq",            m_dist_sq},
    {"angleBetween",      m_angle_between},
    {"rotateDeg",         m_rotate_deg},
    {"headingDeg",        m_heading_deg},

    {NULL, NULL}
};

static const luaL_Reg vec2_module[] = {
    {"new",               vec2_new},
    {"from_angle",        vec2_from_angle},
    {"from_angle_deg",    vec2_from_angle_deg},
    {"random2d",          vec2_random2d},
    {"zero",              vec2_zero},
    {"is_vec2",           vec2_is_vec2},

    {"add",               s_add},
    {"sub",               s_sub},
    {"mult",              s_mult},
    {"div",               s_div},
    {"dist",              s_dist},
    {"dot",               s_dot},
    {"cross",             s_cross},
    {"lerp",              s_lerp},
    {"angle_between",     s_angle_between},
    {"angle_between_deg", s_angle_between_deg},

    /* camelCase aliases */
    {"fromAngle",         vec2_from_angle},
    {"random2D",          vec2_random2d},
    {"angleBetween",      s_angle_between},
    {"isVec2",            vec2_is_vec2},

    {NULL, NULL}
};

static const luaL_Reg vec2_metamethods[] = {
    {"__index",    vec2_index},
    {"__newindex", vec2_newindex},
    {"__add",      vec2_add_op},
    {"__sub",      vec2_sub_op},
    {"__mul",      vec2_mul_op},
    {"__div",      vec2_div_op},
    {"__unm",      vec2_unm_op},
    {"__eq",       vec2_eq_op},
    {"__len",      vec2_len_op},
    {"__tostring", vec2_tostring_op},
    {NULL, NULL}
};

int luaopen_vec2(lua_State *L) {
    /* The metatable, keyed in the registry so check_vec2 can find it */
    luaL_newmetatable(L, LUAPLOT_VEC2_MT);
    luaL_setfuncs(L, vec2_metamethods, 0);

    /* Methods hang off the metatable under __methods; vec2_index consults it
     * only after ruling out .x/.y/[1]/[2]. */
    luaL_newlib(L, vec2_methods);
    lua_setfield(L, -2, "__methods");

    /* Don't let scripts reach in and rewrite the metatable by accident */
    lua_pushliteral(L, "vec2");
    lua_setfield(L, -2, "__name");

    lua_pop(L, 1);              /* done with the metatable */

    /* The module table, made callable so vec2(3, 4) works */
    luaL_newlib(L, vec2_module);

    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, vec2_call);
    lua_setfield(L, -2, "__call");
    lua_setmetatable(L, -2);

    return 1;
}
