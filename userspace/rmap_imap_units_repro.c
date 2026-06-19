/*
 * rmap_imap_units_repro — reproduce the PGCL i_mmap interval-tree unit bug
 * (kernel BUG at mm/rmap.c:3307, VM_BUG_ON_VMA(address == -EFAULT)).
 *
 * Root cause: the i_mmap interval tree is keyed in MMUPAGE units (vm_pgoff,
 * vma_pages()), but __rmap_walk_file() queried it with a folio's PAGE-cluster
 * index.  A low cluster index then spuriously falls inside the MMUPAGE key
 * range of a *different*, lower VMA that does not actually map the folio;
 * vma_address() converts the cluster index to MMUPAGE, lands past that VMA,
 * returns -EFAULT, and BUGs.
 *
 * Trigger (mirrors journald's punch-hole on a btrfs journal file):
 *   - window A: shared mmap of file bytes [0, 8 MiB)         -> i_mmap key [0, 0x7ff] (MMUPAGE)
 *   - window B: shared mmap of one cluster at file off 12 MiB (cluster 0xbd)
 *               -> the folio there is *mapped*, so writeback runs folio_mkclean
 *   - dirty B, then fsync()/fallocate(PUNCH_HOLE) the high cluster
 *       writeback -> folio_mkclean(folio@cluster 0xbd) -> __rmap_walk_file
 *       query(cluster 0xbd) matches window A's MMUPAGE range [0,0x7ff] (BUG)
 *       instead of window B's [0xbd0,0xbdf].
 *
 * PGCL=0 / mainline: cluster==MMUPAGE, no false match, exits 0.
 * Unfixed PGCL>=1: kernel BUG (this task is killed / box wedges).
 * Fixed   PGCL>=1: clean, prints OK, exits 0.
 *
 * Build (cluster size = PAGE_SIZE = 64K at PGCL=4; works at any PAGE_SIZE
 * because we drive everything off the kernel's PAGE_SIZE via the CLUSTER macro
 * passed at compile time, defaulting to 64K).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/stat.h>

#ifndef CLUSTER
#define CLUSTER (64UL * 1024)		/* kernel PAGE_SIZE at PAGE_MMUSHIFT=4 */
#endif

#define WIN_A_BYTES (128UL * CLUSTER)	/* 8 MiB at 64K clusters: i_mmap [0, 0x7ff] MMUPAGE */
#define HI_CLUSTER  0xbdUL		/* the journald folio's cluster index */
#define HI_OFF      (HI_CLUSTER * CLUSTER)
#define FILE_BYTES  (HI_OFF + 16UL * CLUSTER)

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "./rmap_repro.dat";
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { perror("open"); return 2; }
	if (ftruncate(fd, FILE_BYTES)) { perror("ftruncate"); return 2; }

	/* window A: low 8 MiB, shared -> inserted into i_mmap at vm_pgoff 0 */
	char *A = mmap(NULL, WIN_A_BYTES, PROT_READ | PROT_WRITE,
		       MAP_SHARED, fd, 0);
	if (A == MAP_FAILED) { perror("mmap A"); return 2; }

	/* window B: one cluster at the high offset, shared -> maps folio@0xbd */
	char *B = mmap(NULL, CLUSTER, PROT_READ | PROT_WRITE,
		       MAP_SHARED, fd, HI_OFF);
	if (B == MAP_FAILED) { perror("mmap B"); return 2; }

	A[0] = 'a';			/* fault in window A (in the tree, mapped) */
	B[0] = 'b';			/* dirty the high folio via its mapping  */
	printf("mapped A=[0,%luK) B=@%luK; dirtied cluster 0x%lx; syncing...\n",
	       WIN_A_BYTES >> 10, HI_OFF >> 10, HI_CLUSTER);
	fflush(stdout);

	if (msync(B, CLUSTER, MS_SYNC))			/* writeback -> folio_mkclean */
		perror("msync");
	if (fsync(fd))
		perror("fsync");
	/* the exact journald trigger: punch a hole over the high cluster */
	if (fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
		      HI_OFF, CLUSTER))
		fprintf(stderr, "fallocate(PUNCH_HOLE): %s\n", strerror(errno));

	munmap(A, WIN_A_BYTES);
	munmap(B, CLUSTER);
	close(fd);
	unlink(path);
	printf("OK: no BUG — rmap file walk survived the cross-window writeback\n");
	return 0;
}
