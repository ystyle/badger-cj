#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/io_uring.h>
int main() {
    struct io_uring_params p;
    memset(&p, 0, sizeof(p));
    long ret = syscall(__NR_io_uring_setup, 8, &p);
    if (ret < 0) { printf("io_uring_setup FAILED: errno=%d (%s)\n", errno, strerror(errno)); return 1; }
    printf("io_uring_setup OK: fd=%ld\n", ret);
    close(ret); return 0;
}
