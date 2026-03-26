/*
 * Minimal nolibc init for PGCL test initramfs
 *
 * Mounts proc/sys/dev, runs /bin/pgcl-test and /bin/pgcl-stress,
 * then powers off.
 *
 * Compile: $CC -static -O2 -nostdlib -nostdinc \
 *   -isystem $LINUX/tools/include/nolibc \
 *   -include nolibc.h -o init-alpha init-nolibc.c -lgcc
 */
#define _GNU_SOURCE
#include "nolibc.h"
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/reboot.h>
#include <linux/reboot.h>

static void do_mount(const char *src, const char *tgt, const char *type)
{
	if (mount(src, tgt, type, 0, NULL) < 0) {
		/* ignore errors — may already be mounted */
	}
}

static int run(const char *path)
{
	int pid = fork();
	if (pid < 0) {
		write(1, "fork failed\n", 12);
		return 1;
	}
	if (pid == 0) {
		char *argv[] = { (char *)path, NULL };
		char *envp[] = { NULL };
		execve(path, argv, envp);
		write(1, "execve failed\n", 14);
		exit(1);
	}
	int status = 0;
	waitpid(pid, &status, 0);
	return WEXITSTATUS(status);
}

int main(void)
{
	do_mount("proc",     "/proc",  "proc");
	do_mount("sysfs",    "/sys",   "sysfs");
	do_mount("devtmpfs", "/dev",   "devtmpfs");

	write(1, "========================================\n", 41);
	write(1, " PGCL Boot Test - alpha\n", 24);
	write(1, "========================================\n", 41);

	int total_fail = 0;

	write(1, "\n--- Running PGCL basic tests ---\n", 34);
	total_fail += run("/bin/pgcl-test");

	write(1, "\n--- Running PGCL stress tests ---\n", 35);
	total_fail += run("/bin/pgcl-stress");

	if (total_fail == 0)
		write(1, "\nALL TESTS PASSED\n", 18);
	else
		write(1, "\nSOME TESTS FAILED\n", 19);

	write(1, "\nPowering off...\n", 17);

	/* sys_reboot(LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
	 *            LINUX_REBOOT_CMD_POWER_OFF, NULL) */
	my_syscall4(__NR_reboot,
		    LINUX_REBOOT_MAGIC1,
		    LINUX_REBOOT_MAGIC2,
		    LINUX_REBOOT_CMD_POWER_OFF,
		    0);

	/* unreachable */
	for (;;) ;
	return 0;
}
