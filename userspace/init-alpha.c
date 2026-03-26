/*
 * Minimal static init for PGCL alpha test initramfs.
 * Does not use nolibc — compiled against glibc sysroot, fully static.
 */
#define _GNU_SOURCE
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/reboot.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>

static int run(const char *path)
{
	pid_t pid = fork();
	if (pid < 0) {
		perror("fork");
		return 1;
	}
	if (pid == 0) {
		char *argv[] = { (char *)path, NULL };
		execv(path, argv);
		perror("execv");
		_exit(1);
	}
	int status = 0;
	waitpid(pid, &status, 0);
	return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

int main(void)
{
	mount("proc",     "/proc",  "proc",     0, NULL);
	mount("sysfs",    "/sys",   "sysfs",    0, NULL);
	mount("devtmpfs", "/dev",   "devtmpfs", 0, NULL);
	mount("tmpfs",    "/tmp",   "tmpfs",    0, NULL);

	puts("========================================");
	puts(" PGCL Boot Test - alpha");
	puts("========================================");

	int total_fail = 0;

	puts("\n--- Running PGCL basic tests ---");
	fflush(stdout);
	total_fail += run("/bin/pgcl-test");

	puts("\n--- Running PGCL stress tests ---");
	fflush(stdout);
	total_fail += run("/bin/pgcl-stress");

	if (total_fail == 0)
		puts("\nALL TESTS PASSED");
	else
		puts("\nSOME TESTS FAILED");

	puts("\nPowering off...");
	fflush(stdout);

	reboot(RB_POWER_OFF);
	for (;;) ;
	return 0;
}
