/*
 * file_fork_repro — pin the #143 file-folio rmap underflow via the fork path.
 *
 * Hypothesis: set_pte_range eager-maps a large FILE folio cluster with +16
 * (PAGE_MMUCOUNT) sub-PTEs (folio_add_rmap_subptes), the zap removes -16
 * (folio_remove_rmap_subptes), but the fork file-dup (folio_dup_file_rmap_ptes
 * -> __folio_dup_file_rmap, per-struct-page) only adds the child's mapping as
 * +1 per cluster.  So each fork(child)+exit nets -15 on the cluster page's
 * _mapcount even while the parent keeps it mapped -> accumulating underflow ->
 * "Bad page".  Needs LARGE file folios (btrfs at 64K PAGE forms them; ext4
 * mostly order-0) + eager full-cluster mapping (MADV_POPULATE_READ).
 *
 * usage: file_fork_repro <dir> <seconds> [workers]
 * Run on btrfs.  Under DEBUG_VM the underflow trips a kernel "Bad page" oops.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/wait.h>

#ifndef CLUSTER
#define CLUSTER (64UL * 1024)
#endif
#define FILESZ (8UL * 1024 * 1024)

static long deadline;
static long nowsec(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec; }

static void worker(const char *dir, int id)
{
	char path[256];
	snprintf(path, sizeof path, "%s/ff_%d_%ld.bin", dir, id, (long)getpid());
	for (unsigned it = 0; nowsec() < deadline; it++) {
		int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (fd < 0) return;
		if (ftruncate(fd, FILESZ)) { close(fd); unlink(path); return; }
		/* write pattern, then read back to coalesce into large folios */
		char *b = malloc(CLUSTER);
		for (unsigned long o = 0; o < FILESZ; o += CLUSTER) { memset(b, it + 1, CLUSTER); if (write(fd, b, CLUSTER) < 0) break; }
		free(b);
		posix_fadvise(fd, 0, FILESZ, POSIX_FADV_WILLNEED);
		{ char t[CLUSTER]; for (unsigned long o = 0; o < FILESZ; o += CLUSTER) pread(fd, t, sizeof t, o); }

		/* PRIVATE read map; eager-populate -> full-cluster sub-PTEs */
		char *m = mmap(NULL, FILESZ, PROT_READ, MAP_PRIVATE, fd, 0);
		if (m == MAP_FAILED) { close(fd); unlink(path); return; }
		madvise(m, FILESZ, MADV_POPULATE_READ);
		(void)*(volatile char *)m;	/* ensure faulted */

		/* fork several children that inherit the mapping and just exit
		 * (each child's exit zaps the inherited file mapping).  The parent
		 * keeps the mapping the whole time -- so any per-fork count desync
		 * accumulates on the still-live folio. */
		for (int k = 0; k < 8 && nowsec() < deadline; k++) {
			pid_t c = fork();
			if (c == 0) {
				/* touch a few sub-PTEs so the child definitely has them mapped */
				for (unsigned long o = 0; o < FILESZ; o += 4096) (void)*(volatile char *)(m + o);
				_exit(0);		/* -> exit_mmap -> zap inherited file maps */
			} else if (c > 0) {
				int st; waitpid(c, &st, 0);
			} else break;
		}
		munmap(m, FILESZ);
		close(fd);
	}
	unlink(path);
}

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "/tmp";
	int secs = argc > 2 ? atoi(argv[2]) : 60;
	int nw = argc > 3 ? atoi(argv[3]) : 6;
	deadline = nowsec() + secs;
	printf("FFORK start dir=%s secs=%d workers=%d cluster=%lu\n", dir, secs, nw, CLUSTER);
	fflush(stdout);
	pid_t k[32]; if (nw > 32) nw = 32;
	for (int i = 0; i < nw; i++) { pid_t p = fork(); if (p == 0) { worker(dir, i); _exit(0); } k[i] = p; }
	for (int i = 0; i < nw; i++) { int st; waitpid(k[i], &st, 0); }
	printf("FFORK DONE\n");
	return 0;
}
