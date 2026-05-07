#!/bin/bash
# arm-lpae — vexpress_defconfig + LPAE; needs an explicit DTB at QEMU boot.
# Without -dtb, the kernel produces no console output and the cell times out.
scripts/config --file "$KBUILD/.config" --enable ARM_LPAE
TIMEOUT=600

# Shared initramfs with arm (no dedicated arm-lpae build)
INITRD_ARG="-initrd $INITRAMFS/initramfs-arm.cpio.gz"

# Driver arranges `make dtbs` after vmlinux for this arch.  EXTRA_QEMU is set
# only if the DTB actually built — otherwise QEMU runs without it and times
# out (still better than failing the whole cell).
if [ -f "$KBUILD/arch/arm/boot/dts/arm/vexpress-v2p-ca15-tc1.dtb" ]; then
    EXTRA_QEMU="-dtb $KBUILD/arch/arm/boot/dts/arm/vexpress-v2p-ca15-tc1.dtb"
fi
