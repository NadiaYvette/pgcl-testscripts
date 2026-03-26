/*
 * Minimal CRT startup for hppa64 (PA-RISC 2.0 64-bit) Linux static binaries.
 *
 * PA-RISC stack grows UP. Kernel places argc/argv/envp/auxv at initial sp.
 * Layout: [argc][argv[0]][argv[1]]...[NULL][envp[0]]...[NULL][auxv pairs...]
 * Each element is 8 bytes (64-bit).
 *
 * We call __minilib_start(sp) which parses the stack and calls main().
 */
	.level 2.0w
	.text
	.align 8
	.globl _start
	.type _start, @function
_start:
	/* Pass original sp as first argument to __minilib_start */
	copy %r30, %r26

	/* Allocate 128 bytes of stack frame (PA-RISC stack grows up) */
	ldo 128(%r30), %r30

	/* Call __minilib_start(orig_sp) */
	bl __minilib_start, %r2
	nop

	/* exit_group(retval) */
	copy %r28, %r26
	ldi 222, %r20
	ble 0x100(%sr2, %r0)
	nop

	b .
	nop

	.size _start, . - _start
