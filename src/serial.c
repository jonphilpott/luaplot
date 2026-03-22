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

/* Single open file descriptor — one plotter at a time */
static int fd = -1;

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
 * Blocks until '\n' is received or the buffer fills.
 * Returns the number of characters in the line (excluding '\n').
 */
static int read_line(char *buf, int len) {
    int pos = 0;
    while (pos < len - 1) {
        char c;
        int n = (int)read(fd, &c, 1);
        if (n <= 0) break;          /* timeout or error — stop waiting */
        if (c == '\r') continue;    /* ignore CR in CRLF */
        if (c == '\n') break;       /* end of line */
        buf[pos++] = c;
    }
    buf[pos] = '\0';
    return pos;
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

    fd = open(port, O_RDWR | O_NOCTTY);
    if (fd < 0)
        return luaL_error(L, "Cannot open %s: %s", port, strerror(errno));

    struct termios tty;
    if (tcgetattr(fd, &tty) != 0)
        return luaL_error(L, "tcgetattr failed: %s", strerror(errno));

    /* Input/output baud rate */
    cfsetispeed(&tty, speed);
    cfsetospeed(&tty, speed);

    /*
     * Raw mode: no canonical processing, no echo, no signals.
     * 8 data bits, no parity, 1 stop bit (8N1).
     * No hardware (RTS/CTS) or software (XON/XOFF) flow control.
     */
    tty.c_cflag &= ~(PARENB | CSTOPB | CSIZE | CRTSCTS);
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

    if (tcsetattr(fd, TCSANOW, &tty) != 0)
        return luaL_error(L, "tcsetattr failed: %s", strerror(errno));

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
 * Sends str followed by '\n', then blocks reading responses until GRBL
 * sends a line starting with "ok". Lines starting with "<" are GRBL
 * status reports and are silently skipped. Lines starting with "error"
 * cause a Lua error.
 *
 * GRBL responses:
 *   ok          — command accepted and queued
 *   error:N     — command rejected (bad G-code, alarm state, etc.)
 *   <...>       — status report (from ? query, not our concern here)
 */
static int l_writeline(lua_State *L) {
    const char *line = luaL_checkstring(L, 1);

    if (fd < 0)
        return luaL_error(L, "Serial port is not open");

    /* Send the command */
    char buf[256];
    int  len = snprintf(buf, sizeof(buf), "%s\n", line);
    if (write(fd, buf, (size_t)len) < 0)
        return luaL_error(L, "Write failed: %s", strerror(errno));

    /* Wait for ok (or error) */
    char resp[64];
    while (1) {
        int n = read_line(resp, sizeof(resp));

        if (n == 0) continue;                          /* empty line, keep waiting */
        if (resp[0] == '<') continue;                  /* status report, ignore */
        if (strncmp(resp, "ok", 2) == 0) break;        /* success */
        if (strncmp(resp, "error", 5) == 0)
            return luaL_error(L, "GRBL error: %s (sent: %s)", resp, line);
    }

    return 0;
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
    {"open",      l_open},
    {"writeline", l_writeline},
    {"close",     l_close},
    {NULL, NULL}
};

int luaopen_serial(lua_State *L) {
    luaL_newlib(L, serial_lib);
    return 1;
}
