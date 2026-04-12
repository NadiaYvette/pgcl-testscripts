/*
 * arm-ltp-repro.c - Reproduce the exact LTP new-API flow that crashes on ARM32 PGCL
 *
 * Flow: mmap IPC in /dev/shm → mkdtemp+chdir → fork → child writes to IPC mmap
 * This is what every LTP new-API test with needs_tmpdir=1 does.
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

struct ipc_data {
	int magic;
	int passed;
	int failed;
	int skipped;
	int broken;
	char msg[256];
};

static void run_test(const char *name, int do_tmpdir, int do_ipc, int do_file)
{
	char tmpdir[] = "/tmp/repro_XXXXXX";
	struct ipc_data *ipc = NULL;
	int ipc_fd = -1;
	int status;
	pid_t pid;
	int pagesize = sysconf(_SC_PAGESIZE);

	printf("  %-40s ", name);
	fflush(stdout);

	/* Step 1: IPC mmap in /dev/shm (like setup_ipc) */
	if (do_ipc) {
		char shm_path[256];
		snprintf(shm_path, sizeof(shm_path), "/dev/shm/repro_%d", getpid());
		ipc_fd = open(shm_path, O_CREAT | O_EXCL | O_RDWR, 0600);
		if (ipc_fd < 0) {
			printf("FAIL: open shm: %s\n", strerror(errno));
			return;
		}
		ftruncate(ipc_fd, pagesize);
		ipc = mmap(NULL, pagesize, PROT_READ | PROT_WRITE, MAP_SHARED, ipc_fd, 0);
		if (ipc == MAP_FAILED) {
			printf("FAIL: mmap shm: %s\n", strerror(errno));
			close(ipc_fd);
			unlink(shm_path);
			return;
		}
		close(ipc_fd);
		unlink(shm_path);
		memset(ipc, 0, pagesize);
		ipc->magic = 0xCAFE;
	}

	/* Step 2: Create tmpdir and chdir (like tst_tmpdir) */
	if (do_tmpdir) {
		if (!mkdtemp(tmpdir)) {
			printf("FAIL: mkdtemp: %s\n", strerror(errno));
			return;
		}
		if (chdir(tmpdir)) {
			printf("FAIL: chdir: %s\n", strerror(errno));
			rmdir(tmpdir);
			return;
		}
	}

	/* Step 3: Fork (like fork_testrun) */
	pid = fork();
	if (pid < 0) {
		printf("FAIL: fork: %s\n", strerror(errno));
		goto cleanup;
	}

	if (pid == 0) {
		/* Child: mimic LTP child testrun */
		setpgid(0, 0);

		if (do_ipc && ipc) {
			/* Write to IPC shared mmap (like tst_res) */
			ipc->passed++;
			snprintf(ipc->msg, sizeof(ipc->msg), "child was here");
		}

		if (do_file) {
			/* Create and write a file in tmpdir */
			int fd = open("testfile", O_CREAT | O_RDWR | O_TRUNC, 0644);
			if (fd >= 0) {
				char buf[4096];
				memset(buf, 'A', sizeof(buf));
				write(fd, buf, sizeof(buf));
				close(fd);
			}
		}

		_exit(0);
	}

	waitpid(pid, &status, 0);

	if (WIFSIGNALED(status)) {
		printf("FAIL (killed by signal %d)\n", WTERMSIG(status));
		goto cleanup;
	}
	if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
		printf("FAIL (exit %d)\n", WEXITSTATUS(status));
		goto cleanup;
	}

	/* Verify IPC data */
	if (do_ipc && ipc) {
		if (ipc->passed != 1 || strcmp(ipc->msg, "child was here") != 0) {
			printf("FAIL (IPC verify: passed=%d msg='%s')\n",
				ipc->passed, ipc->msg);
			goto cleanup;
		}
	}

	printf("PASS\n");

cleanup:
	if (do_tmpdir) {
		if (do_file)
			unlink("testfile");
		chdir("/tmp");
		rmdir(tmpdir);
	}
	if (ipc)
		munmap(ipc, pagesize);
}

int main(void)
{
	int pagesize = sysconf(_SC_PAGESIZE);
	printf("=== ARM32 LTP SIGSEGV Reproducer ===\n");
	printf("Page size: %d\n", pagesize);
	printf("\n");

	/* Isolate the exact combination that triggers SIGSEGV */
	run_test("fork_only (no ipc, no tmpdir)", 0, 0, 0);
	run_test("fork+ipc (no tmpdir)", 0, 1, 0);
	run_test("fork+tmpdir (no ipc)", 1, 0, 0);
	run_test("fork+tmpdir+file (no ipc)", 1, 0, 1);
	run_test("fork+ipc+tmpdir", 1, 1, 0);
	run_test("fork+ipc+tmpdir+file", 1, 1, 1);

	/* Repeat to check for intermittent failures */
	printf("\n--- Repeat x5 of critical combo ---\n");
	for (int i = 0; i < 5; i++) {
		char name[64];
		snprintf(name, sizeof(name), "fork+ipc+tmpdir+file #%d", i+1);
		run_test(name, 1, 1, 1);
	}

	printf("\n=== Done ===\n");
	return 0;
}
