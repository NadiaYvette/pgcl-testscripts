/*
 * setup-cpu-partitions-wrap.c — tiny setuid-root exec wrapper.
 *
 * Linux ignores the setuid bit on #! script files, so a setuid *binary* is
 * needed to elevate.  This wrapper raises to full root then exec()s the fixed
 * bash setup script (hardcoded path — do NOT make it take an arbitrary script).
 *
 *   gcc -O2 -Wall -o setup-cpu-partitions-wrap setup-cpu-partitions-wrap.c
 *   sudo chown root setup-cpu-partitions-wrap
 *   sudo chmod u+s  setup-cpu-partitions-wrap        # -rwsr-xr-x root
 *
 * Then:  ./setup-cpu-partitions-wrap setup | join pgcl|telix [PID] | status | teardown
 */
#define _GNU_SOURCE	/* for setresuid/setresgid */
#include <unistd.h>
#include <stdio.h>

#define SCRIPT "/home/nyc/src/pgcl/rmap-ab/setup-cpu-partitions.sh"

int main(int argc, char **argv)
{
	char *nargv[32];
	int i, n = 0;

	/* Become full root (real+eff+saved) so bash keeps the privilege. */
	if (setresgid(0, 0, 0) != 0)
		perror("setresgid (non-fatal)");
	if (setresuid(0, 0, 0) != 0) {
		perror("setresuid");
		return 1;
	}

	nargv[n++] = "bash";
	nargv[n++] = SCRIPT;
	for (i = 1; i < argc && n < 30; i++)
		nargv[n++] = argv[i];
	nargv[n] = 0;

	execv("/bin/bash", nargv);
	perror("execv /bin/bash");
	return 1;
}
