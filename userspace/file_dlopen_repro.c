/*
 * file_dlopen_repro — faithful repro of the #143 file-folio rmap underflow.
 *
 * gst-plugin-scanner / wireplumber dlopen() many shared objects; the dynamic
 * linker mmaps each .so's segments MAP_PRIVATE at 4K (MMUPAGE) — i.e.
 * NON-cluster-aligned — offsets, mprotects RELRO, and COWs the GOT/data via
 * relocations.  Under PGCL those file folios straddle PTE tables, hitting the
 * (dead) straddle path -> rmap mapcount/refcount desync.  Cross-process sharing
 * of the same .so (high mapcount) + fork+exit (zap of inherited maps) compounds
 * it.  We replicate exactly: scan the system libdirs and dlopen real .so files
 * in many workers, forking short-lived children that exit with the libs mapped.
 *
 * usage: file_dlopen_repro <seconds> [workers]
 * MUST be built dynamic (needs the loader + dlopen).  Under a DEBUG_VM PGCL
 * kernel the underflow trips a "Bad page" oops (watch dmesg) and/or the freed
 * .so folios fail the free-time mapcount check.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <dlfcn.h>
#include <unistd.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/mman.h>

#define MAXLIBS 256
static char *libs[MAXLIBS];
static int nlibs;
static long deadline;
static long nowsec(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec; }

static void scan(const char *dir)
{
	DIR *d = opendir(dir);
	if (!d) return;
	struct dirent *e;
	while ((e = readdir(d)) && nlibs < MAXLIBS) {
		if (!strstr(e->d_name, ".so"))
			continue;
		char path[512];
		snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
		libs[nlibs++] = strdup(path);
	}
	closedir(d);
}

/* dlopen a batch, optionally fork a child that exits with them mapped, dlclose */
static void cycle(unsigned it)
{
	void *h[32];
	int n = 0;
	for (int i = 0; i < 24 && nlibs; i++) {
		const char *l = libs[(it * 7 + i) % nlibs];
		void *x = dlopen(l, RTLD_LAZY | RTLD_LOCAL);
		if (x) {
			h[n++] = x;
			/* touch a symbol to fault/relocate (COW) more of it */
			dlsym(x, "malloc");
		}
		if (n >= 32) break;
	}
	/* fork children that inherit the mappings and exit -> zap path */
	pid_t c = fork();
	if (c == 0) {
		/* grandchild: dlopen a few more, then exit with everything mapped */
		for (int i = 0; i < 6 && nlibs; i++)
			dlopen(libs[(it * 13 + i) % nlibs], RTLD_LAZY | RTLD_LOCAL);
		_exit(0);
	} else if (c > 0) {
		int st; waitpid(c, &st, 0);
	}
	for (int i = 0; i < n; i++)
		dlclose(h[i]);		/* unmap (refcount -> 0) */
}

static void mempress(void)
{
	/* light reclaim pressure -> workingset/refault of .so pages */
	size_t sz = 256UL * 1024 * 1024;
	while (nowsec() < deadline) {
		char *p = mmap(NULL, sz, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) { usleep(1000); continue; }
		for (size_t o = 0; o < sz; o += 4096) p[o] = 1;
		munmap(p, sz);
	}
}

int main(int argc, char **argv)
{
	int secs = argc > 1 ? atoi(argv[1]) : 75;
	int nw = argc > 2 ? atoi(argv[2]) : 10;
	if (argc > 3)			/* dlopen .so from this dir only (e.g. btrfs) */
		scan(argv[3]);
	else {
		scan("/usr/lib64"); scan("/lib64"); scan("/usr/lib");
	}
	deadline = nowsec() + secs;
	printf("DLREPRO start secs=%d workers=%d libs=%d\n", secs, nw, nlibs);
	fflush(stdout);
	if (!nlibs) { printf("DLREPRO no libs found\n"); return 2; }

	pid_t k[64]; int nk = 0;
	if (nw > 60) nw = 60;
	for (int i = 0; i < nw; i++) {
		pid_t p = fork();
		if (p == 0) { for (unsigned it = 0; nowsec() < deadline; it++) cycle(it); _exit(0); }
		k[nk++] = p;
	}
	{ pid_t p = fork(); if (p == 0) { mempress(); _exit(0); } k[nk++] = p; }
	for (int i = 0; i < nk; i++) { int st; waitpid(k[i], &st, 0); }
	printf("DLREPRO DONE\n");
	return 0;
}
