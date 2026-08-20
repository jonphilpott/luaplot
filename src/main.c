/*
 * main.c — entry point for luaplot
 *
 * Sets up a Lua 5.4 interpreter, registers the 'serial' C module so Lua
 * scripts can do  require 'serial',  points package.path at the ./lua/
 * directory so  require 'plotter'  and  require 'hershey'  resolve, then
 * runs the script given on the command line.
 *
 * Usage:
 *   ./luaplot examples/hello.lua
 *
 * Error handling philosophy:
 *   Any Lua error (syntax, runtime, or from our C modules) prints the
 *   message to stderr and exits with code 1, so shell scripts can detect
 *   failure.
 */

#include "serial.h"
#include "vec2.h"
#include "noise.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ── Module preloading ────────────────────────────────────────────────────── */

/*
 * Lua's require() looks in package.preload before searching the filesystem.
 * We register our C module there so  require 'serial'  calls luaopen_serial
 * without needing a .so file.
 *
 * The mechanism:
 *   package.preload is a table mapping module name → loader function.
 *   When require('serial') is called and 'serial' isn't already loaded,
 *   Lua calls package.preload['serial']() and caches the result in
 *   package.loaded['serial'].
 */
static void preload_module(lua_State *L, const char *name, lua_CFunction opener) {
    /* Step 1: get package.preload onto the stack */
    lua_getglobal(L, "package");          /* stack: package */
    lua_getfield(L, -1, "preload");       /* stack: package, package.preload */

    /* Step 2: set package.preload[name] = opener */
    lua_pushcfunction(L, opener);         /* stack: package, preload, fn */
    lua_setfield(L, -2, name);            /* preload[name] = fn */

    /* Step 3: clean up — pop preload and package */
    lua_pop(L, 2);
}

/*
 * Make a module available as a global as well as through require().
 *
 * vec2 (and noise) are meant to read like language primitives — writing
 * `local vec2 = require 'vec2'` at the top of every sketch is friction for no
 * benefit, since the binary always has them compiled in. They remain
 * require()-able so that scripts which prefer to be explicit still can.
 */
static void global_module(lua_State *L, const char *name) {
    lua_getglobal(L, "require");
    lua_pushstring(L, name);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "luaplot: failed to load module '%s': %s\n",
                name, lua_tostring(L, -1));
        lua_pop(L, 1);
        return;
    }
    lua_setglobal(L, name);
}

/* ── package.path setup ───────────────────────────────────────────────────── */

/*
 * Point package.path at the bundled lua/ directory so  require 'plotter'
 * resolves.
 *
 * This used to be a hardcoded relative "./lua/?.lua", which meant luaplot only
 * worked when invoked from the repo root — running it from anywhere else, or
 * installing the binary elsewhere on PATH, failed to find the modules. We now
 * search, in order:
 *
 *   1. $LUAPLOT_PATH             — explicit override, wins outright
 *   2. <dir of argv[0]>/lua/     — a binary sitting next to its lua/ directory
 *   3. <dir of argv[0]>/../lua/  — a binary installed into a bin/ subdirectory
 *   4. ./lua/                    — the old behaviour, kept for compatibility
 *   5. the stdlib default paths
 *
 * '?' is replaced by the module name, so "…/lua/?.lua" with require("plotter")
 * becomes "…/lua/plotter.lua".
 */
static void setup_package_path(lua_State *L, const char *argv0) {
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");
    const char *existing = lua_tostring(L, -1);

    /* dirname() may modify its argument, so give it a copy it can chew on */
    char exedir[PATH_MAX];
    snprintf(exedir, sizeof(exedir), "%s", argv0 ? argv0 : ".");
    const char *dir = dirname(exedir);

    const char *override = getenv("LUAPLOT_PATH");

    /* lua_pushfstring grows as needed — the old fixed 2048-byte buffer
     * silently truncated an already-long package.path. */
    if (override && *override)
        lua_pushfstring(L, "%s;", override);
    else
        lua_pushliteral(L, "");

    lua_pushfstring(L, "%s/lua/?.lua;%s/../lua/?.lua;./lua/?.lua;%s",
                    dir, dir, existing ? existing : "");
    lua_concat(L, 2);

    lua_remove(L, -2);          /* drop the old path string */
    lua_setfield(L, -2, "path");
    lua_pop(L, 1);              /* pop package */
}

/* ── Error reporting ──────────────────────────────────────────────────────── */

/*
 * Message handler installed for lua_pcall.
 *
 * It runs while the erroring stack frame is still live, which is the only
 * moment a traceback can be captured — by the time pcall returns, the stack
 * has already been unwound. Without this, a runtime error deep inside a sketch
 * reported only its own line and nothing about how it got there.
 */
static int msghandler(lua_State *L) {
    const char *msg = lua_tostring(L, 1);

    if (msg == NULL) {
        /* A non-string error object. Give __tostring a chance before falling
         * back to naming the type. */
        if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING)
            return 1;
        msg = lua_pushfstring(L, "(error object is a %s value)",
                              luaL_typename(L, 1));
    }

    luaL_traceback(L, L, msg, 1);
    return 1;
}

/*
 * Called when lua_pcall returns an error.
 * The error message is on top of the Lua stack; print it and clean up.
 */
static void report_error(lua_State *L) {
    const char *msg = lua_tostring(L, -1);
    fprintf(stderr, "luaplot error: %s\n", msg ? msg : "(no message)");
    lua_pop(L, 1);
}

/* ── main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <script.lua>\n", argv[0]);
        return 1;
    }
    const char *script = argv[1];

    /* Step 1: Create a new Lua state with the standard allocator */
    lua_State *L = luaL_newstate();
    if (!L) {
        fprintf(stderr, "luaplot: out of memory creating Lua state\n");
        return 1;
    }

    /* Step 2: Open the standard Lua libraries (math, string, io, etc.)
     * These give scripts access to things like io.write(), math.sin(), etc. */
    luaL_openlibs(L);

    /* Step 3: Register our C modules in package.preload */
    preload_module(L, "serial", luaopen_serial);
    preload_module(L, "vec2",   luaopen_vec2);
    preload_module(L, "noise",  luaopen_noise);

    /* Step 4: Point package.path at the bundled lua/ so require('plotter') works */
    setup_package_path(L, argv[0]);

    /* Step 5: Expose the primitive types as globals too. Must come after
     * setup_package_path, since require() is what loads them. */
    global_module(L, "vec2");
    global_module(L, "noise");

    /*
     * Step 6: Pass extra command-line arguments to the script via the global
     * 'arg' table, matching the standard Lua interpreter convention:
     *   arg[0] = script name
     *   arg[1] = first user argument
     *   arg[-1] = "luaplot" (the interpreter name)
     *
     * This lets scripts do things like:  local port = arg[1]
     */
    lua_newtable(L);
    lua_pushstring(L, argv[0]);
    lua_rawseti(L, -2, -1);               /* arg[-1] = argv[0] */
    lua_pushstring(L, script);
    lua_rawseti(L, -2, 0);               /* arg[0]  = script  */
    for (int i = 2; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - 1);       /* arg[1..] = remaining args */
    }
    lua_setglobal(L, "arg");

    /* Step 7: Load and run the script.
     *
     * luaL_loadfile compiles the script to bytecode; lua_pcall runs it.
     * Both return 0 on success, non-zero on error.  Using pcall (protected
     * call) means errors are caught and returned rather than crashing. */
    int ok = luaL_loadfile(L, script);
    if (ok != LUA_OK) {
        report_error(L);
        lua_close(L);
        return 1;
    }

    /* Push the message handler below the function so pcall can find it, and
     * pass its absolute index — this is what turns a bare error message into
     * a message plus stack traceback. */
    lua_pushcfunction(L, msghandler);
    lua_insert(L, -2);
    int msgh = lua_gettop(L) - 1;

    ok = lua_pcall(L, 0, LUA_MULTRET, msgh);
    if (ok != LUA_OK) {
        report_error(L);
        lua_close(L);
        return 1;
    }

    /* Step 8: Clean shutdown */
    lua_close(L);
    return 0;
}
