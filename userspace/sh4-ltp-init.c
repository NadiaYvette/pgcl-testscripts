/* sh4-ltp-init.c — busybox-free PID1 for the size-constrained sh4 (r2d) LTP cell.
 *
 * r2d is tiny: 64M RAM, ~16M zImage load limit, and the sh zImage self-
 * decompressor overlaps the compressed image for zImages much above ~4M.
 * busybox (1.4M) alone fills the initramfs budget, leaving no room for LTP,
 * so this static C init replaces the shell init: it mounts the pseudo-fs,
 * runs pgcl-test + pgcl-stress, then every /bin/ltp/* binary with a per-test
 * timeout, tallies PASS/FAIL/SKIP, prints a summary, and powers off.
 *
 * LTP new-API exit codes: 0=all TPASS, 32=TCONF (skip), 33=TBROK, else fail.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/reboot.h>

static int run(const char *path, char *const argv[], int timeout_s)
{
	pid_t pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		execv(path, argv);
		_exit(127);
	}
	/* parent: enforce a wall-clock timeout via alarm on a waitpid loop */
	int status = 0;
	for (int t = 0; t < timeout_s * 10; t++) {
		pid_t r = waitpid(pid, &status, WNOHANG);
		if (r == pid)
			return WIFEXITED(status) ? WEXITSTATUS(status)
						 : 128 + WTERMSIG(status);
		usleep(100000);
	}
	kill(pid, SIGKILL);
	waitpid(pid, &status, 0);
	return -2; /* timed out */
}

static int cmp(const void *a, const void *b)
{ return strcmp(*(char *const *)a, *(char *const *)b); }

int main(void)
{
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("tmpfs", "/tmp", "tmpfs", 0, NULL);

	printf("\n======== sh4 PGCL LTP cell (busybox-free init) ========\n");
	fflush(stdout);

	char *av0[] = { NULL, NULL };

	/* pgcl-test first (fast, fully self-contained) */
	if (!access("/bin/pgcl-test", X_OK)) {
		av0[0] = "/bin/pgcl-test";
		printf("--- /bin/pgcl-test ---\n"); fflush(stdout);
		int rc = run("/bin/pgcl-test", av0, 300);
		printf("=== /bin/pgcl-test rc=%d ===\n", rc); fflush(stdout);
	}

	/* every /bin/ltp/* binary, sorted, with a 60s per-test timeout.
	 * Run LTP (and print its summary) BEFORE pgcl-stress: the multithreaded
	 * stressor trips a find_vma/mmap_lock WARNING in the sh4 fault path that
	 * can end the run, so do the LTP tally first to capture it. */
	DIR *d = opendir("/bin/ltp");
	int pass = 0, fail = 0, skip = 0, total = 0;
	if (d) {
		char *names[256]; int n = 0;
		struct dirent *e;
		while ((e = readdir(d)) && n < 256) {
			if (e->d_name[0] == '.')
				continue;
			names[n++] = strdup(e->d_name);
		}
		closedir(d);
		qsort(names, n, sizeof(char *), cmp);
		printf("--- LTP mm tests (%d) ---\n", n); fflush(stdout);
		for (int i = 0; i < n; i++) {
			char path[300];
			snprintf(path, sizeof path, "/bin/ltp/%s", names[i]);
			av0[0] = path;
			int rc = run(path, av0, 60);
			const char *v;
			if (rc == 0)      { v = "PASS"; pass++; }
			else if (rc == 32){ v = "SKIP"; skip++; }
			else              { v = "FAIL"; fail++; }
			total++;
			printf("  %-24s %s (rc=%d)\n", names[i], v, rc);
			fflush(stdout);
		}
	}

	printf("\n======== LTP SUMMARY: %d pass, %d fail, %d skip (of %d) ========\n",
	       pass, fail, skip, total);
	fflush(stdout);

	/* pgcl-stress last: it trips a sh4 fault-path locking WARNING that may
	 * end the run, so it must not block the LTP tally printed above. */
	if (!access("/bin/pgcl-stress", X_OK)) {
		av0[0] = "/bin/pgcl-stress";
		printf("--- /bin/pgcl-stress ---\n"); fflush(stdout);
		int rc = run("/bin/pgcl-stress", av0, 300);
		printf("=== /bin/pgcl-stress rc=%d ===\n", rc); fflush(stdout);
	}

	printf("======== sh4 PGCL LTP cell DONE ========\n");
	fflush(stdout);
	sync();
	reboot(RB_POWER_OFF);
	for (;;)
		pause();
	return 0;
}
