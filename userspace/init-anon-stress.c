/*
 * init-anon-stress.c - PGCL anon large-folio rmap stressor (MMUPAGE conversion).
 *
 * Exercises exactly the anon paths converted to MMUPAGE-uniform mapcount:
 *   - large anon fault         (map_anon_folio_pte_nopf / do_anonymous_page)
 *   - fork dup (COW-read share)(copy_present_ptes)
 *   - COW write                (wp_page_copy / do_wp_page)
 *   - munmap                   (zap_present_ptes)
 * Enables THP so the large-folio (Contract-A->MMUPAGE) path is hit, then:
 *   fill+verify parent; fork children that COW-read (must see parent data) then
 *   COW-write their own pattern (must see their writes); parent re-verifies its
 *   copy UNCHANGED (COW isolation).  A mapcount underflow/leak from the
 *   conversion shows as a kernel "Bad page"/"still mapped" dump; a wrong
 *   mapcount that mis-shares COW shows as a memcmp mismatch (CORRUPT).
 *
 * Build: gcc -O2 -static -include stdarg.h -o init-anon-stress init-anon-stress.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <sys/reboot.h>

#define MARK "PGCL-ANON"
#define MMU 4096UL
static void W(const char *s){ (void)write(1,s,strlen(s)); }
static void Wf(const char *f,...){ char b[200]; va_list a; va_start(a,f); vsnprintf(b,sizeof b,f,a); va_end(a); W(b); }
static unsigned char pat(size_t i, unsigned s){ return (unsigned char)(s*2654435761u + i*1099087573u + (i>>11)); }

static void enable_thp(void){
	int fd = open("/sys/kernel/mm/transparent_hugepage/enabled", O_WRONLY);
	if (fd>=0){ (void)write(fd,"always",6); close(fd); }
	/* best-effort mTHP enable for a few orders */
	const char *o[]={"hugepages-64kB","hugepages-128kB","hugepages-256kB","hugepages-512kB","hugepages-1024kB","hugepages-2048kB"};
	for (unsigned k=0;k<sizeof(o)/sizeof(o[0]);k++){
		char p[160]; snprintf(p,sizeof p,"/sys/kernel/mm/transparent_hugepage/%s/enabled",o[k]);
		int f=open(p,O_WRONLY); if(f>=0){ (void)write(f,"always",6); close(f);} }
}

/* one cycle: large anon mmap, fault, fork COW-read+write, verify isolation. ret 0 ok */
static int cycle(size_t sz, unsigned seed)
{
	unsigned char *m = mmap(NULL, sz, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if (m==MAP_FAILED) return -1;
	madvise(m, sz, MADV_HUGEPAGE);
	for (size_t i=0;i<sz;i++) m[i]=pat(i,seed);            /* fault in (large anon) */
	for (size_t i=0;i<sz;i+=MMU) if (m[i]!=pat(i,seed)) { munmap(m,sz); return -2; }

	pid_t p = fork();
	if (p==0){
		/* child: COW-read must see parent's data (shared via fork dup) */
		for (size_t i=0;i<sz;i+=MMU) if (m[i]!=pat(i,seed)) _exit(20);
		/* COW-write our own pattern, then verify our writes */
		for (size_t i=0;i<sz;i++) m[i]=pat(i,seed^0xABCD);
		for (size_t i=0;i<sz;i+=MMU) if (m[i]!=pat(i,seed^0xABCD)) _exit(21);
		_exit(0);
	}
	int st; waitpid(p,&st,0);
	/* parent: its copy must be UNCHANGED by the child's COW writes */
	for (size_t i=0;i<sz;i+=MMU) if (m[i]!=pat(i,seed)) { munmap(m,sz); return -3; }
	munmap(m,sz);
	if (!WIFEXITED(st) || WEXITSTATUS(st)) return -4 - WEXITSTATUS(st);
	return 0;
}

static void worker(int wkr)
{
	const size_t sizes[]={ 256*MMU, 512*MMU, 1u<<20, 2u<<20, 4u<<20 };
	for (int it=0; it<80; it++){
		for (unsigned s=0;s<sizeof(sizes)/sizeof(sizes[0]);s++){
			int rc = cycle(sizes[s], (unsigned)(wkr*100003 + it*31 + s));
			if (rc){ Wf(MARK ": CORRUPT wkr=%d it=%d sz=%zu rc=%d\n", wkr,it,sizes[s],rc); _exit(7); }
		}
		if (wkr==0 && it%20==0) Wf(MARK ": hb it=%d\n", it);
	}
	_exit(0);
}

int main(void)
{
	setvbuf(stdout,NULL,_IONBF,0);
	mkdir("/proc",0755); mount("proc","/proc","proc",0,0);
	mkdir("/sys",0755); mount("sysfs","/sys","sysfs",0,0);
	enable_thp();
	W(MARK ": start (large-anon fork/COW rmap stress)\n");
	int nw=4;
	for (int w=0; w<nw; w++){ pid_t p=fork(); if(p==0) worker(w); }
	int st,n=0,fl=0; while (wait(&st)>0){ n++; if(!WIFEXITED(st)||WEXITSTATUS(st)) fl++; }
	Wf(MARK ": workers=%d failed=%d\n", n, fl);
	W(fl ? MARK ": FAIL\n" : MARK ": PASS\n");
	sync(); W(MARK ": halting\n"); reboot(RB_POWER_OFF); for(;;) pause(); return 0;
}
