/* Minimal _start for hppa64 static binaries.
 * Initializes dp (r27 = global data pointer) and calls main().
 * The kernel ABI: argc at sp[0], argv at sp[8].
 */

	.level 2.0w
	.text
	.align 8
	.globl _start
	.type _start, @function
_start:
	/* b,l stores return address (PC after delay slot) in dp.
	 * After this: dp = address of $PIC_pcrel$0.
	 * The addil in delay slot uses this new dp value.
	 */
	b,l	.+8, %dp
	addil	L'__gp - $PIC_pcrel$0, %dp
$PIC_pcrel$0:
	ldo	R'__gp - $PIC_pcrel$0(%r1), %dp

	/* Load argc and argv from stack */
	ldw	0(%sp), %r26		/* argc */
	ldo	8(%sp), %r25		/* argv = sp + 8 */

	/* Allocate stack frame (PA-RISC 64-bit ABI: 128-byte minimum) */
	ldo	128(%sp), %sp

	/* Zero the frame marker area */
	stw	%r0, -4(%sp)
	stw	%r0, -8(%sp)

	/* Call main(argc, argv) */
	b,l	main, %rp
	nop

	/* Call _exit(retval) - return value in r28 (ret0) */
	copy	%ret0, %r26
	b,l	_exit, %rp
	nop

	/* Should not reach here */
	break	0, 0

	.size _start, . - _start
