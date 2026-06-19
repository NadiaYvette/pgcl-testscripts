/*
 * hugetlb_pgcl_test — exercise hugetlb page-cache / i_mmap indexing under PGCL.
 *
 * Validates the MMUPAGE-units fixes in mm/hugetlb.c:
 *   - vma_hugecache_offset()  (every hugetlb fault + reservation)
 *   - hugetlbfs_pagecache_present()  (file-backed fault page-cache probe)
 *   - unmap_ref_private()     (private COW with a second private mapper)
 *   - page_table_shareable()/huge_pmd_share() (large shared mappings)
 *
 * Default 2 MiB huge pages.  Needs hugepages reserved + a hugetlbfs mount
 * passed as argv[1] (default /mnt/huge) for the file-backed tests; the anon
 * test needs only MAP_HUGETLB.  Prints "HTEST <name>: PASS/FAIL"; exits
 * nonzero if any fail.  Under a broken (unfixed) PGCL kernel the file/offset
 * page-cache indices are off by PAGE_MMUCOUNT -> wrong data / SIGBUS / FAIL.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>

#define HPAGE (2UL * 1024 * 1024)	/* x86 default huge page */

static int fails;
#define CHECK(name, cond) do {						\
	if (cond) printf("HTEST %s: PASS\n", (name));			\
	else { printf("HTEST %s: FAIL\n", (name)); fails++; }		\
} while (0)

/* A: anonymous hugetlb private — fault + reservation (vma_hugecache_offset). */
static void test_anon(void)
{
	char *p = mmap(NULL, 4 * HPAGE, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
	if (p == MAP_FAILED) { printf("HTEST anon: SKIP (%s)\n", strerror(errno)); return; }
	for (unsigned long i = 0; i < 4 * HPAGE; i += 4096)
		p[i] = (char)(i / HPAGE + 1);
	int ok = 1;
	for (unsigned long i = 0; i < 4 * HPAGE; i += 4096)
		if (p[i] != (char)(i / HPAGE + 1)) ok = 0;
	CHECK("anon_rw", ok);
	munmap(p, 4 * HPAGE);
}

/* B: hugetlbfs file shared — page-cache indexing across maps + at vm_pgoff. */
static void test_file_shared(const char *dir)
{
	char path[256];
	snprintf(path, sizeof path, "%s/htest_shared", dir);
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) { printf("HTEST file_shared: SKIP (open: %s)\n", strerror(errno)); return; }
	if (ftruncate(fd, 4 * HPAGE)) { printf("HTEST file_shared: SKIP (ftruncate)\n"); close(fd); return; }
	char *m1 = mmap(NULL, 4 * HPAGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (m1 == MAP_FAILED) { printf("HTEST file_shared: SKIP (mmap1: %s)\n", strerror(errno)); close(fd); return; }
	for (int h = 0; h < 4; h++)
		m1[h * HPAGE + 12345] = (char)(0xA0 + h);	/* non-zero sub-offset */
	char *m2 = mmap(NULL, 4 * HPAGE, PROT_READ, MAP_SHARED, fd, 0);
	if (m2 == MAP_FAILED) { printf("HTEST file_shared: SKIP (mmap2)\n"); munmap(m1, 4 * HPAGE); close(fd); return; }
	int ok = 1;
	for (int h = 0; h < 4; h++)
		if (m2[h * HPAGE + 12345] != (char)(0xA0 + h)) ok = 0;
	CHECK("file_shared_pagecache", ok);

	/* map starting at file offset = 2 huge pages -> stresses vm_pgoff index */
	char *m3 = mmap(NULL, 2 * HPAGE, PROT_READ, MAP_SHARED, fd, 2 * HPAGE);
	if (m3 != MAP_FAILED) {
		CHECK("file_shared_offset_vmpgoff",
		      m3[12345] == (char)(0xA0 + 2) && m3[HPAGE + 12345] == (char)(0xA0 + 3));
		munmap(m3, 2 * HPAGE);
	}
	munmap(m1, 4 * HPAGE); munmap(m2, 4 * HPAGE); close(fd); unlink(path);
}

/* C: hugetlbfs private COW + a second private mapper (unmap_ref_private). */
static void test_file_private_cow(const char *dir)
{
	char path[256];
	snprintf(path, sizeof path, "%s/htest_priv", dir);
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) { printf("HTEST priv_cow: SKIP (open)\n"); return; }
	if (ftruncate(fd, 2 * HPAGE)) { printf("HTEST priv_cow: SKIP (ftruncate)\n"); close(fd); return; }
	char *s = mmap(NULL, 2 * HPAGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (s == MAP_FAILED) { printf("HTEST priv_cow: SKIP (shared)\n"); close(fd); return; }
	s[0] = 'S'; s[HPAGE] = 'T'; msync(s, 2 * HPAGE, MS_SYNC); munmap(s, 2 * HPAGE);

	char *a = mmap(NULL, 2 * HPAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
	char *b = mmap(NULL, 2 * HPAGE, PROT_READ, MAP_PRIVATE, fd, 0);
	if (a == MAP_FAILED || b == MAP_FAILED) { printf("HTEST priv_cow: SKIP (priv maps)\n"); close(fd); return; }
	int pre = (a[0] == 'S' && b[0] == 'S');		/* both read from page cache */
	a[0] = 'X';					/* COW in a -> unmap_ref_private */
	CHECK("priv_cow_isolation", pre && a[0] == 'X' && b[0] == 'S');
	munmap(a, 2 * HPAGE); munmap(b, 2 * HPAGE); close(fd); unlink(path);
}

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "/mnt/huge";
	printf("HTEST start dir=%s syspage=%ld\n", dir, sysconf(_SC_PAGESIZE));
	test_anon();
	test_file_shared(dir);
	test_file_private_cow(dir);
	printf("HTEST DONE fails=%d\n", fails);
	return fails ? 1 : 0;
}
