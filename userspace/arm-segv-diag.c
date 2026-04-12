/*
 * arm-segv-diag.c - Diagnose ARM32 PGCL SIGSEGV pattern
 * Tests various operations that fail on ARM32 with MMUSHIFT=4
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <unistd.h>

static volatile sig_atomic_t got_segv;
static volatile void *segv_addr;

static void segv_handler(int sig, siginfo_t *info, void *ctx)
{
	char buf[128];
	int len = 0;
	unsigned long addr = (unsigned long)info->si_addr;
	unsigned long sp;

	__asm__ volatile("mov %0, sp" : "=r" (sp));

	/* Write diagnostic using write() syscall directly */
	len = snprintf(buf, sizeof(buf),
		"  SIGSEGV at addr=0x%08lx sp=0x%08lx si_code=%d\n",
		addr, sp, info->si_code);
	write(1, buf, len);
	_exit(139);
}

static void install_handler(void)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = segv_handler;
	sa.sa_flags = SA_SIGINFO;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
}

static int run_child(const char *desc, void (*fn)(void))
{
	int status;
	pid_t pid;

	printf("  %-55s ", desc);
	fflush(stdout);

	pid = fork();
	if (pid < 0) {
		printf("FAIL fork: %s\n", strerror(errno));
		return 1;
	}
	if (pid == 0) {
		install_handler();
		fn();
		_exit(0);
	}
	waitpid(pid, &status, 0);
	if (WIFSIGNALED(status)) {
		printf("FAIL (signal %d)\n", WTERMSIG(status));
		return 1;
	}
	if (WIFEXITED(status) && WEXITSTATUS(status) == 139) {
		printf("FAIL (SIGSEGV caught)\n");
		return 1;
	}
	if (WIFEXITED(status) && WEXITSTATUS(status)) {
		printf("FAIL (exit %d)\n", WEXITSTATUS(status));
		return 1;
	}
	printf("PASS\n");
	return 0;
}

/* Test 1: tmpfile + mmap shared + fork */
static void test_tmpfile_mmap_shared(void)
{
	FILE *f = tmpfile();
	if (!f) _exit(1);
	ftruncate(fileno(f), 4096);
	void *p = mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_SHARED, fileno(f), 0);
	if (p == MAP_FAILED) _exit(2);
	*(volatile int *)p = 0xdeadbeef;
	msync(p, 4096, MS_SYNC);
	munmap(p, 4096);
	fclose(f);
}

/* Test 2: tmpfile + mmap private + MAP_POPULATE */
static void test_tmpfile_populate(void)
{
	FILE *f = tmpfile();
	if (!f) _exit(1);
	ftruncate(fileno(f), 4096);
	/* First write something */
	unsigned long val = 0xdeadbabe;
	write(fileno(f), &val, sizeof(val));
	lseek(fileno(f), 0, SEEK_SET);
	/* Map private+populate */
	void *p = mmap(NULL, 4096, PROT_READ|PROT_WRITE,
			MAP_PRIVATE|MAP_POPULATE, fileno(f), 0);
	if (p == MAP_FAILED) _exit(2);
	if (*(volatile unsigned long *)p != 0xdeadbabe) _exit(3);
	munmap(p, 4096);
	fclose(f);
}

/* Test 3: open/write/read a file (what fork01 child does) */
static void test_file_io(void)
{
	int fd = open("testfile", O_CREAT|O_RDWR|O_TRUNC, 0644);
	if (fd < 0) _exit(1);
	char buf[64];
	int len = snprintf(buf, sizeof(buf), "%d", getpid());
	if (write(fd, buf, len) != len) _exit(2);
	lseek(fd, 0, SEEK_SET);
	char rbuf[64] = {0};
	if (read(fd, rbuf, len) != len) _exit(3);
	close(fd);
	unlink("testfile");
}

/* Test 4: mmap anonymous + write + fork + child read */
static void test_anon_cow(void)
{
	void *p = mmap(NULL, 4096, PROT_READ|PROT_WRITE,
			MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) _exit(1);
	*(volatile int *)p = 42;

	pid_t child = fork();
	if (child < 0) _exit(2);
	if (child == 0) {
		/* child: verify we can read the value */
		if (*(volatile int *)p != 42) _exit(10);
		/* child: write (trigger COW) */
		*(volatile int *)p = 99;
		_exit(0);
	}
	int status;
	waitpid(child, &status, 0);
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) _exit(3);
	munmap(p, 4096);
}

/* Test 5: mmap 64K region (one kernel page worth) */
static void test_mmap_64k(void)
{
	void *p = mmap(NULL, 65536, PROT_READ|PROT_WRITE,
			MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) _exit(1);
	/* Touch every 4K sub-page */
	for (int i = 0; i < 16; i++)
		*((volatile char *)p + i * 4096) = i;
	/* Verify */
	for (int i = 0; i < 16; i++)
		if (*((volatile char *)p + i * 4096) != i) _exit(2);
	munmap(p, 65536);
}

/* Test 6: creat + write in tmpdir (LTP old-API pattern) */
static void test_creat_in_tmpdir(void)
{
	char tmpd[] = "/tmp/diag_XXXXXX";
	if (!mkdtemp(tmpd)) _exit(1);
	if (chdir(tmpd) < 0) _exit(2);

	int fd = open("output", O_CREAT|O_RDWR|O_TRUNC, 0644);
	if (fd < 0) _exit(3);
	char *msg = "hello world\n";
	write(fd, msg, strlen(msg));
	close(fd);

	unlink("output");
	chdir("/");
	rmdir(tmpd);
}

/* Test 7: fork + file write in child in tmpdir (exact LTP fork01 pattern) */
static void test_fork_filewrite_tmpdir(void)
{
	char tmpd[] = "/tmp/diag_XXXXXX";
	if (!mkdtemp(tmpd)) _exit(1);
	if (chdir(tmpd) < 0) _exit(2);

	pid_t child = fork();
	if (child < 0) _exit(3);
	if (child == 0) {
		install_handler();
		int fd = open("childpid", O_CREAT|O_RDWR|O_TRUNC, 0700);
		if (fd < 0) _exit(10);
		char buf[32];
		int len = snprintf(buf, sizeof(buf), "%d", getpid());
		write(fd, buf, len);
		close(fd);
		_exit(42);
	}
	int status;
	waitpid(child, &status, 0);
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 42) {
		chdir("/");
		rmdir(tmpd);
		_exit(4);
	}

	/* Read it back */
	int fd = open("childpid", O_RDONLY);
	if (fd < 0) { chdir("/"); rmdir(tmpd); _exit(5); }
	char buf[32] = {0};
	read(fd, buf, sizeof(buf)-1);
	close(fd);

	int cpid = atoi(buf);
	if (cpid != child) { chdir("/"); rmdir(tmpd); _exit(6); }

	unlink("childpid");
	chdir("/");
	rmdir(tmpd);
}

/* Test 8: mmap file + MAP_POPULATE (exact map_populate pattern) */
static void test_file_map_populate(void)
{
	char tmpf[] = "/tmp/mp_XXXXXX";
	int fd = mkstemp(tmpf);
	if (fd < 0) _exit(1);
	unlink(tmpf);
	ftruncate(fd, 4096);

	/* Write a value */
	unsigned long val = 0xdeadbabe;
	write(fd, &val, sizeof(val));

	/* Map shared first */
	void *shared = mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
	if (shared == MAP_FAILED) _exit(2);
	*(unsigned long *)shared = 0xdeadbabe;
	msync(shared, 4096, MS_SYNC);

	/* Map private + populate */
	void *priv = mmap(NULL, 4096, PROT_READ|PROT_WRITE,
			MAP_PRIVATE|MAP_POPULATE, fd, 0);
	if (priv == MAP_FAILED) _exit(3);

	/* Verify populate worked */
	if (*(unsigned long *)priv != 0xdeadbabe) _exit(4);

	/* Write to shared, verify private didn't change (COW) */
	*(unsigned long *)shared = 0x22222BAD;
	msync(shared, 4096, MS_SYNC);
	if (*(unsigned long *)priv == 0x22222BAD) _exit(5); /* COW failed */

	munmap(shared, 4096);
	munmap(priv, 4096);
	close(fd);
}

/* Test 9: mmap /dev/zero (what mmap01 does) */
static void test_mmap_devzero(void)
{
	int fd = open("/dev/zero", O_RDONLY);
	if (fd < 0) _exit(1);
	void *p = mmap(NULL, 4096, PROT_READ, MAP_PRIVATE, fd, 0);
	if (p == MAP_FAILED) _exit(2);
	if (*(volatile char *)p != 0) _exit(3);
	munmap(p, 4096);
	close(fd);
}

/* Test 10: nested fork (fork01 does multiple forks) */
static void test_multi_fork(void)
{
	for (int i = 0; i < 5; i++) {
		pid_t child = fork();
		if (child < 0) _exit(1);
		if (child == 0) {
			volatile char buf[256];
			memset((char *)buf, i, sizeof(buf));
			_exit(42);
		}
		int status;
		waitpid(child, &status, 0);
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 42) _exit(2);
	}
}

/* Test 11: mmap 1MB then mprotect parts */
static void test_mmap_mprotect_large(void)
{
	size_t sz = 1024 * 1024;
	void *p = mmap(NULL, sz, PROT_READ|PROT_WRITE,
			MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) _exit(1);
	/* Touch all pages */
	for (size_t off = 0; off < sz; off += 4096)
		*((volatile char *)p + off) = 'A';
	/* mprotect middle portion to NONE then back */
	mprotect((char *)p + 4096*4, 4096*8, PROT_NONE);
	mprotect((char *)p + 4096*4, 4096*8, PROT_READ|PROT_WRITE);
	/* Touch again */
	for (size_t off = 4096*4; off < 4096*12; off += 4096)
		*((volatile char *)p + off) = 'B';
	munmap(p, sz);
}

/* Test 12: socketpair + fork (map_populate uses this) */
static void test_socketpair_fork(void)
{
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) < 0) _exit(1);

	pid_t child = fork();
	if (child < 0) _exit(2);
	if (child == 0) {
		close(sv[1]);
		int val = 42;
		write(sv[0], &val, sizeof(val));
		close(sv[0]);
		_exit(0);
	}
	close(sv[0]);
	int val = 0;
	read(sv[1], &val, sizeof(val));
	close(sv[1]);
	int status;
	waitpid(child, &status, 0);
	if (val != 42) _exit(3);
}

int main(void)
{
	int fail = 0;
	unsigned long sp;
	__asm__ volatile("mov %0, sp" : "=r" (sp));

	printf("=== ARM32 PGCL SIGSEGV diagnosis ===\n");
	printf("Page size: %ld\n", sysconf(_SC_PAGESIZE));
	printf("SP: 0x%lx\n\n", sp);

	install_handler();

	printf("--- Basic operations (no fork wrapper) ---\n");
	fail += run_child("tmpfile + mmap shared", test_tmpfile_mmap_shared);
	fail += run_child("tmpfile + MAP_PRIVATE + MAP_POPULATE", test_tmpfile_populate);
	fail += run_child("open/write/read file", test_file_io);
	fail += run_child("anon mmap + fork + COW", test_anon_cow);
	fail += run_child("mmap 64K (full kernel page)", test_mmap_64k);
	fail += run_child("creat+write in tmpdir", test_creat_in_tmpdir);
	fail += run_child("fork + file write in tmpdir (LTP fork01)", test_fork_filewrite_tmpdir);
	fail += run_child("file mmap + MAP_POPULATE (selftest pattern)", test_file_map_populate);
	fail += run_child("mmap /dev/zero", test_mmap_devzero);
	fail += run_child("multi fork (5x)", test_multi_fork);
	fail += run_child("mmap 1MB + mprotect", test_mmap_mprotect_large);
	fail += run_child("socketpair + fork", test_socketpair_fork);

	printf("\n=== Result: %d failures ===\n", fail);
	return fail;
}
