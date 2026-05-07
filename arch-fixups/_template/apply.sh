#!/bin/bash
# arch-fixups/<arch>/apply.sh — sourced by matrix-driver-all.sh
#
# Available read-only inputs:
#   $KBUILD     — kernel build dir
#   $ARCH       — matrix arch name
#   $LA         — kernel ARCH=
#   $CC         — CROSS_COMPILE= (may be empty)
#   $INITRAMFS  — initramfs dir
#   $CONFIG     — mainline / 0 / 2 / 4 / 6
#
# Variables you may set (default to empty / generic in the driver):
#   TIMEOUT             — QEMU wall-clock seconds (default 300)
#   INITRD_ARG          — overrides default `-initrd $INITRAMFS/initramfs-$ARCH.cpio.gz`
#   EXTRA_QEMU          — additional QEMU args
#   EMBEDDED_INITRD     — set to 1 if initramfs is embedded (no -initrd)
#   BOOT_STYLE          — `default` or `esp` (FAT32 disk + EFI)
#   EXTRA_CC_PATH       — prepended to PATH for pinned cross-toolchains

# Example: enable a Kconfig option
# scripts/config --file "$KBUILD/.config" --enable SOME_OPTION

# Example: set a timeout
# TIMEOUT=900
