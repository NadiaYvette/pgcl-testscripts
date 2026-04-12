/*
 * arm-maps-diag.c - Dump /proc/self/maps and probe the segfault address
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
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void dump_maps(void)
{
	char buf[4096];
	int fd = open("/proc/self/maps", O_RDONLY);
	if (fd < 0) {
		printf("  Cannot open /proc/self/maps: no procfs?\n");
		return;
	}
	int n;
	while ((n = read(fd, buf, sizeof(buf))) > 0)
		write(1, buf, n);
	close(fd);
}

static void probe_addr_child(unsigned long addr, const char *desc)
{
	int status;
	pid_t pid = fork();
	if (pid == 0) {
		/* Install signal handler that prints and exits */
		struct sigaction sa;
		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = SIG_DFL;
		sigaction(SIGSEGV, &sa, NULL);

		volatile char c = *(volatile char *)addr;
		printf("  0x%08lx (%s): readable (0x%02x)\n", addr, desc, (unsigned char)c);
		fflush(stdout);
		_exit(0);
	}
	waitpid(pid, &status, 0);
	if (WIFSIGNALED(status))
		printf("  0x%08lx (%s): FAULT (signal %d)\n", addr, desc, WTERMSIG(status));
	else if (WIFEXITED(status) && WEXITSTATUS(status))
		printf("  0x%08lx (%s): exit %d\n", addr, desc, WEXITSTATUS(status));
}

int main(void)
{
	unsigned long sp;
	__asm__ volatile("mov %0, sp" : "=r" (sp));

	printf("=== ARM32 maps + probe diagnosis ===\n");
	printf("Page size: %ld\n", sysconf(_SC_PAGESIZE));
	printf("SP: 0x%lx\n", sp);
	printf("main() at: 0x%lx\n", (unsigned long)main);
	printf("environ at: 0x%lx\n", (unsigned long)environ);
	if (environ && environ[0])
		printf("environ[0] at: 0x%lx (\"%s\")\n",
			(unsigned long)environ[0], environ[0]);

	printf("\n--- /proc/self/maps ---\n");
	dump_maps();

	printf("\n--- Address probing ---\n");
	probe_addr_child(0xbef4c000, "known fault addr");
	probe_addr_child(0xbef4c000 - 4096, "fault - 4K");
	probe_addr_child(0xbef4c000 - 65536, "fault - 64K");
	probe_addr_child(0xbef4c000 + 4096, "fault + 4K");
	probe_addr_child(0xbef4c000 + 65536, "fault + 64K");
	probe_addr_child(sp, "current SP");
	probe_addr_child(sp + 65536, "SP + 64K");

	/* Try clock_gettime (might use vDSO) */
	printf("\n--- vDSO / libc tests ---\n");
	{
		struct timespec ts;
		int ret = clock_gettime(CLOCK_MONOTONIC, &ts);
		printf("  clock_gettime: ret=%d sec=%ld\n", ret, (long)ts.tv_sec);
	}
	{
		struct timeval tv;
		int ret = gettimeofday(&tv, NULL);
		printf("  gettimeofday: ret=%d sec=%ld\n", ret, (long)tv.tv_sec);
	}

	/* Try tmpfile - this is what crashes */
	printf("\n--- tmpfile / mkstemp tests ---\n");
	printf("  Before tmpfile(), dumping maps:\n");
	dump_maps();

	printf("  Calling tmpfile()...\n");
	fflush(stdout);
	{
		pid_t pid = fork();
		if (pid == 0) {
			FILE *f = tmpfile();
			if (f) {
				printf("  tmpfile() OK: fd=%d\n", fileno(f));
				fclose(f);
			} else {
				printf("  tmpfile() NULL: %s\n", strerror(errno));
			}
			_exit(0);
		}
		int status;
		waitpid(pid, &status, 0);
		if (WIFSIGNALED(status))
			printf("  tmpfile() child killed by signal %d\n", WTERMSIG(status));
		else
			printf("  tmpfile() child exited %d\n", WEXITSTATUS(status));
	}

	printf("  Calling mkstemp()...\n");
	fflush(stdout);
	{
		pid_t pid = fork();
		if (pid == 0) {
			char tmpf[] = "/tmp/test_XXXXXX";
			int fd = mkstemp(tmpf);
			if (fd >= 0) {
				printf("  mkstemp() OK: %s\n", tmpf);
				close(fd);
				unlink(tmpf);
			} else {
				printf("  mkstemp() failed: %s\n", strerror(errno));
			}
			_exit(0);
		}
		int status;
		waitpid(pid, &status, 0);
		if (WIFSIGNALED(status))
			printf("  mkstemp() child killed by signal %d\n", WTERMSIG(status));
		else
			printf("  mkstemp() child exited %d\n", WEXITSTATUS(status));
	}

	/* Direct open/write (should work) */
	printf("  Calling open+write directly...\n");
	fflush(stdout);
	{
		pid_t pid = fork();
		if (pid == 0) {
			int fd = open("/tmp/directtest", O_CREAT|O_RDWR|O_TRUNC, 0644);
			if (fd >= 0) {
				write(fd, "hello", 5);
				close(fd);
				unlink("/tmp/directtest");
				printf("  open+write OK\n");
			} else {
				printf("  open failed: %s\n", strerror(errno));
			}
			_exit(0);
		}
		int status;
		waitpid(pid, &status, 0);
		if (WIFSIGNALED(status))
			printf("  open+write child killed by signal %d\n", WTERMSIG(status));
		else
			printf("  open+write child exited %d\n", WEXITSTATUS(status));
	}

	printf("\n=== Done ===\n");
	return 0;
}
