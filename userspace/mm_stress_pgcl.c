/*
 * mm_stress_pgcl — sustained mm stress for PGCL validation, biased toward the
 * paths page clustering touches (esp. the #140 file-rmap/writeback path).
 *
 * usage: mm_stress_pgcl <seconds> <dir1> [dir2 ...]
 *
 * Forks a worker per stress kind, each looping until the deadline:
 *   W_writeback : THE #140 path — per dir, create a file, mmap it SHARED in
 *                 several windows at varied offsets, dirty high-offset folios,
 *                 msync/fsync/fallocate(PUNCH_HOLE) -> writeback -> folio_mkclean
 *                 -> rmap_walk_file across the multi-window i_mmap (journald/btrfs
 *                 pattern that tripped rmap.c:3307).
 *   W_priv_cow  : per dir, seed a file via shared write, map MAP_PRIVATE twice,
 *                 read (page cache) then COW-write -> exercises private rmap.
 *   W_anon_fork : anon mmap, touch, fork; child COW-writes every page, verifies
 *                 isolation, exits.  COW-clustering churn.
 *   W_mmap_churn: rapid mmap/touch/munmap of varied sizes (cluster boundaries).
 *   W_thp       : MADV_HUGEPAGE anon 2M regions, touch, fork COW, mprotect split.
 *
 * Success = runs to "STRESS DONE ok" with no kernel BUG/WARN on the console.
 * Self-checks data integrity where cheap and reports mismatches.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/wait.h>

static long g_deadline;		/* CLOCK_MONOTONIC seconds */
static int g_mismatch;

static long now_sec(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec;
}
static int past_deadline(void) { return now_sec() >= g_deadline; }

#define CL (64UL * 1024)		/* cluster (PAGE_SIZE at pgcl4); harmless if not */
#define HP (2UL * 1024 * 1024)

/* #140 path: multi-window shared mmap + writeback + punch_hole. */
static void w_writeback(const char *dir, int id)
{
	char path[256];
	snprintf(path, sizeof path, "%s/wb_%d.dat", dir, id);
	for (unsigned it = 0; !past_deadline(); it++) {
		int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
		if (fd < 0) return;
		size_t fsz = 24 * 1024 * 1024;			/* 24 MiB */
		if (ftruncate(fd, fsz)) { close(fd); return; }
		/* low window [0,8M) + high window covering a high cluster */
		char *lo = mmap(NULL, 8 * 1024 * 1024, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		off_t hoff = (off_t)(12 * 1024 * 1024) + (it % 7) * CL;	/* vary */
		char *hi = mmap(NULL, 2 * CL, PROT_READ | PROT_WRITE, MAP_SHARED, fd, hoff & ~(CL - 1));
		if (lo != MAP_FAILED && hi != MAP_FAILED) {
			lo[0] = 1; lo[4 * 1024 * 1024] = 2;	/* dirty low window */
			hi[0] = (char)(0xC0 + it);		/* dirty high folio */
			hi[CL + 7] = (char)(0xD0 + it);
			msync(hi, 2 * CL, MS_SYNC);		/* writeback -> folio_mkclean */
			fsync(fd);
			fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
				  hoff & ~(CL - 1), CL);	/* exact #140 trigger */
		}
		if (lo != MAP_FAILED) munmap(lo, 8 * 1024 * 1024);
		if (hi != MAP_FAILED) munmap(hi, 2 * CL);
		close(fd);
	}
	unlink(path);
}

/* private COW from a page-cache-seeded file. */
static void w_priv_cow(const char *dir, int id)
{
	char path[256];
	snprintf(path, sizeof path, "%s/pc_%d.dat", dir, id);
	while (!past_deadline()) {
		int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
		if (fd < 0) return;
		size_t sz = 4 * 1024 * 1024;
		if (ftruncate(fd, sz)) { close(fd); return; }
		char *s = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		if (s != MAP_FAILED) { for (size_t i = 0; i < sz; i += CL) s[i] = 'S'; msync(s, sz, MS_SYNC); munmap(s, sz); }
		char *a = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
		char *b = mmap(NULL, sz, PROT_READ, MAP_PRIVATE, fd, 0);
		if (a != MAP_FAILED && b != MAP_FAILED) {
			for (size_t i = 0; i < sz; i += CL) { if (a[i] != 'S' || b[i] != 'S') g_mismatch++; a[i] = 'X'; }
			for (size_t i = 0; i < sz; i += CL) if (a[i] != 'X' || b[i] != 'S') g_mismatch++;
		}
		if (a != MAP_FAILED) munmap(a, sz);
		if (b != MAP_FAILED) munmap(b, sz);
		close(fd);
	}
	unlink(path);
}

static void w_anon_fork(int id)
{
	(void)id;
	size_t sz = 8 * 1024 * 1024;
	while (!past_deadline()) {
		char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) continue;
		for (size_t i = 0; i < sz; i += CL) p[i] = (char)(i / CL);
		pid_t c = fork();
		if (c == 0) {
			for (size_t i = 0; i < sz; i += CL) { if (p[i] != (char)(i / CL)) _exit(2); p[i] = (char)(~(i / CL)); }
			_exit(0);
		} else if (c > 0) {
			int st; waitpid(c, &st, 0);
			for (size_t i = 0; i < sz; i += CL) if (p[i] != (char)(i / CL)) g_mismatch++;	/* parent unchanged */
		}
		munmap(p, sz);
	}
}

static void w_mmap_churn(int id)
{
	(void)id;
	size_t sizes[] = { CL / 2, CL, CL + 4096, 3 * CL, HP, 5 * CL };
	for (unsigned it = 0; !past_deadline(); it++) {
		size_t sz = sizes[it % (sizeof sizes / sizeof sizes[0])];
		char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) continue;
		for (size_t i = 0; i < sz; i += 4096) p[i] = 1;
		if (sz >= 2 * 4096) mprotect(p, 4096, PROT_READ);	/* split */
		munmap(p, sz);
	}
}

static void w_thp(int id)
{
	(void)id;
	size_t sz = 8 * HP;
	while (!past_deadline()) {
		char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) continue;
		madvise(p, sz, MADV_HUGEPAGE);
		for (size_t i = 0; i < sz; i += 4096) p[i] = (char)i;
		pid_t c = fork();
		if (c == 0) { for (size_t i = 0; i < sz; i += 4096) p[i] = (char)~i; _exit(0); }
		else if (c > 0) { int st; waitpid(c, &st, 0); }
		mprotect(p + HP, 4096, PROT_READ);	/* force PMD split */
		munmap(p, sz);
	}
}

int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: %s <seconds> <dir> [dir...]\n", argv[0]); return 2; }
	int secs = atoi(argv[1]);
	g_deadline = now_sec() + secs;
	int ndirs = argc - 2;
	char **dirs = &argv[2];
	printf("STRESS start secs=%d dirs=%d\n", secs, ndirs); fflush(stdout);

	pid_t kids[64]; int nk = 0;
	for (int d = 0; d < ndirs; d++) {
		pid_t p = fork();
		if (p == 0) { w_writeback(dirs[d], d); _exit(g_mismatch ? 1 : 0); }
		kids[nk++] = p;
		p = fork();
		if (p == 0) { w_priv_cow(dirs[d], d); _exit(g_mismatch ? 1 : 0); }
		kids[nk++] = p;
	}
	for (int i = 0; i < 2; i++) { pid_t p = fork(); if (p == 0) { w_anon_fork(i); _exit(g_mismatch ? 1 : 0); } kids[nk++] = p; }
	{ pid_t p = fork(); if (p == 0) { w_mmap_churn(0); _exit(0); } kids[nk++] = p; }
	{ pid_t p = fork(); if (p == 0) { w_thp(0); _exit(0); } kids[nk++] = p; }

	int bad = 0;
	for (int i = 0; i < nk; i++) { int st; waitpid(kids[i], &st, 0); if (!WIFEXITED(st) || WEXITSTATUS(st)) bad++; }
	printf("STRESS DONE %s bad_workers=%d\n", bad ? "FAIL" : "ok", bad);
	return bad ? 1 : 0;
}
