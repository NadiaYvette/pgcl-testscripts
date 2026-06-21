/*
 * file_largefolio_repro — reproduce the PGCL FILE large-folio rmap
 * mapcount/refcount UNDERFLOW (#143).
 *
 * Root cause (trace-verified): copy_present_ptes() routes FILE large folios
 * through folio_dup_file_rmap_ptes(folio, page, nr) = atomic_inc across `nr`
 * DISTINCT pages, but under PGCL the `nr` sub-PTEs of a batch share ONE cluster
 * page -> fork scatters +1 onto neighbouring clusters while the zap subtracts
 * `nr` from one cluster -> mapcount underflow.
 *
 * Filesystem matters (the key lesson):
 *   - btrfs at 64K PAGE = subpage mode (4K<64K) -> order-0 folios only -> can't
 *     host the bug (the precondition WARN never fired across 7 runs).
 *   - tmpfs huge=always -> 2MB folios, but PMD-mapped -> fork takes copy_huge_pmd,
 *     not the buggy copy_present_ptes.
 *   - ext4 calls mapping_set_folio_order_range() (fs/ext4/inode.c:5218) so its
 *     readahead forms SUB-PMD large folios, which are ALWAYS PTE-mapped -> they
 *     go straight through copy_present_ptes. This is the laptop's .so case.
 *
 * Recipe: write a file on ext4, DROP its cache (so the mmap fault does fresh
 * large-folio readahead, not a re-map of order-0 write pages), mmap RO+EXEC,
 * read-fault (readahead -> sub-PMD PTE-mapped large folios), FORK while live
 * (the dup bug), then unmap + unlink each cycle so the scrambled folio is freed
 * (DEBUG_VM flags "Bad page state ... mapcount:-N" only on free).
 *
 * Run on ext4 with THP=always. usage: file_largefolio_repro <dir> <secs> [workers] [MB]
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
#ifndef MADV_HUGEPAGE
#define MADV_HUGEPAGE 14
#endif
#define HWPAGE 4096UL

static long deadline;
static unsigned long filesz = 16 * MB;
static long nowsec(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec; }

static unsigned long touch_ro(const char *m)
{
	volatile unsigned long s = 0;
	for (unsigned long o = 0; o < filesz; o += HWPAGE)
		s += m[o];
	return s;
}

static void cycle(const char *dir, int id, unsigned it)
{
	char path[256];
	snprintf(path, sizeof path, "%s/lf_%d_%u.so", dir, id, it);

	/* 1) write the file, fsync, close */
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
	if (fd < 0) return;
	char *buf = malloc(MB);
	if (buf) {
		memset(buf, 0x5a, MB);
		for (unsigned long o = 0; o < filesz; o += MB)
			if (write(fd, buf, MB) < 0) break;
		free(buf);
	}
	fsync(fd);
	close(fd);

	/* 2) reopen RO, DROP cache so the fault does fresh large-folio readahead */
	fd = open(path, O_RDONLY);
	if (fd < 0) { unlink(path); return; }
	posix_fadvise(fd, 0, filesz, POSIX_FADV_DONTNEED);

	char *m = mmap(NULL, filesz, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
	if (m != MAP_FAILED) {
		madvise(m, filesz, MADV_HUGEPAGE);			/* encourage large folios (capped sub-PMD by the kernel) */
		posix_fadvise(fd, 0, filesz, POSIX_FADV_WILLNEED);	/* kick readahead */
		/* MADV_POPULATE_READ faults the whole range via the populate path,
		 * which PTE-maps the large folio (not do_set_pmd) -> fork takes
		 * copy_present_ptes (the #143 path), per the PMD-trace analysis. */
		madvise(m, filesz, MADV_POPULATE_READ);
		volatile unsigned long s = touch_ro(m);			/* ensure present */

		/* fork while the large file mapping is live: folio_dup_file_rmap_ptes
		 * over-counts; parent keeps it across rounds so it accumulates */
		for (int k = 0; k < 4 && nowsec() < deadline; k++) {
			pid_t c = fork();
			if (c == 0) { volatile unsigned long t = touch_ro(m); (void)t; _exit(0); }
			else if (c > 0) { int st; waitpid(c, &st, 0); }
			else break;
		}
		munmap(m, filesz);
		(void)s;
	}
	close(fd);
	unlink(path);	/* free the (scrambled) folio -> Bad page state if underflowed */
}

static void worker(const char *dir, int id)
{
	for (unsigned it = 0; nowsec() < deadline; it++)
		cycle(dir, id, it);
}

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "/var/tmp";
	int secs = argc > 2 ? atoi(argv[2]) : 90;
	int nw   = argc > 3 ? atoi(argv[3]) : 8;
	if (argc > 4) filesz = (unsigned long)atoi(argv[4]) * MB;

	deadline = nowsec() + secs;
	printf("LF start dir=%s secs=%d workers=%d filesz=%luMB (ext4 RO drop-cache + fork-dup)\n",
	       dir, secs, nw, filesz / MB);
	fflush(stdout);

	pid_t k[64];
	if (nw > 64) nw = 64;
	for (int i = 0; i < nw; i++) {
		pid_t p = fork();
		if (p == 0) { worker(dir, i); _exit(0); }
		k[i] = p;
	}
	for (int i = 0; i < nw; i++) { int st; waitpid(k[i], &st, 0); }
	printf("LF DONE\n");
	return 0;
}
