# luaplot — Lua-scriptable pen plotter toolkit
# Bundles Lua 5.4 source so the only dependency is a C compiler.
#
# First time setup:
#   make fetch-lua     — downloads and unpacks Lua 5.4.7 into lua-src/
#   make               — builds the luaplot executable
#   make test          — runs the test suite
#
# Usage:
#   ./luaplot examples/hello.lua

LUA_VERSION = 5.4.7
LUA_DIR     = lua-src
LUA_URL     = https://www.lua.org/ftp/lua-$(LUA_VERSION).tar.gz

BUILD_DIR = build
TARGET    = luaplot

CC      = cc
CFLAGS  = -O2 -I$(LUA_DIR)/src
LDFLAGS = -lm

# We hold our own code to -Wextra; bundled Lua is upstream's problem, so it
# builds at plain -Wall to keep the output readable.
WARN_OURS = -Wall -Wextra
WARN_LUA  = -Wall

# ── Platform ──────────────────────────────────────────────────────────────────
#
# Lua's luaconf.h needs a platform define to enable POSIX facilities (dynamic
# module loading, io.popen, os.tmpname).  Without one it falls back to the
# portable-C89 subset.  LUA_USE_LINUX additionally wants -ldl for dlopen().
#
# LUA_USE_LINUX also defines LUA_USE_READLINE, but that is only consumed by the
# standalone interpreter (lua.c), which we exclude — so no readline dependency.

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
    CFLAGS  += -DLUA_USE_MACOSX
endif
ifeq ($(UNAME_S),Linux)
    CFLAGS  += -DLUA_USE_LINUX
    LDFLAGS += -ldl
endif

# ── Sources ───────────────────────────────────────────────────────────────────

SRCS = src/main.c src/serial.c src/vec2.c src/noise.c

# Lua source files — exclude the standalone interpreter (lua.c) and compiler
# (luac.c) since we provide our own main()
LUA_SRCS = $(filter-out \
    $(LUA_DIR)/src/lua.c \
    $(LUA_DIR)/src/luac.c, \
    $(wildcard $(LUA_DIR)/src/*.c))

# Mirror the source tree under build/ so object files never collide
OBJS = $(SRCS:%.c=$(BUILD_DIR)/%.o) $(LUA_SRCS:%.c=$(BUILD_DIR)/%.o)
DEPS = $(OBJS:.o=.d)

# ── Guards ────────────────────────────────────────────────────────────────────

ifneq ($(MAKECMDGOALS),fetch-lua)
ifeq ($(wildcard $(LUA_DIR)/src/lua.h),)
$(error Lua source not found. Run 'make fetch-lua' first.)
endif
endif

# ── Targets ───────────────────────────────────────────────────────────────────

.PHONY: all fetch-lua test lint clean

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) -o $@ $^ $(LDFLAGS)

# -MMD -MP emits a .d file of header dependencies alongside each object, so
# editing a header rebuilds exactly the objects that include it.
$(BUILD_DIR)/src/%.o: src/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(WARN_OURS) -MMD -MP -c $< -o $@

$(BUILD_DIR)/$(LUA_DIR)/src/%.o: $(LUA_DIR)/src/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(WARN_LUA) -MMD -MP -c $< -o $@

-include $(DEPS)

test: $(TARGET)
	./$(TARGET) tests/run.lua

lint:
	luacheck lua tests tools examples

fetch-lua:
	@echo "Fetching Lua $(LUA_VERSION)..."
	curl -L $(LUA_URL) | tar xz
	mv lua-$(LUA_VERSION) $(LUA_DIR)
	@echo "Done. Run 'make' to build."

clean:
	rm -rf $(BUILD_DIR) $(TARGET)
