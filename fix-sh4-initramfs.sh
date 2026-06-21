#!/bin/bash
set -u
D=/home/nyc/src/pgcl; LX=/home/nyc/src/linux; US=$D/userspace
KB=$D/sh4-pgcl4-build; OUT=$D/sh4-cell-out
TC=/home/nyc/x-tools/sh-sh4--musl--stable-2025.08-1
export PATH="$TC/bin:/usr/bin:$PATH"

echo "=== extract full initramfs to a dir (files+symlinks) @ $(date +%T) ==="
RD="$US/initramfs/sh4-root"; rm -rf "$RD"; mkdir -p "$RD"
( cd "$RD" && zcat "$US/initramfs/initramfs-sh4.cpio.gz" | cpio -idm 2>/dev/null )
echo "  files: $(find "$RD" -type f | wc -l), symlinks: $(find "$RD" -type l | wc -l)"

echo "=== device-node spec (gen_init_cpio format, no root needed) ==="
cat > "$US/initramfs/sh4-nodes.txt" <<NODES
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/zero 0666 0 0 c 1 5
nod /dev/kmsg 0644 0 0 c 1 11
nod /dev/ttySC1 0660 0 0 c 204 9
NODES

echo "=== point kernel at dir+nodes (gen_initramfs merges -> dev nodes in cpio) ==="
cd "$LX"
scripts/config --file "$KB/.config" \
  --set-str INITRAMFS_SOURCE "$RD $US/initramfs/sh4-nodes.txt"
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" olddefconfig >>"$OUT/kbuild3.log" 2>&1
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" -j8 zImage >>"$OUT/kbuild3.log" 2>&1
[ -f "$KB/arch/sh/boot/zImage" ] || { echo "BUILD FAIL"; tail -6 "$OUT/kbuild3.log"; exit 2; }

echo "=== boot @ $(date +%T) ==="
timeout 300 qemu-system-sh4 -M r2d -serial null -serial stdio -no-reboot -kernel "$KB/arch/sh/boot/zImage" > "$OUT/boot3.log" 2>&1
echo "  qemu rc=$?"
echo "================ sh4 PGCL=4 musl-userspace VERDICT ================"
grep -hoE 'Page size.*|Test Summary:.*|: (PASS|FAIL|SKIP)|PGCL[^|]*|Bad page|BUG:|unable to open' "$OUT/boot3.log" | tail -30
echo "rmap/mapcount issues: $(grep -ciE 'rmap.h:|Bad page|nonzero.*mapcount|does not match folio' "$OUT/boot3.log")"
echo "DONE @ $(date +%T)"
