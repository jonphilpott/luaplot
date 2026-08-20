/*
 * noise.h — coherent noise functions for luaplot
 *
 * Registered into package.preload as 'noise' and also exposed as a global by
 * main.c, alongside vec2.
 */

#ifndef LUAPLOT_NOISE_H
#define LUAPLOT_NOISE_H

#include <lua.h>

int luaopen_noise(lua_State *L);

#endif /* LUAPLOT_NOISE_H */
