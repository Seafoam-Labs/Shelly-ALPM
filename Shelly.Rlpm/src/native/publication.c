#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

int rlpm_directory_lock(const char *path, int exclusive, int nonblock) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | (nonblock ? LOCK_NB : 0))) {
        close(fd);
        return -1;
    }
    return fd;
}

int rlpm_private_directory(const char *path) {
    if (mkdir(path, 0700) && errno != EEXIST)
        return -1;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
        return -1;
    struct stat st;
    int ok = fstat(fd, &st) == 0 && st.st_uid == getuid() && (st.st_mode & 0777) == 0700;
    close(fd);
    return ok ? 0 : -1;
}

#include <pwd.h>
/* Called only for a newly created, parent-owned private worker directory. */
int rlpm_worker_directory(const char *path, const char *user) {
    struct passwd storage, *pw = NULL;
    char buffer[16384];
    if (getpwnam_r(user, &storage, buffer, sizeof(buffer), &pw) || !pw)
        return -1;
    return chown(path, pw->pw_uid, pw->pw_gid);
}

#include <poll.h>
int rlpm_worker_read(int fd, void *bytes, unsigned long count) {
    struct pollfd descriptor = {.fd = fd, .events = POLLIN};
    int ready = poll(&descriptor, 1, 20);
    if (ready == 0 || (ready < 0 && errno == EINTR))
        return -2;
    if (ready < 0)
        return -1;
    ssize_t n = read(fd, bytes, count);
    return n < 0 && errno == EINTR ? -2 : (int)n;
}
