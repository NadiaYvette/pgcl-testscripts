/*
 * file_reclaim_race_repro — reproduce the PGCL order-0 file-folio
 * reclaim-vs-COW race (#143).
 *
 * Root cause (trace-verified): shrink_folio_list (mm/vmscan.c:1347) adds
 * TTU_SYNC only for folio_test_large(folio). Under PGCL an order-0 folio is
 * mapped by PAGE_MMUCOUNT (16) hardware sub-PTEs, so it is multiply-mapped like
 * a large folio and hits the same page_vma_mapped_walk lazy-PTL race: a
 * concurrent COW clears a sub-PTE before re-installing it, the unsynchronized
 * reclaim walk skips it, folio_mapped() reads a transient count, and the folio
 * is freed while still mapped -> refcount/mapcount underflow.
 *
 * Why earlier QEMU runs missed it: it is a RACE, not a deterministic miscount.
 * It needs ALL of: btrfs (subpage = order-0 + PG_private file folios, taking the
 * deferred-rmap path that widens the window) + file folios kept MAPPED and
 * CONTINUOUSLY COWed + memory pressure forcing reclaim to try_to_unmap them
 * concurrently. Run hot under tight RAM.
 *
 * usage: file_reclaim_race_repro <btrfs-dir> <seconds> [workers] [hogMB] [fileMB]
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

#define MB (1024UL * 1024)
#define HWPAGE 4096UL
#define CLUSTER (64UL * 1024)

static long deadline;
static long nowsec(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec; }

/* keep allocating + touching anon to force reclaim of the mapped file folios */
static void hog(unsigned long mb)
{
	unsigned long n = mb * MB;
	while (nowsec() < deadline) {
		char *p = mmap(NULL, n, PROT_READ | PROT_WRITE,
			       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) { usleep(20000); continue; }
		for (unsigned long o = 0; o < n; o += HWPAGE)
			p[o] = 1;			/* resident -> pressure */
		munmap(p, n);
	}
	_exit(0);
}

/* keep a btrfs file mapped MAP_PRIVATE and COW it continuously while reclaim
 * (driven by the hog) tries to unmap it -- and fork so parent+child COW at once */
static void worker(const char *dir, int id, unsigned long fsz)
{
	char path[256];
	snprintf(path, sizeof path, "%s/rr_%d.bin", dir, id);
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) return;
	char *buf = malloc(MB);
	if (buf) { memset(buf, 0x5a, MB);
		for (unsigned long o = 0; o < fsz; o += MB) if (write(fd, buf, MB) < 0) break;
		free(buf); }
	fsync(fd);

	for (unsigned it = 0; nowsec() < deadline; it++) {
		posix_fadvise(fd, 0, fsz, POSIX_FADV_DONTNEED);	/* drop cache -> fresh folios */
		char *m = mmap(NULL, fsz, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
		if (m == MAP_FAILED) continue;
		volatile unsigned long s = 0;
		for (unsigned long o = 0; o < fsz; o += HWPAGE) s += m[o];	/* fault: map sub-PTEs */

		pid_t c = fork();				/* parent+child COW concurrently */
		if (c == 0) {
			for (int r = 0; r < 80; r++)
				for (unsigned long o = 0; o < fsz; o += CLUSTER + HWPAGE) m[o] ^= 1;
			_exit(0);
		}
		for (int r = 0; r < 80; r++)
			for (unsigned long o = HWPAGE; o < fsz; o += CLUSTER + HWPAGE) m[o] ^= 1;
		if (c > 0) { int st; waitpid(c, &st, 0); }
		(void)s;
		munmap(m, fsz);
	}
	close(fd);
	unlink(path);
}

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "/mnt/btrfs";
	int secs = argc > 2 ? atoi(argv[2]) : 120;
	int nw   = argc > 3 ? atoi(argv[3]) : 8;
	unsigned long hogmb = argc > 4 ? strtoul(argv[4], 0, 10) : 1536;
	unsigned long fmb   = argc > 5 ? strtoul(argv[5], 0, 10) : 4;

	deadline = nowsec() + secs;
	printf("RR start dir=%s secs=%d workers=%d hog=%luMB file=%luMB\n", dir, secs, nw, hogmb, fmb);
	fflush(stdout);

	pid_t k[96]; int nk = 0;
	pid_t h = fork(); if (h == 0) hog(hogmb); k[nk++] = h;
	for (int i = 0; i < nw; i++) {
		pid_t p = fork();
		if (p == 0) { worker(dir, i, fmb * MB); _exit(0); }
		k[nk++] = p;
	}
	for (int i = 0; i < nk; i++) { int st; waitpid(k[i], &st, 0); }
	printf("RR DONE\n");
	return 0;
}
