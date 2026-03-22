#pragma once

#include <lua.h>

/*
 * serial — Lua module for serial port communication
 *
 * Exposed to Lua as the 'serial' module (registered by main.c).
 * Maintains a single open connection at a time, which is all we need
 * for talking to one plotter.
 *
 * Lua API:
 *   serial.open(port, baud)   — open port, returns true or raises error
 *   serial.writeline(str)     — send a line, block until GRBL replies 'ok'
 *   serial.close()            — close the port
 */
int luaopen_serial(lua_State *L);
