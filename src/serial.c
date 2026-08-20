/*
 * serial.c — termios serial port module for luaplot
 *
 * Handles opening the port, sending G-code lines, and waiting for GRBL's
 * 'ok' acknowledgement before returning. This is important: GRBL has a
 * small internal buffer (~128 bytes). If you send commands faster than it
 * can execute them without reading 'ok', you overflow the buffer and lose
 * commands mid-draw. The blocking read here provides the flow control.
 *
 * Works on macOS and Linux — both use POSIX termios.
 */

#include "serial.h"

#include <lua.h>
#include <lauxlib.h>

#include <termios.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>

/* Single open file descriptor — one plotter at a time */
static int fd = -1;

/*
 * How long GRBL may stay silent AND fail to answer a status query before we
 * declare it dead, in seconds.
 *
 * This is a liveness timeout, not a speed limit, and the distinction matters.
 * GRBL acknowledges most commands as soon as they are parsed into its planner
 * buffer, but the synchronising ones -- G4 dwell, $H homing, M5 -- are not
 * answered until every queued move has physically finished. A pen lift after a
 * 200 mm path at 600 mm/min legitimately leaves the port silent for twenty
 * seconds, and an earlier version of this code called that a failure.
 *
 * So silence alone proves nothing. When the port goes quiet we send '?', a
 * realtime status query that GRBL answers immediately from an interrupt
 * regardless of what the planner is doing. An answer means it is alive and
 * working, and the clock resets. Only silence that survives repeated probes
 * counts against this budget.
 */
#define DEFAULT_REPLY_TIMEOUT 10
static int reply_timeout = DEFAULT_REPLY_TIMEOUT;

/* Whether we have already mentioned a feed hold on this command */
static int warned_hold = 0;

/* Distinguishes "read timed out" from "read an empty line" in read_line() */
#define READ_TIMEOUT (-1)

/* ── GRBL result codes ────────────────────────────────────────────────────── */

/*
 * GRBL reports failures as bare numbers -- "error:9", "ALARM:1" -- and nobody
 * remembers what they mean. Without the text you get a number and a stack
 * trace, which tells you something went wrong but not what or what to do,
 * so the tables are worth their space.
 */
static const char *error_text(int code) {
    switch (code) {
        case 1:  return "a G-code word had no letter, or no value";
        case 2:  return "bad or missing numeric value";
        case 3:  return "unrecognised $ system command";
        case 4:  return "negative value where a positive one was expected";
        case 5:  return "homing is not enabled ($22=0)";
        case 6:  return "step pulse time must be greater than 3 microseconds";
        case 7:  return "EEPROM read failed; settings were reset to defaults";
        case 8:  return "$ commands only work while GRBL is idle";
        case 9:  return "G-code locked out during alarm or jog state";
        case 10: return "soft limits need homing enabled too";
        case 11: return "line too long; it was not executed";
        case 12: return "setting value exceeds the maximum step rate";
        case 13: return "safety door is open";
        case 15: return "jog target is outside machine travel";
        case 16: return "malformed jog command";
        case 17: return "laser mode requires PWM output";
        case 20: return "unsupported or invalid G-code command";
        case 21: return "two G-code commands from the same modal group";
        case 22: return "feed rate has not been set";
        case 23: return "command requires an integer value";
        case 24: return "two commands both wanting axis words";
        case 25: return "repeated G-code word";
        case 26: return "command needs axis words and none were given";
        case 27: return "invalid line number";
        case 28: return "command is missing a required value word";
        case 29: return "G59.x work coordinate systems are unsupported";
        case 30: return "G53 only works with G0 and G1";
        case 31: return "axis words given to a command that uses none";
        case 32: return "arc needs at least one in-plane axis word";
        case 33: return "motion target is invalid";
        case 34: return "arc radius is invalid";
        case 35: return "arc needs at least one in-plane offset word";
        case 36: return "unused value words in the block";
        case 38: return "tool number above the maximum supported";
        default: return NULL;
    }
}

static const char *alarm_text(int code) {
    switch (code) {
        case 1:  return "hard limit triggered; machine position is lost, re-home";
        case 2:  return "motion target exceeds machine travel";
        case 3:  return "reset while moving; position is not trustworthy, re-home";
        case 4:  return "probe was not in its expected starting state";
        case 5:  return "probe did not reach the workpiece";
        case 6:  return "reset during homing";
        case 7:  return "safety door opened during homing";
        case 8:  return "homing could not clear the limit switch; check $27 and wiring";
        case 9:  return "homing could not find a limit switch within the search distance";
        default: return NULL;
    }
}

/*
 * The one failure everybody hits first: GRBL boots into ALARM whenever homing
 * is enabled, and refuses every G-code word until it is told where it is. The
 * message is useless without saying so.
 */
static const char *ALARM_HINT =
    " -- GRBL is in an alarm state, which is normal right after power-on when "
    "homing is enabled ($22=1). Send $H to home, or $X to unlock without "
    "homing (safe when nothing is going to move).";

/* ── Helpers ─────────────────────────────────────────────────────────────── */

/*
 * Map an integer baud rate to the termios speed_t constant.
 * termios doesn't accept raw integers — it has its own symbolic constants.
 */
static speed_t baud_to_speed(int baud) {
    switch (baud) {
        case 9600:    return B9600;
        case 19200:   return B19200;
        case 38400:   return B38400;
        case 57600:   return B57600;
        case 115200:  return B115200;
        default:      return 0;
    }
}

/*
 * Read one line from the serial port into buf (up to len-1 bytes).
 * Blocks until '\n' is received, the buffer fills, or read() times out.
 *
 * Returns the number of characters in the line (excluding '\n'), or
 * READ_TIMEOUT if the port went quiet before any part of a line arrived.
 *
 * That distinction matters: returning 0 for both "GRBL sent a blank line" and
 * "GRBL sent nothing at all" is what previously let the caller spin forever on
 * an unplugged cable.
 */
static int read_line(char *buf, int len) {
    int pos = 0;
    int got_any = 0;

    while (pos < len - 1) {
        char c;
        int n = (int)read(fd, &c, 1);
        if (n <= 0) {
            /* VTIME elapsed with nothing to read, or the device went away.
             * If we were mid-line, keep what we have; otherwise report the
             * timeout so the caller can count it against its budget. */
            if (!got_any) return READ_TIMEOUT;
            break;
        }
        got_any = 1;
        if (c == '\r') continue;    /* ignore CR in CRLF */
        if (c == '\n') break;       /* end of line */
        buf[pos++] = c;
    }
    buf[pos] = '\0';
    return pos;
}

/*
 * Send a line (appending '\n') and block until GRBL replies 'ok'.
 *
 * Shared by serial.writeline() and serial.query().  When 'collect' is non-NULL
 * every non-status reply line seen before the 'ok' is appended to the Lua table
 * at that stack index, 1-based — this is how $$ settings are read back.
 *
 * Returns 0 on success, or -1 with a Lua error message pushed on the stack.
 */
static int send_and_wait(lua_State *L, const char *line, int collect) {
    if (fd < 0) {
        lua_pushfstring(L, "Serial port is not open");
        return -1;
    }

    /* snprintf returns the length it *would* have written, which can exceed
     * the buffer.  Clamp before handing it to write(), or a G-code line of
     * 256 bytes or more makes write() read past the end of buf. */
    char buf[512];
    int  len = snprintf(buf, sizeof(buf), "%s\n", line);
    if (len < 0) {
        lua_pushfstring(L, "Failed to format command");
        return -1;
    }
    if (len >= (int)sizeof(buf))
        len = (int)sizeof(buf) - 1;

    if (write(fd, buf, (size_t)len) < 0) {
        lua_pushfstring(L, "Write failed: %s", strerror(errno));
        return -1;
    }

    /* Wait for 'ok' (or an error). See reply_timeout above: silence is only
     * treated as failure once GRBL has also stopped answering status queries. */
    char resp[256];
    int  quiet = 0;
    int  nresults = 0;

    warned_hold = 0;

    while (1) {
        int n = read_line(resp, sizeof(resp));

        if (n == READ_TIMEOUT) {
            if (++quiet >= reply_timeout) {
                lua_pushfstring(L,
                    "No response from GRBL after %d s, and it stopped answering "
                    "status queries too (sent: %s). Check the cable, the port, "
                    "and that the controller is powered.",
                    reply_timeout, line);
                return -1;
            }

            /* Ask whether it is alive. '?' is a realtime command: one byte, no
             * newline, answered from an interrupt without touching the planner
             * buffer, so it works even mid-move. */
            if (write(fd, "?", 1) < 0) {
                lua_pushfstring(L, "Write failed: %s", strerror(errno));
                return -1;
            }
            continue;
        }

        if (n == 0) continue;                      /* blank line, keep waiting */

        if (resp[0] == '<') {
            /* A status report, so the controller is alive and the wait is
             * legitimate -- a long move, or a homing cycle. Reset the clock. */
            quiet = 0;

            /* An alarm mid-command means the 'ok' is never coming. */
            if (strncmp(resp + 1, "Alarm", 5) == 0) {
                lua_pushfstring(L,
                    "GRBL entered an alarm state while waiting (sent: %s). "
                    "A limit switch or a soft limit was probably hit. Status: %s",
                    line, resp);
                return -1;
            }

            /* Hold and Door are alive but paused indefinitely, waiting for a
             * person. Say so once rather than sitting there mutely. */
            if (!warned_hold &&
                (strncmp(resp + 1, "Hold", 4) == 0 ||
                 strncmp(resp + 1, "Door", 4) == 0)) {
                warned_hold = 1;
                fprintf(stderr,
                    "luaplot: GRBL is paused (%s) and is waiting to be resumed. "
                    "Send ~ to resume, or Ctrl-C to give up.\n", resp);
                fflush(stderr);
            }
            continue;
        }

        quiet = 0;                                 /* it is still talking */
        if (strncmp(resp, "ok", 2) == 0) break;    /* success */
        if (strncmp(resp, "error", 5) == 0 || strncmp(resp, "ALARM", 5) == 0) {
            int  is_alarm = (resp[0] == 'A');
            int  code     = 0;
            const char *colon = strchr(resp, ':');
            if (colon) code = atoi(colon + 1);

            const char *text = is_alarm ? alarm_text(code) : error_text(code);
            const char *hint = (!is_alarm && code == 9) ? ALARM_HINT : "";

            if (text)
                lua_pushfstring(L, "GRBL %s: %s (sent: %s)%s",
                                resp, text, line, hint);
            else
                lua_pushfstring(L, "GRBL %s (sent: %s)%s", resp, line, hint);
            return -1;
        }

        /* Anything else is payload — a $$ settings line, $I build info, and
         * so on.  Keep it if the caller asked for it, drop it otherwise. */
        if (collect) {
            lua_pushstring(L, resp);
            lua_rawseti(L, collect, ++nresults);
        }
    }

    return 0;
}

/* ── Lua-facing functions ─────────────────────────────────────────────────── */

/*
 * serial.open(port, baud)
 *
 * Opens the serial port and configures it for 8N1, no flow control,
 * raw (non-canonical) mode. After opening, waits 2 seconds for GRBL to
 * send its startup greeting, then flushes the buffer.
 */
static int l_open(lua_State *L) {
    const char *port = luaL_checkstring(L, 1);
    int baud         = (int)luaL_checkinteger(L, 2);

    speed_t speed = baud_to_speed(baud);
    if (speed == 0)
        return luaL_error(L, "Unsupported baud rate: %d", baud);

    /* Close any existing connection */
    if (fd >= 0) { close(fd); fd = -1; }

    /*
     * macOS exposes two device files per USB serial adapter:
     *   /dev/tty.usbmodem...  — blocks on open() until carrier detect is asserted
     *   /dev/cu.usbmodem...   — no such requirement ("cu" = call-up, outgoing)
     *
     * Always use /dev/cu.* on macOS. Using /dev/tty.* will cause open() to
     * hang indefinitely if the adapter does not assert carrier detect.
     * On Linux, /dev/ttyUSB0 or /dev/ttyACM0 are the usual names and do
     * not have this issue.
     */
    fd = open(port, O_RDWR | O_NOCTTY);
    if (fd < 0)
        return luaL_error(L, "Cannot open %s: %s", port, strerror(errno));

    struct termios tty;
    if (tcgetattr(fd, &tty) != 0) {
        /* Leaving fd set here would let a later writeline() happily write to a
         * port we never managed to configure. */
        int e = errno;
        close(fd); fd = -1;
        return luaL_error(L, "tcgetattr failed: %s", strerror(e));
    }

    /* Input/output baud rate */
    cfsetispeed(&tty, speed);
    cfsetospeed(&tty, speed);

    /*
     * Raw mode: no canonical processing, no echo, no signals.
     * 8 data bits, no parity, 1 stop bit (8N1).
     * No hardware (RTS/CTS) or software (XON/XOFF) flow control.
     *
     * HUPCL is cleared deliberately, and it matters more than it looks.
     * "Hang up on last close" drops DTR when the port closes, and on every
     * Arduino-style board that line is wired to reset -- so closing the port
     * reboots the controller. With homing enabled that means each luaplot run
     * finds GRBL freshly booted and sitting in an alarm, refusing G-code until
     * it is homed again, which is a homing cycle per plot.
     *
     * Clearing it leaves DTR asserted through the close, so the controller
     * keeps running between invocations: home once, then plot as often as you
     * like. The very first connection still resets, since DTR has to be
     * asserted from idle at some point.
     */
    tty.c_cflag &= ~(PARENB | CSTOPB | CSIZE | CRTSCTS | HUPCL);
    tty.c_cflag |=  CS8 | CREAD | CLOCAL;
    tty.c_lflag &= ~(ICANON | ECHO | ECHOE | ISIG);
    tty.c_iflag &= ~(IXON | IXOFF | IXANY | ICRNL);
    tty.c_oflag &= ~OPOST;

    /*
     * VMIN=0, VTIME=10: read() returns after up to 1 second with whatever
     * bytes are available (or 0 if none). This gives us a natural timeout
     * if GRBL stops responding rather than hanging forever.
     */
    tty.c_cc[VMIN]  = 0;
    tty.c_cc[VTIME] = 10;   /* tenths of a second */

    if (tcsetattr(fd, TCSANOW, &tty) != 0) {
        int e = errno;
        close(fd); fd = -1;
        return luaL_error(L, "tcsetattr failed: %s", strerror(e));
    }

    /*
     * GRBL resets when the serial port opens (DTR line toggles on most
     * USB-serial adapters). Wait 2 seconds for it to boot and send its
     * version string, then flush so we start clean.
     */
    sleep(2);
    tcflush(fd, TCIOFLUSH);

    lua_pushboolean(L, 1);
    return 1;
}

/*
 * serial.writeline(str)
 *
 * Sends str followed by '\n', then blocks until GRBL replies "ok".
 * Status reports ("<...>") are skipped; "error:N" and "ALARM" raise a Lua
 * error, as does a port that stays silent past the reply timeout.
 *
 * GRBL responses:
 *   ok          — command accepted and queued
 *   error:N     — command rejected (bad G-code, alarm state, etc.)
 *   <...>       — status report (from ? query, not our concern here)
 */
static int l_writeline(lua_State *L) {
    const char *line = luaL_checkstring(L, 1);

    if (send_and_wait(L, line, 0) != 0)
        return lua_error(L);        /* message was pushed by send_and_wait */

    return 0;
}

/*
 * serial.query(cmd) -> { "line", "line", ... }
 *
 * Like writeline(), but returns every reply line GRBL sent before the "ok".
 * This is what makes GRBL's own settings readable:
 *
 *   local lines = serial.query("$$")   --> { "$0=10", "$1=25", ... }
 *   local info  = serial.query("$I")   --> { "[VER:1.1h.20190825:]", ... }
 *
 * Status reports are still filtered out. Returns an empty table for commands
 * that answer with a bare "ok".
 */
static int l_query(lua_State *L) {
    const char *cmd = luaL_checkstring(L, 1);

    lua_newtable(L);
    int tbl = lua_gettop(L);

    if (send_and_wait(L, cmd, tbl) != 0)
        return lua_error(L);

    return 1;
}

/*
 * serial.set_timeout(seconds) -> previous
 *
 * How long a command may leave the port silent before we give up on it.
 * Returns the previous value so callers can restore it:
 *
 *   local prev = serial.set_timeout(60)   -- $H homing can take 30 s
 *   serial.writeline("$H")
 *   serial.set_timeout(prev)
 */
static int l_set_timeout(lua_State *L) {
    int prev = reply_timeout;
    int secs = (int)luaL_checkinteger(L, 1);

    luaL_argcheck(L, secs > 0, 1, "timeout must be positive");
    reply_timeout = secs;

    lua_pushinteger(L, prev);
    return 1;
}

/*
 * serial.is_open() -> boolean
 */
static int l_is_open(lua_State *L) {
    lua_pushboolean(L, fd >= 0);
    return 1;
}

/*
 * serial.close()
 *
 * Closes the port. Safe to call even if not open.
 */
static int l_close(lua_State *L) {
    (void)L;
    if (fd >= 0) { close(fd); fd = -1; }
    return 0;
}

/* ── Module registration ──────────────────────────────────────────────────── */

static const luaL_Reg serial_lib[] = {
    {"open",        l_open},
    {"writeline",   l_writeline},
    {"query",       l_query},
    {"set_timeout", l_set_timeout},
    {"is_open",     l_is_open},
    {"close",       l_close},
    {NULL, NULL}
};

int luaopen_serial(lua_State *L) {
    luaL_newlib(L, serial_lib);
    return 1;
}
