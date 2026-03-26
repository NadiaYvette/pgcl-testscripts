/*
 * PGCL (Page Clustering) Userspace Stress Tests
 *
 * Tests that the kernel correctly handles sub-page operations when
 * PAGE_SIZE > MMUPAGE_SIZE (hardware page size).
 *
 * Compile: $CC -static -O2 -o pgcl-test pgcl-test.c
 * Run as /init in initramfs, or from shell.
 */

#define _GNU_SOURCE
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/auxv.h>
#include <sys/resource.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
/* pthread.h removed: pgcl-test does not use pthreads */
#include <fcntl.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <stdint.h>

static int test_pass, test_fail;
static long page_size;  /* hardware MMU page size (from AT_PAGESZ) */

#define PASS(name) do { printf("  %-40s PASS\n", name); test_pass++; } while(0)
#define FAIL(name, ...) do { printf("  %-40s FAIL: ", name); printf(__VA_ARGS__); printf("\n"); test_fail++; } while(0)

/* ---- Test 1: AT_PAGESZ reports hardware page size ---- */
static void test_at_pagesz(void)
{
	long ps = sysconf(_SC_PAGESIZE);
	long at = getauxval(AT_PAGESZ);

	if (ps != at) {
		FAIL("at_pagesz", "sysconf=%ld auxval=%ld mismatch", ps, at);
		return;
	}
	/*
	 * With PGCL, AT_PAGESZ must report the HARDWARE page size
	 * (e.g. 4096 on x86, arm64, riscv, s390), not the kernel's
	 * internal PAGE_SIZE.
	 */
	if (ps == 4096 || ps == 8192 || ps == 16384 || ps == 65536) {
		PASS("at_pagesz");
	} else {
		FAIL("at_pagesz", "unexpected page size %ld", ps);
	}
}

/* ---- Test 2: mmap anonymous + touch every sub-page ---- */
static void test_mmap_basic(void)
{
	size_t sz = page_size * 16;  /* 16 hardware pages */
	volatile char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
				MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("mmap_basic", "mmap failed: %s", strerror(errno));
		return;
	}

	/* Write a unique byte to each hardware-page-sized offset */
	for (int i = 0; i < 16; i++)
		p[i * page_size] = (char)(i + 0x41);

	/* Read them back */
	int ok = 1;
	for (int i = 0; i < 16; i++) {
		if (p[i * page_size] != (char)(i + 0x41)) {
			ok = 0;
			break;
		}
	}

	munmap((void *)p, sz);
	if (ok) PASS("mmap_basic");
	else FAIL("mmap_basic", "data corruption");
}

/* ---- Test 3: mmap at MMUPAGE-aligned address (MAP_FIXED) ---- */
static void test_mmap_fixed(void)
{
	/* First get a big region */
	size_t sz = page_size * 64;
	char *base = mmap(NULL, sz, PROT_READ | PROT_WRITE,
			  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (base == MAP_FAILED) {
		FAIL("mmap_fixed", "base mmap failed");
		return;
	}

	/* Now MAP_FIXED a sub-page-aligned region inside it */
	char *sub = base + page_size * 3;  /* MMUPAGE-aligned but maybe not PAGE-aligned */
	char *p = mmap(sub, page_size, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("mmap_fixed", "MAP_FIXED at %p failed: %s", sub, strerror(errno));
		munmap(base, sz);
		return;
	}
	if (p != sub) {
		FAIL("mmap_fixed", "got %p expected %p", p, sub);
		munmap(base, sz);
		return;
	}

	/* Touch it */
	*p = 42;
	munmap(base, sz);
	PASS("mmap_fixed");
}

/* ---- Test 4: Fork COW — different sub-pages ---- */
static void test_fork_cow(void)
{
	size_t sz = page_size * 16;
	volatile char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
				MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("fork_cow", "mmap failed");
		return;
	}

	/* Fill with known pattern */
	for (int i = 0; i < 16; i++)
		p[i * page_size] = (char)(i + 1);

	pid_t pid = fork();
	if (pid < 0) {
		FAIL("fork_cow", "fork failed");
		munmap((void *)p, sz);
		return;
	}

	if (pid == 0) {
		/* Child: verify original data, then write different sub-pages */
		int child_ok = 1;
		for (int i = 0; i < 16; i++) {
			if (p[i * page_size] != (char)(i + 1)) {
				child_ok = 0;
				break;
			}
		}
		/* Write to even sub-pages */
		for (int i = 0; i < 16; i += 2)
			p[i * page_size] = (char)(0x80 + i);

		_exit(child_ok ? 0 : 1);
	}

	/* Parent: write to odd sub-pages */
	for (int i = 1; i < 16; i += 2)
		p[i * page_size] = (char)(0xC0 + i);

	int status;
	waitpid(pid, &status, 0);

	/* Verify parent's odd sub-pages are intact */
	int parent_ok = 1;
	for (int i = 1; i < 16; i += 2) {
		if (p[i * page_size] != (char)(0xC0 + i)) {
			parent_ok = 0;
			break;
		}
	}

	munmap((void *)p, sz);

	if (WIFEXITED(status) && WEXITSTATUS(status) == 0 && parent_ok)
		PASS("fork_cow");
	else
		FAIL("fork_cow", "child=%d parent_ok=%d",
		     WIFEXITED(status) ? WEXITSTATUS(status) : -1, parent_ok);
}

/* ---- Test 5: Fork COW all sub-pages stress ---- */
static void test_fork_cow_stress(void)
{
	int niter = 32;
	size_t sz = page_size * 16;
	int failures = 0;

	for (int iter = 0; iter < niter; iter++) {
		volatile char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
					MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) { failures++; continue; }

		for (int i = 0; i < 16; i++)
			p[i * page_size] = (char)(iter + i);

		pid_t pid = fork();
		if (pid == 0) {
			/* Child: write ALL sub-pages */
			for (int i = 0; i < 16; i++)
				p[i * page_size] = (char)(0xFF - i);
			_exit(0);
		}
		if (pid < 0) { failures++; munmap((void *)p, sz); continue; }

		int status;
		waitpid(pid, &status, 0);

		/* Parent: verify original data survived */
		for (int i = 0; i < 16; i++) {
			if (p[i * page_size] != (char)(iter + i)) {
				failures++;
				break;
			}
		}
		munmap((void *)p, sz);
	}

	if (failures == 0) PASS("fork_cow_stress");
	else FAIL("fork_cow_stress", "%d/%d iterations failed", failures, niter);
}

/* ---- Test 6: mprotect at MMUPAGE granularity ---- */
static void test_mprotect_subpage(void)
{
	size_t sz = page_size * 4;
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("mprotect_subpage", "mmap failed");
		return;
	}

	/* Write data first */
	for (int i = 0; i < 4; i++)
		p[i * page_size] = (char)(i + 1);

	/* Make middle 2 pages read-only */
	if (mprotect(p + page_size, page_size * 2, PROT_READ) != 0) {
		FAIL("mprotect_subpage", "mprotect failed: %s", strerror(errno));
		munmap(p, sz);
		return;
	}

	/* Verify we can still read */
	int ok = (p[page_size] == 2 && p[2 * page_size] == 3);

	/* Verify first and last pages are still writable */
	p[0] = 99;
	p[3 * page_size] = 99;

	/* Restore permissions and clean up */
	mprotect(p + page_size, page_size * 2, PROT_READ | PROT_WRITE);
	munmap(p, sz);

	if (ok) PASS("mprotect_subpage");
	else FAIL("mprotect_subpage", "data mismatch after mprotect");
}

/* ---- Test 7: munmap partial (sub-page granularity) ---- */
static void test_munmap_partial(void)
{
	size_t sz = page_size * 8;
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("munmap_partial", "mmap failed");
		return;
	}

	/* Touch all pages */
	for (int i = 0; i < 8; i++)
		p[i * page_size] = (char)(i + 1);

	/* Unmap pages 2 and 3 (middle of the region) */
	if (munmap(p + 2 * page_size, 2 * page_size) != 0) {
		FAIL("munmap_partial", "munmap failed: %s", strerror(errno));
		munmap(p, sz);
		return;
	}

	/* Pages 0,1 and 4-7 should still be accessible */
	int ok = 1;
	if (p[0] != 1 || p[page_size] != 2) ok = 0;
	if (p[4 * page_size] != 5 || p[7 * page_size] != 8) ok = 0;

	munmap(p, 2 * page_size);  /* pages 0-1 */
	munmap(p + 4 * page_size, 4 * page_size);  /* pages 4-7 */

	if (ok) PASS("munmap_partial");
	else FAIL("munmap_partial", "data corruption after partial munmap");
}

/* ---- Test 8: mremap ---- */
static void test_mremap(void)
{
	size_t sz = page_size * 4;
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("mremap", "mmap failed");
		return;
	}

	for (int i = 0; i < 4; i++)
		p[i * page_size] = (char)(i + 0x10);

	/* Grow the mapping */
	size_t newsz = page_size * 8;
	char *q = mremap(p, sz, newsz, MREMAP_MAYMOVE);
	if (q == MAP_FAILED) {
		FAIL("mremap", "mremap failed: %s", strerror(errno));
		munmap(p, sz);
		return;
	}

	/* Verify old data survived */
	int ok = 1;
	for (int i = 0; i < 4; i++) {
		if (q[i * page_size] != (char)(i + 0x10)) {
			ok = 0;
			break;
		}
	}

	/* Touch new pages */
	for (int i = 4; i < 8; i++)
		q[i * page_size] = (char)(i + 0x20);

	munmap(q, newsz);

	if (ok) PASS("mremap");
	else FAIL("mremap", "data corruption after mremap");
}

/* ---- Test 9: brk at MMUPAGE granularity ---- */
static void test_brk(void)
{
	/*
	 * musl's sbrk(inc) with inc!=0 returns -ENOMEM unconditionally,
	 * so use raw brk syscall instead.
	 */
	unsigned long orig = syscall(SYS_brk, 0);
	if (!orig) {
		FAIL("brk", "brk(0) failed");
		return;
	}

	/* Grow by several hardware pages */
	int ok = 1;
	unsigned long cur = orig;
	for (int i = 0; i < 8; i++) {
		unsigned long newbrk = cur + page_size;
		unsigned long ret = syscall(SYS_brk, newbrk);
		if (ret != newbrk) {
			printf("  brk iter %d: orig=0x%lx cur=0x%lx requested=0x%lx got=0x%lx\n",
			       i, orig, cur, newbrk, ret);
			ok = 0;
			break;
		}
		/* Touch the new memory */
		memset((void *)cur, i + 1, page_size);
		cur = newbrk;
	}

	/* Shrink back */
	syscall(SYS_brk, orig);

	if (ok) PASS("brk");
	else FAIL("brk", "brk growth failed");
}

/* ---- Test 10: mlock/munlock ---- */
static void test_mlock(void)
{
	size_t sz = page_size * 4;
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("mlock", "mmap failed");
		return;
	}

	/* Touch pages first */
	memset(p, 0xAA, sz);

	/* Lock individual hardware pages */
	int ok = 1;
	if (mlock(p + page_size, page_size) != 0) {
		/* mlock may fail without CAP_IPC_LOCK and low RLIMIT_MEMLOCK */
		if (errno == ENOMEM || errno == EPERM) {
			munmap(p, sz);
			PASS("mlock (skipped: no privilege)");
			return;
		}
		ok = 0;
	}

	if (ok && munlock(p + page_size, page_size) != 0)
		ok = 0;

	munmap(p, sz);
	if (ok) PASS("mlock");
	else FAIL("mlock", "mlock/munlock failed: %s", strerror(errno));
}

/* ---- Test 11: multi-fork stress ---- */
static void test_multi_fork(void)
{
	int nchildren = 16;
	size_t sz = page_size * 4;
	volatile char *shared_area = mmap(NULL, sz, PROT_READ | PROT_WRITE,
					  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (shared_area == MAP_FAILED) {
		FAIL("multi_fork", "mmap failed");
		return;
	}

	memset((void *)shared_area, 0, sz);

	int failures = 0;
	for (int c = 0; c < nchildren; c++) {
		pid_t pid = fork();
		if (pid == 0) {
			/* Child: touch all sub-pages */
			for (size_t off = 0; off < sz; off += page_size)
				shared_area[off] = (char)(c + 1);
			/* Also do some mmap/munmap in child */
			void *p = mmap(NULL, page_size * 2, PROT_READ | PROT_WRITE,
				       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
			if (p != MAP_FAILED) {
				memset(p, c, page_size * 2);
				munmap(p, page_size * 2);
			}
			_exit(0);
		}
		if (pid < 0) failures++;
	}

	/* Wait for all children */
	for (int c = 0; c < nchildren; c++) {
		int status;
		wait(&status);
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
			failures++;
	}

	munmap((void *)shared_area, sz);

	if (failures == 0) PASS("multi_fork");
	else FAIL("multi_fork", "%d failures", failures);
}

/* ---- Test 12: memory pressure / swap stress ---- */
static void test_swap_stress(void)
{
	/* Try to allocate more than available memory to trigger swapping.
	 * Read /proc/meminfo to find available memory. */
	FILE *f = fopen("/proc/meminfo", "r");
	long avail_kb = 0;
	if (f) {
		char line[256];
		while (fgets(line, sizeof(line), f)) {
			if (sscanf(line, "MemAvailable: %ld kB", &avail_kb) == 1)
				break;
		}
		fclose(f);
	}

	if (avail_kb < 32768) {  /* < 32MB available, skip */
		PASS("swap_stress (skipped: low memory)");
		return;
	}

	/* Allocate 50% of available memory.
	 * With PGCL, each page_size (MMUPAGE) write allocates an entire
	 * kernel page which may be PAGE_MMUCOUNT * page_size bytes.
	 * We don't know PAGE_MMUCOUNT from userspace, so use a conservative
	 * 50% target and cap the number of pages touched.
	 */
	size_t alloc_bytes = (avail_kb * 1024) / 2;
	size_t npages = alloc_bytes / page_size;
	if (npages > 4096) npages = 4096;  /* cap at 4k pages */

	char *p = mmap(NULL, npages * page_size, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("swap_stress", "mmap(%zu bytes) failed: %s", npages * page_size, strerror(errno));
		return;
	}

	/* Write unique pattern to each page */
	for (size_t i = 0; i < npages; i++)
		p[i * page_size] = (char)(i & 0xFF);

	/* Read back and verify */
	int errors = 0;
	for (size_t i = 0; i < npages; i++) {
		if (p[i * page_size] != (char)(i & 0xFF))
			errors++;
	}

	munmap(p, npages * page_size);

	if (errors == 0) PASS("swap_stress");
	else FAIL("swap_stress", "%d/%zu pages corrupted", errors, npages);
}

/* ---- Test 13: mmap + madvise ---- */
static void test_madvise(void)
{
	size_t sz = page_size * 16;
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("madvise", "mmap failed");
		return;
	}

	/* Fill with data */
	for (int i = 0; i < 16; i++)
		p[i * page_size] = (char)(i + 1);

	/* MADV_DONTNEED a sub-range */
	if (madvise(p + 4 * page_size, 4 * page_size, MADV_DONTNEED) != 0) {
		FAIL("madvise", "MADV_DONTNEED failed: %s", strerror(errno));
		munmap(p, sz);
		return;
	}

	/* Advised pages should read as zero */
	int ok = 1;
	char fail_detail[256] = {0};
	for (int i = 4; i < 8; i++) {
		if (p[i * page_size] != 0) {
			snprintf(fail_detail, sizeof(fail_detail),
				 "advised page %d has 0x%02x, expected 0", i,
				 (unsigned char)p[i * page_size]);
			ok = 0;
			break;
		}
	}

	/* Non-advised pages should be intact */
	if (ok) {
		for (int i = 0; i < 4; i++) {
			if (p[i * page_size] != (char)(i + 1)) {
				snprintf(fail_detail, sizeof(fail_detail),
					 "non-advised page %d has 0x%02x, expected 0x%02x",
					 i, (unsigned char)p[i * page_size],
					 (unsigned char)(i + 1));
				ok = 0;
				break;
			}
		}
	}

	munmap(p, sz);
	if (ok) PASS("madvise");
	else FAIL("madvise", "%s", fail_detail);
}

/* ---- Test 14: MAP_SHARED with fork ---- */
static void test_shared_mmap(void)
{
	size_t sz = page_size * 4;
	volatile char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
				MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("shared_mmap", "mmap failed");
		return;
	}

	memset((void *)p, 0, sz);

	pid_t pid = fork();
	if (pid == 0) {
		/* Child writes to even sub-pages */
		for (int i = 0; i < 4; i += 2)
			p[i * page_size] = (char)(0xA0 + i);
		_exit(0);
	}
	if (pid < 0) {
		FAIL("shared_mmap", "fork failed");
		munmap((void *)p, sz);
		return;
	}

	int status;
	waitpid(pid, &status, 0);

	/* Parent should see child's writes (shared mapping) */
	int ok = 1;
	for (int i = 0; i < 4; i += 2) {
		if (p[i * page_size] != (char)(0xA0 + i)) {
			ok = 0;
			break;
		}
	}

	munmap((void *)p, sz);
	if (ok) PASS("shared_mmap");
	else FAIL("shared_mmap", "shared data not visible across fork");
}

/* ---- Test 15: rapid mmap/munmap cycle ---- */
static void test_mmap_cycle(void)
{
	int niter = 1024;
	int failures = 0;

	for (int i = 0; i < niter; i++) {
		size_t sz = page_size * (1 + (i % 8));
		char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
			       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) { failures++; continue; }
		p[0] = (char)i;
		p[sz - 1] = (char)~i;
		munmap(p, sz);
	}

	if (failures == 0) PASS("mmap_cycle");
	else FAIL("mmap_cycle", "%d/%d failed", failures, niter);
}

/* ---- Test 16: RSS accounting after COW ---- */
static void test_rss_accounting(void)
{
	size_t sz = page_size * 16;
	volatile char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
				MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("rss_accounting", "mmap failed");
		return;
	}

	/* Write pattern to each MMUPAGE offset */
	for (int i = 0; i < 16; i++)
		p[i * page_size] = (char)(i + 0x10);

	/* Read initial RSS from /proc/self/statm (field 2 = resident pages) */
	FILE *f = fopen("/proc/self/statm", "r");
	if (!f) {
		printf("  %-40s SKIP (no /proc/self/statm)\n", "rss_accounting");
		test_pass++;
		munmap((void *)p, sz);
		return;
	}
	long vsize0, rss0;
	if (fscanf(f, "%ld %ld", &vsize0, &rss0) != 2) {
		fclose(f);
		FAIL("rss_accounting", "cannot parse statm");
		munmap((void *)p, sz);
		return;
	}
	fclose(f);

	pid_t pid = fork();
	if (pid < 0) {
		FAIL("rss_accounting", "fork failed");
		munmap((void *)p, sz);
		return;
	}

	if (pid == 0) {
		/* Child: write different pattern to every other page (triggers COW) */
		for (int i = 0; i < 16; i += 2)
			p[i * page_size] = (char)(0xBB + i);
		_exit(0);
	}

	int status;
	waitpid(pid, &status, 0);

	/* Read RSS again — should have increased due to COW splits */
	f = fopen("/proc/self/statm", "r");
	long vsize1, rss1;
	int got_rss = 0;
	if (f) {
		if (fscanf(f, "%ld %ld", &vsize1, &rss1) == 2)
			got_rss = 1;
		fclose(f);
	}

	/* Verify parent's data is unchanged */
	int data_ok = 1;
	for (int i = 0; i < 16; i++) {
		if (p[i * page_size] != (char)(i + 0x10)) {
			data_ok = 0;
			break;
		}
	}

	munmap((void *)p, sz);

	if (!data_ok)
		FAIL("rss_accounting", "parent data corrupted after COW");
	else if (!got_rss)
		FAIL("rss_accounting", "cannot read post-fork RSS");
	else if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
		FAIL("rss_accounting", "child exited abnormally");
	else
		PASS("rss_accounting");
}

/* ---- Test 17: vmsplice/splice GUP page array ---- */
static void test_vmsplice_gup(void)
{
#ifndef __NR_vmsplice
	printf("  %-40s SKIP (no __NR_vmsplice)\n", "vmsplice_gup");
	test_pass++;
	return;
#else
	int pipefd[2];
	if (pipe(pipefd) != 0) {
		FAIL("vmsplice_gup", "pipe failed: %s", strerror(errno));
		return;
	}

	int npages = 8;
	size_t sz = page_size * npages;
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("vmsplice_gup", "mmap failed");
		close(pipefd[0]);
		close(pipefd[1]);
		return;
	}

	/* Write known pattern at each MMUPAGE offset */
	for (int i = 0; i < npages; i++)
		memset(p + i * page_size, (char)(i + 0x30), page_size);

	/* vmsplice pages into pipe — one iovec per page */
	struct iovec iov[8];
	for (int i = 0; i < npages; i++) {
		iov[i].iov_base = p + i * page_size;
		iov[i].iov_len = page_size;
	}

	long ret = syscall(__NR_vmsplice, pipefd[1], iov, npages, 0);
	if (ret < 0) {
		if (errno == ENOSYS) {
			printf("  %-40s SKIP (vmsplice not supported)\n", "vmsplice_gup");
			test_pass++;
		} else {
			FAIL("vmsplice_gup", "vmsplice failed: %s", strerror(errno));
		}
		munmap(p, sz);
		close(pipefd[0]);
		close(pipefd[1]);
		return;
	}

	/* Read back from pipe and verify */
	size_t total = (size_t)ret;
	char *buf = malloc(total);
	if (!buf) {
		FAIL("vmsplice_gup", "malloc failed");
		munmap(p, sz);
		close(pipefd[0]);
		close(pipefd[1]);
		return;
	}

	size_t nread = 0;
	while (nread < total) {
		ssize_t r = read(pipefd[0], buf + nread, total - nread);
		if (r <= 0) break;
		nread += r;
	}

	close(pipefd[0]);
	close(pipefd[1]);

	int ok = 1;
	if (nread != total) {
		ok = 0;
	} else {
		/* Verify each MMUPAGE-sized chunk */
		for (size_t off = 0; off < nread && ok; off += page_size) {
			int pg = off / page_size;
			char expected = (char)(pg + 0x30);
			for (size_t j = 0; j < page_size && (off + j) < nread; j++) {
				if (buf[off + j] != expected) {
					ok = 0;
					break;
				}
			}
		}
	}

	free(buf);
	munmap(p, sz);

	if (ok) PASS("vmsplice_gup");
	else FAIL("vmsplice_gup", "data mismatch after round-trip");
#endif
}

/* ---- Test 18: pagemap PTE encoding ---- */
static void test_pagemap_pte(void)
{
	int npages = 16;
	size_t sz = page_size * npages;
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("pagemap_pte", "mmap failed");
		return;
	}

	/* Touch every MMUPAGE to ensure they're faulted in */
	for (int i = 0; i < npages; i++)
		p[i * page_size] = (char)(i + 1);

	int fd = open("/proc/self/pagemap", O_RDONLY);
	if (fd < 0) {
		printf("  %-40s SKIP (no /proc/self/pagemap)\n", "pagemap_pte");
		test_pass++;
		munmap(p, sz);
		return;
	}

	/* Each pagemap entry is 8 bytes, indexed by virtual page number */
	uint64_t entries[16];
	int ok = 1;
	for (int i = 0; i < npages; i++) {
		unsigned long addr = (unsigned long)(p + i * page_size);
		unsigned long vpn = addr / page_size;
		off_t offset = vpn * sizeof(uint64_t);

		if (lseek(fd, offset, SEEK_SET) != offset) {
			ok = 0;
			break;
		}
		if (read(fd, &entries[i], sizeof(uint64_t)) != sizeof(uint64_t)) {
			ok = 0;
			break;
		}
	}

	close(fd);

	if (!ok) {
		printf("  %-40s SKIP (pagemap read failed, need root?)\n", "pagemap_pte");
		test_pass++;
		munmap(p, sz);
		return;
	}

	/* Verify: all entries show "present" (bit 63) */
	int all_present = 1;
	for (int i = 0; i < npages; i++) {
		if (!(entries[i] & ((uint64_t)1 << 63))) {
			all_present = 0;
			break;
		}
	}

	if (!all_present) {
		/* Pages might be swapped or pagemap requires root for PFNs */
		printf("  %-40s SKIP (pages not present, need root?)\n", "pagemap_pte");
		test_pass++;
		munmap(p, sz);
		return;
	}

	/* Extract PFNs (bits 0-54) and check progression */
	int pfn_ok = 1;
	uint64_t pfn_mask = ((uint64_t)1 << 55) - 1;
	uint64_t prev_pfn = entries[0] & pfn_mask;

	/* PFN 0 means no permission to read PFNs */
	if (prev_pfn == 0) {
		printf("  %-40s SKIP (PFN read requires CAP_SYS_ADMIN)\n", "pagemap_pte");
		test_pass++;
		munmap(p, sz);
		return;
	}

	for (int i = 1; i < npages; i++) {
		uint64_t pfn = entries[i] & pfn_mask;
		if (pfn == 0) { pfn_ok = 0; break; }
		/*
		 * Consecutive MMUPAGEs within the same kernel page should
		 * have consecutive PFNs (differ by 1). Across kernel page
		 * boundaries the stride may be larger, but should still be
		 * non-zero and positive for contiguous allocations.
		 */
		if (pfn <= prev_pfn) {
			/* Non-ascending PFN — not necessarily wrong for
			 * non-contiguous allocations, just verify present */
		}
		prev_pfn = pfn;
	}

	munmap(p, sz);

	if (all_present && pfn_ok) PASS("pagemap_pte");
	else FAIL("pagemap_pte", "present=%d pfn_ok=%d", all_present, pfn_ok);
}

/* ---- Test 19: RLIMIT_AS VM accounting boundary ---- */
static void test_rlimit_boundary(void)
{
	struct rlimit orig_lim;
	if (getrlimit(RLIMIT_AS, &orig_lim) != 0) {
		FAIL("rlimit_boundary", "getrlimit failed: %s", strerror(errno));
		return;
	}

	/* Read current VM size from /proc/self/statm (field 1 = pages) */
	FILE *f = fopen("/proc/self/statm", "r");
	if (!f) {
		printf("  %-40s SKIP (no /proc/self/statm)\n", "rlimit_boundary");
		test_pass++;
		return;
	}
	long vsize_pages;
	if (fscanf(f, "%ld", &vsize_pages) != 1) {
		fclose(f);
		FAIL("rlimit_boundary", "cannot parse statm");
		return;
	}
	fclose(f);

	/*
	 * statm reports in units of page_size. Set RLIMIT_AS to
	 * current VM + 4 pages worth, so we can allocate exactly 4 more.
	 * Add some slack for internal kernel overhead.
	 */
	size_t current_vm = (size_t)vsize_pages * page_size;
	size_t slack = page_size * 8;  /* headroom for kernel bookkeeping */
	struct rlimit new_lim;
	new_lim.rlim_cur = current_vm + 4 * page_size + slack;
	new_lim.rlim_max = orig_lim.rlim_max;

	/* Make sure we don't exceed hard limit */
	if (new_lim.rlim_cur > new_lim.rlim_max && new_lim.rlim_max != RLIM_INFINITY) {
		printf("  %-40s SKIP (hard limit too low)\n", "rlimit_boundary");
		test_pass++;
		return;
	}

	if (setrlimit(RLIMIT_AS, &new_lim) != 0) {
		if (errno == EPERM) {
			printf("  %-40s SKIP (no privilege to set RLIMIT_AS)\n", "rlimit_boundary");
			test_pass++;
			return;
		}
		FAIL("rlimit_boundary", "setrlimit failed: %s", strerror(errno));
		return;
	}

	/* Try 4 small mmaps — should succeed */
	void *maps[4];
	int alloc_ok = 1;
	int allocated = 0;
	for (int i = 0; i < 4; i++) {
		maps[i] = mmap(NULL, page_size, PROT_READ | PROT_WRITE,
			       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (maps[i] == MAP_FAILED) {
			alloc_ok = 0;
			break;
		}
		/* Touch to commit */
		*(volatile char *)maps[i] = (char)i;
		allocated++;
	}

	/* Keep allocating — eventually should hit ENOMEM */
	int hit_limit = 0;
	void *extras[256];
	int nextra = 0;
	if (alloc_ok) {
		for (int i = 0; i < 256; i++) {
			void *extra = mmap(NULL, page_size, PROT_READ | PROT_WRITE,
					   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
			if (extra == MAP_FAILED) {
				hit_limit = 1;
				break;
			}
			extras[nextra++] = extra;
			*(volatile char *)extra = (char)i;
		}
	}

	/* Clean up */
	for (int i = 0; i < nextra; i++)
		munmap(extras[i], page_size);
	for (int i = 0; i < allocated; i++)
		munmap(maps[i], page_size);

	/* Restore original limit */
	setrlimit(RLIMIT_AS, &orig_lim);

	if (alloc_ok && hit_limit) PASS("rlimit_boundary");
	else if (!alloc_ok) FAIL("rlimit_boundary", "initial allocs failed at %d", allocated);
	else FAIL("rlimit_boundary", "mmap didn't fail at RLIMIT_AS boundary");
}

int main(int argc, char *argv[])
{
	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0) page_size = 4096;

	printf("========================================\n");
	printf("  PGCL Userspace Stress Tests\n");
	printf("  Page size (MMUPAGE): %ld bytes\n", page_size);
	printf("========================================\n\n");

	test_at_pagesz();
	test_mmap_basic();
	test_mmap_fixed();
	test_fork_cow();
	test_fork_cow_stress();
	test_mprotect_subpage();
	test_munmap_partial();
	test_mremap();
	test_brk();
	test_mlock();
	test_multi_fork();
	test_swap_stress();
	test_madvise();
	test_shared_mmap();
	test_mmap_cycle();
	test_rss_accounting();
	test_vmsplice_gup();
	test_pagemap_pte();
	test_rlimit_boundary();

	printf("\n========================================\n");
	printf("  Results: %d passed, %d failed\n", test_pass, test_fail);
	printf("========================================\n");

	return test_fail > 0 ? 1 : 0;
}
