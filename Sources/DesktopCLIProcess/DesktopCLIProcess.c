#include "DesktopCLIProcess.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <limits.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static int cloexec_pipe(int pair[2]) {
    if (pipe(pair)) return -1;
    if (fcntl(pair[0], F_SETFD, FD_CLOEXEC) == -1 || fcntl(pair[1], F_SETFD, FD_CLOEXEC) == -1) {
        int error = errno;
        close(pair[0]); close(pair[1]);
        pair[0] = pair[1] = -1;
        errno = error;
        return -1;
    }
    return 0;
}

static void child_fail(int descriptor) {
    int error = errno;
    ssize_t ignored = write(descriptor, &error, sizeof(error));
    (void)ignored;
    _exit(127);
}

int ps_desktop_cli_spawn(const char *shell, char *const argv[], char *const env[],
                         const char *cwd, int terminal, uint16_t rows, uint16_t columns,
                         PSDesktopCLIChild *child) {
    int input[2] = {-1, -1}, output[2] = {-1, -1}, error[2] = {-1, -1};
    int launch[2] = {-1, -1}, master = -1, slave = -1, result = 0;
    struct rlimit descriptors;
    if (getrlimit(RLIMIT_NOFILE, &descriptors)) return errno;
    int descriptor_limit = descriptors.rlim_cur > INT_MAX ? INT_MAX : (int)descriptors.rlim_cur;
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    if (cloexec_pipe(launch)) { result = errno; goto done; }
    if (terminal) {
        if (openpty(&master, &slave, NULL, NULL, &size)) { result = errno; goto done; }
        if (fcntl(master, F_SETFD, FD_CLOEXEC) == -1 || fcntl(slave, F_SETFD, FD_CLOEXEC) == -1) {
            result = errno; goto done;
        }
    } else if (cloexec_pipe(input) || cloexec_pipe(output) || cloexec_pipe(error)) {
        result = errno; goto done;
    }
    pid_t pid = fork();
    if (pid == -1) { result = errno; goto done; }
    if (pid == 0) {
        // Never run Foundation or Swift in this child. A session owns its entire group.
        close(launch[0]);
        if (setsid() == -1) child_fail(launch[1]);
        if (terminal && ioctl(slave, TIOCSCTTY, 0) == -1) child_fail(launch[1]);
        if (chdir(cwd) == -1) child_fail(launch[1]);
        if (dup2(terminal ? slave : input[0], STDIN_FILENO) == -1 ||
            dup2(terminal ? slave : output[1], STDOUT_FILENO) == -1 ||
            dup2(terminal ? slave : error[1], STDERR_FILENO) == -1) child_fail(launch[1]);
        if (dup2(launch[1], 3) == -1) child_fail(launch[1]);
        if (fcntl(3, F_SETFD, FD_CLOEXEC) == -1) child_fail(3);
        for (int descriptor = 4; descriptor < descriptor_limit; descriptor++) close(descriptor);
        // The app ignores SIGPIPE. Restore ordinary child signal semantics.
        struct sigaction action = {0};
        action.sa_handler = SIG_DFL;
        sigemptyset(&action.sa_mask);
        for (int number = 1; number < NSIG; number++) sigaction(number, &action, NULL);
        sigset_t mask;
        sigemptyset(&mask);
        sigprocmask(SIG_SETMASK, &mask, NULL);
        execve(shell, argv, env);
        child_fail(3);
    }
    close(launch[1]); launch[1] = -1;
    int launch_error = 0;
    ssize_t bytes;
    do { bytes = read(launch[0], &launch_error, sizeof(launch_error)); } while (bytes == -1 && errno == EINTR);
    if (bytes != 0) {
        result = bytes == sizeof(launch_error) ? launch_error : EIO;
        kill(-pid, SIGKILL);
        while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {}
        goto done;
    }
    child->pid = pid;
    if (terminal) {
        child->output = master; master = -1;
        child->input = dup(child->output);
        child->error = -1;
        if (child->input == -1) {
            result = errno; close(child->output); kill(-pid, SIGKILL);
            while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {}
            goto done;
        }
        fcntl(child->input, F_SETFD, FD_CLOEXEC);
    } else {
        child->input = input[1]; input[1] = -1;
        child->output = output[0]; output[0] = -1;
        child->error = error[0]; error[0] = -1;
    }
done:
    for (int i = 0; i < 2; i++) {
        if (input[i] >= 0) close(input[i]);
        if (output[i] >= 0) close(output[i]);
        if (error[i] >= 0) close(error[i]);
        if (launch[i] >= 0) close(launch[i]);
    }
    if (master >= 0) close(master);
    if (slave >= 0) close(slave);
    return result;
}
