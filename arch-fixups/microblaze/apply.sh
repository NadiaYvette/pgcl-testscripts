#!/bin/bash
# microblaze — embedded initramfs (CONFIG_INITRAMFS_SOURCE), big-endian default.
# Per MEMORY.md: QEMU microblaze silent boot is an open QEMU/kernel infra
# issue even with this BE config.  Builds work; runtime hangs.
scripts/config --file "$KBUILD/.config" \
    --enable CPU_BIG_ENDIAN --disable CPU_LITTLE_ENDIAN \
    --enable BLK_DEV_INITRD \
    --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-microblaze.cpio.gz" \
    --set-str CMDLINE "console=ttyUL0 panic=1 autotest=1" --enable CMDLINE_BOOL

EMBEDDED_INITRD=1
TIMEOUT=1500
