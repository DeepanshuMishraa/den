#ifndef DEN_PTY_H
#define DEN_PTY_H

#include <sys/types.h>

/// Forks a child attached to a new pseudo-terminal and execs `path`.
///
/// Only async-signal-safe calls run between fork and exec, which is why this
/// lives in C rather than Swift. Returns the child pid and stores the PTY
/// master fd in `out_master`, or returns -1 with errno set.
pid_t den_spawn_pty(const char *path,
                    char *const argv[],
                    char *const envp[],
                    const char *cwd,
                    unsigned short cols,
                    unsigned short rows,
                    unsigned short width_px,
                    unsigned short height_px,
                    int *out_master);

/// Sets the PTY window size. Returns 0 on success, -1 with errno set.
int den_pty_resize(int master, unsigned short cols, unsigned short rows,
                   unsigned short width_px, unsigned short height_px);

/// Process group currently in the PTY foreground, or -1.
pid_t den_pty_foreground(int master);

#endif
