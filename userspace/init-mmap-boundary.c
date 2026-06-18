/*
 * init-mmap-boundary.c - PGCL large-file-folio rmap boundary stressor.
 *
 * Targets the Contract-A mapcount path that init-btrfs-io.c only hit in the
 * aligned nr>1 case.  Exercises:
 *   T1 whole-file mmap+verify (aligned nr>1 eager path)
 *   T2 unaligned sub-range mmap (offset/len 4K-granular, not cluster-aligned)
 *   T3 partial munmap that SPLITS clusters, then verify the surviving head+tail
 *      (partial-cluster zap / last-present detection)
 *   T4 MAP_FIXED at a +4K (non-cluster-aligned) address -> forces the nr==1
 *      fallback fault of a large folio (and, when it crosses a PMD, the
 *      straddle case) -> exercises set_pte_range first-present detection
 *   T5 many map/unmap cycles -> a mapcount underflow trips "Bad page map";
 *      a mapcount leak never frees the folio -> eventual OOM.
 *
 * Any memcmp mismatch => CORRUPT (the data bug).  Kernel-side "Bad page map"
 * shows on the console regardless.  PASS => poweroff.
 *
 * Build: gcc -O2 -static -include stdarg.h -o init-mmap-boundary init-mmap-boundary.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <sys/stat.h>

#define MARK "PGCL-MMAP-BND"
#define MMU 4096UL              /* hardware page (userspace-visible) */
static void W(const char *s) { (void)write(1, s, strlen(s)); }
static void Wf(const char *fmt, ...) {
	char b[240]; va_list ap; va_start(ap, fmt);
	vsnprintf(b, sizeof b, fmt, ap); va_end(ap); W(b);
}

static unsigned char patbyte(size_t i, unsigned seed) {
	return (unsigned char)(seed * 2654435761u + i * 1099087573u + (i >> 13));
}

/* write a file of size sz with a seeded pattern; returns fd or <0 */
static int mkpat(const char *path, size_t sz, unsigned seed)
{
	char *buf = malloc(sz);
	if (!buf) return -1;
	for (size_t i = 0; i < sz; i++) buf[i] = patbyte(i, seed);
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { free(buf); return -2; }
	for (size_t off = 0; off < sz; ) {
		ssize_t r = write(fd, buf + off, sz - off);
		if (r <= 0) { close(fd); free(buf); return -3; }
		off += r;
	}
	fsync(fd); free(buf);
	return fd;
}

/* verify [lo,hi) of mapping m against pattern seed; 0 ok, -1 mismatch */
static int vrfy(const unsigned char *m, size_t lo, size_t hi, unsigned seed)
{
	for (size_t i = lo; i < hi; i++)
		if (m[i] != patbyte(i, seed)) return -1;
	return 0;
}

static int fails;
#define CHK(cond, ...) do { if (!(cond)) { Wf(MARK ": CORRUPT " __VA_ARGS__); fails++; } } while (0)

static void test_size(const char *dir, unsigned id, size_t sz)
{
	char path[96];
	unsigned seed = 0x9e37 ^ (id * 40503u) ^ (unsigned)sz;
	snprintf(path, sizeof path, "%s/b%u.dat", dir, id);
	int fd = mkpat(path, sz, seed);
	if (fd < 0) { Wf(MARK ": IOERR mk id=%u sz=%zu rc=%d\n", id, sz, fd); fails++; return; }

	/* T1: whole-file mmap (aligned, nr>1 for multi-cluster) */
	unsigned char *m = mmap(NULL, sz, PROT_READ, MAP_PRIVATE, fd, 0);
	CHK(m != MAP_FAILED, "T1 map id=%u sz=%zu errno=%d\n", id, sz, errno);
	if (m != MAP_FAILED) {
		CHK(vrfy(m, 0, sz, seed) == 0, "T1 id=%u sz=%zu\n", id, sz);
		munmap(m, sz);
	}

	/* T2: unaligned sub-range mmaps (4K-granular offset+len, not cluster-aligned) */
	size_t offs[] = { MMU, 5*MMU, 17*MMU };
	for (unsigned o = 0; o < 3; o++) {
		size_t off = offs[o];
		if (off + MMU >= sz) continue;
		size_t len = sz - off - (MMU/2 ? 0 : 0);
		/* round len down to MMU, leave it deliberately non-cluster-len */
		len = ((sz - off) / MMU) * MMU;
		if (!len) continue;
		unsigned char *s = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, off);
		CHK(s != MAP_FAILED, "T2 map id=%u off=%zu len=%zu errno=%d\n", id, off, len, errno);
		if (s != MAP_FAILED) {
			for (size_t i = 0; i < len; i++)
				if (s[i] != patbyte(off + i, seed)) { CHK(0, "T2 id=%u off=%zu i=%zu\n", id, off, i); break; }
			munmap(s, len);
		}
	}

	/* T3: whole map, partial munmap of a cluster-splitting middle, verify survivors */
	if (sz >= 8*MMU) {
		unsigned char *w = mmap(NULL, sz, PROT_READ, MAP_PRIVATE, fd, 0);
		CHK(w != MAP_FAILED, "T3 map id=%u errno=%d\n", id, errno);
		if (w != MAP_FAILED) {
			size_t a = 3*MMU, b = (sz/MMU - 2)*MMU;  /* 4K-aligned, not cluster-aligned */
			(void)vrfy(w, 0, sz, seed);              /* fault it all in first */
			munmap(w + a, b - a);                    /* split clusters */
			CHK(vrfy(w, 0, a, seed) == 0, "T3-head id=%u\n", id);
			CHK(vrfy(w, b, sz, seed) == 0, "T3-tail id=%u\n", id);
			munmap(w, a); munmap(w + b, sz - b);
		}
	}

	/* T4: MAP_FIXED at a +4K (non-cluster-aligned) addr -> nr==1 fallback / straddle */
	if (sz >= 4*MMU) {
		size_t rsv = sz + (1UL<<21);             /* reserve > a PMD so +4K can straddle */
		unsigned char *base = mmap(NULL, rsv, PROT_READ, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		CHK(base != MAP_FAILED, "T4 rsv id=%u errno=%d\n", id, errno);
		if (base != MAP_FAILED) {
			unsigned char *want = base + MMU;     /* +4K: MMU-aligned, not cluster-aligned */
			unsigned char *f = mmap(want, sz, PROT_READ, MAP_PRIVATE|MAP_FIXED, fd, 0);
			CHK(f == want, "T4 fixed id=%u got=%p want=%p errno=%d\n", id, (void*)f, (void*)want, errno);
			if (f == want) {
				CHK(vrfy(f, 0, sz, seed) == 0, "T4 id=%u sz=%zu\n", id, sz);
				munmap(f, sz);
			}
			munmap(base, rsv);
		}
	}

	close(fd);
	unlink(path);
}

static void worker(int wkr, const char *dir)
{
	/* sizes chosen to make partial clusters at both 64K and 256K PAGE_SIZE */
	const size_t sizes[] = {
		3*MMU, 16*MMU, 17*MMU, 64*MMU, 65*MMU, 80*MMU, 256*MMU, 257*MMU, 320*MMU,
	};
	for (int it = 0; it < 60; it++) {              /* T5: many cycles -> leak=>OOM, underflow=>bad map */
		for (unsigned s = 0; s < sizeof(sizes)/sizeof(sizes[0]); s++)
			test_size(dir, (unsigned)(wkr*1000 + it*10 + s), sizes[s]);
		if (wkr == 0 && it % 10 == 0) Wf(MARK ": hb it=%d fails=%d\n", it, fails);
	}
	_exit(fails ? 7 : 0);
}

int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	mkdir("/proc", 0755); mount("proc", "/proc", "proc", 0, 0);
	mkdir("/testdir", 0755);
	W(MARK ": start (large-file-folio rmap boundary stress)\n");

	int nw = 4;
	for (int wkr = 0; wkr < nw; wkr++) {
		pid_t p = fork();
		if (p == 0) worker(wkr, "/testdir");
	}
	int st, n = 0, fl = 0;
	while (wait(&st) > 0) { n++; if (!WIFEXITED(st) || WEXITSTATUS(st)) fl++; }
	Wf(MARK ": workers=%d failed=%d\n", n, fl);
	W(fl ? MARK ": FAIL\n" : MARK ": PASS\n");
	sync(); W(MARK ": halting\n");
	reboot(RB_POWER_OFF);
	for (;;) pause();
	return 0;
}
