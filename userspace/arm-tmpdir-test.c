/*
 * arm-tmpdir-test.c - Minimal reproducer for ARM32 PGCL tmpdir SIGSEGV
 *
 * Tests file-backed operations after chdir() to tmpfs, which is the
 * pattern that triggers SIGSEGV in 39 of 40 failing LTP tests on ARM32
 * with PAGE_MMUSHIFT=4.
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
#include <signal.h>
#include <errno.h>

static volatile int got_signal = 0;
static void sighandler(int sig) { got_signal = sig; }

#define CHECK(cond, msg) do { \
	if (!(cond)) { \
		printf("  FAIL: %s: %s (errno=%d)\n", msg, strerror(errno), errno); \
		return 1; \
	} \
} while (0)

/* Test 1: creat+write+read in tmpdir */
static int test_file_io_in_tmpdir(void)
{
	char buf[4096];
	int fd, ret;

	printf("  test_file_io_in_tmpdir: ");

	fd = open("testfile1", O_CREAT | O_RDWR | O_TRUNC, 0644);
	CHECK(fd >= 0, "open");

	memset(buf, 'A', sizeof(buf));
	ret = write(fd, buf, sizeof(buf));
	CHECK(ret == sizeof(buf), "write");

	lseek(fd, 0, SEEK_SET);
	memset(buf, 0, sizeof(buf));
	ret = read(fd, buf, sizeof(buf));
	CHECK(ret == sizeof(buf), "read");
	CHECK(buf[0] == 'A' && buf[4095] == 'A', "data verify");

	close(fd);
	unlink("testfile1");
	printf("PASS\n");
	return 0;
}

/* Test 2: mmap a file in tmpdir */
static int test_mmap_file_in_tmpdir(void)
{
	int fd;
	char *p;

	printf("  test_mmap_file_in_tmpdir: ");

	fd = open("testfile2", O_CREAT | O_RDWR | O_TRUNC, 0644);
	CHECK(fd >= 0, "open");

	CHECK(ftruncate(fd, 4096) == 0, "ftruncate");

	p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	CHECK(p != MAP_FAILED, "mmap");

	memset(p, 'B', 4096);
	msync(p, 4096, MS_SYNC);

	/* Verify via read */
	char buf[4096];
	lseek(fd, 0, SEEK_SET);
	CHECK(read(fd, buf, 4096) == 4096, "read");
	CHECK(buf[0] == 'B' && buf[4095] == 'B', "mmap data verify");

	munmap(p, 4096);
	close(fd);
	unlink("testfile2");
	printf("PASS\n");
	return 0;
}

/* Test 3: fork + file I/O in tmpdir */
static int test_fork_file_in_tmpdir(void)
{
	int fd, status;
	pid_t pid;

	printf("  test_fork_file_in_tmpdir: ");

	fd = open("testfile3", O_CREAT | O_RDWR | O_TRUNC, 0644);
	CHECK(fd >= 0, "open");
	CHECK(write(fd, "hello", 5) == 5, "write");
	close(fd);

	pid = fork();
	CHECK(pid >= 0, "fork");

	if (pid == 0) {
		/* Child: read the file */
		char buf[5];
		fd = open("testfile3", O_RDONLY);
		if (fd < 0 || read(fd, buf, 5) != 5 || memcmp(buf, "hello", 5)) {
			_exit(1);
		}
		close(fd);
		_exit(0);
	}

	waitpid(pid, &status, 0);
	CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0, "child verify");

	unlink("testfile3");
	printf("PASS\n");
	return 0;
}

/* Test 4: signal handler setup (mimics tst_sig) */
static int test_signal_setup(void)
{
	struct sigaction sa;
	int i;

	printf("  test_signal_setup: ");

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = sighandler;
	sigemptyset(&sa.sa_mask);

	for (i = 1; i < 32; i++) {
		if (i == SIGKILL || i == SIGSTOP || i == SIGCHLD)
			continue;
		if (sigaction(i, &sa, NULL) < 0) {
			/* Some signals can't be caught, that's fine */
		}
	}

	/* Raise and catch SIGUSR1 */
	got_signal = 0;
	raise(SIGUSR1);
	CHECK(got_signal == SIGUSR1, "signal caught");

	printf("PASS\n");
	return 0;
}

/* Test 5: getcwd after chdir to tmpdir */
static int test_getcwd(void)
{
	char buf[256];

	printf("  test_getcwd: ");
	CHECK(getcwd(buf, sizeof(buf)) != NULL, "getcwd");
	CHECK(strstr(buf, "/tmp") != NULL, "cwd contains /tmp");
	printf("PASS (%s)\n", buf);
	return 0;
}

/* Test 6: larger file write + mmap (mimics LTP pattern more closely) */
static int test_large_file_mmap(void)
{
	int fd;
	size_t sz = 65536; /* PAGE_SIZE on PGCL */
	char *p;
	char buf[4096];

	printf("  test_large_file_mmap: ");

	fd = open("testfile6", O_CREAT | O_RDWR | O_TRUNC, 0644);
	CHECK(fd >= 0, "open");

	/* Write in 4KB chunks */
	for (size_t off = 0; off < sz; off += 4096) {
		memset(buf, (char)(off >> 12), 4096);
		CHECK(write(fd, buf, 4096) == 4096, "write chunk");
	}

	/* mmap full range */
	p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	CHECK(p != MAP_FAILED, "mmap");

	/* Verify each chunk */
	for (size_t off = 0; off < sz; off += 4096) {
		CHECK(p[off] == (char)(off >> 12), "mmap verify");
	}

	/* Write through mapping */
	memset(p, 'X', sz);
	msync(p, sz, MS_SYNC);

	/* Verify via read */
	lseek(fd, 0, SEEK_SET);
	CHECK(read(fd, buf, 4096) == 4096, "read back");
	CHECK(buf[0] == 'X', "write-through verify");

	munmap(p, sz);
	close(fd);
	unlink("testfile6");
	printf("PASS\n");
	return 0;
}

/* Test 7: stat after file creation */
static int test_stat_in_tmpdir(void)
{
	struct stat st;
	int fd;

	printf("  test_stat_in_tmpdir: ");

	fd = open("testfile7", O_CREAT | O_WRONLY | O_TRUNC, 0644);
	CHECK(fd >= 0, "open");
	CHECK(write(fd, "data", 4) == 4, "write");
	close(fd);

	CHECK(stat("testfile7", &st) == 0, "stat");
	CHECK(st.st_size == 4, "size check");

	unlink("testfile7");
	printf("PASS\n");
	return 0;
}

int main(void)
{
	int fail = 0;
	char tmpdir[] = "/tmp/arm-pgcl-XXXXXX";

	printf("=== ARM32 PGCL tmpdir reproducer ===\n");
	printf("Page size: %ld\n", sysconf(_SC_PAGESIZE));

	/* Phase 1: Tests without chdir (should all pass) */
	printf("\n--- Phase 1: Tests in /tmp (no chdir) ---\n");
	fail += test_signal_setup();

	/* Phase 2: Create tmpdir and chdir into it (mimics tst_tmpdir) */
	if (!mkdtemp(tmpdir)) {
		printf("FAIL: mkdtemp: %s\n", strerror(errno));
		return 1;
	}
	printf("\n--- Phase 2: After chdir to %s ---\n", tmpdir);
	if (chdir(tmpdir)) {
		printf("FAIL: chdir: %s\n", strerror(errno));
		return 1;
	}

	fail += test_getcwd();
	fail += test_signal_setup();
	fail += test_file_io_in_tmpdir();
	fail += test_mmap_file_in_tmpdir();
	fail += test_fork_file_in_tmpdir();
	fail += test_stat_in_tmpdir();
	fail += test_large_file_mmap();

	/* Cleanup */
	chdir("/tmp");
	rmdir(tmpdir);

	printf("\n=== Result: %d failures ===\n", fail);
	return fail ? 1 : 0;
}
