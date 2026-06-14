/* Standalone instrumented reproducer for LTP mremap06 on PGCL=6.
 * Mirrors testcases/kernel/syscalls/mremap/mremap06.c but prints the
 * result + errno of every mremap/mmap/mprotect call and continues past
 * failures, so we can see exactly which call fails and with what errno. */
#define _GNU_SOURCE
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/shm.h>

#define NUM_GRANULARITYS 3

static long G;          /* MMAP_GRANULARITY */
static int mmap_size, mremap_size;

static long granularity(void)
{
	long shmlba = (long)SHMLBA;
	long pg = getpagesize();
	return shmlba > pg ? shmlba : pg;
}

static void do_test(int n, size_t incompatible, const char *desc)
{
	char *buf, *buf2;
	int i, ret;

	fprintf(stderr, "\n=== tcase %d: %s ===\n", n, desc);

	buf = mmap(0, mmap_size, PROT_READ|PROT_WRITE, MAP_SHARED, 3 /*fd*/, 0);
	fprintf(stderr, "  mmap(%d) = %p (errno=%d %s)\n", mmap_size, buf,
	       buf == MAP_FAILED ? errno : 0,
	       buf == MAP_FAILED ? strerror(errno) : "ok");
	if (buf == MAP_FAILED)
		return;
	fprintf(stderr, "  buf%%G=%#lx  buf%%PAGESIZE=%#lx\n",
	       (unsigned long)buf % G, (unsigned long)buf % getpagesize());

	/* move 2nd granularity chunk out to position 3 (buf+mremap_size) */
	errno = 0;
	buf2 = mremap(buf + G, G, G, MREMAP_MAYMOVE|MREMAP_FIXED, buf + mremap_size);
	fprintf(stderr, "  mremap#1 src=%p dst=%p => %p (errno=%d %s)\n",
	       buf + G, buf + mremap_size, buf2,
	       buf2 == MAP_FAILED ? errno : 0,
	       buf2 == MAP_FAILED ? strerror(errno) : "ok");

	if (incompatible) {
		errno = 0;
		ret = mprotect(buf + (incompatible-1)*G, G, PROT_READ);
		fprintf(stderr, "  mprotect(%p) => %d (errno=%d %s)\n",
		       buf + (incompatible-1)*G, ret,
		       ret ? errno : 0, ret ? strerror(errno) : "ok");
	}

	/* move it back to position 1 (buf+G) */
	errno = 0;
	buf2 = mremap(buf + mremap_size, G, G, MREMAP_MAYMOVE|MREMAP_FIXED, buf + G);
	fprintf(stderr, "  mremap#2 src=%p dst=%p => %p (errno=%d %s)\n",
	       buf + mremap_size, buf + G, buf2,
	       buf2 == MAP_FAILED ? errno : 0,
	       buf2 == MAP_FAILED ? strerror(errno) : "ok");

	if (buf2 != MAP_FAILED) {
		for (i = 0; i < NUM_GRANULARITYS; i++) {
			char val = buf[i * G];
			fprintf(stderr, "  page %d: val=0x%x (want 0x%x) %s\n", i,
			       (unsigned char)val, 0x30 + i,
			       val == 0x30 + i ? "OK" : "WRONG");
		}
	}
	munmap(buf, mremap_size);
}

int main(void)
{
	int fd, i;

	setvbuf(stderr, NULL, _IONBF, 0);
	setvbuf(stdout, NULL, _IONBF, 0);
	G = granularity();
	mmap_size = (NUM_GRANULARITYS+1) * G;
	mremap_size = NUM_GRANULARITYS * G;
	fprintf(stderr, "getpagesize=%d SHMLBA=%ld MMAP_GRANULARITY=%ld mmap_size=%d mremap_size=%d\n",
	       getpagesize(), (long)SHMLBA, G, mmap_size, mremap_size);

	fd = open("mremap06-testfile", O_CREAT|O_RDWR|O_TRUNC, 0600);
	if (fd < 0) { perror("open"); return 1; }
	/* fd is expected to be 3 (stdin/out/err = 0/1/2) */
	if (fd != 3)
		dup2(fd, 3);

	if (fallocate(3, 0, 0, mmap_size)) { perror("fallocate"); return 1; }

	char *buf = mmap(0, mmap_size, PROT_READ|PROT_WRITE, MAP_SHARED, 3, 0);
	if (buf == MAP_FAILED) { perror("setup mmap"); return 1; }
	for (i = 0; i < NUM_GRANULARITYS+1; i++)
		buf[i*G] = 0x30 + i;
	munmap(buf, mmap_size);

	do_test(0, 0, "all compatible");
	do_test(1, 3, "third granularity incompatible");
	do_test(2, 1, "first granularity incompatible");

	fprintf(stderr, "\nDONE\n");
	return 0;
}
