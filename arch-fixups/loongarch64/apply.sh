#!/bin/bash
# loongarch64 — ESP-disk EFI boot.  EDK2 20260213+ broke fw_cfg -kernel
# loading on this arch (per MEMORY.md S50).  Workaround: package vmlinuz.efi
# inside a FAT32 ESP as BOOTLOONGARCH64.EFI on a GPT disk image and boot via
# `-drive file=disk.img,format=raw,if=virtio`.  Driver implements the disk
# packaging when BOOT_STYLE=esp.
scripts/config --file "$KBUILD/.config" \
    --enable BLK_DEV_INITRD \
    --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-loongarch64.cpio.gz" \
    --set-str CMDLINE "console=ttyS0,115200 panic=1 autotest=1" \
    --enable CMDLINE_BOOL --enable EFI_STUB

EMBEDDED_INITRD=1
BOOT_STYLE=esp
