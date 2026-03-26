/*
 * PGCL stress test wrapper for hppa64 using minimal C library.
 */

#define _GNU_SOURCE
#define _SYS_MMAN_H
#define _SYS_WAIT_H
#define _SYS_AUXV_H
#define _SYS_RESOURCE_H
#define _SYS_STAT_H
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

#include "hppa64-minilib.h"

static int test_pass, test_fail;
static long page_size;

#define PASS(name) do { printf("  %-40s PASS\n", name); test_pass++; } while(0)
#define FAIL(name, ...) do { printf("  %-40s FAIL: ", name); printf(__VA_ARGS__); printf("\n"); test_fail++; } while(0)
#define SKIP(name, ...) do { printf("  %-40s SKIP: ", name); printf(__VA_ARGS__); printf("\n"); } while(0)

/* ---- Test 1: Multi-threaded mmap/munmap/fault race ---- */
/* Using fork instead of pthreads since we have no real thread support */

#define MT_THREADS 8
#define MT_ITERS   500

static void *mt_mmap_worker(void *arg)
{
	long tid = (long)arg;
	(void)tid;
	for (int i = 0; i < MT_ITERS; i++) {
		size_t sz = page_size * (4 + (i % 12));
		volatile char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
					MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED)
			continue;
		for (size_t off = 0; off < sz; off += page_size)
			p[off] = (char)(i + off);
		for (size_t off = 0; off < sz; off += page_size) {
			if (p[off] != (char)(i + off))
				return (void *)1;
		}
		munmap((void *)p, sz);
	}
	return NULL;
}

static void test_multithread_mmap(void)
{
	pthread_t threads[MT_THREADS];
	int err = 0;
	for (long i = 0; i < MT_THREADS; i++) {
		if (pthread_create(&threads[i], NULL, mt_mmap_worker, (void *)i) != 0) {
			FAIL("multithread_mmap", "pthread_create failed");
			return;
		}
	}
	for (int i = 0; i < MT_THREADS; i++) {
		void *ret;
		pthread_join(threads[i], &ret);
		if (ret != NULL)
			err++;
	}
	if (err == 0)
		PASS("multithread_mmap");
	else
		FAIL("multithread_mmap", "%d threads saw corruption", err);
}

/* ---- Test 2: Fork + COW + mprotect race ---- */
static void test_cow_mprotect_race(void)
{
	size_t sz = page_size * 32;
	volatile char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
				MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("cow_mprotect_race", "mmap failed");
		return;
	}
	for (size_t off = 0; off < sz; off += page_size)
		p[off] = (char)(off / page_size + 1);
	int failures = 0;
	for (int iter = 0; iter < 20; iter++) {
		pid_t pid = fork();
		if (pid < 0) { failures++; continue; }
		if (pid == 0) {
			for (size_t off = 0; off < sz; off += page_size)
				p[off] = (char)(0xC0 + iter);
			int child_ok = 1;
			for (size_t off = 0; off < sz; off += page_size) {
				if (p[off] != (char)(0xC0 + iter)) {
					child_ok = 0;
					break;
				}
			}
			_exit(child_ok ? 0 : 1);
		}
		for (int j = 0; j < 10; j++) {
			mprotect((void *)p, sz, PROT_READ);
			mprotect((void *)p, sz, PROT_READ | PROT_WRITE);
		}
		int status;
		waitpid(pid, &status, 0);
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
			failures++;
		for (size_t off = 0; off < sz; off += page_size) {
			if (p[off] != (char)(off / page_size + 1)) {
				failures++;
				break;
			}
		}
	}
	munmap((void *)p, sz);
	if (failures == 0)
		PASS("cow_mprotect_race");
	else
		FAIL("cow_mprotect_race", "%d failures in 20 iterations", failures);
}

/* ---- Test 3: mremap across kernel page boundary ---- */
static void test_mremap_cross_page(void)
{
	size_t sz = page_size * 15;
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("mremap_cross_page", "mmap failed");
		return;
	}
	for (int i = 0; i < 15; i++)
		p[i * page_size] = (char)(i + 0x30);
	size_t newsz = page_size * 33;
	char *q = mremap(p, sz, newsz, MREMAP_MAYMOVE);
	if (q == MAP_FAILED) {
		FAIL("mremap_cross_page", "mremap failed: %s", strerror(errno));
		munmap(p, sz);
		return;
	}
	int ok = 1;
	for (int i = 0; i < 15; i++) {
		if (q[i * page_size] != (char)(i + 0x30)) {
			ok = 0;
			break;
		}
	}
	for (int i = 15; i < 33; i++)
		q[i * page_size] = (char)(i + 0x40);
	if (ok) {
		for (int i = 15; i < 33; i++) {
			if (q[i * page_size] != (char)(i + 0x40)) {
				ok = 0;
				break;
			}
		}
	}
	munmap(q, newsz);
	if (ok)
		PASS("mremap_cross_page");
	else
		FAIL("mremap_cross_page", "data corruption across kernel page boundary");
}

/* ---- Test 4: SIGSEGV si_addr accuracy ---- */
static void test_signal_on_fault(void)
{
	/* sigsetjmp/siglongjmp not properly implemented for hppa64 minilib */
	SKIP("signal_on_fault", "sigsetjmp unavailable in minilib");
}

/* ---- Test 5: Swap-out/swap-in data verification ---- */
static void test_swap_verify(void)
{
	size_t npages = 256;
	size_t sz = npages * page_size;
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("swap_verify", "mmap failed");
		return;
	}
	for (size_t i = 0; i < npages; i++) {
		char *pg = p + i * page_size;
		memset(pg, (char)(i & 0xFF), page_size);
		pg[0] = (char)((i >> 0) & 0xFF);
		pg[1] = (char)((i >> 8) & 0xFF);
		pg[2] = (char)(0xAA);
		pg[3] = (char)(0x55);
	}
	madvise(p, sz, MADV_PAGEOUT);
	int errors = 0;
	for (size_t i = 0; i < npages; i++) {
		char *pg = p + i * page_size;
		if (pg[0] != (char)((i >> 0) & 0xFF) ||
		    pg[1] != (char)((i >> 8) & 0xFF) ||
		    pg[2] != (char)(0xAA) ||
		    pg[3] != (char)(0x55)) {
			errors++;
		}
	}
	munmap(p, sz);
	if (errors == 0)
		PASS("swap_verify");
	else
		FAIL("swap_verify", "%d/%zu pages corrupted after pageout", errors, npages);
}

/* ---- Test 6: File-backed mmap + msync + read verification ---- */
static void test_file_backed_mmap(void)
{
	int fd = open("/tmp/pgcl-stress-testfile", O_CREAT | O_RDWR | O_TRUNC);
	if (fd < 0) {
		SKIP("file_backed_mmap", "open failed: %s", strerror(errno));
		return;
	}
	size_t sz = page_size * 8;
	if (ftruncate(fd, sz) != 0) {
		FAIL("file_backed_mmap", "ftruncate failed: %s", strerror(errno));
		close(fd);
		unlink("/tmp/pgcl-stress-testfile");
		return;
	}
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		FAIL("file_backed_mmap", "mmap failed: %s", strerror(errno));
		close(fd);
		unlink("/tmp/pgcl-stress-testfile");
		return;
	}
	for (int i = 0; i < 8; i++)
		memset(p + i * page_size, (char)(i + 0x30), page_size);
	if (msync(p, sz, MS_SYNC) != 0) {
		FAIL("file_backed_mmap", "msync failed: %s", strerror(errno));
		munmap(p, sz);
		close(fd);
		unlink("/tmp/pgcl-stress-testfile");
		return;
	}
	munmap(p, sz);
	lseek(fd, 0, SEEK_SET);
	char *buf = malloc(sz);
	if (!buf) {
		FAIL("file_backed_mmap", "malloc failed");
		close(fd);
		unlink("/tmp/pgcl-stress-testfile");
		return;
	}
	ssize_t got = 0;
	while (got < (ssize_t)sz) {
		ssize_t r = read(fd, buf + got, sz - got);
		if (r <= 0) break;
		got += r;
	}
	int ok = (got == (ssize_t)sz);
	if (ok) {
		for (int i = 0; i < 8 && ok; i++) {
			for (size_t j = 0; j < (size_t)page_size && ok; j++) {
				if (buf[i * page_size + j] != (char)(i + 0x30))
					ok = 0;
			}
		}
	}
	free(buf);
	close(fd);
	unlink("/tmp/pgcl-stress-testfile");
	if (ok)
		PASS("file_backed_mmap");
	else
		FAIL("file_backed_mmap", "data mismatch between mmap write and read()");
}

/* ---- Test 7: Large alignment mmap ---- */
static void test_large_alignment(void)
{
	int ok = 1;
	for (int trial = 0; trial < 32; trial++) {
		size_t sz = page_size * (1 + trial);
		char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
			       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) continue;
		if ((unsigned long)p % page_size != 0) {
			ok = 0;
			munmap(p, sz);
			break;
		}
		p[0] = 'A';
		p[sz - 1] = 'Z';
		munmap(p, sz);
	}
	if (ok)
		PASS("large_alignment");
	else
		FAIL("large_alignment", "mmap returned misaligned address");
}

/* ---- Test 8: mincore at MMUPAGE granularity ---- */
static void test_mincore(void)
{
	size_t npages = 16;
	size_t sz = npages * page_size;
	char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		FAIL("mincore", "mmap failed");
		return;
	}
	for (size_t i = 0; i < npages; i += 2)
		p[i * page_size] = (char)i;
	unsigned char *vec = malloc(npages);
	if (!vec) {
		munmap(p, sz);
		FAIL("mincore", "malloc failed");
		return;
	}
	if (mincore(p, sz, vec) != 0) {
		SKIP("mincore", "not supported: %s", strerror(errno));
		free(vec);
		munmap(p, sz);
		return;
	}
	int ok = 1;
	for (size_t i = 0; i < npages; i += 2) {
		if (!(vec[i] & 1)) {
			ok = 0;
			break;
		}
	}
	free(vec);
	munmap(p, sz);
	if (ok)
		PASS("mincore");
	else
		FAIL("mincore", "faulted pages not reported as resident");
}

int main(int argc, char *argv[])
{
	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0) page_size = 4096;

	printf("========================================\n");
	printf("  PGCL Extended Stress Tests\n");
	printf("  Page size (MMUPAGE): %ld bytes\n", page_size);
	printf("========================================\n\n");

	test_multithread_mmap();
	test_cow_mprotect_race();
	test_mremap_cross_page();
	test_signal_on_fault();
	test_swap_verify();
	test_file_backed_mmap();
	test_large_alignment();
	test_mincore();

	printf("\n========================================\n");
	printf("  Results: %d passed, %d failed\n", test_pass, test_fail);
	printf("========================================\n");

	return test_fail > 0 ? 1 : 0;
}
