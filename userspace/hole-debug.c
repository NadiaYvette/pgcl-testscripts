/*
 * Exact reproduction of mmapstress07 to debug hole-zeroing failure.
 * Matches the LTP test's open/write/mmap sequence precisely.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>

int main(void)
{
	size_t pagesize = sysconf(_SC_PAGESIZE);
	const char *tmpname = "/tmp/hole-debug-file";
	int rofd, rwfd, i;
	char *mapaddr;
	size_t holesize = pagesize;        /* argv[2] equivalent */
	int e_pageskip = 1;                /* argv[3] */
	size_t sparseoff = pagesize * 2;   /* argv[4] equivalent */

	printf("pagesize=%zu sparseoff=%zu holesize=%zu e_pageskip=%d\n",
		pagesize, sparseoff, holesize, e_pageskip);

	/* Exactly match mmapstress07's open pattern */
	unlink(tmpname); /* ensure fresh */
	rofd = open(tmpname, O_RDONLY | O_CREAT, 0777);
	if (rofd < 0) { perror("open rofd"); return 1; }
	rwfd = open(tmpname, O_RDWR);
	if (rwfd < 0) { perror("open rwfd"); return 1; }

	/* lseek to sparseoff */
	if (lseek(rwfd, sparseoff, SEEK_SET) < 0) { perror("lseek1"); return 1; }

	/* Write pagesize 'a's byte-at-a-time */
	i = 0;
	while (i < (int)pagesize && write(rwfd, "a", 1) == 1)
		i++;
	printf("wrote %d 'a's at %zu-%zu\n", i, sparseoff, sparseoff + i);

	/* Create hole: lseek +holesize */
	if (lseek(rwfd, holesize, SEEK_CUR) < 0) { perror("lseek hole"); return 1; }

	/* Write half-page of 'b' */
	i = 0;
	while (i < (int)(pagesize >> 1) && write(rwfd, "b", 1) == 1)
		i++;
	printf("wrote %d 'b's\n", i);

	off_t cur = lseek(rwfd, 0, SEEK_CUR);
	printf("file pos after b: %ld, file size: %ld\n",
		(long)cur, (long)lseek(rwfd, 0, SEEK_END));
	/* seek back to end of b's for c writing later */
	lseek(rwfd, cur, SEEK_SET);

	/* Mmap through rofd (exactly as mmapstress07) */
	mapaddr = mmap(NULL, pagesize * 2 + holesize, PROT_READ,
		       MAP_SHARED, rofd, sparseoff);
	if (mapaddr == MAP_FAILED) { perror("mmap"); return 1; }
	printf("mmap OK at %p, len=%zu, offset=%zu\n",
		mapaddr, pagesize * 2 + holesize, sparseoff);

	/* Write c's to extend (exactly as mmapstress07: continue from i = pagesize/2) */
	i = pagesize >> 1;
	while (i < 2 * (int)pagesize && write(rwfd, "c", 1) == 1)
		i++;
	printf("wrote c's total %d bytes, file size: %ld\n",
		i, (long)lseek(rwfd, 0, SEEK_END));

	/* THE CRITICAL CHECK (line 224 of mmapstress07) */
	char hole_val = *(mapaddr + pagesize + (holesize >> 1));
	printf("\n=== Critical check: *(mapaddr + %zu + %zu) ===\n",
		pagesize, holesize >> 1);
	printf("  file offset = %zu + %zu + %zu = %zu\n",
		sparseoff, pagesize, holesize >> 1,
		sparseoff + pagesize + (holesize >> 1));

	if (hole_val != 0) {
		printf("  FAIL: hole byte = 0x%02x '%c'\n",
			(unsigned char)hole_val,
			(hole_val >= 32 && hole_val < 127) ? hole_val : '?');
	} else {
		printf("  PASS: hole byte is zero\n");
	}

	/* Detailed dump of the mapped regions */
	printf("\nMmap contents dump:\n");
	/* Last few bytes before hole */
	printf("  Before hole (mapaddr[%zu-%zu]):\n", pagesize - 4, pagesize - 1);
	for (i = (int)pagesize - 4; i < (int)pagesize; i++)
		printf("    [%d] = 0x%02x '%c'\n", i, (unsigned char)mapaddr[i],
			(mapaddr[i] >= 32 && mapaddr[i] < 127) ? mapaddr[i] : '.');

	printf("  Hole start (mapaddr[%zu-%zu]):\n", pagesize, pagesize + 8);
	for (i = (int)pagesize; i < (int)(pagesize + 8); i++)
		printf("    [%d] = 0x%02x '%c'\n", i, (unsigned char)mapaddr[i],
			(mapaddr[i] >= 32 && mapaddr[i] < 127) ? mapaddr[i] : '.');

	printf("  Hole middle (mapaddr[%zu-%zu]):\n",
		pagesize + (holesize >> 1) - 4, pagesize + (holesize >> 1) + 4);
	for (i = (int)(pagesize + (holesize >> 1) - 4);
	     i < (int)(pagesize + (holesize >> 1) + 4); i++)
		printf("    [%d] = 0x%02x '%c'\n", i, (unsigned char)mapaddr[i],
			(mapaddr[i] >= 32 && mapaddr[i] < 127) ? mapaddr[i] : '.');

	printf("  Hole end (mapaddr[%zu-%zu]):\n",
		pagesize + holesize - 4, pagesize + holesize + 4);
	for (i = (int)(pagesize + holesize - 4);
	     i < (int)(pagesize + holesize + 4); i++)
		printf("    [%d] = 0x%02x '%c'\n", i, (unsigned char)mapaddr[i],
			(mapaddr[i] >= 32 && mapaddr[i] < 127) ? mapaddr[i] : '.');

	/* Also verify via read() */
	printf("\nread() verification of hole:\n");
	{
		char buf[4096];
		off_t hole_start = sparseoff + pagesize;
		lseek(rofd, hole_start, SEEK_SET);
		ssize_t n = read(rofd, buf, holesize < 4096 ? holesize : 4096);
		int nz = 0;
		for (i = 0; i < (int)n; i++)
			if (buf[i] != 0) nz++;
		printf("  read %zd bytes from hole at offset %ld, %d non-zero\n",
			n, (long)hole_start, nz);
		if (nz > 0) {
			for (i = 0; i < (int)n && i < 16; i++)
				printf("    [%d] = 0x%02x\n", i, (unsigned char)buf[i]);
		}
	}

	munmap(mapaddr, pagesize * 2 + holesize);
	close(rofd);
	close(rwfd);
	unlink(tmpname);
	return (hole_val != 0) ? 1 : 0;
}
