/* zygote32_exec: the guest's 32-bit zygote (the service init calls zygote_secondary).
 *
 * The 64-bit counterpart of this is assets/zygote_exec: create the zygote and usap
 * sockets on fds 3 and 4, point stdio at /dev/null and exec the runtime. Without
 * this the host's 32-bit zygote keeps serving zygote_secondary, so 32-bit processes
 * (WebView's renderers among them) ran One UI's framework under the guest's
 * system_server and died on the first IApplicationThread call.
 *
 * master_inner.sh passes ANDROID_SOCKET_zygote_secondary=3 and
 * ANDROID_SOCKET_usap_pool_secondary=4 in the environment.
 *
 * aarch64-linux-gnu-gcc -static -nostdlib -ffreestanding -fno-stack-protector -Os \
 *     -s -o assets/zygote32_exec tools/zygote32_exec.c
 */
#define AT_FDCWD (-100)
#define AF_UNIX 1
#define SOCK_STREAM 1
#define O_RDWR 2
#define AID_SYSTEM 1000

static long sys(long n, long a, long b, long c, long d, long e) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    register long x3 __asm__("x3") = d;
    register long x4 __asm__("x4") = e;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
    return x0;
}
#define dup3(a, b)          sys(24, (a), (b), 0, 0, 0)
#define unlinkat(p)         sys(35, AT_FDCWD, (long)(p), 0, 0, 0)
#define fchmodat(p, m)      sys(53, AT_FDCWD, (long)(p), (m), 0, 0)
#define fchownat(p, u, g)   sys(54, AT_FDCWD, (long)(p), (u), (g), 0)
#define openat(p, f, m)     sys(56, AT_FDCWD, (long)(p), (f), (m), 0)
#define close(fd)           sys(57, (fd), 0, 0, 0, 0)
#define exit_(c)            sys(93, (c), 0, 0, 0, 0)
#define setpgid0()          sys(154, 0, 0, 0, 0, 0)
#define socket_()           sys(198, AF_UNIX, SOCK_STREAM, 0, 0, 0)
#define bind_(fd, a, l)     sys(200, (fd), (long)(a), (l), 0, 0)
#define listen_(fd)         sys(201, (fd), 10, 0, 0, 0)
#define execve_(p, a, e)    sys(221, (long)(p), (long)(a), (long)(e), 0, 0)

/* gcc emits calls to these even in freestanding code. */
void *memset(void *d, int c, unsigned long n) {
    volatile char *p = d;
    while (n--) *p++ = c;
    return d;
}
void *memcpy(void *d, const void *s, unsigned long n) {
    volatile char *p = d;
    const volatile char *q = s;
    while (n--) *p++ = *q++;
    return d;
}

static void on_fd(long fd, long want) {
    if (fd != want) {
        dup3(fd, want);
        close(fd);
    }
}

static void make_socket(const char *path, long want) {
    struct { unsigned short family; char path[108]; } addr = { AF_UNIX, {0} };
    long len = 0;
    while (path[len]) {
        addr.path[len] = path[len];
        len++;
    }
    unlinkat(path);
    on_fd(socket_(), want);
    if (bind_(want, &addr, sizeof(addr)) < 0 || listen_(want) < 0)
        exit_(1);
    fchmodat(path, 0660);
    fchownat(path, 0, AID_SYSTEM);
}

__attribute__((used)) void entry(long *sp) {
    char **envp = (char **)(sp + 2 + sp[0]);
    static char *const argv[] = {
        "zygote", "-Xzygote", "-Xforcejitzygote", "/system/bin", "--zygote",
        "--socket-name=zygote_secondary", "--enable-lazy-preload", 0,
    };
    setpgid0();
    make_socket("/dev/socket/zygote_secondary", 3);
    make_socket("/dev/socket/usap_pool_secondary", 4);

    /* No log file: zygote aborts its first fork on any fd outside its allowlist. */
    long null = openat("/dev/null", O_RDWR, 0);
    dup3(null, 0);
    dup3(null, 1);
    dup3(null, 2);
    close(null);

    execve_("/system/bin/app_process32", argv, envp);
    exit_(127);
}

__asm__(".globl _start\n_start:\n  mov x0, sp\n  bl entry\n");
