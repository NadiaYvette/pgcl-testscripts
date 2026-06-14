/*
 * Minimal mips64 (n64 ABI, big-endian) init: write("MINIT\n") + exit_group(42).
 * Built non-PIC, no libc, no GOT.  Used to discriminate userspace vs
 * kernel cause of the PACK_PTE_PTLOCKS panic.
 */
        .text
        .globl  __start
        .set    noreorder
        .set    nomacro
__start:
        /* msg = (high 16) | (low 16) of msg address */
        lui     $a1, %hi(msg)
        daddiu  $a1, $a1, %lo(msg)
        li      $a0, 1                  /* fd */
        li      $a2, 6                  /* count */
        li      $v0, 5001               /* __NR_write */
        syscall

        li      $a0, 42                 /* exit_group(42) */
        li      $v0, 5205               /* __NR_exit_group */
        syscall

        /* unreachable */
1:      b       1b
        nop

        .data
        .globl  msg
msg:    .ascii  "MINIT\n"
