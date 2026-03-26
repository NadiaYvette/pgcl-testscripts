/*
 * Alpha glibc TLS override — intercepts __libc_start_main to skip
 * the TLS assertion that fails on alpha with glibc 2.38+.
 *
 * HOW ALPHA _start CALLS US (with --no-relax linker flag):
 *   _start calls '__libc_start_main' via jsr (t12) with t12 correctly
 *   set to our function's address.  Our C function prologue runs normally.
 *
 * THE TLS PROBLEM:
 *   The real glibc __libc_start_main calls __libc_setup_tls() which:
 *   1. Calls __tls_pre_init_tp()
 *   2. Issues 'wruniq tp_address' to set the alpha thread pointer
 *   3. Calls __tls_init_tp() for set_tid_address etc.
 *   4. Calls _dl_allocate_tls_init() ← asserts in glibc 2.38+ on alpha
 *
 *   We skip this, so the thread pointer (from 'rduniq') is 0.
 *   glibc's __syscall_cancel does: errno_addr = rduniq + 64; *errno_addr = err.
 *   With tp=0 this writes to address 64 → SIGSEGV.
 *
 * THE FIX:
 *   Issue 'wruniq' ourselves pointing to a static TLS block large enough
 *   to cover all glibc TLS accesses (at minimum: errno at tp+64, plus
 *   pthread/locale state).  Then skip the assertion-triggering
 *   _dl_allocate_tls_init path entirely.
 *
 *   We must use '--no-relax' at link time so _start calls us via
 *   jsr (t12) (not the relaxed bsr +8 form) to get correct t12/GP.
 *
 * EXIT PATH:
 *   We call fflush(NULL) then _exit() instead of exit() to avoid
 *   glibc's cleanup path which also hits TLS assertion code.
 */

#include <stdio.h>
#include <unistd.h>
#include <stddef.h>

/*
 * Static TLS block.  Must be large enough for all glibc internal TLS.
 * glibc alpha uses:
 *   tp + 64  = errno
 *   tp - ... = various pthread/locale fields
 * Allocate 8KB aligned to 64 bytes; set thread pointer to the MIDDLE
 * so both positive and negative offsets from tp land in the block.
 */
static char __alpha_tls_block[8192] __attribute__((aligned(64)));

/* Set the alpha thread unique register (PALcode wruniq).
 * a0 = value to store in pcb.unique (= what rduniq will return). */
static void __attribute__((noinline)) set_tp(void *tp)
{
	register void *a0 __asm__("$16") = tp;
	__asm__ volatile(".long 0x9f\n\t"   /* wruniq: PALcode 0x9f */
		: : "r"(a0) : "memory");
}

/* Override __libc_start_main: set up a minimal TLS block, call main,
 * flush stdio, then _exit() without going through glibc cleanup. */
int __libc_start_main(int (*main)(int, char **, char **),
		      int argc, char **argv,
		      void *init, void *fini, void *rtld_fini,
		      void *stack_end)
{
	(void)init; (void)fini; (void)rtld_fini; (void)stack_end;

	/* Point the thread pointer at the middle of our static block.
	 * This gives 4KB of headroom in both directions from tp. */
	set_tp(__alpha_tls_block + 4096);

	int ret = main(argc, argv, NULL);

	/* Flush stdio buffers without calling exit() (avoids TLS assertion). */
	fflush(NULL);
	_exit(ret);
}
