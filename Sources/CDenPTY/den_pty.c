#include "den_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t den_spawn_pty(const char *path, char *const argv[], char *const envp[],
                    const char *cwd, unsigned short cols, unsigned short rows,
                    unsigned short width_px, unsigned short height_px,
                    int *out_master) {
    struct winsize ws = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = width_px,
        .ws_ypixel = height_px,
    };
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) return -1;

    if (pid == 0) {
        // Child: restore default signal dispositions inherited from the server.
        signal(SIGCHLD, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        if (cwd != NULL) (void)chdir(cwd);
        execve(path, argv, envp);
        _exit(127);
    }

    int flags = fcntl(master, F_GETFD);
    if (flags >= 0) fcntl(master, F_SETFD, flags | FD_CLOEXEC);
    flags = fcntl(master, F_GETFL);
    if (flags >= 0) fcntl(master, F_SETFL, flags | O_NONBLOCK);
    *out_master = master;
    return pid;
}

int den_pty_resize(int master, unsigned short cols, unsigned short rows,
                   unsigned short width_px, unsigned short height_px) {
    struct winsize ws = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = width_px,
        .ws_ypixel = height_px,
    };
    return ioctl(master, TIOCSWINSZ, &ws);
}

pid_t den_pty_foreground(int master) { return tcgetpgrp(master); }
