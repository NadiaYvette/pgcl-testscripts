#!/bin/bash
# mips64 — Malta defconfig + 64BIT R2 BE + embedded initramfs.
# Per MEMORY.md: QEMU mips Malta emulation is ~10x slower than other arches;
# external -initrd hits reserved memory at top of RAM, embedded works.
scripts/config --file "$KBUILD/.config" \
    --enable 64BIT --enable CPU_MIPS64_R2 \
    --enable CPU_BIG_ENDIAN --disable CPU_LITTLE_ENDIAN \
    --enable BLK_DEV_INITRD \
    --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-mips64.cpio.gz" \
    --set-str CMDLINE "console=ttyS0 panic=1 autotest=1" --enable CMDLINE_BOOL

EMBEDDED_INITRD=1
TIMEOUT=1800
