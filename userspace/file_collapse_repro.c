/*
 * file_collapse_repro — target the file THP-collapse rmap path (#121/#143).
 *
 * Having ruled out fault/zap/COW/reclaim/fork-dup (all symmetric under PGCL
 * because folio_pte_batch advances by PFN -> nr==1 per sub-PTE), the remaining
 * suspect for the file-folio mapcount underflow is the complex rmap-rewriting
 * paths: file THP collapse (khugepaged / MADV_COLLAPSE) and folio split.
 * gst/wireplumber/gnome map many .so/data files that khugepaged collapses.
 * MADV_COLLAPSE forces that path synchronously.
 *
 * usage: file_collapse_repro <dir> <seconds> [workers]
 * Under DEBUG_VM a collapse/split rmap miscount trips a "Bad page" oops or the
 * #121 VM_BUG_ON in khugepaged.c.
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

#ifndef MADV_COLLAPSE
#define MADV_COLLAPSE 25
#endif
#define HPAGE (2UL * 1024 * 1024)
#define FILESZ (8UL * HPAGE)		/* 16 MiB -> several PMD-collapsible ranges */

static long deadline;
static long nowsec(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec; }

static void worker(const char *dir, int id)
{
	char path[256];
	snprintf(path, sizeof path, "%s/fc_%d_%ld.bin", dir, id, (long)getpid());
	for (unsigned it = 0; nowsec() < deadline; it++) {
		int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (fd < 0) return;
		if (ftruncate(fd, FILESZ)) { close(fd); unlink(path); return; }
		char *b = malloc(HPAGE);
		for (unsigned long o = 0; o < FILESZ; o += HPAGE) { memset(b, it+1, HPAGE); if (write(fd, b, HPAGE) < 0) break; }
		free(b);
		char *m = mmap(NULL, FILESZ, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
		char *s = mmap(NULL, FILESZ, PROT_READ, MAP_SHARED, fd, 0);
		if (m == MAP_FAILED || s == MAP_FAILED) { if(m!=MAP_FAILED)munmap(m,FILESZ); if(s!=MAP_FAILED)munmap(s,FILESZ); close(fd); continue; }

		/* fault in small folios across the range (both maps) */
		for (unsigned long o = 0; o < FILESZ; o += 4096) { (void)*(volatile char*)(s+o); (void)*(volatile char*)(m+o); }
		/* force THP collapse of the small file folios -> heavy rmap rewrite */
		madvise(s, FILESZ, MADV_COLLAPSE);
		madvise(m, FILESZ, MADV_COLLAPSE);
		/* COW a few sub-pages of the (now possibly collapsed) private map */
		for (unsigned long o = 0; o < FILESZ; o += HPAGE/4) m[o] = 'x';
		/* split it back down */
		for (unsigned long o = HPAGE; o < FILESZ; o += HPAGE) mprotect(m + o, 4096, PROT_READ);
		/* fork + exit (zap collapsed/split mappings) */
		pid_t c = fork();
		if (c == 0) { madvise(m, FILESZ, MADV_COLLAPSE); _exit(0); }
		else if (c > 0) { int st; waitpid(c,&st,0); }
		munmap(m, FILESZ); munmap(s, FILESZ); close(fd);
	}
	unlink(path);
}

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "/tmp";
	int secs = argc > 2 ? atoi(argv[2]) : 60;
	int nw = argc > 3 ? atoi(argv[3]) : 6;
	deadline = nowsec() + secs;
	printf("FCOLL start dir=%s secs=%d workers=%d\n", dir, secs, nw);
	fflush(stdout);
	pid_t k[32]; if (nw > 32) nw = 32;
	for (int i = 0; i < nw; i++) { pid_t p = fork(); if (p == 0) { worker(dir, i); _exit(0); } k[i] = p; }
	for (int i = 0; i < nw; i++) { int st; waitpid(k[i], &st, 0); }
	printf("FCOLL DONE\n");
	return 0;
}
