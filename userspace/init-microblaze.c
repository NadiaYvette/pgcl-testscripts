/* Minimal init for microblaze test — runs pgcl-test and pgcl-stress directly */
#include <unistd.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <string.h>
#include <stdlib.h>

static void write_str(int fd, const char *s)
{
	write(fd, s, strlen(s));
}

static int run_program(const char *path, const char *arg)
{
	pid_t pid = fork();
	if (pid < 0) {
		write_str(2, "FAIL: fork() failed\n");
		return -1;
	}
	if (pid == 0) {
		char *argv[] = { (char *)path, (char *)arg, NULL };
		char *envp[] = { "HOME=/", "TERM=linux", NULL };
		execve(path, argv, envp);
		write_str(2, "FAIL: execve failed for ");
		write_str(2, path);
		write_str(2, "\n");
		_exit(127);
	}
	int status;
	waitpid(pid, &status, 0);
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

int main(void)
{
	int rc;

	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

	write_str(1, "\n========================================\n");
	write_str(1, " PGCL Boot Test - microblaze\n");
	write_str(1, "========================================\n");

	write_str(1, "--- Running PGCL basic tests ---\n");
	rc = run_program("/bin/pgcl-test", "-a");
	if (rc == 0)
		write_str(1, "pgcl-test: ALL PASSED\n");
	else
		write_str(1, "pgcl-test: SOME FAILED\n");

	write_str(1, "--- Running PGCL stress tests ---\n");
	rc = run_program("/bin/pgcl-stress", "-a");
	if (rc == 0)
		write_str(1, "pgcl-stress: ALL PASSED\n");
	else
		write_str(1, "pgcl-stress: SOME FAILED\n");

	write_str(1, "\n========================================\n");
	write_str(1, " Test Complete\n");
	write_str(1, "========================================\n");

	sync();
	reboot(0x4321fedc); /* RB_POWER_OFF */
	return 0;
}
