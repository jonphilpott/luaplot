# luaplot

A Lua-scriptable toolkit for pen plotters running GRBL. Write a Lua script, get
lines on paper.

Lua 5.4 is bundled — the only dependency is a C compiler.
macOS and Linux only (POSIX termios serial).

```lua
local plotter = require 'plotter'

plotter.init { mode = "svg", width = 200, height = 200, svg_file = "out.svg" }
-- for hardware, add: origin = vec2(43, 127)  -- where the paper sits on the bed

plotter.rect(10, 10, 180, 180)
plotter.text(20, 100, "hello", 20)
plotter.circle(vec2(100, 60), 30)

plotter.done()
```

## Building

```sh
make fetch-lua   # download Lua 5.4 source into lua-src/
make             # build the luaplot executable
make test        # run the test suite
```

## Usage

```sh
./luaplot --help                               # options, tools, environment
./luaplot examples/hello.lua                   # SVG preview (default)
./luaplot examples/hello.lua gcode             # write a G-code file
./luaplot examples/hello.lua serial            # send to the plotter
./luaplot examples/hello.lua serial /dev/cu.usbmodem1101
```

The port also comes from `$LUAPLOT_PORT`. On macOS use `/dev/cu.*`, never
`/dev/tty.*` — the latter blocks on `open()` waiting for carrier detect.

## What's here

| | |
|---|---|
| **Drawing** | Processing-style transform stack, lines, curves, Bézier and Catmull-Rom, text in a single-stroke Hershey font, hatching with holes |
| **`vec2`** | A 2D vector primitive modelled on Processing's `PVector`, in C. Drops straight into point lists |
| **`noise`** | Perlin, fBm, ridged, turbulence and Worley/cellular noise, in C |
| **`util`** | `map`/`lerp`/`constrain`, seeded random including Gaussian and weighted, Poisson-disk and Halton point distributions |
| **Output** | SVG, G-code file, or live over serial — with pen-travel optimisation, work-area clipping, layers and pen changes |
| **Real-time** | `flush()` emits a batch and keeps the session open, so a plot can build up over time |
| **Brush painting** | Paint pots at fixed bed positions, with `dip()` to reload — dwell in the paint, then dwell over the pot to drip |
| **Tools** | Pen setup with bed levelling, steps-per-mm calibration, GRBL settings backup/restore |

## Output modes

| Mode | Description |
|------|-------------|
| `svg` | Write an SVG file — no hardware needed, good for iteration |
| `gcode` | Write a `.nc` G-code file for repeatable plotter playback |
| `serial` | Send G-code to the plotter live over serial |
| `both` | Serial + SVG simultaneously |

## Generative example

```lua
local plotter = require 'plotter'
local util    = require 'util'

plotter.init { mode = "svg", width = 200, height = 260,
               svg_file = "flow.svg", optimize = true, clip = "clip" }

noise.seed(42)

local function field(p)
    return vec2.from_angle(noise.fbm(p.x * 0.006, p.y * 0.006) * math.pi * 2)
end

for _, s in ipairs(util.poisson_disk(184, 244, 2.6)) do
    local pts = plotter.streamline(vec2(s[1] + 8, s[2] + 8), field, 320, 1.2, {
        stop = function(p) return p.x < 8 or p.y < 8 or p.x > 192 or p.y > 252 end,
    })
    if #pts >= 25 then plotter.polyline(pts) end
end

plotter.done()
```

## Painting with a brush

A brush needs reloading, and the paint pot sits at a fixed spot on the bed:

```lua
plotter.init {
    mode      = "serial",
    port      = port,
    pen_up    = 0,
    pen_down  = 150,

    paint_pot = vec2(15, 15),
    pen_dip   = 175,    -- the paint is deeper than the paper
    dip_time  = 1.5,    -- seconds in the paint
    drip_time = 2.0,    -- seconds above the pot, letting excess fall back
}

plotter.dip()                    -- up, travel, down, wait, up, wait
plotter.polyline(stroke)
```

Pot positions are absolute — the transform stack never touches them, so a dip
inside a `push()`/`pop()` block still goes to the same physical place. Dips are
queued in order alongside strokes and act as a barrier the travel optimiser
will not reorder across, so a load of paint stays with the strokes you dipped
for. `plotter.pot(name, x, y)` registers more than one; `dip_every = 120`
reloads automatically every 120 mm drawn.

## Setting up the pen

On a new machine, first find the servo values — with no pen fitted, since you
are hunting for the travel limits:

```sh
./luaplot tools/servo-sweep.lua            # sends only M3 S<n>; no motion
```

Jog the head around to find where your paper sits — arrow keys, live
coordinates, and `0` to zero the work origin at a corner:

```sh
./luaplot tools/jog.lua --pen-up 0 --pen-down 150
```

Then fit the pen and check it reaches the paper everywhere:

```sh
./luaplot tools/pen-setup.lua --pen-up 0 --pen-down 150 --paper 180,240
```

It moves to the middle of the paper and lowers the holder so you can fit the
pen at the right height, then walks a 3×3 grid across the paper pausing at each
point with the pen down — bed levelling, borrowed from 3D printing and for the
same reason. Finally it revisits every point and puts a dot down. Nine dots of
even weight means you are level; a missing one is a corner the pen never
reached.

## Calibrating the machine

If a commanded 100 mm line measures 98 mm, GRBL's steps-per-mm is wrong:

```sh
./luaplot tools/grbl-config.lua dump grbl-backup.txt      # back up first
./luaplot tools/calibrate.lua --pen-up 0 --pen-down 150   # measure and fix
./luaplot tools/grbl-config.lua restore grbl-backup.txt   # undo if needed
```

`calibrate.lua` draws a reference line on each axis with tick marks at the
exact commanded endpoints, asks you what it actually measured, and writes the
corrected `$100`/`$101` after showing you the change. It takes its own
timestamped backup before touching anything.

## Examples

| | |
|---|---|
| `hello.lua` | One of every primitive, as a reference sheet |
| `flowfield.lua` | Streamlines through a Perlin field, with even spacing |
| `brush.lua` | Two-colour brush painting, with automatic reloads |
| `stipple.lua` | Variable-density stippling from Worley noise, plus hatching |
| `mandelbrot.lua` | Escape-time contours via marching squares |
| `monalisa.lua` | A portrait: geometry for shape, a light model for tone, a different mark per material |

## Full documentation

Open `docs/index.html` in a browser — it is the complete API reference.
