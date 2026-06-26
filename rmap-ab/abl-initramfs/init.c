/* minimal PID1 for the #143 ablation initramfs: mount btrfs(/dev/vdc), read
 * rr_* ablation knobs from /proc/cmdline -> env, run /repro on /mnt, poweroff. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <linux/reboot.h>

static void knob(const char *cmd, const char *tok, const char *env)
{
	if (strstr(cmd, tok)) setenv(env, "1", 1);
}

int main(void)
{
	mkdir("/proc", 0755); mkdir("/sys", 0755); mkdir("/dev", 0755); mkdir("/mnt", 0755);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

	int c = open("/dev/console", O_RDWR);
	if (c >= 0) { dup2(c, 0); dup2(c, 1); dup2(c, 2); if (c > 2) close(c); }

	printf("\nINIT: ablation initramfs up; swapon /dev/vdb, mount btrfs /dev/vda\n"); fflush(stdout);
	if (syscall(SYS_swapon, "/dev/vdb", 0) != 0)
		perror("INIT: swapon /dev/vdb (continuing)");
	if (mount("/dev/vda", "/mnt", "btrfs", 0, NULL) != 0) {
		perror("INIT: mount btrfs /dev/vda -> /mnt FAILED");
		sync(); reboot(LINUX_REBOOT_CMD_POWER_OFF); return 1;
	}

	char cmd[4096] = {0};
	int fd = open("/proc/cmdline", O_RDONLY);
	if (fd >= 0) { if (read(fd, cmd, sizeof cmd - 1) < 0) {} close(fd); }
	knob(cmd, "rr_nofork", "RR_NOFORK");
	knob(cmd, "rr_nocow",  "RR_NOCOW");
	knob(cmd, "rr_nohog",  "RR_NOHOG");
	knob(cmd, "rr_nofadv", "RR_NOFADV");
	printf("INIT: cmdline=%s\n", cmd); fflush(stdout);

	pid_t p = fork();
	if (p == 0) {
		/* dir secs workers hogMB fileMB */
		execl("/repro", "/repro", "/mnt", "120", "10", "2048", "4", (char *)NULL);
		perror("INIT: exec /repro"); _exit(127);
	}
	int st = 0;
	if (p > 0) waitpid(p, &st, 0);
	printf("INIT: repro done status=0x%x; powering off\n", st); fflush(stdout);
	sync();
	reboot(LINUX_REBOOT_CMD_POWER_OFF);
	return 0;
}
