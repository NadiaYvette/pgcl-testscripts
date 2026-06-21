#!/bin/bash
set -u
D=/home/nyc/src/pgcl; LX=/home/nyc/src/linux; KB=$D/sh4-pgcl4-build
TC=/home/nyc/x-tools/sh-sh4--musl--stable-2025.08-1
export PATH="$TC/bin:/usr/bin:$PATH"
OUT=$D/sh4-cell-out
echo "=== enable DEVTMPFS + rebuild @ $(date +%T) ==="
cd "$LX"
scripts/config --file "$KB/.config" --enable DEVTMPFS --enable DEVTMPFS_MOUNT
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" olddefconfig >>"$OUT/kbuild2.log" 2>&1
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" -j8 zImage >>"$OUT/kbuild2.log" 2>&1
[ -f "$KB/arch/sh/boot/zImage" ] || { echo "REBUILD FAIL"; tail -5 "$OUT/kbuild2.log"; exit 2; }
echo "=== re-boot @ $(date +%T) ==="
timeout 300 qemu-system-sh4 -M r2d -serial null -serial stdio -no-reboot -kernel "$KB/arch/sh/boot/zImage" > "$OUT/boot2.log" 2>&1
echo "  qemu rc=$?"
echo "================ sh4 PGCL=4 musl-userspace VERDICT ================"
grep -hoE 'Page size.*|Test Summary:.*|: (PASS|FAIL|SKIP)|PGCL[^ ]*[^|]*|Bad page|BUG:|panic' "$OUT/boot2.log" 2>/dev/null | tail -30
echo "rmap/mapcount issues: $(grep -ciE 'rmap.h:|Bad page|nonzero.*mapcount|does not match folio' "$OUT/boot2.log")"
echo "DONE @ $(date +%T)"
