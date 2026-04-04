/*
 * frag-bench.c — Memory fragmentation + THP collapse benchmark for PGCL
 *
 * Implements three fragmentation strategies inspired by:
 *   1. transhuge-stress (kernel selftests) — pin one sub-page per 2MB
 *   2. compaction_test (kernel selftests) — checkerboard locked chunks
 *   3. masim-stairs (DAMON project) — phased multi-region access
 *
 * After each fragmentation, measures THP collapse time for a fresh
 * allocation. The hypothesis: PGCL's 16x coarser pages should survive
 * fragmentation better, yielding faster THP collapse.
 *
 * Build: ${CC} -static -O2 -o frag-bench frag-bench.c -lpthread
 * Usage: frag-bench [-a]     # -a = all modes, or specify --transhuge etc.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <time.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <stdint.h>

/* ── helpers ─────────────────────────────────────────────────────────── */

static long page_size(void)
{
	static long ps;
	if (!ps) {
		unsigned long *auxv;
		extern char **environ;
		char **p = environ;
		while (*p++) ;
		for (auxv = (unsigned long *)p; *auxv; auxv += 2)
			if (*auxv == 6) { ps = auxv[1]; break; }
		if (!ps) ps = sysconf(_SC_PAGESIZE);
	}
	return ps;
}

static long read_vmstat(const char *key)
{
	FILE *f = fopen("/proc/vmstat", "r");
	if (!f) return -1;
	char line[256];
	long val = -1;
	int klen = strlen(key);
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, key, klen) == 0 && line[klen] == ' ') {
			val = atol(line + klen + 1);
			break;
		}
	}
	fclose(f);
	return val;
}

static long read_smaps_anon_huge(void *addr)
{
	FILE *f = fopen("/proc/self/smaps", "r");
	if (!f) return -1;
	char line[512];
	unsigned long target = (unsigned long)addr;
	int found_vma = 0;
	long ahp = -1;

	while (fgets(line, sizeof(line), f)) {
		unsigned long start, end;
		if (sscanf(line, "%lx-%lx", &start, &end) == 2) {
			found_vma = (target >= start && target < end);
		}
		if (found_vma && strncmp(line, "AnonHugePages:", 14) == 0) {
			ahp = atol(line + 14);
			break;
		}
	}
	fclose(f);
	return ahp;
}

static long read_memfree_kb(void)
{
	FILE *f = fopen("/proc/meminfo", "r");
	if (!f) return -1;
	char line[256];
	long val = -1;
	while (fgets(line, sizeof(line), f)) {
		if (sscanf(line, "MemFree: %ld kB", &val) == 1)
			break;
	}
	fclose(f);
	return val;
}

static long read_memtotal_kb(void)
{
	FILE *f = fopen("/proc/meminfo", "r");
	if (!f) return -1;
	char line[256];
	long val = -1;
	while (fgets(line, sizeof(line), f)) {
		if (sscanf(line, "MemTotal: %ld kB", &val) == 1)
			break;
	}
	fclose(f);
	return val;
}

static void write_file(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY);
	if (fd >= 0) {
		write(fd, val, strlen(val));
		close(fd);
	}
}

static double monotonic_sec(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void alarm_nop(int sig) { (void)sig; }

/*
 * Aggressive fragmenter: fill nearly all RAM with locked pages,
 * then free one page per stride. If stride < 512 (baseline 4KB pages)
 * or stride < 32 (PGCL 64KB pages), no contiguous 2MB block exists,
 * forcing khugepaged to rely on compaction.
 *
 * Returns pointer/size for caller to clean up.
 */
struct frag_state {
	void *base;
	size_t total_sz;
	size_t stride_pages;  /* lock stride in kernel pages */
	void *drain;
	size_t drain_sz;
};

static int aggressive_fragment(struct frag_state *fs, size_t stride_bytes,
			       int pct_fill)
{
	struct rlimit lim = { RLIM_INFINITY, RLIM_INFINITY };
	setrlimit(RLIMIT_MEMLOCK, &lim);

	long ps = page_size();
	long memfree_kb = read_memfree_kb();
	size_t fill_sz = (size_t)(memfree_kb * pct_fill / 100) * 1024;
	/* Align to stride boundary */
	fill_sz -= fill_sz % stride_bytes;

	printf("  Allocating %zu MB (%d%% of free)...\n",
	       fill_sz >> 20, pct_fill);

	void *base = mmap(NULL, fill_sz, PROT_READ | PROT_WRITE,
			  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (base == MAP_FAILED) {
		printf("  SKIP: mmap %zu MB failed\n", fill_sz >> 20);
		return -1;
	}
	madvise(base, fill_sz, MADV_NOHUGEPAGE);

	/* Fault all pages */
	for (size_t off = 0; off < fill_sz; off += ps)
		*(volatile char *)(base + off) = 1;

	/* Lock everything */
	printf("  Locking %zu MB...\n", fill_sz >> 20);
	if (mlock(base, fill_sz) != 0) {
		/* Try page by page if bulk fails */
		int locked = 0;
		for (size_t off = 0; off < fill_sz; off += ps) {
			if (mlock(base + off, ps) == 0) locked++;
		}
		printf("  Locked %d/%zu pages individually\n",
		       locked, fill_sz / ps);
	}

	/* Punch holes: unlock+free one page every stride_bytes */
	int holes = 0;
	for (size_t off = 0; off < fill_sz; off += stride_bytes) {
		munlock(base + off, ps);
		madvise(base + off, ps, MADV_DONTNEED);
		holes++;
	}

	printf("  Punched %d holes (every %zu bytes = %zu KB)\n",
	       holes, stride_bytes, stride_bytes / 1024);
	printf("  Free memory created: ~%d × %ld KB = %ld KB\n",
	       holes, ps / 1024, (long)holes * ps / 1024);
	printf("  MemFree after holes: %ld kB\n", read_memfree_kb());

	/*
	 * Phase 2: Drain remaining contiguous free memory.
	 * Allocate+fault (no mlock) additional memory, leaving ~200MB free.
	 * This consumes contiguous free memory without the mlock overhead
	 * that pushed us into OOM. The pages are movable but occupy physical
	 * frames, preventing trivial hugepage allocation.
	 */
	long current_free = read_memfree_kb();
	long target_free = 200 * 1024;  /* leave 200MB free for THP + headroom */
	if (current_free > target_free + 100 * 1024) {
		size_t drain_sz = (size_t)(current_free - target_free) * 1024;
		drain_sz -= drain_sz % ps;
		printf("  Draining %zu MB of contiguous free memory...\n",
		       drain_sz >> 20);
		void *drain = mmap(NULL, drain_sz, PROT_READ | PROT_WRITE,
				   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (drain != MAP_FAILED) {
			madvise(drain, drain_sz, MADV_NOHUGEPAGE);
			/* Fault pages to consume physical memory */
			for (size_t off = 0; off < drain_sz; off += ps)
				*(volatile char *)(drain + off) = 2;
			fs->drain = drain;
			fs->drain_sz = drain_sz;
		} else {
			fs->drain = NULL;
			fs->drain_sz = 0;
		}
	} else {
		fs->drain = NULL;
		fs->drain_sz = 0;
	}

	printf("  MemFree after drain: %ld kB\n", read_memfree_kb());

	fs->base = base;
	fs->total_sz = fill_sz;
	fs->stride_pages = stride_bytes / ps;
	return 0;
}

static void aggressive_cleanup(struct frag_state *fs)
{
	if (fs->drain)
		munmap(fs->drain, fs->drain_sz);
	munlock(fs->base, fs->total_sz);
	munmap(fs->base, fs->total_sz);
}

/* ── THP collapse measurement ──────────────────────────────────────── */

#define COLLAPSE_SZ (32UL << 20)   /* 32MB — 16 hugepages */
#define COLLAPSE_TIMEOUT 60        /* seconds to wait for khugepaged */

static void measure_thp_collapse(const char *label)
{
	printf("\n  --- THP Collapse (%s) ---\n", label);

	long compact_before = read_vmstat("compact_migrate_scanned");
	long thp_collapse_ok = read_vmstat("thp_collapse_alloc");
	long thp_collapse_fail = read_vmstat("thp_collapse_alloc_failed");

	void *p = mmap(NULL, COLLAPSE_SZ, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		printf("  SKIP: mmap failed\n");
		return;
	}
	madvise(p, COLLAPSE_SZ, MADV_HUGEPAGE);
	memset(p, 0xAA, COLLAPSE_SZ);

	double t0 = monotonic_sec();
	double first_huge = -1;
	double full_collapse = -1;
	long target_kb = COLLAPSE_SZ / 1024;

	for (int i = 0; i < COLLAPSE_TIMEOUT * 10; i++) {
		struct timespec ts = { 0, 100000000L };  /* 100ms */
		nanosleep(&ts, NULL);
		long ahp = read_smaps_anon_huge(p);
		double elapsed = monotonic_sec() - t0;

		if (ahp > 0 && first_huge < 0) {
			first_huge = elapsed;
			printf("  First hugepage at %.1fs: AnonHugePages=%ldkB\n",
			       elapsed, ahp);
		}
		if (ahp >= target_kb) {
			full_collapse = elapsed;
			printf("  Full collapse at %.1fs: AnonHugePages=%ldkB (100%%)\n",
			       elapsed, ahp);
			break;
		}
		/* Progress report every 5s */
		if (i > 0 && i % 50 == 0)
			printf("    %.1fs: AnonHugePages=%ldkB (%ld%%)\n",
			       elapsed, ahp, ahp * 100 / target_kb);
	}

	if (full_collapse < 0) {
		long ahp = read_smaps_anon_huge(p);
		printf("  TIMEOUT after %ds: AnonHugePages=%ldkB (%ld%%)\n",
		       COLLAPSE_TIMEOUT, ahp, ahp * 100 / target_kb);
	}

	long compact_after = read_vmstat("compact_migrate_scanned");
	long thp_ok = read_vmstat("thp_collapse_alloc") - thp_collapse_ok;
	long thp_fail = read_vmstat("thp_collapse_alloc_failed") - thp_collapse_fail;

	printf("  Collapse allocs: %ld ok, %ld failed\n", thp_ok, thp_fail);
	printf("  Compaction pages scanned: %ld\n", compact_after - compact_before);
	printf("  Collapse time: %.1fs (first), %.1fs (full)\n",
	       first_huge >= 0 ? first_huge : -1.0,
	       full_collapse >= 0 ? full_collapse : -1.0);

	munmap(p, COLLAPSE_SZ);
}

/* ── Mode 1: transhuge-stress style ──────────────────────────────── */

/*
 * Pin one sub-page every 2MB across a large region.
 * This is the worst case for THP: physically scattered pinned pages
 * prevent the buddy allocator from forming contiguous 2MB blocks.
 *
 * Approach: mmap large region with MADV_HUGEPAGE, touch each 2MB chunk
 * to fault in pages, then MADV_DONTNEED all but last sub-page of each
 * chunk. The remaining pinned pages scatter physical memory.
 */
static void frag_transhuge_stress(void)
{
	printf("\n=== Mode 1: transhuge-stress ===\n");
	printf("  Lock 90%% of RAM, punch 1-page holes every 1MB.\n");
	printf("  Each free hole is one page — far smaller than 2MB hugepage.\n");
	printf("  Compaction must migrate locked pages to form 2MB runs.\n\n");

	struct frag_state fs;
	/* Holes every 1MB — no contiguous 2MB block can exist */
	if (aggressive_fragment(&fs, 1UL << 20, 90) < 0)
		return;

	measure_thp_collapse("after transhuge-stress");
	aggressive_cleanup(&fs);
}

/* ── Mode 2: compaction_test style ──────────────────────────────── */

/*
 * Fill ~60% of RAM with MAP_LOCKED 100MB chunks, then free every other
 * chunk. The remaining locked chunks are pinned in physical memory,
 * creating a checkerboard of free/locked 100MB regions.
 *
 * THP needs contiguous 2MB, but the scattered locked chunks limit
 * how much the compactor can defragment.
 */

#define CHUNK_SZ (100UL << 20)  /* 100MB per chunk */

struct chunk_list {
	void *addr;
	struct chunk_list *next;
};

static void frag_compaction_checkerboard(void)
{
	printf("\n=== Mode 2: compaction_test checkerboard ===\n");
	printf("  Lock 90%% of RAM, punch 1-page holes every 512KB.\n");
	printf("  Denser holes = more free memory, but in tiny pieces.\n\n");

	struct frag_state fs;
	/* Holes every 512KB — 4× more holes than mode 1 */
	if (aggressive_fragment(&fs, 512UL << 10, 90) < 0)
		return;

	measure_thp_collapse("after compaction checkerboard");
	aggressive_cleanup(&fs);
}

/* ── Mode 3: masim-stairs style ──────────────────────────────────── */

/*
 * Allocate 10 regions of 10MB each (100MB total). Access them in
 * sequential phases (like masim stairs.cfg), then fragment by
 * MADV_DONTNEED on even-numbered regions. The non-contiguous
 * access + partial free creates realistic working-set fragmentation.
 */

#define MASIM_NREGIONS   10
#define MASIM_REGION_SZ  (10UL << 20)  /* 10MB each */
#define MASIM_PHASE_MS   500           /* 500ms per phase */

static void frag_masim_stairs(void)
{
	printf("\n=== Mode 3: masim-stairs (mixed workload) ===\n");
	printf("  Lock 90%% of RAM, punch 1-page holes every 256KB.\n");
	printf("  Densest holes — most free memory in smallest pieces.\n\n");

	struct frag_state fs;
	/* Holes every 256KB — very dense fragmentation */
	if (aggressive_fragment(&fs, 256UL << 10, 90) < 0)
		return;

	measure_thp_collapse("after masim-stairs dense frag");
	aggressive_cleanup(&fs);
}

/* ── main ────────────────────────────────────────────────────────────── */

int main(int argc, char **argv)
{
	int do_all = 0, do_thstress = 0, do_compact = 0, do_masim = 0;

	printf("========================================\n");
	printf(" PGCL Fragmentation + THP Collapse Bench\n");
	printf("========================================\n");

	/* Print system info */
	{
		unsigned long *auxv;
		extern char **environ;
		char **p = environ;
		while (*p++) ;
		long at_pagesz = 0;
		for (auxv = (unsigned long *)p; *auxv; auxv += 2)
			if (*auxv == 6) { at_pagesz = auxv[1]; break; }
		FILE *f = fopen("/proc/version", "r");
		char ver[256] = {0};
		if (f) { fgets(ver, sizeof(ver), f); fclose(f); }
		printf("Kernel: %s", ver);
		printf("AT_PAGESZ: %ld\n", at_pagesz);
		printf("MemTotal: %ld kB\n", read_memtotal_kb());
		printf("MemFree:  %ld kB\n", read_memfree_kb());
	}

	/* First: measure baseline collapse (no fragmentation) */
	printf("\n=== Baseline: No Fragmentation ===\n");
	measure_thp_collapse("no fragmentation");

	/* Parse args */
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-a") || !strcmp(argv[i], "--all"))
			do_all = 1;
		else if (!strcmp(argv[i], "--transhuge"))
			do_thstress = 1;
		else if (!strcmp(argv[i], "--compaction"))
			do_compact = 1;
		else if (!strcmp(argv[i], "--masim"))
			do_masim = 1;
	}

	if (!do_all && !do_thstress && !do_compact && !do_masim)
		do_all = 1;

	if (do_all || do_thstress)
		frag_transhuge_stress();

	if (do_all || do_compact)
		frag_compaction_checkerboard();

	if (do_all || do_masim)
		frag_masim_stairs();

	printf("\n========================================\n");
	printf(" Benchmark Complete\n");
	printf("========================================\n");

	return 0;
}
