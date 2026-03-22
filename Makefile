# luaplot — Lua-scriptable pen plotter toolkit
# Bundles Lua 5.4 source so the only dependency is a C compiler.
#
# First time setup:
#   make fetch-lua     — downloads and unpacks Lua 5.4.7 into lua-src/
#   make               — builds the luaplot executable
#
# Usage:
#   ./luaplot examples/hello.lua

LUA_VERSION = 5.4.7
LUA_DIR     = lua-src
LUA_URL     = https://www.lua.org/ftp/lua-$(LUA_VERSION).tar.gz

CC      = cc
CFLAGS  = -Wall -O2 -I$(LUA_DIR)/src
LDFLAGS = -lm

TARGET = luaplot

# Our source files
SRCS = src/main.c src/serial.c

# Lua source files — exclude the standalone interpreter (lua.c) and compiler
# (luac.c) since we provide our own main()
LUA_SRCS = $(filter-out \
    $(LUA_DIR)/src/lua.c \
    $(LUA_DIR)/src/luac.c, \
    $(wildcard $(LUA_DIR)/src/*.c))

# ── Guards ────────────────────────────────────────────────────────────────────

ifneq ($(MAKECMDGOALS),fetch-lua)
ifeq ($(wildcard $(LUA_DIR)/src/lua.h),)
$(error Lua source not found. Run 'make fetch-lua' first.)
endif
endif

# ── Targets ───────────────────────────────────────────────────────────────────

.PHONY: all fetch-lua clean

all: $(TARGET)

$(TARGET): $(SRCS) $(LUA_SRCS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

fetch-lua:
	@echo "Fetching Lua $(LUA_VERSION)..."
	curl -L $(LUA_URL) | tar xz
	mv lua-$(LUA_VERSION) $(LUA_DIR)
	@echo "Done. Run 'make' to build."

clean:
	rm -f $(TARGET)
