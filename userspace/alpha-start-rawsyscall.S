    .text
    .globl _start
    .ent _start
_start:
    /* Derive GP from PC */
    br      $27, 1f
1:  ldgp    $29, 0($27)

    /* Set up stack */
    lda     $30, -16($30)
    stq     $26, 0($30)

    /* Write "A\n" using PC-relative data */
    lda     $16, 1          /* fd = stdout */
    br      $17, 2f
    .ascii  "A\n"
    .align  3
2:
    lda     $18, 2          /* len */
    lda     $0, 4           /* __NR_write */
    callsys

    /* Re-derive GP (callsys clobbers registers, gp is callee-saved but be safe) */
    br      $27, 3f
3:  ldgp    $29, 0($27)

    /* wruniq(tls_block + 4096) — use literal reloc for GOT access */
    ldq     $16, __alpha_tls_block($29)   !literal!2
    lda     $16, 4096($16)                !lituse_base!2
    call_pal 0x9f

    /* Write "B\n" */
    lda     $16, 1
    br      $17, 4f
    .ascii  "B\n"
    .align  3
4:
    lda     $18, 2
    lda     $0, 4
    callsys

    /* Re-derive GP */
    br      $27, 5f
5:  ldgp    $29, 0($27)

    /* Call pgcl_init() */
    ldq     $27, pgcl_init($29)   !literal!1
    jsr     $26, ($27), pgcl_init !lituse_jsr!1
    ldgp    $29, 0($26)

    /* Write "C\n" */
    lda     $16, 1
    br      $17, 6f
    .ascii  "C\n"
    .align  3
6:
    lda     $18, 2
    lda     $0, 4
    callsys

    /* exit(0) */
    lda     $16, 0
    lda     $0, 1
    callsys
    halt
    .end _start

    .section .note.GNU-stack,"",@progbits
