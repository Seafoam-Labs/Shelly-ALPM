#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

/* Keep the descriptor open while checking identity: the inode cannot be reused.
 * This protects cooperating writers, not an adversary racing stat and unlink. */
int rlpm_lock_acquire(const char *path, int *fd) {
    int result;
    do
        result = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0000);
    while (result < 0 && errno == EINTR);
    if (result < 0)
        return errno;
    *fd = result;
    return 0;
}

int rlpm_lock_check(const char *path, int fd) {
    struct stat owned, current;
    if (fstat(fd, &owned) < 0)
        return errno;
    if (lstat(path, &current) < 0)
        return errno;
    if (owned.st_dev != current.st_dev || owned.st_ino != current.st_ino)
        return ESTALE;
    return 0;
}

int rlpm_lock_release(const char *path, int fd) {
    int result = rlpm_lock_check(path, fd);
    if (!result && unlink(path) < 0)
        result = errno;
    /* Do not retry close on Linux: an EINTR has already closed the descriptor. */
    if (close(fd) < 0 && !result)
        result = errno;
    return result == ENOENT ? 0 : result;
}
