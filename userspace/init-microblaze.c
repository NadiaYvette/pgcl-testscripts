/* Minimal init for microblaze test — runs pgcl-test, pgcl-stress, and mm-selftests */
#include <unistd.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <dirent.h>

static void write_str(int fd, const char *s)
{
	write(fd, s, strlen(s));
}

static int run_program(const char *path, const char *arg)
{
	pid_t pid = fork();
	if (pid < 0) {
		write_str(2, "FAIL: fork() failed\n");
		return -1;
	}
	if (pid == 0) {
		char *argv[] = { (char *)path, arg ? (char *)arg : NULL, NULL };
		char *envp[] = { "HOME=/", "TERM=linux", NULL };
		execve(path, argv, envp);
		write_str(2, "FAIL: execve failed for ");
		write_str(2, path);
		write_str(2, "\n");
		_exit(127);
	}
	int status;
	waitpid(pid, &status, 0);
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

int main(void)
{
	int rc, fd;

	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("tmpfs", "/tmp", "tmpfs", 0, NULL);

	/* Redirect stdio to console */
	fd = open("/dev/console", 2 /* O_RDWR */);
	if (fd >= 0) {
		dup2(fd, 0);
		dup2(fd, 1);
		dup2(fd, 2);
		if (fd > 2) close(fd);
	}

	write_str(1, "\n========================================\n");
	write_str(1, " PGCL Boot Test - microblaze\n");
	write_str(1, "========================================\n");

	write_str(1, "--- Running PGCL basic tests ---\n");
	rc = run_program("/bin/pgcl-test", "-a");
	if (rc == 0)
		write_str(1, "pgcl-test: ALL PASSED\n");
	else
		write_str(1, "pgcl-test: SOME FAILED\n");

	write_str(1, "--- Running PGCL stress tests ---\n");
	rc = run_program("/bin/pgcl-stress", "-a");
	if (rc == 0)
		write_str(1, "pgcl-stress: ALL PASSED\n");
	else
		write_str(1, "pgcl-stress: SOME FAILED\n");

	/* Run mm selftests */
	DIR *d = opendir("/bin/mm-selftests");
	if (d) {
		write_str(1, "--- Running kernel mm selftests ---\n");
		struct dirent *ent;
		while ((ent = readdir(d)) != NULL) {
			if (ent->d_name[0] == '.')
				continue;
			/* Skip known-problematic tests and .o files */
			if (strcmp(ent->d_name, "droppable") == 0 ||
			    strcmp(ent->d_name, "mseal_test") == 0)
				continue;
			int len = strlen(ent->d_name);
			if (len > 2 && ent->d_name[len-2] == '.' && ent->d_name[len-1] == 'o')
				continue;
			char path[256];
			snprintf(path, sizeof(path), "/bin/mm-selftests/%s", ent->d_name);
			struct stat st;
			if (stat(path, &st) != 0 || !(st.st_mode & S_IXUSR))
				continue;
			write_str(1, "  [");
			write_str(1, ent->d_name);
			write_str(1, "]\n");
			rc = run_program(path, NULL);
			if (rc == 0) {
				write_str(1, "  ");
				write_str(1, ent->d_name);
				write_str(1, ": PASS\n");
			} else if (rc == 4) {
				write_str(1, "  ");
				write_str(1, ent->d_name);
				write_str(1, ": SKIP\n");
			} else {
				write_str(1, "  ");
				write_str(1, ent->d_name);
				write_str(1, ": FAIL\n");
			}
		}
		closedir(d);
	}

	write_str(1, "\n========================================\n");
	write_str(1, " Test Complete\n");
	write_str(1, "========================================\n");

	sync();
	reboot(0x4321fedc); /* RB_POWER_OFF */
	return 0;
}
