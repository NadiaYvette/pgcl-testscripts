#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

static void check_buf(const char *label, const char *buf, size_t sz)
{
	size_t j;
	int first_bad = -1;
	for (j = 0; j < sz; j++) {
		if ((unsigned char)buf[j] != 0x01) {
			first_bad = j;
			break;
		}
	}
	printf("%s: %s", label, first_bad < 0 ? "PASS" : "FAIL");
	if (first_bad >= 0)
		printf(" mismatch@%d/%zu val=0x%02x",
		       first_bad, sz, (unsigned char)buf[first_bad]);
	printf("\n");
}

int main(void)
{
	long pgsz = sysconf(_SC_PAGESIZE);
	size_t thpsize = 512 * 1024;
	size_t mmap_size = 2 * thpsize;
	char *mmap_mem, *mem;
	int ret, status;

	printf("pagesize=%ld thpsize=%zu\n", pgsz, thpsize);

	mmap_mem = mmap(NULL, mmap_size, PROT_READ | PROT_WRITE,
			MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (mmap_mem == MAP_FAILED) { perror("mmap"); return 1; }

	mem = (char *)(((unsigned long)mmap_mem + thpsize) & ~(thpsize - 1));
	madvise(mem, thpsize, MADV_HUGEPAGE);
	mem[0] = 1;
	memset(mem, 1, thpsize);

	/* PTE-mapping dance */
	mprotect(mem + pgsz, pgsz, PROT_READ);
	mprotect(mem + pgsz, pgsz, PROT_READ | PROT_WRITE);

	/* Test: exact cow selftest child_vmsplice_memcmp_fn flow */
	ret = fork();
	if (ret < 0) { perror("fork"); return 1; }
	if (ret == 0) {
		/* Child - replicate exact cow test flow */
		struct iovec iov = { .iov_base = mem, .iov_len = thpsize };
		char *old, *new;
		ssize_t transferred, cur, total;
		int fds[2];

		old = malloc(thpsize);
		new = malloc(thpsize);
		memset(old, 0, thpsize);
		memset(new, 0, thpsize);

		/* Backup */
		memcpy(old, mem, thpsize);
		check_buf("child-after-memcpy", old, thpsize);

		/* Pipe + vmsplice */
		pipe(fds);
		transferred = vmsplice(fds[1], &iov, 1, 0);
		printf("child: vmsplice returned %zd\n", transferred);
		check_buf("child-after-vmsplice", old, thpsize);

		/* Unmap */
		munmap(mem, thpsize);
		check_buf("child-after-munmap", old, thpsize);

		/* Read pipe */
		for (total = 0; total < transferred; total += cur) {
			cur = read(fds[0], new + total, transferred - total);
			if (cur < 0) { perror("read"); _exit(1); }
		}
		check_buf("child-pipe-data", new, thpsize);

		/* Compare */
		if (memcmp(old, new, transferred))
			printf("child: MEMCMP FAIL\n");
		else
			printf("child: MEMCMP PASS\n");

		close(fds[0]);
		close(fds[1]);
		free(old);
		free(new);
		_exit(0);
	}

	/* Parent: wait, write, signal */
	usleep(100000); /* let child do vmsplice + munmap */
	memset(mem, 0xff, thpsize); /* trigger COW */
	wait(&status);

	munmap(mmap_mem, mmap_size);
	return 0;
}
