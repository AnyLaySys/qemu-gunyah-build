#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>

typedef int (*connect_func)(int, const struct sockaddr *, socklen_t);

static connect_func real_connect_func(void)
{
    static connect_func fn;

    if (!fn) {
        fn = (connect_func)dlsym(RTLD_NEXT, "connect");
    }
    return fn;
}

static int make_path(char *out, size_t out_len, const char *dir,
                     const char *leaf)
{
    size_t dir_len;
    size_t leaf_len;
    int add_slash;

    if (!dir || !*dir) {
        return 0;
    }

    dir_len = strlen(dir);
    leaf_len = strlen(leaf);
    add_slash = dir[dir_len - 1] != '/';

    if (dir_len + add_slash + leaf_len + 1 > out_len) {
        errno = ENAMETOOLONG;
        return -1;
    }

    memcpy(out, dir, dir_len);
    if (add_slash) {
        out[dir_len++] = '/';
    }
    memcpy(out + dir_len, leaf, leaf_len + 1);
    return 1;
}

static int rewrite_path(const char *path, char *out, size_t out_len)
{
    const char *p;
    char dir[sizeof(((struct sockaddr_un *)0)->sun_path)];

    p = strstr(path, "/.X11-unix/");
    if (p) {
        const char *leaf = p + strlen("/.X11-unix/");
        const char *socket_dir = getenv("X11_SOCKET_DIR");
        const char *tmpdir = getenv("X11_TMPDIR");

        if (socket_dir && *socket_dir) {
            return make_path(out, out_len, socket_dir, leaf);
        }
        if (tmpdir && *tmpdir) {
            if (snprintf(dir, sizeof(dir), "%s/.X11-unix", tmpdir) >=
                (int)sizeof(dir)) {
                errno = ENAMETOOLONG;
                return -1;
            }
            return make_path(out, out_len, dir, leaf);
        }
        return 0;
    }

    p = strstr(path, "/.XIM-unix/");
    if (p) {
        const char *leaf = p + strlen("/.XIM-unix/");
        const char *socket_dir = getenv("XIM_SOCKET_DIR");
        const char *tmpdir = getenv("X11_TMPDIR");

        if (socket_dir && *socket_dir) {
            return make_path(out, out_len, socket_dir, leaf);
        }
        if (tmpdir && *tmpdir) {
            if (snprintf(dir, sizeof(dir), "%s/.XIM-unix", tmpdir) >=
                (int)sizeof(dir)) {
                errno = ENAMETOOLONG;
                return -1;
            }
            return make_path(out, out_len, dir, leaf);
        }
    }

    return 0;
}

int connect(int fd, const struct sockaddr *addr, socklen_t addrlen)
{
    struct sockaddr_un rewritten;
    char new_path[sizeof(rewritten.sun_path)];
    connect_func real_connect = real_connect_func();
    const struct sockaddr_un *un;
    int ret;

    if (!real_connect) {
        errno = ENOSYS;
        return -1;
    }

    if (!addr || addr->sa_family != AF_UNIX ||
        addrlen <= offsetof(struct sockaddr_un, sun_path)) {
        return real_connect(fd, addr, addrlen);
    }

    un = (const struct sockaddr_un *)addr;
    if (!un->sun_path[0]) {
        return real_connect(fd, addr, addrlen);
    }

    ret = rewrite_path(un->sun_path, new_path, sizeof(new_path));
    if (ret <= 0) {
        return ret < 0 ? -1 : real_connect(fd, addr, addrlen);
    }

    memset(&rewritten, 0, sizeof(rewritten));
    rewritten.sun_family = AF_UNIX;
    memcpy(rewritten.sun_path, new_path, strlen(new_path) + 1);

    return real_connect(fd, (const struct sockaddr *)&rewritten,
                        offsetof(struct sockaddr_un, sun_path) +
                        strlen(rewritten.sun_path) + 1);
}
