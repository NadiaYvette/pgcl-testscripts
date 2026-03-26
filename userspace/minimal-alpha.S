/*
 * Absolute minimal alpha test — write(1, "ok\n", 3) then exit(0)
 * NO GOT, NO GP, NO DATA SEGMENT.
 * Compile: alpha-linux-gnu-gcc -static -nostdlib -nostartfiles
 *          -o minimal-alpha minimal-alpha.S
 */
	.text
	.globl _start
	.ent _start
_start:
	/* write(1, buf, 3) */
	lda	$0, 4		/* __NR_write */
	lda	$16, 1		/* fd = 1 (stdout) */
	lda	$17, msg($31)	/* buf (PC-relative would be nice; use .rdata) */
	lda	$18, 4		/* len = 4 */
	callsys
	/* exit(0) */
	lda	$0, 1		/* __NR_exit */
	lda	$16, 0
	callsys
1:	br	1b
	.end _start

	.section .rodata
msg:	.ascii "ok\n\n"
