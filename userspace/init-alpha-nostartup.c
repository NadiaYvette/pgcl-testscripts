/*
 * Alpha init that bypasses glibc TLS initialization.
 * Provides its own _start that directly calls our init function
 * without going through __libc_start_main.
 *
 * Uses inline asm for mount/fork/exec/wait/write/reboot syscalls
 * to avoid any glibc function calls that could trigger TLS init.
 */
#define _GNU_SOURCE
#include <sys/syscall.h>
#include <asm/unistd.h>
#include <linux/reboot.h>
#include <stddef.h>

/* Alpha syscall inline asm */
static long syscall0(long nr)
{
	register long v0 __asm__("$0") = nr;
	register long a3 __asm__("$19");
	__asm__ volatile ("callsys"
		: "=r"(v0), "=r"(a3)
		: "r"(v0)
		: "$1","$2","$3","$4","$5","$6","$7","$8",
		  "$16","$17","$18","$20","$21","$22","$23","$24","$25","memory");
	return v0;
}

static long syscall1(long nr, long a)
{
	register long v0 __asm__("$0") = nr;
	register long a0 __asm__("$16") = a;
	register long a3 __asm__("$19");
	__asm__ volatile ("callsys"
		: "=r"(v0), "=r"(a3)
		: "r"(v0), "r"(a0)
		: "$1","$2","$3","$4","$5","$6","$7","$8",
		  "$17","$18","$20","$21","$22","$23","$24","$25","memory");
	return v0;
}

static long syscall3(long nr, long a, long b, long c)
{
	register long v0 __asm__("$0") = nr;
	register long a0 __asm__("$16") = a;
	register long a1 __asm__("$17") = b;
	register long a2 __asm__("$18") = c;
	register long a3 __asm__("$19");
	__asm__ volatile ("callsys"
		: "=r"(v0), "=r"(a3)
		: "r"(v0), "r"(a0), "r"(a1), "r"(a2)
		: "$1","$2","$3","$4","$5","$6","$7","$8",
		  "$20","$21","$22","$23","$24","$25","memory");
	return v0;
}

static long syscall5(long nr, long a, long b, long c, long d, long e)
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
	return v0;
}

/* Wrappers */
static void my_write(const char *buf, long len)
{
	syscall3(__NR_write, 1, (long)buf, len);
}

static __attribute__((noinline)) long my_strlen(const char *s)
{
	long len = 0;
	while (s[len]) len++;
	return len;
}

static void write_str(const char *s)
{
	my_write(s, my_strlen(s));
}

static long my_fork(void)
{
	return syscall0(__NR_fork);
}

static void my_execve(const char *path)
{
	/* Build argv on stack: {path, NULL} */
	const char *argv[2] = { path, NULL };
	const char *envp[1] = { NULL };
	syscall3(__NR_execve, (long)path, (long)argv, (long)envp);
}

static long my_wait4(long pid, int *status)
{
	return syscall3(__NR_wait4, pid, (long)status, 0);
}

static void my_mount(const char *src, const char *tgt, const char *type)
{
	syscall5(__NR_mount, (long)src, (long)tgt, (long)type, 0, 0);
}

static void my_reboot(void)
{
	syscall3(__NR_reboot,
		 LINUX_REBOOT_MAGIC1,
		 LINUX_REBOOT_MAGIC2,
		 LINUX_REBOOT_CMD_POWER_OFF);
}

static int run(const char *path)
{
	long pid = my_fork();
	if (pid < 0) {
		write_str("fork failed\n");
		return 1;
	}
	if (pid == 0) {
		my_execve(path);
		write_str("execve failed\n");
		syscall1(__NR_exit, 1);
	}
	int status = 0;
	my_wait4(pid, &status);
	/* Check if killed by signal (WIFSIGNALED: low 7 bits non-zero, bit 7 = 0) */
	if ((status & 0x7f) != 0) {
		write_str("KILLED BY SIGNAL ");
		/* print signal number */
		char sbuf[4] = { '0' + ((status & 0x7f) / 10),
				 '0' + ((status & 0x7f) % 10), '\n', 0 };
		my_write(sbuf, 3);
		return 1;
	}
	/* WEXITSTATUS */
	return (status >> 8) & 0xff;
}

void pgcl_init(void)
{
	my_mount("proc",     "/proc",  "proc");
	my_mount("sysfs",    "/sys",   "sysfs");
	my_mount("devtmpfs", "/dev",   "devtmpfs");
	my_mount("tmpfs",    "/tmp",   "tmpfs");

	write_str("========================================\n");
	write_str(" PGCL Boot Test - alpha\n");
	write_str("========================================\n");

	int total_fail = 0;

	write_str("\n--- Running PGCL basic tests ---\n");
	total_fail += run("/bin/pgcl-test");

	write_str("\n--- Running PGCL stress tests ---\n");
	total_fail += run("/bin/pgcl-stress");

	if (total_fail == 0)
		write_str("\nALL TESTS PASSED\n");
	else
		write_str("\nSOME TESTS FAILED\n");

	write_str("\nPowering off...\n");
	my_reboot();

	/* unreachable */
	for (;;) ;
}

/* Override __libc_start_main to bypass glibc TLS initialization.
 * The CRT startup files call __libc_start_main(main, argc, argv, ...).
 * We intercept here and call pgcl_init() directly. */
int __libc_start_main(int (*main)(int, char **, char **),
		      int argc, char **argv,
		      void *init, void *fini, void *rtld_fini,
		      void *stack_end)
{
	(void)main; (void)argc; (void)argv;
	(void)init; (void)fini; (void)rtld_fini; (void)stack_end;
	pgcl_init();
	return 0;
}

int main(void) { return 0; }
