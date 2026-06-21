#!/bin/bash
set -u
D=/home/nyc/src/pgcl; LX=/home/nyc/src/linux; US=$D/userspace
KB=$D/sh4-pgcl4-build; OUT=$D/sh4-cell-out; RD="$US/initramfs/sh4-root"
TC=/home/nyc/x-tools/sh-sh4--musl--stable-2025.08-1
export PATH="$TC/bin:/usr/bin:$PATH"
# run the ACTUAL pgcl-test (the program that failed) on the post-#94-fix kernel
cp "$US/build/pgcl-test-sh4" "$RD/init"; chmod +x "$RD/init"
cd "$LX"
echo "=== rebuild sh4 PGCL=4 (has #94 mmap.c fix) @ $(date +%T) ==="
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" -j6 zImage >>"$OUT/retest.kb" 2>&1
[ -f "$KB/arch/sh/boot/zImage" ] || { echo BUILDFAIL; tail -4 "$OUT/retest.kb"; exit 2; }
echo "=== boot @ $(date +%T) ==="
timeout 180 qemu-system-sh4 -M r2d -serial null -serial stdio -no-reboot -kernel "$KB/arch/sh/boot/zImage" > "$OUT/retest.boot" 2>&1
echo "================ pgcl-test post-#94-fix VERDICT ================"
grep -hoE '[a-z_]+ +(PASS|FAIL[^|]*)' "$OUT/retest.boot" 2>/dev/null | head -10
echo "fork_cow line: $(grep -hE 'fork_cow' "$OUT/retest.boot" 2>/dev/null | tail -1)"
echo "DONE @ $(date +%T)"
