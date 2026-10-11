#include "den_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#include <sys/syscall.h>
#endif
#include <sys/wait.h>

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

int den_pidfd_open(pid_t pid) {
#if defined(__linux__) && defined(SYS_pidfd_open)
    return (int)syscall(SYS_pidfd_open, pid, 0);
#else
    (void)pid;
    errno = ENOSYS;
    return -1;
#endif
}

pid_t den_spawn_detached(const char *path, char *const argv[], const char *log_path) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid > 0) {
        int status = 0;
        // The intermediate child exits right away; reap it.
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        return pid;
    }
    // Intermediate child: new session, then fork again so the daemon is
    // re-parented to init and never gets a controlling terminal.
    if (setsid() < 0) _exit(1);
    signal(SIGHUP, SIG_IGN);
    pid_t daemon = fork();
    if (daemon != 0) _exit(daemon < 0 ? 1 : 0);
    int null_fd = open("/dev/null", O_RDWR);
    int log_fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (null_fd >= 0) dup2(null_fd, 0);
    if (log_fd >= 0) {
        dup2(log_fd, 1);
        dup2(log_fd, 2);
    }
    for (int fd = 3; fd < 1024; fd++) close(fd);
    signal(SIGHUP, SIG_DFL);
    execv(path, argv);
    _exit(127);
}
