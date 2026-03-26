/*
 * Minimal Alpha assembly init for PGCL test initramfs.
 * Avoids all libc/TLS/glibc dependencies.
 *
 * Alpha syscall ABI:
 *   $0  = syscall number (on entry/exit)
 *   $16-$21 = args
 *   callsys instruction
 *   return value in $0, error if $19 is nonzero (or $0 < 0 for some syscalls)
 *
 * We mount proc/sys/dev, then exec pgcl-test and pgcl-stress,
 * then power off.
 */
	.set noat
	.set noreorder

	.section .rodata
msg_boot:	.ascii "========================================\n PGCL Boot Test - alpha\n========================================\n"
msg_boot_len = . - msg_boot

msg_basic:	.ascii "\n--- Running PGCL basic tests ---\n"
msg_basic_len = . - msg_basic

msg_stress:	.ascii "\n--- Running PGCL stress tests ---\n"
msg_stress_len = . - msg_stress

msg_pass:	.ascii "\nALL TESTS PASSED\n"
msg_pass_len = . - msg_pass

msg_fail:	.ascii "\nSOME TESTS FAILED\n"
msg_fail_len = . - msg_fail

msg_poweroff:	.ascii "\nPowering off...\n"
msg_poweroff_len = . - msg_poweroff

pgcl_test_path:	.asciz "/bin/pgcl-test"
pgcl_stress_path: .asciz "/bin/pgcl-stress"

proc_path:	.asciz "/proc"
sys_path:	.asciz "/sys"
dev_path:	.asciz "/dev"
tmp_path:	.asciz "/tmp"
proc_fs:	.asciz "proc"
sysfs_fs:	.asciz "sysfs"
devtmpfs_fs:	.asciz "devtmpfs"
tmpfs_fs:	.asciz "tmpfs"

	.text
	.globl _start
	.ent _start
_start:
	/* Set up a proper stack frame */
	lda	$sp, -64($sp)

	/* Mount proc */
	lda	$16, proc_fs
	lda	$17, proc_path
	lda	$18, proc_fs
	lda	$19, 0
	lda	$20, 0
	lda	$0, 21		/* __NR_mount */
	callsys

	/* Mount sysfs */
	lda	$16, sysfs_fs
	lda	$17, sys_path
	lda	$18, sysfs_fs
	lda	$19, 0
	lda	$20, 0
	lda	$0, 21
	callsys

	/* Mount devtmpfs */
	lda	$16, devtmpfs_fs
	lda	$17, dev_path
	lda	$18, devtmpfs_fs
	lda	$19, 0
	lda	$20, 0
	lda	$0, 21
	callsys

	/* Mount tmpfs */
	lda	$16, tmpfs_fs
	lda	$17, tmp_path
	lda	$18, tmpfs_fs
	lda	$19, 0
	lda	$20, 0
	lda	$0, 21
	callsys

	/* Write boot message */
	lda	$16, 1		/* stdout */
	lda	$17, msg_boot
	lda	$18, msg_boot_len
	lda	$0, 4		/* __NR_write */
	callsys

	/* Call run("/bin/pgcl-test") */
	lda	$16, msg_basic
	lda	$17, msg_basic_len
	bsr	$26, write_msg
	lda	$16, pgcl_test_path
	bsr	$26, run_prog

	/* Save return code in $9 */
	mov	$0, $9

	/* Call run("/bin/pgcl-stress") */
	lda	$16, msg_stress
	lda	$17, msg_stress_len
	bsr	$26, write_msg
	lda	$16, pgcl_stress_path
	bsr	$26, run_prog

	/* OR the two return codes */
	bis	$9, $0, $9

	/* Print pass/fail */
	bne	$9, print_fail
	lda	$16, msg_pass
	lda	$17, msg_pass_len
	bsr	$26, write_msg
	br	do_poweroff
print_fail:
	lda	$16, msg_fail
	lda	$17, msg_fail_len
	bsr	$26, write_msg

do_poweroff:
	lda	$16, msg_poweroff
	lda	$17, msg_poweroff_len
	bsr	$26, write_msg

	/* reboot(LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, CMD_POWER_OFF) */
	ldah	$16, -19912($31)	/* 0xfee1dead = LINUX_REBOOT_MAGIC1 */
	lda	$16, -8483($16)
	ldah	$17, 1397948($31)	/* 0x28121969 = LINUX_REBOOT_MAGIC2 (approx) */
	lda	$17, 6505($17)
	lda	$18, 0x4321fedc		/* LINUX_REBOOT_CMD_POWER_OFF */
	lda	$0, 56		/* __NR_reboot */
	callsys

	/* Should not reach here */
1:	br	1b

	/* write_msg($16=ptr, $17=len): writes to stdout, clobbers $0, $19 */
write_msg:
	mov	$16, $17	/* move ptr -> $17 already set... wait */
	/* On entry: $16=ptr, $17=len, $26=return addr */
	/* Alpha write syscall: $16=fd, $17=buf, $18=count */
	mov	$17, $18	/* len -> $18 */
	mov	$16, $17	/* ptr -> $17 */
	lda	$16, 1		/* fd = 1 (stdout) */
	lda	$0, 4		/* __NR_write */
	callsys
	ret	$31, ($26), 1

	/* run_prog($16=path): fork+exec, returns exit code in $0 */
run_prog:
	mov	$16, $9		/* save path in $9 (callee-saved) */
	lda	$0, 2		/* __NR_fork */
	callsys
	bne	$0, parent_wait	/* if ret != 0, we're parent */

	/* child: exec the program */
	/* execve($16=path, $17=argv, $18=envp) */
	mov	$9, $16
	/* argv = {path, NULL} - put on stack */
	lda	$sp, -32($sp)
	stq	$9, 0($sp)
	stq	$31, 8($sp)
	mov	$sp, $17	/* argv */
	lda	$sp, -8($sp)
	stq	$31, 0($sp)
	mov	$sp, $18	/* envp = {NULL} */
	lda	$0, 59		/* __NR_execve */
	callsys
	/* execve failed — exit(1) */
	lda	$16, 1
	lda	$0, 1		/* __NR_exit */
	callsys

parent_wait:
	mov	$0, $10		/* save child pid in $10 */
	/* waitpid(pid, &status, 0) */
	mov	$10, $16
	lda	$sp, -16($sp)
	mov	$sp, $17	/* &status */
	lda	$18, 0
	lda	$0, 114		/* __NR_wait4 */
	callsys
	/* get exit status from stack */
	ldl	$0, 0($sp)
	lda	$sp, 16($sp)
	/* Extract exit code: (status >> 8) & 0xff */
	srl	$0, 8, $0
	and	$0, 0xff, $0
	ret	$31, ($26), 1
	.end _start
