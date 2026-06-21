#!/bin/bash
set -u
D=/home/nyc/src/pgcl; LX=/home/nyc/src/linux; US=$D/userspace
KB=$D/sh4-pgcl0-build; OUT=$D/sh4-cell-out; RD="$US/initramfs/sh4-root"
TC=/home/nyc/x-tools/sh-sh4--musl--stable-2025.08-1
export PATH="$TC/bin:/usr/bin:$PATH"
cp "$US/build/pgcl-test-sh4" "$RD/init"; chmod +x "$RD/init"
cd "$LX"
echo "=== build sh4 PGCL=0 (mainline-equiv) @ $(date +%T) ==="
rm -rf "$KB"; mkdir -p "$KB"
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" rts7751r2dplus_defconfig >"$OUT/kb0.log" 2>&1
scripts/config --file "$KB/.config" --set-val PAGE_MMUSHIFT 0 \
  --enable DEVTMPFS --enable DEVTMPFS_MOUNT \
  --set-str INITRAMFS_SOURCE "$RD $US/initramfs/sh4-nodes.txt" \
  --enable CMDLINE_OVERWRITE --set-str CMDLINE "console=ttySC1,115200 noiotrap panic=1"
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" olddefconfig >>"$OUT/kb0.log" 2>&1
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" -j8 zImage >>"$OUT/kb0.log" 2>&1
[ -f "$KB/arch/sh/boot/zImage" ] || { echo BUILDFAIL; tail -5 "$OUT/kb0.log"; exit 2; }
echo "=== boot PGCL=0 @ $(date +%T) ==="
timeout 150 qemu-system-sh4 -M r2d -serial null -serial stdio -no-reboot -kernel "$KB/arch/sh/boot/zImage" > "$OUT/boot-pgcl0.log" 2>&1
echo "================ sh4 PGCL=0 pgcl-test (A/B control) ================"
grep -hoE 'Page size.*|[a-z_]+ +(PASS|FAIL[^|]*)' "$OUT/boot-pgcl0.log" | head -15
echo "DONE @ $(date +%T)"
