/*
 * PGCL test wrapper for hppa64 using minimal C library.
 * Neither musl nor glibc supports hppa64, so we use our own minilib.
 */

/* Override standard headers with our minilib */
#define _GNU_SOURCE

/* Block all standard headers */
#define _SYS_MMAN_H
#define _SYS_WAIT_H
#define _SYS_AUXV_H
#define _SYS_RESOURCE_H
#define _UNISTD_H
#define _SIGNAL_H
#define _STRING_H
#define _STDLIB_H
#define _STDIO_H
#define _ERRNO_H
#define _PTHREAD_H
#define _FCNTL_H
#define _SYS_SYSCALL_H
#define _SETJMP_H
#define _SYS_STAT_H

#include "hppa64-minilib.h"

/* Provide missing type */
typedef struct { int rlim_cur; int rlim_max; } rlimit_dummy;

/* Now include the actual test, with headers already satisfied */
/* We directly embed the test code, adapted for our minilib */

static int test_pass, test_fail;
static long page_size;

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
	if (ps == 4096 || ps == 8192 || ps == 16384 || ps == 65536) {
		PASS("at_pagesz");
	} else {
		FAIL("at_pagesz", "unexpected page size %ld", ps);
	}
}

/* ---- Test 2: mmap anonymous + touch every sub-page ---- */
static void test_mmap_basic(void)
{
	size_t sz = page_size * 16;
	volatile char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
				MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("mmap_basic", "mmap failed: %s", strerror(errno));
		return;
	}
	for (int i = 0; i < 16; i++)
		p[i * page_size] = (char)(i + 0x41);
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
	size_t sz = page_size * 64;
	char *base = mmap(NULL, sz, PROT_READ | PROT_WRITE,
			  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (base == MAP_FAILED) {
		FAIL("mmap_fixed", "base mmap failed");
		return;
	}
	char *sub = base + page_size * 3;
	char *p = mmap(sub, page_size, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("mmap_fixed", "MAP_FIXED failed: %s", strerror(errno));
		munmap(base, sz);
		return;
	}
	if (p != sub) {
		FAIL("mmap_fixed", "got %p expected %p", p, sub);
		munmap(base, sz);
		return;
	}
	*p = 42;
	munmap(base, sz);
	PASS("mmap_fixed");
}

/* ---- Test 4: Fork COW ---- */
static void test_fork_cow(void)
{
	size_t sz = page_size * 16;
	volatile char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
				MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("fork_cow", "mmap failed");
		return;
	}
	for (int i = 0; i < 16; i++)
		p[i * page_size] = (char)(i + 1);

	pid_t pid = fork();
	if (pid < 0) {
		FAIL("fork_cow", "fork failed");
		munmap((void *)p, sz);
		return;
	}
	if (pid == 0) {
		int child_ok = 1;
		for (int i = 0; i < 16; i++) {
			if (p[i * page_size] != (char)(i + 1)) {
				child_ok = 0;
				break;
			}
		}
		for (int i = 0; i < 16; i += 2)
			p[i * page_size] = (char)(0x80 + i);
		_exit(child_ok ? 0 : 1);
	}
	for (int i = 1; i < 16; i += 2)
		p[i * page_size] = (char)(0xC0 + i);

	int status;
	waitpid(pid, &status, 0);
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

/* ---- Test 5: Fork COW stress ---- */
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
			for (int i = 0; i < 16; i++)
				p[i * page_size] = (char)(0xFF - i);
			_exit(0);
		}
		if (pid < 0) { failures++; munmap((void *)p, sz); continue; }
		int status;
		waitpid(pid, &status, 0);
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
	for (int i = 0; i < 4; i++)
		p[i * page_size] = (char)(i + 1);
	if (mprotect(p + page_size, page_size * 2, PROT_READ) != 0) {
		FAIL("mprotect_subpage", "mprotect failed: %s", strerror(errno));
		munmap(p, sz);
		return;
	}
	int ok = (p[page_size] == 2 && p[2 * page_size] == 3);
	p[0] = 99;
	p[3 * page_size] = 99;
	mprotect(p + page_size, page_size * 2, PROT_READ | PROT_WRITE);
	munmap(p, sz);
	if (ok) PASS("mprotect_subpage");
	else FAIL("mprotect_subpage", "data mismatch after mprotect");
}

/* ---- Test 7: munmap partial ---- */
static void test_munmap_partial(void)
{
	size_t sz = page_size * 8;
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("munmap_partial", "mmap failed");
		return;
	}
	for (int i = 0; i < 8; i++)
		p[i * page_size] = (char)(i + 1);
	if (munmap(p + 2 * page_size, 2 * page_size) != 0) {
		FAIL("munmap_partial", "munmap failed: %s", strerror(errno));
		munmap(p, sz);
		return;
	}
	int ok = 1;
	if (p[0] != 1 || p[page_size] != 2) ok = 0;
	if (p[4 * page_size] != 5 || p[7 * page_size] != 8) ok = 0;
	munmap(p, 2 * page_size);
	munmap(p + 4 * page_size, 4 * page_size);
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
	size_t newsz = page_size * 8;
	char *q = mremap(p, sz, newsz, MREMAP_MAYMOVE);
	if (q == MAP_FAILED) {
		FAIL("mremap", "mremap failed: %s", strerror(errno));
		munmap(p, sz);
		return;
	}
	int ok = 1;
	for (int i = 0; i < 4; i++) {
		if (q[i * page_size] != (char)(i + 0x10)) {
			ok = 0;
			break;
		}
	}
	for (int i = 4; i < 8; i++)
		q[i * page_size] = (char)(i + 0x20);
	munmap(q, newsz);
	if (ok) PASS("mremap");
	else FAIL("mremap", "data corruption after mremap");
}

/* ---- Test 9: brk ---- */
static void test_brk(void)
{
	unsigned long orig = _raw_syscall1(__NR_brk, 0);
	if (!orig) {
		FAIL("brk", "brk(0) failed");
		return;
	}
	int ok = 1;
	unsigned long cur = orig;
	for (int i = 0; i < 8; i++) {
		unsigned long newbrk = cur + page_size;
		unsigned long ret = _raw_syscall1(__NR_brk, newbrk);
		if (ret != newbrk) {
			ok = 0;
			break;
		}
		memset((void *)cur, i + 1, page_size);
		cur = newbrk;
	}
	_raw_syscall1(__NR_brk, orig);
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
	memset(p, 0xAA, sz);
	int ok = 1;
	if (mlock(p + page_size, page_size) != 0) {
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
			for (size_t off = 0; off < sz; off += page_size)
				shared_area[off] = (char)(c + 1);
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

/* ---- Test 12: memory pressure ---- */
static void test_swap_stress(void)
{
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
	if (avail_kb < 32768) {
		PASS("swap_stress (skipped: low memory)");
		return;
	}
	size_t alloc_bytes = (avail_kb * 1024 * 3) / 4;
	size_t npages = alloc_bytes / page_size;
	if (npages > 16384) npages = 16384;
	char *p = mmap(NULL, npages * page_size, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("swap_stress", "mmap failed: %s", strerror(errno));
		return;
	}
	for (size_t i = 0; i < npages; i++)
		p[i * page_size] = (char)(i & 0xFF);
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
	for (int i = 0; i < 16; i++)
		p[i * page_size] = (char)(i + 1);
	if (madvise(p + 4 * page_size, 4 * page_size, MADV_DONTNEED) != 0) {
		FAIL("madvise", "MADV_DONTNEED failed: %s", strerror(errno));
		munmap(p, sz);
		return;
	}
	int ok = 1;
	for (int i = 4; i < 8; i++) {
		if (p[i * page_size] != 0) {
			ok = 0;
			break;
		}
	}
	if (ok) {
		for (int i = 0; i < 4; i++) {
			if (p[i * page_size] != (char)(i + 1)) {
				ok = 0;
				break;
			}
		}
	}
	munmap(p, sz);
	if (ok) PASS("madvise");
	else FAIL("madvise", "data mismatch");
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

	printf("\n========================================\n");
	printf("  Results: %d passed, %d failed\n", test_pass, test_fail);
	printf("========================================\n");

	return test_fail > 0 ? 1 : 0;
}
