#!/bin/bash
# build-sh4-cell.sh — finish the full sh4 matrix cell:
#   wait for busybox-sh4 -> re-pack initramfs (musl busybox+pgcl-test+stress)
#   -> build sh4 PGCL=4 kernel -> boot-test the full userspace under qemu r2d.
set -u
D=/home/nyc/src/pgcl; US=$D/userspace; LX=/home/nyc/src/linux
TC=/home/nyc/x-tools/sh-sh4--musl--stable-2025.08-1
export PATH="$TC/bin:/usr/bin:$PATH"
OUT=$D/sh4-cell-out; mkdir -p "$OUT"
BB="$US/build/busybox-sh4/busybox"

echo "=== [1] wait for busybox-sh4 @ $(date +%T) ==="
for i in $(seq 1 80); do
  [ -f "$BB" ] && break
  pgrep -f '[m]ake.*busybox-sh4' >/dev/null 2>&1 || { sleep 3; break; }
  sleep 5
done
[ -f "$BB" ] && echo "  busybox OK ($(du -h "$BB"|cut -f1))" || { echo "  BUSYBOX MISSING — abort"; exit 1; }

echo "=== [2] re-pack initramfs-sh4 (now with busybox) @ $(date +%T) ==="
( cd "$US" && bash ./build-all.sh sh4 ) >"$OUT/repack.log" 2>&1
sz=$(stat -c%s "$US/initramfs/initramfs-sh4.cpio.gz" 2>/dev/null); echo "  initramfs: $sz bytes"

echo "=== [3] build sh4 PGCL=4 kernel @ $(date +%T) ==="
KB=$D/sh4-pgcl4-build; rm -rf "$KB"; mkdir -p "$KB"
cd "$LX"
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" rts7751r2dplus_defconfig >"$OUT/kbuild.log" 2>&1
scripts/config --file "$KB/.config" --set-val PAGE_MMUSHIFT 4 \
  --enable BLK_DEV_INITRD --set-str INITRAMFS_SOURCE "$US/initramfs/initramfs-sh4.cpio.gz" \
  --enable CMDLINE_OVERWRITE --set-str CMDLINE "console=ttySC1,115200 noiotrap panic=1 autotest=1"
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" olddefconfig >>"$OUT/kbuild.log" 2>&1
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" -j8 zImage >>"$OUT/kbuild.log" 2>&1
if [ ! -f "$KB/arch/sh/boot/zImage" ]; then echo "  KERNEL BUILD FAIL"; tail -8 "$OUT/kbuild.log"; exit 2; fi
echo "  zImage OK ($(grep -c CONFIG_PAGE_MMUSHIFT=4 "$KB/.config") @ PGCL4)"

echo "=== [4] boot-test sh4 PGCL=4 + musl userspace @ $(date +%T) ==="
timeout 300 qemu-system-sh4 -M r2d -serial null -serial stdio -no-reboot \
  -kernel "$KB/arch/sh/boot/zImage" > "$OUT/boot.log" 2>&1
echo "  qemu rc=$?"
echo "================ sh4 VERDICT ================"
grep -hoE 'Page size.*|Test Summary:.*|: (PASS|FAIL|SKIP)|PGCL-[A-Z]+:.*|Bad page|BUG:|Kernel panic|Run /init' "$OUT/boot.log" 2>/dev/null | tail -25
echo "rmap/mapcount issues: $(grep -ciE 'rmap.h:|Bad page|nonzero.*mapcount|does not match folio' "$OUT/boot.log")"
echo "DONE @ $(date +%T)"
