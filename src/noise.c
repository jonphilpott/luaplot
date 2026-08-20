/*
 * noise.c — coherent noise for luaplot
 *
 * Perlin noise, fractal (octave) variants, and Worley/cellular noise.
 *
 * Why C: noise is almost always evaluated across a grid — one call per cell
 * per octave — so it sits in the hottest loop a generative sketch has.
 * examples/mandelbrot.lua already shows how slow that gets in plain Lua.
 *
 *     noise.seed(42)
 *     noise.perlin(x, y)                          --> -1 .. 1
 *     noise.fbm(x, y, { octaves = 5, gain = 0.55 })
 *     local f1, f2, id = noise.worley(x, y)
 *
 * ── Output ranges ────────────────────────────────────────────────────────────
 *
 *   perlin, fbm            -1 .. 1
 *   ridged, turbulence      0 .. 1
 *   noise (Processing)      0 .. 1
 *   worley                  f1, f2 are distances >= 0 (typically 0 .. 1.5)
 *
 * The signed functions are clamped to their stated range, so you can map()
 * them without defensive checks.
 *
 * ── Determinism ──────────────────────────────────────────────────────────────
 *
 * The permutation table is built from noise.seed(n) using a private PRNG, so
 * the same seed gives the same field on every machine and every run. It is
 * deliberately independent of math.randomseed: you usually want to re-roll a
 * sketch's random scatter while holding its noise field fixed, or the reverse.
 * The default seed is 0, so output is reproducible even if you never call
 * seed().
 *
 * ── Processing compatibility ─────────────────────────────────────────────────
 *
 * noise.noise() / noise_detail() / noise_seed() mirror Processing's interface,
 * parameter meanings and 0..1 output range, so sketches port without rescaling.
 * They are NOT bit-identical to Processing, which uses value noise rather than
 * Perlin — the character of the field is the same, the exact numbers are not.
 */

#include "noise.h"

#include <lauxlib.h>

#include <math.h>
#include <stdint.h>
#include <string.h>

/* ── Permutation table ────────────────────────────────────────────────────── */

/* Doubled to 512 so index arithmetic never needs a modulo */
static unsigned char perm[512];

/*
 * SplitMix64 — a tiny, well-distributed PRNG used only to shuffle the
 * permutation table. Self-contained so seeding never depends on the C library
 * or Lua's RNG state.
 */
static uint64_t sm_state;

static uint64_t splitmix64(void) {
    uint64_t z = (sm_state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

static void noise_reseed(uint64_t seed) {
    sm_state = seed;

    for (int i = 0; i < 256; i++)
        perm[i] = (unsigned char)i;

    /* Fisher-Yates */
    for (int i = 255; i > 0; i--) {
        int j = (int)(splitmix64() % (uint64_t)(i + 1));
        unsigned char t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
    }

    memcpy(perm + 256, perm, 256);
}

/* ── Perlin ───────────────────────────────────────────────────────────────── */

/* Perlin's 2002 quintic fade — first and second derivatives vanish at the
 * lattice points, which is what removes the visible grid creasing that the
 * original cubic fade produced. */
static double fade(double t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

static double lerpd(double a, double b, double t) {
    return a + (b - a) * t;
}

/* Eight evenly spaced unit gradients. Equal length matters: mixing unit and
 * diagonal-length vectors biases the field toward the diagonals. */
static const double GRAD2[8][2] = {
    { 1.0,  0.0}, {-1.0,  0.0}, { 0.0,  1.0}, { 0.0, -1.0},
    { 0.70710678118654752, 0.70710678118654752},
    {-0.70710678118654752, 0.70710678118654752},
    { 0.70710678118654752,-0.70710678118654752},
    {-0.70710678118654752,-0.70710678118654752},
};

static double grad2(int hash, double x, double y) {
    const double *g = GRAD2[hash & 7];
    return g[0] * x + g[1] * y;
}

/* Perlin's 12 cube-edge gradients, plus 4 repeats to fill the 16-way hash */
static double grad3(int hash, double x, double y, double z) {
    int h = hash & 15;
    double u = h < 8 ? x : y;
    double v = h < 4 ? y : (h == 12 || h == 14 ? x : z);
    return ((h & 1) ? -u : u) + ((h & 2) ? -v : v);
}

static double clamp1(double v) {
    if (v >  1.0) return  1.0;
    if (v < -1.0) return -1.0;
    return v;
}

/*
 * Scale factors bringing each dimension's raw output up to a full [-1, 1].
 * Perlin's theoretical bound is sqrt(N)/2 with unit gradients, so the raw
 * field only ever uses part of the range; without this, 2D noise would top out
 * around +/-0.707 and every sketch would have to rescale by hand.
 */
#define PERLIN2_SCALE 1.41421356237309505
#define PERLIN3_SCALE 1.15470053837925153

static double perlin2(double x, double y) {
    int X = (int)floor(x) & 255;
    int Y = (int)floor(y) & 255;
    x -= floor(x);
    y -= floor(y);

    double u = fade(x), v = fade(y);

    int A = perm[X] + Y, B = perm[X + 1] + Y;

    double res = lerpd(
        lerpd(grad2(perm[A],     x,       y),
              grad2(perm[B],     x - 1.0, y),       u),
        lerpd(grad2(perm[A + 1], x,       y - 1.0),
              grad2(perm[B + 1], x - 1.0, y - 1.0), u),
        v);

    return clamp1(res * PERLIN2_SCALE);
}

static double perlin3(double x, double y, double z) {
    int X = (int)floor(x) & 255;
    int Y = (int)floor(y) & 255;
    int Z = (int)floor(z) & 255;
    x -= floor(x);
    y -= floor(y);
    z -= floor(z);

    double u = fade(x), v = fade(y), w = fade(z);

    int A  = perm[X]     + Y, AA = perm[A] + Z, AB = perm[A + 1] + Z;
    int B  = perm[X + 1] + Y, BA = perm[B] + Z, BB = perm[B + 1] + Z;

    double res = lerpd(
        lerpd(lerpd(grad3(perm[AA],     x,       y,       z),
                    grad3(perm[BA],     x - 1.0, y,       z),       u),
              lerpd(grad3(perm[AB],     x,       y - 1.0, z),
                    grad3(perm[BB],     x - 1.0, y - 1.0, z),       u), v),
        lerpd(lerpd(grad3(perm[AA + 1], x,       y,       z - 1.0),
                    grad3(perm[BA + 1], x - 1.0, y,       z - 1.0), u),
              lerpd(grad3(perm[AB + 1], x,       y - 1.0, z - 1.0),
                    grad3(perm[BB + 1], x - 1.0, y - 1.0, z - 1.0), u), v),
        w);

    return clamp1(res * PERLIN3_SCALE);
}

/*
 * 1D noise is a horizontal slice through the 2D field rather than a true 1D
 * Perlin.
 *
 * True 1D Perlin has only two possible unit gradients (+1 and -1), so whenever
 * two adjacent lattice points draw the same one the midpoint between them
 * evaluates to exactly zero — which happens for half of all x.5 coordinates
 * and shows up as a periodic flat spot. Slicing 2D noise costs one extra
 * interpolation and has no such artifact. The offset is an arbitrary
 * irrational so the slice never lines up with the lattice.
 */
#define PERLIN1_SLICE 0.31830988618379067   /* 1/pi */

static double perlin1(double x) {
    return perlin2(x, PERLIN1_SLICE);
}

static double perlin_nd(int dims, const double c[3]) {
    if (dims <= 1) return perlin1(c[0]);
    if (dims == 2) return perlin2(c[0], c[1]);
    return perlin3(c[0], c[1], c[2]);
}

/* ── Argument parsing ─────────────────────────────────────────────────────── */

/*
 * Read 1-3 leading numeric coordinates, then note whether a table of options
 * follows. Lets every entry point share one signature shape:
 *
 *     f(x)  f(x, y)  f(x, y, z)  and each with a trailing opts table
 */
static int read_coords(lua_State *L, double c[3], int *opts_idx) {
    int n = 0;
    c[0] = c[1] = c[2] = 0.0;

    while (n < 3 && lua_type(L, n + 1) == LUA_TNUMBER) {
        c[n] = lua_tonumber(L, n + 1);
        n++;
    }

    if (n == 0)
        luaL_argerror(L, 1, "expected at least one coordinate");

    *opts_idx = (lua_type(L, n + 1) == LUA_TTABLE) ? n + 1 : 0;
    return n;
}

static double opt_field(lua_State *L, int idx, const char *key, double dflt) {
    if (idx == 0) return dflt;

    lua_getfield(L, idx, key);
    double v = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : dflt;
    lua_pop(L, 1);
    return v;
}

static const char *opt_string(lua_State *L, int idx, const char *key,
                              const char *dflt) {
    if (idx == 0) return dflt;

    lua_getfield(L, idx, key);
    const char *v = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : dflt;
    lua_pop(L, 1);      /* safe: the string is still referenced by the table */
    return v;
}

/* ── Fractal variants ─────────────────────────────────────────────────────── */

typedef struct {
    int    octaves;
    double lacunarity;      /* frequency multiplier per octave */
    double gain;            /* amplitude multiplier per octave */
} FractalOpts;

static FractalOpts read_fractal_opts(lua_State *L, int idx) {
    FractalOpts o;
    o.octaves    = (int)opt_field(L, idx, "octaves", 4);
    o.lacunarity =      opt_field(L, idx, "lacunarity", 2.0);
    o.gain       =      opt_field(L, idx, "gain", 0.5);

    if (o.octaves < 1)  o.octaves = 1;
    if (o.octaves > 16) o.octaves = 16;   /* beyond this the terms are noise
                                           * below floating-point relevance */
    return o;
}

/*
 * Fractional Brownian motion: sum octaves of Perlin at rising frequency and
 * falling amplitude, then divide by the total amplitude so the result keeps
 * the [-1, 1] range regardless of octave count.
 */
static double fbm_nd(int dims, const double c[3], FractalOpts o) {
    double sum = 0.0, amp = 1.0, total = 0.0, freq = 1.0;
    double p[3];

    for (int i = 0; i < o.octaves; i++) {
        p[0] = c[0] * freq; p[1] = c[1] * freq; p[2] = c[2] * freq;
        sum   += perlin_nd(dims, p) * amp;
        total += amp;
        amp   *= o.gain;
        freq  *= o.lacunarity;
    }

    return total > 0.0 ? clamp1(sum / total) : 0.0;
}

/* Absolute value of each octave — creases the field into billowy ridges. 0..1 */
static double turbulence_nd(int dims, const double c[3], FractalOpts o) {
    double sum = 0.0, amp = 1.0, total = 0.0, freq = 1.0;
    double p[3];

    for (int i = 0; i < o.octaves; i++) {
        p[0] = c[0] * freq; p[1] = c[1] * freq; p[2] = c[2] * freq;
        sum   += fabs(perlin_nd(dims, p)) * amp;
        total += amp;
        amp   *= o.gain;
        freq  *= o.lacunarity;
    }

    double v = total > 0.0 ? sum / total : 0.0;
    return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
}

/*
 * Ridged multifractal: invert the turbulence creases so they become sharp
 * crests, and square to sharpen them further. Gives the eroded-mountain look
 * that plots well as contour lines. 0..1
 */
static double ridged_nd(int dims, const double c[3], FractalOpts o) {
    double sum = 0.0, amp = 1.0, total = 0.0, freq = 1.0;
    double p[3];

    for (int i = 0; i < o.octaves; i++) {
        p[0] = c[0] * freq; p[1] = c[1] * freq; p[2] = c[2] * freq;
        double n = 1.0 - fabs(perlin_nd(dims, p));
        sum   += n * n * amp;
        total += amp;
        amp   *= o.gain;
        freq  *= o.lacunarity;
    }

    double v = total > 0.0 ? sum / total : 0.0;
    return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
}

/* ── Worley / cellular ────────────────────────────────────────────────────── */

enum { DIST_EUCLIDEAN, DIST_MANHATTAN, DIST_CHEBYSHEV };

/* Hash a lattice cell to a stable pseudo-random 32-bit value */
static uint32_t cell_hash(int i, int j, int k) {
    uint32_t h = 2166136261u;
    h = (h ^ (uint32_t)(i * 73856093))  * 16777619u;
    h = (h ^ (uint32_t)(j * 19349663))  * 16777619u;
    h = (h ^ (uint32_t)(k * 83492791))  * 16777619u;
    h ^= h >> 15;
    return h;
}

/* Two independent 0..1 values from one cell hash, for the feature point offset */
static void cell_offset(uint32_t h, double jitter, double *ox, double *oy) {
    *ox = 0.5 + ((double)(h & 0xFFFF) / 65535.0 - 0.5) * jitter;
    *oy = 0.5 + ((double)((h >> 16) & 0xFFFF) / 65535.0 - 0.5) * jitter;
}

static double metric(int m, double dx, double dy, double dz) {
    switch (m) {
        case DIST_MANHATTAN:
            return fabs(dx) + fabs(dy) + fabs(dz);
        case DIST_CHEBYSHEV: {
            double a = fabs(dx), b = fabs(dy), c = fabs(dz);
            if (b > a) a = b;
            if (c > a) a = c;
            return a;
        }
        default:
            return sqrt(dx * dx + dy * dy + dz * dz);
    }
}

/*
 * Scatter one feature point per lattice cell and report the distance to the
 * nearest (f1) and second-nearest (f2), plus an id for the winning cell.
 *
 * Searching the 3x3 (or 3x3x3) neighbourhood is enough because a feature point
 * is confined to its own cell, so nothing outside that ring can beat a
 * candidate already found inside it.
 */
static void worley(int dims, const double c[3], double jitter, int m,
                   double *f1, double *f2, uint32_t *id) {
    int bx = (int)floor(c[0]);
    int by = dims >= 2 ? (int)floor(c[1]) : 0;
    int bz = dims >= 3 ? (int)floor(c[2]) : 0;

    int jlo = dims >= 2 ? -1 : 0, jhi = dims >= 2 ? 1 : 0;
    int klo = dims >= 3 ? -1 : 0, khi = dims >= 3 ? 1 : 0;

    *f1 = *f2 = 1e30;
    *id = 0;

    for (int k = klo; k <= khi; k++) {
        for (int j = jlo; j <= jhi; j++) {
            for (int i = -1; i <= 1; i++) {
                int cx = bx + i, cy = by + j, cz = bz + k;

                uint32_t h = cell_hash(cx, cy, cz);
                double ox, oy;
                cell_offset(h, jitter, &ox, &oy);

                /* Third axis reuses a rehash so the offset stays independent */
                double oz = 0.5;
                if (dims >= 3) {
                    uint32_t h2 = cell_hash(cz, cx, cy);
                    oz = 0.5 + ((double)(h2 & 0xFFFF) / 65535.0 - 0.5) * jitter;
                }

                double dx = (double)cx + ox - c[0];
                double dy = dims >= 2 ? (double)cy + oy - c[1] : 0.0;
                double dz = dims >= 3 ? (double)cz + oz - c[2] : 0.0;

                double d = metric(m, dx, dy, dz);

                if (d < *f1) {
                    *f2 = *f1;
                    *f1 = d;
                    *id = h;
                } else if (d < *f2) {
                    *f2 = d;
                }
            }
        }
    }
}

/* ── Processing-compatible layer ──────────────────────────────────────────── */

static int    proc_octaves = 4;
static double proc_falloff = 0.5;

/* ── Lua-facing functions ─────────────────────────────────────────────────── */

/* noise.seed(n) — reseed the permutation table */
static int l_seed(lua_State *L) {
    noise_reseed((uint64_t)luaL_checkinteger(L, 1));
    return 0;
}

/* noise.perlin(x [, y [, z]]) -> -1 .. 1 */
static int l_perlin(lua_State *L) {
    double c[3];
    int opts;
    int dims = read_coords(L, c, &opts);
    lua_pushnumber(L, perlin_nd(dims, c));
    return 1;
}

/* noise.fbm(x [, y [, z]] [, opts]) -> -1 .. 1 */
static int l_fbm(lua_State *L) {
    double c[3];
    int opts;
    int dims = read_coords(L, c, &opts);
    lua_pushnumber(L, fbm_nd(dims, c, read_fractal_opts(L, opts)));
    return 1;
}

/* noise.turbulence(x [, y [, z]] [, opts]) -> 0 .. 1 */
static int l_turbulence(lua_State *L) {
    double c[3];
    int opts;
    int dims = read_coords(L, c, &opts);
    lua_pushnumber(L, turbulence_nd(dims, c, read_fractal_opts(L, opts)));
    return 1;
}

/* noise.ridged(x [, y [, z]] [, opts]) -> 0 .. 1 */
static int l_ridged(lua_State *L) {
    double c[3];
    int opts;
    int dims = read_coords(L, c, &opts);
    lua_pushnumber(L, ridged_nd(dims, c, read_fractal_opts(L, opts)));
    return 1;
}

/*
 * noise.worley(x [, y [, z]] [, opts]) -> f1, f2, cell_id
 *
 * opts.jitter  0..1, how far feature points stray from their cell centre (1)
 * opts.metric  "euclidean" (default) | "manhattan" | "chebyshev"
 *
 * f2 - f1 gives the classic cracked-cell edges; cell_id is a stable integer
 * per cell, useful for making a per-cell decision (which hatch angle, which
 * glyph) that stays put as you sample around inside the cell.
 */
static int l_worley(lua_State *L) {
    double c[3];
    int opts;
    int dims = read_coords(L, c, &opts);

    double jitter = opt_field(L, opts, "jitter", 1.0);
    if (jitter < 0.0) jitter = 0.0;
    if (jitter > 1.0) jitter = 1.0;

    const char *ms = opt_string(L, opts, "metric", "euclidean");
    int m = DIST_EUCLIDEAN;
    if      (strcmp(ms, "manhattan") == 0) m = DIST_MANHATTAN;
    else if (strcmp(ms, "chebyshev") == 0) m = DIST_CHEBYSHEV;
    else if (strcmp(ms, "euclidean") != 0)
        return luaL_error(L, "unknown distance metric '%s' "
                             "(expected euclidean, manhattan or chebyshev)", ms);

    double f1, f2;
    uint32_t id;
    worley(dims, c, jitter, m, &f1, &f2, &id);

    lua_pushnumber(L, f1);
    lua_pushnumber(L, f2);
    lua_pushinteger(L, (lua_Integer)id);
    return 3;
}

/* noise.noise_detail(octaves [, falloff]) — Processing's noiseDetail() */
static int l_noise_detail(lua_State *L) {
    int oct = (int)luaL_checkinteger(L, 1);
    if (oct < 1)  oct = 1;
    if (oct > 16) oct = 16;
    proc_octaves = oct;

    if (lua_isnumber(L, 2)) {
        double f = lua_tonumber(L, 2);
        if (f < 0.0) f = 0.0;
        if (f > 1.0) f = 1.0;
        proc_falloff = f;
    }
    return 0;
}

/* noise.noise_seed(n) — Processing's noiseSeed() */
static int l_noise_seed(lua_State *L) {
    return l_seed(L);
}

/*
 * noise.noise(x [, y [, z]]) -> 0 .. 1
 *
 * Processing's noise(): same interface, same parameters, same output range.
 * Not the same numbers — Processing uses value noise, this is Perlin.
 */
static int l_noise(lua_State *L) {
    double c[3];
    int opts;
    int dims = read_coords(L, c, &opts);

    FractalOpts o = { proc_octaves, 2.0, proc_falloff };
    lua_pushnumber(L, fbm_nd(dims, c, o) * 0.5 + 0.5);
    return 1;
}

/* ── Registration ─────────────────────────────────────────────────────────── */

static const luaL_Reg noise_lib[] = {
    {"seed",         l_seed},
    {"perlin",       l_perlin},
    {"fbm",          l_fbm},
    {"turbulence",   l_turbulence},
    {"ridged",       l_ridged},
    {"worley",       l_worley},

    /* Processing-compatible names */
    {"noise",        l_noise},
    {"noise_detail", l_noise_detail},
    {"noise_seed",   l_noise_seed},
    {"noiseDetail",  l_noise_detail},
    {"noiseSeed",    l_noise_seed},

    {NULL, NULL}
};

/* Called with the module table on top; makes noise(x, y) work as shorthand
 * for noise.perlin(x, y), the way it reads in a Processing sketch. */
static int noise_call(lua_State *L) {
    lua_remove(L, 1);
    return l_perlin(L);
}

int luaopen_noise(lua_State *L) {
    noise_reseed(0);            /* deterministic even if seed() is never called */

    luaL_newlib(L, noise_lib);

    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, noise_call);
    lua_setfield(L, -2, "__call");
    lua_setmetatable(L, -2);

    return 1;
}
