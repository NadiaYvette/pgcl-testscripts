/*
 * arm-fork-chdir.c - Minimal reproducer: fork after chdir to various paths
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>

static void test_fork_after_chdir(const char *desc, const char *dir, int create)
{
	char tmpdir[256];
	int status;
	pid_t pid;

	printf("  %-45s ", desc);
	fflush(stdout);

	if (create) {
		snprintf(tmpdir, sizeof(tmpdir), "%s/forktest_XXXXXX", dir);
		if (!mkdtemp(tmpdir)) {
			printf("FAIL: mkdtemp(%s): %s\n", tmpdir, strerror(errno));
			return;
		}
		dir = tmpdir;
	}

	if (chdir(dir)) {
		printf("SKIP: chdir(%s): %s\n", dir, strerror(errno));
		return;
	}

	pid = fork();
	if (pid < 0) {
		printf("FAIL: fork: %s\n", strerror(errno));
		goto out;
	}
	if (pid == 0) {
		/* Child: do minimal work */
		char cwd[256];
		getcwd(cwd, sizeof(cwd));
		_exit(0);
	}
	waitpid(pid, &status, 0);

	if (WIFSIGNALED(status))
		printf("FAIL (signal %d)\n", WTERMSIG(status));
	else if (WIFEXITED(status) && WEXITSTATUS(status))
		printf("FAIL (exit %d)\n", WEXITSTATUS(status));
	else
		printf("PASS\n");

out:
	chdir("/");
	if (create)
		rmdir(tmpdir);
}

static void test_fork_no_chdir(void)
{
	int status;
	pid_t pid;

	printf("  %-45s ", "fork without any chdir");
	fflush(stdout);

	pid = fork();
	if (pid < 0) {
		printf("FAIL: fork: %s\n", strerror(errno));
		return;
	}
	if (pid == 0)
		_exit(0);
	waitpid(pid, &status, 0);
	if (WIFSIGNALED(status))
		printf("FAIL (signal %d)\n", WTERMSIG(status));
	else
		printf("PASS\n");
}

int main(void)
{
	printf("=== fork-after-chdir test ===\n");
	printf("Page size: %ld\n\n", sysconf(_SC_PAGESIZE));

	test_fork_no_chdir();
	test_fork_after_chdir("fork after chdir /", "/", 0);
	test_fork_after_chdir("fork after chdir /proc", "/proc", 0);
	test_fork_after_chdir("fork after chdir /sys", "/sys", 0);
	test_fork_after_chdir("fork after chdir /dev", "/dev", 0);
	test_fork_after_chdir("fork after chdir /tmp (tmpfs)", "/tmp", 0);
	test_fork_after_chdir("fork after mkdtemp+chdir in /tmp", "/tmp", 1);
	test_fork_after_chdir("fork after chdir /dev/shm (tmpfs)", "/dev/shm", 0);
	test_fork_after_chdir("fork after mkdtemp+chdir in /dev/shm", "/dev/shm", 1);

	/* Test multiple forks in tmpdir */
	printf("\n--- Multiple forks in /tmp ---\n");
	chdir("/tmp");
	for (int i = 0; i < 5; i++) {
		char desc[64];
		snprintf(desc, sizeof(desc), "fork #%d in /tmp", i+1);
		printf("  %-45s ", desc);
		fflush(stdout);
		pid_t pid = fork();
		if (pid < 0) {
			printf("FAIL: fork\n");
			continue;
		}
		if (pid == 0)
			_exit(0);
		int status;
		waitpid(pid, &status, 0);
		if (WIFSIGNALED(status))
			printf("FAIL (signal %d)\n", WTERMSIG(status));
		else
			printf("PASS\n");
	}

	printf("\n=== Done ===\n");
	return 0;
}
