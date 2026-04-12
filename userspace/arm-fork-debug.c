/*
 * arm-fork-debug.c - Debug fork+mkdir SIGSEGV with signal handler
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

static volatile sig_atomic_t fault_addr_set;
static volatile void *fault_addr;

static void sigsegv_handler(int sig, siginfo_t *info, void *ctx)
{
	/* Write the faulting address using direct syscall to avoid stdio */
	char buf[128];
	int len = 0;
	unsigned long addr = (unsigned long)info->si_addr;
	unsigned long sp;

	/* Get current SP */
	__asm__ volatile("mov %0, sp" : "=r" (sp));

	buf[len++] = 'S'; buf[len++] = 'I'; buf[len++] = 'G';
	buf[len++] = 'S'; buf[len++] = 'E'; buf[len++] = 'G';
	buf[len++] = 'V'; buf[len++] = ' ';
	buf[len++] = 'a'; buf[len++] = 'd'; buf[len++] = 'd';
	buf[len++] = 'r'; buf[len++] = '='; buf[len++] = '0';
	buf[len++] = 'x';

	/* Hex encode addr */
	for (int i = 28; i >= 0; i -= 4) {
		int nib = (addr >> i) & 0xf;
		buf[len++] = nib < 10 ? '0' + nib : 'a' + nib - 10;
	}

	buf[len++] = ' '; buf[len++] = 's'; buf[len++] = 'p';
	buf[len++] = '='; buf[len++] = '0'; buf[len++] = 'x';

	for (int i = 28; i >= 0; i -= 4) {
		int nib = (sp >> i) & 0xf;
		buf[len++] = nib < 10 ? '0' + nib : 'a' + nib - 10;
	}

	buf[len++] = '\n';
	write(1, buf, len);

	_exit(139);
}

static void install_handler(void)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = sigsegv_handler;
	sa.sa_flags = SA_SIGINFO;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
}

static int do_fork_test(const char *desc, int depth)
{
	int status;
	pid_t pid;

	printf("  %-45s ", desc);
	fflush(stdout);

	pid = fork();
	if (pid < 0) {
		printf("FAIL: fork: %s\n", strerror(errno));
		return 1;
	}
	if (pid == 0) {
		install_handler();

		/* Touch stack at various depths */
		volatile char buf[4096];
		memset((char*)buf, 'X', depth);
		buf[0] = buf[depth-1];

		/* Also try to call write to verify stdio works */
		write(1, "", 0);

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

/* Use a large stack frame to touch more of the stack */
static int __attribute__((noinline)) deep_call(int n, volatile char *out)
{
	volatile char local[256];
	memset((char*)local, n & 0xff, sizeof(local));
	*out = local[n % 256];
	if (n > 0)
		return deep_call(n-1, out);
	return local[0];
}

int main(void)
{
	int fail = 0;
	unsigned long sp;
	__asm__ volatile("mov %0, sp" : "=r" (sp));

	printf("=== fork-debug test ===\n");
	printf("Page size: %ld\n", sysconf(_SC_PAGESIZE));
	printf("SP: 0x%lx (page offset: 0x%lx)\n", sp, sp & 0xfff);
	printf("SP PAGE_MASK offset: 0x%lx\n", sp & 0xffff);

	install_handler();

	/* Vary how much stack we use before forking */
	printf("\n--- Fork with varying stack depth (in /) ---\n");
	chdir("/");
	fail += do_fork_test("fork, 64 bytes stack", 64);
	fail += do_fork_test("fork, 512 bytes stack", 512);
	fail += do_fork_test("fork, 2048 bytes stack", 2048);
	fail += do_fork_test("fork, 4096 bytes stack", 4096);

	/* Now with mkdir+chdir */
	printf("\n--- Fork with mkdir+chdir /tmp/testX ---\n");
	mkdir("/tmp/test1", 0755);
	chdir("/tmp/test1");
	fail += do_fork_test("mkdir+chdir, 64 bytes", 64);
	chdir("/tmp");
	rmdir("/tmp/test1");

	mkdir("/tmp/test2", 0755);
	chdir("/tmp/test2");
	fail += do_fork_test("mkdir+chdir, 512 bytes", 512);
	chdir("/tmp");
	rmdir("/tmp/test2");

	mkdir("/tmp/test3", 0755);
	chdir("/tmp/test3");
	fail += do_fork_test("mkdir+chdir, 2048 bytes", 2048);
	chdir("/tmp");
	rmdir("/tmp/test3");

	mkdir("/tmp/test4", 0755);
	chdir("/tmp/test4");
	fail += do_fork_test("mkdir+chdir, 4096 bytes", 4096);
	chdir("/tmp");
	rmdir("/tmp/test4");

	/* Deep stack use to dirty many pages, then mkdir+chdir+fork */
	printf("\n--- Deep stack before mkdir+chdir ---\n");
	volatile char out;
	deep_call(50, &out);  /* Use ~12KB of stack */
	printf("  (used deep stack, sp: 0x%lx)\n", sp);

	mkdir("/tmp/test5", 0755);
	chdir("/tmp/test5");
	fail += do_fork_test("deep stack + mkdir+chdir, 64b", 64);
	chdir("/tmp");
	rmdir("/tmp/test5");

	/* Try fork several times in same dir */
	printf("\n--- Multiple forks in same mkdir dir ---\n");
	mkdir("/tmp/test6", 0755);
	chdir("/tmp/test6");
	for (int i = 0; i < 5; i++) {
		char desc[64];
		snprintf(desc, sizeof(desc), "fork #%d, 256b stack", i+1);
		fail += do_fork_test(desc, 256);
	}
	chdir("/tmp");
	rmdir("/tmp/test6");

	printf("\n=== Result: %d failures ===\n", fail);
	return fail;
}
