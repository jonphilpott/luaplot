/*
 * vec2.h — 2D vector userdata type for luaplot
 *
 * Registered into package.preload as 'vec2' and also exposed as a global by
 * main.c, so scripts can treat it as a language primitive.
 */

#ifndef LUAPLOT_VEC2_H
#define LUAPLOT_VEC2_H

#include <lua.h>

/* Metatable name — also used by other C modules that hand back vectors */
#define LUAPLOT_VEC2_MT "luaplot.vec2"

/* Push a new vec2 userdata onto the stack */
void luaplot_vec2_push(lua_State *L, double x, double y);

int luaopen_vec2(lua_State *L);

#endif /* LUAPLOT_VEC2_H */
