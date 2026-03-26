/*
 * Alpha PGCL init: raw syscall-based init for alpha PGCL testing.
 * 
 * Bypasses glibc entirely to avoid the TLS crash (glibc 2.41 on alpha
 * with PGCL: flush_thread zeros pcb.unique, glibc's _dl_allocate_tls_init
 * asserts l != NULL in __cxa_atexit).
 *
 * Uses inline fork/exec/wait to avoid stack corruption issue with
 * function-call-based run() after child signal death.
 */
#define _GNU_SOURCE
#include <sys/syscall.h>
#include <asm/unistd.h>
#include <linux/reboot.h>
#include <stddef.h>

char __alpha_tls_block[8192] __attribute__((aligned(64)));

static long sys3(long nr, long a, long b, long c)
{
    register long v0 __asm__("$0") = nr;
    register long a0 __asm__("$16") = a;
    register long a1 __asm__("$17") = b;
    register long a2 __asm__("$18") = c;
    register long a3 __asm__("$19") = 0;
    __asm__ volatile ("callsys"
        : "+r"(v0), "+r"(a3)
        : "r"(a0), "r"(a1), "r"(a2)
        : "$1","$2","$3","$4","$5","$6","$7","$8",
          "$20","$21","$22","$23","$24","$25","memory");
    return a3 ? -v0 : v0;
}

static long sys5(long nr, long a, long b, long c, long d, long e)
{
    register long v0 __asm__("$0") = nr;
    register long a0 __asm__("$16") = a;
    register long a1 __asm__("$17") = b;
    register long a2 __asm__("$18") = c;
    register long a3 __asm__("$19") = d;
    register long a4 __asm__("$20") = e;
    register long err __asm__("$19");
    __asm__ volatile ("callsys"
        : "=r"(v0), "=r"(err)
        : "r"(v0), "r"(a0), "r"(a1), "r"(a2), "r"(a3), "r"(a4)
        : "$1","$2","$3","$4","$5","$6","$7","$8",
          "$21","$22","$23","$24","$25","memory");
    return err ? -v0 : v0;
}

static void wr(const char *s)
{
    long n = 0;
    while (s[n]) n++;
    sys3(__NR_write, 1, (long)s, n);
}

/* Inline macro for fork+exec+wait to avoid stack corruption
 * that occurs when using a function-call-based run() wrapper
 * (parent SIGSEGV after child signal death on alpha PGCL). */
#define RUN(path, label, result_var) do { \
    static const char *_argv[2] = { path, NULL }; \
    static const char *_envp[1] = { NULL }; \
    wr(label); \
    long _pid = sys3(2 /* __NR_fork */, 0, 0, 0); \
    if (_pid == 0) { \
        sys3(__NR_execve, (long)(path), (long)_argv, (long)_envp); \
        sys3(__NR_exit, 127, 0, 0); \
        __builtin_unreachable(); \
    } \
    if (_pid > 0) { \
        int _st = 0; \
        sys3(__NR_wait4, _pid, (long)&_st, 0); \
        if ((_st & 0x7f) != 0) { \
            int _sig = _st & 0x7f; \
            wr("  KILLED BY SIGNAL "); \
            char _sb[3] = { '0' + _sig/10, '0' + _sig%10, '\n' }; \
            sys3(__NR_write, 1, (long)_sb, 3); \
            result_var = 1; \
        } else { \
            int _ex = (_st >> 8) & 0xff; \
            if (_ex != 0) { \
                wr("  EXIT CODE "); \
                char _eb[4] = { '0'+_ex/100, '0'+(_ex/10)%10, '0'+_ex%10, '\n' }; \
                sys3(__NR_write, 1, (long)_eb, 4); \
                result_var = 1; \
            } else { \
                result_var = 0; \
            } \
        } \
    } else { \
        wr("  fork failed\n"); \
        result_var = 1; \
    } \
} while(0)

void pgcl_init(void)
{
    sys5(__NR_mount, (long)"proc", (long)"/proc", (long)"proc", 0, 0);
    sys5(__NR_mount, (long)"sysfs", (long)"/sys", (long)"sysfs", 0, 0);
    sys5(__NR_mount, (long)"devtmpfs", (long)"/dev", (long)"devtmpfs", 0, 0);
    sys5(__NR_mount, (long)"tmpfs", (long)"/tmp", (long)"tmpfs", 0, 0);

    wr("========================================\n");
    wr(" PGCL Boot Test - alpha\n");
    wr("========================================\n\n");

    int r1 = 0, r2 = 0;

    RUN("/bin/pgcl-test", "--- Running PGCL basic tests ---\n", r1);
    RUN("/bin/pgcl-stress", "\n--- Running PGCL stress tests ---\n", r2);

    wr("\n========================================\n");
    if (r1 == 0 && r2 == 0)
        wr(" ALL TESTS PASSED\n");
    else
        wr(" SOME TESTS FAILED\n");
    wr("========================================\n");

    wr("\nPowering off...\n");
    sys3(__NR_reboot, (long)0xfee1dead, (long)0x28121969, (long)0x4321fedc);
    for (;;) ;
}
