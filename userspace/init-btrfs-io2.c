/*
 * init-btrfs-io2.c - STAGE 2 btrfs repro: subvolume + compress=zstd, matching
 * the laptop (/ and /home are btrfs subvols, /home has compress=zstd).
 *
 * Kernel mounts root=/dev/vda (top-level subvolid 5).  This init then:
 *   1. creates subvol "home" via BTRFS_IOC_SUBVOL_CREATE (no btrfs-progs needed)
 *   2. mounts /dev/vda -o subvol=home,compress=zstd at /home
 *   3. hammers I/O on both / (plain) and /home (compressed) with fsync,
 *      mmap-verify, read-verify; /home uses COMPRESSIBLE data so the zstd
 *      compression path actually executes under PAGE_SIZE = 64K/256K.
 *
 * Detect: hang (heartbeat stops), CORRUPT (memcmp), IOERR, or PASS+poweroff.
 * Build: gcc -O2 -static -o init-btrfs-io2 init-btrfs-io2.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/stat.h>

#define MARK "PGCL-BTRFS-IO2"
static void W(const char *s) { (void)write(1, s, strlen(s)); }
static void Wf(const char *fmt, ...) {
	char b[200]; va_list ap; va_start(ap, fmt);
	vsnprintf(b, sizeof b, fmt, ap); va_end(ap); W(b);
}

/* btrfs ioctl (avoid needing linux/btrfs.h) */
#define BTRFS_IOCTL_MAGIC 0x94
#define BTRFS_PATH_NAME_MAX 4087
struct btrfs_ioctl_vol_args { long long fd; char name[BTRFS_PATH_NAME_MAX + 1]; };
#define BTRFS_IOC_SUBVOL_CREATE _IOW(BTRFS_IOCTL_MAGIC, 14, struct btrfs_ioctl_vol_args)

/* compressible=1 -> low-entropy (zstd compresses); else pseudo-random */
static int do_file(const char *path, size_t sz, unsigned seed, int compressible)
{
	char *buf = malloc(sz), *rb = malloc(sz);
	int rc = -1;
	if (!buf || !rb) { free(buf); free(rb); return -1; }
	for (size_t i = 0; i < sz; i++)
		buf[i] = compressible ? (char)('A' + ((i >> 6) + seed) % 7)
				      : (char)(seed * 2654435761u + i * 131u);
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { rc = -2; goto out; }
	for (size_t off = 0; off < sz; ) {
		ssize_t r = write(fd, buf + off, sz - off);
		if (r <= 0) { rc = -3; goto out_fd; }
		off += r;
	}
	if (fsync(fd)) { rc = -4; goto out_fd; }
	void *m = mmap(NULL, sz, PROT_READ, MAP_PRIVATE, fd, 0);
	if (m != MAP_FAILED) { int bad = memcmp(m, buf, sz); munmap(m, sz);
			       if (bad) { rc = -10; goto out_fd; } }
	lseek(fd, 0, SEEK_SET);
	for (size_t off = 0; off < sz; ) {
		ssize_t r = read(fd, rb + off, sz - off);
		if (r <= 0) { rc = -5; goto out_fd; }
		off += r;
	}
	rc = memcmp(buf, rb, sz) ? -11 : 0;
out_fd:	close(fd);
out:	free(buf); free(rb);
	return rc;
}

static void worker(int wkr, const char *dir, int compressible)
{
	const size_t sizes[] = { 4096, 65536, 262144, 1u<<20, 4u<<20 };
	char path[96];
	for (int it = 0; it < 120; it++) {
		for (unsigned s = 0; s < sizeof(sizes)/sizeof(sizes[0]); s++) {
			snprintf(path, sizeof path, "%s/w%d_%u.dat", dir, wkr, s);
			int rc = do_file(path, sizes[s], (unsigned)(wkr*100003 + it*7 + s), compressible);
			if (rc == -10 || rc == -11) { Wf(MARK ": CORRUPT %s wkr=%d it=%d sz=%zu rc=%d\n", dir, wkr, it, sizes[s], rc); _exit(7); }
			if (rc < 0)               { Wf(MARK ": IOERR %s wkr=%d it=%d sz=%zu rc=%d errno=%d\n", dir, wkr, it, sizes[s], rc, errno); _exit(8); }
			unlink(path);
		}
		if (wkr == 0 && it % 20 == 0) Wf(MARK ": hb %s it=%d\n", dir, it);
	}
	_exit(0);
}

int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	mkdir("/proc", 0755); mount("proc", "/proc", "proc", 0, 0);
	mkdir("/testdir", 0755);
	W(MARK ": btrfs top-level root mounted\n");

	/* create subvol "home" under / */
	int rootfd = open("/", O_RDONLY | O_DIRECTORY);
	struct btrfs_ioctl_vol_args va; memset(&va, 0, sizeof va);
	strcpy(va.name, "home");
	if (rootfd < 0 || ioctl(rootfd, BTRFS_IOC_SUBVOL_CREATE, &va) < 0)
		Wf(MARK ": SUBVOL_CREATE failed errno=%d (continuing plain)\n", errno);
	else
		W(MARK ": subvol 'home' created\n");
	if (rootfd >= 0) close(rootfd);

	/* mount it compressed at /home */
	mkdir("/home", 0755);
	int have_home = 0;
	if (mount("/dev/vda", "/home", "btrfs", 0, "subvol=home,compress=zstd") == 0) {
		W(MARK ": /home subvol mounted compress=zstd\n"); have_home = 1;
	} else {
		Wf(MARK ": /home subvol mount failed errno=%d\n", errno);
	}

	int nw = 6;
	for (int wkr = 0; wkr < nw; wkr++) {
		pid_t p = fork();
		if (p == 0) worker(wkr, "/testdir", 0);               /* plain */
	}
	if (have_home)
		for (int wkr = 0; wkr < nw; wkr++) {
			pid_t p = fork();
			if (p == 0) worker(100 + wkr, "/home", 1);    /* compressed */
		}

	int st, n = 0, fails = 0;
	while (wait(&st) > 0) { n++; if (!WIFEXITED(st) || WEXITSTATUS(st)) fails++; }
	Wf(MARK ": workers=%d fails=%d home=%d\n", n, fails, have_home);
	W(fails ? MARK ": FAIL\n" : MARK ": PASS\n");
	sync(); W(MARK ": halting\n");
	reboot(RB_POWER_OFF);
	for (;;) pause();
	return 0;
}
