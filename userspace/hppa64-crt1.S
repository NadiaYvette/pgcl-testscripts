/*
 * Custom crt1.o for hppa64 static binaries.
 *
 * Replaces glibc's crt1.o which uses r19 (linkage table pointer) to find
 * main's function descriptor. In static binaries, the kernel doesn't set r19,
 * so glibc's _start crashes with a NULL dereference.
 *
 * This version bootstraps dp (global data pointer r27) via PC-relative
 * relocations (R_PARISC_PCREL21L/14R, same as glibc's crt1.o), sets up TLS
 * via __pgcl_setup_tls_asm, then calls main directly without function
 * descriptors.
 *
 * Kernel sets up: r25=argc, r24=argv, r30=sp, r23=0
 * We call: __pgcl_setup_tls_asm(), then main(argc, argv, envp)
 */
	.level 2.0w
	.text
	.align 8
	.globl _start
	.type _start, @function
_start:
	/* Clear frame marker */
	stw	%r0, -4(%sp)

	/* Bootstrap dp (r27) via PC-relative addressing.
	 * Uses $PIC_pcrel$0 convention for proper PCREL relocations.
	 * b,l sets dp = address of $PIC_pcrel$0 label.
	 * addil/ldo compute dp = __gp using PCREL21L/14R relocs. */
	b,l	.Lpc_target, %dp
	addil	L%__gp - ($PIC_pcrel$0 - 4), %dp
.Lpc_target:
$PIC_pcrel$0:
	ldo	R%__gp - ($PIC_pcrel$0 - 8)(%r1), %dp

	/* Allocate stack frame: 128 bytes for 64-bit PA-RISC ABI */
	ldo	128(%sp), %sp
	stw	%r0, -4(%sp)

	/* Save argc, argv, dp across calls.
	 * Kernel: r25=argc, r24=argv (from start_thread get_user) */
	copy	%r25, %r3		/* r3 = argc */
	copy	%r24, %r5		/* r5 = argv */
	copy	%dp, %r4		/* r4 = dp (save across calls) */

	/* Set up TLS before calling any glibc function.
	 * __pgcl_setup_tls_asm allocates TLS block + sets cr27 via gateway. */
	b,l	__pgcl_setup_tls_asm, %rp
	nop
	copy	%r4, %dp		/* restore dp after call */

	/* Call main(argc, argv, envp)
	 * envp = argv + (argc+1)*8 (skip argv[] array + NULL terminator) */
	copy	%r3, %r26		/* argc */
	copy	%r5, %r25		/* argv */
	ldo	1(%r3), %r24		/* argc + 1 */
	depd,z	%r24, 60, 61, %r24	/* (argc+1) << 3 = (argc+1)*8 */
	add,l	%r5, %r24, %r24		/* envp = argv + (argc+1)*8 */
	b,l	main, %rp
	nop
	copy	%r4, %dp		/* restore dp */

	/* exit_group(retval) */
	copy	%ret0, %r26
	ldi	222, %r20		/* __NR_exit_group */
	ble	0x100(%sr2, %r0)
	nop

	break	0, 0

	.size _start, . - _start
