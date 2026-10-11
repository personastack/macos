#pragma once
#include <stdint.h>
#include <sys/types.h>

typedef struct {
    pid_t pid;
    int input;
    int output;
    int error;
} PSDesktopCLIChild;

// The child performs only async-signal-safe syscalls between fork and exec.
int ps_desktop_cli_spawn(const char *shell, char *const argv[], char *const env[],
                         const char *cwd, int terminal, uint16_t rows, uint16_t columns,
                         PSDesktopCLIChild *child);
