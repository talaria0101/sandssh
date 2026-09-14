/* fakepty.c — make a pipe-backed shell believe it has a terminal.
 *
 * For environments where the kernel offers no /dev/ptmx (sealed cages,
 * seccomp profiles without mknod/devpts, some CI sandboxes). Interposes
 * isatty/tcgetattr/tcsetattr/ioctl(TCGETS|TCSETS|TIOCGWINSZ|TIOCGPGRP)
 * for fds 0-2 so bash+readline provide echo and line editing over pipes.
 * Every other request passes through to libc.
 *
 * Build: gcc -shared -fPIC -O2 -o fakepty.so fakepty.c
 * Use:   LD_PRELOAD=./fakepty.so bash -i
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

static int fakefd(int fd) { return fd == 0 || fd == 1 || fd == 2; }

int isatty(int fd) {
    static int (*real)(int);
    if (!real) real = dlsym(RTLD_NEXT, "isatty");
    if (fakefd(fd)) return 1;
    return real(fd);
}

char *ttyname(int fd) {
    static char *(*real)(int);
    if (!real) real = dlsym(RTLD_NEXT, "ttyname");
    if (fakefd(fd)) return "/dev/pts/0";
    return real(fd);
}

int tcgetattr(int fd, struct termios *t) {
    if (fakefd(fd)) {
        memset(t, 0, sizeof(*t));
        t->c_iflag = ICRNL | IXON | BRKINT;
        t->c_oflag = OPOST | ONLCR;
        t->c_cflag = CS8 | CREAD | CLOCAL;
        t->c_lflag = ICANON | ECHO | ECHOE | ECHOK | ISIG | IEXTEN;
        t->c_cc[VMIN] = 1; t->c_cc[VTIME] = 0;
        return 0;
    }
    int (*r)(int, struct termios *) = dlsym(RTLD_NEXT, "tcgetattr");
    return r(fd, t);
}

int tcsetattr(int fd, int act, const struct termios *t) {
    (void)act; (void)t;
    if (fakefd(fd)) return 0;
    int (*r)(int, int, const struct termios *) = dlsym(RTLD_NEXT, "tcsetattr");
    return r(fd, act, t);
}

int ioctl(int fd, unsigned long req, ...) {
    va_list ap; void *arg;
    va_start(ap, req); arg = va_arg(ap, void *); va_end(ap);
    if (fakefd(fd)) {
        switch (req) {
        case TCGETS: {
            struct termios t;
            tcgetattr(fd, &t);
            if (arg) memcpy(arg, &t, sizeof(t));
            return 0;
        }
        case TCSETS: case TCSETSW: case TCSETSF:
            return 0;
        case TIOCGWINSZ: {
            struct winsize *w = arg;
            if (w) { w->ws_row = 24; w->ws_col = 80; w->ws_xpixel = 0; w->ws_ypixel = 0; }
            return 0;
        }
        case TIOCSWINSZ:
            return 0;
        case TIOCGPGRP: {
            pid_t *p = arg;
            if (p) *p = getpgrp();
            return 0;
        }
        case TIOCSPGRP:
            return 0;
        }
    }
    int (*r)(int, unsigned long, ...) = dlsym(RTLD_NEXT, "ioctl");
    return r(fd, req, arg);
}
