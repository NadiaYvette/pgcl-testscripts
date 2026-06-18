/*
 * init-btrfs-io.c - PID1 btrfs I/O stressor for reproducing the laptop's
 * PGCL btrfs/block hang in QEMU (kernel mounts root=/dev/vda rootfstype=btrfs).
 *
 * Exercises the path the matrix never did (9p/musl): btrfs root mount (just
 * reaching this code proves it) + concurrent block I/O with fsync, mmap-verify
 * and read-verify across sub-PAGE..multi-cluster sizes.  Detects:
 *   - hang        : heartbeat stops, qemu times out (a worker stuck in D)
 *   - corruption  : memcmp mismatch -> "CORRUPT"
 *   - I/O error   : write/read/fsync fails -> "IOERR"
 * Clean run -> "PGCL-BTRFS-IO: PASS" then power off.
 *
 * Build: gcc -O2 -static -o init-btrfs-io init-btrfs-io.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <sys/stat.h>

#define MARK "PGCL-BTRFS-IO"
static void W(const char *s) { (void)write(1, s, strlen(s)); }
static void Wf(const char *fmt, ...) {
	char b[160]; va_list ap; va_start(ap, fmt);
	vsnprintf(b, sizeof b, fmt, ap); va_end(ap); W(b);
}

/* write a patterned file, fsync, mmap-verify, read-verify; <0 = error/corrupt */
static int do_file(const char *path, size_t sz, unsigned seed)
{
	char *buf = malloc(sz), *rb = malloc(sz);
	int rc = -1;
	if (!buf || !rb) { free(buf); free(rb); return -1; }
	for (size_t i = 0; i < sz; i++)
		buf[i] = (char)(seed * 2654435761u + i * 131u);
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { rc = -2; goto out; }
	for (size_t off = 0; off < sz; ) {
		ssize_t r = write(fd, buf + off, sz - off);
		if (r <= 0) { rc = -3; goto out_fd; }
		off += r;
	}
	if (fsync(fd)) { rc = -4; goto out_fd; }
	void *m = mmap(NULL, sz, PROT_READ, MAP_PRIVATE, fd, 0);
	if (m != MAP_FAILED) {
		int bad = memcmp(m, buf, sz);
		munmap(m, sz);
		if (bad) { rc = -10; goto out_fd; }   /* mmap corruption */
	}
	lseek(fd, 0, SEEK_SET);
	for (size_t off = 0; off < sz; ) {
		ssize_t r = read(fd, rb + off, sz - off);
		if (r <= 0) { rc = -5; goto out_fd; }
		off += r;
	}
	rc = memcmp(buf, rb, sz) ? -11 : 0;        /* read corruption */
out_fd:
	close(fd);
out:
	free(buf); free(rb);
	return rc;
}

int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	mkdir("/proc", 0755); mount("proc", "/proc", "proc", 0, 0);
	mkdir("/sys", 0755);  mount("sysfs", "/sys", "sys", 0, 0);
	mkdir("/testdir", 0755);
	W(MARK ": btrfs root mounted, userspace reached\n");

	const size_t sizes[] = { 4096, 65536, 262144, 1u<<20, 4u<<20 };
	const int nw = 8, iters = 120;

	for (int wkr = 0; wkr < nw; wkr++) {
		pid_t p = fork();
		if (p == 0) {
			char path[80];
			for (int it = 0; it < iters; it++) {
				for (unsigned s = 0; s < sizeof(sizes)/sizeof(sizes[0]); s++) {
					snprintf(path, sizeof path, "/testdir/w%d_%u.dat", wkr, s);
					int rc = do_file(path, sizes[s], (unsigned)(wkr*100003 + it*7 + s));
					if (rc == -10 || rc == -11) {
						Wf(MARK ": CORRUPT wkr=%d it=%d sz=%zu rc=%d\n", wkr, it, sizes[s], rc);
						_exit(7);
					}
					if (rc < 0) {
						Wf(MARK ": IOERR wkr=%d it=%d sz=%zu rc=%d errno=%d\n", wkr, it, sizes[s], rc, errno);
						_exit(8);
					}
					unlink(path);
				}
				if (wkr == 0 && it % 20 == 0)
					Wf(MARK ": heartbeat it=%d/%d\n", it, iters);
			}
			_exit(0);
		}
	}

	int st, n = 0, fails = 0;
	while (wait(&st) > 0) { n++; if (!WIFEXITED(st) || WEXITSTATUS(st)) fails++; }
	Wf(MARK ": workers=%d fails=%d\n", n, fails);
	W(fails ? MARK ": FAIL\n" : MARK ": PASS\n");
	sync();
	W(MARK ": halting\n");
	reboot(RB_POWER_OFF);
	for (;;) pause();
	return 0;
}
