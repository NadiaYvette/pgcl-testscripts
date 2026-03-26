/*
 * Alpha __libc_start_main override in assembly.
 *
 * On alpha, _start calls __libc_start_main via 'bsr ra, __libc_start_main'
 * which does NOT set $27 (t12 / PV = Procedure Value register).  The C
 * compiler initialises GP as 'ldah gp, N($27)' in each function prologue,
 * so if $27 is stale (still _start's address) the computed GP is wrong, and
 * every GOT load in the function reads garbage.
 *
 * Fix: use 'br $27, 1f; 1: ldgp $29, 0($27)' to derive our own PC and set
 * GP correctly, regardless of what $27 contained on entry.
 *
 * Alpha register aliases used here:
 *   $0  = v0   (return value)
 *   $9  = s0   (callee-saved scratch)
 *   $10 = s1   (callee-saved scratch)
 *   $11 = s2   (callee-saved scratch)
 *   $16 = a0   (arg 0)
 *   $17 = a1   (arg 1)
 *   $18 = a2   (arg 2)
 *   $26 = ra   (return address)
 *   $27 = t12  (procedure value / called-function address)
 *   $29 = gp   (global pointer)
 *   $30 = sp   (stack pointer)
 *   $31 = zero (always zero)
 *
 * Arguments (__libc_start_main calling convention from glibc crt1.S):
 *   $16 = main function pointer
 *   $17 = argc
 *   $18 = argv
 *   $19 = init
 *   $20 = fini
 *   $21 = rtld_fini
 *   stack[0] = stack_end
 *
 * We call main(argc, argv, NULL) via jsr (with $27=main so the callee
 * can re-initialise its own GP), then call exit(retval) the same way.
 *
 * We must call exit() rather than returning: _start does 'bsr ...; halt'
 * so returning would hit 'halt' (illegal instruction) and kill the process
 * before stdio buffers are flushed.
 */

	.text
	.globl	__libc_start_main
	.ent	__libc_start_main
__libc_start_main:
	/*
	 * Step 1: fix GP using our own PC.
	 * 'br $27, .+4' sets $27 = address of the next instruction.
	 * 'ldgp $29, 0($27)' then computes GP = $27 + GOT_offset.
	 */
	br	$27, 1f
1:	ldgp	$29, 0($27)

	/*
	 * Step 2: set up a stack frame and save callee-saved registers.
	 *   $9  (s0) = main pointer  (from $16)
	 *   $10 (s1) = argc          (from $17)
	 *   $11 (s2) = argv          (from $18)
	 */
	lda	$30, -32($30)
	stq	$26,  0($30)		/* save ra */
	stq	$9,   8($30)		/* save s0 */
	stq	$10, 16($30)		/* save s1 */
	stq	$11, 24($30)		/* save s2 */

	bis	$16, $31, $9		/* s0 = main  (bis r,zero,dst = mov r,dst) */
	bis	$17, $31, $10		/* s1 = argc */
	bis	$18, $31, $11		/* s2 = argv */

	/*
	 * Step 3: call main(argc, argv, NULL) via jsr.
	 * $27 must equal main's address so main can initialise its own GP.
	 */
	bis	$9,  $31, $27		/* $27 = main */
	bis	$10, $31, $16		/* a0  = argc */
	bis	$11, $31, $17		/* a1  = argv */
	bis	$31, $31, $18		/* a2  = NULL (envp) */
	jsr	$26, ($27)		/* call main */
	ldgp	$29, 0($26)		/* restore GP after the indirect call */

	/*
	 * Step 4: call exit(return_value_of_main).
	 * Load exit's address from the GOT (now that GP is valid), put it
	 * in $27 so exit()'s prologue 'ldah gp, N($27)' works correctly.
	 */
	bis	$0, $31, $10		/* s1 = v0 (main's return value) */
	ldq	$27, exit($29)		!literal!1
	bis	$10, $31, $16		/* a0 = exit code */
	jsr	$26, ($27), exit	/* call exit — does not return */

	/* Unreachable safety net. */
	halt
	.end	__libc_start_main
