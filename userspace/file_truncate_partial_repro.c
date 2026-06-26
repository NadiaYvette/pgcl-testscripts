/*
 * file_truncate_partial_repro — exercise truncate_inode_partial_folio() under
 * PGCL, targeting the PAGE_ALIGN_DOWN(offset)/PAGE_SIZE split rounding that may
 * discard the "overhanging MMU fragment" [cluster_start, T) when a file is
 * ftruncate()d to a MID-CLUSTER (MMUPAGE-aligned, NOT cluster-aligned) size.
 *
 * The focused reclaim repro (file_reclaim_race_repro) NEVER hits this path: it
 * only O_TRUNCs to 0 (full-folio truncate_inode_folio) + posix_fadvise(DONTNEED)
 * (whole-folio folio_unmap_invalidate).  This one does explicit non-aligned
 * ftruncate of a MAPPED file, with concurrency + reclaim pressure, and VERIFIES
 * the kept sub-cluster bytes survive (rounding-too-aggressive => data loss /
 * dangling PTE on the dropped boundary cluster).
 *
 * usage: file_truncate_partial_repro <dir> <seconds> [workers] [hogMB] [fileKB]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/wait.h>

#define MB (1024UL * 1024)
#define HWPAGE 4096UL		/* MMUPAGE (userspace page) */
#define CLUSTER (64UL * 1024)	/* PGCL PAGE_SIZE at pgcl4 */

static long deadline;
static long nowsec(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec; }

/* per-MMUPAGE stamp so we can detect a dropped/zeroed "kept" fragment */
static unsigned char stamp_of(unsigned long off){ return (unsigned char)(0x80 | ((off / HWPAGE) & 0x7f)); }

static void hog(unsigned long mb)
{
	unsigned long n = mb * MB;
	while (nowsec() < deadline) {
		char *p = mmap(NULL, n, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) { usleep(20000); continue; }
		for (unsigned long o = 0; o < n; o += HWPAGE) p[o] = 1;
		munmap(p, n);
	}
	_exit(0);
}

static void refill(int fd, unsigned long fsz)
{
	if (ftruncate(fd, fsz) < 0) return;
	for (unsigned long o = 0; o < fsz; o += HWPAGE) {
		unsigned char c = stamp_of(o);
		if (pwrite(fd, &c, 1, o) != 1) break;
		/* fill the rest of the MMUPAGE so reads are meaningful */
	}
}

static int errors;

static void worker(const char *dir, int id, unsigned long fsz)
{
	char path[256];
	snprintf(path, sizeof path, "%s/tp_%d.bin", dir, id);
	int fd = open(path, O_RDWR|O_CREAT|O_TRUNC, 0644);
	if (fd < 0) return;
	refill(fd, fsz);
	fsync(fd);

	for (unsigned it = 0; nowsec() < deadline; it++) {
		/* map SHARED so the file folios themselves are the mapped pages
		 * that truncate must unmap (MAP_PRIVATE would COW to anon). */
		char *m = mmap(NULL, fsz, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
		if (m == MAP_FAILED) continue;
		volatile unsigned long s = 0;
		for (unsigned long o = 0; o < fsz; o += HWPAGE) s += m[o];	/* fault sub-PTEs */

		/* mid-cluster truncation point: K clusters + S MMUPAGEs (S=1..15) */
		unsigned int S = 1 + (it % 15);
		unsigned long K = (fsz / CLUSTER) / 2;
		unsigned long T = K * CLUSTER + S * HWPAGE;		/* MMUPAGE-aligned, mid-cluster */

		pid_t c = fork();					/* race truncate vs access */
		if (c == 0) {
			for (int r = 0; r < 200 && nowsec() < deadline; r++)
				for (unsigned long o = 0; o < T; o += HWPAGE)
					s += m[o];			/* keep the kept region mapped+hot */
			_exit(0);
		}

		ftruncate(fd, T);			/* shrink -> partial folio at T */
		ftruncate(fd, fsz);			/* re-extend (tail becomes zeros) */

		if (c > 0) { int st; waitpid(c, &st, 0); }

		/* VERIFY via the file: the kept overhang [K*CLUSTER, T) must retain
		 * its stamp; if PAGE_ALIGN_DOWN dropped the boundary cluster it will
		 * read back zero. (Bytes >= T were re-zeroed by the extend.) */
		for (unsigned long o = K * CLUSTER; o < T; o += HWPAGE) {
			unsigned char c0 = 0;
			if (pread(fd, &c0, 1, o) == 1 && c0 != stamp_of(o)) {
				if (__sync_fetch_and_add(&errors, 1) < 20)
					fprintf(stderr, "TP-LOSS id=%d off=%lu (cloff=%lu) got=0x%02x want=0x%02x\n",
						id, o, o - K*CLUSTER, c0, stamp_of(o));
			}
		}
		munmap(m, fsz);
		refill(fd, fsz);			/* restamp for the next iteration */
	}
	close(fd);
	unlink(path);
	_exit(errors ? 1 : 0);
}

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "/mnt/btrfs";
	int secs = argc > 2 ? atoi(argv[2]) : 120;
	int nw   = argc > 3 ? atoi(argv[3]) : 8;
	unsigned long hogmb = argc > 4 ? strtoul(argv[4],0,10) : 1536;
	unsigned long fkb   = argc > 5 ? strtoul(argv[5],0,10) : 1024;	/* 1MB = 16 clusters */

	deadline = nowsec() + secs;
	printf("TP start dir=%s secs=%d workers=%d hog=%luMB file=%luKB\n", dir, secs, nw, hogmb, fkb);
	fflush(stdout);

	pid_t k[96]; int nk = 0, fail = 0;
	pid_t h = fork(); if (h == 0) hog(hogmb); k[nk++] = h;
	for (int i = 0; i < nw; i++) {
		pid_t p = fork();
		if (p == 0) worker(dir, i, fkb * 1024);
		k[nk++] = p;
	}
	for (int i = 0; i < nk; i++) { int st; waitpid(k[i], &st, 0); if (WIFEXITED(st) && WEXITSTATUS(st)) fail = 1; }
	printf("TP DONE%s\n", fail ? " (DATA-LOSS DETECTED)" : "");
	return fail;
}
