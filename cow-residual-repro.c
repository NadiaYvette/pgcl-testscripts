/*
 * cow-residual-repro: amplify the intermittent PGCL large-folio (mTHP) mapcount
 * over-count so it fires deterministically.  Under PGCL, sysconf(_SC_PAGESIZE)
 * is the MMUPAGE (hardware) size, so madvise/mprotect/alternating COW operate at
 * sub-(kernel-page) granularity and can split a kernel page's PTE cluster.
 *
 * Per iteration, on an mTHP-sized region: fault it whole (one large folio),
 * punch sub-page gaps (MADV_DONTNEED / mprotect a couple of MMUPAGEs), then fork
 * and have parent+child write alternating MMUPAGEs (COW).  Loop hard.
 */
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* Force a full compaction pass -> migrates movable (incl. THP) pages, exercising
 * the migration rmap path on our gapped clusters. */
static void force_compaction(void)
{
	int fd = open("/proc/sys/vm/compact_memory", O_WRONLY);
	if (fd >= 0) { (void)!write(fd, "1\n", 2); close(fd); }
}

int main(int argc, char **argv)
{
	long ps = sysconf(_SC_PAGESIZE);              /* = MMUPAGE under PGCL */
	int iters = argc > 1 ? atoi(argv[1]) : 3000;
	/* a few kernel pages' worth so the fault path makes an mTHP (order >= 2) */
	size_t sz = (size_t)ps * 64;                  /* 64 MMUPAGEs = 256K @ 4K MMU */
	int n = sz / ps;
	int bad_mmap = 0;

	for (int it = 0; it < iters; it++) {
		volatile char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
					MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) { bad_mmap++; continue; }
		madvise((void *)p, sz, MADV_HUGEPAGE);

		/* fault every MMUPAGE -> one (large) folio per kernel page */
		for (int i = 0; i < n; i++)
			p[(size_t)i * ps] = (char)(i + it);

		/* punch sub-page gaps inside kernel pages: drop a scattered few */
		madvise((void *)(p + 5 * ps), 3 * ps, MADV_DONTNEED);   /* gap 5..7  */
		madvise((void *)(p + 21 * ps), 2 * ps, MADV_DONTNEED);  /* gap 21..22 */
		mprotect((void *)(p + 12 * ps), ps, PROT_READ);         /* RO 12 */
		mprotect((void *)(p + 12 * ps), ps, PROT_READ | PROT_WRITE);

		pid_t pid = fork();
		if (pid == 0) {
			/* child: refault gaps + write even MMUPAGEs (COW) */
			for (int i = 0; i < n; i += 2)
				p[(size_t)i * ps] = (char)(0x80 + i);
			_exit(0);
		}
		if (pid > 0) {
			/* parent: write odd MMUPAGEs (COW) then reap */
			for (int i = 1; i < n; i += 2)
				p[(size_t)i * ps] = (char)(0xC0 + i);
			int st;
			waitpid(pid, &st, 0);
		}
		/* migrate the now-gapped, still-mapped mTHP -> migration rmap path */
		if ((it & 15) == 0)
			force_compaction();
		munmap((void *)p, sz);
		if ((it & 511) == 0)
			write(1, ".", 1);
	}
	printf("\ncow-residual-repro done: %d iters, %d bad_mmap, ps=%ld sz=%zu\n",
	       iters, bad_mmap, ps, sz);
	return 0;
}
