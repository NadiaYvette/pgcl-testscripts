/* Self-pacing fork09 reproducer for m68k PGCL=6.
 * Mirrors LTP fork09: open files until EMFILE, fork, child closes all +
 * reopens first. Reports every step via raw write(2,...) (no stdio buffering,
 * no LTP framework) with its own usleep pacing so output survives m68k's
 * lossy goldfish UART. Tag "F9R" for easy grep. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>

static void emit(const char *fmt, ...)
{
	char b[256];
	int n;
	va_list a;
	va_start(a, fmt);
	n = vsnprintf(b, sizeof b, fmt, a);
	va_end(a);
	if (n > 0)
		write(2, b, n < (int)sizeof b ? n : (int)sizeof b - 1);
	usleep(200000);   /* 200ms: pace so the UART does not drop lines */
}

int main(void)
{
	struct rlimit rl;
	long maxf, n = 0, i;
	FILE **fs;
	pid_t pid;
	int st;

	getrlimit(RLIMIT_NOFILE, &rl);
	emit("F9R start pagesize=%d SC_OPEN_MAX=%ld NOFILE cur=%lu max=%lu\n",
	     getpagesize(), sysconf(_SC_OPEN_MAX),
	     (unsigned long)rl.rlim_cur, (unsigned long)rl.rlim_max);

	maxf = sysconf(_SC_OPEN_MAX);
	emit("F9R malloc %ld ptrs (%lu bytes)\n", maxf,
	     (unsigned long)(sizeof(FILE *) * maxf));
	fs = malloc(sizeof(FILE *) * maxf);
	if (!fs) {
		emit("F9R malloc FAILED errno=%d %s\n", errno, strerror(errno));
		return 1;
	}

	emit("F9R malloc ok, entering open loop\n");
	for (n = 0; n < maxf; n++) {
		char nm[64];
		FILE *f;
		if ((n % 128) == 0)
			emit("F9R ... opening #%ld\n", n);
		snprintf(nm, sizeof nm, "/tmp/f9_%ld", n);
		errno = 0;
		f = fopen(nm, "a");
		if (!f) {
			emit("F9R fopen #%ld stop errno=%d %s\n",
			     n, errno, strerror(errno));
			break;
		}
		fs[n] = f;
	}
	emit("F9R opened %ld files\n", n);
	if (n == 0) {
		emit("F9R ZERO files opened -> would TBROK\n");
		return 1;
	}

	pid = fork();
	if (pid < 0) {
		emit("F9R fork FAILED errno=%d %s\n", errno, strerror(errno));
		return 1;
	}
	if (pid == 0) {
		FILE *r;
		errno = 0;
		fclose(fs[0]);
		r = fopen("/tmp/f9_0", "a");
		if (!r)
			emit("F9R child reopen FAILED errno=%d %s\n",
			     errno, strerror(errno));
		else
			fs[0] = r;
		for (i = n - 1; i >= 0; i--)
			if (fs[i] && fclose(fs[i]))
				emit("F9R child fclose #%ld FAILED errno=%d\n",
				     i, errno);
		emit("F9R child OK\n");
		_exit(0);
	}

	waitpid(pid, &st, 0);
	emit("F9R child: exited=%d code=%d signalled=%d sig=%d\n",
	     WIFEXITED(st), WEXITSTATUS(st), WIFSIGNALED(st), WTERMSIG(st));
	emit("F9R DONE\n");
	return 0;
}
