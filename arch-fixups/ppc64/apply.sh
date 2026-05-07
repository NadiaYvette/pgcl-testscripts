#!/bin/bash
# ppc64 — force PPC_4K_PAGES.  PGCL with PPC_64K_PAGES + MMUSHIFT=4 yields
# 1MB kernel pages, exceeding slab `oo_make()` capacity (per MEMORY.md S60+).
# 4K base + MMUSHIFT=4 → 64KB kernel pages — same effective page size as
# other arches at PGCL=4 and within slab/blk-layer limits.
scripts/config --file "$KBUILD/.config" \
    --enable PPC_4K_PAGES --disable PPC_64K_PAGES --disable PPC_16K_PAGES

# Initramfs filename mismatch: ppc64 arch name vs powerpc64 cpio file
INITRD_ARG="-initrd $INITRAMFS/initramfs-powerpc64.cpio.gz"

TIMEOUT=400
