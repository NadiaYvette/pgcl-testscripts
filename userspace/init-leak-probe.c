/*
 * init-leak-probe.c - pinpoint which mmap size leaks mapcount ("still mapped
 * when deleted").  Sequential, one file per size, markers around each so the
 * kernel bad-page dump (if any) lands between begin/done for the guilty size.
 * Build: gcc -O2 -static -include stdarg.h -o init-leak-probe init-leak-probe.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mount.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <sys/stat.h>

#define MMU 4096UL
static void W(const char *s){ (void)write(1,s,strlen(s)); }
static void Wf(const char *f,...){ char b[200]; va_list a; va_start(a,f); vsnprintf(b,sizeof b,f,a); va_end(a); W(b);}

static void probe(unsigned long sz)
{
	char path[64]; snprintf(path,sizeof path,"/testdir/p_%lu.dat", sz);
	char *buf = malloc(sz);
	for (unsigned long i=0;i<sz;i++) buf[i]=(char)(i*131u+7u);
	int fd = open(path,O_RDWR|O_CREAT|O_TRUNC,0644);
	if (fd<0){ Wf("PROBE sz=%lu OPENERR %d\n",sz,errno); free(buf); return; }
	for (unsigned long o=0;o<sz;){ ssize_t r=write(fd,buf+o,sz-o); if(r<=0){Wf("PROBE sz=%lu WRERR\n",sz);close(fd);free(buf);return;} o+=r; }
	fsync(fd);
	Wf("PROBE sz=%lu BEGIN\n", sz);
	unsigned char *m = mmap(NULL,sz,PROT_READ,MAP_PRIVATE,fd,0);
	if (m==MAP_FAILED){ Wf("PROBE sz=%lu MAPFAIL %d\n",sz,errno); close(fd);free(buf);return; }
	volatile unsigned long acc=0;
	for (unsigned long i=0;i<sz;i+=MMU) acc+=m[i];   /* fault every sub-page */
	int bad = memcmp(m,buf,sz);
	munmap(m,sz);
	close(fd);
	sync();
	unlink(path);                                    /* triggers evict; leak -> "still mapped" here */
	sync();
	Wf("PROBE sz=%lu DONE bad=%d acc=%lu\n", sz, bad, (unsigned long)acc);
	free(buf);
}

int main(void)
{
	setvbuf(stdout,NULL,_IONBF,0);
	mkdir("/proc",0755); mount("proc","/proc","proc",0,0);
	mkdir("/testdir",0755);
	W("LEAK-PROBE: start\n");
	unsigned long sizes[] = { 64*MMU, 256*MMU/MMU*MMU, /* placeholders below */ };
	(void)sizes;
	/* explicit byte sizes: 64K, 256K(=1 cluster@pgcl6), 320K, 512K, 1M, 2M, 4M, 8M */
	unsigned long S[] = { 64UL<<10, 256UL<<10, 320UL<<10, 512UL<<10,
			      1UL<<20, 2UL<<20, 4UL<<20, 8UL<<20 };
	for (unsigned i=0;i<sizeof(S)/sizeof(S[0]);i++) {
		probe(S[i]);
		probe(S[i]);   /* twice: second run faults into possibly-leaked state */
	}
	W("LEAK-PROBE: PASS\n"); sync(); W("LEAK-PROBE: halting\n");
	reboot(RB_POWER_OFF); for(;;) pause(); return 0;
}
