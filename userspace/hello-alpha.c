/*
 * Minimal alpha hello world with our TLS override.
 * Compile: alpha-linux-gnu-gcc -static -O2 --sysroot=... -Wl,--allow-multiple-definition
 *          -o hello-alpha tls-override-alpha.c hello-alpha.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void)
{
	/* Test 1: basic printf */
	printf("Hello from alpha userspace!\n");
	fflush(stdout);

	/* Test 2: basic mmap */
	void *p = mmap(NULL, 4096, PROT_READ|PROT_WRITE,
		       MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		printf("mmap failed!\n");
		return 1;
	}
	*(volatile char *)p = 42;
	if (*(volatile char *)p != 42) {
		printf("mmap store/load failed!\n");
		return 1;
	}
	munmap(p, 4096);
	printf("mmap OK\n");

	/* Test 3: fork */
	pid_t pid = fork();
	if (pid < 0) {
		printf("fork failed!\n");
		return 1;
	}
	if (pid == 0) {
		printf("child alive\n");
		exit(0);
	}
	printf("fork OK, parent continuing\n");

	printf("All basic tests passed!\n");
	return 0;
}
