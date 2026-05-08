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
void *malloc(size_t);
void free(void *);

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
#define __NR_exit_group     94
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
/* _dl_early_allocate: __libc_setup_tls needs this to allocate TLS block.
 * Returning NULL causes TLS setup to fail and cr27 never gets set.
 * Use a static buffer — TLS is typically small (a few KB). */
static char _dl_early_pool[65536];
static unsigned long _dl_early_pool_used = 0;
void *_dl_early_allocate(unsigned long sz)
{
    /* Align to 64 bytes (hppa64 cache line) */
    sz = (sz + 63) & ~63UL;
    if (_dl_early_pool_used + sz > sizeof(_dl_early_pool))
        return 0;
    void *ret = &_dl_early_pool[_dl_early_pool_used];
    _dl_early_pool_used += sz;
    return ret;
}
void _dl_deallocate_tls(void *p, int d) { }
void _dl_determine_tlsoffset(void) { }
void _dl_tls_static_surplus_init(void) { }
/* hppa64: set cr27 (thread pointer) via kernel gateway at 0xe0.
 * __libc_setup_tls calls ble 0xe0(sr2,r0) to set cr27 before calling us,
 * but provide belt-and-suspenders implementation in case __libc_setup_tls
 * fails or takes a different code path. The 0xe0 gateway does mtctl r26,cr27. */
void __tls_init_tp(void *tcbp)
{
    register void *r26 __asm__("r26") = tcbp;
    __asm__ volatile(
        "ble 0xe0(%%sr2, %%r0)\n\t"
        "nop"
        : : "r"(r26) : "r31", "memory"
    );
}
void __tls_pre_init_tp(void) { }
void __atomic_link_error(void) { }
void __cxa_thread_atexit_impl(void) { }
void __syscall_cancel_arch(void) { }
int __tunable_get_val(void) { return 0; }

/* Override glibc __libc_start_main: glibc's version does TLS setup,
 * random data processing, and other init that requires dynamic linker
 * structures we can't properly stub. Provide a minimal version that
 * just calls main(argc, argv, envp). */
static char _dl_random_buf[16]; /* must be valid memory, not NULL */
void *_dl_random = _dl_random_buf;
void *__libc_stack_end = 0;

void _dl_non_dynamic_init(void) { }

/* ELF auxiliary vector types */
#define AT_NULL         0
#define AT_PHDR         3
#define AT_PHNUM        5
#define AT_PAGESZ       6
#define AT_RANDOM       25

void _dl_aux_init(void *auxv_raw) {
    unsigned long *auxv = (unsigned long *)auxv_raw;
    if (!auxv) return;
    while (auxv[0] != AT_NULL) {
        switch (auxv[0]) {
        case AT_PHDR:   _dl_phdr = (void *)auxv[1]; break;
        case AT_PHNUM:  _dl_phnum = (unsigned int)auxv[1]; break;
        case AT_PAGESZ: _dl_pagesize = auxv[1]; break;
        case AT_RANDOM: _dl_random = (void *)auxv[1]; break;
        }
        auxv += 2;
    }
}
void __tunables_init(char **envp) { }
void __libc_early_init(int initial) { }
void *_dl_debug_initialize(unsigned long ldbase, unsigned long ns) { return 0; }
int __canonicalize_funcptr_for_compare(void *fptr) { return (int)(unsigned long)fptr; }

/* Minimal TLS setup for hppa64 static binaries.
 * glibc's __libc_setup_tls accesses complex DLT/GOT-relative data structures
 * that break in our static linking setup (r19 not initialized by kernel).
 * We provide our own that allocates a minimal TLS block and sets cr27.
 *
 * hppa64 TLS layout (variant I, like most arches):
 *   [padding] [TLS block] [TCB header]
 *                          ^-- cr27 points here
 * The TCB header on hppa64 is just a pointer to the dtv (dynamic TLS vector).
 * For static TLS, we only need: a zeroed TLS block + a TCB with dtv[0]=gen,dtv[1]=tls_base.
 */
void __pgcl_setup_tls_asm(void); /* called from asm _start */
void __pgcl_setup_tls(void)
{
    /* Allocate TLS area: 4KB should be plenty for static TLS */
    static char tls_area[4096] __attribute__((aligned(64)));
    /* Use the end of the area as TCB. hppa uses variant I TLS:
     * cr27 points to TCB at high end, TLS data grows downward.
     * TCB[0] = pointer to dtv array. For static single-module TLS,
     * dtv[0] = generation counter (1), dtv[1] = TLS base address. */
    static unsigned long dtv[3];
    char *tcb = &tls_area[sizeof(tls_area) - 64]; /* TCB at end, 64-byte aligned */
    dtv[0] = 1; /* generation counter */
    dtv[1] = (unsigned long)(tcb); /* TLS base = TCB for variant I */
    *(unsigned long *)tcb = (unsigned long)dtv; /* TCB->dtv = &dtv */

    /* Set cr27 via kernel gateway page at 0xe0 */
    __tls_init_tp(tcb);
}

/* Override glibc's __libc_setup_tls which crashes in static binaries due to
 * complex DLT/GOT-relative data accesses with uninitialized r19. */
void __libc_setup_tls(void) { __pgcl_setup_tls(); }
void __pgcl_setup_tls_asm(void) { __pgcl_setup_tls(); }

extern void __libc_init_first(int argc, char **argv, char **envp);

/* Our __libc_start_main: called by crt1.o with
 * r26=main, r25=argc, r24=argv, r23=init, stack has fini+stack_end.
 * Initializes TLS (needed for ctype, malloc, etc.), then calls main. */
int __libc_start_main(int (*main_func)(int, char **, char **),
                       int argc, char **argv,
                       void (*init)(void), void (*fini)(void),
                       void (*rtld_fini)(void), void *stack_end)
{
    char **envp = argv + argc + 1;
    /* Parse auxv for _dl_aux_init (needed by TLS setup for AT_PHDR etc.) */
    {
        char **p = envp;
        while (*p) p++;
        _dl_aux_init(p + 1);
    }
    __pgcl_setup_tls();
    __libc_init_first(argc, argv, envp);
    int ret = main_func(argc, argv, envp);
    _sc1(__NR_exit_group, ret);
    __builtin_unreachable();
}
int __libc_start_main_impl(int (*main_func)(int, char **, char **),
                            int argc, char **argv,
                            void (*init)(void), void (*fini)(void),
                            void (*rtld_fini)(void), void *stack_end)
    __attribute__((alias("__libc_start_main")));

/* $$dyncall: indirect function call stub for PA-RISC */
__asm__(".globl $$dyncall\n$$dyncall:\n\tbve,n (%r21)\n");
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

/* ======== Core libc functions needed for standalone linking ======== */
/* hppa64 mmap uses __NR_mmap2 (not __NR_mmap) with page-unit offset */
#define __NR_mmap         90
#define __NR_mmap2        197
#define __NR_brk          45
#define __NR_read         3
#define __NR_open         5
#define __NR_ioctl        54
#define __NR_fcntl        55
#define __NR_lseek        19
#define __NR_fstat64      112
#define __NR_stat64       101
#define __NR_lstat64      102
#define __NR_wait4        114
#define __NR_rt_sigaction 174
#define __NR_rt_sigprocmask 175
#define __NR_nanosleep    162
#define __NR_clock_gettime 246
#define __NR_getrlimit    76
#define __NR_setrlimit    75
#define __NR_mremap       163
#define __NR_msync        144
#define __NR_shmget       307
#define __NR_shmat        308
#define __NR_shmdt        309
#define __NR_shmctl       310
#define __NR_mlock2       345
#define __NR_pkey_mprotect 346
#define __NR_process_mrelease 448
#define __NR_dup2         63
#define __NR_dup3         312
#define __NR_access       33
#define __NR_openat       275
#define __NR_readlinkat   285
#define __NR_fstatat64    280
#define __NR_gettimeofday 78
#define __NR_getcwd       110
#define __NR_getdents64   299
#define __NR_set_tid_address 237
#define __NR_futex        210
#define __NR_exit_group   222
#define __NR_tgkill       265
#define __NR_tkill         208
#define __NR_clone         120
#define __NR_waitpid       7
#define __NR_prlimit64     321
#define __NR_sched_yield   158
#define __NR_ftruncate64   200
#define __NR_process_vm_readv 330
#define __NR_process_vm_writev 331
#define __NR_memfd_create  340
#define __NR_remap_file_pages 227

static long _sc6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    register long r20 __asm__("r20") = nr;
    register long r26 __asm__("r26") = a1;
    register long r25 __asm__("r25") = a2;
    register long r24 __asm__("r24") = a3;
    register long r23 __asm__("r23") = a4;
    register long r22 __asm__("r22") = a5;
    register long r21 __asm__("r21") = a6;
    register long ret __asm__("r28");
    __asm__ volatile("ble 0x100(%%sr2,%%r0)\n\tnop"
        : "=r"(ret) : "r"(r20), "r"(r26), "r"(r25), "r"(r24), "r"(r23), "r"(r22), "r"(r21) : "r1", "r2", "r29", "r31", "memory");
    return ret;
}

/* Thread-local errno emulation (single-threaded is fine for LTP) */
static int _errno_val;
int *__errno_location(void) { return &_errno_val; }

static long _set_errno(long ret) {
    if (ret < 0 && ret > -4096) { _errno_val = -ret; return -1; }
    _errno_val = 0;
    return ret;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, long offset) {
    return (void *)_sc6(__NR_mmap, (long)addr, len, prot, flags, fd, offset);
}
void *__mmap(void *addr, size_t len, int prot, int flags, int fd, long offset) {
    return mmap(addr, len, prot, flags, fd, offset);
}

void *mremap(void *old, size_t oldsz, size_t newsz, int flags, ...) {
    return (void *)_sc4(__NR_mremap, (long)old, oldsz, newsz, flags);
}
void *__mremap(void *old, size_t oldsz, size_t newsz, int flags, ...) {
    return mremap(old, oldsz, newsz, flags);
}

int msync(void *a, size_t l, int f) { return _set_errno(_sc3(__NR_msync, (long)a, l, f)); }

void *memcpy(void *d, const void *s, size_t n) {
    char *dd = d; const char *ss = s;
    while (n--) *dd++ = *ss++;
    return d;
}

void *memmove(void *d, const void *s, size_t n) {
    char *dd = d; const char *ss = (const char *)s;
    if (dd < ss) { while (n--) *dd++ = *ss++; }
    else { dd += n; ss += n; while (n--) *--dd = *--ss; }
    return d;
}

void *memset(void *d, int c, size_t n) {
    unsigned char *p = d;
    while (n--) *p++ = (unsigned char)c;
    return d;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *p = a, *q = b;
    while (n--) { if (*p != *q) return *p - *q; p++; q++; }
    return 0;
}

char *strcpy(char *d, const char *s) { char *r = d; while ((*d++ = *s++)); return r; }
char *strncpy(char *d, const char *s, size_t n) {
    char *r = d;
    while (n && (*d++ = *s++)) n--;
    while (n--) *d++ = 0;
    return r;
}
char *strcat(char *d, const char *s) { char *r = d; while (*d) d++; while ((*d++ = *s++)); return r; }
char *strncat(char *d, const char *s, size_t n) {
    char *r = d; while (*d) d++;
    while (n-- && (*d++ = *s++));
    *d = 0;
    return r;
}
size_t strnlen(const char *s, size_t n) { const char *p = s; while (n-- && *p) p++; return p - s; }
char *strchr(const char *s, int c) {
    while (*s) { if (*s == (char)c) return (char *)s; s++; }
    return c == 0 ? (char *)s : 0;
}
char *strrchr(const char *s, int c) {
    const char *r = 0;
    while (*s) { if (*s == (char)c) r = s; s++; }
    return c == 0 ? (char *)s : (char *)r;
}
char *strstr(const char *h, const char *n) {
    size_t nl = strlen(n);
    if (!nl) return (char *)h;
    while (*h) { if (!strncmp(h, n, nl)) return (char *)h; h++; }
    return 0;
}
size_t strspn(const char *s, const char *a) {
    const char *p = s;
    while (*p) { const char *q = a; int found = 0; while (*q) { if (*p == *q++) { found = 1; break; } } if (!found) break; p++; }
    return p - s;
}
size_t strcspn(const char *s, const char *r) {
    const char *p = s;
    while (*p) { const char *q = r; while (*q) { if (*p == *q++) return p - s; } p++; }
    return p - s;
}
char *strpbrk(const char *s, const char *a) {
    while (*s) { const char *q = a; while (*q) { if (*s == *q++) return (char *)s; } s++; }
    return 0;
}
char *strdup(const char *s) {
    size_t l = strlen(s) + 1;
    char *d = malloc(l);
    if (d) memcpy(d, s, l);
    return d;
}
char *strndup(const char *s, size_t n) {
    size_t l = strnlen(s, n);
    char *d = malloc(l + 1);
    if (d) { memcpy(d, s, l); d[l] = 0; }
    return d;
}

void _exit(int s) { _sc1(__NR_exit_group, s); __builtin_unreachable(); }
void exit(int s) { _exit(s); }
void __exit(int s) { _exit(s); }
void abort(void) { _sc2(__NR_kill, _sc0(__NR_getpid), 6); _exit(127); __builtin_unreachable(); }
void __stack_chk_fail(void) { abort(); }

/* I/O */
ssize_t read(int fd, void *b, size_t n) { return _set_errno(_sc3(__NR_read, fd, (long)b, n)); }
ssize_t __read(int fd, void *b, size_t n) { return read(fd, b, n); }
ssize_t write(int fd, const void *b, size_t n) { return _set_errno(_sc3(__NR_write, fd, (long)b, n)); }
ssize_t __write(int fd, const void *b, size_t n) { return write(fd, b, n); }
int open(const char *p, int f, ...) { return _set_errno(_sc3(__NR_open, (long)p, f, 0)); }
int __open(const char *p, int f, ...) { return open(p, f); }
int openat(int d, const char *p, int f, ...) { return _set_errno(_sc4(__NR_openat, d, (long)p, f, 0)); }
int __openat(int d, const char *p, int f, ...) { return openat(d, p, f); }
int close(int fd) { return _set_errno(_sc1(__NR_close, fd)); }
int __close(int fd) { return close(fd); }
long lseek(int fd, long off, int w) { return _set_errno(_sc3(__NR_lseek, fd, off, w)); }
long __lseek(int fd, long off, int w) { return lseek(fd, off, w); }
int dup2(int o, int n) { return _set_errno(_sc2(__NR_dup2, o, n)); }
int dup3(int o, int n, int f) { return _set_errno(_sc3(__NR_dup3, o, n, f)); }
int access(const char *p, int m) { return _set_errno(_sc2(__NR_access, (long)p, m)); }
int ioctl(int fd, unsigned long r, ...) { return -1; } /* stub */
int __ioctl(int fd, unsigned long r, ...) { return -1; }
int fcntl(int fd, int c, ...) { return _set_errno(_sc3(__NR_fcntl, fd, c, 0)); }
int __fcntl(int fd, int c, ...) { return fcntl(fd, c); }

/* brk/sbrk */
static unsigned long _brk_cur;
void *sbrk(long inc) {
    if (!_brk_cur) _brk_cur = _sc1(__NR_brk, 0);
    unsigned long old = _brk_cur;
    unsigned long new_brk = _sc1(__NR_brk, old + inc);
    if (new_brk == old + inc) { _brk_cur = new_brk; return (void *)old; }
    _errno_val = 12; /* ENOMEM */
    return (void *)-1;
}
void *__sbrk(long inc) { return sbrk(inc); }
int brk(void *a) {
    unsigned long r = _sc1(__NR_brk, (long)a);
    if (r == (unsigned long)a) { _brk_cur = r; return 0; }
    _errno_val = 12;
    return -1;
}
int __brk(void *a) { return brk(a); }

/* process */
int fork(void) { return _set_errno(_sc0(__NR_fork)); }
int __fork(void) { return fork(); }
int execve(const char *f, char *const a[], char *const e[]) { return _set_errno(_sc3(__NR_execve, (long)f, (long)a, (long)e)); }
int wait4(int p, int *s, int o, void *r) { return _set_errno(_sc4(__NR_wait4, p, (long)s, o, (long)r)); }
int __wait4(int p, int *s, int o, void *r) { return wait4(p, s, o, r); }
int waitpid(int p, int *s, int o) { return wait4(p, s, o, 0); }
int __waitpid(int p, int *s, int o) { return waitpid(p, s, o); }

/* signal */
typedef void (*sighandler_t)(int);
sighandler_t signal(int sig, sighandler_t h) { return (sighandler_t)-1; } /* stub */
sighandler_t __sysv_signal(int sig, sighandler_t h) { return signal(sig, h); }
int sigaction(int sig, const void *a, void *o) { return _set_errno(_sc4(__NR_rt_sigaction, sig, (long)a, (long)o, 8)); }
int __sigaction(int sig, const void *a, void *o) { return sigaction(sig, a, o); }
int sigprocmask(int how, const void *s, void *o) { return _set_errno(_sc4(__NR_rt_sigprocmask, how, (long)s, (long)o, 8)); }
int __sigprocmask(int how, const void *s, void *o) { return sigprocmask(how, s, o); }
int raise(int sig) { return kill(getpid(), sig); }

/* time */
int nanosleep(const void *r, void *rem) { return _set_errno(_sc2(__NR_nanosleep, (long)r, (long)rem)); }
int __nanosleep(const void *r, void *rem) { return nanosleep(r, rem); }
int clock_gettime(int clk, void *tp) { return _set_errno(_sc2(__NR_clock_gettime, clk, (long)tp)); }
int __clock_gettime(int clk, void *tp) { return clock_gettime(clk, tp); }
int gettimeofday(void *tv, void *tz) { return _set_errno(_sc2(__NR_gettimeofday, (long)tv, (long)tz)); }
int __gettimeofday(void *tv, void *tz) { return gettimeofday(tv, tz); }
unsigned int sleep(unsigned int s) { long r[2] = {s, 0}; nanosleep(r, 0); return 0; }

/* resource limits */
int getrlimit(int r, void *l) { return _set_errno(_sc2(__NR_getrlimit, r, (long)l)); }
int __getrlimit(int r, void *l) { return getrlimit(r, l); }
int setrlimit(int r, const void *l) { return _set_errno(_sc2(__NR_setrlimit, r, (long)l)); }
int prlimit64(int p, int r, const void *n, void *o) { return _set_errno(_sc4(__NR_prlimit64, p, r, (long)n, (long)o)); }

/* misc */
int getpagesize(void) { return 4096; }
long syscall(long nr, ...) {
    /* Variadic syscall - limited support */
    return _sc0(nr);
}
long __syscall(long nr, ...) { return syscall(nr); }
int chmod(const char *p, unsigned int m) { return _set_errno(_sc2(__NR_chmod, (long)p, m)); }
char *getcwd(char *b, size_t s) {
    long r = _sc2(__NR_getcwd, (long)b, s);
    return r < 0 ? 0 : b;
}
char *__getcwd(char *b, size_t s) { return getcwd(b, s); }

int fstat(int fd, void *s) { return _set_errno(_sc2(__NR_fstat64, fd, (long)s)); }
int __fstat(int fd, void *s) { return fstat(fd, s); }
int stat(const char *p, void *s) { return _set_errno(_sc2(__NR_stat64, (long)p, (long)s)); }
int __stat(const char *p, void *s) { return stat(p, s); }
int lstat(const char *p, void *s) { return _set_errno(_sc2(__NR_lstat64, (long)p, (long)s)); }
int __lstat(const char *p, void *s) { return lstat(p, s); }
int fstatat(int d, const char *p, void *s, int f) { return _set_errno(_sc4(__NR_fstatat64, d, (long)p, (long)s, f)); }

long readlinkat(int d, const char *p, char *b, size_t s) { return _set_errno(_sc4(__NR_readlinkat, d, (long)p, (long)b, s)); }
long readlink(const char *p, char *b, size_t s) { return readlinkat(-100, p, b, s); }
int __readlink(const char *p, char *b, size_t s) { return readlink(p, b, s); }

int set_tid_address(int *t) { return _sc1(__NR_set_tid_address, (long)t); }

/* SysV shared memory */
int shmget(int k, size_t s, int f) { return _set_errno(_sc3(__NR_shmget, k, s, f)); }
void *shmat(int id, const void *a, int f) { return (void *)_set_errno(_sc3(__NR_shmat, id, (long)a, f)); }
int shmdt(const void *a) { return _set_errno(_sc1(__NR_shmdt, (long)a)); }
int shmctl(int id, int c, void *b) { return _set_errno(_sc3(__NR_shmctl, id, c, (long)b)); }

/* Additional mlock/mprotect variants */
int mlock2(const void *a, size_t l, unsigned int f) { return _set_errno(_sc3(__NR_mlock2, (long)a, l, f)); }
int pkey_mprotect(void *a, size_t l, int p, int k) { return _set_errno(_sc4(__NR_pkey_mprotect, (long)a, l, p, k)); }

/* ftruncate */
int ftruncate(int fd, long l) { return _set_errno(_sc2(__NR_ftruncate64, fd, l)); }

/* memfd_create */
int memfd_create(const char *n, unsigned int f) { return _set_errno(_sc2(__NR_memfd_create, (long)n, f)); }

/* getdents64 */
long getdents64(int fd, void *d, size_t c) { return _set_errno(_sc3(__NR_getdents64, fd, (long)d, c)); }

/* futex for checkpoint sync */
int futex(int *u, int o, int v, const void *t, int *u2, int v3) { return _set_errno(_sc6(__NR_futex, (long)u, o, v, (long)t, (long)u2, v3)); }

/* pidfd_open (Linux 5.3+) */
#define __NR_pidfd_open    434
int pidfd_open(int pid, unsigned int flags) { return _set_errno(_sc2(__NR_pidfd_open, pid, flags)); }

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

/* _start is provided by crt1.o from glibc sysroot.
 * It initializes dp (global data pointer) and calls __libc_start_main,
 * which calls main(argc, argv, envp). */
