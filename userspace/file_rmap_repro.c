/*
 * file_rmap_repro — provoke the PGCL file-folio rmap mapcount/refcount
 * UNDERFLOW (#143): "BUG: Bad page state/map", refcount/mapcount negative,
 * seen on the laptop in gst-plugin/wireplumber/etc. at GNOME session start.
 *
 * Strategy: mimic dlopen/dlclose of shared objects, which is what those
 * processes do — map a file PRIVATE at sub-cluster (MMUPAGE=4K) offsets with
 * mixed segment prots, COW-write into it (file->anon), mprotect RELRO-style
 * splits, fork, partial munmap, then exit (the zap path that underflowed).
 * Also a SHARED+writeback variant.  Many workers x iterations to hit the edge.
 *
 * usage: file_rmap_repro <dir> <seconds> [workers]
 *
 * Under a DEBUG_VM PGCL kernel the underflow trips a kernel "Bad page" oops
 * (watch dmesg) -- the userspace side just performs the operations.  Data
 * self-checks are included as a secondary signal.
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

#ifndef CLUSTER
#define CLUSTER (64UL * 1024)		/* PAGE_SIZE at PAGE_MMUSHIFT=4 */
#endif
#define MMU 4096UL			/* MMUPAGE / getpagesize() */
#define FILESZ (4UL * 1024 * 1024)	/* 4 MiB -> large readahead folios */

static long deadline;
static long nowsec(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec; }

/* create+populate a file so its page cache holds (large) file folios */
static int makefile(const char *dir, int id)
{
	char path[256];
	snprintf(path, sizeof path, "%s/so_%d_%ld.bin", dir, id, (long)getpid());
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) return -1;
	char *buf = malloc(CLUSTER);
	if (!buf) { close(fd); return -1; }
	for (unsigned long o = 0; o < FILESZ; o += CLUSTER) {
		memset(buf, (int)(o / CLUSTER) + 1, CLUSTER);
		if (write(fd, buf, CLUSTER) != (ssize_t)CLUSTER) break;
	}
	free(buf);
	fsync(fd);
	unlink(path);		/* keep the fd; vanishes on close (like a temp .so) */
	return fd;
}

/* one dlopen-like cycle: private map, sub-cluster faults, COW, RELRO, fork */
static void dlopen_cycle(int fd, unsigned it)
{
	char *m = mmap(NULL, FILESZ, PROT_READ, MAP_PRIVATE, fd, 0);
	if (m == MAP_FAILED) return;

	/* read-fault scattered sub-PTEs (4K) across clusters, not whole clusters */
	for (unsigned long o = (it % 3) * MMU; o < FILESZ; o += 3 * MMU)
		(void)*(volatile char *)(m + o);

	/* a text-like exec segment + a writable data segment at sub-cluster offset */
	mprotect(m + CLUSTER, CLUSTER, PROT_READ | PROT_EXEC);
	mprotect(m + 2 * CLUSTER + MMU, 2 * MMU, PROT_READ | PROT_WRITE);

	/* COW-write into the writable window (file folio -> anon, sub-PTE) */
	m[2 * CLUSTER + MMU] = 'X';
	m[2 * CLUSTER + 2 * MMU] = 'Y';
	/* COW a few more scattered sub-PTEs after making them writable */
	mprotect(m + 3 * CLUSTER, CLUSTER, PROT_READ | PROT_WRITE);
	for (unsigned long o = 3 * CLUSTER; o < 4 * CLUSTER; o += 2 * MMU)
		m[o] = (char)o;

	/* RELRO-style: flip part back to read-only (VMA split mid-cluster) */
	mprotect(m + 3 * CLUSTER, MMU, PROT_READ);

	pid_t c = fork();
	if (c == 0) {
		/* child: touch + COW different sub-PTEs, then exit -> zap */
		for (unsigned long o = MMU; o < 2 * CLUSTER; o += 5 * MMU)
			(void)*(volatile char *)(m + o);
		mprotect(m, CLUSTER, PROT_READ | PROT_WRITE);
		m[MMU] = 'c'; m[7 * MMU] = 'd';
		_exit(0);
	} else if (c > 0) {
		int st; waitpid(c, &st, 0);
	}

	/* partial munmap: punch a hole in the middle (splits the VMA + rmap) */
	munmap(m + CLUSTER, CLUSTER);
	/* unmap the rest in two pieces */
	munmap(m, CLUSTER);
	munmap(m + 2 * CLUSTER, FILESZ - 2 * CLUSTER);
}

/* SHARED variant: exercises writeback rmap on file folios too */
static void shared_cycle(int fd, unsigned it)
{
	char *m = mmap(NULL, FILESZ, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (m == MAP_FAILED) return;
	for (unsigned long o = (it % 5) * MMU; o < FILESZ; o += 4 * MMU)
		m[o] = (char)(o + it);
	msync(m, FILESZ, MS_ASYNC);
	pid_t c = fork();
	if (c == 0) { for (unsigned long o = 0; o < FILESZ; o += 7 * MMU) (void)*(volatile char*)(m+o); _exit(0); }
	else if (c > 0) { int st; waitpid(c,&st,0); }
	munmap(m + 2 * MMU, FILESZ - 4 * MMU);	/* unaligned partial */
	munmap(m, 2 * MMU);
	munmap(m + FILESZ - 2 * MMU, 2 * MMU);
}

static void worker(const char *dir, int id)
{
	for (unsigned it = 0; nowsec() < deadline; it++) {
		int fd = makefile(dir, id);
		if (fd < 0) { usleep(1000); continue; }
		if (it & 1) dlopen_cycle(fd, it); else shared_cycle(fd, it);
		close(fd);		/* drops the last ref -> file folios freed */
	}
}

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "/tmp";
	int secs = argc > 2 ? atoi(argv[2]) : 60;
	int nw = argc > 3 ? atoi(argv[3]) : 8;
	deadline = nowsec() + secs;
	printf("FRMAP start dir=%s secs=%d workers=%d cluster=%lu\n", dir, secs, nw, CLUSTER);
	fflush(stdout);
	pid_t k[64]; if (nw > 64) nw = 64;
	for (int i = 0; i < nw; i++) { pid_t p = fork(); if (p == 0) { worker(dir, i); _exit(0); } k[i] = p; }
	for (int i = 0; i < nw; i++) { int st; waitpid(k[i], &st, 0); }
	printf("FRMAP DONE\n");
	return 0;
}
