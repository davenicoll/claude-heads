#ifndef CPTY_HELPERS_H
#define CPTY_HELPERS_H

#include <sys/ioctl.h>

/// Sets the window size on a PTY file descriptor.
/// Returns 0 on success, -1 on failure (with errno set).
static inline int pty_set_window_size(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

#endif /* CPTY_HELPERS_H */
