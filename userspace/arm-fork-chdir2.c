/*
 * arm-fork-chdir2.c - More focused fork+chdir reproducer
 * Tests various conditions to isolate the exact trigger
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

static int do_fork_test(const char *desc)
{
	int status;
	pid_t pid;

	printf("  %-50s ", desc);
	fflush(stdout);

	pid = fork();
	if (pid < 0) {
		printf("FAIL: fork: %s\n", strerror(errno));
		return 1;
	}
	if (pid == 0) {
		/* Child: touch the stack a bit */
		volatile char buf[256];
		memset((char*)buf, 'A', sizeof(buf));
		buf[0] = buf[255]; /* prevent optimization */
		_exit(0);
	}
	waitpid(pid, &status, 0);
	if (WIFSIGNALED(status)) {
		printf("FAIL (signal %d)\n", WTERMSIG(status));
		return 1;
	}
	if (WIFEXITED(status) && WEXITSTATUS(status)) {
		printf("FAIL (exit %d)\n", WEXITSTATUS(status));
		return 1;
	}
	printf("PASS\n");
	return 0;
}

int main(void)
{
	int fail = 0;
	char tmpdir[] = "/tmp/test_XXXXXX";

	printf("=== fork-chdir deep diagnosis ===\n");
	printf("Page size: %ld\n\n", sysconf(_SC_PAGESIZE));

	/* Test 1: plain fork in root */
	chdir("/");
	fail += do_fork_test("fork in /");

	/* Test 2: fork in /tmp */
	chdir("/tmp");
	fail += do_fork_test("fork in /tmp");

	/* Test 3: mkdir in /tmp, DON'T chdir, fork */
	mkdir("/tmp/testdir1", 0755);
	fail += do_fork_test("fork after mkdir (no chdir)");
	rmdir("/tmp/testdir1");

	/* Test 4: mkdir in /tmp, chdir, fork */
	mkdir("/tmp/testdir2", 0755);
	chdir("/tmp/testdir2");
	fail += do_fork_test("fork after mkdir+chdir /tmp/testdir2");
	chdir("/tmp");
	rmdir("/tmp/testdir2");

	/* Test 5: mkdtemp, DON'T chdir, fork */
	if (mkdtemp(tmpdir)) {
		fail += do_fork_test("fork after mkdtemp (no chdir)");
		rmdir(tmpdir);
	}

	/* Test 6: mkdir on rootfs (not tmpfs), chdir, fork */
	mkdir("/testdir3", 0755);
	if (chdir("/testdir3") == 0) {
		fail += do_fork_test("fork after mkdir+chdir /testdir3 (rootfs)");
		chdir("/");
	} else {
		printf("  %-50s SKIP (chdir failed)\n", "fork after mkdir+chdir /testdir3");
	}
	rmdir("/testdir3");

	/* Test 7: mkdtemp, chdir, fork — the known failure */
	{
		char tmpdir2[] = "/tmp/test2_XXXXXX";
		if (mkdtemp(tmpdir2)) {
			chdir(tmpdir2);
			fail += do_fork_test("fork after mkdtemp+chdir (KNOWN FAIL)");
			chdir("/tmp");
			rmdir(tmpdir2);
		}
	}

	/* Test 8: mkdir on /dev/shm (also tmpfs), chdir, fork */
	mkdir("/dev/shm/testdir4", 0755);
	if (chdir("/dev/shm/testdir4") == 0) {
		fail += do_fork_test("fork after mkdir+chdir /dev/shm/testdir4");
		chdir("/tmp");
	}
	rmdir("/dev/shm/testdir4");

	/* Test 9: chdir to /tmp subdir created by shell (mkdir -p) */
	system("mkdir -p /tmp/shelldir");
	if (chdir("/tmp/shelldir") == 0) {
		fail += do_fork_test("fork after chdir to shell-created /tmp/shelldir");
		chdir("/tmp");
	}
	system("rmdir /tmp/shelldir");

	/* Test 10: multiple levels of nesting */
	mkdir("/tmp/a", 0755);
	mkdir("/tmp/a/b", 0755);
	mkdir("/tmp/a/b/c", 0755);
	chdir("/tmp/a/b/c");
	fail += do_fork_test("fork in /tmp/a/b/c (3 levels deep)");
	chdir("/tmp");
	rmdir("/tmp/a/b/c");
	rmdir("/tmp/a/b");
	rmdir("/tmp/a");

	printf("\n=== Result: %d failures ===\n", fail);
	return fail;
}
