/*
 * damon-bench.c — PGCL vs baseline DAMON/THP/compaction benchmark
 *
 * Measures:
 *   1. Page fault rate for sequential access
 *   2. THP collapse latency (time until khugepaged promotes to hugepages)
 *   3. Compaction effort (pages scanned/migrated)
 *   4. Struct page overhead (managed pages × 64 bytes)
 *   5. Fragmentation resistance (hugepage assembly after deliberate fragmentation)
 *
 * Drives DAMON via sysfs when available, but all core measurements use
 * /proc/vmstat and /proc/self/smaps directly — no userspace tools needed.
 *
 * Build: ${CC} -static -o damon-bench damon-bench.c -lpthread
 * Usage: damon-bench [-a]   # -a runs all tests, default runs fault+thp+compact
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>

static void alarm_nop(int sig) { (void)sig; }

/* ── helpers ─────────────────────────────────────────────────────────── */

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

static long read_smaps_thp(void *addr, size_t len)
{
	FILE *f = fopen("/proc/self/smaps", "r");
	if (!f) return -1;
	char line[256];
	int found = 0;
	long thp_kb = 0;
	unsigned long target = (unsigned long)addr;
	while (fgets(line, sizeof(line), f)) {
		unsigned long start, end;
		if (sscanf(line, "%lx-%lx", &start, &end) == 2)
			found = (target >= start && target < end);
		if (found && strncmp(line, "AnonHugePages:", 14) == 0) {
			thp_kb = atol(line + 14);
			break;
		}
	}
	fclose(f);
	return thp_kb;
}

static double monotonic_sec(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static long page_size(void)
{
	return sysconf(_SC_PAGESIZE);
}

static void write_file(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY);
	if (fd >= 0) {
		write(fd, val, strlen(val));
		close(fd);
	}
}

static int file_exists(const char *path)
{
	return access(path, F_OK) == 0;
}

/* ── Test 1: Page fault rate ─────────────────────────────────────────── */

static void test_fault_rate(void)
{
	size_t sz = 256UL << 20;  /* 256MB */
	long pgsz = page_size();

	printf("\n=== Test 1: Page Fault Rate ===\n");
	printf("Region size: %zuMB, page size (AT_PAGESZ): %ld\n", sz >> 20, pgsz);

	/* Disable THP for this test to measure raw fault clustering */
	void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		printf("SKIP: mmap failed (not enough memory)\n");
		return;
	}
	madvise(p, sz, MADV_NOHUGEPAGE);

	long faults_before = read_vmstat("pgfault");
	double t0 = monotonic_sec();

	/* Touch every hardware page sequentially */
	volatile char *cp = p;
	for (size_t i = 0; i < sz; i += pgsz)
		cp[i] = 1;

	double t1 = monotonic_sec();
	long faults_after = read_vmstat("pgfault");
	long faults = faults_after - faults_before;
	long expected_no_pgcl = sz / pgsz;

	printf("  Faults:   %ld\n", faults);
	printf("  Expected (no clustering): %ld\n", expected_no_pgcl);
	if (faults > 0)
		printf("  Clustering ratio: %.1fx fewer faults\n",
		       (double)expected_no_pgcl / faults);
	printf("  Time:     %.3f sec\n", t1 - t0);
	printf("  Rate:     %.0f faults/sec\n", faults / (t1 - t0));

	munmap(p, sz);
}

/* ── Test 2: THP collapse latency ────────────────────────────────────── */

static void test_thp_collapse(void)
{
	size_t sz = 32UL << 20;  /* 32MB — enough for several hugepages */

	printf("\n=== Test 2: THP Collapse Latency ===\n");

	/* Check if THP is available */
	if (!file_exists("/sys/kernel/mm/transparent_hugepage/enabled")) {
		printf("SKIP: THP not available\n");
		return;
	}

	long collapse_before = read_vmstat("thp_collapse_alloc");
	long collapse_fail_before = read_vmstat("thp_collapse_alloc_failed");

	void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		printf("SKIP: mmap failed\n");
		return;
	}
	/* Allow THP */
	madvise(p, sz, MADV_HUGEPAGE);

	/* Fault all pages */
	memset(p, 0x42, sz);

	printf("  Region: %p-%p (%zuMB)\n", p, (char *)p + sz, sz >> 20);
	printf("  Waiting for khugepaged...\n");

	double t0 = monotonic_sec();
	double first_thp_time = 0;
	double full_thp_time = 0;
	long target_kb = sz / 1024;

	for (int i = 0; i < 60; i++) {
		long thp_kb = read_smaps_thp(p, sz);
		double elapsed = monotonic_sec() - t0;

		printf("  %5.1fs: AnonHugePages=%ldkB (%ld%%)\n",
		       elapsed, thp_kb, thp_kb * 100 / target_kb);

		if (thp_kb > 0 && first_thp_time == 0)
			first_thp_time = elapsed;
		if (thp_kb >= target_kb) {
			full_thp_time = elapsed;
			break;
		}
		sleep(1);
	}

	long collapse_after = read_vmstat("thp_collapse_alloc");
	long collapse_fail_after = read_vmstat("thp_collapse_alloc_failed");

	printf("  First hugepage appeared: %.1fs\n",
	       first_thp_time > 0 ? first_thp_time : -1.0);
	printf("  Full collapse: %.1fs\n",
	       full_thp_time > 0 ? full_thp_time : -1.0);
	printf("  Collapses: %ld successful, %ld failed\n",
	       collapse_after - collapse_before,
	       collapse_fail_after - collapse_fail_before);

	munmap(p, sz);
}

/* ── Test 3: Compaction effort ───────────────────────────────────────── */

static void test_compaction(void)
{
	printf("\n=== Test 3: Compaction Effort ===\n");

	long migrate_before = read_vmstat("compact_migrate_scanned");
	long free_before = read_vmstat("compact_free_scanned");
	long success_before = read_vmstat("compact_success");
	long fail_before = read_vmstat("compact_fail");
	long stall_before = read_vmstat("compact_stall");

	/* Trigger compaction by requesting a hugepage-sized allocation */
	size_t sz = 64UL << 20;  /* 64MB */
	void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		printf("SKIP: mmap failed\n");
		return;
	}
	madvise(p, sz, MADV_HUGEPAGE);
	memset(p, 0x55, sz);

	/* Trigger explicit compaction in a child process with timeout
	 * (compact_memory on 8GB QEMU can take minutes) */
	{
		pid_t cpid = fork();
		if (cpid == 0) {
			signal(SIGALRM, alarm_nop);
			alarm(30);
			write_file("/proc/sys/vm/compact_memory", "1");
			_exit(0);
		} else if (cpid > 0) {
			int wst;
			waitpid(cpid, &wst, 0);
		}
	}
	sleep(2);

	long migrate_after = read_vmstat("compact_migrate_scanned");
	long free_after = read_vmstat("compact_free_scanned");
	long success_after = read_vmstat("compact_success");
	long fail_after = read_vmstat("compact_fail");
	long stall_after = read_vmstat("compact_stall");

	printf("  Pages scanned (migrate): %ld\n", migrate_after - migrate_before);
	printf("  Pages scanned (free):    %ld\n", free_after - free_before);
	printf("  Compaction successes:    %ld\n", success_after - success_before);
	printf("  Compaction failures:     %ld\n", fail_after - fail_before);
	printf("  Compaction stalls:       %ld\n", stall_after - stall_before);

	munmap(p, sz);
}

/* ── Test 4: Struct page overhead ────────────────────────────────────── */

static void test_struct_page_overhead(void)
{
	printf("\n=== Test 4: Struct Page Overhead ===\n");

	long pgsz = page_size();
	FILE *f = fopen("/proc/zoneinfo", "r");
	if (!f) {
		printf("SKIP: cannot read /proc/zoneinfo\n");
		return;
	}

	long managed_total = 0;
	char line[256];
	while (fgets(line, sizeof(line), f)) {
		long v;
		if (sscanf(line, "        managed  %ld", &v) == 1)
			managed_total += v;
	}
	fclose(f);

	/* struct page is typically 64 bytes */
	long struct_page_bytes = managed_total * 64;
	long managed_bytes = managed_total * pgsz;  /* wrong for PGCL — kernel pages */

	/* Read actual MemTotal for the real number */
	f = fopen("/proc/meminfo", "r");
	long memtotal_kb = 0;
	if (f) {
		if (fgets(line, sizeof(line), f))
			sscanf(line, "MemTotal: %ld kB", &memtotal_kb);
		fclose(f);
	}

	printf("  Kernel page size: %ld bytes\n", pgsz);
	printf("  Managed kernel pages: %ld\n", managed_total);
	printf("  MemTotal: %ld kB\n", memtotal_kb);
	printf("  Struct page array: %ld kB (%.3f%% of RAM)\n",
	       struct_page_bytes / 1024,
	       100.0 * struct_page_bytes / (memtotal_kb * 1024.0));
	printf("  Struct pages per MB of RAM: %ld\n",
	       managed_total / (memtotal_kb / 1024));
}

/* ── Test 5: Fragmentation resistance ────────────────────────────────── */

static void test_fragmentation_resistance(void)
{
	printf("\n=== Test 5: Fragmentation Resistance (Hugepage Assembly) ===\n");

	if (!file_exists("/sys/kernel/mm/transparent_hugepage/enabled")) {
		printf("SKIP: THP not available\n");
		return;
	}

	long pgsz = page_size();
	/*
	 * Strategy: allocate many small regions, free every other one to
	 * create maximum fragmentation, then allocate a large region and
	 * see how quickly it gets collapsed to hugepages.
	 */
	int nchunks = 2048;
	size_t chunk_sz = 64 * 1024;  /* 64KB each — one kernel page with PGCL */
	void **chunks = calloc(nchunks, sizeof(void *));
	if (!chunks) {
		printf("SKIP: calloc failed\n");
		return;
	}

	printf("  Fragmenting: %d × %zukB allocations...\n",
	       nchunks, chunk_sz / 1024);

	/* Allocate all */
	for (int i = 0; i < nchunks; i++) {
		chunks[i] = mmap(NULL, chunk_sz, PROT_READ | PROT_WRITE,
				 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (chunks[i] != MAP_FAILED)
			memset(chunks[i], i & 0xff, chunk_sz);
	}

	/* Free every other one */
	for (int i = 0; i < nchunks; i += 2) {
		if (chunks[i] != MAP_FAILED)
			munmap(chunks[i], chunk_sz);
		chunks[i] = MAP_FAILED;
	}

	printf("  Freed %d/%d chunks (checkerboard pattern)\n",
	       nchunks / 2, nchunks);

	/* Now allocate a 16MB region and request hugepages */
	size_t big_sz = 16UL << 20;
	long collapse_before = read_vmstat("thp_collapse_alloc");
	long collapse_fail_before = read_vmstat("thp_collapse_alloc_failed");
	long compact_before = read_vmstat("compact_migrate_scanned");

	void *big = mmap(NULL, big_sz, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (big == MAP_FAILED) {
		printf("SKIP: cannot allocate %zuMB region\n", big_sz >> 20);
		goto cleanup;
	}
	madvise(big, big_sz, MADV_HUGEPAGE);
	memset(big, 0xAA, big_sz);

	printf("  Allocated %zuMB, waiting for THP collapse...\n", big_sz >> 20);

	double t0 = monotonic_sec();
	long target_kb = big_sz / 1024;
	double collapse_time = -1;

	for (int i = 0; i < 45; i++) {
		long thp_kb = read_smaps_thp(big, big_sz);
		double elapsed = monotonic_sec() - t0;
		if (i % 5 == 0 || thp_kb >= target_kb)
			printf("  %5.1fs: AnonHugePages=%ldkB (%ld%%)\n",
			       elapsed, thp_kb, thp_kb * 100 / target_kb);
		if (thp_kb >= target_kb) {
			collapse_time = elapsed;
			break;
		}
		sleep(1);
	}

	long collapse_after = read_vmstat("thp_collapse_alloc");
	long collapse_fail_after = read_vmstat("thp_collapse_alloc_failed");
	long compact_after = read_vmstat("compact_migrate_scanned");

	printf("  Collapse time: %.1fs\n", collapse_time);
	printf("  Collapses: %ld ok, %ld failed\n",
	       collapse_after - collapse_before,
	       collapse_fail_after - collapse_fail_before);
	printf("  Compaction pages scanned: %ld\n",
	       compact_after - compact_before);

	munmap(big, big_sz);

cleanup:
	for (int i = 0; i < nchunks; i++) {
		if (chunks[i] != MAP_FAILED)
			munmap(chunks[i], chunk_sz);
	}
	free(chunks);
}

/* ── Test 6: DAMON sysfs monitoring ──────────────────────────────────── */

static void test_damon_monitoring(void)
{
	printf("\n=== Test 6: DAMON Access Monitoring ===\n");

	if (!file_exists("/sys/kernel/mm/damon/admin")) {
		printf("SKIP: DAMON sysfs not available\n");
		return;
	}

	/*
	 * Configure DAMON via sysfs to monitor our process.
	 * This is the minimal sysfs configuration sequence.
	 */
	char pidbuf[32];
	snprintf(pidbuf, sizeof(pidbuf), "%d", getpid());

	/* Set up DAMON context */
	write_file("/sys/kernel/mm/damon/admin/kdamonds/nr_kdamonds", "1");
	write_file("/sys/kernel/mm/damon/admin/kdamonds/0/contexts/nr_contexts", "1");
	write_file("/sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/operations", "vaddr");

	/* Set target */
	write_file("/sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/targets/nr_targets", "1");
	write_file("/sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/targets/0/pid_target", pidbuf);

	/* Set monitoring intervals: 5ms sample, 100ms aggr, 1s update */
	write_file("/sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/monitoring_attrs/intervals/sample_us", "5000");
	write_file("/sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/monitoring_attrs/intervals/aggr_us", "100000");
	write_file("/sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/monitoring_attrs/intervals/update_us", "1000000");

	/* Start DAMON */
	write_file("/sys/kernel/mm/damon/admin/kdamonds/0/state", "on");

	printf("  DAMON started, monitoring PID %s\n", pidbuf);

	/* Run a workload: sequential scan of 64MB */
	size_t sz = 64UL << 20;
	void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		printf("SKIP: mmap failed\n");
		goto stop;
	}

	long pgsz = page_size();
	long faults_before = read_vmstat("pgfault");
	double t0 = monotonic_sec();

	/* 3 passes to let DAMON observe access patterns */
	for (int pass = 0; pass < 3; pass++) {
		volatile char *cp = p;
		for (size_t i = 0; i < sz; i += pgsz)
			cp[i] = pass + 1;
	}

	double t1 = monotonic_sec();
	long faults_after = read_vmstat("pgfault");

	printf("  Workload: 3 passes over %zuMB in %.2fs\n", sz >> 20, t1 - t0);
	printf("  Faults: %ld (first pass creates faults, passes 2-3 are TLB hits)\n",
	       faults_after - faults_before);

	/* Let DAMON aggregate for a moment */
	sleep(2);

	munmap(p, sz);

stop:
	/* Stop DAMON */
	write_file("/sys/kernel/mm/damon/admin/kdamonds/0/state", "off");
	printf("  DAMON stopped\n");
}

/* ── main ────────────────────────────────────────────────────────────── */

int main(int argc, char **argv)
{
	int run_all = 0;
	if (argc > 1 && strcmp(argv[1], "-a") == 0)
		run_all = 1;

	printf("========================================\n");
	printf(" PGCL DAMON/THP Benchmark\n");
	printf("========================================\n");

	/* Print system info */
	FILE *f = fopen("/proc/version", "r");
	if (f) {
		char line[256];
		if (fgets(line, sizeof(line), f)) {
			line[strcspn(line, "\n")] = 0;
			printf("Kernel: %s\n", line);
		}
		fclose(f);
	}
	printf("Page size (AT_PAGESZ): %ld\n", page_size());

	f = fopen("/proc/meminfo", "r");
	if (f) {
		char line[256];
		if (fgets(line, sizeof(line), f)) {
			line[strcspn(line, "\n")] = 0;
			printf("%s\n", line);
		}
		fclose(f);
	}

	/* Core tests — always run */
	test_fault_rate();
	test_thp_collapse();
	test_compaction();
	test_struct_page_overhead();

	/* Extended tests */
	test_fragmentation_resistance();

	if (run_all)
		test_damon_monitoring();

	printf("\n========================================\n");
	printf(" Benchmark Complete\n");
	printf("========================================\n");

	return 0;
}
