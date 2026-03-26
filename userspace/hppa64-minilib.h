/*
 * Minimal C library for hppa64 (PA-RISC 2.0 64-bit) Linux
 *
 * Neither musl nor glibc supports hppa64, so we provide a minimal
 * implementation using raw syscalls via the PA-RISC gateway page.
 *
 * PA-RISC syscall convention:
 *   - Syscall number in %r20
 *   - Arguments in %r26, %r25, %r24, %r23, %r22, %r21 (descending)
 *   - Return value in %r28
 *   - Call via: ble 0x100(%sr2, %r0)  (gateway page at fixed address)
 *   - r19 (GOT/PIC register) is clobbered by syscall, save in r4
 *   - r1, r2, r20, r29, r31 are clobbered
 */

#ifndef HPPA64_MINILIB_H
#define HPPA64_MINILIB_H

/* We need compiler builtins only */
typedef unsigned long size_t;
typedef long ssize_t;
typedef long off_t;
typedef int pid_t;
typedef unsigned int mode_t;
typedef unsigned long sigset_t;

#define NULL ((void *)0)
#define EOF (-1)

/* From Linux UAPI for parisc */
#define __NR_exit           1
#define __NR_fork           2
#define __NR_read           3
#define __NR_write          4
#define __NR_open           5
#define __NR_close          6
#define __NR_waitpid        7
#define __NR_unlink         10
#define __NR_brk            45
#define __NR_ioctl          54
#define __NR_mmap2          89
#define __NR_mmap           90
#define __NR_munmap         91
#define __NR_mprotect       94
#define __NR_getpid         20
#define __NR_kill           37
#define __NR_lseek          19
#define __NR_ftruncate64    200
#define __NR_madvise        119
#define __NR_mincore        72
#define __NR_mremap         163
#define __NR_mlock          150
#define __NR_munlock        151
#define __NR_msync          144
#define __NR_exit_group     222
#define __NR_rt_sigaction   174
#define __NR_rt_sigprocmask 175
#define __NR_wait4          114
#define __NR_sysconf_pgsz   0  /* not a real syscall, use AT_PAGESZ */
#define __NR_clone          120

/* mmap flags */
#define PROT_NONE       0x0
#define PROT_READ       0x1
#define PROT_WRITE      0x2
#define PROT_EXEC       0x4
#define MAP_SHARED      0x01
#define MAP_PRIVATE     0x02
#define MAP_FIXED       0x10
#define MAP_ANONYMOUS   0x20
#define MAP_FAILED      ((void *)-1)

/* madvise */
#define MADV_DONTNEED   4
#define MADV_PAGEOUT    21

/* msync */
#define MS_SYNC         4

/* mremap */
#define MREMAP_MAYMOVE  1

/* open flags */
#define O_RDONLY        0x0000
#define O_WRONLY        0x0001
#define O_RDWR          0x0002
#define O_CREAT         0x0200
#define O_TRUNC         0x0400

/* Wait flags */
#define WNOHANG         1
#define WUNTRACED       2
#define WIFEXITED(s)    (((s) & 0x7f) == 0)
#define WEXITSTATUS(s)  (((s) & 0xff00) >> 8)

/* Signal stuff */
#define SIGSEGV         11
#define SA_SIGINFO      0x10

/* lseek */
#define SEEK_SET        0
#define SEEK_CUR        1
#define SEEK_END        2

/* errno */
#define ENOMEM          12
#define EPERM           1
#define ENOSYS          251  /* parisc uses different errno values! */

/* PA-RISC has different errno encoding than other architectures */
/* Linux parisc error numbers - selected ones we need */
#define HPPA_EPERM      1
#define HPPA_ENOENT     2
#define HPPA_ENOMEM     12
#define HPPA_EACCES     13
#define HPPA_EFAULT     14
#define HPPA_EINVAL     22
#define HPPA_ENOSYS     251

static int __errno_val;
#define errno __errno_val

/* Auxiliary vector */
#define AT_NULL         0
#define AT_PAGESZ       6
/* We'll store this from _start */
static unsigned long __at_pagesz = 4096;
#define _SC_PAGESIZE    30

/*
 * PA-RISC syscall inline assembly.
 * Note: on PA-RISC, syscalls return negative errno on error (like most Linux archs),
 * BUT some PA-RISC errno values differ from generic Linux!
 */

#define K_STW_PIC  "copy %%r19, %%r4\n\t"
#define K_LDW_PIC  "copy %%r4, %%r19\n\t"
#define K_CLOB     "r1", "r2", "r4", "r20", "r29", "r31"

static inline long __syscall0(long nr)
{
    register unsigned long __res __asm__("r28");
    __asm__ volatile(
        K_STW_PIC
        "ble 0x100(%%sr2, %%r0)\n\t"
        "ldi %1, %%r20\n\t"
        K_LDW_PIC
        : "=r" (__res)
        : "i" (0)  /* placeholder, we use copy below */
        : "memory", K_CLOB, "r26", "r25", "r24", "r23", "r22", "r21"
    );
    /* Workaround: can't use "i" for large syscall numbers */
    (void)nr;
    return (long)__res;
}

/* Use a function-like macro approach for syscalls to handle the number */
static inline long _raw_syscall0(int nr)
{
    register unsigned long __res __asm__("r28");
    register unsigned long __nr __asm__("r20") = nr;
    __asm__ volatile(
        K_STW_PIC
        "ble 0x100(%%sr2, %%r0)\n\t"
        "copy %1, %%r20\n\t"
        K_LDW_PIC
        : "=r" (__res)
        : "r" (__nr)
        : "memory", "r1", "r2", "r4", "r29", "r31",
          "r26", "r25", "r24", "r23", "r22", "r21"
    );
    return (long)__res;
}

static inline long _raw_syscall1(int nr, unsigned long a1)
{
    register unsigned long __res __asm__("r28");
    register unsigned long __nr __asm__("r20") = nr;
    register unsigned long __r26 __asm__("r26") = a1;
    __asm__ volatile(
        K_STW_PIC
        "ble 0x100(%%sr2, %%r0)\n\t"
        "copy %1, %%r20\n\t"
        K_LDW_PIC
        : "=r" (__res)
        : "r" (__nr), "r" (__r26)
        : "memory", "r1", "r2", "r4", "r29", "r31",
          "r25", "r24", "r23", "r22", "r21"
    );
    return (long)__res;
}

static inline long _raw_syscall2(int nr, unsigned long a1, unsigned long a2)
{
    register unsigned long __res __asm__("r28");
    register unsigned long __nr __asm__("r20") = nr;
    register unsigned long __r26 __asm__("r26") = a1;
    register unsigned long __r25 __asm__("r25") = a2;
    __asm__ volatile(
        K_STW_PIC
        "ble 0x100(%%sr2, %%r0)\n\t"
        "copy %1, %%r20\n\t"
        K_LDW_PIC
        : "=r" (__res)
        : "r" (__nr), "r" (__r26), "r" (__r25)
        : "memory", "r1", "r2", "r4", "r29", "r31",
          "r24", "r23", "r22", "r21"
    );
    return (long)__res;
}

static inline long _raw_syscall3(int nr, unsigned long a1, unsigned long a2,
                                  unsigned long a3)
{
    register unsigned long __res __asm__("r28");
    register unsigned long __nr __asm__("r20") = nr;
    register unsigned long __r26 __asm__("r26") = a1;
    register unsigned long __r25 __asm__("r25") = a2;
    register unsigned long __r24 __asm__("r24") = a3;
    __asm__ volatile(
        K_STW_PIC
        "ble 0x100(%%sr2, %%r0)\n\t"
        "copy %1, %%r20\n\t"
        K_LDW_PIC
        : "=r" (__res)
        : "r" (__nr), "r" (__r26), "r" (__r25), "r" (__r24)
        : "memory", "r1", "r2", "r4", "r29", "r31",
          "r23", "r22", "r21"
    );
    return (long)__res;
}

static inline long _raw_syscall4(int nr, unsigned long a1, unsigned long a2,
                                  unsigned long a3, unsigned long a4)
{
    register unsigned long __res __asm__("r28");
    register unsigned long __nr __asm__("r20") = nr;
    register unsigned long __r26 __asm__("r26") = a1;
    register unsigned long __r25 __asm__("r25") = a2;
    register unsigned long __r24 __asm__("r24") = a3;
    register unsigned long __r23 __asm__("r23") = a4;
    __asm__ volatile(
        K_STW_PIC
        "ble 0x100(%%sr2, %%r0)\n\t"
        "copy %1, %%r20\n\t"
        K_LDW_PIC
        : "=r" (__res)
        : "r" (__nr), "r" (__r26), "r" (__r25), "r" (__r24), "r" (__r23)
        : "memory", "r1", "r2", "r4", "r29", "r31",
          "r22", "r21"
    );
    return (long)__res;
}

static inline long _raw_syscall5(int nr, unsigned long a1, unsigned long a2,
                                  unsigned long a3, unsigned long a4,
                                  unsigned long a5)
{
    register unsigned long __res __asm__("r28");
    register unsigned long __nr __asm__("r20") = nr;
    register unsigned long __r26 __asm__("r26") = a1;
    register unsigned long __r25 __asm__("r25") = a2;
    register unsigned long __r24 __asm__("r24") = a3;
    register unsigned long __r23 __asm__("r23") = a4;
    register unsigned long __r22 __asm__("r22") = a5;
    __asm__ volatile(
        K_STW_PIC
        "ble 0x100(%%sr2, %%r0)\n\t"
        "copy %1, %%r20\n\t"
        K_LDW_PIC
        : "=r" (__res)
        : "r" (__nr), "r" (__r26), "r" (__r25), "r" (__r24),
          "r" (__r23), "r" (__r22)
        : "memory", "r1", "r2", "r4", "r29", "r31",
          "r21"
    );
    return (long)__res;
}

static inline long _raw_syscall6(int nr, unsigned long a1, unsigned long a2,
                                  unsigned long a3, unsigned long a4,
                                  unsigned long a5, unsigned long a6)
{
    register unsigned long __res __asm__("r28");
    register unsigned long __nr __asm__("r20") = nr;
    register unsigned long __r26 __asm__("r26") = a1;
    register unsigned long __r25 __asm__("r25") = a2;
    register unsigned long __r24 __asm__("r24") = a3;
    register unsigned long __r23 __asm__("r23") = a4;
    register unsigned long __r22 __asm__("r22") = a5;
    register unsigned long __r21 __asm__("r21") = a6;
    __asm__ volatile(
        K_STW_PIC
        "ble 0x100(%%sr2, %%r0)\n\t"
        "copy %1, %%r20\n\t"
        K_LDW_PIC
        : "=r" (__res)
        : "r" (__nr), "r" (__r26), "r" (__r25), "r" (__r24),
          "r" (__r23), "r" (__r22), "r" (__r21)
        : "memory", "r1", "r2", "r4", "r29", "r31"
    );
    return (long)__res;
}

/* Check if return value is an error (-4095 to -1) */
static inline long __syscall_ret(long r)
{
    if (r >= -4095L && r < 0) {
        errno = -r;
        return -1;
    }
    return r;
}

/* ---- POSIX-like wrappers ---- */

static inline void _exit(int status)
{
    _raw_syscall1(__NR_exit_group, status);
    __builtin_unreachable();
}

static inline ssize_t write(int fd, const void *buf, size_t count)
{
    return __syscall_ret(_raw_syscall3(__NR_write, fd, (unsigned long)buf, count));
}

static inline ssize_t read(int fd, void *buf, size_t count)
{
    return __syscall_ret(_raw_syscall3(__NR_read, fd, (unsigned long)buf, count));
}

static inline int open(const char *path, int flags, ...)
{
    /* Simple version without varargs mode — we always pass mode */
    return __syscall_ret(_raw_syscall3(__NR_open, (unsigned long)path, flags, 0600));
}

static inline int close(int fd)
{
    return __syscall_ret(_raw_syscall1(__NR_close, fd));
}

static inline int unlink(const char *path)
{
    return __syscall_ret(_raw_syscall1(__NR_unlink, (unsigned long)path));
}

static inline off_t lseek(int fd, off_t offset, int whence)
{
    return __syscall_ret(_raw_syscall3(__NR_lseek, fd, offset, whence));
}

static inline int ftruncate(int fd, off_t length)
{
    return __syscall_ret(_raw_syscall2(__NR_ftruncate64, fd, length));
}

static inline void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset)
{
    long r = _raw_syscall6(__NR_mmap, (unsigned long)addr, len, prot, flags, fd, offset);
    if (r >= -4095L && r < 0) {
        errno = -r;
        return MAP_FAILED;
    }
    return (void *)r;
}

static inline int munmap(void *addr, size_t len)
{
    return __syscall_ret(_raw_syscall2(__NR_munmap, (unsigned long)addr, len));
}

static inline int mprotect(void *addr, size_t len, int prot)
{
    return __syscall_ret(_raw_syscall3(__NR_mprotect, (unsigned long)addr, len, prot));
}

static inline void *mremap(void *old_addr, size_t old_size, size_t new_size, int flags)
{
    return (void *)__syscall_ret(_raw_syscall4(__NR_mremap,
        (unsigned long)old_addr, old_size, new_size, flags));
}

static inline int madvise(void *addr, size_t len, int advice)
{
    return __syscall_ret(_raw_syscall3(__NR_madvise, (unsigned long)addr, len, advice));
}

static inline int mincore(void *addr, size_t len, unsigned char *vec)
{
    return __syscall_ret(_raw_syscall3(__NR_mincore,
        (unsigned long)addr, len, (unsigned long)vec));
}

static inline int mlock(const void *addr, size_t len)
{
    return __syscall_ret(_raw_syscall2(__NR_mlock, (unsigned long)addr, len));
}

static inline int munlock(const void *addr, size_t len)
{
    return __syscall_ret(_raw_syscall2(__NR_munlock, (unsigned long)addr, len));
}

static inline int msync(void *addr, size_t len, int flags)
{
    return __syscall_ret(_raw_syscall3(__NR_msync, (unsigned long)addr, len, flags));
}

static inline pid_t fork(void)
{
    return __syscall_ret(_raw_syscall0(__NR_fork));
}

static inline pid_t getpid(void)
{
    return _raw_syscall0(__NR_getpid);
}

static inline int kill(pid_t pid, int sig)
{
    return __syscall_ret(_raw_syscall2(__NR_kill, pid, sig));
}

static inline pid_t waitpid(pid_t pid, int *status, int options)
{
    return __syscall_ret(_raw_syscall4(__NR_wait4, pid, (unsigned long)status, options, 0));
}

static inline pid_t wait(int *status)
{
    return waitpid(-1, status, 0);
}

static inline long syscall(long nr, ...)
{
    /* We can't do proper varargs without a real libc.
     * This is a simplified version for brk only. */
    return 0;  /* overridden below */
}

/* brk syscall */
static inline unsigned long sys_brk(unsigned long newbrk)
{
    return (unsigned long)_raw_syscall1(__NR_brk, newbrk);
}

static inline long sysconf(int name)
{
    if (name == _SC_PAGESIZE)
        return __at_pagesz;
    return -1;
}

static inline unsigned long getauxval(unsigned long type)
{
    if (type == AT_PAGESZ)
        return __at_pagesz;
    return 0;
}

/* Signal handling */
struct siginfo_t {
    int si_signo;
    int si_errno;
    int si_code;
    int _pad[29];
    void *si_addr;  /* faulting address for SIGSEGV */
};

typedef void (*__sighandler_t)(int);
typedef void (*__sigaction_handler_t)(int, struct siginfo_t *, void *);

struct k_sigaction {
    union {
        __sighandler_t sa_handler;
        __sigaction_handler_t sa_sigaction;
    };
    unsigned long sa_flags;
    sigset_t sa_mask;
};

/* Use typedef matching what pgcl-test/pgcl-stress expect */
typedef struct siginfo_t siginfo_t;

struct sigaction {
    union {
        __sighandler_t sa_handler;
        void (*sa_sigaction)(int, siginfo_t *, void *);
    };
    unsigned long sa_flags;
    sigset_t sa_mask;
};

static inline int sigaction(int signum, const struct sigaction *act,
                            struct sigaction *oldact)
{
    /* Convert to kernel sigaction format */
    struct k_sigaction kact, kold;
    if (act) {
        kact.sa_handler = act->sa_handler;
        kact.sa_flags = act->sa_flags;
        kact.sa_mask = act->sa_mask;
    }
    long r = _raw_syscall4(__NR_rt_sigaction, signum,
                           act ? (unsigned long)&kact : 0,
                           oldact ? (unsigned long)&kold : 0,
                           sizeof(sigset_t));
    if (oldact && r == 0) {
        oldact->sa_handler = kold.sa_handler;
        oldact->sa_flags = kold.sa_flags;
        oldact->sa_mask = kold.sa_mask;
    }
    return __syscall_ret(r);
}

/* sigsetjmp/siglongjmp - minimal implementation */
typedef unsigned long jmp_buf[64];  /* oversized for safety */
typedef unsigned long sigjmp_buf[66];

/* We need asm for setjmp/longjmp. Use a simple C approximation
 * that won't survive complex unwinding but works for our fault handler pattern.
 * Note: This is NOT a correct implementation. For SIGSEGV recovery in
 * pgcl-stress, we'd need proper asm. For now, mark signal tests as skip. */
static volatile int __sigsetjmp_val;
static volatile void *__siglongjmp_target;

/* ---- String functions ---- */

static inline void *memset(void *s, int c, size_t n)
{
    unsigned char *p = s;
    while (n--)
        *p++ = (unsigned char)c;
    return s;
}

static inline void *memcpy(void *dest, const void *src, size_t n)
{
    unsigned char *d = dest;
    const unsigned char *s = src;
    while (n--)
        *d++ = *s++;
    return dest;
}

static inline size_t strlen(const char *s)
{
    const char *p = s;
    while (*p) p++;
    return p - s;
}

static inline int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *(unsigned char *)a - *(unsigned char *)b;
}

static inline char *strcpy(char *dest, const char *src)
{
    char *d = dest;
    while ((*d++ = *src++));
    return dest;
}

/* strerror - minimal */
static inline const char *strerror(int err)
{
    switch (err) {
    case 0:  return "Success";
    case 1:  return "EPERM";
    case 12: return "ENOMEM";
    case 13: return "EACCES";
    case 14: return "EFAULT";
    case 22: return "EINVAL";
    default: return "Unknown error";
    }
}

/* ---- Simple printf implementation ---- */

static int __putchar(int c)
{
    char ch = c;
    write(1, &ch, 1);
    return c;
}

static void __puts(const char *s)
{
    write(1, s, strlen(s));
}

static void __putnum(long val, int base, int is_signed, int min_width, int pad_zero)
{
    char buf[32];
    int neg = 0;
    unsigned long v;
    int i = 0;

    if (is_signed && val < 0) {
        neg = 1;
        v = -val;
    } else {
        v = val;
    }

    if (v == 0) {
        buf[i++] = '0';
    } else {
        while (v > 0) {
            int d = v % base;
            buf[i++] = (d < 10) ? ('0' + d) : ('a' + d - 10);
            v /= base;
        }
    }

    if (neg) buf[i++] = '-';

    /* Pad */
    char padch = pad_zero ? '0' : ' ';
    while (i < min_width) buf[i++] = padch;

    /* Reverse and print */
    for (int j = i - 1; j >= 0; j--)
        __putchar(buf[j]);
}

/* Minimal printf - supports: %s %d %ld %lu %lx %p %zu %zd %c %% and %-Ns for left-justified */
static int printf(const char *fmt, ...)
{
    __builtin_va_list ap;
    __builtin_va_start(ap, fmt);

    while (*fmt) {
        if (*fmt != '%') {
            __putchar(*fmt++);
            continue;
        }
        fmt++;

        /* Parse flags and width */
        int left_justify = 0;
        int pad_zero = 0;
        int width = 0;

        if (*fmt == '-') { left_justify = 1; fmt++; }
        if (*fmt == '0') { pad_zero = 1; fmt++; }

        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }

        int is_long = 0;
        int is_size = 0;
        if (*fmt == 'l') { is_long = 1; fmt++; }
        if (*fmt == 'z') { is_size = 1; fmt++; }

        switch (*fmt) {
        case 's': {
            const char *s = __builtin_va_arg(ap, const char *);
            if (!s) s = "(null)";
            int len = strlen(s);
            if (left_justify) {
                __puts(s);
                for (int i = len; i < width; i++) __putchar(' ');
            } else {
                for (int i = len; i < width; i++) __putchar(' ');
                __puts(s);
            }
            break;
        }
        case 'd': {
            long val;
            if (is_long || is_size)
                val = __builtin_va_arg(ap, long);
            else
                val = __builtin_va_arg(ap, int);
            __putnum(val, 10, 1, pad_zero ? width : 0, pad_zero);
            break;
        }
        case 'u': {
            unsigned long val;
            if (is_long || is_size)
                val = __builtin_va_arg(ap, unsigned long);
            else
                val = __builtin_va_arg(ap, unsigned int);
            __putnum(val, 10, 0, pad_zero ? width : 0, pad_zero);
            break;
        }
        case 'x': {
            unsigned long val;
            if (is_long || is_size)
                val = __builtin_va_arg(ap, unsigned long);
            else
                val = __builtin_va_arg(ap, unsigned int);
            __putnum(val, 16, 0, pad_zero ? width : 0, pad_zero);
            break;
        }
        case 'p': {
            void *p = __builtin_va_arg(ap, void *);
            __puts("0x");
            __putnum((unsigned long)p, 16, 0, 0, 0);
            break;
        }
        case 'c': {
            int c = __builtin_va_arg(ap, int);
            __putchar(c);
            break;
        }
        case '%':
            __putchar('%');
            break;
        default:
            __putchar('%');
            __putchar(*fmt);
            break;
        }
        fmt++;
    }

    __builtin_va_end(ap);
    return 0;
}

/* snprintf - very minimal, writes to buffer */
static int snprintf(char *buf, size_t size, const char *fmt, ...)
{
    /* Minimal: just copy the format string for simple cases */
    /* This is a stub - the test programs mostly use printf */
    if (size == 0) return 0;
    size_t i = 0;
    __builtin_va_list ap;
    __builtin_va_start(ap, fmt);
    while (*fmt && i < size - 1) {
        if (*fmt != '%') {
            buf[i++] = *fmt++;
            continue;
        }
        fmt++;
        /* Skip width/flags */
        while (*fmt == '-' || *fmt == '0' || (*fmt >= '0' && *fmt <= '9')) fmt++;
        if (*fmt == 'l' || *fmt == 'z') fmt++;
        switch (*fmt) {
        case 's': {
            const char *s = __builtin_va_arg(ap, const char *);
            if (!s) s = "(null)";
            while (*s && i < size - 1) buf[i++] = *s++;
            break;
        }
        case 'd': case 'u': case 'x': case 'p':
            /* Skip the value, write placeholder */
            if (*fmt == 'p')
                (void)__builtin_va_arg(ap, void *);
            else
                (void)__builtin_va_arg(ap, long);
            {
                const char *ph = "?";
                while (*ph && i < size - 1) buf[i++] = *ph++;
            }
            break;
        case '%':
            buf[i++] = '%';
            break;
        default:
            buf[i++] = '?';
            break;
        }
        fmt++;
    }
    buf[i] = '\0';
    __builtin_va_end(ap);
    return i;
}

/* ---- Memory allocation (simple bump allocator) ---- */
static unsigned long __heap_start;
static unsigned long __heap_end;

static inline void *malloc(size_t size)
{
    if (__heap_start == 0) {
        __heap_start = sys_brk(0);
        __heap_end = __heap_start;
    }
    size = (size + 15) & ~15UL;  /* align to 16 */
    unsigned long new_end = __heap_end + size;
    if (new_end > sys_brk(new_end)) {
        errno = ENOMEM;
        return NULL;
    }
    void *p = (void *)__heap_end;
    __heap_end = new_end;
    return p;
}

static inline void free(void *p)
{
    (void)p;  /* bump allocator doesn't free */
}

/* ---- FILE (minimal) ---- */
typedef struct {
    int fd;
    int eof;
    int error;
} FILE;

static FILE __stdin_file  = { 0, 0, 0 };
static FILE __stdout_file = { 1, 0, 0 };
static FILE __stderr_file = { 2, 0, 0 };
#define stdin  (&__stdin_file)
#define stdout (&__stdout_file)
#define stderr (&__stderr_file)

static inline FILE *fopen(const char *path, const char *mode)
{
    int flags = O_RDONLY;
    if (mode[0] == 'w') flags = O_WRONLY | O_CREAT | O_TRUNC;
    else if (mode[0] == 'r' && mode[1] == '+') flags = O_RDWR;

    int fd = open(path, flags);
    if (fd < 0) return NULL;

    FILE *f = malloc(sizeof(FILE));
    if (!f) { close(fd); return NULL; }
    f->fd = fd;
    f->eof = 0;
    f->error = 0;
    return f;
}

static inline int fclose(FILE *f)
{
    int r = close(f->fd);
    free(f);
    return r;
}

static inline char *fgets(char *buf, int size, FILE *f)
{
    int i = 0;
    while (i < size - 1) {
        char c;
        ssize_t r = read(f->fd, &c, 1);
        if (r <= 0) {
            f->eof = 1;
            break;
        }
        buf[i++] = c;
        if (c == '\n') break;
    }
    if (i == 0) return NULL;
    buf[i] = '\0';
    return buf;
}

static inline int sscanf(const char *str, const char *fmt, ...)
{
    /* Very minimal: only handles "MemAvailable: %ld kB" pattern */
    __builtin_va_list ap;
    __builtin_va_start(ap, fmt);

    /* Find ':' in str and fmt */
    const char *sp = str;
    const char *fp = fmt;

    /* Match literal prefix up to %ld */
    while (*fp && *fp != '%') {
        if (*fp != *sp) {
            __builtin_va_end(ap);
            return 0;
        }
        fp++;
        sp++;
    }

    if (*fp == '%') {
        fp++;
        if (*fp == 'l') fp++;
        if (*fp == 'd') {
            long *out = __builtin_va_arg(ap, long *);
            /* Skip whitespace */
            while (*sp == ' ' || *sp == '\t') sp++;
            /* Parse number */
            long val = 0;
            int neg = 0;
            if (*sp == '-') { neg = 1; sp++; }
            if (*sp < '0' || *sp > '9') {
                __builtin_va_end(ap);
                return 0;
            }
            while (*sp >= '0' && *sp <= '9') {
                val = val * 10 + (*sp - '0');
                sp++;
            }
            *out = neg ? -val : val;
            __builtin_va_end(ap);
            return 1;
        }
    }

    __builtin_va_end(ap);
    return 0;
}

/* ---- Pthreads (minimal stubs) ---- */

typedef unsigned long pthread_t;
typedef struct { int dummy; } pthread_attr_t;

/* For hppa64, we don't have real thread support without a proper libc.
 * Provide stubs that run the function in the same thread. */
static inline int pthread_create(pthread_t *tid, const pthread_attr_t *attr,
                                  void *(*start_routine)(void *), void *arg)
{
    /* Run in a forked process instead of a real thread */
    (void)attr;
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        void *ret = start_routine(arg);
        _exit(ret != NULL ? 1 : 0);
    }
    *tid = pid;
    return 0;
}

static inline int pthread_join(pthread_t tid, void **retval)
{
    int status;
    waitpid(tid, &status, 0);
    if (retval) {
        if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
            *retval = NULL;
        else
            *retval = (void *)1;
    }
    return 0;
}

/* ---- setjmp/longjmp (PA-RISC 64-bit) ---- */
/* For signal recovery we need real setjmp.
 * Minimal implementation saving callee-saved registers. */

/* sigsetjmp returns 0 on first call, non-zero on siglongjmp.
 * We implement this with fork-based signal handling instead. */

#define sigsetjmp(env, save)  __sigsetjmp_impl(env)
#define siglongjmp(env, val)  __siglongjmp_impl(env, val)

/* Placeholder - signal fault test will be skipped on hppa64 */
static inline int __sigsetjmp_impl(sigjmp_buf env)
{
    (void)env;
    return 0;
}

static inline void __siglongjmp_impl(sigjmp_buf env, int val)
{
    (void)env;
    (void)val;
    _exit(99);  /* Can't actually long jump, just exit */
}

/* ---- Override SYS_brk for the syscall(SYS_brk, ...) pattern ---- */
#define SYS_brk __NR_brk

/* Redefine syscall() as a macro to handle brk */
#undef syscall
#define syscall(nr, ...) _mini_syscall(nr, ##__VA_ARGS__)

static inline long _mini_syscall(long nr, ...)
{
    __builtin_va_list ap;
    __builtin_va_start(ap, nr);
    unsigned long a1 = __builtin_va_arg(ap, unsigned long);
    __builtin_va_end(ap);
    return _raw_syscall1(nr, a1);
}

/* ---- Startup code: parse auxv and call main ---- */
/* Called from hppa64-crt0.S with orig_sp as argument */
extern int main(int argc, char *argv[]);

int __minilib_start(unsigned long *sp)
{
    int argc = (int)sp[0];
    char **argv = (char **)&sp[1];

    /* Walk past argv to find envp */
    char **envp = argv + argc + 1;

    /* Walk past envp to find auxv */
    char **ep = envp;
    while (*ep) ep++;
    ep++;  /* skip NULL terminator */

    /* Parse auxv for AT_PAGESZ */
    unsigned long *auxv = (unsigned long *)ep;
    while (auxv[0] != AT_NULL) {
        if (auxv[0] == AT_PAGESZ) {
            __at_pagesz = auxv[1];
            break;
        }
        auxv += 2;
    }

    return main(argc, argv);
}

#endif /* HPPA64_MINILIB_H */
