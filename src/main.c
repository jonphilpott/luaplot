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

#include <dirent.h>
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
/*
 * Where the bundled lua/ directory lives, resolved from argv[0].
 *
 * Shared by setup_package_path and the help text, so what --help reports is
 * the same directory require() will actually search -- the two drifting apart
 * would make the help actively misleading when a path problem is exactly what
 * you are trying to debug.
 *
 * Writes into buf and returns it, or NULL if nothing plausible was found.
 */
static const char *resolve_root(const char *argv0, char *buf, size_t len) {
    char exedir[PATH_MAX];
    snprintf(exedir, sizeof(exedir), "%s", argv0 ? argv0 : ".");
    const char *dir = dirname(exedir);   /* dirname may modify its argument */

    const char *candidates[] = { "%s", "%s/..", "." };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(*candidates); i++) {
        char probe[PATH_MAX];
        snprintf(buf, len, candidates[i], dir);
        snprintf(probe, sizeof(probe), "%s/lua/plotter.lua", buf);
        if (access(probe, R_OK) == 0)
            return buf;
    }

    return NULL;
}

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

/* ── Help ─────────────────────────────────────────────────────────────────── */

/*
 * Pull a one-line description out of a tool's header comment.
 *
 * Every tool opens with a block comment whose first line names the file and
 * follows it with an em dash and a description. Reading that back means the
 * listing cannot go stale as tools are added or renamed, which a hand-written
 * list in this file certainly would.
 *
 * Returns 1 and fills desc on success.
 */
static int tool_description(const char *path, char *desc, size_t len) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;

    char line[512];
    int found = 0;

    /* The description is in the header, so a handful of lines is plenty */
    for (int i = 0; i < 8 && fgets(line, sizeof(line), f); i++) {
        /* U+2014 EM DASH is three bytes in UTF-8 */
        char *dash = strstr(line, "\xe2\x80\x94");
        size_t skip = 3;

        if (!dash) { dash = strstr(line, " -- "); skip = 4; }
        if (!dash) continue;

        char *text = dash + skip;
        while (*text == ' ') text++;

        char *nl = strchr(text, '\n');
        if (nl) *nl = '\0';

        if (*text) {
            snprintf(desc, len, "%s", text);
            found = 1;
        }
        break;
    }

    fclose(f);
    return found;
}

/* List the bundled tools, newest information first: read from disk, not from
 * a list in this file that someone has to remember to update. */
static void list_tools(const char *root) {
    char dirpath[PATH_MAX];
    snprintf(dirpath, sizeof(dirpath), "%s/tools", root);

    DIR *d = opendir(dirpath);
    if (!d) return;

    /* Collect and sort, so the listing does not depend on directory order */
    char names[64][NAME_MAX];
    int  count = 0;

    struct dirent *e;
    while ((e = readdir(d)) != NULL && count < 64) {
        size_t n = strlen(e->d_name);
        if (n > 4 && strcmp(e->d_name + n - 4, ".lua") == 0)
            snprintf(names[count++], NAME_MAX, "%s", e->d_name);
    }
    closedir(d);

    if (count == 0) return;

    for (int i = 0; i < count - 1; i++)
        for (int j = i + 1; j < count; j++)
            if (strcmp(names[i], names[j]) > 0) {
                char t[NAME_MAX];
                snprintf(t, sizeof(t), "%s", names[i]);
                snprintf(names[i], NAME_MAX, "%s", names[j]);
                snprintf(names[j], NAME_MAX, "%s", t);
            }

    printf("\nTools (run with --help for each tool's own options):\n");

    for (int i = 0; i < count; i++) {
        char path[PATH_MAX], desc[256];
        snprintf(path, sizeof(path), "%s/tools/%s", root, names[i]);

        if (tool_description(path, desc, sizeof(desc)))
            printf("  tools/%-20s %s\n", names[i], desc);
        else
            printf("  tools/%s\n", names[i]);
    }
}

static void print_help(const char *argv0) {
    printf(
"luaplot - a Lua-scriptable toolkit for pen plotters running GRBL\n"
"\n"
"Usage:\n"
"  %s <script.lua> [args...]     run a script\n"
"  %s --help                     this message\n"
"  %s --version                  version information\n"
"\n"
"Arguments after the script name are passed through to it in the global\n"
"'arg' table, the same way the standard Lua interpreter does it. Most of the\n"
"bundled examples read arg[1] as an output mode and arg[2] as a serial port:\n"
"\n"
"  %s examples/hello.lua                  SVG preview (the default)\n"
"  %s examples/hello.lua gcode            write a .nc file\n"
"  %s examples/hello.lua serial           plot it over serial\n"
"  %s examples/hello.lua serial /dev/cu.usbmodem1101\n"
"\n"
"Output modes are chosen by the script through plotter.init{mode=...}:\n"
"  svg      write an SVG file, no hardware needed\n"
"  gcode    write a .nc G-code file for later playback\n"
"  serial   stream G-code to the plotter\n"
"  both     serial and SVG at once\n"
"\n"
"Environment:\n"
"  LUAPLOT_PORT       default serial port for the tools and examples\n"
"  LUAPLOT_PEN_UP     default pen-up servo value for the examples\n"
"  LUAPLOT_PEN_DOWN   default pen-down servo value\n"
"  LUAPLOT_PATH       extra directories to search for Lua modules; prepended\n"
"                     to package.path ahead of the bundled lua/\n"
"\n"
"Modules available to a script:\n"
"  plotter   require 'plotter'   drawing, transforms, output (the main API)\n"
"  util      require 'util'      maths, seeded random, point distributions\n"
"  grbl      require 'grbl'      GRBL settings, status, alarm handling\n"
"  serial    require 'serial'    raw serial access\n"
"  vec2      (a global)          2D vector primitive\n"
"  noise     (a global)          Perlin, fBm, Worley noise\n",
        argv0, argv0, argv0, argv0, argv0, argv0, argv0);

    char root[PATH_MAX];
    const char *found = resolve_root(argv0, root, sizeof(root));

    if (found) {
        list_tools(found);
        printf("\nModules are being loaded from: %s/lua\n", found);
        printf("Full documentation: %s/docs/index.html\n", found);
    } else {
        printf("\nWARNING: could not find the bundled lua/ directory near %s\n"
               "         require 'plotter' will fail. Run luaplot from the\n"
               "         repository root, or set LUAPLOT_PATH.\n", argv0);
    }
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
    /*
     * Only argv[1] is inspected for options. Everything after the script name
     * belongs to the script, so a plot that takes a --help of its own is not
     * intercepted here.
     */
    if (argc >= 2) {
        if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
            print_help(argv[0]);
            return 0;
        }
        if (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-v") == 0) {
            printf("luaplot (built against %s)\n", LUA_RELEASE);
            return 0;
        }
    }

    if (argc < 2) {
        fprintf(stderr, "Usage: %s <script.lua> [args...]\n", argv[0]);
        fprintf(stderr, "Try '%s --help' for the full list.\n", argv[0]);
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
