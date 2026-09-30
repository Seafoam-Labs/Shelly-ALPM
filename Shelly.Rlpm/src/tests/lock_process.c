#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

/* Independent POSIX writer, in a different process. Child executes only
 * async-signal-safe libc calls after fork; no inherited Zig allocator/Io. */
int rlpm_test_contender(const char *path) {
    pid_t child = fork();
    if (child < 0)
        return -1;
    if (!child) {
        int fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0000);
        if (fd >= 0) {
            close(fd);
            unlink(path);
            _exit(2);
        }
        _exit(errno == EEXIST ? 0 : 3);
    }
    int status;
    while (waitpid(child, &status, 0) < 0)
        if (errno != EINTR)
            return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

int rlpm_test_writer(const char *path, int *writer, int *signal_fd) {
    int ready[2], done[2];
    if (pipe(ready) < 0)
        return -1;
    if (pipe(done) < 0) {
        close(ready[0]);
        close(ready[1]);
        return -1;
    }
    pid_t child = fork();
    if (child < 0) {
        close(ready[0]);
        close(ready[1]);
        close(done[0]);
        close(done[1]);
        return -1;
    }
    if (!child) {
        close(ready[0]);
        close(done[1]);
        int fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0000);
        char status = fd < 0 ? 1 : 0;
        if (write(ready[1], &status, 1) != 1 || status)
            _exit(1);
        close(ready[1]);
        while (read(done[0], &status, 1) < 0)
            if (errno != EINTR)
                _exit(2);
        close(done[0]);
        close(fd);
        _exit(unlink(path) == 0 ? 0 : 3);
    }
    close(ready[1]);
    close(done[0]);
    char status = 1;
    ssize_t count;
    do
        count = read(ready[0], &status, 1);
    while (count < 0 && errno == EINTR);
    close(ready[0]);
    if (count != 1 || status) {
        close(done[1]);
        waitpid(child, 0, 0);
        return -1;
    }
    *writer = child;
    *signal_fd = done[1];
    return 0;
}

int rlpm_test_finish_writer(int child, int fd) {
    close(fd); /* EOF releases child, including when parent work failed. */
    int status;
    while (waitpid(child, &status, 0) < 0)
        if (errno != EINTR)
            return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}
