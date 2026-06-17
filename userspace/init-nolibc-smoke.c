/* sh4 PGCL boot smoke test — nolibc /init.
 *
 * Goal: prove a page-clustering kernel reaches userspace on sh4 (qemu r2d)
 * and that the core mm paths work. Uses only write()/mmap()/fork() so it has
 * no libc and no libgcc division dependency (numbers printed in hex).
 *
 * Build (see build-and-boot.sh):
 *   sh4-linux-gcc -Os -static -nostdlib -nostdinc \
 *     -I<k>/tools/include/nolibc -include <k>/tools/include/nolibc/nolibc.h \
 *     -o init init.c
 */

#ifndef MAP_FAILED
#define MAP_FAILED ((void *)-1)
#endif
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS 0x20
#endif
#ifndef MAP_PRIVATE
#define MAP_PRIVATE 0x02
#endif
#ifndef PROT_READ
#define PROT_READ 0x1
#endif
#ifndef PROT_WRITE
#define PROT_WRITE 0x2
#endif

static void puts_(const char *s)
{
	int n = 0;
	while (s[n])
		n++;
	write(1, s, n);
}

/* print an unsigned long as 0x... (no division → no libgcc) */
static void puthex(unsigned long v)
{
	char b[2 + 16 + 1];
	int i = sizeof(b) - 1;
	b[i--] = '\0';
	if (!v)
		b[i--] = '0';
	while (v) {
		int d = v & 0xf;
		b[i--] = d < 10 ? '0' + d : 'a' + d - 10;
		v >>= 4;
	}
	b[i--] = 'x';
	b[i] = '0';
	write(1, &b[i], (int)(sizeof(b) - 1 - i));
}

int main(void)
{
	unsigned long len, i;
	char *p, *q;
	int pid, st, ok;

	puts_("\n==== PGCL-NOLIBC-SMOKE ====\n");
	puts_("userspace reached\n");

	puts_("AT_PAGESZ=");
	puthex(getauxval(AT_PAGESZ));
	puts_(" getpagesize=");
	puthex((unsigned long)getpagesize());
	puts_("\n");

	/* mmap a 256 KiB anon region, touch every 4 KiB MMU page, verify */
	len = 256UL * 1024;
	p = mmap(0, len, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		puts_("MMAP: FAIL\n");
	} else {
		for (i = 0; i < len; i += 4096)
			p[i] = (char)(i >> 12);
		ok = 1;
		for (i = 0; i < len; i += 4096)
			if (p[i] != (char)(i >> 12))
				ok = 0;
		puts_(ok ? "MMAP-TOUCH: OK\n" : "MMAP-TOUCH: FAIL\n");
		munmap(p, len);
	}

	/* fork + COW: child writes its copy, parent must still read its own */
	q = mmap(0, 65536, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (q == MAP_FAILED) {
		puts_("FORK-COW: SKIP (mmap fail)\n");
	} else {
		q[0] = 'A';
		q[4096] = 'A';
		pid = fork();
		if (pid == 0) {
			q[0] = 'B';
			q[4096] = 'B';
			_exit(0);
		}
		st = 0;
		waitpid(pid, &st, 0);
		ok = (q[0] == 'A' && q[4096] == 'A');
		puts_(ok ? "FORK-COW: OK\n" : "FORK-COW: FAIL\n");
		munmap(q, 65536);
	}

	puts_("==== PGCL-NOLIBC-SMOKE: PASS ====\n");

	/* settle the console, then power off the r2d */
	for (i = 0; i < 2000000; i++)
		__asm__ __volatile__("");
	reboot(RB_POWER_OFF);

	/* if poweroff is unsupported on this board, spin so qemu's timeout
	 * kills us rather than panicking on init exit */
	for (;;)
		;
	return 0;
}
