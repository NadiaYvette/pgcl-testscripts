/* Loop the upstream mm-selftest cow.c (the real deterministic trigger for the
 * PGCL large-folio mapcount residual) N times so markers accumulate reliably. */
#include <unistd.h>
#include <sys/wait.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv)
{
	int n = argc > 1 ? atoi(argv[1]) : 12;
	for (int i = 0; i < n; i++) {
		pid_t p = fork();
		if (p == 0) {
			execl("/bin/mm-selftests/cow", "cow", (char *)0);
			_exit(127);
		}
		int st; waitpid(p, &st, 0);
		dprintf(1, "[cow-loop %d/%d rc=%d]\n", i + 1, n,
			WIFEXITED(st) ? WEXITSTATUS(st) : -1);
	}
	dprintf(1, "cow-loop done (%d runs)\n", n);
	return 0;
}
