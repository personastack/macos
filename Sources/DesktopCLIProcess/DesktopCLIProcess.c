#include "DesktopCLIProcess.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

typedef struct {
    int input[2], output[2], error[2], launch[2];
    int master, slave;
} ChildIO;

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

static int prepare_io(ChildIO *io, int terminal, uint16_t rows, uint16_t columns) {
    if (cloexec_pipe(io->launch)) return -1;
    if (!terminal) {
        return cloexec_pipe(io->input) || cloexec_pipe(io->output) || cloexec_pipe(io->error) ? -1 : 0;
    }
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    if (openpty(&io->master, &io->slave, NULL, NULL, &size)) return -1;
    if (fcntl(io->master, F_SETFD, FD_CLOEXEC) == -1 || fcntl(io->slave, F_SETFD, FD_CLOEXEC) == -1) return -1;
    return 0;
}

static void close_io(ChildIO *io) {
    for (int i = 0; i < 2; i++) {
        if (io->input[i] >= 0) close(io->input[i]);
        if (io->output[i] >= 0) close(io->output[i]);
        if (io->error[i] >= 0) close(io->error[i]);
        if (io->launch[i] >= 0) close(io->launch[i]);
    }
    if (io->master >= 0) close(io->master);
    if (io->slave >= 0) close(io->slave);
}

static _Noreturn void child_fail(int descriptor) {
    int error = errno;
    ssize_t ignored = write(descriptor, &error, sizeof(error));
    (void)ignored;
    _exit(127);
}

static _Noreturn void child_exec(const ChildIO *io, int descriptor_limit, int terminal,
                                 const char *cwd, const char *shell, char *const argv[], char *const env[]) {
    // Never run Foundation, Swift, allocation, or logging between fork and exec.
    close(io->launch[0]);
    if (setsid() == -1) child_fail(io->launch[1]);
    if (terminal && ioctl(io->slave, TIOCSCTTY, 0) == -1) child_fail(io->launch[1]);
    if (chdir(cwd) == -1) child_fail(io->launch[1]);
    if (dup2(terminal ? io->slave : io->input[0], STDIN_FILENO) == -1 ||
        dup2(terminal ? io->slave : io->output[1], STDOUT_FILENO) == -1 ||
        dup2(terminal ? io->slave : io->error[1], STDERR_FILENO) == -1) child_fail(io->launch[1]);
    if (dup2(io->launch[1], 3) == -1) child_fail(io->launch[1]);
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

static void terminate_launch(pid_t pid) {
    kill(-pid, SIGKILL);
    while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {}
}

static int launch_handshake(ChildIO *io) {
    close(io->launch[1]); io->launch[1] = -1;
    int error = 0;
    ssize_t bytes;
    do { bytes = read(io->launch[0], &error, sizeof(error)); } while (bytes == -1 && errno == EINTR);
    if (bytes == 0) return 0;
    return bytes == sizeof(error) ? error : EIO;
}

static int publish_io(ChildIO *io, int terminal, pid_t pid, PSDesktopCLIChild *child) {
    child->pid = pid;
    if (terminal) {
        child->output = io->master; io->master = -1;
        child->input = dup(child->output);
        child->error = -1;
        if (child->input == -1) {
            int error = errno;
            close(child->output);
            return error;
        }
        fcntl(child->input, F_SETFD, FD_CLOEXEC);
    } else {
        child->input = io->input[1]; io->input[1] = -1;
        child->output = io->output[0]; io->output[0] = -1;
        child->error = io->error[0]; io->error[0] = -1;
    }
    return 0;
}

int ps_desktop_cli_spawn(const char *shell, char *const argv[], char *const env[],
                         const char *cwd, int terminal, uint16_t rows, uint16_t columns,
                         PSDesktopCLIChild *child) {
    ChildIO io = {.input = {-1, -1}, .output = {-1, -1}, .error = {-1, -1}, .launch = {-1, -1}, .master = -1, .slave = -1};
    struct rlimit descriptors;
    if (getrlimit(RLIMIT_NOFILE, &descriptors)) return errno;
    int descriptor_limit = descriptors.rlim_cur > INT_MAX ? INT_MAX : (int)descriptors.rlim_cur;
    int result = 0;
    if (prepare_io(&io, terminal, rows, columns)) { result = errno; goto done; }
    pid_t pid = fork();
    if (pid == -1) { result = errno; goto done; }
    if (pid == 0) child_exec(&io, descriptor_limit, terminal, cwd, shell, argv, env);
    result = launch_handshake(&io);
    if (!result) result = publish_io(&io, terminal, pid, child);
    if (result) terminate_launch(pid);
done:
    close_io(&io);
    return result;
}
