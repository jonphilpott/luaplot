# luaplot

A Lua-scriptable toolkit for pen plotters running GRBL. Write a Lua script, get lines on paper.

Lua 5.4 is bundled — the only dependency is a C compiler.
macOS and Linux only (POSIX termios serial).

## Building

```sh
make fetch-lua   # download Lua 5.4 source into lua-src/
make             # build the luaplot executable
```

## Usage

```sh
./luaplot examples/hello.lua           # SVG preview (default)
./luaplot examples/hello.lua gcode     # write G-code file (output.nc)
./luaplot examples/hello.lua serial    # send to plotter over serial
```

## Quick example

```lua
local plotter = require 'plotter'

plotter.init {
    mode     = "svg",
    width    = 200,
    height   = 200,
    svg_file = "out.svg",
}

plotter.rect(10, 10, 180, 180)
plotter.text(20, 100, "hello", 20)
plotter.circle(100, 60, 30)

plotter.done()
```

## Output modes

| Mode | Description |
|------|-------------|
| `svg` | Write an SVG file — no hardware needed, good for iteration |
| `gcode` | Write a `.nc` G-code file for repeatable plotter playback |
| `serial` | Send G-code to the plotter live over serial |
| `both` | Serial + SVG simultaneously |

## Primitives

```lua
plotter.line(x1, y1, x2, y2)
plotter.polyline(points, close)        -- core path primitive, one pen lift per path
plotter.polygon(points)                -- closed arbitrary shape
plotter.rect(x, y, w, h)
plotter.circle(cx, cy, r [, steps])
plotter.ellipse(cx, cy, rx, ry [, steps])
plotter.arc(cx, cy, r, start_angle, end_angle [, steps])
plotter.bezier(x1,y1, cx1,cy1, cx2,cy2, x2,y2 [, steps])
plotter.text(x, y, str, height)        -- Hershey Roman Simplex single-stroke font
plotter.text_width(str, height)        -- measure without drawing
```

## Transform stack

Processing-style push/pop transform stack. All drawing calls go through the current transform.

```lua
plotter.push()
    plotter.translate(100, 100)
    plotter.rotate(45)          -- degrees, clockwise
    plotter.scale(2)
    plotter.rect(-10, -10, 20, 20)
plotter.pop()
```

Coordinate system is Y-down, origin top-left (Processing convention). Y-axis is flipped automatically when emitting G-code.

## init() options

```lua
plotter.init {
    mode       = "svg",              -- "svg" | "gcode" | "serial" | "both"
    width      = 200,                -- work area mm
    height     = 200,
    port       = "/dev/ttyUSB0",     -- serial port (serial/both)
    baud       = 115200,
    feed       = 1000,               -- drawing feed rate mm/min
    pen_up     = 90,                 -- M3 S value for pen up servo position
    pen_down   = 30,                 -- M3 S value for pen down servo position
    svg_file   = "output.svg",       -- svg/both
    gcode_file = "output.nc",        -- gcode mode
}
```

## Full documentation

Open `docs/index.html` in a browser.
