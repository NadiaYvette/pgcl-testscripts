#!/bin/bash
set -u
D=/home/nyc/src/pgcl; LX=/home/nyc/src/linux; KB=$D/sh4-pgcl4-build; OUT=$D/sh4-cell-out
TC=/home/nyc/x-tools/sh-sh4--musl--stable-2025.08-1
export PATH="$TC/bin:/usr/bin:$PATH"
cd "$LX"
echo "=== rebuild sh4 PGCL=4 with update_mmu_cache_range fix @ $(date +%T) ==="
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" -j8 zImage >"$OUT/fix.kb" 2>&1
[ -f "$KB/arch/sh/boot/zImage" ] || { echo BUILDFAIL; tail -6 "$OUT/fix.kb"; exit 2; }
echo "=== boot diag2 (full COW sequence) @ $(date +%T) ==="
timeout 150 qemu-system-sh4 -M r2d -serial null -serial stdio -no-reboot -kernel "$KB/arch/sh/boot/zImage" > "$OUT/fix.boot" 2>&1
echo "================ sh4 fork-COW FIX VERDICT ================"
grep -hE 'DIAG2|CHILD|PARENT|C-READBAD|C-WRITEBAD|P-ODDBAD|P-EVEN-ISO' "$OUT/fix.boot" 2>/dev/null
echo "(qemu $(grep -qE 'terminating on signal 15' "$OUT/fix.boot" && echo HUNG || echo exited))"
echo "DONE @ $(date +%T)"
