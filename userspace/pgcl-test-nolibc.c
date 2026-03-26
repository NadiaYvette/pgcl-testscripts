/*
 * PGCL Stress Tests — nolibc version for architectures without musl support
 * (alpha, sparc64, hppa, xtensa)
 *
 * Uses Linux kernel's tools/include/nolibc/ headers.
 * Compile: $CC -static -O2 -nostdlib -nostdinc \
 *   -isystem $LINUX/tools/include/nolibc \
 *   -include nolibc.h -o pgcl-test-nolibc pgcl-test-nolibc.c -lgcc
 */

#ifndef NOLIBC
#define _GNU_SOURCE
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#endif

/* nolibc may not provide mprotect — declare via raw syscall */
#ifdef NOLIBC
#include <linux/mman.h>
#ifndef __NR_mprotect
#include <asm/unistd.h>
#endif
static int my_mprotect(void *addr, unsigned long len, int prot)
{
	return (int)my_syscall3(__NR_mprotect, addr, len, prot);
}
#else
#define my_mprotect mprotect
#endif

static int test_pass, test_fail;
static volatile long page_size;

static void print_str(const char *s)
{
	int len = 0;
	while (s[len]) len++;
	write(1, s, len);
}

static void print_num(long n)
{
	char buf[24];
	int i = 0, neg = 0;
	if (n < 0) { neg = 1; n = -n; }
	if (n == 0) { buf[i++] = '0'; }
	else { while (n > 0) { buf[i++] = '0' + (n % 10); n /= 10; } }
	if (neg) buf[i++] = '-';
	/* reverse */
	char out[24];
	int j;
	for (j = 0; j < i; j++) out[j] = buf[i - 1 - j];
	out[i] = 0;
	print_str(out);
}

static void result(const char *name, int pass, const char *msg)
{
	print_str("  ");
	print_str(name);
	/* pad to ~42 chars */
	int len = 0;
	while (name[len]) len++;
	while (len < 40) { print_str(" "); len++; }
	if (pass) {
		print_str("PASS\n");
		test_pass++;
	} else {
		print_str("FAIL");
		if (msg) { print_str(": "); print_str(msg); }
		print_str("\n");
		test_fail++;
	}
}

/* Test 1: page size is a known hardware page size */
static void test_at_pagesz(void)
{
	long ps = page_size;
	if (ps == 4096 || ps == 8192 || ps == 16384 || ps == 65536)
		result("at_pagesz", 1, 0);
	else
		result("at_pagesz", 0, "unexpected page size");
}

/* Test 2: mmap anonymous + touch every sub-page */
static void test_mmap_basic(void)
{
	long sz = page_size * 16;
	volatile char *p = (volatile char *)mmap(0, sz,
		PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) { result("mmap_basic", 0, "mmap failed"); return; }

	int i;
	for (i = 0; i < 16; i++)
		p[i * page_size] = (char)(i + 0x41);

	int ok = 1;
	for (i = 0; i < 16; i++)
		if (p[i * page_size] != (char)(i + 0x41)) { ok = 0; break; }

	munmap((void *)p, sz);
	result("mmap_basic", ok, "data corruption");
}

/* Test 2b: sub-page identity — verify each sub-page is distinct */
static void test_subpage_identity(void)
{
	long sz = page_size * 16;
	volatile char *p = (volatile char *)mmap(0, sz,
		PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) { result("subpage_identity", 0, "mmap failed"); return; }

	/* Write unique value to each sub-page */
	int i;
	for (i = 0; i < 16; i++)
		p[i * page_size] = (char)(0x40 + i);

	/* Read back and verify each is distinct */
	int ok = 1;
	for (i = 0; i < 16; i++) {
		if (p[i * page_size] != (char)(0x40 + i)) {
			print_str("    subpage[");
			print_num(i);
			print_str("] got=");
			print_num((unsigned char)p[i * page_size]);
			print_str(" exp=");
			print_num((unsigned char)(char)(0x40 + i));
			print_str("\n");
			ok = 0;
		}
	}

	munmap((void *)p, sz);
	result("subpage_identity", ok, "sub-pages alias");
}

/* Test 3: MAP_FIXED */
static void test_mmap_fixed(void)
{
	long sz = page_size * 64;
	char *base = (char *)mmap(0, sz, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (base == MAP_FAILED) { result("mmap_fixed", 0, "base mmap failed"); return; }

	char *sub = base + page_size * 3;
	char *p = (char *)mmap(sub, page_size, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
	if (p != sub) { result("mmap_fixed", 0, "address mismatch"); munmap(base, sz); return; }

	*p = 42;
	munmap(base, sz);
	result("mmap_fixed", 1, 0);
}

/* Test 4: Fork COW */
static void test_fork_cow(void)
{
	long sz = page_size * 16;
	volatile char *p = (volatile char *)mmap(0, sz,
		PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) { result("fork_cow", 0, "mmap failed"); return; }

	int i;
	for (i = 0; i < 16; i++)
		p[i * page_size] = (char)(i + 1);

	pid_t pid = fork();
	if (pid < 0) { result("fork_cow", 0, "fork failed"); munmap((void *)p, sz); return; }

	if (pid == 0) {
		/* Child: verify, then write even sub-pages */
		int child_ok = 1;
		for (i = 0; i < 16; i++)
			if (p[i * page_size] != (char)(i + 1)) { child_ok = 0; break; }
		for (i = 0; i < 16; i += 2)
			p[i * page_size] = (char)(0x80 + i);
		_exit(child_ok ? 0 : 1);
	}

	/* Parent: write odd sub-pages */
	for (i = 1; i < 16; i += 2)
		p[i * page_size] = (char)(0xC0 + i);

	int status = 0;
	waitpid(pid, &status, 0);

	int parent_ok = 1;
	for (i = 1; i < 16; i += 2)
		if (p[i * page_size] != (char)(0xC0 + i)) { parent_ok = 0; break; }

	munmap((void *)p, sz);
	int ok = (status == 0 || (WIFEXITED(status) && WEXITSTATUS(status) == 0)) && parent_ok;
	result("fork_cow", ok, "COW isolation failure");
}

/* Test 5: Fork COW stress */
static void test_fork_cow_stress(void)
{
	int niter = 16, failures = 0;
	int iter, i;

	for (iter = 0; iter < niter; iter++) {
		long sz = page_size * 16;
		volatile char *p = (volatile char *)mmap(0, sz,
			PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) {
			print_str("    MMAP_FAIL iter=");
			print_num(iter);
			print_str(" errno=");
			print_num(errno);
			print_str(" sz=");
			print_num(sz);
			print_str("\n");
			failures++;
			continue;
		}

		for (i = 0; i < 16; i++)
			p[i * page_size] = (char)(iter + i);

		/* Pre-fork verification */
		for (i = 0; i < 16; i++) {
			if (p[i * page_size] != (char)(iter + i)) {
				print_str("    PRE-FORK: iter=");
				print_num(iter);
				print_str(" i=");
				print_num(i);
				print_str(" got=");
				print_num((unsigned char)p[i * page_size]);
				print_str(" exp=");
				print_num((unsigned char)(char)(iter + i));
				print_str("\n");
				failures++;
			}
		}

		pid_t pid = fork();
		if (pid == 0) {
			for (i = 0; i < 16; i++)
				p[i * page_size] = (char)(0xFF - i);
			_exit(0);
		}
		if (pid < 0) {
			print_str("    FORK_FAIL iter=");
			print_num(iter);
			print_str("\n");
			failures++;
			munmap((void *)p, sz);
			continue;
		}

		int status = 0;
		waitpid(pid, &status, 0);

		for (i = 0; i < 16; i++) {
			char got = p[i * page_size];
			char exp = (char)(iter + i);
			if (got != exp) {
				print_str("    POST-FORK: iter=");
				print_num(iter);
				print_str(" i=");
				print_num(i);
				print_str(" got=");
				print_num((unsigned char)got);
				print_str(" exp=");
				print_num((unsigned char)exp);
				print_str("\n");
				failures++;
			}
		}
		munmap((void *)p, sz);
	}
	result("fork_cow_stress", failures == 0, "iterations failed");
}

/* Test 6: mprotect */
static void test_mprotect_subpage(void)
{
	long sz = page_size * 4;
	char *p = (char *)mmap(0, sz, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) { result("mprotect_subpage", 0, "mmap failed"); return; }

	int i;
	for (i = 0; i < 4; i++)
		p[i * page_size] = (char)(i + 1);

	if (my_mprotect(p + page_size, page_size * 2, PROT_READ) != 0) {
		result("mprotect_subpage", 0, "mprotect failed");
		munmap(p, sz); return;
	}

	int ok = (p[page_size] == 2 && p[2 * page_size] == 3);
	p[0] = 99;
	p[3 * page_size] = 99;
	my_mprotect(p + page_size, page_size * 2, PROT_READ | PROT_WRITE);
	munmap(p, sz);
	result("mprotect_subpage", ok, "data mismatch");
}

/* Test 7: partial munmap */
static void test_munmap_partial(void)
{
	long sz = page_size * 8;
	char *p = (char *)mmap(0, sz, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) { result("munmap_partial", 0, "mmap failed"); return; }

	int i;
	for (i = 0; i < 8; i++)
		p[i * page_size] = (char)(i + 1);

	munmap(p + 2 * page_size, 2 * page_size);

	int ok = (p[0] == 1 && p[page_size] == 2 &&
		  p[4 * page_size] == 5 && p[7 * page_size] == 8);
	munmap(p, 2 * page_size);
	munmap(p + 4 * page_size, 4 * page_size);
	result("munmap_partial", ok, "data corruption");
}

/* Test 8: mremap */
static void test_mremap(void)
{
	long sz = page_size * 4;
	char *p = (char *)mmap(0, sz, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) { result("mremap", 0, "mmap failed"); return; }

	int i;
	for (i = 0; i < 4; i++)
		p[i * page_size] = (char)(i + 0x10);

	long newsz = page_size * 8;
	char *q = (char *)mremap(p, sz, newsz, 1 /* MREMAP_MAYMOVE */, 0);
	if (q == MAP_FAILED) { result("mremap", 0, "mremap failed"); munmap(p, sz); return; }

	int ok = 1;
	for (i = 0; i < 4; i++)
		if (q[i * page_size] != (char)(i + 0x10)) { ok = 0; break; }

	munmap(q, newsz);
	result("mremap", ok, "data corruption");
}

/* Test 9: brk (raw syscall) */
static void test_brk(void)
{
	unsigned long orig = (unsigned long)my_syscall1(__NR_brk, 0);
	if (orig == 0) { result("brk", 0, "brk(0) failed"); return; }

	int ok = 1, i;
	for (i = 0; i < 8; i++) {
		unsigned long newbrk = orig + (i + 1) * page_size;
		unsigned long ret = (unsigned long)my_syscall1(__NR_brk, newbrk);
		if (ret != newbrk) { ok = 0; break; }
		/* Touch the new page */
		*(volatile char *)(orig + i * page_size) = (char)(i + 1);
	}
	my_syscall1(__NR_brk, orig);
	result("brk", ok, "brk growth failed");
}

/* Test 10: multi-fork */
static void test_multi_fork(void)
{
	int nchildren = 8, failures = 0, c;
	for (c = 0; c < nchildren; c++) {
		pid_t pid = fork();
		if (pid == 0) {
			void *p = mmap(0, page_size * 2, PROT_READ | PROT_WRITE,
				MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
			if (p != MAP_FAILED) {
				*(volatile char *)p = (char)c;
				munmap(p, page_size * 2);
			}
			_exit(0);
		}
		if (pid < 0) failures++;
	}
	for (c = 0; c < nchildren; c++) {
		int status = 0;
		wait(&status);
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) failures++;
	}
	result("multi_fork", failures == 0, "child failures");
}

/* Test 11: MAP_SHARED with fork */
static void test_shared_mmap(void)
{
	long sz = page_size * 4;
	volatile char *p = (volatile char *)mmap(0, sz,
		PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) { result("shared_mmap", 0, "mmap failed"); return; }

	int i;
	for (i = 0; i < 4; i++) p[i * page_size] = 0;

	pid_t pid = fork();
	if (pid == 0) {
		for (i = 0; i < 4; i += 2)
			p[i * page_size] = (char)(0xA0 + i);
		_exit(0);
	}
	if (pid < 0) { result("shared_mmap", 0, "fork failed"); munmap((void *)p, sz); return; }

	int status = 0;
	waitpid(pid, &status, 0);

	int ok = 1;
	for (i = 0; i < 4; i += 2)
		if (p[i * page_size] != (char)(0xA0 + i)) { ok = 0; break; }

	munmap((void *)p, sz);
	result("shared_mmap", ok, "shared data not visible");
}

/* Test 12: rapid mmap/munmap cycle */
static void test_mmap_cycle(void)
{
	int niter = 256, failures = 0, i;
	for (i = 0; i < niter; i++) {
		long sz = page_size * (1 + (i % 8));
		char *p = (char *)mmap(0, sz, PROT_READ | PROT_WRITE,
			MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) { failures++; continue; }
		p[0] = (char)i;
		p[sz - 1] = (char)~i;
		munmap(p, sz);
	}
	result("mmap_cycle", failures == 0, "mmap failures");
}

int main(void)
{
	page_size = getpagesize();
	if (page_size <= 0) page_size = 4096;

	print_str("========================================\n");
	print_str("  PGCL Stress Tests (nolibc)\n");
	print_str("  Page size (MMUPAGE): ");
	print_num(page_size);
	print_str(" bytes\n");
	print_str("========================================\n\n");

	test_at_pagesz();
	test_mmap_basic();
	test_subpage_identity();
	test_mmap_fixed();
	test_fork_cow();
	test_fork_cow_stress();
	test_mprotect_subpage();
	test_munmap_partial();
	test_mremap();
	test_brk();
	test_multi_fork();
	test_shared_mmap();
	test_mmap_cycle();

	print_str("\n========================================\n");
	print_str("  Results: ");
	print_num(test_pass);
	print_str(" passed, ");
	print_num(test_fail);
	print_str(" failed\n");
	print_str("========================================\n");

	return test_fail > 0 ? 1 : 0;
}

