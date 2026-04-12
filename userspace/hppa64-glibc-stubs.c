/* Comprehensive glibc internal stubs for hppa64 static linking.
 *
 * glibc's libc.a on hppa64 was never properly built for static linking.
 * It references dynamic linker internals (_dl_*), hidden string functions,
 * and TLS infrastructure that don't exist in a static binary.
 *
 * This file provides minimal stubs to satisfy the linker.
 * Combined with the patched binutils (TPREL/PLABEL32 relocation support),
 * this enables static linking on hppa64.
 */
/* Avoid including glibc headers that conflict with our stub declarations */
typedef unsigned long size_t;
typedef long ssize_t;
struct utsname;

/* From mman.h - needed for malloc */
#define PROT_READ    0x1
#define PROT_WRITE   0x2
#define MAP_PRIVATE  0x02
#define MAP_ANONYMOUS 0x20
#define MAP_FAILED   ((void *)-1)
void *mmap(void *, size_t, int, int, int, long);
void *memcpy(void *, const void *, size_t);

/* ======== hppa64 syscall ABI ======== */
/* Syscall number in r20, args in r26,r25,r24,r23 (reversed from other arches)
   Return in r28. Gateway at 0x100 in space register 2. */

static long _sc0(long nr) {
    register long r20 __asm__("r20") = nr;
    register long ret __asm__("r28");
    __asm__ volatile("ble 0x100(%%sr2,%%r0)\n\tnop"
        : "=r"(ret) : "r"(r20) : "r1", "r2", "r29", "r31", "memory");
    return ret;
}
static long _sc1(long nr, long a1) {
    register long r20 __asm__("r20") = nr;
    register long r26 __asm__("r26") = a1;
    register long ret __asm__("r28");
    __asm__ volatile("ble 0x100(%%sr2,%%r0)\n\tnop"
        : "=r"(ret) : "r"(r20), "r"(r26) : "r1", "r2", "r29", "r31", "memory");
    return ret;
}
static long _sc2(long nr, long a1, long a2) {
    register long r20 __asm__("r20") = nr;
    register long r26 __asm__("r26") = a1;
    register long r25 __asm__("r25") = a2;
    register long ret __asm__("r28");
    __asm__ volatile("ble 0x100(%%sr2,%%r0)\n\tnop"
        : "=r"(ret) : "r"(r20), "r"(r26), "r"(r25) : "r1", "r2", "r29", "r31", "memory");
    return ret;
}
static long _sc3(long nr, long a1, long a2, long a3) {
    register long r20 __asm__("r20") = nr;
    register long r26 __asm__("r26") = a1;
    register long r25 __asm__("r25") = a2;
    register long r24 __asm__("r24") = a3;
    register long ret __asm__("r28");
    __asm__ volatile("ble 0x100(%%sr2,%%r0)\n\tnop"
        : "=r"(ret) : "r"(r20), "r"(r26), "r"(r25), "r"(r24) : "r1", "r2", "r29", "r31", "memory");
    return ret;
}
static long _sc4(long nr, long a1, long a2, long a3, long a4) {
    register long r20 __asm__("r20") = nr;
    register long r26 __asm__("r26") = a1;
    register long r25 __asm__("r25") = a2;
    register long r24 __asm__("r24") = a3;
    register long r23 __asm__("r23") = a4;
    register long ret __asm__("r28");
    __asm__ volatile("ble 0x100(%%sr2,%%r0)\n\tnop"
        : "=r"(ret) : "r"(r20), "r"(r26), "r"(r25), "r"(r24), "r"(r23) : "r1", "r2", "r29", "r31", "memory");
    return ret;
}
static long _sc5(long nr, long a1, long a2, long a3, long a4, long a5) {
    register long r20 __asm__("r20") = nr;
    register long r26 __asm__("r26") = a1;
    register long r25 __asm__("r25") = a2;
    register long r24 __asm__("r24") = a3;
    register long r23 __asm__("r23") = a4;
    register long r22 __asm__("r22") = a5;
    register long ret __asm__("r28");
    __asm__ volatile("ble 0x100(%%sr2,%%r0)\n\tnop"
        : "=r"(ret) : "r"(r20), "r"(r26), "r"(r25), "r"(r24), "r"(r23), "r"(r22) : "r1", "r2", "r29", "r31", "memory");
    return ret;
}

/* hppa syscall numbers (from asm/unistd.h) */
#define __NR_exit           1
#define __NR_fork           2
#define __NR_write          4
#define __NR_close          6
#define __NR_execve         11
#define __NR_chdir          12
#define __NR_chmod          15
#define __NR_getpid         20
#define __NR_mount          21
#define __NR_umask          60
#define __NR_chroot         61
#define __NR_dup            41
#define __NR_pipe           42
#define __NR_getgid         47
#define __NR_signal         48
#define __NR_geteuid        49
#define __NR_getegid        50
#define __NR_kill           37
#define __NR_mkdirat        276 /* via openat family */
#define __NR_alarm          27
#define __NR_getuid         24
#define __NR_uname          59
#define __NR_munmap         91
#define __NR_mprotect       125
#define __NR_getpgid        132
#define __NR_setsid         66
#define __NR_setpgid        57
#define __NR_personality    136
#define __NR_sysinfo        116
#define __NR_prctl          172
#define __NR_getppid        64
#define __NR_vfork          113
#define __NR_madvise        233
#define __NR_mincore        72
#define __NR_mlock          150
#define __NR_munlock        151
#define __NR_getgroups      80
#define __NR_pipe2          313
#define __NR_chown          180
#define __NR_fchmod         94
#define __NR_fchown         95
#define __NR_lchown         16
#define __NR_fchownat       278
#define __NR_unlinkat       281
#define __NR_linkat         283
#define __NR_symlinkat      282
#define __NR_setns          328
#define __NR_unshare        288
#define __NR_getresuid      165
#define __NR_getresgid      171
#define __NR_setxattr        229
#define __NR_lsetxattr       230
#define __NR_fsetxattr       231
#define __NR_getxattr        232
#define __NR_removexattr     235
#define __NR_lremovexattr    236
#define __NR_fremovexattr    237
#define __NR_gettid          206
#define __NR_socket          17
#define __NR_bind            22  /* These are actually socketcall sub-numbers */
#define __NR_getsockname     6
#define __NR_getpeername     7
#define __NR_fchdir          133
#define __NR_sched_setscheduler 141
#define __NR_sched_getscheduler 142
#define __NR_sched_setparam  140
#define __NR_sched_getparam  143
#define __NR_sched_get_priority_max 159
#define __NR_sched_get_priority_min 160

/* ======== Dynamic linker stubs ======== */
unsigned long _dl_pagesize = 4096;
int _dl_clktck = 100;
int _dl_debug_mask = 0;
int __libc_enable_secure = 0;
unsigned long _dl_minsigstacksize = 2048;
int _dl_ns = 0;
void *_dl_phdr = 0;
int _dl_phnum = 0;
int _dl_stack_prot_flags = 0;
void *_dl_stack_cache = 0;
unsigned long _dl_stack_cache_actsize = 0;
int _dl_stack_cache_lock = 0;
void *_dl_stack_used = 0;
void *_dl_stack_user = 0;
int _dl_in_flight_stack = 0;
int _dl_load_lock = 0;
int _dl_load_tls_lock = 0;
void *_dl_vdso_clock_gettime = 0;
int __nss_not_use_nscd_group = 1;
int __nss_not_use_nscd_passwd = 1;
int __tunable_is_initialized = 0;

void _dl_debug_printf(const char *fmt, ...) { }
void _dl_allocate_tls_init(void *p) { }
void *_dl_early_allocate(unsigned long sz) { return 0; }
void _dl_deallocate_tls(void *p, int d) { }
void _dl_determine_tlsoffset(void) { }
void _dl_tls_static_surplus_init(void) { }
void __tls_init_tp(void) { }
void __tls_pre_init_tp(void) { }
void __atomic_link_error(void) { }
void __cxa_thread_atexit_impl(void) { }
void __syscall_cancel_arch(void) { }
int __tunable_get_val(void) { return 0; }
int __readonly_area(const void *p, unsigned long s) { return 0; }
void __chk_fail(void) { _sc1(__NR_exit, 127); __builtin_unreachable(); }
void __nscd_getgrgid_r(void) { }
void __nscd_getgrnam_r(void) { }
void __nscd_getpwnam_r(void) { }
void *__libc_dlopen_mode(const char *n, int m) { return 0; }
void *__libc_dlsym(void *h, const char *s) { return 0; }
void __libc_dlclose(void *h) { }

/* printf float formatting stubs - not needed for LTP mm tests */
void __printf_fp_l_buffer(void) { }
void __printf_fphex_l_buffer(void) { }
void __wprintf_fp_l_buffer(void) { }
void __wprintf_fphex_l_buffer(void) { }
void __mpn_construct_double(void) { }
void __mpn_construct_float(void) { }
double __strtod_nan(const char *s, char **e, char c) { return 0.0; }
float __strtof_nan(const char *s, char **e, char c) { return 0.0f; }

/* ======== Hidden string functions ======== */
int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}
int strncmp(const char *a, const char *b, size_t n) {
    while (n && *a && *a == *b) { a++; b++; n--; }
    return n ? (unsigned char)*a - (unsigned char)*b : 0;
}
size_t strlen(const char *s) {
    const char *p = s; while (*p) p++; return p - s;
}
void *__rawmemchr(const void *s, int c) {
    const unsigned char *p = s;
    while (*p != (unsigned char)c) p++;
    return (void *)p;
}
/* memchr - avoid name clash with glibc's _Generic macro */
__attribute__((visibility("default")))
void *__memchr(const void *s, int c, size_t n) {
    const unsigned char *p = s;
    while (n--) { if (*p == (unsigned char)c) return (void *)p; p++; }
    return 0;
}
/* Provide the symbol 'memchr' via alias to bypass the macro */
void *memchr(const void *, int, size_t) __attribute__((alias("__memchr")));
void *__memrchr(const void *s, int c, size_t n) {
    const unsigned char *p = (const unsigned char *)s + n;
    while (n--) { p--; if (*p == (unsigned char)c) return (void *)p; }
    return 0;
}
char *__stpcpy(char *d, const char *s) {
    while ((*d = *s)) { d++; s++; } return d;
}
char *strchrnul(const char *s, int c) {
    while (*s && *s != (char)c) s++;
    return (char *)s;
}
char *__strchrnul(const char *s, int c) {
    return strchrnul(s, c);
}

/* ======== Syscall wrappers (hidden glibc symbols) ======== */
unsigned int alarm(unsigned int s) { return _sc1(__NR_alarm, s); }
int chdir(const char *p) { return _sc1(__NR_chdir, (long)p); }
int __chdir(const char *p) { return chdir(p); }
int __fchdir(int fd) { return _sc1(__NR_fchdir, fd); }
int chown(const char *p, unsigned int u, unsigned int g) { return _sc3(__NR_chown, (long)p, u, g); }
int chroot(const char *p) { return _sc1(__NR_chroot, (long)p); }
int dup(int fd) { return _sc1(__NR_dup, fd); }
int __dup(int fd) { return dup(fd); }
int fchmod(int fd, unsigned int m) { return _sc2(__NR_fchmod, fd, m); }
int fchown(int fd, unsigned int u, unsigned int g) { return _sc3(__NR_fchown, fd, u, g); }
int fchownat(int d, const char *p, unsigned int u, unsigned int g, int f) { return _sc5(__NR_fchownat, d, (long)p, u, g, f); }
int lchown(const char *p, unsigned int u, unsigned int g) { return _sc3(__NR_lchown, (long)p, u, g); }
int getpid(void) { return _sc0(__NR_getpid); }
int __getpid(void) { return getpid(); }
int __gettid(void) { return _sc0(__NR_gettid); }
int getppid(void) { return _sc0(__NR_getppid); }
unsigned int getuid(void) { return _sc0(__NR_getuid); }
unsigned int __getuid(void) { return getuid(); }
unsigned int geteuid(void) { return _sc0(__NR_geteuid); }
unsigned int __geteuid(void) { return geteuid(); }
unsigned int getgid(void) { return _sc0(__NR_getgid); }
unsigned int __getgid(void) { return getgid(); }
unsigned int __getegid(void) { return _sc0(__NR_getegid); }
int getpgid(int p) { return _sc1(__NR_getpgid, p); }
int __getpgid(int p) { return getpgid(p); }
int setpgid(int p, int g) { return _sc2(__NR_setpgid, p, g); }
int __setpgid(int p, int g) { return setpgid(p, g); }
int setsid(void) { return _sc0(__NR_setsid); }
int __setsid(void) { return setsid(); }
int kill(int p, int s) { return _sc2(__NR_kill, p, s); }
int mount(const char *s, const char *t, const char *fs, unsigned long f, const void *d) { return _sc5(__NR_mount, (long)s, (long)t, (long)fs, f, (long)d); }
unsigned int umask(unsigned int m) { return _sc1(__NR_umask, m); }
int uname(struct utsname *b) { return _sc1(__NR_uname, (long)b); }
int __uname(struct utsname *b) { return uname(b); }
int personality(unsigned long p) { return _sc1(__NR_personality, p); }
int sysinfo(void *i) { return _sc1(__NR_sysinfo, (long)i); }
int __sysinfo(void *i) { return sysinfo(i); }
int prctl(int o, unsigned long a2, unsigned long a3, unsigned long a4, unsigned long a5) { return _sc5(__NR_prctl, o, a2, a3, a4, a5); }
int mprotect(void *a, size_t l, int p) { return _sc3(__NR_mprotect, (long)a, l, p); }
int __mprotect(void *a, size_t l, int p) { return mprotect(a, l, p); }
int madvise(void *a, size_t l, int ad) { return _sc3(__NR_madvise, (long)a, l, ad); }
int __madvise(void *a, size_t l, int ad) { return madvise(a, l, ad); }
int mincore(void *a, size_t l, unsigned char *v) { return _sc3(__NR_mincore, (long)a, l, (long)v); }
int mlock(const void *a, size_t l) { return _sc2(__NR_mlock, (long)a, l); }
int munlock(const void *a, size_t l) { return _sc2(__NR_munlock, (long)a, l); }
int mlockall(int f) { return _sc1(152, f); }    /* __NR_mlockall = 152 on hppa */
int munlockall(void) { return _sc0(153); }       /* __NR_munlockall = 153 on hppa */
int munmap(void *a, size_t l) { return _sc2(__NR_munmap, (long)a, l); }
int __munmap(void *a, size_t l) { return munmap(a, l); }
int __pipe2(int fd[2], int f) { return _sc2(__NR_pipe2, (long)fd, f); }
int pipe2(int fd[2], int f) { return __pipe2(fd, f); }
int vfork(void) { return _sc0(__NR_fork); } /* use fork instead of vfork */
int setns(int fd, int t) { return _sc2(__NR_setns, fd, t); }
int unshare(int f) { return _sc1(__NR_unshare, f); }
int getresuid(unsigned int *r, unsigned int *e, unsigned int *s) { return _sc3(__NR_getresuid, (long)r, (long)e, (long)s); }
int getresgid(unsigned int *r, unsigned int *e, unsigned int *s) { return _sc3(__NR_getresgid, (long)r, (long)e, (long)s); }
int getgroups(int sz, unsigned int *l) { return _sc2(__NR_getgroups, sz, (long)l); }
int __getgroups(int sz, unsigned int *l) { return getgroups(sz, l); }
int unlinkat(int d, const char *p, int f) { return _sc3(__NR_unlinkat, d, (long)p, f); }
int mkdirat(int d, const char *p, int m) { return _sc3(__NR_mkdirat, d, (long)p, m); }
int linkat(int o, const char *op, int n, const char *np, int f) { return _sc5(__NR_linkat, o, (long)op, n, (long)np, f); }
int symlinkat(const char *t, int d, const char *l) { return _sc3(__NR_symlinkat, (long)t, d, (long)l); }
int setxattr(const char *p, const char *n, const void *v, size_t s, int f) { return _sc5(__NR_setxattr, (long)p, (long)n, (long)v, s, f); }
int lsetxattr(const char *p, const char *n, const void *v, size_t s, int f) { return _sc5(__NR_lsetxattr, (long)p, (long)n, (long)v, s, f); }
int fsetxattr(int fd, const char *n, const void *v, size_t s, int f) { return _sc5(__NR_fsetxattr, fd, (long)n, (long)v, s, f); }
long getxattr(const char *p, const char *n, void *v, size_t s) { return _sc4(__NR_getxattr, (long)p, (long)n, (long)v, s); }
int removexattr(const char *p, const char *n) { return _sc2(__NR_removexattr, (long)p, (long)n); }
int lremovexattr(const char *p, const char *n) { return _sc2(__NR_lremovexattr, (long)p, (long)n); }
int fremovexattr(int fd, const char *n) { return _sc2(__NR_fremovexattr, fd, (long)n); }
int __execve(const char *f, char *const a[], char *const e[]) { return _sc3(__NR_execve, (long)f, (long)a, (long)e); }

/* sync */
void sync(void) { _sc0(36); } /* __NR_sync = 36 on hppa */

/* pthread stubs - enough for basic tests */
int __syscall_cancel_arch_start = 0;
int __syscall_cancel_arch_end = 0;
int __rseq_offset = 0;
int __rseq_size = 0;
int __rseq_flags = 0;
char *stpcpy(char *d, const char *s) {
    while ((*d = *s)) { d++; s++; } return d;
}

/* Socket stubs - not real implementations, just enough to not crash */
int __socket(int d, int t, int p) { return -1; }
int __bind(int s, const void *a, unsigned int l) { return -1; }
int __getsockname(int s, void *a, void *l) { return -1; }
int __getpeername(int s, void *a, void *l) { return -1; }

/* clone for pthread */
int __clone(int (*fn)(void *), void *stack, int flags, void *arg, ...) { return -1; }

/* Scheduler stubs */
int __sched_setscheduler(int p, int pol, const void *par) { return _sc3(__NR_sched_setscheduler, p, pol, (long)par); }
int __sched_getscheduler(int p) { return _sc1(__NR_sched_getscheduler, p); }
int __sched_setparam(int p, const void *par) { return _sc2(__NR_sched_setparam, p, (long)par); }
int __sched_getparam(int p, void *par) { return _sc2(__NR_sched_getparam, p, (long)par); }
int __sched_get_priority_max(int pol) { return _sc1(__NR_sched_get_priority_max, pol); }
int __sched_get_priority_min(int pol) { return _sc1(__NR_sched_get_priority_min, pol); }

/* ======== TLS-free malloc (replaces glibc's TLS-using malloc.o) ======== */
struct alloc_hdr { unsigned long size; unsigned long magic; };
#define AHDR_MAGIC 0xA110CA7EDEADBEEFUL

void *malloc(size_t size) {
    if (!size) size = 1;
    size_t total = (size + sizeof(struct alloc_hdr) + 4095) & ~4095UL;
    void *p = mmap(0, total, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return 0;
    struct alloc_hdr *h = (struct alloc_hdr *)p;
    h->size = total;
    h->magic = AHDR_MAGIC;
    return (char *)p + sizeof(struct alloc_hdr);
}

void free(void *ptr) {
    if (!ptr) return;
    struct alloc_hdr *h = (struct alloc_hdr *)((char *)ptr - sizeof(struct alloc_hdr));
    if (h->magic == AHDR_MAGIC)
        munmap(h, h->size);
}

void *calloc(size_t n, size_t sz) {
    return malloc(n * sz); /* mmap returns zeroed pages */
}

void *realloc(void *ptr, size_t size) {
    if (!ptr) return malloc(size);
    if (!size) { free(ptr); return 0; }
    struct alloc_hdr *h = (struct alloc_hdr *)((char *)ptr - sizeof(struct alloc_hdr));
    size_t old_data = h->size - sizeof(struct alloc_hdr);
    void *new_p = malloc(size);
    if (!new_p) return 0;
    size_t cp = old_data < size ? old_data : size;
    memcpy(new_p, ptr, cp);
    free(ptr);
    return new_p;
}

void *reallocarray(void *p, size_t n, size_t sz) { return realloc(p, n*sz); }

/* ======== _start entry point ======== */
extern int main(int, char **, char **);
extern void exit(int);

void _start(void) __attribute__((used, section(".text.startup")));
void _start(void) {
    static char *argv[] = { "test", 0 };
    static char *envp[] = { 0 };
    exit(main(1, argv, envp));
}
