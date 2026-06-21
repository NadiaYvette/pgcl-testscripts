#!/bin/bash
set -u
D=/home/nyc/src/pgcl; LX=/home/nyc/src/linux; KB=$D/sh4-pgcl4-dbg; OUT=$D/sh4-cell-out
TC=/home/nyc/x-tools/sh-sh4--musl--stable-2025.08-1
export PATH="$TC/bin:/usr/bin:$PATH"
cd "$LX"
echo "=== set CMDLINE without panic=1 (let the Oops print) + rebuild @ $(date +%T) ==="
scripts/config --file "$KB/.config" --set-str CMDLINE "console=ttySC1,115200 noiotrap ignore_loglevel"
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" olddefconfig >>"$OUT/bt.kb" 2>&1
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" -j8 zImage >>"$OUT/bt.kb" 2>&1
[ -f "$KB/arch/sh/boot/zImage" ] || { echo BUILDFAIL; tail -5 "$OUT/bt.kb"; exit 2; }
echo "=== boot (no panic=1 -> Oops prints, then halt) @ $(date +%T) ==="
timeout 120 qemu-system-sh4 -M r2d -serial null -serial stdio -no-reboot \
  -kernel "$KB/arch/sh/boot/zImage" > "$OUT/bt.boot" 2>&1
echo "================ sh4 COW-write panic backtrace ================"
awk '/cow-write i=0 OK/{f=1} f' "$OUT/bt.boot" 2>/dev/null | head -50
