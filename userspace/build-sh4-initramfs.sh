#!/bin/bash
# build-sh4-initramfs.sh — assemble the sh4 (r2d) matrix-cell initramfs TREE.
#
# Produces userspace/initramfs/sh4-ltp-root/ : a busybox-free root whose PID1
# (sh4-ltp-init.c) runs pgcl-test, a core LTP MM subset, then pgcl-stress, and
# powers off.  matrix-driver-all.sh embeds this DIR via CONFIG_INITRAMFS_SOURCE
# = "sh4-ltp-root sh4-nodes.txt" with kernel-side XZ compression.
#
# Why this shape (hard r2d constraints):
#   * qemu-system-sh4 -M r2d can only -kernel a zImage up to ~16MB AND the sh
#     zImage self-decompressor overwrites the compressed image once the
#     decompressed vmlinux exceeds ~8MB (compressed image is loaded at
#     MEMORY_START+0x800000).  The defconfig kernel is ~7.3MB, so the embedded
#     (compressed) initramfs must be <~0.5MB.
#   * A pre-compressed .cpio.{gz,xz} as INITRAMFS_SOURCE does NOT boot; gzip of
#     the tree is too bulky.  Only a DIRECTORY source + kernel-side XZ both fits
#     and boots.
#   * busybox alone (1.4MB) blows the budget, so PID1 is a static C init and
#     LTP is limited to a core MM subset (~12 tests).  Full LTP (101) builds
#     fine (build-ltp-cross.sh sh4) but cannot fit r2d; external-initrd arches
#     run the full set.
#
# Prereqs: Bootlin sh4 musl toolchain on PATH; pgcl-test/pgcl-stress for sh4 in
# sh4-root/bin; LTP built via ./build-ltp-cross.sh sh4 (build/ltp-sh4/).
set -eu

SD="$(cd "$(dirname "$0")" && pwd)"
IR="$SD/initramfs"
R="$IR/sh4-ltp-root"
BB="$IR/sh4-root/bin"
LTP="$SD/build/ltp-sh4"

# Core PGCL-relevant MM tests that fit the r2d budget (override with $SH4_LTP_SUBSET).
SUBSET="${SH4_LTP_SUBSET:-mmap01 mmap02 mmap03 mmap06 mmap12 mremap01 mremap02 \
mprotect01 mprotect02 mprotect03 madvise01 mincore01}"

for f in "$BB/pgcl-test" "$BB/pgcl-stress" "$SD/sh4-ltp-init.c" "$IR/sh4-nodes.txt"; do
	[ -e "$f" ] || { echo "MISSING prereq: $f"; exit 1; }
done
[ -d "$LTP" ] || { echo "MISSING LTP: run ./build-ltp-cross.sh sh4"; exit 1; }

echo "=== compile busybox-free C init (static sh4) ==="
sh4-linux-gcc -static -Os -o /tmp/sh4-ltp-init "$SD/sh4-ltp-init.c"
sh4-linux-strip /tmp/sh4-ltp-init

echo "=== assemble $R ==="
rm -rf "$R"; mkdir -p "$R"/{bin/ltp,proc,sys,dev,tmp}
install -m755 /tmp/sh4-ltp-init "$R/init"
install -m755 "$BB/pgcl-test" "$BB/pgcl-stress" "$R/bin/"
n=0
for t in $SUBSET; do
	if [ -f "$LTP/$t" ]; then install -m755 "$LTP/$t" "$R/bin/ltp/"; n=$((n+1)); fi
done
echo "  init + pgcl-test + pgcl-stress + $n LTP tests"
echo "  NOTE: matrix-driver-all.sh embeds this dir via INITRAMFS_SOURCE +"
echo "        INITRAMFS_COMPRESSION_XZ (do NOT pre-compress to a .cpio)."
