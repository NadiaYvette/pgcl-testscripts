/*
 * Diagnostic: test VmLck reporting via /proc/self/status
 * Tests both direct sscanf and vsscanf-via-va_list approaches.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* Direct sscanf approach (no va_list) */
static long read_vmlck_direct(void)
{
	FILE *fp;
	char line[256];
	long val = -1;

	fp = fopen("/proc/self/status", "r");
	if (!fp) return -1;
	while (fgets(line, sizeof(line), fp)) {
		if (sscanf(line, "VmLck: %ld", &val) == 1)
			break;
	}
	fclose(fp);
	return val;
}

/* vsscanf approach via va_list (simulates LTP stub) */
static int scan_via_vsscanf(const char *line, const char *fmt, ...)
{
	va_list ap;
	int ret;
	va_start(ap, fmt);
	ret = vsscanf(line, fmt, ap);
	va_end(ap);
	return ret;
}

static long read_vmlck_vsscanf(void)
{
	FILE *fp;
	char line[256];
	long val = -1;

	fp = fopen("/proc/self/status", "r");
	if (!fp) return -1;
	while (fgets(line, sizeof(line), fp)) {
		long tmp = -999;
		if (scan_via_vsscanf(line, "VmLck: %ld", &tmp) == 1) {
			val = tmp;
			break;
		}
	}
	fclose(fp);
	return val;
}

/* Simulate LTP file_lines_scanf exactly */
static int file_lines_scanf_sim(const char *path, const char *fmt, ...)
{
	FILE *fp;
	char line[4096];
	va_list ap;
	int ret = 0;

	fp = fopen(path, "r");
	if (!fp) return 1;
	while (fgets(line, sizeof(line), fp)) {
		va_start(ap, fmt);
		ret = vsscanf(line, fmt, ap);
		va_end(ap);
		if (ret >= 1) break;
	}
	fclose(fp);
	return (ret >= 1) ? 0 : 1;
}

int main(void)
{
	long pgsz = sysconf(_SC_PAGESIZE);
	long before_direct, after_direct;
	long before_vsscanf, after_vsscanf;
	long before_sim = -1, after_sim = -1;
	char *addr;

	printf("=== VmLck Diagnostic ===\n");
	printf("pagesize=%ld\n", pgsz);

	/* First: dump all Vm* lines from /proc/self/status */
	{
		FILE *fp = fopen("/proc/self/status", "r");
		char line[256];
		if (!fp) {
			printf("FAIL: cannot open /proc/self/status\n");
			return 1;
		}
		printf("--- /proc/self/status Vm lines ---\n");
		while (fgets(line, sizeof(line), fp)) {
			if (line[0] == 'V' && line[1] == 'm') {
				/* Print with visible whitespace */
				printf("  [");
				for (int i = 0; line[i] && line[i] != '\n'; i++) {
					if (line[i] == '\t')
						printf("\\t");
					else
						putchar(line[i]);
				}
				printf("]\n");
			}
		}
		fclose(fp);
		printf("---\n");
	}

	/* Also test basic sscanf matching */
	{
		char test[] = "VmLck:\t       0 kB\n";
		long tval = -999;
		int r = sscanf(test, "VmLck: %ld", &tval);
		printf("sscanf test (hardcoded): ret=%d val=%ld\n", r, tval);
	}

	/* Read VmLck before mlock */
	before_direct = read_vmlck_direct();
	before_vsscanf = read_vmlck_vsscanf();
	file_lines_scanf_sim("/proc/self/status", "VmLck: %ld", &before_sim);

	printf("Before mlock:\n");
	printf("  direct sscanf:   VmLck = %ld kB\n", before_direct);
	printf("  vsscanf:         VmLck = %ld kB\n", before_vsscanf);
	printf("  sim stub:        VmLck = %ld kB\n", before_sim);

	/* mmap + mlock one page */
	addr = mmap(NULL, pgsz, PROT_READ | PROT_WRITE,
		    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (addr == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	addr[0] = 1; /* fault in */
	if (mlock(addr, pgsz) != 0) {
		perror("mlock");
		return 1;
	}

	/* Read VmLck after mlock */
	after_direct = read_vmlck_direct();
	after_vsscanf = read_vmlck_vsscanf();
	file_lines_scanf_sim("/proc/self/status", "VmLck: %ld", &after_sim);

	printf("After mlock(%ld bytes):\n", pgsz);
	printf("  direct sscanf:   VmLck = %ld kB (delta=%ld)\n",
		after_direct, after_direct - before_direct);
	printf("  vsscanf:         VmLck = %ld kB (delta=%ld)\n",
		after_vsscanf, after_vsscanf - before_vsscanf);
	printf("  sim stub:        VmLck = %ld kB (delta=%ld)\n",
		after_sim, after_sim - before_sim);

	/* Also dump the actual VmLck line for inspection */
	{
		FILE *fp = fopen("/proc/self/status", "r");
		char line[256];
		if (fp) {
			while (fgets(line, sizeof(line), fp)) {
				if (strncmp(line, "VmLck:", 6) == 0) {
					printf("  raw line: [%s]\n", line);
					printf("  hex dump: ");
					for (int i = 0; line[i] && i < 40; i++)
						printf("%02x ", (unsigned char)line[i]);
					printf("\n");
					break;
				}
			}
			fclose(fp);
		}
	}

	long expected_delta = pgsz / 1024; /* pgsz bytes = pgsz/1024 kB */
	int pass = 1;
	if (after_direct - before_direct != expected_delta) {
		printf("FAIL: direct sscanf delta %ld != expected %ld\n",
			after_direct - before_direct, expected_delta);
		pass = 0;
	}
	if (after_vsscanf - before_vsscanf != expected_delta) {
		printf("FAIL: vsscanf delta %ld != expected %ld\n",
			after_vsscanf - before_vsscanf, expected_delta);
		pass = 0;
	}
	if (after_sim - before_sim != expected_delta) {
		printf("FAIL: sim stub delta %ld != expected %ld\n",
			after_sim - before_sim, expected_delta);
		pass = 0;
	}

	if (pass)
		printf("PASS: all methods show correct VmLck delta\n");

	munlock(addr, pgsz);
	munmap(addr, pgsz);
	return pass ? 0 : 1;
}
