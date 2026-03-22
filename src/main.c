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

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
static void preload_serial(lua_State *L) {
    /* Step 1: get package.preload onto the stack */
    lua_getglobal(L, "package");          /* stack: package */
    lua_getfield(L, -1, "preload");       /* stack: package, package.preload */

    /* Step 2: set package.preload["serial"] = luaopen_serial */
    lua_pushcfunction(L, luaopen_serial); /* stack: package, preload, fn */
    lua_setfield(L, -2, "serial");        /* preload["serial"] = fn */

    /* Step 3: clean up — pop preload and package */
    lua_pop(L, 2);
}

/* ── package.path setup ───────────────────────────────────────────────────── */

/*
 * Prepend "./lua/?.lua" to package.path so  require 'plotter'  resolves to
 * ./lua/plotter.lua relative to wherever luaplot is invoked from.
 *
 * We prepend rather than replace so the standard library paths remain
 * available (e.g. if the user has system Lua modules they want to use).
 *
 * Lua string format tip: '?' is replaced by the module name, so
 *   "./lua/?.lua"  with  require("plotter")  → "./lua/plotter.lua"
 */
static void setup_package_path(lua_State *L) {
    /* Get the existing path string */
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");

    const char *existing = lua_tostring(L, -1);

    /* Build new path: our dir first, then the old paths */
    char newpath[2048];
    snprintf(newpath, sizeof(newpath), "./lua/?.lua;%s", existing ? existing : "");

    /* Set package.path = newpath */
    lua_pop(L, 1);                        /* pop old path string */
    lua_pushstring(L, newpath);
    lua_setfield(L, -2, "path");          /* package.path = newpath */
    lua_pop(L, 1);                        /* pop package */
}

/* ── Error reporting ──────────────────────────────────────────────────────── */

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

    /* Step 3: Register our serial C module in package.preload */
    preload_serial(L);

    /* Step 4: Point package.path at ./lua/ so require('plotter') works */
    setup_package_path(L);

    /*
     * Step 5: Pass extra command-line arguments to the script via the global
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

    /* Step 6: Load and run the script.
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

    ok = lua_pcall(L, 0, LUA_MULTRET, 0);
    if (ok != LUA_OK) {
        report_error(L);
        lua_close(L);
        return 1;
    }

    /* Step 7: Clean shutdown */
    lua_close(L);
    return 0;
}
