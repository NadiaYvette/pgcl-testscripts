/*
 * Minimal PID1 smoke init for xtensa PGCL bring-up.
 * Built static against the dc233c uclibc toolchain (no nolibc xtensa port yet).
 * Exercises the PGCL anon-fault + fork/COW paths from userspace, then powers off
 * cleanly so qemu -no-reboot exits without a kill-init panic.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/reboot.h>

#define MARK "PGCL-XTENSA-SMOKE"

int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	printf("%s: userspace reached\n", MARK);

	/* anon mmap + touch every hw page within a kernel cluster */
	size_t len = 256 * 1024;
	char *p = mmap(NULL, len, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		printf("%s: mmap FAIL\n", MARK);
		goto done;
	}
	memset(p, 0xa5, len);
	if (p[0] != (char)0xa5 || p[len - 1] != (char)0xa5) {
		printf("%s: mmap data FAIL\n", MARK);
		goto done;
	}

	/* fork + COW: child mutates, parent must keep the old value */
	pid_t pid = fork();
	if (pid == 0) {
		p[0] = 0x5a;
		_exit(p[0] == 0x5a ? 42 : 1);
	} else if (pid > 0) {
		int st = 0;
		waitpid(pid, &st, 0);
		if (!WIFEXITED(st) || WEXITSTATUS(st) != 42) {
			printf("%s: fork/COW child FAIL (st=%d)\n", MARK, st);
			goto done;
		}
		if (p[0] != (char)0xa5) {
			printf("%s: COW isolation FAIL\n", MARK);
			goto done;
		}
	} else {
		printf("%s: fork FAIL\n", MARK);
		goto done;
	}

	printf("%s: PASS\n", MARK);
done:
	printf("%s: halting\n", MARK);
	sync();
	reboot(RB_POWER_OFF);
	for (;;)
		pause();
	return 0;
}
