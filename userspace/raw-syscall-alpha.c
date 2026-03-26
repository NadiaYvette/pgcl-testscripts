/*
 * Raw syscall test for alpha — no libc, no TLS, no GOT.
 * Compile: alpha-linux-gnu-gcc -static -O2 -nostdlib -nostartfiles -fno-builtin
 *          -fno-plt -fno-pic
 *          -o raw-alpha raw-syscall-alpha.c -lgcc
 */

/* Alpha syscall: number in $0, args in $16-$21, callsys */
static long __attribute__((noinline))
do_write(const char *buf, long len)
{
	register long v0 __asm__("$0") = 4; /* __NR_write */
	register long a0 __asm__("$16") = 1;
	register long a1 __asm__("$17") = (long)buf;
	register long a2 __asm__("$18") = len;
	register long a3 __asm__("$19");
	__asm__ volatile("callsys"
		: "=r"(v0), "=r"(a3)
		: "r"(v0), "r"(a0), "r"(a1), "r"(a2)
		: "memory");
	return v0;
}

static void __attribute__((noinline))
do_exit(long code)
{
	register long v0 __asm__("$0") = 1; /* __NR_exit */
	register long a0 __asm__("$16") = code;
	__asm__ volatile("callsys" : : "r"(v0), "r"(a0));
	__builtin_unreachable();
}

void pgcl_raw_main(void);

__asm__(
	".globl _start\n"
	".ent _start\n"
	"_start:\n"
	/* GP setup for static binary */
	"	br $27, .+4\n"	/* $27 = PC of next instruction */
	"	ldgp $29, 0($27)\n"	/* sets $gp relative to $27 */
	"	bis $31, $31, $fp\n"
	"	lda $sp, -16($sp)\n"
	"	bsr $26, pgcl_raw_main\n"
	"1:	br 1b\n"
	".end _start\n"
);

static const char msg1[] = "raw: step1 before mmap\n";
static const char msg2[] = "raw: step2 after mmap\n";
static const char msg3[] = "raw: step3 mmap ok\n";
static const char msg_fail[] = "raw: FAIL\n";
static const char msg_done[] = "raw: ALL OK\n";

void pgcl_raw_main(void)
{
	do_write(msg1, sizeof(msg1)-1);

	/* mmap anonymous */
	register long v0 __asm__("$0") = 197; /* __NR_mmap */
	register long a0 __asm__("$16") = 0;  /* addr = NULL */
	register long a1 __asm__("$17") = 8192; /* len = 8KB */
	register long a2 __asm__("$18") = 3; /* PROT_READ|PROT_WRITE */
	register long a3 __asm__("$19") = 0x22; /* MAP_PRIVATE|MAP_ANONYMOUS */
	register long a4 __asm__("$20") = -1; /* fd = -1 */
	register long a5 __asm__("$21") = 0; /* offset = 0 */
	__asm__ volatile("callsys"
		: "=r"(v0), "=r"(a3)
		: "r"(v0), "r"(a0), "r"(a1), "r"(a2), "r"(a3), "r"(a4), "r"(a5)
		: "memory");
	long p = v0;

	do_write(msg2, sizeof(msg2)-1);

	if (p < 0 || p == -1) {
		do_write(msg_fail, sizeof(msg_fail)-1);
		do_exit(1);
	}

	/* Touch the page */
	*(volatile long *)p = 0xdeadbeef;

	do_write(msg3, sizeof(msg3)-1);
	do_write(msg_done, sizeof(msg_done)-1);
	do_exit(0);
}
